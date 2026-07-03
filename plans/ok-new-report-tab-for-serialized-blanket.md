# Plan: SaferOps "Reports" tab — portfolio compliance & operations report

## Context

SaferOps operators (Haven Home Safe, agency 37413) need a single reporting tab
that summarises the whole portfolio across five areas: **Properties, Devices
(smoke alarms), Testing, Incidents, Jobs**. Today these numbers are scattered
across per-property drawers and the live monitor; there is no agency-wide
report.

The data lives in the Sensor backend (MySQL `tbl_properties` / `tbl_alarms` /
`tbl_jobs` + MongoDB `tbl_alarm_logs`). Some metrics already have aggregated
Sensor endpoints; several (alarm expiry counts, test SMS/email failure, the
per-contractor job breakdown) do **not**.

**Decisions taken with the user:**
- **Add new Sensor aggregation endpoints** to cover the gaps (not just
  safer-ops-side, not heavy client pulls).
- **Fixed windows per spec** — no interactive date picker in v1.
- **Per-contractor breakdowns now** for the Jobs section.

Outcome: a new `Reports` tab in the SaferOps web app, backed by one cached
safer-ops API call, backed by one new agency-scoped Sensor aggregation endpoint.

---

## Architecture (3 layers, one round-trip per refresh)

```
ReportsView.tsx ──/api/report──> safer-ops apps/api ──/users/report/summary (AdminUserAuth — admits the AGENCY operator token)──> Sensor (NEW)
  (React Query)      (cached per-agency,                (AdminAuth + REPORT perm,
                      backoff like monitor)              all counts server-side, agency-scoped)
```

Counts are computed **server-side in Sensor** and returned in one payload. This
is the WAF-safe design (the 500 req/5min/IP rule that bit the live monitor):
safer-ops makes **one** upstream call per refresh, not N device pages.

### Why the Sensor endpoint is reachable by our token
- `src/routes/index.ts` mounts the admin API at `BASE_ROUTES.ADMINS =
  /api/v1/admins`, with `src/routes/v1/index.ts` as the router.
- safer-ops already calls this surface (e.g. `/admins/jobs/:id` in
  `apps/api/src/sensor-client.ts`) with the depot SUB_ADMIN operator token.
- A new route under `src/routes/v1/` is therefore reachable at
  `/users/report/summary (AdminUserAuth — admits the AGENCY operator token)` with the **same** token — no new auth model.

---

## Layer 1 — Sensor backend (`sensor-alarm-backend`) — Class A pure addition

> Regulated repo (Sensor Regression Posture). Keep this a **Class A pure
> addition**: new files only, no existing route/controller/entity/query touched.
> Run `.claude/agents/sensor-regression-guard.md` before commit-ready.

**New files (no edits to existing logic):**
- `src/routes/v1/report.routes.ts` — one route `GET /report/summary`, mirroring
  the existing report-endpoint guard chain in `src/routes/v1/properties.routes.ts`
  (`Middlewares.Auth.AdminAuth` → set `permissionName = PERMISSION_MODULE_LIST.REPORT`,
  `permissionAction = "view"` → `Middlewares.Auth.VerifyAccessPermission`).
- `src/controllers/opsReport.controller.ts` — `getReportSummary(query, userDetail)`.
- `src/entities/opsReport.entity.ts` — the new read-only count queries.

**One edit (additive, single line):** register the router in
`src/routes/v1/index.ts` next to the others:
`router.use("/report", <express.Application>reportRoutes);`
This is the only existing file touched — a pure addition of one mount line.

**Agency scoping:** follow the jobs-entity pattern
(`src/entities/jobs.entity.ts:184`): `agencyId = sessionData.agency ||
sessionData.userId`. All queries filter to this agency. Alarms scope via
`tbl_alarms.propertyId → tbl_properties.agency`.

**Reuse existing helpers wherever they already aggregate** (do NOT reimplement):
- `alarmEventsHistoryEntity.connectionStat()` → connected/total.
- `adminPropertiesEntity.fetchPropertiesByStatus([...])` → status splits
  (e.g. `PROPERTY_STATUS.NEW = 4` for "requiring new installation").
- `adminPropertiesEntity.hubTestStat()` → success/total tests.
- `jobsEntity.fetchOverDueJobsCount()` / `fetchCompletedJobsCount()` and the
  per-trader grouping in `fetchJobsCountForTraderPerson()` /
  `fetchJobsCountForServiceStaff()` (group by `tradePersonId`).
- The `tbl_alarm_logs` event-count logic already in
  `src/entities/logs.entity.ts` `getAlarmLogs()` (`eventType → where.event`,
  `fromDate/toDate`, agency scope) — reuse for incident counts.

**New count queries to add (the gaps):**

