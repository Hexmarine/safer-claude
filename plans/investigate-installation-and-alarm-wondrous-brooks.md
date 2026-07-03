# Plan — Fix systemic spurious `lowBattery` flag (varchar string-compare)

## Context
Investigating property GREE6/403 surfaced a **systemic bug**: ~2,340 active hubs are
flagged `lowBattery=1` while their battery is numerically healthy (>15). Root cause
is **pinned and proven live**: `tbl_alarms.batteryStatus` is `varchar(20)` (Sequelize
`DataTypes.STRING(20)`), and `updateAlertOnHub` probes for a low child with
`batteryStatus: { [Op.lte]: 15 }`. Sequelize binds `15` as the string `'15'`, emitting
SQL `batteryStatus <= '15'` — a lexical compare where `'100' <= '15'` is TRUE. So
full-battery devices match the "≤15" probe → the hub's `lowBattery` is set to 1.

Live proof (hub 4590, children both `'100'`): `WHERE batteryStatus <= 15` → `[]`;
`WHERE batteryStatus <= '15'` → matches both. Deployed == source (v1.1.0, build
2026-06-25 20:02) so this is a bug in **current** code, not a stale artifact.

Impact is **display-only** (nothing reads `WHERE lowBattery=1` to send comms — verified;
low-battery comms fire off the live MQTT `BATTERY<=15` frame, not this column). So it's
~2,340 misleading operator-portal "low battery" badges + `readStatus` unread markers,
not a notification incident. Outcome wanted: the flag reflects real battery state.

Full detail: MEMORY.md `hub-lowbattery-string-compare-systemic-bug`.

## Decisions (confirmed)
- **Scope:** CAST the one Sequelize bug site **+ harden** the 3 already-correct JS
  comparisons with `Number(...)`. No column-type migration.
- **Cleanup:** draft the scoped mass UPDATE now; apply it **only after** the fix is
  deployed (elevated — named approval at that time).
- **Deliverable now:** apply the fix to the working tree, run `sensor-regression-guard`
  on the diff, write the investigation doc. Deploy stays with the user/dev team.

## Fix surface (from exploration)
- **PRIMARY (the bug):** `src/entities/alarms.entity.ts:2644` — `updateAlertOnHub`,
  the `batteryStatus: { [Op.lte]: 15 }` findOne. Only Sequelize-Op string-compare on
  batteryStatus in the codebase.
- **Harden for clarity (already numeric-correct in JS):** `:2647`
  `controllerDetails.batteryStatus <= 15`; `:1887` (`verifyAlarm`) and `:2052`
  (`updateAlarmUsingIndex`) `params.batteryStatus > 15`. Wrap in `Number(...)`.
- **Imports already present:** `import { Op, Sequelize } from "sequelize"`
  (`alarms.entity.ts:1`). Idiom in repo: `Sequelize.where(Sequelize.literal(...), {...})`.

## Change
Replace the string-compared probe with a numeric CAST, matching repo style:
```ts
const lowBattery = await Alarms.findOne({
  where: {
    controllerId: controllerDetails.id,
    status: LISTING_STATUS.ACTIVE,
    [Op.and]: Sequelize.where(
      Sequelize.literal("CAST(`batteryStatus` AS UNSIGNED)"),
      { [Op.lte]: 15 },
    ),
  },
});
```
- `CAST('100' AS UNSIGNED)=100` → not ≤15 (correct); `'13'`→13 ≤15 (correctly low);
  `NULL`/non-numeric → `CAST` is NULL/0 — confirm desired handling (NULL should NOT
  count as low; add a `batteryStatus IS NOT NULL` guard if needed).
- Harden `:2647/:1887/:2052` with `Number(...)` for defense-in-depth + readability.
- **No column-type migration** in this change (varchar→INT is invasive: backfill +
  audit every read/write); keep scope tight.

## Process (this is core Sensor / JV code — Class-C change)
1. Apply the edit to the working tree.
2. **Run `.claude/agents/sensor-regression-guard.md`** on the diff (mandatory before
   commit per CLAUDE.md) — verify no behavior change for genuinely-low batteries and
   no new error shapes.
3. Write a dated investigation note under `docs/investigations/` (root cause, live
   proof, blast radius, fix, cleanup).
4. Hand the diff to the user/dev team for **deploy** (deploy is elevated — out of scope
   for me to execute).

## Post-deploy data cleanup (ELEVATED — separate, named approval)
The fixed code only recomputes on a hub event, so ~2,340 stale flags won't clear
promptly. After the fix is **live**, propose a one-time scoped correction:
```sql
UPDATE tbl_alarms SET lowBattery = 0
WHERE controller = 1 AND lowBattery = 1 AND CAST(batteryStatus AS UNSIGNED) > 15;
-- expected ~2,340 rows; verify count first with the matching SELECT
```
- Consider whether to also clear the `readStatus=0` unread markers set alongside.
- Mass data change → requires the user to **name the resource** ("go — tbl_alarms
  lowBattery cleanup") per CLAUDE.md; record in `docs/applied-changes.md` after.

## Verification
- **Static/unit:** add a Mocha unit test (sinon/proxyquire, no DB) asserting
  `updateAlertOnHub` builds the findOne with the CAST literal (guards against regression
  of the `Op.lte:15` form). Run `npm run test:unit`.
- **SQL-layer proof (read-only, pre/post):** via `scripts/diag/sql-read.py`, confirm the
  fixed predicate `CAST(batteryStatus AS UNSIGNED) <= 15` excludes `'100'` children and
  still includes genuinely-low (`'13'`) ones.
- **Post-deploy behavior:** pick a healthy 100% hub, trigger `updateAlertOnHub`
  (a `mqtt-diag.py --mode battery` poll, propose→go), and confirm `lowBattery` stays/goes
  to 0 instead of flipping to 1. Re-run the blast-radius `COUNT(*)` and confirm it falls.
```
