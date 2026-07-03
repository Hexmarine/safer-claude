---
name: prepared-kit-fungible-pool-pivot
description: "The 2026-05-28 pivot — no depot reserve; kits are a fungible open ready pool, binding happens at attach on-site; attach + pair are async fire-and-poll; current status model"
metadata:
  node_type: memory
  type: project
  originSessionId: 37a45498-e9ae-422d-b657-dcf4449c5278
---

Full design + build log (codex hardening rounds, live validation) archived to
`docs/investigations/2026-05-28-prepared-kit-fungible-pool-pivot.md`.

**Durable design (shipped + live-validated 2026-05-28):**
- **No reserve.** Depot only prepares (pair → off-site test → `offsite_tested`).
  Ready kits are a fungible open pool (`offsite_tested` + serviceStaffId/propertyId/
  jobId all NULL); any installer sees all. `reserveKit`/assign routes removed;
  `"reserved"` stays in `KitStatus` for back-compat reads only.
- **Attach binds.** `attachKit({kitId,jobId})` writes property/job/owner
  (`serviceStaffId=job.assigneeId`, #62) ONLY after Sensor confirms; failure leaves
  the kit in the pool (no stranded-reserved dead-end). `offsite_tested` doubles as
  the optimistic lock (concurrent attach → 409).
- **Attach and Pair are async fire-and-poll** (sync versions 504'd at ~90s):
  statuses `attaching` (has `attach_operation_id`) and `pairing` (state in per-child
  `KitDevice.connectionStatus`); UI polls `attach-refresh`/`pair-refresh` with
  useRef in-flight guards; re-ADD throttled to 25s; 10-min pair window → stragglers
  `failed`, kit stays `pairing` (never auto-terminal).
- **Drop mid-pairing** (non-destructive, #101): remove a stubborn non-hub child,
  keep connected siblings; release-before-delete; hub removal mid-pairing rejected.
- Add-device is serial-typed (#81): product code infers type (C001 hub, A001 smoke,
  A002 CO, A003 smoke+CO, A004 leak) → `400 unrecognized_serial` if unparseable.
- **sensor-alarm-backend has NO change from this work** (an ALARMS re-issue watchdog
  was built then REMOVED — its duplicate reply could mutate stock inventory via
  syncAlarmList).

**Open/deferred:** sub-ms TOCTOU in refresh-vs-drop (needs distributed lock,
deferred #68/#103); A004 water-leak pairing gesture unconfirmed with vendor (#102);
Reset is destructive (REMOVEs paired siblings; recovery = power-cycle hub while the
alarm is in pairing mode); live retest of the drop path on a multi-alarm kit.

See [[installation-flows-old-and-new]], [[prepared-kit-backend-internals-doc]],
[[stranded-device-detach-recovery]], [[installer-identity-model]].
