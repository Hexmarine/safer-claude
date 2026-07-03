# Plan: Pause customer/agent alert comms fleet-wide during the hub-swap, auto-quiet → resume on new hub

## Context

During the Haven (and broader) hub-swap program, old hubs lose connectivity. The
backend's **scheduled self-test** runs against the dead hub, times out after 6
minutes, and emails the real-estate agent **"Action Required: Scheduled Test
unsuccessful at <address>"** (SendGrid template **S162**, prod id
`d-a520a237badc4985a0f36f08b36bb07f`). Andrew Cox (Sensor) asked, via Richard, to
**pause all comms to all parties while there is no data connectivity, and only
switch alerts back on with the new hub**.

Operator decisions captured this session:
- **Scope:** entire fleet, all agencies.
- **Comms to pause:** the S162 scheduled-test email **and** offline/disconnect
  alerts.
- **Re-enable:** automatically as each new hub comes online.

This plan is **operational**, not a code change. No Sensor backend behaviour is
modified (Sensor regression posture preserved). Everything proposed is reversible.

## What actually generates the noise (verified in code)

All the complained-about comms are **cron-driven re-notifiers**, not event-driven
life-safety alerts:

| Comm | Trigger endpoint | Code path |
|------|------------------|-----------|
| S162 "Scheduled Test unsuccessful" | `GET /properties/test-alarm-cron` | `entities/properties.entity.ts:5092` (select due props: `alarmTestDate` in window **and** `status=ACTIVE`) → `testPropertyAlarmOnScheduleDate` → 6-min timeout sends S162 at `properties.entity.ts:5516-5582` |
| "Upcoming scheduled test" reminder | `GET /properties/test-alarm-notify-cron` | same selector, `type=1` (24h ahead) |
| Daily "still disconnected" agent email (`disconnect_every_day`), plus daily tamper / low-battery **re-notifies** | `GET /mqtt/start-cron` → `mqtt.controller.ts:5` → `cronFunction()` | `services/mqtt/subscriber.ts:2900-2962` (DISCONNECT branch builds `disconnect_every_day` at :2943) |

Key facts that make this safe and that shaped the approach:
- **Real fire/alarm alerts are event-driven and immediate** — pausing crons
  cannot silence a genuine alarm. (Confirmed: S162 and `disconnect_every_day` are
  the only relevant cron outputs; alarm dispatch is on the MQTT message path.)
- The **immediate** disconnect email is **off by default**
  (`DEFAULT_PROPERTY_CONFIGURTION.disconnect.*.email=false`, `constants/app.ts`);
  the only default-on offline comm to an agent is the **cron-driven daily**
  `disconnect_every_day.agent.email=true`. So suspending `/mqtt/start-cron`
  removes the offline noise an agent actually receives.
- The S162 failure path **does not consult** `alertConfiguration` or `hushEmail`
  (`properties.entity.ts:5516-5582`) — so the "obvious" per-property notification
  toggles do **not** silence it. Its only gates are `status=ACTIVE` + `alarmTestDate`.
- **SMS is already globally off** (`SEND_SMS=0`, applied 2026-05-08, see
  `docs/applied-changes.md`) — that channel is already paused fleet-wide.
- There is **no** global email kill-switch (no `SEND_EMAIL` analog to `SEND_SMS`
  in `libs/MailManagerClass.ts`); a code-level email mute was explicitly out of scope.

## Recommended approach: pause the three prod cron cadences

Suspend the production schedule that invokes `/test-alarm-cron`,
`/test-alarm-notify-cron`, and `/mqtt/start-cron`. This silences **both** families
fleet-wide with **zero production data mutation** and is reversible by a single
re-enable.

### Critical caveat — the prod scheduler is NOT in the repo
`code/infra/k8s/manifests/jobs/*` are **local/suspended smoke scaffolding**
("Disabled for v1 local job runner", `k8s/docs/jobs-local-model.md:13`). Prod runs
on **PM2/EC2** (per the 2026-05-08 SMS runbook, which restarted PM2 on two prod API
instances). The real schedule lives on the prod host (EC2 crontab) or an external
scheduler (EventBridge / uptime-cron) calling these URLs with the cron-IP header.

### Step 1 — Discovery (DONE 2026-06-14, read-only diagnostic window)
**Scheduler = a standalone cron-server EC2**, `i-0392d1fca678f1a21`
(`smoke-prod-api-cron-server`, 10.0.2.167, t2.micro). It is NOT in the API ASG, so
**root crontab edits persist** across API blue/green deploys. (The
`docs/infra/prod-services-access.md` instance id `i-0a1cd47cfadedf035` is stale;
same role + private IP.) Reached read-only via SSM interactive session
(`send-command` is broken on local CLI 2.31/Py3.14 — use a PTY-wrapped
`start-session` fed via stdin).

`sudo crontab -l` holds ~30 lines that `curl` `https://api.sensorglobal.com/...`
with a static HTTP Basic header. **The three lines driving our two noise families:**
- `*/30 * * * * ... /api/v1/admins/properties/test-alarm-cron`        → scheduled tests → **S162**
- `*/30 * * * * ... /api/v1/admins/properties/test-alarm-notify-cron` → upcoming-test reminders
- `0 0 * * *   ... /api/v1/admins/mqtt/start-cron`                     → `cronFunction()` → **daily `disconnect_every_day`** (+ tamper/battery re-notify)

Leave running (out of scope): `hub-heartbeat` + `retry-hub-heartbeat` (every min —
disconnect-state *detection*, not the email; blinding it would harm hub status),
and all billing/sync/job crons.

