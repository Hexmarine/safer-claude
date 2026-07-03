---
name: saferops-property-operational-column
description: "safer-ops property-list \"Operational\" column (Tier 0 pills + Tier 1 device rollup) + the new Sensor operational-summary endpoint"
metadata: 
  node_type: memory
  type: project
  originSessionId: 7f2c795b-1095-4005-9ded-cc69a2bef7fb
---

The safer-ops property book now has an **Operational** column (replaced the raw status code). Built + pushed 2026-06-27; both reviews clean (sensor-regression-guard SAFE Class A, codex clean).

**Tier 0 (safer-ops only, no Sensor change):** `OperationalCell.tsx` system pill + scheduled-test marker from fields already on the list payload. `normalizePropertyListRow` now also maps `alarmTestDate` (Sensor returns the raw PROPERTY_STATUS code; "1"=Active, "4"=New/needs-install, "10"=Disconnected). Pill precedence is operational: NEW / Disconnected win over alarmStatus="1" Active, else muted lifecycle label.

**Tier 1 (device rollup, line 2 "N offline · M fault"):** NEW Sensor endpoint `GET /api/v1/users/report/operational-summary` → `opsReportEntity.fetchOperationalSummary` (reuses the SAME agency-scoped scan/derivations as `fetchReportSummary`, so per-property rows aggregate back to the report totals exactly). safer-ops merges it server-side into `/api/properties` by id via `apps/api/src/operational-summary.ts` (cached 60s + single-flight, keyed `subject:<id>`), **best-effort** — if the endpoint is absent/errors, rows degrade to Tier 0. So safer-ops is safe to ship before the Sensor deploy; line 2 just won't appear until the endpoint is live. Deploy Sensor FIRST to see Tier 1.

**Deliberate exclusions / gotchas:** battery is NEVER shown (the [[hub-lowbattery-string-compare-systemic-bug]] flags ~2340 healthy hubs). `alarmTestDate` null = "unknown", never "overdue". `offline` (connectedStatus != CONNECTED) and `faults` (DEAD/tampered/FAILED) OVERLAP — a FAILED device counts in both; OPEN decision whether to make them disjoint. `connectedStatus` is sticky ([[sensor-device-state-schema-gotchas]]) so "offline" is coarse; v1.1 refinement = use hub lastConnectionTestDate. Reuses opsReport [[saferops-reports-tab]].
