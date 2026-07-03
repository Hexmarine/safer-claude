# Plan: Abort install reverts the kit to stock (back to the ready pool)

## Context

When an installer hits **Abort install** on a kit whose hub is physically installed
(`attached` / `testing` / `tested`), `recoverKit` calls `remove-controller`, which is a
full decommission: it firmware-**RESET**s the hub, soft-deletes the children, deactivates
the SIM, then `resetKitWorkflow` drops the kit to **`draft`** (unpaired, unowned). The kit
vanishes for the installer and needs a full depot re-prep before it can be used again.

That kills the installer's ability to **redo** on the spot. We want abort to give them
freedom: detach the hub from the property but **keep the kit paired**, returning it to the
**open ready pool** so they (or anyone) can immediately re-attach it and try again.

Why this needs a Sensor change: there is **no non-destructive detach** today —
`remove-controller` always RESETs firmware + deletes children. Firmware pairing is
otherwise *sticky* (only RESET clears it), so a detach that skips RESET and keeps the child
rows `ACTIVE`+`CONNECTED` genuinely preserves the kit as stock-paired — exactly the state
the re-attach **adopt** path already expects (`installationJob` adopt branch: child
`propertyId NULL` + `controllerId = hub` + `ACTIVE`).

**Confirmed decisions:** return to the **open pool** (offsite_tested, unowned);
**re-verify** the roster before re-pooling; leave the SIM active (hot redo; re-attach
reactivates anyway); do **not** add children to the job's `removedSerialNumbers` (so a redo
re-adds products cleanly).

This touches the **prod product backend** (`sensor-alarm-backend`) — a bigger surface than
our safer-ops-only changes — so it should be reviewed/signed-off before shipping.

## Approach

