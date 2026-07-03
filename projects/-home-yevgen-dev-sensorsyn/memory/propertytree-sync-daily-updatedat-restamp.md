---
name: propertytree-sync-daily-updatedat-restamp
description: "Daily PropertyTree sync re-stamps a synced agency's ENTIRE portfolio's updatedAt every run (unconditional update); since portal \"Added On\"=updatedAt, the whole portfolio looks \"newly added today\" daily — looks like a mass import but isn't. Agency 55586 (Melanie Dalwood, ~1000 all-NEW props)."
metadata: 
  node_type: memory
  type: project
  originSessionId: b6b2208e-7cc8-46b8-b4c0-40d6e544c31a
---

Investigated 2026-06-26: "lots of new NEW-status properties dated Jun 27" reported.

**Verdict: cosmetic daily churn, NOT a mass import.** Only 3 props were truly
created that day (createdToday=3); ~1002 were pre-existing, re-stamped.

**Source:** single agency **55586 = "Melanie Dalwood"** (userType 2, tz
Australia/Hobart, onboarded 2026-02-22). ~1076 props total; **1006 status=4
(NEW, never activated)**, 53 status=11, 13 status=1 ACTIVE. The NEW bulk
(ids 22490–23499) were created **2026-02-23** under PropertyTree import
`propertyFileId 18878` (addCount 1010) and have sat un-activated since.

**Why they look "added Jun 27":** portal "Added On" column shows `updatedAt`
(NOT createdAt — see [[property-import-safety-tooling]]). The daily PropertyTree
sync cron `/api/v1/users/properties/sync-property-tree-cron`
(`PropertiesEntities.syncPropertyTreeCron`, properties.entity.ts:18542; agency
processed at its LOCAL 05:00 = 19:00 UTC for Hobart) re-stamps `updatedAt` on the
whole portfolio every run → whole portfolio floats to top dated "today", every
day. Today=Jun27 Hobart, tomorrow=Jun28, etc.

**Mechanism — unconditional full re-write daily:**
- Fetch `getPropertyTreeProperties()` = `/residentialproperty/v1/Properties`
  with **NO modified-since filter** (full portfolio every run; `lastSyncAt`
  column exists but is NOT used to filter the pull — only written after).
- Match existing row **by GUID** (`PROPERTY_GUID`), entity.ts:11412.
- **`Properties.update()` at entity.ts:12422 is UNCONDITIONAL** — runs for every
  matched prop whether or not anything changed → bumps updatedAt + re-runs status
  logic (CAN reset status→NEW on landlord change), landlord-history create, MQTT
  `{"CMD":"VERIFY"}` on ACTIVE controllers, SIM status changes — daily on
  unchanged data. `activeCount` on the file = props that reached this block:
  **~1001 every day** (Jun 18–26 all ~1000–1004) → proof it's daily, not one-off.
- `updateCount` increments ONLY on `!isEqual(params, csvData)` (entity.ts:12465),
  `addCount` only on agency change → file record reads tiny (e.g. add=3/update=4)
  while ~1004 rows re-stamped. **Don't trust add/updateCount as "what moved";
  activeCount is the processed count.**

**KEY GOTCHA (I got this wrong first):** `updatedAt` is one column = LATEST run
only. Querying "rows with updatedAt=today" shows ~all, "prior days"=~0 — looks
like a one-off, but it's daily overwrite. Use `activeCount` across day-files to
see recurrence, not the updatedAt histogram.

**The 71 not-touched-today:** 18 status=4 that **error every run**
(`errorCount=18` constant in every day's file — a stuck bad-data subset, worth a
separate look) + 53 status=11 (excluded from sync path).

**Comms? NO (verified 2026-06-26).** The daily re-stamp generates no customer
comms for this portfolio. Comm sites in the sync update path: tenant template
**S033** (entity.ts:~12688 & ~12792) + `sendEmailOnCreateAgent` (~11751). S033 is
double-gated `propertyData.status == PROPERTY_STATUS.ACTIVE` AND a genuinely-new
tenant email AND `createLeaseAndImportTenants` → the all-NEW (status=4) bulk fails
the ACTIVE gate, so no S033. No SMS/push in the update path; no summary/digest
email in the cron body (18104–18650). Empirical proof: tbl_logs `reportType:"Email"`
count for propertyId 22490–23499 = **0** (none ever). Comms WOULD fire only on
real state changes (new tenant on an ACTIVE prop → S033; brand-new agent → agent
email) — not on the cosmetic re-stamp. (MQTT VERIFY in sync is also ACTIVE-gated;
the VERIFY logs seen at 04:xx UTC are the hub-heartbeat cron, not this sync.)

**Potential fixes (none applied):** guard entity.ts:12422 with the already-
computed `isEqual(params, propertyData.csvData)` so update only fires on real
change (kills write-amplification + daily side effects + the cosmetic re-stamp);
and/or surface `createdAt` not `updatedAt` as portal "Added On". Both are
Class-C touches to original shared sync code → regression-guard first
(`Properties.update` side effects: status reset, MQTT VERIFY, SIM, landlord
history). See [[pms-integrations-propertyme-propertytree-status]].
