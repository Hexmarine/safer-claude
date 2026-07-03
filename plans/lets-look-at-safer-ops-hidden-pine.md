# Plan: Operational at-a-glance indicators on the safer-ops property list

## Context

The property book (`apps/web/src/views/PropertiesView.tsx`) currently shows only
**administrative** columns — Property (id+title), Address, Status, Owner, Agent.
An operator scanning it can't tell *what's going on* with each property's safety
system (is it live? installed? overdue for a test? any device down?). We want each
row to carry an **operational** glance.

Exploration established two tiers of signal and their cost:

- **Tier 0 — already in the `/users/properties/list` payload, safer-ops just drops
  it.** `alarmStatus` (system active/inactive), `status` (NEW ⇒ needs install),
  and `alarmTestDate` (the *next* scheduled test date — `< now` ⇒ overdue) all
  arrive on each upstream row but `normalizePropertyListRow` doesn't map them.
  Zero Sensor change.
- **Tier 1 — per-property device rollup (offline / fault counts).** Cheaply
  derivable by mirroring the Reports ops-scan (`opsReport.entity.ts` — 2 bulk
  reads + Set-based JS rollup, no N+1), but needs a new Sensor endpoint.

**Decision (user):** ship **Tier 0 now** (no Sensor change, low risk, fast), then
decide on Tier 1 after seeing it live. User wants **all four** signal groups
(System status, Test compliance, Connectivity, Device faults) — so Connectivity +
Faults are the **planned Phase 2**, not dropped. The row cell is built Phase 1 with
a slot for the Phase 2 line.

**Data-quality guardrails (from our investigations — the design MUST honour these):**
- **Battery is OFF the menu.** The ~2340-hub `lowBattery` varchar string-compare
  bug (`'100' <= '15'` TRUE) means any battery indicator shows false positives.
  Never render battery until that CAST fix ships. See [[hub-lowbattery-string-compare-systemic-bug]].
- **`alarmTestDate` is the NEXT scheduled test**, written `now + frequency` after a
  successful test. `< now` ⇒ overdue is clean, BUT it's deliberately not updated
  for real-estate agencies with an `spID` → can be null/stale. **Null = "unknown",
  never "overdue".**
- **`connectedStatus` is a sticky majority flag, not live liveness** ([[sensor-device-state-schema-gotchas]]).
  Tier 1's "offline" count (opsReport definition: property has devices but none
  CONNECTED) is coarse — label it plainly; a v1.1 refinement can lean on the hub
  `lastConnectionTestDate` heartbeat instead.
- **`signalStatus`** is an unconstrained varchar with no enum/known semantics →
  do-not-show.

## Approach

### Phase 1 — Tier 0 (now, safer-ops only, no Sensor change)

Surface fields already returned and render a compact **Operational** column.

1. **`packages/shared/src/index.ts`** — extend `PropertyListItem` with
   `alarmTestDate: string | null` (`alarmStatus` and `status` already exist on the
   type).
2. **`apps/api/src/sensor-client.ts`** — in `normalizePropertyListRow` (~1731),
   map `alarmTestDate` via the existing `stringValue` helper. Confirm the exact
   `status` value the list returns for NEW/needs-install (Sensor status enum; the
   UI currently prints `status` verbatim, e.g. "active"/"inactive") and document
   the mapping. No route change.
3. **`apps/api/src/sensor-client-fake.ts`** — extend the `listPropertiesPaged`
   fixtures with `alarmTestDate` (+ NEW/inactive cases) so route tests cover the
   new states.
4. **`apps/web/src/views/OperationalCell.tsx` (new)** — a small presentational
   component (sibling to `DeviceBadges.tsx`) rendering:
   - **System pill** (reuse `.status-pill` + `.ok/.warn/.bad/.muted`, styles.css
     ~3146): `alarmStatus==="1"` → `.ok` "Active"; `status` NEW → `.warn` "Needs
     install"; else `.muted` "Inactive".
   - **Test marker**: `alarmTestDate < now` → `.status-pill.bad` "Test overdue";
     within N days → `.warn` "Test due"; future or **null** → nothing.
   - A reserved slot (renders nothing in Phase 1) for the Phase 2 issues line.
5. **`apps/web/src/views/PropertiesView.tsx`** — add an "Operational" column
   (between Status and Owner, or fold the raw `status` cell into it) rendering
   `<OperationalCell>`. Reuse the zebra/readability tokens already in place.

### Phase 2 — Tier 1 (planned follow-up, gated on user go-ahead after Phase 1)

Per-property offline/fault counts via a **new additive Sensor endpoint** (Class A
pure addition — chosen over extending the shared `/users/properties/list`, which is
consumed by native apps and is higher regression risk).

1. **Sensor `src/entities/opsReport.entity.ts`** — factor the existing device-scan
   + per-property derivation (`isActiveDeviceFault`, the connected/disconnected
   Sets in `buildPropertiesSection`) into a shared helper and add
   `fetchOperationalSummary(sessionData)` returning per-property rows
   `{ propertyId, deviceCount, offline, faults, testedRecently }` for the agency.
2. **Sensor controller + route** — thin passthrough + `GET
   /users/properties/operational-summary`, mirroring `report.routes.ts` guard
   chain (`AdminUserAuth` + `updateReadonlyUserDetailsInSession`, scope from token
   only). No existing query touched.
3. **safer-ops** — `getOperationalSummary()` in `sensor-client.ts` (mirror
   `getReportSummary`, ~337); `OperationalSummary` type in shared; **merge
   server-side in the `/api/properties` handler** (`routes.ts` ~344) by building a
   `Map<id, rollup>` and left-joining onto the page rows (one agency-wide fetch
   backs every page; rows without a rollup degrade to Tier 0 cleanly).
4. **`OperationalCell` line 2** — render `"2 offline · 1 fault"` (reuse
   `IssueList`/amber `AlertTriangle`); nothing or a muted "OK" when counts are 0.
   Test marker upgrades to authoritative `testedRecently===false`.

## Reuse (don't reinvent)

- `.status-pill.ok/.warn/.bad/.muted`, `IssueList`/`StatusBadge`
  (`views/DeviceBadges.tsx`), and the readability tokens — already in the codebase.
- `stringValue` (sensor-client.ts) for field mapping.
- Phase 2: `opsReportEntity` scan/derivation + the `getReportSummary` client/route
  shape as the 1:1 additive precedent.

## Verification

- **API (node:test + `FakeSensorClient`, like `property-history-routes.test.ts`):**
  `GET /api/properties` now returns `alarmTestDate`; test-overdue boundaries
  (`< now` overdue, null ⇒ no marker, future ⇒ none); NEW ⇒ needs-install.
- **UI (headless Playwright MCP, stub `/api/properties`):** fixtures for Active+clean,
  Needs-install, Inactive, and Test-overdue; screenshot + assert pill tone per
  state, **no battery text ever**, table not overflowing.
- **Phase 2 correctness:** the new endpoint's per-property rows must aggregate back
  to the existing `fetchReportSummary` totals (count(faults>0) == `withActiveDeviceFaults`,
  etc.) — cheapest guard against drift since both share the scan.

## Regression posture

- Phase 1 is safer-ops-only, additive (new column + mapped fields); no Sensor
  change.
- Phase 2 Sensor side is **Class A pure addition** (new route/controller/entity
  method, existing list + native apps untouched). Run
  `.claude/agents/sensor-regression-guard.md` before suggesting commit; deploy the
  Sensor endpoint to prod before safer-ops calls it live.
- The user does commits/pushes; no attribution.
