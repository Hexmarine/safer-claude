---
name: mcp-server
description: read-only MCP server at /mcp wrapping service queries for Claude/ChatGPT operators
metadata: 
  node_type: memory
  type: project
  originSessionId: 1769fb3b-18a0-44eb-b1d6-92c988578f10
---

**v2 operational toolset (2026-06-07)**: grew from 11 read tools to 19 read + 4
guarded write. New reads: `find_client`/`find_worker` (fuzzy, reuse
`scoreNameSimilarity` from invoice-validation/client-matching), `get_daily_brief`
+ `get_action_queue` (one-call aggregates w/ a `freshness` block),
`search_inbox`/`get_thread` (synced mail incl. EmailMessage.bodyText) +
`gmail_live_search` (live Gmail q=), `get_worker_timesheets` (live Deputy incl.
GPS, for self-validating invoices). Writes (operator-only, rejected for the
static service token, audited): `set_event_review_status`, `revalidate_invoice`,
`refresh_inbox`, `sync_deputy`; **proposal-apply deliberately excluded** (HIGH
risk, UI only). Registration was split out of server.ts into `src/mcp/tools/*`
(`registrar.ts` has `registerReadTool`/`registerWriteTool` + audit policy;
`instructions.ts` holds MCP_INSTRUCTIONS). Freshness is **on-demand** (no prod
cron, by user choice) — `getInboxFreshness` is embedded everywhere so answers
state staleness + offer refresh_inbox. New resource `docs://operator-playbook`;
invoice-validation.md got an agent self-validation playbook (rules: 0.5h
tolerance, 1000m attendance, non-clockable transport, area-day grouping). New
audit actions `roster.event.review_updated`, `inbox.refresh.triggered`. No DB
migration (code-only). Note: local full-suite runs flake with 5s-timeout
failures under load (12-core box thrashed by parallel builds) — not logic; passes
with --testTimeout bumped / fewer workers, and CI passes at default.

**Client editing via proposals (2026-06-07, same day)**: added 4 more tools (27
total) in `src/mcp/tools/proposal-tools.ts` — `list_client_proposals` (read) +
guarded writes `propose_client_change` (plain-English →
`createManualClientRegistryProposal`), `propose_from_thread` (resolve
gmailThreadId→internal EmailThread.id → `createGmailClientRegistryProposal`),
`apply_proposal`. Review-first: the agent DRAFTS proposals (mutate nothing until
applied); `apply_proposal` only applies kinds in {notes, standing_fact} — it
rejects schedule/status/contact/address with a "use the web UI" message. Reuses
`listClientRegistryProposalSets` + `applyClientRegistryProposal`; audits
`roster.proposal.created` / `roster.proposal.applied` (existing actions, no
migration). Caveat: registerWriteTool audits the *attempt* before run, so a
guard-rejected apply still writes a `roster.proposal.applied` row (result shows
ok:false) — acceptable "logs the attempt" semantics.

Added a **read-only MCP server** so operators can investigate the app
conversationally from Claude/ChatGPT. v1 scope/decisions (all locked by user):

- **Transport/auth:** stateless Streamable-HTTP at `POST /mcp` on the same
  service, guarded by shared bearer token `MCP_AUTH_TOKEN` (modeled on
  `JOB_SHARED_SECRET`). Mounted only when `MCP_ENABLED=true`. GET/DELETE → 405.
  Connect via the `mcp-remote` bridge.
