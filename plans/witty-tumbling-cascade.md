# Plan: append-only device-event journal (`tbl_device_events`, Mongo time-series)

## Context

`tbl_alarm_logs` (Mongo) is today the only replayable record of device behaviour, but
it is **not append-only**: rows are rewritten in place by a 6-min timeout sweep, an
in-place TEST-result overwrite, location back-fills, and flapping/alert/certificate
bookkeeping flags (`timestamps:true` + a `beforeEdit` snapshot field prove this). The
same document fuses three concerns — the immutable device event, retroactively-edited
"facts", and mutable alerting workflow state — which is why it reads as noisy and can't
be trusted as a frozen record. Investigations (e.g. the Mildura Essex/Balmoral swap)
have to mentally subtract the noise and can't recover overwritten history.

We will add a **separate, append-only, insert-only** journal of decoded device frames so
that "what the device reported / what we sent it, frozen at the time" is a trivial
ordered read. The existing MySQL `tbl_device_operation_events` (the `recordEvent()`
pattern in `entities/deviceOperations.entity.ts`) already proves the append-only
discipline, but is scoped to bounded pre-paired/stock-verification operations — it does
NOT cover the unbounded device-lifetime frame stream. This journal complements it.

### Grounded decision (measured 2026-06-30, live `sensorproddb.tbl_alarm_logs`)

- 589,629 docs over a 91-day live window ≈ **6,465 docs/day** (~2.36M/yr) — **small**.
- **92.9% of all rows are VERIFY connection polls** (heartbeat command+reply cycle).
- On disk: 175.7 MB data vs **235.9 MB across 24 indexes** — index bloat, not volume, is
  the real cost today.
- Extrapolated firehose-incl-heartbeats: ~1.6 GB/yr in a 24-index collection,
  **~0.15–0.3 GB/yr in a Mongo time-series collection** (columnar bucketing crushes the
  93% near-identical VERIFY frames).

**Chosen store: a Mongo time-series collection capturing the full firehose (heartbeats
included).** Rationale: TS columnar compression makes the heartbeats nearly free while
preserving the heartbeat-*absence* signal (the cue that exposed the 3-months-dead Essex
hub); native TTL gives retention for free; append-only + fixed `metaField`/`timeField`
matches the only query shape ("this device, this window, newest-first"); and a clean
~6-index design escapes the 24-index bloat. Volume is far too small to justify a new
TSDB; MySQL was rejected because keeping heartbeats there is comparatively expensive and
the journal needs no relational joins (correlation is by serial / property /
correlationId, all carried in the doc).

## Target design

### 1. Collection — `tbl_device_events` (time-series, live `MONGO_DB` connection)

Create via `createCollection` with:
- `timeseries: { timeField: "ts", metaField: "meta", granularity: "minutes" }`
  (granularity is a tuning knob — start at `minutes`, confirm bucket efficiency with
  `collStats` after dark-launch; per-hub events are sparse-but-bursty).
- `expireAfterSeconds` = retention TTL, env-driven (`DEVICE_EVENTS_TTL_DAYS`, default e.g.
  365 — generous because TS storage is cheap; replaces the manual two-cluster archive
  split entirely).

### 2. Document shape (immutable; projected from the persisted alarm-log doc)

- `ts` (Date) — event time.
- `meta: { hubSerial, controllerId, propertyId }` — the grouping identity (TS metaField).
- `direction: "command" | "report"` — the clarity axis we lacked; derive from the frame
  (`details == null && status == PROGRESS` ⇒ outbound command, else inbound report).
- `event` / `cmd` (e.g. VERIFY/ADD/ALARMS/TEST/TAMPERED/BATTERY/POWER/REMOVE/…).
- `childSerial`, `index` (when applicable).
- `source` — `eventTriggerSource` (HUB | HEARTBEAT | PING | command | sweep).
- `outcome` / `status` — **frozen at write time** (the device's `details.STATUS` and the
  app `REPORT_STATUS`); a later timeout/correction is a NEW appended row, never a rewrite.
