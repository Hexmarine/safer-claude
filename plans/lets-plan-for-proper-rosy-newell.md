# Proper fix: structured, correlated logging for sensor-alarm-backend

## Context

Diagnostics on the Sensor platform are hard today because production logging is
effectively blind. The root causes, confirmed by code audit:

- The main log helper `logToConsole` (~938 call sites, `src/utils/Help.ts:196`)
  is wrapped in a `NODE_ENV` gate (`Help.ts:202-207`) that only emits for
  `local`/`dev`/`development`/`qa`. **In production every one of those calls is a
  silent no-op.**
- There is **no HTTP access log** (no morgan/equivalent), so per-request
  method/path/status/latency/who is unrecoverable.
- Logs are **unstructured ANSI strings**, with **no request-scoped context** —
  no `correlationId`/`userId`/route on log lines, and no `AsyncLocalStorage`.
- Sentry is configured but the team **does not have access to the Sentry
  project**, so captured exceptions are invisible to us — it is not a usable
  safety net.
- Side-effect failures go dark or crash: Firebase push has no try/catch
  (`entities/notification.entity.ts`), and the CSV-import finalize is
  fire-and-forget so an SES 454 throttle becomes an unlogged unhandled rejection
  (the `csv-import-email-throttle-aborts-finalize` incident).

**Infra fact that makes the fix cheap:** the backend runs under **PM2 on EC2**
and its stdout/stderr already ship to CloudWatch (`smoke-api-prod-pm2-out-log`,
`smoke-api-prod-pm2-error-log`, `smoke-prod-api-error-logs`). So emitting
structured **JSON to stdout** lands in a sink we already control, queryable via
**CloudWatch Logs Insights** — our Sentry replacement, no new SaaS, no infra
mutation.

**Intended outcome:** every production request and error emits a structured,
correlated JSON line to CloudWatch that we can filter and trace end-to-end
(safer-ops → backend), without changing any existing behaviour.

This plan covers **sensor-alarm-backend only** (Phase 1, the bigger blind spot).
sso-provider is a deliberate follow-up (sketched at the end).

## Regression posture

This is designed to be **additive (Class A/B)** per `CLAUDE.md`:

- We add a **new** pino-based logger that runs in prod; we **do not touch** the
  ~938 `logToConsole` call sites — they remain dev-only debug.
- We **reuse** the existing, tested `resolveCorrelationId()`
  (`src/utils/correlationId.ts`) rather than invent a new scheme.
- We **leave `Sentry.init` as-is** (no behaviour change); our error logging is
  parallel, not a replacement edit.
- New middleware is purely observational (read request, log, set one response
  header); it does not alter routing, auth, response bodies, or status codes.
- Run `.claude/agents/sensor-regression-guard.md` + `codex review --uncommitted`
  before suggesting a commit.

## Changes

### 0. Prove the pipe FIRST (de-risk before building anything)

Before writing the logger, confirm a structured JSON line written to stdout
actually reaches a CloudWatch group we can query. The whole plan assumes
`stdout (PM2) → CloudWatch → Logs Insights`; this step verifies that assumption
cheaply and bails early if the wiring differs from what the log-group names imply.

- Add a one-line, throwaway startup probe (temporary) that prints a single
  tagged JSON line on boot, e.g.
  `console.log(JSON.stringify({ probe: "log-pipe-check", env: process.env.NODE_ENV, ts: Date.now() }))`.
  Deploy/run it in **qa** (not prod) under the normal PM2 process.
- Then confirm it landed, read-only, via CloudWatch Logs Insights against the
  qa group (qa equivalent of `smoke-api-prod-pm2-out-log`), e.g.
  `fields @timestamp, @message | filter @message like "log-pipe-check" | sort @timestamp desc | limit 5`.
  Identify the **exact** qa log-group name first with
  `aws logs describe-log-groups` (read-only).
- **Decision gate:**
  - ✅ line appears → the transport is real; proceed to #1, remove the probe.
  - ❌ nothing appears → STOP. The CloudWatch-agent config (which files it tails)
    differs from assumption; resolve the sink (an infra question, needs the infra
    repo / approval) before investing in the logger. This avoids building a
    structured logger whose output goes nowhere.
- No infra mutation: the probe is an app-level `console.log` only; verification is
  read-only AWS `describe`/Logs-Insights queries.

### 1. New structured logger — `src/utils/logger.ts` (new file)
- pino instance. Level from `process.env.LOG_LEVEL` (default `info`; `debug` when
  `NODE_ENV` is local/dev/qa). Base fields: `service: "sensor-alarm-backend"`,
  `env: NODE_ENV`, `pid`.
- **Redaction** via pino `redact` for the hard "never log secrets" rule: paths
  like `req.headers.authorization`, `req.headers.cookie`, `*.password`, `*.otp`,
  `*.token`, `*.jwt`, `*.secret`, `*.accessToken`. This is the central guard so
  new logging stays safe by default.
- Local dev only: optional `pino-pretty` transport when `LOG_PRETTY=true` (dev
  dependency; prod stays raw JSON for CloudWatch).