| Section | Metric | Source / query |
|---|---|---|
| Properties | total / connected / disconnected | `connectionStat()` + property-status counts |
| Properties | requiring new installation | `fetchPropertiesByStatus([NEW=4])` |
| Properties | active device faults | `tbl_alarms.status IN (TEMPERED=0, DEAD=2)` join property, distinct propertyId |
| Devices | smoke alarms expired | `tbl_alarms` `expireDate < NOW()` (agency join) |
| Devices | expiring within 12 months | `expireDate BETWEEN NOW() AND +12mo` |
| Testing | success in last 12mo / without | `hubTestStat()` + `tbl_alarm_logs` TEST events, 12mo window |
| Testing | SMS-failed / email-failed at last test | **hardest** — `tbl_outgoing_communications` failure status joined to the property's latest TEST event; scope to last 12mo |
| Incidents | tampered / tampered ≥15min | `tbl_alarm_logs.event = tampered` / `tampered_for_15_minutes` (both exist, `constants/app.ts:2063`) |
| Incidents | power loss / smoke / water-leak / fault / disconnect | `tbl_alarm_logs` by `event`/`alertType` over window |
| Jobs | completed/pending/overdue **per contractor** | `tbl_jobs` group by `tradePersonId` × status (1/5/10) |
| Jobs | new-install per contractor by status | filter `jobType = INSTALLATION (1)` |
| Jobs | by maintenance category per contractor | filter `jobType = MAINTENANCE (2)`, group `job_category` |

Enums to use (verified in `src/constants/app.ts`): `JOB_STATUS` PENDING=1/
COMPLETED=5/OVERDUE=10, `JOB_TYPE` INSTALLATION=1/MAINTENANCE=2, `ALARM_STATUS`
TEMPERED=0/DEAD=2, event-type strings at `:2063`.

**Fixed windows:** counts = current state; testing/expiry = rolling 12 months;
incidents = a default window (propose 12 months, constant at top of entity).

---

## Layer 2 — safer-ops backend (`apps/api`)

- `src/sensor-client.ts` — add `getReportSummary()` calling
  `GET /users/report/summary (AdminUserAuth — admits the AGENCY operator token)` via the existing `getJson()` helper (token +
  `x-correlation-id` handled already).
- `src/report-routes.ts` (new, registered in `app.ts` like `kit-routes.ts` /
  `job-routes.ts`) — `GET /api/report`, agency-scoped, returns the Sensor
  payload.
- **Cache + backoff:** reuse the monitor pattern (`src/monitor.ts`): per-agency
  cache key, modest TTL (~60s — report data is not real-time), exponential
  cooldown + `degraded` flag + `503 retry-after` on upstream failure. The report
  is one upstream call, so WAF pressure is low, but the cache also de-dupes
  concurrent viewers.

---

## Layer 3 — safer-ops web (`apps/web`)

- `src/views/ReportsView.tsx` (new) — `useQuery(["report"], () =>
  apiGet("/api/report"))`. Five sections (Properties / Devices / Testing /
  Incidents / Jobs) as stat-card grids; Jobs section renders a per-contractor
  table. Reuse existing `LoadErrorState`, status badges, and the `.devices-page`
  / table CSS classes in `src/styles.css`.
- `src/App.tsx` — register the tab: add `"reports"` to the `WorkspaceView` union,
  a sidebar nav button (lucide icon, e.g. `BarChart3`), the conditional render,
  and `viewTitle()`/`viewSubtitle()` strings. Gate to the depot persona (same
  list that already excludes installers).

**Good human-collaboration point (Learning style, at implementation time):** the
`ReportsView` section-card layout / how metrics are grouped and labelled, and the
per-contractor table shape — these are design decisions worth a `TODO(human)`.

---

## Key risks to verify FIRST (before building the full thing)

1. **REPORT permission on the operator persona.** The new endpoint uses
   `VerifyAccessPermission` with `PERMISSION_MODULE_LIST.REPORT` ("reports",
   "view"). If the SUB_ADMIN service persona lacks it → 403. **Pre-build probe:**
   hit an existing report endpoint
   (`/admins/properties/event/report/count`) with the operator token. If 403,
   either grant the persona REPORT-view (a Sensor change needing your approval)
   or gate the new route by a permission the persona already holds.
2. **`/admins/*` 504 hang.** Memory notes the admin API can 504 ~60s on an
   AdminUserAuth hang for our token. safer-ops `/admins/jobs/:id` works, so it's
   not universal — but probe latency early; the report fan-out of many counts
   must stay well under the gateway timeout (run counts in parallel via
   `Promise.all`).
3. **SMS/email-failed-at-test** is the one metric with no clean existing join.
   Confirm `tbl_outgoing_communications` carries a usable failure status + a key
   that joins to a TEST event/property before committing to it; if not, ship it
   as "not yet available" and revisit.

## Verification (end-to-end)

1. **Sensor unit-ish:** run each new entity query against a read replica / local
   with a known agency; sanity-check counts against the live monitor and the
   property drawer for agency 37413.
2. **Sensor regression:** run `.claude/agents/sensor-regression-guard.md` — must
   classify as Class A (pure addition), confirm no existing route/permission/
   schema collision. Then `codex review --uncommitted`.
3. **safer-ops API:** `curl /api/report` with a logged-in session; confirm
   agency-scoped payload + that a forced upstream failure yields `degraded`/503.
4. **Web:** run the app (`/run` or the apps/web dev server), open the Reports
   tab, verify each section renders, numbers match step 1, and the
   per-contractor table populates.
5. **Approvals:** Sensor backend changes are commit-prepared only — the user
   commits/pushes. No deploy without an explicit window.

## Out of scope (v1)
- Interactive date-range picker (fixed windows per decision).
- CSV/PDF export of the report.
- Non-Haven / multi-agency rollup (endpoint is agency-scoped automatically).
