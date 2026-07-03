---
name: saferops-agency-header-pill
description: "safer-ops header now shows the logged-in AGENCY name (a wrong-org guardrail) — how agency id+name are resolved, and the deliberately login-path-free design"
metadata: 
  node_type: memory
  type: project
  originSessionId: f36d7861-f9b5-4f62-af73-178ecb331372
---

Added the logged-in **agency name** to the safer-ops top-right header pill
(built 2026-06-06, after the job-import landed). Rationale: this is a
write-capable, agency-scoped ops console and every mishap this session was a
wrong-org/wrong-account risk ([[haven-ops-login-59256]] +haven collision, the
one-email-many-accounts SSO gotcha) — a visible "Haven Home Safe · depot" turns
"am I in the right org?" into a glance.

**Design (low-risk, login-path untouched):** resolved in `GET /api/me`, NOT at
login/finalize, so it covers single-account AND chooser sessions uniformly and
can't break the sensitive auth path. `withAgencyLabel` (routes.ts) is fully
best-effort (try/catch → returns the session unchanged on any failure).

**How agency id + name are resolved (reusable Sensor knowledge):**
- **agency id**: decode the minted Sensor token payload — it carries an `agency`
  claim (same token `traderPerson` is read from). Helpers added in
  sensor-exchange.ts: `decodeSensorTokenPayload(jwt)` + `readAgencyId(jwt)`. No
  network call for the id.
- **agency id**: token claim often ABSENT for our sub-account login → fall back
  to `SensorClient.getUserAgencyId(subject)` = `/users/users/user-details?id=<subject>`
  → `data.data.agency` (viewing self is allowed). This worked (→ 37413).
- **agency name**: `/users/users/user-details?id=<agencyId>` **404s** for a
  sub-account token (can't read the agency admin row directly). USE the
  token-derived `/users/settings/business/details` instead — for AGENCY/AGENT
  tokens `getBusinessSettingDetail` (settings.entity.ts:197) queries
  BusinessDetails WHERE userId IN [operator, agency], so it returns the AGENCY's
  `business_name` with NO id param (no visibility 404). `SensorClient.getOwnAgencyName()`.
  NOTE: that route is gated by VerifyAccessPermission MENU_SETTINGS/view — if the
  operator's role lacks it, expect 403 → blank pill (then need another source).
  Cached process-wide in `agencyNameCache` (Map agencyId→name, successes only)
  so /api/me's frequent reads (incl. refetch-on-focus) don't re-call per read.

**Related cleanup (2026-06-06):** removed the legacy **Settings → Sensor API**
service-login mechanism entirely — safer-ops uses ONLY the per-operator SSO login
token for Sensor calls (`getOperatorSensorToken`, no service-token fallback).
Deleted `sensor-auth.ts`, the `/api/settings/sensor-api*` routes, the settings
UI section, `SensorApiSettingsStatus`, and the `sensor_api_credentials` table
(migration 20260606000000). `status.ts` connectivity probe reworked to an
UNAUTHENTICATED reachability check (any HTTP response = up; only network
error/timeout = down) since there's no shared token to probe with.

**Plumbing:** `OperatorSession` (packages/shared) gained optional
`agencyId?: number` + `agencyName?: string`; App.tsx renders `.identity-agency`
(bold, divider) before the operator name in the identity-chip.

Tests: sensor-exchange.test.ts covers readAgencyId/decode. Typecheck clean all 3
packages. Runtime-verify: expect "Haven Home Safe" for agency 37413; if the pill
is blank, check the `session.agency_label.failed` warn log or that the token
carried `agency` (fallback would be a user-details?id=<subject> lookup, not built).
