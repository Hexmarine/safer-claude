---
name: swap-comms-pause-cron-levers
description: "How to pause customer/agent alert comms fleet-wide during a hub swap — the noise emails are cron-driven, lever is suspending crons, not per-property toggles"
metadata: 
  node_type: memory
  type: project
  originSessionId: 6dd51ead-c7a5-4b5b-925b-589943c794a7
---

2026-06-14: Andrew Cox (Sensor) via Richard asked to pause all customer/agent
comms while hubs have no connectivity during the swap, re-enable with new hub.
The complained-about email is **S162 "Action Required: Scheduled Test unsuccessful
at <address>"** (SendGrid prod template `d-a520a237badc4985a0f36f08b36bb07f`).

Verified mechanism (all the noise is **cron-driven re-notifiers**, NOT the
event-driven life-safety alarm path — pausing crons can never silence a real fire):
- S162 + "upcoming test" reminder → `GET /properties/test-alarm-cron` &
  `/test-alarm-notify-cron`. Selector = `alarmTestDate` in window AND `status=ACTIVE`
  (`entities/properties.entity.ts:5092`); S162 sent on 6-min timeout at `:5516-5582`.
- Daily "still disconnected" agent email (`disconnect_every_day`) + daily tamper /
  low-battery re-notify → `GET /mqtt/start-cron` → `mqtt.controller.ts:5` →
  `cronFunction()` (`services/mqtt/subscriber.ts:2900-2962`, DISCONNECT branch :2943).

Gotchas that defeat the "obvious" fixes:
- **S162 path ignores `alertConfiguration` and `hushEmail`** — only gates are
  `status=ACTIVE` + `alarmTestDate`. Per-property notification toggles do NOT silence it.
- Immediate disconnect email is **off by default** (`DEFAULT_PROPERTY_CONFIGURTION`
  `disconnect.*.email=false`); only default-on offline comm is the cron-driven daily
  `disconnect_every_day.agent.email=true`.
- **No `SEND_EMAIL` global kill-switch** (only `SEND_SMS`, already =0 since 2026-05-08,
  so SMS is already paused fleet-wide).
- `completeJob` resets `alarmTestDate`+`status=ACTIVE` only for `jobType==INSTALLATION`
  (`controllers/users/jobs.controller.ts:2344-2394`); a MAINTENANCE swap does NOT
  (`else if` :2396). `alertConfiguration` is NOT reset on install.

**Recommended lever:** suspend the three prod cron cadences. Zero data mutation,
reversible, fleet-wide.

**Prod scheduler LOCATED (2026-06-14):** standalone cron-server EC2
`i-0392d1fca678f1a21` (`smoke-prod-api-cron-server`, 10.0.2.167, t2.micro; NOT in the
API ASG so root-crontab edits persist). `docs/infra/prod-services-access.md` lists a
stale id `i-0a1cd47cfadedf035` (same role+IP). `sudo crontab -l` = ~30 lines that
`curl https://api.sensorglobal.com/api/v1/...` with a hardcoded HTTP Basic header
(static shared secret across all cron lines — flag for rotation). The 3 lines to
comment for this task:
- `*/30 * * * * .../admins/properties/test-alarm-cron`        (S162)
- `*/30 * * * * .../admins/properties/test-alarm-notify-cron` (test reminders)
- `0 0 * * *   .../admins/mqtt/start-cron`                    (daily disconnect_every_day)
Leave `hub-heartbeat`/`retry-hub-heartbeat` (every-min disconnect *detection*) alone.
cron re-reads on edit; no restart.

**APPLIED 2026-06-14:** the 3 lines (crontab lines 2,3,38) commented with
`#SWAP-PAUSE ` prefix; backup at `/root/crontab.pre-swap-pause.bak` (50 lines);
verified grep -c '#SWAP-PAUSE'=3, total still 50. See docs/applied-changes.md.
Re-enable: `sudo crontab -l | sed -E 's/^#SWAP-PAUSE //' | sudo crontab -`. Each
swapped property auto-resumes once crons re-enabled.

