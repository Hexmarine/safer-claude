---
name: haven-device-swap-baseline
description: "Haven device-swap program starts Friday 2026-06-12; pre-swap serial baseline CSVs taken 2026-06-10 in ops-and-extracts/ (3,123 active devices across 902 properties) — the reference for verifying replaced/new devices"
metadata: 
  node_type: memory
  type: project
  originSessionId: 3121effc-806f-44f1-950b-cfb41e9c42eb
---

Ops are swapping devices at Haven Home Safe (agency 37413) properties starting **Friday 2026-06-12**. Point-in-time baseline taken 2026-06-10 (post-incident-recovery, pre-swap):

- `ops-and-extracts/haven-device-serials-2026-06-10.csv` — 3,123 ACTIVE devices (`tbl_alarms.status='1'`): 902 Sensor Hub, 1,305 Sensor Smoke Alarm, 916 Sensor Water Leak Alarm. Columns: property_guid/property_id/address, device_type (= `tbl_alarms.alarmType` string), serial_number, location, hub_serial (parent controller for satellites), installationDate, expireDate, lastTestDate. 0 duplicate serials.
- `ops-and-extracts/haven-properties-without-devices-2026-06-10.csv` — 299 properties with NO active devices (228 ACCEPTED + 71 NEW) — devices exist only on the 902 installed properties.

**How to apply:** when verifying swaps later, diff current `tbl_alarms` (same query shape: join `tbl_properties` agency=37413, status='1') against this baseline per property — replaced devices show as serial changes, additions as new rows. The 422 status='2' REMOVED device rows were deliberately excluded from the baseline.

Related: [[haven-mass-deactivation-2026-06]] (recovery completed same day — note `lastTestDate`/`connectedStatus` in baseline reflect post-restore state).
