# Plan: Installer adds loose (unpaired) devices on-site to an ATTACHED kit

## Goal
While on-site, an installer adds extra LOOSE spare devices (e.g. water-leak
detectors) to a kit that is already ATTACHED to a property/job. The new device is
bonded fresh to the installed hub (firmware CMD:ADD), becomes a full KitDevice row
on the SAME kit flagged `addedOnSite`, counts toward the child limit (default 7),
and must pass the on-site test before the kit can be completed.

---

## CRITICAL DECISION: which Sensor primitive + which token (verify before coding)

The prompt names admin `PUT /api/v1/alarms/add-alarm` (AlarmsController.addAlarmOnProperty).
Verified against the Sensor backend, that route is gated by `Middlewares.Auth.AdminAuth`
(sensor-alarm-backend/src/routes/v1/alarms.routes.ts:184-185), and AdminAuth REJECTS
any token whose userType is not SUPER_ADMIN/SUB_ADMIN
(src/middlewares/auth.ts:103-112 → 423). safer-ops's per-request token is the
OPERATOR's own SSO-exchanged token (operator-token.ts getOperatorSensorToken), i.e.
an agency/agent/trade-person token for an installer — which AdminAuth will reject.
So `add-alarm` only works on a SUB_ADMIN service token, NOT the on-site installer.

There is a user-tree alternative that DOES run on the installer token (AdminUserAuth):
`POST /api/v1/users/alarms` → AlarmsController(users).installationJob, existing-hub
branch (controllerId set, no controllerData). Verified:
- route: src/routes/users/v1/alarm.routes.ts:40-88, AdminUserAuth.
- body (Joi): jobId (req), propertyId (req), controllerId (the installed hub's
  Sensor device id), alarmsData[] ({ alarmType, serialNumber, location?, ... }).
- entity: src/entities/alarms.entity.ts installationJob, existing-hub branch
  (createsAlarms row connectedStatus=IN_PROGRESS for a fresh serial, then
  controller fires `{CMD:ADD,ALARMSERIAL:...}` per child; a 10s timer marks an
  unresponsive child FAILED + push-notifies). This is exactly "bond a loose
  device to the installed hub".

### Recommendation
Use the **installer-token path `POST /users/alarms` (installationJob existing-hub
branch)** because:
1. It authenticates with the on-site installer's own token (consistent with
   testKit/completeKit/attach using `userToken` for Sensor audit attribution).
2. It sets jobId + propertyId explicitly (add-alarm only inherits propertyId from
   the hub and never stamps jobId — our completion/test reads are job/property
   scoped, and `addNewProductsInJob` keeps the job's product manifest correct).
3. The on-site Test + status-by-serial reads already authorize the assigned
   installer for their job's property (users/alarm.controller assignedInstallerJobIds
   path), so the poll works on the same token with no new permission.

If product/ops insists on the admin `add-alarm` primitive, the call must run on
the SUB_ADMIN service token (a separate token provider, NOT the operator token),
and we must separately stamp jobId on the new row / job manifest — extra work and
weaker audit attribution. PROCEED WITH THE INSTALLER-TOKEN PATH unless told
otherwise. (Surface this to the user before implementation.)

Poll: reuse the existing status-by-serial primitive WITH propertyId
(sensor-client.getAlarmStatuses currently omits propertyId — see step 1) until the
new serial reports connectedStatus="1" (CONNECTED) + indexNumber. ALARM connection
codes: "1"=CONNECTED, "3"=IN_PROGRESS, "4"=FAILED (sensor-client comment + entity).

---

## Order of changes

1. schema.prisma — add KitDevice.addedOnSite
2. shared types — KitDevice.addedOnSite + request/response DTO
3. sensor-client.ts (+ fake) — addInstalledDevice + propertyId-aware status poll
4. kits.ts — addKitDeviceOnSite + refreshAddKitDeviceOnSite + completion gating
5. kit-routes.ts — POST /onsite + /devices/:deviceId/onsite-refresh
6. frontend — KitDetailPanel add UI + poll
7. tests

---