On abort of an installed kit: **unallocate** (Sensor, keep pairing) → **re-verify** (stock
VERIFY) → **return to pool**; if re-verify fails, **fall back** to the existing destructive
teardown → `draft` (honest: pairing didn't survive → depot re-prep).

## Part A — Sensor backend: a non-destructive `unallocate-controller`

A twin of `removeController` that detaches from the property but preserves pairing. Mirror
`removeController` (controller `src/controllers/alarms.controller.ts:624-878`; route
`src/routes/users/v1/alarm.routes.ts:622-653`), **keeping** the property/job/alert/socket
cleanup but **dropping** the pairing teardown:

- **New controller method** `unallocateController({ Id }, sessionData)` (after
  `removeController`), resolved by id via `getAlarmDetail({ id, listType: "" })`:
  - **Hub row:** `propertyId=null, jobId=null, location=null, installedBy=null,
    testStatus=null`. **KEEP** `connectedStatus` (stay CONNECTED) and **do NOT** touch the
    SIM (leave active).
  - **Child rows:** `propertyId=null, jobId=null` **only**. **KEEP** `status=ACTIVE`,
    `connectedStatus=CONNECTED`, `controllerId`, `indexNumber` (the whole pairing).
  - **DROP** the firmware `{"CMD":"RESET"}` publish entirely.
  - **KEEP** the property cleanup (mark the property no longer installed:
    `alarmStatus=INACTIVE`, `status=DISCONNECTED`, clear `installedAt`/test dates), the
    alert clear (`AlarmAlerts.eventStatus=false`), and the socket count refreshes.
  - **Job:** clear the aborted install's `newProducts` + reset the job `testStatus`, but
    **do NOT** add serials to `removedSerialNumbers` (else a same-job redo skips re-adding
    products — `installationJob` honours `removedSerialNumbers`). Verify exact job-state
    handling against `removeController` during implementation.
  - Use a distinct activity-log/op tag (e.g. `unallocated`) rather than the remove log.
- **New route** `PUT /users/alarms/unallocate-controller`, Joi `{ Id: number }`,
  `Middlewares.Auth.AdminUserAuth` (ownership-agnostic like remove-controller, so the
  on-site installer can call it). Register beside `/remove-controller`.

## Part B — safer-ops wiring

- **`sensor-client.ts`**: new `unallocateHub(sensorDeviceId, options)` →
  `PUT /users/alarms/unallocate-controller { Id: numericSensorId(sensorDeviceId,"controller") }`,
  on the operator token. Traceability per CLAUDE.md (log start/result/error with the hub).
- **`kits.ts` `recoverKit`** (`~1674`) — the installed branch (`hub && hub.sensorDeviceId &&
  kit.propertyId`, currently `detachHubByDeviceId` → `resetKitWorkflow` → draft) becomes:
  1. `await sensorClient.unallocateHub(hub.sensorDeviceId, options)`.
  2. `verifyStockKit({ hubSerial, devices })` (reuse) to confirm the hub still reports its
     full roster.
  3. **matched** → `returnKitToPool(kitId)`; **mismatched/failed** →
     `detachHubByDeviceId` + `resetKitWorkflow` (draft) + `logger.warn` (pairing lost →
     depot re-prep).
  - The `attaching` (in-flight, not installed) and stock `release` branches are unchanged.
- **New `returnKitToPool(kitId)`** (sibling of `resetKitWorkflow`): kit →
  `status="offsite_tested"`, `jobId/propertyId/propertyAddress/serviceStaffId=null`,
  `attachedAt/testedAt/completedAt/assignedAt/attachOperationId=null`, `offsiteTestedAt=now`;
  devices keep `connectionStatus="passed"` + `offsiteTestStatus="passed"` (still paired+ok),
  reset `testStatus="pending"` (the on-site test is void). This lands the kit in the
  fungible pool (`listKits({pool})` = offsite_tested + no owner/property; `isClaimablePoolKit`).

## Edge cases
- **Re-verify fails** → destructive fallback to draft (above) — never silently pool a kit
  whose pairing didn't survive.
- **Re-attach round-trip** is already supported: after unallocate the children match the
  adopt branch's precondition, so attach re-adopts them with no re-pair.
- **Idempotency / partial failure**: if `unallocateHub` throws, surface the error and leave
  the kit attached (don't half-reset) — same shape as the current detach error path.
- **Depot "Reset"** (`resetKit` → draft) is unchanged; only installer **Abort install**
  (`recoverKit`) now reverts-to-pool.

## Critical files
- `code/sensor-alarm-backend/src/controllers/alarms.controller.ts` (new `unallocateController`)
- `code/sensor-alarm-backend/src/routes/users/v1/alarm.routes.ts` (new route)
- `code/safer-ops/apps/api/src/sensor-client.ts` (`unallocateHub`)
- `code/safer-ops/apps/api/src/kits.ts` (`recoverKit` rewire + `returnKitToPool`)
- `code/safer-ops/apps/api/src/sensor-client-fake.ts` (+ tests)

## Verification
- **safer-ops tests** (extend `kit-routes.test.ts` / `sensor-client.test.ts`): installed
  abort → kit `offsite_tested`, unowned, `propertyId/jobId` null, devices
  `connectionStatus="passed"` + `testStatus="pending"`; assert `unallocateHub` + stock
  VERIFY were called and the kit is visible in `GET /api/kits/ready`; re-verify-mismatch →
  draft fallback; `unallocateHub` request shape (PUT, `Id`, operator token). Run
  `pnpm --filter @safer-ops/api test`.
- **Sensor backend**: add/extend a test for `unallocateController` if the repo has a harness
  (assert children stay ACTIVE/CONNECTED, hub property/job null, NO `CMD:RESET` published).
- **E2E (prod, real hub)**: attach → test → **Abort install** → confirm the kit reappears
  in the installer's ready picker, re-attach the same kit to the same job, test, complete.
  Cross-check Sensor: hub+children `propertyId` null after abort but children still
  `ACTIVE`/`CONNECTED`; firmware NOT reset (MQTT shows no `RESET`); SIM still active.
- `codex review --uncommitted` in each repo (cross-layer + prod-backend change).
