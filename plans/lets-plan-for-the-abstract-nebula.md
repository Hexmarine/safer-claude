# Haven portfolio recovery — mass deactivation of 2026-06-04/06

## Context

Our 23-row `haven-import-2026-06-05.csv` uploads (login 59256, property files **20920** @ 06-04 22:28 UTC and **20921** @ 06-04 22:34 UTC) triggered the Sensor import's full-snapshot reconcile: every Haven (agency **37413**) property not in the file was deactivated.

**Damage (all verified against prod DB + code):**

| What | Count | Mechanism | Restorable from |
|---|---|---|---|
| `tbl_properties.status` → '11' DEACTIVATED | 1,178 | 278 immediate (06-04, non-ACTIVE ones), 900 via 48h review sweep (06-06 23:00:05) | `previousStatus` preserved on every row: 900×'1', 228×'8', 49×'4', 1×'10' |
| `tbl_jobs` → status 9 CLOSED, `completionDate` set, `rejectReason`='Property no longer in Sensor Global' | 242 (238 jobType 1, 4 jobType 2 — incl. our e2e job 6384) | 237 closed 06-04 22:28, 5 closed 06-06 23:00 | **PITR clones only** — prior status recorded nowhere (`tbl_jobs_logs` empty, no previousStatus column) |
| `tbl_alarms.connectedStatus` → '0' DISCONNECTED | ~2,221 (of 3,545) | flip in `deactivateProperty` for ACTIVE alarms | **PITR clones** (cron does NOT self-heal it; all 902 controllers now '0') |
| KORE SIM deactivation API calls | up to 902 (all simIds are "HS" prefix → calls were attempted) | `changeSimStatus(sid,'inactive')`, errors swallowed | Likely no-op: post-incident connection-test cron shows all 902 `notRespondingCount`=0; verify via MQTT |
| Emails | S138 to contractors/agency (jobs), S114 missing-property warnings | sent 06-04 (partially SES-throttled — both file rows stuck `status`=0) | N/A — user handles comms separately |

**Not damaged:** leases, alarmStatus, alarmTestDate, simStatus in DB, Odoo (odoo_status all NULL), the 23 newly imported properties (status 4, by design). No other agency affected (their June inactiveCounts are normal churn ≤44).

**Re-deactivation risk: currently zero, but neutralize anyway.** The sweep endpoint `/users/properties/review-list-deactivation` (cron-IP-gated, `properties.entity.ts:27712 deactivatePropertyFromReviewList`) selects `tbl_property_review` rows with `status=0 AND isCurrentImport=1 AND createdAt<now-48h` joined to ACTIVE properties. Current rows: 900 (status=0, isCurrentImport=0 — inert) + 900 (status=1, isCurrentImport=1 — consumed). Nothing matches; we'll zero `isCurrentImport` on all of them for belt-and-braces before reactivating properties.

**⏰ HARD DEADLINE:** RDS `sensor-prod` PITR retention is **7 days** (latest restorable 2026-06-10 02:20 UTC). The 06-04 22:20 restore point **expires ~2026-06-11 22:28 UTC** → Phase 0 must run **today**.

**User decisions:** PITR clone for exact fidelity · we execute the writes ourselves · DB recovery only (no comms drafts).

## Key code references (sensor-alarm-backend)

