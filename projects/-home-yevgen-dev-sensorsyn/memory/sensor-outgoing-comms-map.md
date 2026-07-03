---
name: sensor-outgoing-comms-map
description: "Full map of every outgoing comms channel in sensor-alarm-backend (email/SMS/push/MQTT), their transports, send-gates, and the four trigger classes incl. the external cron-pulled HTTP endpoints"
metadata: 
  node_type: memory
  type: reference
  originSessionId: 2e415041-1cc0-4e2e-8c74-e75f1df4996d
---

Complete map of outgoing comms in `code/sensor-alarm-backend` (verified 2026-06-16).

## Four channels + transports
- **Email** — **PROD SENDS VIA SES** (SendGrid is retired — user-confirmed 2026-06-19; corroborated by `tbl_sendgrid_event_logs` going stale 2026-04-26). The code still supports SendGrid (default) / AWS SES / legacy SMTP selected by `EMAIL_PROVIDER`, and the *code* default is `sendgrid`, but the prod runtime config sets the provider to SES — don't chase SendGrid logs/suppression for a prod delivery miss, check **SES** (suppression list, CloudWatch send events). Central: `src/libs/MailManagerClass.ts` (`MailManager.sendMail`). Template id maps in `src/config/templateIds.ts` + `envWiseTemplateIds/` (S0xx codes, ~160). **No global send-gate** — if the path runs, it sends.
- **SMS** — **AWS SNS**, NOT Twilio. Central: `src/libs/smsManager.ts` (`_sendMessage`/`sendOtp`, `new AWS.SNS().publish`). Gated by `SEND_SMS=='1'` (+ `SEND_SMS_ONLY_ON_ALLOWED_LIST`). The `twilio` dep is used ONLY for SuperSIM status changes (`alarms.entity.ts:2341`), not messaging.
- **Push** — Firebase Admin / FCM. Central: `src/entities/notification.entity.ts` (hardcoded `sensor-production-firebase-adminsdk-*.json`). Android = data-only, iOS = notification+data. No global gate; only per-user `notificationSetting`.
- **MQTT outbound** (device commands) — `src/services/mqtt/subscriber.ts` (`sendMessage`/`sendMessageCron`); publishes `{"CMD":"VERIFY|ADD|ALARMS|REMOVE|BATTERY|TEST|REBOOT"}` to topic `sg/sas/cmd/{serial}`. Inbound sub is `sg/sas/resp/+`.

## Four trigger classes (the "when/where")
1. **Event-driven** — hub MQTT inbound → `subscriber.ts` fans out push+email(+SMS): ALERT/TAMPERED/LOW-BATTERY/DISCONNECT/RECONNECT per property `alertConfiguration`; ADD/VERIFY → installer push within 5min.
2. **Request-driven** — API actions send immediately: job lifecycle (`jobs.controller.ts`), property/lease invites, account/password, manual test-alarm (5s setTimeout → MQTT TEST, 6-min setTimeout → S162 result).
3. **In-process scheduled** — Agenda (`src/services/scheduleService/index.ts`: run-sheet 16:00/tz, summary emails) + node-schedule/setTimeout delays. Agenda jobs mostly just call the HTTP cron endpoints below.
4. **Externally cron-pulled HTTP endpoints — the crontab is NOT in this repo (PM2/EC2).** An external scheduler GETs these; each then sends comms:
   - `mqtt/start-cron` → `cronFunction` (`subscriber.ts:2900`): daily DISCONNECT email, 2-day TAMPERED, 7-day LOW-BATTERY
   - `properties/test-alarm-cron` + `test-alarm-notify-cron`: scheduled per-property tests → tenant SMS/email
   - `properties/check-expired-lease-cron`: lease-expiry reminder (S149)
   - `jobs/send-run-sheet`, `check-overdue-jobs-cron`, `check-overdue-jobs-to-agency-cron`
   - `users/send-out-summary-emails-cron`, `send-communication-queue-sms-cron`, `invite-reminder`
   - `properties/invitation-reminder…`, `sync-property-*-cron`, `alarms/hub-power-state-cron`

## Key gotchas
- S162 "scheduled test unsuccessful" + daily disconnect emails are cron-driven, NOT gated by `alertConfiguration`/`hushEmail` — silence = suspend external crons. See [[swap-comms-pause-cron-levers]].
- No `SEND_EMAIL` flag exists (only `SEND_SMS`).
