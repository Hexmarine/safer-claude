---
name: sensor-account-inactive-symptoms
description: "How a non-ACTIVE Sensor account presents in safer-ops (persona \"defaulted\" + \"error serial present\") and how to confirm it"
metadata: 
  node_type: memory
  type: project
  originSessionId: 37a45498-e9ae-422d-b657-dcf4449c5278
---

When a depot/installer operator in safer-ops shows **persona "depot · defaulted"** ("can't see sensor role") AND **"error serial present"** blocking add-device/Pair, the usual root cause is that their **Sensor account is not ACTIVE**, not a device/serial problem.

The Sensor SSO exchange (`sensor-alarm-backend/src/controllers/sso.controller.ts:642`) allow-lists **only `status == ACTIVE`** and rejects every other state with the generic message *"Account has been blocked, please contact admin"* (`ACCOUNT_BLOCKED_MESSAGE`, HTTP code in the 423 `UNAUTHORIZED_TOKEN` family). When the exchange fails: no per-user Sensor token + no `userType` → persona defaults to depot, and `getOperatorSensorToken` throws `token_unavailable` → serial lookups error → `checkStatus:"error"` → "error serial present".

**Confirm it from safer-ops pod logs** (no DB needed):
`kubectl --context safer-ops-prod -n safer-ops logs deploy/safer-ops-api -c api --since=8h | grep -E 'auth\.debug\.code_exchange|auth\.sensor_exchange\.failed|auth\.persona\.unresolved'`
— look for `auth.sensor_exchange.failed … "Account has been blocked…"` with the `sub=<sensorUserId>`.

**Confirm the exact account state** via the sanctioned read-only helper: `source ./scripts/load-prod-env.sh` (needs sensorsyn-mfa session + MySQL tunnel on `127.0.0.1:13308`), then `sensor-mysql -t -e "SELECT id, status, userType FROM tbl_admins WHERE id=<id>;"`. `LISTING_STATUS`: 0=Inactive, 1=Active, 2=Deleted, 3=Blocked, 4=Invited (`app.ts:33`). `USER_TYPES`: 4=TradePerson/Contractor, 5=ServiceStaff, 8=SubAdmin (`app.ts:144`). Direct `mysql` with raw creds is blocked by the prod-PII classifier — use the `sensor-mysql` helper and select only non-PII columns.

Example (2026-05-30): kristyn.heywood@gmail.com, Sensor id 59118, was `status=2 (DELETED)`, `userType=8 (SUB_ADMIN)` → all symptoms above. Fix is Sensor-side (admin restores account to ACTIVE), not a safer-ops change. Distinct from [[oidc-expected-issuer-localhost]] and from the token-*expiry* case (the `423`→isAuthFailure re-mint fix). safer-ops now distinguishes this: a 401/403/423 or OperatorTokenError on the add-device serial lookup throws `KitError("sensor_session_inactive")` instead of marking the device `error`. See [[sensor-write-auth-agency-token]], [[installer-identity-model]].