- `battery`, `powerState`, `rawDetails` (decoded frame verbatim).
- `correlationId` (from `utils/requestContext` when the frame originates from an API
  command), `testId`, `operationId`, `jobId` — stitch/correlation keys.
- `backfilled: Boolean` (default `false`) + `backfillBatch`, `sourceId` (original
  `tbl_alarm_logs` `_id`) — the backfill provenance indicator.
- `schemaVersion` — to evolve the projection safely.

Explicitly **excluded**: `alertSent`, `flapping*AlertSent`, `certificateCreated`,
`hideFromAlarmsLogs` and every other mutable workflow flag — those stay on
`tbl_alarm_logs`. This collection never carries processing state.

### 3. Indexes (~6, vs the 24 on the old collection)

TS auto-creates `(meta, ts)`. Add secondary indexes for the real query shapes (from the
`tbl_alarm_logs` read-site audit):
- `{ "meta.propertyId": 1, ts: -1 }` — per-property chronological (primary).
- `{ "meta.hubSerial": 1, ts: -1 }` — per-hub chronological.
- `{ childSerial: 1, ts: -1 }` — per-child chronological (measurement-field index, needs
  Mongo 6.3+; else fold child into meta).
- `{ correlationId: 1 }`, `{ testId: 1 }`, `{ operationId: 1 }` — correlation lookups.

(No unique indexes — TS constraint; idempotency handled in backfill, see below.)

### 4. Write integration — single best-effort hook

All `tbl_alarm_logs` inserts flow through two physical paths (no single entity function
sits above both): `saveAlarmLog` one-by-one (`entities/logs.entity.ts:1075`,
`new AlarmLogsModel().save()`) and the batched `insertMany`
(`entities/logs.entity.ts:3991` & `:4024`). Outbound commands also reach these via
`addMqttCommandsLogCron` → `logsEntity.add({prepareDataOnly:true})` (the batched path),
so a hook on both paths captures **both directions**.

Hook both with one file edit using mongoose post-hooks on `alarmLogsSchema`
(`models/mongo-db/alarmLogs.model.ts`, before model registration at line 96):
- `alarmLogsSchema.post("save", doc => projectAndAppend(doc))`
- `alarmLogsSchema.post("insertMany", docs => projectAndAppend(docs))`

Each hook:
- runs **after** the authoritative `tbl_alarm_logs` write,
- is **fire-and-forget + `.catch(logToConsole)`** (copy the `addMqttCommandsLogCron`
  idiom at `subscriber.ts:758`) so it can never block or break the device flow,
- is gated by a **kill-switch env flag** `DEVICE_EVENTS_ENABLED` (dark-launchable,
  instantly disable-able),
- **filters** to device events (`logType == "Action"`); comms rows (Email/Sms/Push) are
  skipped.

### 5. Backfill (with the provenance indicator)

One-off runner (new `scripts/diag/` or `scripts/migrate/` node script reusing
`CONFIG.DB.MONGO_DB.CONNECTION`; there is no existing Mongo migration runner, so this
introduces the pattern). Reads historical `tbl_alarm_logs` (live, then the
`MONGO_DB_ARCHIVED` cluster) in **`_id`-ascending batches**, projects via the same
projection function, sets `backfilled:true` + `backfillBatch` + `sourceId`, and
`insertMany`s into the TS collection.

- **Caveat to honour:** backfilled rows inherit `tbl_alarm_logs`' *already-mutated* state
  (overwritten TEST rows, sweep-stamped statuses), so backfilled data is explicitly
  "best-effort historical"; only forward (`backfilled:false`) rows are the trustworthy
  frozen record. The boundary is the Phase-2 deploy timestamp.
- **Idempotency:** TS can't enforce a unique index, so the backfill is **checkpoint-
  driven** (resume from last processed `sourceId`); never re-run overlapping `_id` ranges.
- **Order:** deploy collection + forward hook FIRST (start capturing trustworthy data),
  then backfill older history behind it.

## Rollout (each mutation gated by propose → "go"; record applied steps in `docs/applied-changes.md`)

- **Phase 0 — docs.** Short design note under `docs/` capturing this decision + the
  signal/noise taxonomy + the schema. (Safe; docs are default-allowed.)
