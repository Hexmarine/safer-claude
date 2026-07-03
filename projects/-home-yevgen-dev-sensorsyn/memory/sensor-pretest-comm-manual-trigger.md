---
name: sensor-pretest-comm-manual-trigger
description: "How to emit the \"upcoming scheduled test\" tenant comm (SMS+email) on demand, and that the auto cron is currently paused"
metadata: 
  node_type: memory
  type: reference
  originSessionId: be01a52d-54b5-4677-b590-d29a7807bea2
---

How to fire the tenant **pre-test "upcoming scheduled test"** comm on demand (e.g. for a demo), verified live 2026-06-22 on property 23848 → real SMS+email reached the tenant.

**The auto cron is PAUSED.** On cron box `i-0392d1fca678f1a21` the `*/30 * * * * curl … /admins/properties/test-alarm-notify-cron` line is **commented out with `#SWAP-PAUSE`** (hub-swap comms-pause, see [[swap-comms-pause-cron-levers]]). So even a correctly scheduled test will NOT auto-send its 24h reminder until that line is uncommented — the comm must be triggered manually.

**Manual one-off recipe (net-zero, reversible):**
1. Set the property's `tbl_properties.alarmTestDate` = **now + 24h** in UTC (`YYYY-MM-DD HH:MM:SS`). Whole-day offset means the test's UTC hour-of-day and minute land on "now", satisfying BOTH the DB window `(now+23.5h, now+24h]` AND the controller's per-property re-check (`alarmTestDate.getUTCHours()==now hour` and the half-hour bucket 0–30 / 31–60). **Set + trigger within the same minute-bucket**, else the bucket re-check drops it — on a miss, just reset and retry.
2. Trigger `GET https://api.sensorglobal.com/api/v1/admins/properties/test-alarm-notify-cron` **from the cron box** (`i-0392d1fca678f1a21`) — its static IP is in `tbl_cron_whitelist_ips` (the endpoint is IP-gated via `AuthenticateCronIPs`; localhost/workstation = 403). Cleanest: have the box de-comment + run its OWN crontab line so the Basic-auth header never leaves it. HTTP 200 `{"code":200,"message":"Success"}` = ran (not proof of send).
3. Revert `alarmTestDate` to its original value.

**Gates for the send to actually go (all required):** property `status=ACTIVE`; a lease tenant with email (→email) and phoneCode+phone (→SMS, also needs property ACTIVE); tenant phone on the SMS allowlist (see [[sensor-sms-gating-and-failure-report]]). Email template **S035**, SMS template **S056** (+ TinyURL reschedule link). Recipient = `leaseDetails[0].leaseTenants[0]` (first tenant, no active-tenant check).

**Verify the send** in Mongo `tbl_logs` filtered `propertyId`: look for two rows at trigger time — email title "Sensor Global - Scheduled Notification of Smoke Alarm Test" + SMS title "Alarm Test" (`scripts/diag/prod-read.py --collection tbl_logs`). HTTP 200 alone is not enough.

Demo note: demo install properties 23854/23855 (agency 59120, tenant Kristyn) are status 8 pre-install; the same recipe works on them once they flip ACTIVE post-install. 23848 ("00003", 13 Peters St) is an already-ACTIVE sibling usable for rehearsal. See [[sensor-outgoing-comms-map]].

**2026-06-23 demo prep (verified ready):** cron box `i-0392d1fca678f1a21` pub IP **54.153.177.72** = `tbl_cron_whitelist_ips` id2 ACTIVE (3 IPs whitelisted; guard `AuthenticateCronIPs`→`getIpsListToValidateCrom`→CronWhitelistIps status ACTIVE, matches col `ipAddress`). Manual trigger one-liner ON the box (token never leaves it): `crontab -l | grep 'test-alarm-notify-cron' | sed 's/^#SWAP-PAUSE //' | bash`. Active-lease recipient on 23854/23855 = tenant **59280** `kristyn.heywood@saferhomesau.com.au` (NOT the inactive @syncom 59303 lease — alarm/comm loads filter leaseDetails to status ACTIVE). **Fixed today**: agency/agent acct 59120 phone typo `401596481`→`401586481` (now matches whitelist+tenant) so agent SMS (e.g. tampered_for_15_minutes, already sms+email=true on both props) delivers. Full demo runbook: `docs/runbooks/demo-2026-06-23.md`. Audit export verified healthy (Chrome128 LAUNCH_OK both nodes, auditExprotProgress=0 cluster).
