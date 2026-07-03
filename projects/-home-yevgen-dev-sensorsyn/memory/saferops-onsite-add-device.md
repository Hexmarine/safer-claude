---
name: saferops-onsite-add-device
description: "safer-ops on-site add-device feature — installer bonds loose extra devices to an attached kit's hub; the API-path + gating gotchas"
metadata: 
  node_type: memory
  type: project
  originSessionId: e097111e-3354-4441-a46c-63f64ec949b7
---

Built (2026-06-07) in code/safer-ops: an installer can add loose extra devices
(e.g. more water-leak detectors) to a kit **after attach**, bonding them to the
already-installed hub on-site. They become full KitDevice rows (`addedOnSite`),
count toward the child limit, and must pass the on-site test before complete.

Key non-obvious decisions (cross-layer):
- **Sensor API path = `POST /users/alarms`** (installationJob existing-hub branch,
  installer/AdminUserAuth token), NOT admin `PUT /api/v1/alarms/add-alarm`. The
  admin route's `AdminAuth` rejects any non-SUPER/SUB_ADMIN token (423), and
  safer-ops carries the operator's own SSO token. With `controllerId` set (the
  hub's Sensor device id), the controller fires `{CMD:ADD}` to the installed hub +
  arms a 10s failAddAlarm timer; the global MQTT ADD handler flips the row
  IN_PROGRESS→CONNECTED. Poll `getAlarmStatuses(serials, propertyId)` (status-by-
  serial WITH propertyId = installed read) to confirm.
- **No new completion gating needed**: `enforceReadyForTest`/`enforceReadyForComplete`
  (kits.ts) already require every device connection/test status passed, so a
  pending added device blocks test→complete automatically.
- Added device created with `offsiteTestStatus: "passed"` (skips the bench gate it
  never had) but `connectionStatus/testStatus: "pending"`.
- **Re-bond after timeout**: the bond window anchors on `lastCheckedAt` (reset on
  re-scan), NOT `createdAt` — else a retry of a failed row times out instantly.
  (codex caught this.)
- Code: `addKitDeviceOnSite`/`refreshAddKitDeviceOnSite` (kits.ts),
  `addInstalledDevice` (sensor-client.ts), routes `POST /api/kits/:id/devices/onsite`
  + `/devices/:deviceId/onsite-refresh`, UI in KitDetailPanel On-site panel.

## Hub liveness in the prep view (same session)

Added a hub connectivity indicator distinct from the pairing `connectionStatus`
chip: **passive** `GET /api/kits/:id/hub-status` (reads Sensor `connectedStatus`
via `getAlarmStatuses([hubSerial])`, stock-scoped) + **active** `POST .../hub-status/probe`
(fires a VERIFY via `verifyStockKit({devices:[]})` — harmless, always cancels the
op). Key facts learned:
- A hub's `connectedStatus` is updated by VERIFY/ADD/RECONNECT/DISCONNECT handshakes,
  NOT raw MQTT broker presence — passive reads can be stale; the VERIFY probe is the
  real-time signal. An unallocated hub may have no tbl_alarms row (→ unknown).
- The active probe is authoritative: no-answer ⇒ `offline` (do NOT fall back to the
  stale passive status). Probe gated to draft/connected/ready/offsite_tested (avoid
  colliding with a live pair/attach op) and to write-mode (it's a Sensor write).
- The "Not connected" pairing chip is suppressed on the hub in `draft` (misleading
  when the hub is online); children's chips say "Paired/Not paired" everywhere
  (PairingBoard + Devices tab), hubs say "Connected".

Codex caught (and these are fixed): 402-on-add must verify it's on THIS property
before keeping the row (else owned-elsewhere strands the kit) + normalise the kept
row's `checkStatus` off "assigned"; probe must report offline on timeout despite a
stale passive "1"; Devices-tab relabel must preserve "Removed" (not collapse to
"Not paired").

## Installer token can't call agency-scoped reads (403)

An installer's Sensor token is rejected (403) by **agency/admin-scoped list reads** —
notably `GET /users/alarms/list?listType=controller&search=<serial>` (the hub
inventory lookup behind `findDeviceBySerial`/`getHub`/`detachHub`'s TOCTOU re-verify).
What DOES work for an installer: property-scoped `status-by-serial?...&propertyId=`
(the backend authorizes the assigned installer for their job's property) and
`remove-controller` (enforces no ownership). So any installer-reachable flow must
avoid the controller list:
- MQTT diagnostics for installers → scoped to their kit's hub via `getKitByHubSerial`
  + `installerOwnsKit` (mqtt-monitor-routes), drawer locked to that hub.
- Abort install (`recoverKit`) → use `detachHubByDeviceId(hub.sensorDeviceId,…)`
  (straight to remove-controller), NOT `detachHub` (whose list re-verify 403s the
  installer). Caught on-site 2026-06-08; regression-guarded in kit-routes.test.

## Abort install = revert kit to the ready pool (2026-06-08)

Installer "Abort install" (recoverKit) on an INSTALLED kit (attached/testing/tested)
no longer tears down to `draft`. New flow: **unallocate** (keep pairing) → **stock
VERIFY** → return to the **open ready pool** (`offsite_tested`, unowned, devices
passed, testStatus pending) so the installer can re-attach + redo. If re-verify
mismatches (pairing didn't survive), fall back to **stock RESET** (resetStockController,
NOT remove-controller — the hub is stock post-unallocate; remove-controller would
deref a null property) → draft.
- **NEW prod Sensor backend op**: `unallocateController` + `PUT /users/alarms/unallocate-controller`
  (sensor-alarm-backend) — a non-destructive twin of `removeController`: nulls hub+children
  property/job but keeps children ACTIVE+CONNECTED+indexNumber, NO firmware RESET, leaves
  SIM active, clears addNotificationSent, scopes job cleanup to `controller.jobId` (not all
  property jobs), no `removedSerialNumbers` bump (so same-job redo re-adds products).
  Firmware pairing is sticky (only RESET clears it) → skipping RESET genuinely preserves it;
  after unallocate the children match the re-attach adopt precondition exactly.
- safer-ops: `sensorClient.unallocateHub`, `recoverKit` rewire, `returnKitToPool` helper.
- NOTE: this is a TWO-repo change incl. the prod product backend → needs sign-off; the
  sensor-alarm-backend working tree also had UNRELATED JWT-key-rotation WIP (auth.ts/
  TokenManager/sso.key) — commit the unallocate change separately.

Related: [[prepared-kit-backend-internals-doc]], [[prepared-kit-fungible-pool-pivot]],
[[sensor-write-auth-agency-token]], [[traceability-rule-saferops]], [[codex-review-finishing-step]],
[[codex-stop-on-low-value]].
