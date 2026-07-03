---
name: device-mqtt-event-history-tbl-alarm-logs
description: "Mongo tbl_alarm_logs = per-device MQTT event history (status 1/2 toggles); how to query it via diag tool; backend's FLAPPING_ALERT_CONFIG; confirmed sensor 26205 hardware flap"
metadata: 
  node_type: memory
  type: project
  originSessionId: 686f63b2-db38-4eaf-bca4-c3eb1d5c12ae
---

The device MQTT event stream IS persisted: Mongo collection **`tbl_alarm_logs`**
(model `code/sensor-alarm-backend/src/models/mongo-db/alarmLogs.model.ts`). One
row per MQTT-reported event. Key fields: `alarm.serialNumber` (the child device;
hub is `controller.serialNumber`), `event` ("ALERT"), `status` (**1 = condition
detected, 2 = condition cleared**), `alertType` (Number; 3 = water leak),
`eventTriggerSource` ("HUB"), `title` (human text e.g. "Alarm in under kitchen
sink detected a water leak"), `createdAt`. This is the definitive activate/recover
ground truth — finer than tbl_alarm_alerts (which only holds current eventStatus).

Query it from this workstation via the on-instance diag tool (Atlas allows app
servers, not the workstation IP — see [[sensor-prod-read-diag-tooling]]):
```
source ./scripts/load-prod-env.sh; export AWS_PROFILE=sensorsyn-mfa
python3 scripts/diag/prod-read.py --collection tbl_alarm_logs --op find \
  --filter '{"alarm.serialNumber":"<SERIAL>"}' \
  --projection '{"createdAt":1,"event":1,"status":1,"title":1,"eventTriggerSource":1,"_id":0}' \
  --sort '{"createdAt":-1}' --limit 40
```
aggregate/$dateToString group-by-hour works too (events-per-hour flap rate).

**FALSE-ZERO TRAP (cost real cycles 2026-06-25):** `tbl_alarm_logs` has **NO
top-level `propertyId`** — it nests as **`property.id`** (Number) and keys the hub
under **`controller.serialNumber`** (child under `alarm.serialNumber`). Filtering
`{"propertyId":N}` returns count 0 with no error → looks like "no events ever"
when there are hundreds. Always use `{"property.id":N}` / `{"controller.serialNumber":...}`.
(Contrast tbl_logs, which DOES have top-level `propertyId`.)

**STATUS namespace collision** (also bit me 2026-06-25): the row's top-level
`status` = **REPORT_STATUS** (`1=SUCCESS, 2=FAIL, 3=PROGRESS`, app-written), which
is NOT the firmware code. The firmware reply lives in **`details.STATUS`** =
**ADD_EVENT_STATUS** (`0=doesnt-exist,1=success,2="FAILURE" but really ALREADY
EXISTS/bonded,3=already-exists`; enum label "FAILURE" is a known misnomer — hub
returns 2 for already-bonded; see subscriber.ts ADD handler ~323). A row with
title "Hub did not respond" + `status:2` + **no `details`** + `eventTriggerSource:null`
was written by the 6-min **timeout sweep** (subscriber.ts:5161, sets
REPORT_STATUS.FAIL), NOT a firmware reply. Discriminator = `details`/`eventTriggerSource`,
never the bare number. To read the device's actual answer use `details.STATUS`.

**BATTERY MQTT command** (`{"CMD":"BATTERY"}` → `sg/sas/cmd/<hub>`; opt `INDEX` for
one child): hub replies on `sg/sas/resp/<hub>` **per-child by INDEX only**
(`{CMD:BATTERY,INDEX:n,BATTERY:pct}`) — it does NOT report its own/backup battery
in this response. The **hub's own battery comes via VERIFY/POWER frames**
(`details.BATTERY` on "Hub connection status verified"). Backend consumes the
resp: `BATTERY>15` = silent `batteryStatus` refresh; `BATTERY<=15` flips
`lowBattery` AND `sendNotification` (low-battery comm to tenant). Added a
**`battery` mode to `scripts/diag/mqtt-diag.js`** (mirrors `verify`, fail-closed
serial guard) for live polls. See [[sensor-hub-power-handling]], [[sensor-device-state-schema-gotchas]].

**Backend already has a flapping concept**: `FLAPPING_ALERT_CONFIG`
(`src/constants/app.ts:2815`) — flapping = **≥3 events/hour** or **≥5 events/24h**;
on trip sets `flappingFlag` + PAUSE_DURATION (60min / 1440min) via
`checkFlappingEventsScheduled` (Help.ts). That gate suppresses the customer/agent
EMAILS, NOT `tbl_alarm_alerts.eventStatus` — so a flapping device still toggles
the alert row, which is why the safer-ops notifier (reads the alert table) still
sees churn. Mirror these constants for notifier dampening = platform-consistent,
non-arbitrary thresholds.

**Confirmed case (2026-06-19):** water-leak sensor `000000026205A0042406`
(23/49 Stewart Drive Werribee) is genuinely HARDWARE-flapping: status 1↔2 every
~16–200s, 17–85 events/hour sustained all day, 1,961 lifetime rows. NOT a
notifier artifact, NOT truncation/pagination, NOT the deep-cap bug. The safer-ops
notifier faithfully relays it (downsampled to its 60s tick / 15min flap cooldown)
→ ALERTS spam. Fix = field-replace the sensor + add notifier flap-dampening.
Relates to [[saferops-chat-notifier]], [[swap-comms-pause-cron-levers]].