- `src/entities/jobs.entity.ts:10890` `deactivateProperty` — the full effect list (jobs close, property status, alarms flip, SIM call, PropertyFiles counters, review row → APPROVED)
- `src/entities/jobs.entity.ts:9469` `addPropertyInReviewOnCSVImport` — missing-GUID selection + `autoDeactivation` branch (Haven's flag = 1)
- `src/entities/properties.entity.ts:27712` `deactivatePropertyFromReviewList` — the 48h sweep & its WHERE clause
- `src/entities/properties.entity.ts:12349` — CSV re-import reactivation (NOT used; partial semantics, doesn't restore jobs/alarms)
- `src/constants/app.ts` — PROPERTY_STATUS (DEACTIVATED='11'), JOB_STATUS (CLOSED=9), ALARM_CONNECTION_STATUS (CONNECTED='1', DISCONNECTED='0')

## Execution plan

All prod writes run over the existing tunnel (`source ./scripts/load-prod-env.sh`, MySQL on 127.0.0.1:13308, admin creds) inside explicit transactions with `ROW_COUNT()` assertions; abort on any mismatch. Working dir for artifacts: `backups/incident-20260604/`.

### Phase 0 — PITR clones + evidence preservation (TODAY, ~1h wall clock)

Two restore points are needed (wave-2 jobs like 6384 didn't exist on 06-04; wave-1 rows already closed by 06-06):

1. Create both clones in parallel (same VPC/subnet group/SG as `sensor-prod`, copy from `describe-db-instances`; small class e.g. db.t3.medium, no multi-AZ, not public):
   - **clone A**: `--restore-time 2026-06-04T22:20:00Z` → `sensor-prod-inc-a` (before 22:28:03 wave 1)
   - **clone B**: `--restore-time 2026-06-06T22:55:00Z` → `sensor-prod-inc-b` (before 23:00:05 sweep)
2. Port-forward to each clone endpoint using the same SSM mechanism as `scripts/db-tunnel-start.sh` (ad-hoc ports 13309/13310).
3. Extract to CSV (per clone): for agency 37413 — `tbl_properties (id,status,previousStatus,updatedAt)`, `tbl_jobs (id,status,completionDate,rejectReason)` for the affected property set, `tbl_alarms (id,propertyId,connectedStatus,simStatus)`.
4. Snapshot **current live state** of every row we'll touch (`mysqldump --where` for tbl_properties/tbl_jobs/tbl_alarms/tbl_property_review/tbl_property_files scoped to agency 37413 / file ids 20920-21) → rollback baseline.
5. Sanity gate: clone A property statuses must match live `previousStatus` for all 1,178 (expect 900/228/49/1). **If mismatch → stop and reassess.**

### Phase 1 — Neutralize re-triggers (live DB, first writes)

```sql
-- expect 1800
UPDATE tbl_property_review SET isCurrentImport=0 WHERE propertyFileId IN (20920,20921);
-- expect 2; clears stuck 'processing' state from the aborted finalize (counts left as audit trail)
UPDATE tbl_property_files SET status='1' WHERE id IN (20920,20921) AND status='0';
```
Then assert the sweep matches nothing: `SELECT COUNT(*) FROM tbl_property_review WHERE status=0 AND isCurrentImport=1;` → 0 (global).

### Phase 2 — Restore property statuses (1,178 rows)

```sql
-- expect exactly 1178
UPDATE tbl_properties
SET status = previousStatus, previousStatus = NULL
WHERE agency = 37413 AND status = '11' AND previousStatus IS NOT NULL;
```
Post-check: per-status counts = 1→900, 8→228, 10→1, 4→72 (49 restored + 23 new); status-11 count = 0.

### Phase 3 — Restore the 242 jobs (from clone data)

Generate one transaction of per-id UPDATEs from clone extracts (wave 1 ← clone A: jobs with completionDate in 06-04 22:28:04±, wave 2 ← clone B: 06-06 23:00±):

```sql
-- per job id, values from the matching clone row
UPDATE tbl_jobs SET status=<prior>, completionDate=<prior|NULL>, rejectReason=<prior|NULL>
WHERE id=<id> AND status=9 AND rejectReason LIKE 'Property no longer%';
```
Guard: total touched must equal 242; afterwards `rejectReason LIKE '%no longer%'` count for agency 37413 = 0. (Generation script in `backups/incident-20260604/`, plain node or python over the CSVs.)

### Phase 4 — Restore alarm connectedStatus (~2,221 rows)

Restore set = Haven alarms where live `connectedStatus='0'` and clone value differs. Wave attribution via the **property's** `updatedAt` date (06-04 → clone A, 06-06 → clone B); alarm `updatedAt` is unreliable (connection-test cron re-bumped controllers on 06-09/10). Same generated per-id UPDATE pattern with count assertion against the computed restore set.

### Phase 5 — SIM provider verification (read-only)

- `./scripts/mqtt-listen.sh <hub-serial>` for 3–5 hub serials across both waves → confirm live traffic.
- If any hub is silent: query KORE SuperSIM API (creds in backend env / sensor-prod secret) for those SIM statuses; reactivate via KORE/Omondo as needed and recheck. Current evidence (all 902 controllers `notRespondingCount`=0 after post-incident connection tests) says this is likely a no-op.

### Phase 6 — Verification & teardown

1. DB recounts (phases 2–4 assertions re-run).
2. Portal spot-checks: `MOOR322/205Z` (property 16735) visible in Haven property list; dashboard totalProperties ≈ 1,201; a sample reopened job visible.
3. **T+48–72h re-check** (after ≥1 sweep-cron pass): Haven status-11 count still 0; no new rows in `tbl_property_review`. (I'll re-query; can set a reminder.)
4. Delete both clone instances (`--skip-final-snapshot`); keep CSV extracts + pre-change dumps in `backups/incident-20260604/`.

### Rollback

Each phase is independently reversible from the Phase-0 `mysqldump` pre-images (restore by re-applying dumped rows). No schema changes, no deletes anywhere in the plan.

## Out of scope / follow-ups (not executed now)

- Comms to Haven/contractors — user handles separately (affected-job list available from Phase 0 extracts on request).
- Product bugs to raise with SensorGlobal later: silent full-snapshot reconcile on partial CSV, swallowed `changeSimStatus` errors, SES-throttle aborting import finalize (stuck status 0), no prior-status bookkeeping on job close.
- Process rule (already in memory): never partial-CSV property import for an agency with existing stock.
- `tbl_admins.autoDeactivation` for 37413 left as-is (Haven's quarterly full imports rely on reconcile being intended behaviour; turning it off only reroutes via the same 48h sweep).
