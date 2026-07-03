---
name: saferops-live-trace-rig
description: How to observe a live safer-ops prod flow (logs/MQTT/DB) + the pmsi-pods naming-collision gotcha
metadata: 
  node_type: memory
  type: reference
  originSessionId: 37a45498-e9ae-422d-b657-dcf4449c5278
---

To watch a live safer-ops prod operation across layers:

- **safer-ops API logs** (our app, the primary trace): `kubectl -n safer-ops logs -f deploy/safer-ops-api` (cluster `safer-ops-prod`). Pino JSON with `operation:`, `actorId`, ids, and `sensor.request` lines logging every outbound Sensor call (method/path/status/ms). The `requestId` == the `x-correlation-id` header == the backend's persisted `correlationId` — one click is greppable end to end by that id.
- **Firmware/hardware**: the user's own direct MQTT subscription — topics `sg/sas/cmd/<hubSerial>` and `sg/sas/resp/<hubSerial>` (CMD ADD/VERIFY/ALARMS/TEST/RESET/REMOVE…). This is the authoritative device view; depot pairing/reset go API→broker→hub and don't surface in any worker log.
- **Sensor backend DB**: `source ./scripts/load-prod-env.sh` then `sensor-mysql` (read-only, needs the user's `:13308` tunnel up). e.g. `tbl_jobs` (status: 1 Pending, 2 Accepted, 5 Completed), `tbl_device_operations` (correlationId). Non-PII columns unless authorised.

**GOTCHA / correction (2026-05-31):** the `pmsi-api` / `pmsi-worker` pods on the `pmsi-aks` context (namespace `pmsi-dev`) are an **unrelated project** — the "pmsi" name collided. They are NOT the Sensor backend; do not tail them expecting Sensor activity (a tail there sits at 0 for Sensor ops). The Sensor backend's own server logs were not directly tail-able this session; use the safer-ops `sensor.request` lines + MQTT + `sensor-mysql` instead. See [[saferops-e2e-verified-2026-05-31]].
