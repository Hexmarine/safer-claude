---
name: stranded-device-detach-recovery
description: "How an installed hub gets stranded (often out of the operator's read scope), why serial-based detach / Reset / Abort-install can't recover it, and the in-app 'Return hub to stock' (detachHubByDeviceId) + remove-controller recipe that does"
metadata: 
  node_type: memory
  type: project
  originSessionId: 37a45498-e9ae-422d-b657-dcf4449c5278
---

Live-hardware finding (2026-05-26 bench run): a failed on-site Test followed by **closing the job in the Sensor portal** strands the kit. The hub stays installed (`tbl_alarms.propertyId` + `jobId` set, child CONNECTED), so safer-ops **Reset/Pair → 409 `hub_not_stock`** and **Complete → 409** (kit never reached `tested`). The installer has no in-app way out — see tasks #70 (flow re-eval, no dead-ends) and #71 (in-app detach in safer-ops).

Why Test hung: Sensor `testAlarm` (`alarms.controller.ts:360`) fires `{"CMD":"VERIFY"}` immediately then **unconditionally** `{"CMD":"TEST"}` 5s later (setTimeout, not gated on the VERIFY reply) and sets the child `testStatus=INPROGRESS`. If the hub goes silent (no TEST response on `sg/sas/resp`), testStatus stays INPROGRESS → our poll reports `pending` until the window expires. Not a backend bug; the hub stopped answering (watch the bench hub power — VERIFY responses showed `BATTERY:0`).

**Detach/recovery recipe (returns an installed hub to stock):** `PUT /users/alarms/remove-controller` (note `/alarms/`) body `{"Id": <hub tbl_alarms.id>}` (the hub row, not the child), base `https://api.sensorglobal.com/api/v1`, header `access_token: bearer <jwt>`, content-type `application/json`. It detaches the hub (propertyId/jobId NULL, status ACTIVE, conn REMOVED), **soft-deletes all children where `controllerId=<hubId>`**, sets the property DISCONNECTED, fires `{"CMD":"RESET"}` to clear the **firmware ALARMS roster** (avoids the [[prepared-kit-backend-internals-doc]] ADD STATUS 2 "already exists" reuse gotcha on re-pair), and sets the SIM inactive. (The new stock-only `/reset-stock-controller` reuses that same `CMD:RESET` clean-slate but WITHOUT the SIM deactivation / property teardown — see [[prepared-kit-backend-internals-doc]].) `remove-controller` enforces **no** property ownership (alarms.controller.ts) and is null-guarded, so any token with route access detaches by id.

**In-app recovery — shipped (#80, 2026-05-27); MERGED INTO Reset 2026-05-28 (#105):** originally a separate "Return hub to stock" button (depot, Prep panel) = `detachHubByDeviceId(kit.sensor_device_id)` → remove-controller. **As of #105 the two are ONE "Reset" action** — `resetKit` now: stock kit → firmware RESET clean-slate (new `/users/alarms/reset-stock-controller`, see [[prepared-kit-backend-internals-doc]]); else → `releaseKitDevicesOnSensor(forceByDeviceId:true)` which is exactly the old Return-hub detach-by-device-id. So Reset alone now recovers an out-of-scope stranded hub; `detachKitHub` + `/api/kits/:id/detach-hub` + the 2nd web button were removed. (committed since; verified 2026-07-03.)
- **Why plain Reset / "Abort install" don't recover it:** the stranded install is usually **out of the operator's read scope** (property belongs to another agency/agent), so it's invisible to BOTH reads `detachHubBySerial` uses — the agency-scoped controller list AND `status-by-serial` (stock-only). So serial resolution returns nothing and the detach **silently no-ops** (`detached:false`, UI shows "Available"), while the hub stays installed. The fix is to detach by the **stored `sensor_device_id`** (captured at pair/attach), which needs no read.
- **`recoverKit`/"Abort install" still 404s here (task #84):** it detaches via the re-verify path (`detachHub` → `findDeviceBySerial` first → `hub_not_found`). Until #84, "Return hub to stock" is the only working recovery for an out-of-scope installed hub.

Related: [[prepared-kit-backend-internals-doc]], [[installation-flows-old-and-new]], [[installer-identity-model]].
