# Google Chat deploy notifications — safer-ops (pilot)

## Context

Safer Homes wants visibility into safer-ops deployments in Google Workspace Chat,
starting with a pilot: a dedicated Chat space receives a message each time a new
version of safer-ops actually rolls out to prod, showing the **version** and the
**commit message**, with a way to **suppress** the notification from the commit.

Decisions locked with the user:
- **Trigger = real rollout**, not CI publish. safer-ops deploys asynchronously:
  CI (`publish-images`) only pushes images to ECR; Flux CD scans every ~1 min and
  rolls them out. So "deployed" must mean *the new code is actually running*.
- **Mechanism = app self-announce on startup.** The new `safer-ops-api` pod posts
  to Google Chat once when it boots and starts serving. This is the truest "it's
  live" signal and carries exact app metadata — no Flux Provider/Alert wiring and
  no extra service. (Flux's native googlechat notifier was rejected: it reports the
  GitOps-bot commit, with no app version and no developer commit message.)
- **Message = simple text** (Google Chat renders `*bold*`/`_italic_`/`<url|label>`).
- **Skip marker = `[silent]`** (also accept `#silent`), read from the commit
  message at **build time** in CI and baked into the image as a suppress flag.
- **Dedup** so pod restarts/crashloops don't re-announce the same SHA: use the
  existing **MySQL DB via Prisma** (one tiny table), not the Kubernetes API.

Grounding facts verified during exploration:
- CI: `code/safer-ops/.github/workflows/ci.yml` — job `publish-images` (line 55+)
  builds & pushes the API image at line 87. `git show` is available (checkout present).
- Version source of truth: root `package.json` `version` (`0.14.0`); the web app
  already surfaces it as `__APP_VERSION__`. Per-app versions are `0.1.0` noise.
- `apps/api/Dockerfile` final stage (line 12+) is a clean place for build ARG→ENV.
- `apps/api/src/index.ts` is a 8-line clean startup (`buildApp` → `app.listen`).
- Deployment `deploy/gitops/apps/safer-ops/prod/deployment-api.yaml` is `replicas: 1`,
  `envFrom: secretRef safer-ops-app`.
- `externalsecret-app.yaml` uses `dataFrom: extract` of `safer-ops/prod/app` — **any
  key added to that AWS secret auto-appears as a pod env var; no manifest change.**
- Config pattern: env-driven `apps/api/src/config.ts` with an `*Effective()` helper
  (`mqttMonitorEffective`, line 129) — mirror this.
- Traceability is a hard project rule (`code/safer-ops/CLAUDE.md`): every op logs
  START/RESULT/ERROR with an `operation:` tag and ids; **no silent catches**.

## Approach

Bake deploy metadata into the API image at build time, and have the API post a
single Google Chat message on startup, deduped per source SHA via the DB.

### 1. Bake build metadata into the API image
`apps/api/Dockerfile` — in the **final** stage (after line 23, before `EXPOSE`) add
ARGs and promote to ENV (defaults make it an inert no-op for local/dev builds):
```dockerfile
ARG SOURCE_SHA=unknown
ARG APP_VERSION=0.0.0
ARG COMMIT_SUBJECT=""
ARG SOURCE_REPO_URL=""
ARG DEPLOY_ANNOUNCE=false
ENV SOURCE_SHA=$SOURCE_SHA APP_VERSION=$APP_VERSION COMMIT_SUBJECT=$COMMIT_SUBJECT \
    SOURCE_REPO_URL=$SOURCE_REPO_URL DEPLOY_ANNOUNCE=$DEPLOY_ANNOUNCE
```
Place ARGs late so they don't bust the build-layer cache. API image only (web is
not the announcer; both images share the same source SHA, so one message covers
the whole deploy).

### 2. Compute & pass metadata in CI
`.github/workflows/ci.yml`, job `publish-images`. Before the API build (line 80),
add a step that derives the values (checkout already present at line 62):
- `APP_VERSION` = `jq -r .version package.json`
- `COMMIT_SUBJECT` = `git show -s --format=%s "$GITHUB_SHA"` (single line)
- `DEPLOY_ANNOUNCE` = `false` if `git show -s --format=%B "$GITHUB_SHA"` matches
  (case-insensitive) `[silent]` or `#silent`, else `true`
- `SOURCE_REPO_URL` = `${{ github.server_url }}/${{ github.repository }}`
Expose via `$GITHUB_OUTPUT`, then extend the **API** build command (line 87) with
`--build-arg SOURCE_SHA=${{ github.sha }} --build-arg APP_VERSION=... --build-arg
COMMIT_SUBJECT="..." --build-arg SOURCE_REPO_URL=... --build-arg DEPLOY_ANNOUNCE=...`.
Leave the web build (line 99) untouched.

### 3. Dedup table (Prisma)
Add a minimal model to the API Prisma schema (`apps/api/prisma/`) and a migration:
```prisma
model DeployAnnouncement {
  sha         String   @id
  version     String
  announcedAt DateTime @default(now())
}
```
Migrations already run via the `migrate` initContainer (deployment-api.yaml line 29),
so this self-applies on the next rollout. Use the existing migration tooling/format
(match sibling migrations under `apps/api/prisma`).

