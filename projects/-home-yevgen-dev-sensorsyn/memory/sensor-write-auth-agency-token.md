---
name: sensor-write-auth-agency-token
description: "Why safer-ops Sensor writes need an agency-class token, not the SUB_ADMIN service token"
metadata: 
  node_type: memory
  type: project
  originSessionId: 37a45498-e9ae-422d-b657-dcf4449c5278
---

Sensor's two auth middlewares are **mutually exclusive by user-type**: `/admins/*` (`AdminAuth`, `auth.ts:103-112`) allows **only** SUPER_ADMIN(1)/SUB_ADMIN(8); `/users/*` (`AdminUserAuth`, `auth.ts:225-238`) allows **everyone except** super/sub-admin. safer-ops' reads were on `/admins/*` and writes on `/users/*`, so **no single user-type passes both** — our SUB_ADMIN `SENSOR_API_TOKEN` read fine but 423'd on every write (createJob, attach, test-alarm).

**Decision (2026-05-23, FINAL): per-user SSO identity.** We own the Sensor backend + SSO provider (JV: keep core backward-compatible), so each operator/installer acts in Sensor as themselves. Enabling fact: `AdminUserAuth` verifies only the RS256 signature, **not `aud`/`iss`** (`auth.ts:185-188`) — so an authorization-code `id_token` we enrich (with `userType`/`userId`/`sessionId`/`verified2fa`, signed by the SSO JWKS) passes `/users/*` with no Sensor-backend change. Build: (1) SSO provider enriches `safer_ops_client`'s tokens + creates a Sensor SESSIONS row at login, on both code-exchange and refresh (enrich-on-refresh, silent renewal); (2) safer-ops uses a per-request `SensorClient` bound to the operator's token; (3) loosen kit attach/test/complete to the owning installer. Prereq: SaferHomes staff need typed Sensor accounts (depot=AGENCY/AGENT, installer=TRADE_PERSON). Full plan in the plan file's "Per-user SSO identity" section.

**Superseded interim idea:** single AGENCY service token via `/users/*`. The `/admins/*`→`/users/*` read migration it required was already shipped and is kept (per-user tokens are also non-admin → `/users/*`).

**Authorization boundary:** an agency-wide token returns ALL agency data to safer-ops regardless of who's logged in, so **safer-ops is the sole per-human authz boundary**. Today kit routes (`kit-routes.ts`) are `requireUser` only — no persona/owner gate (only the UI hides kits from installers). Before installers log in, add depot-only gates on kit mutations and scope installer kit reads to `Kit.serviceStaffId == user.subject` (field is indexed; no `requirePersona` helper exists yet). `/api/jobs/mine` is already correctly scoped by `user.subject` (`job-routes.ts:48`). Kits are safer-ops-local with no `agencyId` (single-agency assumption).

**Why:** the new pre-paired flow is a system/agency integration, not a per-human client — reserve is inherently an agency action (installers can't create installation jobs), and the on-site attach is machine-driven via MQTT. Installer identity rides as `job.serviceStaffId` data, not via token.

**How to apply:** after the 423 clears, expect a second layer — the role needs the JOBS `add` privilege (`VerifyAccessPermission`) and the target property must be owned/agented by that agency (data-visibility), else 403/404. Token still ~2-day expiry (refresh is [[installation-flows-old-and-new]] follow-up #48).

Separately, persona defaults **everyone to depot** because the OIDC id-token/userinfo claims carry no `userType` (safer-ops `oidc.ts:96-100`, `persona.ts`). Fix is ours, not SensorGlobal's: the OIDC `sub` equals the Sensor `userId`, so resolve userType via a Sensor lookup at login. Tracked as the persona-via-lookup follow-up. Full analysis in safer-ops `docs/investigations/2026-05-22-real-api-smoke.md`.
