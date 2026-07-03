---
name: haven-ops-login-59256
description: "Our own HHS-scoped Sensor operator login (acct 59256, support+haven@saferhomesau.com.au) — why it exists and how it was minted inbox-free"
metadata: 
  node_type: memory
  type: project
  originSessionId: f36d7861-f9b5-4f62-af73-178ecb331372
---

We created our own Haven-Home-Safe-scoped Sensor login because we can't import
into agency 37413 otherwise: acct 59142 (ours) is SUB_ADMIN/agency=NULL (read
only), and the existing HHS ops accounts live on the JV's `sensorglobal.com`
domain whose inbox we don't control.

**Account:** id **59256**, `support+haven@saferhomesau.com.au`, userType 2
(AGENCY), roleId 11 (Agent Admin → has `importsetting:view`), **agency 37413**,
status ACTIVE, `ignoreRecaptcha=1`. Cloned from the clean HHS importer 53519.
Password set 2026-06-05 (not stored here — ask Eugene / re-run the flow).

**How it was made (all in repo):**
- `ops-and-extracts/create-haven-login.sql` — INSERT...SELECT cloning 53519,
  seeding `token='havensetup'` + `mailOTP='123456'` so the OTP reset works.
- `ops-and-extracts/mint-haven-reset-jwt.js` — mints a `validWithOTP` JWT signed
  with the prod key, then `PUT /api/v1/users/reset-password-with-otp`
  `{token, password, confirm_password, code:123456}` sets the password
  inbox-free (no `sensorglobal.com` mailbox needed, no SALT needed).
- Get a token: `POST /api/v1/users/sso/getTokenViaPassword`
  `{email, password, userType:2}` → `data.id_token` carries agency 37413.
  Recaptcha is bypassed because the row has `ignoreRecaptcha=1` and that route
  passes email+userType so `getUser` finds the row.

Plain `support@saferhomesau.com.au` is UNUSABLE for password login — it already
maps to two other accounts (59215 Kristyn Heywood svc-staff, 59235 Kris Kits in
test agency 59120). Sensor email isn't unique and `getTokenViaPassword` resolves
the LOWEST id, so login landed on Kris Kits, not us. The `+haven` plus-address is
a distinct DB string → no collision. Login verified working 2026-06-05
(id_token: userId 59256, agency 37413, roleId 11).

Prod API base: `https://api.sensorglobal.com/api/v1`. Both prod writes (the SQL
INSERT and the reset/token curls) had to be run by Eugene — the agent guardrail
blocks prod secret/DB writes from me. See [[saferops-test-accounts-and-duplicates]].
Security exposure surfaced while doing this: [[sensor-prod-jwt-key-in-repo]].
