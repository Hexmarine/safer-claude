---
name: sso-duplicate-email-login-shadowing
description: admin.sensorglobal / SSO login fails when an email has duplicate tbl_admins rows — the lowest-id row (incl. DELETED) shadows all others; un-delete or re-home the collider to fix
metadata: 
  node_type: memory
  type: project
  originSessionId: 2ec54da6-1beb-4b18-b5b1-90ee3b296fbe
---

When one email has multiple `tbl_admins` rows, SSO login resolves to the
LOWEST-id row only — including a soft-DELETED one — and the real ACTIVE personas
are unreachable. Confirmed 2026-06-21 for kristyn.heywood@gmail.com (could not
log in to admin.sensorglobal).

**Mechanism (two latent code facts, dup email is just the trigger):**
- sso-provider `account.service.ts` getOne AUTH path builds `whereCond = { email }`
  ONLY — no `userType`, no `status` — then `Admins.findOne(...)` (no `ORDER BY`,
  Sequelize adds `LIMIT 1`) → MySQL returns the clustered-PK-first row = lowest id.
- `auth.controller.ts` login has NO status gate: it just does
  `account?.password === password`. So a DELETED/BLOCKED lowest-id row isn't
  rejected with a "blocked" message — it's silently used, and the only outcome is
  a password compare against the wrong row → presents as "Email/password incorrect"
  even when the user's password is correct for their real account.
- admin.sensorglobal = ADMIN_HOST = SUB_ADMIN/SUPER_ADMIN portal (per-userType
  redirect at `sensor-alarm-backend` `controllers/sso.controller.ts:212-231`).

**Kristyn case:** 5 rows same email — 59118 SUB_ADMIN (userType 8) was soft-DELETED
(status='2') 2026-05-28 and, being lowest id, shadowed 4 ACTIVE personas
(59119 staff, 59120 agency, 59123 contractor, 59279 landlord). Fix = un-delete
the SUB_ADMIN row: `UPDATE tbl_admins SET status='1' WHERE id=59118 AND status='2'`
(1 row, reversible: set back to '2'). Soft-delete is status-only (row/password/
roleId/token all retained), so un-delete fully restores login; pw hash is SHA-512
hex (128 chars). After restore, findOne returns 59118 = valid SUB_ADMIN.

**Diagnosis recipe:** `sensor-mysql` via `db-tunnel-start.sh mysql` +
`source scripts/load-prod-env.sh`. Roles table is `tbl_role` (singular,
`constants/db_models.ts:16`). LISTING_STATUS: 0=INACTIVE 1=ACTIVE 2=DELETED
3=BLOCKED 4=INVITED. USER_TYPES: 1 superadmin, 2 agency, 4 tradeperson/contractor,
5 servicestaff, 7 landlord, 8 subadmin.

If the user needs a DIFFERENT persona than the lowest-id row, neutralize the
collider's email instead (e.g. `+deadNNNNN`) so findOne falls through. See
[[saferops-test-accounts-and-duplicates]] (lowest-id-wins gotcha) and
[[sensor-account-inactive-symptoms]].
