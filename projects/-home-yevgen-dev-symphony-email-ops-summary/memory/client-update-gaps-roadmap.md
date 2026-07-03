---
name: client-update-gaps-roadmap
description: "5-gap roadmap for client-update coverage (worker leave, serviceType, timeline, schedule capture, funding) — paused, to revisit"
metadata: 
  node_type: memory
  type: project
  originSessionId: e1816bf4-a5fe-47d0-b000-0a73e175e132
---

After re-analysing what client updates a home-care/cleaning operator gets vs what the
system supports, we agreed on a 5-gap roadmap to revisit AFTER finishing the per-client
**Edit** flow work. Recommended sequence below. Work the gaps one at a time:
implement → Codex review → fix until clear → pause for user to push → verify in prod on
existing data → next gap.

**Gap 1 — Worker-level leave (central + fan-out). Highest leverage.** "Xiomara away this
week" affects every client she serves but is N manual holds today. New `WorkerLeave`
entity + a fan-out that finds active `ClientScheduleEntry` rows matching the worker in the
window and generates per-client `hold` proposals (reuse bulk-accept). **Pending design
decisions (ask before building):** (a) entry source — manual-first MVP vs manual+email
auto-detect; (b) fan-out — hold proposals for review vs flag-only vs auto-apply; (c)
resume — auto-reinstate after leave end vs manual. (User interrupted the AskUserQuestion
to refocus on the Edit flow, so these are unanswered.)

**Gap 2 — serviceType on the standing schedule.** `ClientScheduleEntry` has no
`serviceType` (schema.prisma ~375), so a client with Personal Care + Domestic can't have
the two standing lines distinguished. Add nullable `serviceType`; carry through extraction
+ apply; scope schedule-replacement by serviceType. Effort M.

**Gap 3 — Sequential thread history → structured timeline.** Long multi-instruction
threads collapse into a notes blob; only final status is structured. Emit one event per
dated instruction with supersedes links; per-client history timeline from
`operationalEvents`. Effort M–L.

**Gap 4 — Standing-schedule capture quality.** Records read "weekly · date not set · time
missing · worker missing". Do a cheap AUDIT script first (count active schedules missing
day/time/worker) before investing; then targeted extraction + "complete this schedule".

**Gap 5 — Funding/plan layer (NDIS/HCP).** No package/plan/budget fields on Client.
**Blocking product question:** what funding model are they actually on (NDIS / HCP /
private / mix)? Don't start without that. Lowest urgency for a cleaning business.

Sequence: 1 → (4 audit) → 2 → 3 → 5. Gaps are mostly independent and reuse the existing
extraction→proposal→bulk-accept rails. See also [[two-apply-systems-clientemailevent-vs-proposals]].