**Incidental security finding (separate remediation):** every cron line embeds a
hardcoded HTTP Basic credential in the crontab, shared across all cron endpoints.
Not reproduced here. Flag for rotation independently of this task.

### Step 2 — Pause (needs an approved mutation window — host config edit)
On `i-0392d1fca678f1a21`, comment out exactly the three crontab lines above,
leaving all others intact. Proposed safe procedure (read-only-then-replace; SSM
interactive session as ssm-user with sudo):
1. Snapshot: `sudo crontab -l | sudo tee /root/crontab.pre-swap-pause.bak`
2. Comment the three lines (specific matches, no false hits):
   `sudo crontab -l | sed -E '/properties\/test-alarm-cron/ s/^/#SWAP-PAUSE /; /properties\/test-alarm-notify-cron/ s/^/#SWAP-PAUSE /; /admins\/mqtt\/start-cron/ s/^/#SWAP-PAUSE /' | sudo crontab -`
3. Verify: `sudo crontab -l | grep -nE 'test-alarm|start-cron'` shows the 3 lines
   prefixed `#SWAP-PAUSE` and no other line changed.
cron re-reads automatically — **no service restart needed**. **Do not** touch the
heartbeat lines or the live alarm/MQTT message path.

### Step 3 — Re-enable
Re-enable when connectivity is restored / the program ends:
`sudo crontab -l | sed -E 's/^#SWAP-PAUSE //' | sudo crontab -` (or restore
`/root/crontab.pre-swap-pause.bak`), then verify the 3 lines are uncommented.
Because no per-property data changed, resumption is automatic and correct for every
property: healthy/swapped hubs pass their next scheduled test; any still-dead hub
correctly resumes alerting.

### How this maps to "switch on with the new hub"
With cron-suspend there is **no per-property bookkeeping** and nothing to re-arm
per install — a swapped hub is online and healthy, so once it reconnects it emits
no disconnect noise, and it simply rejoins the normal schedule when crons resume.
**Divergence to confirm:** this is fleet-level un-suspend, *not* literal
per-property re-enable at the moment each hub is installed. If the operator
requires alerts to visibly resume for an individual property *before* program end,
use the alternative below instead. (Recommended: accept cron-suspend — it is the
lowest-risk, no-data-mutation option and the per-install distinction has no
practical safety impact.)

### Residual to quantify before relying solely on cron-suspend
Properties with **custom** `alertConfiguration` where immediate
`disconnect.*.email=true` (non-default) would still emit the **immediate** (LWT,
event-driven) disconnect email, which cron-suspend does not gate. Count these
first (`tbl_properties.alertConfiguration` LIKE check). In practice they are also
covered by the **open-job guard** (`entities/logs.entity.ts:4022-4042`: an open
job on the controller sets `sendNotificationFlag=false`) for any property with an
active swap job. If a meaningful number have custom immediate-disconnect on AND no
open job, add a scoped `alertConfiguration` edit for just those.

## Alternative (only if literal per-property auto-resume is required): per-property data lever
- **Silence S162:** set `Properties.alarmTestDate = NULL` (same value the
  deactivation path already uses) for in-scope properties → cron never selects them.
- **Auto-resume:** `completeJob` resets `alarmTestDate` + `status=ACTIVE` **only for
  `jobType == INSTALLATION`** with a `localeSettingId`
  (`controllers/users/jobs.controller.ts:2344-2394`). **Verify the swap is logged
  as an INSTALLATION job** — a MAINTENANCE/SERVICE swap hits the `else if`
  (`:2396`) and does **not** repopulate `alarmTestDate`, so those would never auto-resume.
- **Disconnect:** has **no** auto-resume-on-install lever — `alertConfiguration` is
  not reset on install (`properties.entity.ts:327-334`); re-enable would be a
  manual restore from snapshot.
- Downsides vs recommended: fleet-wide MySQL mutation, snapshot/rollback
  bookkeeping for non-swapped properties, and the INSTALLATION-jobType dependency.
  Not recommended for fleet-wide scope.

## Approvals required (per CLAUDE.md)
- **Diagnostic window** for Step 1 (read-only host inspection):
  `Approved diagnostic window: Claude may run read-only diagnostics on <prod API instance(s)> for the hub-swap comms pause.`
- **Mutation window** for Step 2 (elevated if it touches infra/scheduler):
  name the exact mechanism, the three endpoints, expected impact (scheduled-test +
  daily-disconnect emails cease fleet-wide; alarm path unaffected), rollback
  (re-enable), and the verification command.

## Verification
- **Before:** in CloudWatch, confirm S162 sends and `disconnect_every_day` sends in
  the last 24–48h (baseline volume) using the `payload->#` inbound filter
  technique already used for swap diagnostics.
- **After pause:** confirm no new `/test-alarm-cron` / `/mqtt/start-cron`
  invocations fire on schedule, and no new S162 / `disconnect_every_day` emails in
  SendGrid activity (filter by template id `d-a520a237badc4985a0f36f08b36bb07f`)
  for a full cron interval.
- **Safety check:** trigger (or observe) a real alarm/test event end-to-end and
  confirm the immediate alarm notification still dispatches — proving only the
  scheduled re-notifiers were paused.
- **On re-enable:** confirm one cron interval produces expected scheduled-test
  activity again for healthy properties.

## Deliverable
On approval + execution, record the actual change in `docs/applied-changes.md` and
add a `docs/runbooks/` entry (pause + re-enable steps, the exact prod mechanism
found in Step 1, and the verification filters).
