---
name: saferops-reports-tab
description: "SaferOps \"Reports\" tab — agency-scoped portfolio report; new Sensor endpoint /users/report/summary; AGENCY-principal-only access; which metrics are n/a"
metadata: 
  node_type: memory
  type: project
  originSessionId: ce2bd60b-f8a3-4f7b-ac79-3bd8d0acd312
---

SaferOps **Reports** tab (depot-only) shipped 2026-06-21 (both repos committed +
pushed; **live verification against Haven agency 37413 still pending** — confirm
numbers track the live monitor and that the operator token isn't 403'd).

**Architecture:** one cached safer-ops call → one server-side Sensor aggregation.
- Sensor: `GET /api/v1/users/report/summary` — NEW
  `src/entities/opsReport.entity.ts` + `controllers/opsReport.controller.ts` +
  `routes/users/v1/report.routes.ts` (mounted in `routes/users/v1/index.ts`).
  Read-only; counts Properties/Alarms/tbl_jobs (Sequelize) + tbl_alarm_logs
  (Mongo countDocuments) force-scoped to one agencyId, aggregated in JS.
- safer-ops: `GET /api/report` (`apps/api/src/report-routes.ts`, per-agency
  cache + degraded fallback) → `sensor-client.getReportSummary()` →
  `/users/report/summary`; `ReportsView.tsx` tab; `ReportSummary` in
  `packages/shared`.

**Access model (enforced in `resolveAgencyId`):** ALL AGENCY STAFF see the full
agency portfolio, scoped to their OWN agency — admit userType AGENCY (incl.
AGENT_ADMIN, which keeps userType AGENCY) or AGENT; **403** contractors/trade-
persons and agency-less sessions. (Revised 2026-06-21 after the live Haven
operator hit 403: the first cut allowed only a pure AGENCY principal, which
locked out the real depot operator — it's an AGENT/AGENT_ADMIN under agency
37413. Letting agents see the whole agency portfolio is the FEATURE, not a leak:
scope comes only from the session token; a client-supplied agencyId is ignored,
so no cross-agency read. Codex will re-flag this as a leak — it's an intended
product decision, documented in the code comment.) Mounted on `/users`
(AdminUserAuth) NOT `/admins` (AdminAuth 423-rejects the agency token).

**Metrics that are `null`/"not available" by design (no data source):**
SMS-failed & email-failed at last test (outgoing-comms is a template catalog, no
delivery log; SNS MessageId not persisted), and tampered-≥15-min (notification
concept, needs duration derivation). Everything else is real.

**Codex caught (event-sourced-store trap — count by STATE not just event/type):**
exclude REMOVED alarms; tamper lives in `tamperedStatus=ON` not `status`;
incident counts must filter active-state (`ALERT_EVENT_STATUS.ON=1`,
`TAMPERED_EVENT_STATUS.ON=2`, `POWER_EVENT_STATUS.BATTERY=2`) or recoveries
double them; alarm metrics scoped to portfolio (non-deleted) props; testing uses
`alarmStatus=ACTIVE` like `hubTestStat`. Active-fault predicate = DEAD ||
tamperedStatus ON || connectedStatus FAILED.
