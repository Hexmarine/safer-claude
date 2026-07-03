---
name: hub-lowbattery-string-compare-systemic-bug
description: "SYSTEMIC bug surfaced 2026-06-25: ~2340 active hubs spuriously flagged lowBattery=1 while battery is healthy (>15); varchar batteryStatus string-compared ('100' < '15' lexically); display-only (no comm); deployed build likely predates the numeric-compare fix in source"
metadata: 
  node_type: memory
  type: project
  originSessionId: 9f0b02b3-1d09-4a9f-86c9-42cb17e92fc9
---

**SYSTEMIC, pre-existing (found 2026-06-25 via GREE6/403 hub id 4590, prop 21931).**
Blast radius (live counts, tbl_alarms, controller=1 status='1'):
- **2358** active hubs flagged `lowBattery=1` total
- **2340** of them have `CAST(batteryStatus AS UNSIGNED) > 15` (numerically healthy)
  → **~99% of hub low-battery flags are SPURIOUS**; only ~18 genuinely low
- **563** flagged at exactly `batteryStatus='100'`

**Root cause = PINNED 2026-06-26.** The bug is in the **SQL Sequelize generates**,
not the JS. `updateAlertOnHub` (alarms.entity.ts ~2357, deployed build/src/
alarms.entity.js:2357) probes for a low child:
`Alarms.findOne({where:{controllerId, status:ACTIVE, batteryStatus:{[Op.lte]:15}}})`.
`tbl_alarms.batteryStatus` is **varchar(20)**, modeled `declare batteryStatus:string`
→ Sequelize binds the 15 as the STRING `'15'` to match the column type → SQL
`batteryStatus <= '15'` → **lexical** comparison. `'100' <= '15'` is TRUE (also
'10'-'14','100'-'149','1000'+). So healthy full-battery children match the "≤15"
probe → findOne returns a row → hub `update.lowBattery = 1`.
LIVE PROOF (hub 4590 children, both '100'): `WHERE batteryStatus <= 15` → [];
`WHERE batteryStatus <= '15'` → matches both. The sibling JS check
`controllerDetails.batteryStatus <= 15` (:2364) is numeric (correct, false for
'100') — it's specifically the **Op.lte findOne** that's broken.

**Deployed == source** (DISPROVES earlier "old build" guess): live build is v1.1.0,
`build/src/entities/alarms.entity.js` mtime 2026-06-25 20:02, compares numerically
in JS with the Op.lte:15 probe + status:ACTIVE filter + `//update.lowBattery="1"`
commented — identical to local src. The bug is in CURRENT code. (The 13% removed
ghost child id 31904 under reused hub 4590 is correctly excluded by status:ACTIVE;
NOT the cause.) Was 0 before the poll only because updateAlertOnHub hadn't run on
4590 since the children's batteryStatus settled to '100'; the BATTERY poll was the
first run → flipped it.

**FIX APPLIED 2026-06-26; since COMMITTED as `0b135df65` (PR #6045, merged to origin/master; verified 2026-07-03). Mass flag-cleanup of the ~2340 wrong rows still pending (elevated).** alarms.entity.ts: the
`updateAlertOnHub` probe (~:2644) now `[Op.and]:[Sequelize.where(Sequelize.literal(
"CAST(\`batteryStatus\` AS UNSIGNED)"),{[Op.lte]:15})]`; + `Number(...)` hardening at
:2647/:1887/:2052 (behaviour-preserving). New test
`test/updateAlertOnHubLowBattery.unit.test.ts` (full unit suite 79 passing — run with
`NODE_OPTIONS=--no-experimental-strip-types` since this box is node 24 / native
type-strip ESM; CI uses pinned node). sensor-regression-guard = **SAFE** (display-only;
NULL/'' unchanged; only LOW edge: non-numeric junk like 'abc' now matches low via
CAST→0, harmless). Doc: docs/investigations/2026-06-26-hub-lowbattery-varchar-string-compare.md.
Only `updateAlertOnHub` had the Sequelize-Op string-compare; no other site.
**RESOLVED 2026-06-26.** Deployed (CodeDeploy `d-7CWAXUR7J`, Succeeded 12:03 UTC;
serving fleet uniformly on the fix — old build was warm-pool, terminating). Live e2e
verified: hub 4590 recomputed lowBattery 1→0 via a fixed node. THEN mass cleanup ran
(user "go — tbl_alarms lowBattery cleanup"): `UPDATE tbl_alarms SET lowBattery=0,
readStatus=CASE WHEN alertStatus=0 AND tamperedStatus=0 AND connectedStatus='1' THEN
1 ELSE readStatus END WHERE controller=1 AND lowBattery=1 AND
CAST(batteryStatus AS UNSIGNED)>15` → **affected 2341, spurious now 0, 18 genuinely-low
untouched**. Undo ids: docs/investigations/artifacts/2026-06-26-lowbattery-cleanup-undo-ids.txt
(prior uniform lowBattery=1/readStatus=0). Logged in docs/applied-changes.md.
DEPLOY NOTE: node 24 on workstation strips types→ESM; run unit tests with
`NODE_OPTIONS=--no-experimental-strip-types`. Also: a CodeDeploy WARM POOL on the
prior ASG held old-build instances (Warmed:Terminating) — they never served; if one
ever activates pre-refresh it could briefly run old code (didn't here).

**Impact: DISPLAY-ONLY.** grep confirms nothing reads `WHERE lowBattery=1` to send
email/SMS (low-batt comms fire on the live MQTT BATTERY<=15 frame via
sendNotification, not off this column). So this is ~2340 misleading operator-portal
"low battery" badges + readStatus unread markers, NOT a mass-notification incident.

**Behavior note:** the flag is set when aggregation/verify re-runs over a hub
(`updateAlertOnHub`/`verifyAlarm`/the BATTERY path). It is DETERMINISTIC — survived
a full VERIFY→ALARMS→BATTERY re-run on hub 4590 (stayed 1). Does NOT self-heal; a
one-row UPDATE re-flips on the next event. A live VERIFY/BATTERY poll of a healthy
100% hub can FLIP it 0→1 (observed on 4590 at 07:10 then confirmed at 07:26).

**NEXT (not yet done):** (1) pin the exact deployed comparison (diff deployed vs
source / golden-AMI build) — likely a `> "15"` or pre-CAST string compare; (2) code
fix = compare batteryStatus numerically everywhere (Number()/CAST); (3) AFTER fix,
one-time data correction to clear the ~2340 spurious flags (ELEVATED: mass update,
needs explicit approval + exact row scope); (4) regression-guard review. Hub
GREE6/403 itself is healthy: live VERIFY = POWERSTATE 1 (AC), BATTERY 100, roster =
2 water-leak children. Relates to [[sensor-hub-power-handling]],
[[device-mqtt-event-history-tbl-alarm-logs]], [[sensor-device-state-schema-gotchas]],
[[sensor-backend-structured-logging]].