### 4. Announcer module
New `apps/api/src/deploy-announce.ts`, exporting `announceDeploy(app, deps)`:
- Read inputs from config (see step 5): `announceEnabled`, `webhookUrl`, `sourceSha`,
  `appVersion`, `commitSubject`, `repoUrl`.
- **Guard:** if not enabled, or no webhook URL, or `sourceSha === "unknown"` →
  log `operation: "deploy.announce.skip"` (with reason) and return. Makes it inert
  locally and for `[silent]` builds.
- **Dedup (DB):** `prisma.deployAnnouncement.create({ data: { sha, version } })`.
  On Prisma `P2002` (unique) → already announced → log skip + return.
- **Post:** build the simple-text payload and `POST` the webhook via `fetch`:
  ```
  ✅ *safer-ops v{version}* — deployed
  `{sha.slice(0,7)}` _{commitSubject}_
  <{repoUrl}/commit/{sha}|view commit>
  ```
  (Body: `{ text }`.) On non-2xx or throw → **delete the row** (so a later restart
  retries) and log `operation: "deploy.announce.error"` (warn) with status + sha.
- **Success:** log `operation: "deploy.announce.result"` with sha + version.
- Never throws into startup; all failures are logged, not propagated (honors the
  no-silent-catch rule while keeping the server up).

### 5. Config + startup wiring
- `apps/api/src/config.ts`: add fields (`deployAnnounceEnabled`, `deployChatWebhookUrl`,
  `sourceSha`, `appVersion`, `commitSubject`, `sourceRepoUrl`) read from the matching
  env vars (`DEPLOY_ANNOUNCE`, `DEPLOY_CHAT_WEBHOOK_URL`, `SOURCE_SHA`, `APP_VERSION`,
  `COMMIT_SUBJECT`, `SOURCE_REPO_URL`), plus a `deployAnnounceEffective(cfg)` helper
  mirroring `mqttMonitorEffective` (line 129): enabled AND webhook present AND a real SHA.
- `apps/api/src/index.ts`: after `await app.listen(...)`, call
  `await announceDeploy(app, ...)` inside a `try/catch` that only logs — the server
  must come up regardless.

### 6. Secret (runtime, not baked)
The webhook URL is a runtime secret and must **not** be in git or the image. Add key
`DEPLOY_CHAT_WEBHOOK_URL` to AWS Secrets Manager secret `safer-ops/prod/app`
(region `ap-southeast-2`). It flows to the pod automatically via the existing
`dataFrom: extract` ExternalSecret + `envFrom` — **no manifest edit required.**

### 7. One-time manual setup (user / Workspace admin)
1. Create the Google Chat space (e.g. "safer-ops deploys").
2. Space → Apps & integrations → **Webhooks** → add → copy the tokenized URL.
3. Put that URL in AWS Secrets Manager `safer-ops/prod/app` → key `DEPLOY_CHAT_WEBHOOK_URL`.
(Incoming Webhooks need no OAuth/service account — ideal for the pilot.)

## Files to change
- `apps/api/Dockerfile` — build ARG→ENV (final stage).
- `.github/workflows/ci.yml` — metadata step + API `--build-arg`s in `publish-images`.
- `apps/api/prisma/` — `DeployAnnouncement` model + migration.
- `apps/api/src/deploy-announce.ts` — **new** announcer.
- `apps/api/src/config.ts` — announce config fields + `deployAnnounceEffective`.
- `apps/api/src/index.ts` — call announcer after `listen` (guarded).
- `apps/api/src/deploy-announce.test.ts` — **new** unit tests (match repo's test runner).
- AWS Secrets Manager `safer-ops/prod/app` — add `DEPLOY_CHAT_WEBHOOK_URL` (out-of-repo).

## Verification
**Unit:** `deploy-announce.test.ts` with `fetch` + Prisma mocked —
(a) posts correctly formatted text when enabled+webhook+fresh SHA;
(b) skips when disabled / no webhook / SHA `unknown`;
(c) skips on `P2002` (already announced);
(d) deletes the row + logs error on non-2xx POST.
Then `pnpm typecheck` and `pnpm build`.

**Local end-to-end** (against a throwaway Chat space webhook):
```
DEPLOY_ANNOUNCE=true DEPLOY_CHAT_WEBHOOK_URL=<test webhook> \
SOURCE_SHA=deadbeefcafe APP_VERSION=0.14.0 \
COMMIT_SUBJECT="test: hello" SOURCE_REPO_URL=https://github.com/<org>/<repo> \
pnpm --filter @safer-ops/api dev
```
Expect one message; restart → deduped (no second message); set `DEPLOY_ANNOUNCE=false` → none.

**Prod pilot:** push a normal commit → after Flux rolls (~1–3 min) exactly one
message appears with version + subject + commit link. Push a commit containing
`[silent]` → deploy proceeds, **no** message. Confirm via pod logs
(`operation: "deploy.announce.result"` / `.skip`).

## Finishing step
Run `codex review --uncommitted` in `code/safer-ops` after self-review (per repo habit;
reliably catches cross-layer bugs). The user does commits/pushes — do not commit.

## Note on scope
Pilot covers the **deploy** event only. The "health check" integration mentioned as a
later phase is intentionally out of scope here; this announcer + space is the
foundation it can build on.
