---
name: apply-targeter-cannot-retarget-day-change
description: "schedule_change apply matches existing rows by the NEW day, so a day change duplicates instead of replacing"
metadata: 
  node_type: memory
  type: project
  originSessionId: e1816bf4-a5fe-47d0-b000-0a73e175e132
---

`applyStandingScheduleProposal` → `findScheduleEntryToReplace` (`src/services/client-registry-proposal-apply-schedule.ts`) looks up the existing active schedule row to replace **by the proposal's stated dayOfWeek**. So for a *day change* (record = Monday, change = Tuesday) it queries for a Tuesday row, finds none, has no generic/dayless fallback, returns null → it **creates a new Tuesday row and leaves Monday active** = a duplicate. It only safely REPLACES for same-day edits (time/duration/worker/cadence on the existing day) or when a single dayless row exists.

This is why the 2026-06 sweep Fix 4 ("schedule-stating note that conflicts with the record") was implemented as a **warning on the note**, not an auto-created `schedule_change`: promoting a day correction would hit this and duplicate the schedule. See `client-registry-normalization/schedule-fact-warning.ts`.

**Why:** the targeter assumes the change names the same day as the row it's editing; a day move breaks that assumption.

**How to apply:** day-change schedule corrections must be done by the operator in the drawer for now. A proper fix (retarget the sole active row, or carry the target schedule entry id through the proposal so apply updates it) is a separate reviewed change — affects every `schedule_change` apply, so test multi-schedule clients. Related: [[client-update-gaps-roadmap]].