## 1. schema.prisma (apps/api/prisma/schema.prisma, model KitDevice ~line 71)

Add:
```
addedOnSite Boolean @default(false) @map("added_on_site")
```
Migration note: new nullable-with-default column; back-fills false for existing
rows (depot-paired devices). `prisma migrate dev --name kit_device_added_on_site`
(do NOT run in plan mode). No index needed (always read via the kit include).

Confirmed existing KitDevice fields reused as-is: type, serialNumber,
serialNormalized (UNIQUE), sensorDeviceId, sensorPropertyId, sensorSnapshot,
checkStatus, connectionStatus, testStatus, hubIndex, batteryStatus,
lastResponseAt, lastMqttResponse, lastCheckedAt.

---

## 2. Shared types (packages/shared/src/index.ts)

- `interface KitDevice` (line 223): add `addedOnSite: boolean;`.
- New DTOs near KitDetail:
  ```
  export interface AddKitDeviceOnSiteRequest { serialNumber: string; type?: KitDeviceType; location?: string; }
  // response reuses { data: KitDetail }
  ```
- KitCounts (line 239) needs NO new field — added devices are real KitDevice rows
  of their type, so countKitDeviceTypes already counts them in `children`/per-type
  and the existing `childLimit` applies. (Optional: an `addedOnSite` count for UI;
  not required.)
- mapKit in kits.ts (line 1302) must add `addedOnSite: device.addedOnSite` to the
  mapped device object.

---

## 3. sensor-client.ts (apps/api/src/sensor-client.ts)

### 3a. New write method `addInstalledDevice`
Mirror the shape/logging of pairStockKit (line 467) and testInstalledKit (866).
```
async addInstalledDevice(
  input: { hubDeviceId: string; propertyId: string; jobId: string;
           serialNumber: string; alarmType?: number; location?: string },
  options?: WriteOptions
): Promise<{ ok: true }> {
  this.assertWriteAllowed();
  const body = {
    controllerId: numericSensorId(input.hubDeviceId, "controller"?),  // hub sensorDeviceId
    propertyId: numericSensorId(input.propertyId, "property"),
    jobId: numericSensorId(input.jobId, "job"),
    alarmsData: [{ serialNumber: input.serialNumber,
                   ...(input.alarmType ? { alarmType: input.alarmType } : {}),
                   ...(input.location ? { location: input.location } : {}),
                   actionType: ... NEW_INSTALLED }]
  };
  await this.postJson("/users/alarms", body, options?.userToken);
  return { ok: true };
}
```
Notes:
- POST /users/alarms (NOT /admins, NOT add-alarm). baseUrl already carries /api/v1.
- controllerId = the installed hub's Sensor device id (kit.hub.sensorDeviceId,
  captured at attach). numericSensorId currently only allows "job"|"property" —
  extend its label union to include "controller" (or inline-validate).
- alarmType: Sensor's Joi validates `alarmType` against ALARM_TYPE enum and is
  optional in installationJob's create (entity derives alarmType from
  getAlarmDetail by serial). SAFEST: omit alarmType and let the backend derive it
  from the serial. Keep the param optional for future use.
- Traceability (CLAUDE.md): the centralized requestJson already logs
  method/path/status/ms + correlationId. Caller (kits.ts) logs START/RESULT/ERROR
  with the serial (not counts) — see step 4.
- Error handling: a duplicate/already-installed serial returns Sensor 402
  ALARM_ALREADY_INSTALLED_ON_PROPERTY (entity:856) — surfaces as SensorClientError
  statusCode 402; kits.ts maps it (idempotency/ADD-STATUS-2 gotcha, step 9).

