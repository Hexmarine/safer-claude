---
name: saferops-test-accounts-and-duplicates
description: "Test-agency 59120 account roster, the one-email-many-accounts SSO gotcha, and how each email resolves at login"
metadata: 
  node_type: memory
  type: project
  originSessionId: 37a45498-e9ae-422d-b657-dcf4449c5278
---

The safer-ops **test agency is `59120`** (an AGENCY admin in Sensor `tbl_admins`, DB `smokealarmprod`). Its installers (who attach kits) all hang off **Trade Person `59123`**; its depot operators are SaferHomes SUB_ADMINs.

**The role chooser is built AND now works in prod (fixed & verified 2026-05-31).** `/users/sso/exchange` is email-aware (verified email → candidate list → `ChooseAccountView`). It was silently dead for months because it reads the verified email from the **id_token**, which carried no email claim — fixed by `claimsParameter` + a safer-ops claims request ([[saferops-idtoken-email-claim-gap]]). Confirmed: kristyn.heywood@gmail.com now resolves to the 3-account chooser (59119/59120/59123; dead sub 59118 excluded). The gotcha below is the IdP's raw `sub` resolution that the chooser now overrides:

**One email → many Sensor accounts (the big gotcha).** Most testers were created multiple times with different `userType`s. The SSO IdP (issuer `http://localhost:4100`, external — not in the sensor-alarm-backend repo) resolves an email to ONE account (`sub`) at login; the Sensor backend then just trusts that `sub`. Observed rule: **lowest id wins, and it does NOT exclude DELETED accounts.** Examples (id:userType:status):
- `kristyn.heywood@gmail.com` → 59118 SubAdmin **DELETED**(2), 59119 ServiceStaff, 59120 Agency, 59123 TradePerson. Login lands on **59118 (deleted)** → SSO exchange fails → persona "depot · defaulted" + "error serial present". Her clean depot login is the *different* email `kristyn.heywood@saferhomesau.com.au` (59230, SubAdmin ACTIVE).
- `kim.ngo@saferhomesau.com.au` → 59221 Agency / 59222 TradePerson / 59231 SubAdmin (predicted login: 59221, depot).
- `eugene.peresada@saferhomesau.com.au` → 59142 SubAdmin / 59204 ServiceStaff / 59220 Landlord (predicted: 59142, depot).
- `support@saferhomesau.com.au` → 59215 ServiceStaff / 59235 Agency (predicted: 59215, installer).
Predictions for the non-kristyn ones are from the lowest-id rule — confirm per tester by reading `auth.debug.code_exchange` + `auth.persona`/`auth.sensor_exchange` (carry the `sub`/email) in the safer-ops pod after they log in once. See [[sensor-account-inactive-symptoms]].

**Usable depot (create/pre-test kits) — SaferHomes SUB_ADMIN, ACTIVE:** 59117 peresada@gmail.com, 59142 eugene.peresada@…, 59214 czendra.compares@…, 59230 kristyn.heywood@saferhomesau, 59231 kim.ngo@…, 59125 richard.heywood@syncom. Agency-type (also depot) under 59120: 59120/59202/59221/59235.
**Usable installers (attach) — under TradePerson 59123, ACTIVE:** 59123, 59203, 59222 (type4); 59204, 59215, 59223 (type5). 59124 (ServiceStaff) is Inactive → can't attach.

**JV separation gap:** ~120 `@appinventiv.com` accounts are still ACTIVE in prod, incl. two **SUPER_ADMIN** (id 2 jeetendra.singh, id 50 prachi.chaudhary) — full admin. Rest are mostly QA tenant/landlord fixtures (soni.singh+/mayank.kansal+/…). Contradicts "Appinventiv must have no access" ([[sensorglobal-saferhomes-jv.md]]); the privileged subset (userType 1/2/3/4) should be blocked first.
