---
name: sensor-hub-connectivity-heartbeat-model
description: "How sensor-alarm-backend defines hub heartbeat / connected vs disconnected — server-polled VERIFY model, the crons, timings, and on-demand endpoints"
metadata: 
  node_type: memory
  type: reference
  originSessionId: cd25251d-49d4-49ba-ba98-a884d49ffce6
---

Sensor hub liveness is a **server-polled VERIFY model (pull, not a device keepalive)**. Hubs never autonomously beacon "alive"; the backend asks `{"CMD":"VERIFY"}` on `sg/sas/cmd/<serial>` on a ~24h cadence and infers liveness from whether the hub answers on `resp` inside a **60s** window. Devices DO autonomously push *events* (ALERT/TAMPER/BATTERY) — so alerts=push, liveness=poll. Power state (`POWERSTATE` 1=AC,2=battery) is hub-only; child smoke alarms have no mains/power, only BATTERY — see [[sensor-device-state-schema-gotchas]].

**The "heartbeat" = 3 pieces:** (1) cadence `hub_heartbeat_interval=1440min/24h` in `tbl_invoice_settings` id=1 (live 2026-06-22; also chunkPercentage=10, minHubVerification=100, gapBtwHub=10, lastHealthCheck drives the daily sweep gate); (2) work queue `HeartbeatJob`/`tbl_heartbeat_job` `{serialNumbers:[chunk],executeAt,isCompleted}` — cron chunks the fleet (10%/≥100 hubs, staggered 10min); (3) the VERIFY round-trip.

**State fields (subtle):** `lastConnectionTestDate` = last time server SENT a VERIFY (the *attempt*), written ONLY on send (subscriber.ts:5132, alarms.controller.ts:1678) — NOT proof the hub answered. Selection queries compare it `<= NOW()-interval`. The *answered* signals are `verificationStatus` (PENDING on send → SUCCESS/FAILURE), `lastTestDate` (set by verifyAlarm on reply), `connectedStatus`. `ALARM_CONNECTION_STATUS` enum (app.ts:88): **"1"=CONNECTED, "0"=DISCONNECTED, "2"=REMOVED, "3"=IN_PROGRESS, "4"=FAILED** (note "2"≠failed; a stock/returned hub is REMOVED).

**Disconnect detection (ONLY the crons do it):**
- `POST /hub-heartbeat` → `hubHeartbeatCron` (alarms.controller.ts:1357): daily full sweep `addHeartbeatJob`→`getControllersToVerify` (selects ~all active bonded hubs) when cron's lastHealthCheck≥1440min old; else `addPendingHeartbeatJob`→`getPendingControllersToVerify` (lastConnectionTestDate≤NOW()-(1440+10)min). Both joins are `Properties required:true` → **unbonded hubs (propertyId NULL) are NEVER verified/flipped.**
- `sendVerifyCommand` (:1637): publish VERIFY, set lastConnectionTestDate=now + nextRetryDateToConnect=+4h, wait 60s (`setTimeout 60000`) → `prepareDataForAlarmLogAndBulkCreate({updateNextRetryDate:true})` → `checkJobLogsAndUpdateAlarm` (logs.entity.ts:4041) flips non-answerers to **connectedStatus=DISCONNECTED**, NO email on this pass.
- `POST /retry-hub-heartbeat` → `retryhubHeartbeatCron` (:2698): ~4h later (NEXT_RETRY_DATE_TOCONNECT_INTERVAL=4h, app.ts:136; guard `interval>4*60`), re-VERIFY, 60s, `{updateNextRetryDate:false}` → **DISCONNECT email fires** + `disconnectionEmailSent=true` (sticky). Open install job (status not CLOSED/COMPLETED) suppresses the email.
- So: turned-off bonded hub → flips DISCONNECTED at next daily sweep (up to ~24h), email ~4h after the flip. **All gated on external crontab actually pulling these endpoints (schedule not in repo).** Disconnect = a TIMEOUT noticing silence, not an event.

**On-demand verify endpoints (reply-triggered, NO-OP on silence — cannot declare disconnect):**
- `PUT /ping {controllerId}` → `pingHub` (:2938): publishes VERIFY via fire-and-forget `sendMessage`, returns {}. No Redis bucket/timeout. Hub replies → connectedStatus=1; silent → nothing (only logs the outbound cmd). Confirms alive, never marks dead.
- `PUT /sync-alarm {controllerId}` → `syncAlarm` (:1336): publishes `{"CMD":"ALARMS"}` (NOT verify). On reply → `syncAlarmList` (alarms.entity.ts:2424) reconciles child roster: upserts reported devices AND **soft-deletes children the hub doesn't report (status=DELETED, connectedStatus=REMOVED)** + chains BATTERY. Footgun on a flaky hub; no-op if offline.
- `POST /test-alarm`, `/add-controller`+`retryInstallation` (→`verifyHub` :1295, re-VERIFY every 30s until CONNECTED then clearInterval) also send VERIFY on demand.

QoS0+retain:false everywhere → a command only reaches a hub connected at that instant; a battery-sleeping hub misses it (the portal "Hub did not respond"/6-min timeout). Diagnostic rig built: scripts/diag/mqtt-diag.{js,py} (preflight/listen[non-shared mirror]/verify/simulate[power-loss, TODO(human) fail-closed serial guard pending]); broker mqtt://10.0.2.98:1883 reachable only from app nodes. Test bed used: hub 002632449900C0012406 → property 23848 (13 Peters St Watsonia, test agency 59120), job 6460 COMPLETED.
