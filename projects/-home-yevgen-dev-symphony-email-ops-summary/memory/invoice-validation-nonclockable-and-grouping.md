---
name: invoice-validation-nonclockable-and-grouping
description: How invoice line validation handles travel/transport rows and multiple invoice lines billing one Deputy shift
metadata: 
  node_type: memory
  type: project
  originSessionId: 13563370-4aca-4125-8d9a-0e2b77e5b809
---

Invoice→Deputy line validation (`src/services/invoice-validation/line-checks.ts`) has two special cases, added 2026-05-25:

1. **Non-clockable service types** — lines whose `comments` match `transport|travel|mileage|kilometre|kilometer` (regex `NON_CLOCKABLE_SERVICE`, helper `isNonClockableService`) are billed directly and never clocked in Deputy. They return verdict `not_checkable` / code `service_not_clockable` instead of being compared against Deputy hours (which produced false `hours_mismatch` failures). `not_checkable` is a neutral verdict (added to the union) — it doesn't fail or flag the invoice.

2. **Area+day grouping** — when several clockable invoice lines bill the same Deputy area on the same date (one shift split across service-type rows), `buildAreaDayGroups` groups them; the group's summed hours are compared against the single shift once, and the shift's hours are attributed to the *primary* line only (secondary lines get verdict `matched` / code `covered_by_area_group`, `matchedHours: 0`) so area/week totals don't double-count one shift.

**Why:** A real invoice (Maria Paola Dominguez, May 22) billed Beverly Ray as `Individual support` 3h + `Transport` 0.5h on the same day/area; the single ~2.93h Deputy shift was counted against *both* lines, so the 0.5h transport line "failed" against 2.93h. The user chose (a) treat transport as non-checkable, (b) keep per-line validation but stop double-counting.

**How to apply:** The frontend mirrors this — `not_checkable` has a dashed grey pill (`.status-not_checkable`), `getHoursCellStatus` returns null for `not_checkable`/`covered_by_area_group`, and `weeks.ts` excludes `not_checkable` hours from the weekly invoice-hours comparison (keeps their $ in the amount total). The DB only reflects this after a Revalidate run. Relates to [[invoice-weekly-subtotals-feature]].
