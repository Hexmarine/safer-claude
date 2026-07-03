---
name: ses-454-flapping-crash-email-storm
description: "SES 454 throttling storm (real incident ~2026-06-04; the 18.9k 'live' counts were baked-AMI log HISTORY): flapping-suppression crash on undefined alarmData flooded SES; fix = optional-chain 5 sites + .catch the send"
metadata:
  node_type: memory
  type: project
  originSessionId: b38afd56-c669-467d-9776-233dc9ca5f6c
---

**CORRECTION (2026-06-20): the "18,900 per node" was BAKED AMI LOG HISTORY, not a live storm.** `/var/log/api-dev-error.log` is baked into the golden AMI, so every fresh ASG node shows the SAME frozen counts (18,906 454s + 12,465 indexNumber crashes). Timestamps prove it: the 454s are dated **2026-06-04** and the log spans 2026-05-08→present on nodes booted *today*. So there WAS a real SES-454 email-throttle incident **~2026-06-04** (the flapping-crash bug firing on the instance later snapshotted), but the live nodes are NOT currently storming (live MQTT resp ~0/sec, today's due `getTodayChecks` batch = 2, zero new 454s/crashes post-boot). The "617k checkStatus:null backlog" was ALSO a mis-read — `checkStatus`/`checkDate` are null by default on normal alarm_logs (VERIFY heartbeats dominate); the real scheduled-check queue is tiny (~336: 327 past-due + 2 today + 7 future). Lesson: baked AMI logs replay historical counts identically on every node — always check log line TIMESTAMPS vs node boot time before treating a count as live.

**Original incident (~2026-06-04, real):** SES `454 Throttling failure: Maximum sending rate exceeded`, each an UNHANDLED promise rejection, co-occurring with `Cannot read properties of undefined (reading 'indexNumber')` flapping crashes. SES MaxSendRate=14/s; the cron blew past it when the broken dampener let repeats through.

**Root cause (sensor-alarm-backend, `src/services/mqtt/subscriber.ts`):**
`checkFlappingEventsScheduled` (the alert-flapping EMAIL-SUPPRESSION logic) deref'd `payload?.alarmData.indexNumber` — optional-chained on `payload` but NOT on `alarmData`. **Hub-level DISCONNECT events carry no `alarmData`**, so they hit the `else` branch → threw → aborted the suppression function → repeat/disconnect alerts emailed UNTHROTTLED → SES 454 flood. The 454s then became unhandled rejections because `sendEmailTemplate` (~2690) did `mailer.sendMail();` fire-and-forget with NO `.catch`.

**Fix (A+B, regression-guard GO, Class B):**
- Guard ALL `payload?.alarmData?.indexNumber` derefs on the flapping path — there were FIVE across THREE blocks, reached in sequence (the guard caught that fixing only the first left a twin-crash one call later): redis-key build (~5908/5910), `buildFindWhere` (~6016/6018, called ~5950), `updateSingleAlertStatusIFRedisWindowLive` (~6123/6125, called ~5944 on the redis-live branch). When `alarmData` is undefined the key/query now carries literal `undefined` (per-hub-per-status key; Mongo handles `indexNumber:undefined`) instead of throwing.
- `sendEmailTemplate`: `mailer.sendMail().catch((err)=>logToConsole(...))` so SES rejections log instead of becoming unhandled rejections.
- LEFT OUT (different scope, guarded by earlier `if(alarmData)`/`typeof INDEX`, not on disconnect crash path): local-var `alarmData.indexNumber` at ~2798/3156/5106/5397.

**Still optional (assess post-deploy):** (C) rate-limit/queue SES sends ≤14/s or request an SES rate increase; (D) why MQTT reconnect floods a backlog on every node boot. A+B should collapse volume by restoring dampening + stop the unhandled rejections. Related: [[sensor-outgoing-comms-map]] (PROD email=SES), [[daily-email-volume-overdue-job-reminders]] (daily 07:54 batch — separate), [[device-mqtt-event-history-tbl-alarm-logs]] (flapping config). The `indexNumber` crash was first seen as a "red herring" during [[audit-export-puppeteer-chrome-missing]] then traced to be the email-storm engine.