### 3b. Make the status poll propertyId-aware (reuse, don't duplicate)
`getAlarmStatuses` (line 537) currently calls status-by-serial WITHOUT propertyId,
so it only returns STOCK rows — an INSTALLED freshly-bonded child would be
invisible. Add an optional propertyId param:
```
async getAlarmStatuses(serialNumbers: string[], propertyId?: string): Promise<...same map...> {
  ...
  const params = new URLSearchParams({ serials: serialNumbers.join(",") });
  if (propertyId) params.set("propertyId", propertyId);
  ...
}
```
This is the same primitive getAlarmTestStatuses already uses with propertyId
(line 560), and the backend authorizes the assigned installer for their job's
property (users/alarm.controller assignedInstallerJobIds, verified). Existing
pair-refresh callers pass no propertyId → unchanged behaviour. The new on-site
refresh passes kit.propertyId. The returned map already carries connectedStatus,
controllerId, hubIndex, battery — exactly what we persist.

### 3c. FakeSensorClient (apps/api/src/sensor-client-fake.ts)
- Add `addInstalledDevice` recording calls (like pairStockCalls) returning {ok:true};
  add an `failAddInstalledSerials`/`alreadyInstalledSerials` set to script the 402
  duplicate path and a `pendingAddSerials` set to script a not-yet-CONNECTED poll.
- Update getAlarmStatuses signature to accept optional propertyId (ignore value;
  keep pending/otherHub behaviour). Add the new serial to the "connected to
  mock-hub" default so the happy-path poll resolves.

---

## 4. kits.ts (apps/api/src/kits.ts)

### 4a. `addKitDeviceOnSite`
New exported function modelled on addKitDevice (317) + attachKit (799).
```
export async function addKitDeviceOnSite(
  sensorClient, input: { kitId; serialNumber; type?; location? }, userToken?, logger?
): Promise<KitDetail>
```
Steps:
1. `const kit = await requireEditableKit(kitId)` (rejects assigned/archived 409).
2. Guard status: MUST be `attached` (capability only when hub installed,
   property+job known, before complete). Reject otherwise:
   `if (kit.status !== "attached") throw new KitError("kit_not_attached", "Attach the kit first", 409)`.
   (Decision: allow ONLY `attached`. NOT `testing`/`tested` — adding mid/after test
   would un-gate completion in confusing ways; the installer adds before testing.
   If product wants add-after-partial-test, extend to include `testing`/`tested`
   and reset the kit to `attached`/`testing` afterward. Default: attached-only.)