**Residual measured 2026-06-14** (prod smokealarmprod, read-only): 18,368 total
properties, 2,482 active. Of active, 318 have the IMMEDIATE event-driven
`disconnect` email enabled (238 agent-specific) — NOT covered by the cron pause
(fires via MQTT-LWT/heartbeat). Open-job guard (logs.entity.ts:4022, controller's
jobId not CLOSED/COMPLETED) suppresses it for properties with an active swap job, so
real exposure is smaller; it's a one-shot per disconnect, not a daily nag. 129
active have non-default disconnect_every_day (covered — runs via start-cron).

**REFINED (open-job guard + hub state, 2026-06-14): residual ≈ NIL, accepted.**
Of the 318, only 1 is guarded by an open job (the guard only holds during an active
job window, so steady-state ≈0). The other 317 are "exposed" — BUT all 317 hubs are
already `connectedStatus=0` (disconnected) and 316 already have
`disconnectionEmailSent=1`, i.e. the immediate disconnect email ALREADY fired and is
flag-gated from re-sending while still disconnected (only 1 pending). The immediate
disconnect path = hub-heartbeat/retry-hub-heartbeat crons → `checkJobLogsAndUpdateAlarm`
(logs.entity.ts:3941/4022). Do NOT pause hub-heartbeat to suppress it: heartbeat is
load-bearing (hub health + lastCheckedAt, which the safer-ops on-site swap/re-bond
flow depends on). Conclusion: no alertConfiguration mutation needed; the cron pause
plus the one-shot disconnectionEmailSent gate already covers the offline noise.
Tables: tbl_alarms(controller=1,status='1',jobId,connectedStatus,disconnectionEmailSent),
tbl_jobs(status NOT IN (5=COMPLETED,9=CLOSED)=open). 18,368 props / 2,482 active.

**Per-property re-arm ALREADY NATIVE (2026-06-14):** Haven swaps are booked as
INSTALLATION jobs (jobType=1). completeJob (users/jobs.controller.ts:2344-2394)
resets alarmTestDate + status=ACTIVE on type-1 completion. Prod: 931/931 completed
type-1 Haven installs (since 06-01) have alarmTestDate SET; 219 open (status=2
ACCEPTED) swap props have alarmTestDate NULL = silent mid-swap, auto-armed on
completion. So "switch on with new hub" is native for the scheduled-test channel;
the global cron pause is just additionally covering dead-hub props with no managed
swap job yet. JOB_TYPE: 1=INSTALLATION,2=MAINTAINANCE,3=ADD_PRODUCT,4=RECONNECTION
(only type-1 re-arms alarmTestDate). Full re-enablement plan (options A blanket vs B
per-property) in docs/investigations/2026-06-14-swap-comms-reenablement-plan.md.

**SSM access workaround:** local aws-cli 2.31/Py3.14 `ssm send-command` is broken
("badly formed help string", empty CommandId) AND `AWS-StartNonInteractiveCommand`
echoes instead of executing. What works: PTY-wrapped interactive session fed via
stdin —
`timeout 90 script -qec "AWS_PROFILE=sensorsyn-mfa aws ssm start-session --region ap-southeast-2 --target <id>" /dev/null <<'STDIN' ... commands ... \nexit\nSTDIN`.
Current prod API servers: `i-0ad1e502aec0c31a4`/`i-0d729d02217754fed` (prod-api-server).

Open-job guard already mutes immediate disconnect for properties with an active swap
job (`entities/logs.entity.ts:4022-4042`). Plan file:
`~/.claude/plans/functional-doodling-kitten.md`. Decisions: scope=whole fleet,
comms=S162+disconnect, re-enable=on new hub. Related: [[portal-test-mechanics-and-post-swap-failures]],
[[haven-device-swap-baseline]], [[sim-provider-omondo]].