- Export `logger` and `getLogger()` (see #2). Reuse Node's built-in
  `crypto.randomUUID()` for ids — **no new uuid dependency**.

### 2. Request context — `src/utils/requestContext.ts` (new file)
- `AsyncLocalStorage<{ correlationId, requestId, userId?, route?, method? }>`.
- `getContext()` and `getLogger()` (= `logger.child(getContext() ?? {})`) so any
  new code logs with correlation automatically, no threading.

### 3. Context + access-log middleware — `src/middleware/observability.ts` (new file)
- **Context middleware** (mount early, after `cookieParser()` ~`index.ts:195`,
  before `session`): resolve `correlationId` via `resolveCorrelationId(req.body,
  req.headers)` (reuse), generate `requestId` if absent, **set response header
  `x-correlation-id`** so safer-ops/clients can stitch the trace, then
  `als.run(ctx, next)`. NOTE: body is parsed by then (json/urlencoded mounted at
  `index.ts:191-193`), so `req.body.correlationId` is available.
- **Access-log middleware**: on `res` `finish`/`close`, log one line —
  `method`, `route`, `status`, `durationMs`, `contentLength`, `userId`,
  `correlationId`. Level by status: `info` <400, `warn` 4xx, `error` 5xx. Skip a
  small noise list (`/health-check`, swagger assets).

### 4. Error visibility (the Sentry replacement) — `src/index.ts`
- In the existing fallthrough error handler (`index.ts:102-113`), **add** a
  `getLogger().error({ err, status, route, correlationId })` call alongside the
  existing `Sentry.captureException` — keep the response unchanged.
- Add process-level `unhandledRejection` and `uncaughtException` handlers that
  log structured errors. This directly closes the CSV-import-finalize and
  Firebase-push dark-failure holes at the safety-net level.

### 5. Targeted context logs at known dark spots (additive `.catch`/try-catch)
Log-then-preserve-behaviour (no logic change), with context, at:
- Firebase push send (`src/entities/notification.entity.ts` ~`:95,:194`) — wrap
  the `messaging().send()` calls so a failure logs instead of crashing/voiding.
- CSV import finalize fire-and-forget (`src/entities/properties.entity.ts`,
  `processUploadProperties`) — attach a `.catch` that logs the finalize failure
  + `correlationId` (the SES-454 case).
- MailManager SES/SendGrid send error paths (`src/libs/MailManagerClass.ts`) —
  ensure send failures log with recipient-shape (not full PII) + messageId.
Keep this set small; the process-level handlers in #4 are the real backstop.

### 6. Tests — `test/*.unit.test.ts` (mocha + chai, existing pattern)
- Logger redaction: secret-bearing fields do **not** appear in output.
- Context middleware: sets `x-correlation-id` response header; populates ALS;
  honours an inbound `x-correlation-id`.
- Access-log: emits expected fields and status→level mapping.
- Error handler: logs structured error and **still returns the same 500 shape**.
Follow `test/correlationId.unit.test.ts` for pure-unit style and
`test/users.test.ts` (chai-http against `test-server`) for middleware.

### Explicitly NOT in scope (flagged separately)
- The ~938 `logToConsole` calls, route logic, auth, response shapes — untouched.
- `Sentry.init` left as-is. Dead `CONSOLE_CLOUD_TRACING` branch + unused
  `src/utils/Logger.ts` winston stub — optional later cleanup, not required.
- **sso-provider `password.ts:69` `verifyToken()` missing-`await` bug** — a real
  latent behaviour bug found during exploration, NOT a logging issue. Track as
  its own fix.

## Files

- New: `src/utils/logger.ts`, `src/utils/requestContext.ts`,
  `src/middleware/observability.ts`
- Edit: `src/index.ts` (mount 2 middlewares; error-handler + process handlers),
  `src/entities/notification.entity.ts`, `src/entities/properties.entity.ts`,
  `src/libs/MailManagerClass.ts` (targeted `.catch`/try-catch logs only)
- New tests under `test/`
- Reuse: `src/utils/correlationId.ts` (`resolveCorrelationId`), `LLevel`/config
  conventions in `src/config/app.ts`
- Dep: add `pino` (+ `pino-pretty` as devDependency). Package manager is pnpm
  (`pnpm-lock.yaml`) — heed the `saferops-ci-pnpm-packagemanager` gotcha.

## Verification

1. `pnpm build` (tsc) is clean; `pnpm test:unit` passes incl. new tests.
2. Local (`pnpm dev`): hit an endpoint →
   - exactly one JSON access-log line with `correlationId`, `route`, `status`,
     `durationMs`;
   - response carries an `x-correlation-id` header;
   - send a request with `x-correlation-id: test-123` → it is echoed back and
     appears on the log line.
3. Trigger a handler error → structured error log emitted AND the existing 500
   response body/shape is unchanged.
4. Throw an unhandled rejection in a throwaway route → process handler logs it
   (proves the CSV/Firebase dark-failure backstop).
5. In qa/deployed env: confirm lines land in CloudWatch
   `smoke-api-prod-pm2-out-log` and a Logs Insights query works, e.g.
   `fields @timestamp, level, msg, correlationId, route, status
    | filter level="error" | sort @timestamp desc`.
6. `.claude/agents/sensor-regression-guard.md` audit + `codex review
   --uncommitted` clean before commit. (User does the commit/push.)

## Phase 2 (later, separate plan): sso-provider
Smaller, already partly remediated (it has an OIDC error-event listener,
`configs/provider.ts`). Follow-ups: add access-log + request-id middleware
(`src/app.ts:32`), make `errorHandlerView` log
(`middlewares/error.middleware.ts`), add a no-auth `GET /health`
(`routes/index.ts`), instrument the silent claim/account-lookup paths
(`configs/oidc.config.ts`, `actions/grants/password.ts`), and JSON-format the
`secretManager.ts` swallow. Reuse the same pino logger pattern (Koa variant).
