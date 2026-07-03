---
name: sensor-mcp-service
description: "New read-only MCP server for ops enquiries (code/sensor-mcp) — what's built, the key constraints, and what's gated for later phases"
metadata: 
  node_type: memory
  type: project
  originSessionId: 8b73630d-9ff6-4e4c-8925-43f8fa489c26
---

`code/sensor-mcp` — a new standalone **read-only MCP server** so Claude/Gemini can
answer operational questions about the Sensor backend ("how many properties in
agency X", "installed today", "device status for property Y"). Built 2026-06-03;
plan at `~/.claude/plans/wise-discovering-hinton.md`.

**Decisions:** internal, cross-agency; **hybrid** data layer (SQL counts/rollups +
Sensor HTTP API for live per-entity state); inbound auth **static bearer, OAuth-ready**;
**public** internet-facing ALB (cloud clients). Clones the safer-ops build/GitOps
stack (Node22/Fastify/pnpm@10.28 pinned, Flux+Kustomize, ECR 747293622182). Stateless
MCP Streamable HTTP transport; one-file-per-tool registry with a shared
audit/row-cap/rate-limit decorator.

**Built & verified (Phase 0–1, API tools coded):** 7 tools registered (ping,
count_properties [SQL→API fallback], count_devices, installs_in_range, list_agencies,
agency_summary, device_status_for_property). 23 unit tests pass; image builds + runs.
codex review clean after fixing 6 findings.

**Hard constraints that shaped it (not obvious from sensor-mcp's own code):**
- sso-provider issues **OPAQUE** access tokens (no JWKS) → auth verification is via
  `/token/introspection`, and there's **no DCR** → see [[oidc-expected-issuer-localhost]],
  [[saferops-idtoken-email-claim-gap]]. That's why v1 is static-bearer.
- **No cluster→Sensor-RDS path and no read replica yet** → all SQL tools are gated on
  owner-approved infra (replica + network + SELECT-only user + `src/data/views.sql`).
  Without `SENSOR_DB_*`/`SENSOR_API_TOKEN` set, tools return a clean `data_source_unavailable`.
- **`live_alerts` is built but NOT registered** — the only alert feed
  (`/users/alarms/alerts`) is agency-scoped by token; no verified cross-agency admin
  alert endpoint. Register in Phase 2 once one is confirmed.
- `AUTH_MODE` is **required** (no default) so it fails closed, not open on mock.
- `tbl_alarms.controller`=1 is a hub, 0 a detector; the device view filters `controller=0`.

Controlled prod mutations still pending owner approval: read replica + network path,
the `CREATE VIEW` DDL + SELECT-only user. See `code/sensor-mcp/docs/runbook.md`.

**DEPLOYED + PUBLIC — verified live 2026-06-21 (memory above was stale):** runs in
EKS `safer-ops-prod` ns `sensor-mcp` (deploy `sensor-mcp-api` 1/1, ClusterIP :8080)
behind an internet-facing ALB + ACM cert at **`https://sensor-mcp.sensorglobal.com`**
(17d uptime). `/readyz` → `authMode: static`, `sqlConfigured:false` (replica still
unbuilt — SQL tools return `data_source_unavailable`, by design), `apiConfigured:true`.
Secret `sensor-mcp-app` (ESO ← SM `sensor-mcp/prod/app`) holds `MCP_STATIC_BEARER`,
`SENSOR_API_TOKEN` (sends correct `access_token: bearer <tok>` header), `SENSOR_API_BASE_URL=
https://api.sensorglobal.com/api/v1`. Live smoke test (SDK client, static bearer):
handshake + all 7 tools + `ping` OK.

**BLOCKER — Sensor admin-API 504 (isolated 2026-06-21):** all API-backed tools
(`count_properties` fallback, `device_status_for_property`) fail because the Sensor
**`/admins/*`** endpoints hang ~60s → gateway **504** whenever a VALID token is
presented (no-token = fast 423; gateway/base paths = fast 404/401; reproduced
direct, bypassing the pod). Hang is in the shared post-token `AdminUserAuth`
session/admin-validation step (list AND details 504 identically) — a
**sensor-alarm-backend** problem, NOT sensor-mcp/network/token. Owned by backend.

**Gemini Enterprise integration (planned, runbook `docs/gemini-enterprise-integration.md`):**
SaferHomes has Gemini Enterprise (Business edition ON; Cloud-side Agent Registry).
Custom-MCP-server registration needs **OAuth 2.0 ONLY** (no static bearer) + billing
on the GCP project (deferred to a weekday). Transport already matches (StreamableHTTP).
Work = flip server `AUTH_MODE=static`→`introspect` (secret edit + rollout restart; NO
new infra — ALB/cert already exist) + register a `gemini_enterprise_mcp` OAuth client
on sso-provider (redirect `https://vertexaisearch.cloud.google.com/oauth-redirect`) +
an introspection client. Top risk to prove first: `iss=localhost:4100` quirk vs
Gemini id_token validation ([[oidc-expected-issuer-localhost]]). Repo git-init'd, not committed.