- **OAuth 2.1 shipped 2026-06-07** (the once-deferred phase), verified live in
  ChatGPT same day (it called get_dashboard/get_report over OAuth, real data). So
  ChatGPT can connect — its connector UI has no static-API-key field, only
  OAuth/No-Auth. ChatGPT-side gotchas that cost time: a broken first connector
  became a "Draft" (delete it), and connectors only attach to NEW chats + may
  cache an empty tool list, so a clean re-add + fresh chat was the fix (server was
  fine throughout — prod tools/list always returned 11).
  `/mcp` now accepts EITHER the static token OR a per-operator OAuth bearer
  (combined `requireMcpAuth` in `mcp-routes.ts`: static first, else SDK
  `requireBearerAuth`). The app is its own OAuth AS via the MCP SDK's
  `mcpAuthRouter` (mounts `/authorize` `/token` `/register` + `.well-known/*` at
  root); our `OAuthServerProvider` (`src/mcp/oauth/provider.ts`) makes `authorize`
  **bridge into the existing Google login** (`/auth/login/google` →
  `/mcp-oauth/resume`), reusing the `User` email allowlist — so OAuth tool calls
  are audited to the REAL operator, not `mcp`. Access/refresh tokens are stateless
  signed JWTs (`src/mcp/oauth/tokens.ts`, HMAC over `APP_SESSION_SECRET`);
  `verifyAccessToken` re-checks the `User` row every call, so removing a user is
  instant revocation. 3 DB tables (`McpOAuth{Client,PendingAuth,Code}`); no token
  table. No new env (reuses MCP_ENABLED + Google-login creds + APP_SESSION_SECRET +
  APP_BASE_URL as issuer, must be HTTPS in prod).
- **Read-only only** — 11 tools, each a 1:1 wrap of an existing query service
  (no mutation/trigger/draft tools), so review-first holds by construction.
- **Full client data** exposed to the model (same precedent as Gemini/OpenAI
  extraction); every call audited as `mcp.tool.executed`, actor `mcp`.

**Three context layers** describe the system to the model: always-on server
`instructions` (`MCP_INSTRUCTIONS` — domains, real eventType/factType vocab,
tool playbook, caveats); read-on-demand **resources** (`docs://registry-model`,
`docs://invoice-validation` — bundled into `dist/mcp/resources/` by build:server
since prod image excludes `docs/`); and per-tool descriptions. Claude honors all
three; ChatGPT is tool-centric so tool descriptions stay self-contained.
`docs/mcp.md` has a curated "Meaningful requests" set.

Key files: `src/mcp/server.ts` (`buildMcpServer(req)` registers tools + resources),
`src/routes/mcp-routes.ts` (transport), `requireMcpToken` in
`src/middleware/auth.ts`, `env.mcp` in config, `docs/mcp.md`. Tests:
`test/integration/mcp.test.ts` uses the SDK `InMemoryTransport` + `Client` to
exercise tools — one case is DB-backed and `it.skipIf(!dbReachable)`-guarded (probes
`SELECT 1` at collection) because CI has no Postgres; the rest run DB-free.

**Live in prod since 2026-06-02** at `https://email-ops-summary-acxbd3ruka-ts.a.run.app/mcp`
(401 tokenless / 200 with bearer). Deploy lesson (see [[prod-deploy-via-github-actions]]):
prod deploys via `.github/workflows/ci.yml` on push to main, NOT `scripts/deploy.sh`;
its `gcloud run deploy --set-env-vars/--set-secrets` REPLACE the whole set, so
`MCP_ENABLED=true` + `MCP_AUTH_TOKEN` had to be added there or each deploy wiped them.

Why the investigative angle: the SPA only has fixed views; ad-hoc cross-entity
questions (registry × invoices × threads) are where chat-over-tools wins. The
codebase suited it because logic already lives in `src/services/*` with a shared
prisma singleton, so the MCP is a thin second transport. Related:
[[two-apply-systems-clientemailevent-vs-proposals]].

Post-OAuth verify (Firebase Hosting rewrites `**`→Cloud Run, so root-level
`.well-known/*` must pass through): after deploy curl
`https://operations.cleaningsymphony.com.au/.well-known/oauth-authorization-server`
and `…/.well-known/oauth-protected-resource/mcp` — if Firebase swallows them,
that's the likely break point. (DNS moved to operations.cleaningsymphony.com.au.)

Possible next phases (not built): job-trigger tools, draft-proposal (review-first)
write tools.
