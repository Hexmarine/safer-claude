---
name: usage-audit-feature-plan
description: Admin usage-audit feature (Phase 1 viewing) — implemented & typecheck/DB verified 2026-05-31
metadata: 
  node_type: memory
  type: project
  originSessionId: ee9fe2a6-fbbd-4ac6-9403-06b9d0761448
---

Product owner wanted an admin-only "who did what" audit, surfaced as a Settings tab. Phase 1 = recording + viewing UI; later = analytics. Approved plan: `/home/ubuntu/.claude/plans/one-more-functionality-usage-audit-keen-cerf.md`.

**Decisions (locked):** curated business actions (named events, not blanket middleware); fields = actor id/email/role + action + targetType/targetId + method/path/status/requestId/traceId/timestamp + small metadata JSON (no raw payloads); coverage = mutations + a few sensitive reads (invoice view).

**Status: Phase 1 IMPLEMENTED & verified (2026-05-31).** Server + client typecheck clean (`npx tsc -p tsconfig.json` and `-p client/tsconfig.json`); dev migration `20260531013129_add_audit_log` applied; `prisma generate` run (client model `auditLog` exists); DB round-trip smoke test passed (insert / paginated list / action filter / case-insensitive actorEmail filter / cleanup).

**What was built:**
- `prisma/schema.prisma`: `AuditLog` model (snapshot actor fields, NO User relation; indexes createdAt, action, actorEmail, [targetType,targetId]) + migration. **PROD still needs `npm run prisma:gcp_deploy`** (see [[prod-migrations-separate-from-app-deploy]]).
- `src/services/audit/actions.ts`: `AUDIT_ACTIONS` catalog + `AUDIT_ACTION_VALUES`. Actions: roster.proposal.{created,updated,applied}, user.{created,updated,deleted}, invoice.{validated,revalidated,viewed,data_cleared}, deputy.{sync.triggered,data_cleared}, analysis.identification.{resolved,no_action}.
- `src/services/audit-service.ts`: `recordAudit(req,{action,targetType?,targetId?,statusCode?,metadata?})` — fail-safe, fire-and-forget (`void recordAudit(...)`), pulls requestId/traceId from `getLogContext()`; `listAuditEvents(filters)` paginated (page/pageSize/actor/action/targetType/targetId/from/to).
- `src/routes/api-audit-routes.ts`: `GET /api/audit` + `GET /api/audit/actions`, both `requireAdminApi`; registered in `src/routes/api.ts`.
- recordAudit emitted in api-roster-proposal-routes, api-user-routes, api-invoice-routes, api-deputy-routes, api-analysis-routes.
- Client: `client/src/api-audit.ts` (getAuditEvents/getAuditActions) exported via `client/src/api.ts` barrel; `client/src/components/SettingsAuditTab.tsx` exports `AuditTab` (table + pagination + action/actor/date filters; uses `useTableSort`+`applySortToRows`, `getAuditEvents`); re-exported from `SettingsTabs.tsx`; rendered admin-gated in `SettingsPage.tsx`; "audit"/"Activity" section in `settings-page-helpers.ts`. CSS appended to `client/src/styles/settings-controls.css`.

**Gotchas hit this session:** (1) the harness duplicated many tool calls and returned phantom "success" for edits that actually failed — always re-verify with grep/git after batch edits. (2) After a schema change you MUST `npx prisma generate` (load env first: `set -a; . ./.env.local; set +a`) or `prisma.auditLog` won't exist on the typed client. (3) I corrupted `schema.prisma` with a `head`/`tail`-splice heredoc that dropped the `GmailAccount` model + `EmailThread` header; recovered by splicing those blocks back from `git show HEAD:prisma/schema.prisma` (they weren't part of the user's report-flags WIP). NEVER rebuild a large file via line-offset shell splices — use Edit on unique anchors. Final `git diff prisma/schema.prisma` is purely additive (AuditLog + report flags). (4) `prisma generate` run bare fails config validation — run via env-loaded shell.

**Code-review follow-ups applied 2026-05-31 (full vitest suite green: 67 files / 462 tests; server+client tsc exit 0):**
- Durability: all `recordAudit` calls changed `void`→`await` (Cloud Run throttles CPU after response; non-awaited insert could drop). recordAudit still never throws (try/catch + logs).
- Retention: `pruneAuditLogs(retentionDays)` in audit-service + `POST /jobs/audit/prune` (requireJobSecret) in src/routes/jobs.ts; new `AUDIT_RETENTION_DAYS` env (env-schema.ts + env.ts `env.audit.retentionDays`); default 365d. Schedule this job to bound table growth (esp. invoice.viewed).
- `to` date filter: client now sends start-of-local-day / end-of-local-day ISO (was UTC-midnight, excluded the chosen day) via helpers in SettingsAuditTab.tsx.
- Docs: statusCode JSDoc fixed (no auto-default); metadata JSDoc strengthened with explicit no-PII/no-payload guidance.
- Tests added: test/unit/audit-service.test.ts (recordAudit write/fallback/fail-safe, listAuditEvents pagination/cap/filters, pruneAuditLogs cutoff) + test/unit/audit-routes.test.ts (403-for-operator on /audit + /audit/actions, admin listing). NOTE: in audit-routes test, mock ONLY prisma (not audit-service.js) — mocking the service module breaks vitest express resolution in auth.ts; mirror require-admin-api.test.ts style.

**Still not done:** (a) PROD migration `npm run prisma:gcp_deploy`. (b) commit (user does commits). (c) Phase 2 analytics. (d) scheduling the prune job (Cloud Scheduler → /jobs/audit/prune).