3. Require `kit.propertyId && kit.jobId` (else reservation_incomplete 409).
4. `const hub = kit.devices.find(d => d.type === "hub")`; require hub +
   `hub.sensorDeviceId` (we need the installed hub's Sensor id for controllerId).
   If missing → KitError("hub_not_installed", ...).
5. Serial + type: reuse addKitDevice logic — trim, normalizeSerial, infer type via
   kitDeviceTypeFromSerial when not given (reject unrecognized_serial).
6. `enforceLimit(kit, type)` — reuses validateNewKitDevice + config.kitChildDeviceLimit;
   counts INCLUDE all pre-existing kit devices (depot + previously added on-site)
   because it counts kit.devices. A hub add is rejected (hub_exists) — only
   children addable on-site (good).
7. `await enforceGlobalSerial(serialNormalized, kitId)` — same-kit duplicate →
   serial_exists (idempotency: a re-submit of an already-added serial 409s here,
   see step 9); other-kit → serial_in_other_kit.
8. `lookupSerial(sensorClient, type, serialNumber, logger)` + `checkStatus(...)`
   for the snapshot (reuse helpers). START log:
   `logger.info({operation:"kits.devices.onsite.add", kitId, type, serial, propertyId}, "on-site add device")`.
9. Create the KitDevice row:
   ```
   addedOnSite: true,
   connectionStatus: "pending",         // bonding not yet confirmed
   offsiteTestStatus: "passed",         // never bench-tested; not gating on-site (see gating note)
   testStatus: "pending",               // MUST pass on-site test before complete
   checkStatus: status, sensorDeviceId/sensorPropertyId/sensorSnapshot from lookup,
   hubIndex: null, batteryStatus: null, lastMqttResponse: {}, lastCheckedAt: now
   ```
   Decision on offsiteTestStatus: a loose device is never bench-tested. Set it
   `passed` so the off-site gate (which only runs at depot, before attach) is never
   tripped by an on-site device. The REAL gate for an added device is testStatus
   (on-site), enforced at complete (4c). DO NOT use resetKitWorkflow (it wipes the
   whole kit back to draft/pending and clears property/job — catastrophic here).
10. Fire the bond (controlled-write only — guard like other Sensor writes; in
    mock the FakeSensorClient handles it):
    ```
    try {
      await sensorClient.addInstalledDevice(
        { hubDeviceId: hub.sensorDeviceId, propertyId: kit.propertyId, jobId: kit.jobId,
          serialNumber, location: input.location }, userToken ? {userToken} : undefined);
    } catch (error) {
      // Roll back the just-created row so a failed bond doesn't leave a phantom
      // device counting toward the limit / blocking complete. Log warn with serial.
      await prisma.kitDevice.deleteMany({ where: { id: created.id, kitId } });
      logger?.warn({operation:"kits.devices.onsite.add.bond_failed", kitId, serial, err:error}, "on-site bond failed");
      throw error;  // sendKitError maps SensorClientError (402 dup, etc.)
    }
    ```
    EXCEPTION: a Sensor 402 ALARM_ALREADY_INSTALLED_ON_PROPERTY means the firmware
    already has this serial bonded (the ADD-STATUS-2 gotcha). Treat as success —
    keep the row (do NOT delete), since it IS on the hub; the poll will confirm it
    CONNECTED. (See step 9 gotchas.) Detect via SensorClientError statusCode===402.
11. Stamp connectionStatus stays "pending"; the kit stays `attached` (no kit-level
    state change — adding a child doesn't change the kit's workflow stage). RESULT
    log: `kits.devices.onsite.add.result` with serial + checkStatus + sensorDeviceId.
12. `return (await getKit(kitId)) as KitDetail`.

NO kit state transition: kit stays `attached`. The new row's connectionStatus
"pending" + testStatus "pending" drives the UI poll + re-gates complete.

### 4b. `refreshAddKitDeviceOnSite` (poll bonding → CONNECTED)
Modelled on refreshPairKit (599) but scoped to ONE device and property-scoped.
```
export async function refreshAddKitDeviceOnSite(
  sensorClient, kitId, deviceId, userToken?, logger?
): Promise<KitDetail>
```
1. requireEditableKit; find device by id (404 device_not_found); ensure
   device.addedOnSite && device.connectionStatus === "pending" (else return kit
   unchanged — nothing to poll).
2. require kit.propertyId.
3. Window: add `const ONSITE_BOND_WINDOW_MS = 3 * 60 * 1000;` (mirror ATTACH_WINDOW
   /pair window). Use device.createdAt (or lastResponseAt) as the anchor; on a
   kitDevice you have createdAt — read it via the kit include. windowElapsed when
   now - createdAt > window.
4. Read status: `await sensorClient.getAlarmStatuses([device.serialNumber], kit.propertyId)`
   in try/catch (transient read failure → warn + return kit unchanged; CLAUDE.md
   no-silent-catch).
5. Resolve: connectedStatus "1" → passed (persist hubIndex + batteryStatus +
   lastResponseAt + connectionStatus="passed"); "4" → failed; else if windowElapsed
   → failed (definitive); else stay pending. (Reuse the connection-code semantics
   from resolvePairChildStatus — but here we DON'T have a controllerId stash; the
   add went to a known installed hub, so accept connected-anywhere, or compare to
   hub.sensorDeviceId via the row's controllerId.)
6. RESULT log `kits.devices.onsite.add.refresh` with serial + verdict + windowElapsed.
7. Persist via updateMany on {kitId, serialNormalized}. Kit-level status unchanged.
8. return getKit.

Failure recovery: a `failed` added device — the installer can remove it. NOTE
removeKitDevice (365) is depot-only today and calls resetKitWorkflow for a non-
pairing kit (would nuke the attached kit). For on-site removal of a failed added
device, EITHER (a) add a narrow installer-allowed delete that only removes an
addedOnSite row with connectionStatus!="passed" and does NOT resetKitWorkflow (it
should releaseStockKit/REMOVE the binding if any then delete just the row), OR (b)
defer removal to depot recovery. Recommend (a) as a follow-up route
`DELETE /api/kits/:id/devices/:deviceId/onsite`; mark as optional in this plan.

### 4c. Completion gating (where to extend)
`enforceReadyForComplete` (line 1462) already requires
`kit.devices.every(d => d.testStatus === "passed")` and kit.status === "tested".
Because an added device is a real KitDevice row with testStatus default "pending",
it AUTOMATICALLY blocks complete until it passes the on-site test. NO change needed
to enforceReadyForComplete — VERIFY this is the exact check (it is).

BUT verify the on-site Test path covers the added device:
- testKit (1063) tests ALL children: `children = kit.devices.filter(type!="hub")`
  and fires test-alarm by propertyId; the added device (installed on the property)
  is included in the per-serial poll → gets a real testStatus. Good.
- enforceReadyForTest (1450) requires every device connectionStatus === "passed".
  So the added device MUST reach connectionStatus "passed" (via the bond poll 4b)
  BEFORE the installer can (re-)fire Test. This is the correct ordering: add →
  bond confirmed → test → complete. A still-pending/failed added device blocks both
  Test and Complete. Confirm enforceReadyForTest allows status `attached` (it does)
  — the installer adds while `attached`, bonds, then runs Test.
- Edge: kit already `tested` when installer adds → with attached-only guard (4a
  step 2) this is disallowed; the installer must add BEFORE testing. If product
  wants add-after-tested, then on add we must demote kit.status back to `attached`
  (so the new device can be connection-confirmed + tested) — call out as variant.

### 4d. mapKit (1302): add `addedOnSite: device.addedOnSite`.

---

## 5. kit-routes.ts (apps/api/src/kit-routes.ts)

### 5a. Schema
```
const addKitDeviceOnSiteSchema = z.object({
  type: z.string().refine(isKitDeviceType).optional(),
  serialNumber: z.string().trim().min(1).max(120),
  location: z.string().trim().max(120).optional()
});
```

### 5b. POST /api/kits/:kitId/devices/onsite — installer ownerAllowed
Dedicated handler (like /attach) because installer authz here is OWNERSHIP (the
kit is attached → already carries serviceStaffId=owner), NOT the pool-claim rule,
and it takes a body. Pattern: copy the /attach handler's persona block but use
installerOwnsKit only (no isClaimablePoolKit — an attached kit is owned):
```
app.post("/api/kits/:kitId/devices/onsite", async (request, reply) => {
  const user = await requireUser(request, reply); if (!user) return;
  const kitId = ...params.kitId;
  const parsed = addKitDeviceOnSiteSchema.safeParse(request.body);
  if (!parsed.success) return reply.code(400).send({ error: "invalid_kit_device" });
  if (user.persona !== "depot") {
    const owned = await getKit(kitId);
    if (!owned || !installerOwnsKit(user, owned)) return reply.code(404).send({ error: "kit_not_found" });
  }
  request.log.info({ operation:"kits.devices.onsite.add", actorId:user.id, persona:user.persona, kitId, type:parsed.data.type }, "kit on-site device add");
  try {
    return { data: await addKitDeviceOnSite(makeSensorClient(request), { kitId, ...parsed.data }, undefined, request.log) };
  } catch (error) { return sendKitError(reply, error); }
});
```
Token: makeSensorClient(request) already binds the operator token via tokenProvider;
addKitDeviceOnSite passes userToken=undefined → SensorClient uses the operator
token (the installer's) for the POST. (Same as testKit's runKitAction call passing
undefined; the per-request client IS the operator's.) Verify: makeSensorClient
wires tokenProvider=getOperatorSensorToken, so the default token is the installer's
own — satisfying AdminUserAuth for /users/alarms.

NOTE: do NOT route this through the depot-only addKitDevice handler at
POST /api/kits/:kitId/devices (line 257, requireDepot). Keep them distinct.

### 5c. POST /api/kits/:kitId/devices/:deviceId/onsite-refresh — ownerAllowed
Cannot use runKitAction (it only passes kitId). Write a dedicated handler with the
same persona/ownership block as 5b, calling refreshAddKitDeviceOnSite(client,
kitId, deviceId, undefined, request.log). START log
`kits.devices.onsite.add_refresh`; errors via sendKitError.

sendKitError (460) already logs warn/error with code/statusCode/kitId/path — no
new mapper needed; it also maps SensorClientError (402 duplicate) to its real
status.

---

## 6. Frontend (apps/web/src/views/KitDetailPanel.tsx; InstallerView passes persona="installer")

Current: the "Add device" block (lines 396-421) is gated `{!isInstaller && ...}`
and DeviceList passes `hideRemove={isInstaller}`.

Add an installer-only on-site add block:
- Visibility: `const canAddOnSite = isInstaller && kit.status === "attached" && !!kit.propertyId;`
  (matches product rule: installer + attached + property set, before complete).
- A separate trigger/form (reuse the serial input + CameraScanner pattern at
  lines 402-418; existing `serialNumber`/`scannerTarget` state already present).
- Mutation:
  ```
  const addDeviceOnSite = useMutation({
    mutationFn: () => apiPost<{ data: KitDetail }>(`/api/kits/${kit.id}/devices/onsite`, { serialNumber }),
    onSuccess: () => { setSerialNumber(""); refresh(); toast.success("Device added — bonding…"); }
  });
  ```
  refresh() invalidates ["kit", id] + ["kits"]; also invalidate ["kits-by-job"] so
  the installer job panel reflects the new device.
- Poll the bond: add an effect mirroring the test/attach poll guards (useRef
  overlap guard). Poll while any addedOnSite device has connectionStatus==="pending":
  ```
  const onsiteBonding = kit.devices.some(d => d.addedOnSite && d.connectionStatus === "pending");
  ```
  Each tick: for each such device call
  `apiPost('/api/kits/${kit.id}/devices/${device.id}/onsite-refresh')` then refresh().
  (Simplest: one mutation that loops the pending added devices; or poll only the
  first pending one per tick.) Stop when none pending. Match the 3-4s interval +
  in-flight ref used by testRefresh/attachRefresh (lines 164-203).
- Optimistic row: not strictly needed — the POST returns the updated KitDetail with
  the new pending row; refresh() renders it. Show its bonding state via the existing
  per-device status rendering in DeviceList (extend DeviceList to show a "bonding…"
  / "added on-site" badge keyed off device.addedOnSite + connectionStatus).
- After bond → connectionStatus "passed", it flows into the EXISTING on-site Test
  UI (the installer's Test action already tests all children; the added device is
  now included and must pass before Complete is enabled). No new test wiring.
- DeviceList (find component) — add an `addedOnSite` badge; keep hideRemove for
  installers EXCEPT optionally allow removing a failed addedOnSite device if 4b(a)
  is implemented.

InstallerView.tsx: no change required beyond already passing persona="installer"
(line 252). Optionally surface a hint in the On-site explainer that spares can be
added.

---

## 7. Tests

### apps/api/src/kit-rules.test.ts
- validateNewKitDevice already covers device_limit; add a case asserting the limit
  math counts pre-existing devices (e.g. counts.children = childLimit → "device_limit"
  for a new child) — confirms an on-site add respects the limit incl. depot devices.

### apps/api/src/sensor-client.test.ts
- addInstalledDevice: assert it POSTs /users/alarms with controllerId/propertyId/
  jobId/alarmsData (scripted fetch queue like the attach tests at line 33+); assert
  it uses the operator token (no admin path).
- getAlarmStatuses with propertyId: assert the propertyId query param is sent.
- 402 duplicate → SensorClientError statusCode 402 surfaced.

### apps/api/src/kits.test.ts (domain)
Using FakeSensorClient + a kit driven to `attached` (reuse the happy-path setup in
kit-routes.test.ts: addDevice hub+children → pair → offsite-test → attach → poll).
- happy path: addKitDeviceOnSite creates an addedOnSite row connectionStatus
  pending; refreshAddKitDeviceOnSite → passed (fake returns connected); kit stays
  attached; the new row testStatus pending blocks complete; after testKit it passes;
  complete succeeds.
- child-limit exceeded: fill to childLimit, add one more → KitError device_limit 409.
- duplicate serial (same kit) → serial_exists; (other kit) → serial_in_other_kit.
- wrong status: addKitDeviceOnSite on a draft/ready/tested/completed kit → 409.
- bond failure rolls back the row (FakeSensorClient.failAddInstalledSerials) — the
  kit has no phantom device afterward.
- 402 already-installed: keep the row (no rollback), poll confirms CONNECTED.
- bonding timeout: pendingAddSerials + advance the window → refresh marks failed;
  complete stays blocked.

### apps/api/src/kit-routes.test.ts (HTTP + authz)
- installer (owner) can POST /devices/onsite on their attached kit; non-owner
  installer → 404; depot → allowed.
- POST when kit not attached → 409 kit_not_attached.
- onsite-refresh route authz mirrors (owner/depot ok, foreign 404).
- Add an installer login helper if not present (kit-ownership.test.ts shows the
  installer identity shape; kit-routes.test.ts currently logs in via `login` —
  check whether a persona=installer session helper exists, add one if needed).

### apps/api/src/sensor-client-fake.ts
- Implement addInstalledDevice + scripting sets; update getAlarmStatuses signature.

---

## 8. Edge cases & gotchas (must handle)

- ADD STATUS 2 / "already exists" (firmware already bonded): Sensor returns 402
  ALARM_ALREADY_INSTALLED_ON_PROPERTY (entity addAlarmOnProperty:1617-1622 and the
  installationJob create path's ALARM_ALREADY_INSTALLED_ON_PROPERTY:856). Treat 402
  on add as success — the device IS on the hub; keep the local row and let the poll
  confirm CONNECTED. Do NOT roll back on 402. Log warn with serial.
- Bonding timeout / no CONNECTED: ONSITE_BOND_WINDOW_MS in refresh → mark the row
  connectionStatus failed (definitive), surface in UI, offer remove/retry. Don't
  poll forever (CLAUDE.md: definitive verdict).
- Offline hub: addInstalledDevice still creates the Sensor row + queues CMD:ADD; the
  child never reports → poll times out → failed. Same recovery path. The START/
  RESULT/ERROR logs name the serial so the field failure is diagnosable.
- Child-limit math: enforceLimit counts ALL kit.devices (depot + prior on-site),
  so the default-7 cap includes pre-existing devices. Hub add is rejected.
- Idempotency on re-submit of the same serial: enforceGlobalSerial throws
  serial_exists (same kit) BEFORE any Sensor call — a double-tap can't double-bond.
  If the row exists but is still pending, the UI should poll, not re-add. Consider
  returning the existing kit (idempotent 200) instead of 409 when the same serial is
  re-submitted and its row is still pending — OPTIONAL nicety; default is 409.
- Token mismatch (the central decision): if the implementation accidentally calls
  admin add-alarm on the operator (installer) token it 423s. Tests must assert the
  /users/alarms path. If using a service token instead, jobId stamping must be done
  explicitly.
- Do NOT call resetKitWorkflow anywhere in the add path — it would clear
  property/job/owner and reset every device to pending, destroying the attached
  install. Use targeted prisma.kitDevice.create / updateMany only.
- mapKit must include addedOnSite or the frontend can't gate the badge/poll.

---

## Critical files for implementation
- /home/yevgen/dev/sensorsyn/code/safer-ops/apps/api/src/kits.ts
- /home/yevgen/dev/sensorsyn/code/safer-ops/apps/api/src/sensor-client.ts
- /home/yevgen/dev/sensorsyn/code/safer-ops/apps/api/src/kit-routes.ts
- /home/yevgen/dev/sensorsyn/code/safer-ops/apps/api/prisma/schema.prisma
- /home/yevgen/dev/sensorsyn/code/safer-ops/apps/web/src/views/KitDetailPanel.tsx
