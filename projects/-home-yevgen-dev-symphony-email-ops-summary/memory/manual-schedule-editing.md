---
name: manual-schedule-editing
description: Standing schedule now has a direct-CRUD pen editor (separate from LLM proposals) + serviceType column; prod migration pending
metadata: 
  node_type: memory
  type: project
  originSessionId: 0382c8cc-8c8a-4e2a-965b-5ec85c8273f1
---

Implemented 2026-06-08: clients can now manually edit their standing schedule via a
pencil on the "Standing schedule" field of the Client record card (mirrors the address
pen), in addition to the unchanged LLM/registry proposal path.

**Architecture (deliberate):** manual edits write **directly** to `ClientScheduleEntry`
via new endpoints — NOT through the proposal apply pipeline. The profile PATCH endpoint
still rejects schedule fields; schedule has its own routes:
- `POST/PATCH/DELETE /api/roster/clients/:id/schedule[/:entryId]`
- service `src/services/roster-client-schedule-service.ts` (`parseScheduleEntryInput`,
  create/update/delete) → reuses `client-schedule-write.ts` helpers; soft-deletes (isActive=false);
  flags pending email proposals stale like profile edits.
- UI: `ScheduleEditor` in `client-current-summary-profile.tsx` (compact one-row-per-entry,
  add/delete, save diffs draft vs original), wired via `schedule.edit` in `ClientRecordSummary`.

**Service type:** new `serviceType` String? column on `ClientScheduleEntry` (values =
`REGISTRY_SERVICE_TYPES`, the 7-value enum in `client-registry-contracts.ts`). The LLM
apply path now PERSISTS serviceType (previously the mapper emitted it but apply dropped it) —
see `client-registry-proposal-apply-schedule.ts` + preview. Relates to [[two-apply-systems-clientemailevent-vs-proposals]].

**Prod migration:** `20260608074509_add_schedule_service_type` auto-applies via the GitHub
Actions deploy job (runs `prisma migrate deploy` before the Cloud Run deploy) — no manual step,
just commit the migration folder and push to main. See [[prod-migrations-separate-from-app-deploy]].

**Defect fixed 2026-06-10 (hidden entries):** `projectCurrentScheduleEntries`
(ClientRegistryDisplay.ts) drops ALL `effectiveFrom=null` rows whenever the client has
any dated row. Manual *create* stamped `effectiveFrom` to dodge this, but *update*
didn't — so editing a legacy undated baseline row made it vanish from list/summary once
a dated row existed (Yvonne Maulden case). Fix: `updateScheduleEntry` now stamps
`effectiveFrom=now` when the existing row has none and the patch doesn't set one.
Also added a frequency (recurrenceType + fortnight-week) selector to `ScheduleEditor` —
it previously had no recurrence control, so operators typed "Weekly"/"F/N" into the
Worker field. Known remaining gaps: (1) the proposal *apply* path can still create
undated rows (`incoming.effectiveFrom ?? base ?? null`) — Erica Borg's fortnightly row;
(2) ~4 prod clients have undated rows hidden behind dated email-applied rows on other
days — possibly stale, related to [[apply-targeter-cannot-retarget-day-change]];
no backfill done.

**Defect fixed 2026-06-14 (second same-day line not rendering):** `projectCurrentScheduleEntries`
(ClientRegistryDisplay.ts) deduped by `dayOfWeek` alone — keeping only ONE entry per weekday —
so a legitimately distinct second line on the same day (split shift at another time, a second
serviceType, an alternating fortnightly week) was silently dropped from the **client list**
(`ClientsScheduleCell` / compact summary) AND the drawer read-only record summary. The drawer's
`ScheduleEditor` uses the RAW `scheduleEntries`, which is why the editor showed the line but the
list/summary didn't (that was the visible divergence). Root: manual create/update does NOT
deactivate same-day rows (by design — coexisting lines are intended), unlike the registry
schedule_change apply path which sets `isActive=false` on superseded rows. Fix: dedup now keys on
the slot identity (`recurrenceType | day/specificDate | fortnightlyWeek | weekOfMonth | startTime |
serviceType`) so distinct visits survive while a true restatement of the same slot (e.g. a
worker/duration change left active, or an effectiveFrom supersession) still collapses to the latest;
same-day survivors now sort by startTime. New test: `test/unit/schedule-projection.test.ts`. tsc
(client+server) clean. No current prod data had >1 active same-day row, so purely additive for future.