- **Phase 1 — collection.** Pre-req: confirm Atlas ≥ 5.0 (≥6.3 for the child-serial
  index). `createCollection` with the timeseries + TTL options. New collection, reversible
  by `drop` → propose → "go".
- **Phase 2 — model + write hook (dark).** Add `models/mongo-db/deviceEvents.model.ts`,
  the projection function, and the two post-hooks, behind `DEVICE_EVENTS_ENABLED`.
  Touches the shared `alarmLogsSchema` file → **Class B Sensor change**: run
  `.claude/agents/sensor-regression-guard.md` before commit; the hook must be provably
  additive, best-effort, and behaviour-preserving on the existing alarm-log write/read.
  Deploy (golden-AMI), then enable the flag.
- **Phase 3 — verify forward capture.** Reconcile a sample window: device-frame counts in
  `tbl_alarm_logs` vs `tbl_device_events` (parity minus excluded comms). Measure
  `collStats` to confirm the ~0.2 GB/yr compression projection and bucket efficiency.
  Re-derive a known case (the Essex hub story) from the new collection to confirm clean
  command/report reconstruction.
- **Phase 4 — backfill.** Run the checkpointed backfill with the `backfilled` indicator;
  verify counts and provenance flags.
- **Phase 5 (optional) — read-time narrative tool.** Build a `scripts/diag/` reader over
  the clean collection (the per-property/per-hub chronological story with direction +
  correlation), replacing ad-hoc `tbl_alarm_logs` archaeology.

## Files

- **Create** `code/sensor-alarm-backend/src/models/mongo-db/deviceEvents.model.ts` — TS
  model on `CONFIG.DB.MONGO_DB.CONNECTION` (pattern mirrors `alarmLogs.model.ts:96`).
- **Create** the projection helper `alarmLogDoc → deviceEventDoc` (own module, e.g.
  `src/utils/deviceEvent.projection.ts`) — pure, unit-testable. *(Good Learn-by-Doing
  candidate at implementation: the `direction`/`outcome` classification rules.)*
- **Modify** `src/models/mongo-db/alarmLogs.model.ts` — add the two best-effort,
  flag-gated post-hooks before line 96. (The only edit to existing Sensor code.)
- **Create** the Mongo backfill runner under `scripts/` (+ checkpoint handling).
- **Create** `docs/` design note (Phase 0) and append applied steps to
  `docs/applied-changes.md` as each mutation lands.
- **Config:** new env `DEVICE_EVENTS_ENABLED`, `DEVICE_EVENTS_TTL_DAYS`.

## Verification

- **Reconciliation (read-only, via `scripts/diag/prod-read.py` aggregates):** for a fixed
  recent window, assert `tbl_device_events` count == `tbl_alarm_logs` Action-row count;
  spot-check that timed-out ADD/TEST appear as their own appended rows (never an overwrite)
  and that `updatedAt` semantics are gone (no doc ever mutates).
- **Storage:** `collStats` on `tbl_device_events` confirms compression and index footprint
  vs the 1.6 GB/yr / 24-index baseline.
- **Behaviour-preserving:** confirm `tbl_alarm_logs` writes/reads and all existing flows
  are unchanged with the flag on and off (regression-guard sign-off).
- **End-to-end:** reconstruct the Essex hub swap timeline purely from `tbl_device_events`
  and confirm it matches the earlier `tbl_alarm_logs` investigation, now with explicit
  command/report direction.

## Risks / open tuning items

- Touching `alarmLogsSchema` (shared Sensor model) — mitigated by post-hook-only,
  best-effort `.catch`, kill-switch flag, comms filtering, and a regression-guard pass.
- Hot-path safety — TS write is never awaited in the device flow.
- TS prerequisites — confirm Atlas version (≥5.0; ≥6.3 for measurement-field indexes)
  before Phase 1; if <6.3, fold `childSerial` into `meta`.
- `granularity` / bucketing — tune against measured bucket stats after dark-launch.
- Backfill fidelity — historical rows are explicitly best-effort (inherit prior
  mutations); only forward data is authoritative.
