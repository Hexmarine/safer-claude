# Compliance & Coverage Dashboard (safer-ops) — v1 Plan

## Context

SaferHomes runs a smoke-alarm monitoring service for AU housing agencies (live customer:
Haven Home Safe, agency 37413, Victorian). We researched AU smoke-alarm compliance law
(`docs/investigations/2026-06-13-au-smoke-alarm-compliance-research.md`) to ground an
agency-facing compliance dashboard. The need: agencies — especially registered community
housing providers — have statutory obligations (annual smoke-alarm test, jurisdiction-specific
cure periods, 10-year alarm expiry, an accurate property+asset register for NRSCH / Victorian
Housing Registrar compliance returns). Today safer-ops has a live "wall of glass" monitor but
nothing that answers "is this portfolio compliant, what's overdue, and can I prove it?"

Exploration established the key enabler: **the Sensor backend already stores the data we need**
— `tbl_properties.buildDate` (construction date), `.state` (jurisdiction FK), `.alarmTestDate` /
`.successTestDate` / `.lastTestDate`, and a fully-retained `tbl_alarm_test_history`; alarms carry
`manufaturingDate` / `expireDate`. The thin safer-ops proxy just doesn't surface these yet.

**Decisions (confirmed with user):** v1 = Compliance & Coverage anchor dashboard; **Phase 1
read-only, zero Sensor edits**; **VIC rules first**, in an extensible rule-object framework.

**Outcome:** a jurisdiction-aware dashboard showing per-property compliance status, coverage
gaps, alarm age/expiry, and an exportable per-property evidence/register view — built entirely
in safer-ops over existing Sensor endpoints, surviving the Sensor WAF rate limit via the proven
monitor-style cache.

## Honesty boundary (load-bearing design constraint)

Sensor does NOT reliably store: gas presence, alarm sensing type (photoelectric/ionisation —
`alertType` is an unenumerated/sparse TINYINT), or power source (`powerState`, same). Therefore:
- **Reliable facts drive status pills:** test dates, device presence/absence, manufacture/expiry
  dates. These are trustworthy.
- **Unreliable facts become disclosed *requirements/caveats*, never green/red claims.** e.g. show
  "Requirement: interconnected photoelectric (implied by post-2014 build — installed type not
  verified in register)", and render gas/electrical checks as *conditional* ("applies if gas
  present — not recorded"). The dashboard must never assert an unverified installed alarm type.
- Do **not** trust `nextSmokeAlarmTestDate` (CSV/manual-populated, no scheduler) — compute due
  status ourselves and surface the computation basis so it's defensible in a compliance return.

## Architecture (reuse, don't reinvent)

Mirror the existing live-monitor stack end-to-end:
- **Cache/aggregation:** new `apps/api/src/compliance.ts` copies the `monitor.ts` pattern —
  module-level `Map` keyed by `agency:<id>`, `createSingleFlight` coalesce, exponential cooldown,
  `degraded` flag, a `ComplianceBackoffError`→503+Retry-After. Difference: compliance changes over
  *days*, so TTL ~5–15 min (vs the monitor's 30s), and a slow web refetch (minutes, not 3s).
  Per-property evidence is fetched on-demand (drawer open), never polled.
- **Route:** new `GET /api/compliance` + `GET /api/compliance/property/:id/evidence` +
  `GET /api/compliance/export` (CSV), following the exact `/api/monitor` handler conventions in
  `routes.ts` (requireUser, agency cache key via `readAgencyId`, START/RESULT/ERROR logs naming
  property ids per the safer-ops traceability rule, backoff→503).
- **View:** new `apps/web/src/views/ComplianceView.tsx` modeled on `MonitorView.tsx`.

## Implementation

### 1. Rule engine — `packages/shared/src/compliance-rules.ts` (NEW)
SaferHomes IP, pure/unit-testable, shared by api (authoritative compute) + web (labels/export).
Per-jurisdiction **rule objects** (not a flat table). Shape:
```ts
type Jurisdiction = "VIC" | "NSW" | "QLD" | "TAS" | "WA" | "OTHER";
type CureClock = {kind:"business-days"|"calendar-days";days:number} | {kind:"asap"} | {kind:"urgent"};
interface JurisdictionRule {
  jurisdiction: Jurisdiction;
  testCadenceMonths: number | "per-tenancy";
  whoTests: "landlord"|"owner"|"tenant"|"agency";
  cureClock: CureClock;
  ageRuleYears: number | null;            // VIC null; others 10
  impliedAlarmType(buildDate: Date|null): { impliedType:"battery"|"hardwired"|"interconnected-photoelectric"; basis:string };
  gasCheck?: { cadenceMonths:number; conditional:"if-gas-present" };
}
const RULES: Record<Jurisdiction, JurisdictionRule>;     // v1: populate VIC fully; OTHER fallback = "rules not modelled"
function ruleFor(state: string|null): JurisdictionRule;  // robust map of Sensor States value → Jurisdiction
```
v1 ships **VIC** complete (12-month cadence, urgent cure, construction-date tiering pre-1997 /
post-1997 / post-2014, conditional 2-yearly gas+electrical). NSW/QLD/TAS/WA rule objects are
stubbed/`OTHER` until later (research already done, slots in without refactor).

### 2. Shared types — `packages/shared/src/index.ts` (MODIFY, additive)
`PropertyComplianceRow` (id, address, jurisdiction, buildDate, lastReliableTest, nextDue,
status: `compliant|due-soon|overdue|no-devices|unknown`, deviceCount, oldestAlarmExpiry,
impliedRequirement, caveats[]); `ComplianceSummary` (counts per status + coverage-gap count);
`ComplianceResponse` (summary, rows, degraded, generatedAt); `PropertyEvidence` (test-history
rows + existing job photos/notes).

### 3. Upstream reads — `apps/api/src/sensor-client.ts` (MODIFY, additive)
- Extend `SensorPropertySummary` + `normalizePropertyList` to carry `buildDate`, `state`,
  `alarmTestDate`, `successTestDate`, `lastTestDate`, `testStatus`. **Verify early** which
  existing endpoint returns these — prefer the agency-scoped `/agency/properties/list/export`
  (`exportPropertyList`) or `/properties/list` (`getPropertyList`) over the minimal
  `property-list-dropdown`; if the chosen list omits fields, bounded `getProperty` enrichment is
  the fallback (and becomes the trigger for a future Phase-2 Sensor endpoint).
- Add `listAlarmTestHistory(propertyId)` reader for the evidence view. Reuse `getJobEvidence`
  as-is for completion photos/notes. Alarm age/expiry comes from the already-paged device list.

### 4. Compute + cache — `apps/api/src/compliance.ts` (NEW)
`getComplianceSnapshot(key, client, log)` (monitor-style cache) + `buildComplianceResponse(props,
alarms, now)` applying `ruleFor` and due-date math:
`nextDue = (successTestDate ?? alarmTestDate ?? lastTestDate) + rule.testCadenceMonths`;
derive overdue/due-soon/compliant; `no-devices` when buildDate present but device count 0
(high-signal, fully reliable coverage gap). `buildPropertyEvidence(propertyId)` for the drawer.

### 5. Routes — `apps/api/src/routes.ts` (MODIFY, additive)
Add the three `/api/compliance*` handlers per §Architecture.

### 6. View — `apps/web/src/views/ComplianceView.tsx` (NEW) + `App.tsx` + `styles.css` (MODIFY)
- `useQuery(["compliance"], apiGet<ComplianceResponse>)` with a slow refetch (~5 min) + `degraded`
  banner. Summary `Tile`s: Compliant / Due soon / Overdue / Coverage gaps / Expiring alarms.
  Per-property `device-table` + `pager` with `status-pill`s, jurisdiction badge, implied-
  requirement caption, and an evidence drawer (test-history list + reused job photos/notes).
- `App.tsx`: add `"compliance"` to `WorkspaceView`, depot `allowedViews`, a nav button
  (lucide `ShieldCheck`/`ClipboardCheck`), render-switch branch, `viewTitle`/`viewSubtitle`.
- `styles.css`: reuse `.monitor-tile`, `.status-pill`, `.device-table`, `.pager`, `.empty`,
  CSS-var tokens; add `.compliance-*` only where needed.

### Reused assets (paths)
`apps/api/src/monitor.ts` (cache skeleton), `apps/api/src/single-flight.ts` (`createSingleFlight`),
`apps/api/src/routes.ts` (`/api/monitor` conventions), `sensor-client.ts` (`listProperties`,
`listDevices`, `getJobEvidence`); web: `MonitorView.tsx` (Tile/degraded/polling),
`KitStatusPill.tsx`, `lib/format.ts` (`formatLocalDateTime`), `lib/api.ts` (`apiGet`),
`lib/toast.tsx`, `views/LoadErrorState.tsx`.

## Phase 2 (conditional, NOT in v1)
Only if Phase 1 proves too many upstream calls / too slow for large agencies: add an **additive**
Sensor read endpoint — new `src/controllers/users/compliance.controller.ts` + new
`src/routes/users/v1/compliance.routes.ts` mounted via one new line in `routes/users/v1/index.ts`
(celebrate + `AdminUserAuth` + `sendSuccess`), doing the property×alarm×latest-test JOIN in one
agency-scoped query (mirror `exportPropertyList` scoping). **Never** touch `properties.entity.ts`
(~30k lines) or any existing route/response shape. safer-ops `compliance.ts` then just swaps its
source client; cache/view layers unchanged.

## Risks
- **WAF rate limit (500 req/5min/IP)** — chief risk. Mitigated by single-flight + agency-keyed
  cache + long TTL + slow web refetch + on-demand (not polled) evidence.
- **Sensor regression** — Phase 1 makes zero Sensor edits (only reads more already-returned
  fields client-side). Phase 2 is new-files-only + one mount line.
- **Field availability** — confirm the chosen list endpoint emits buildDate/state/test dates
  before committing to one-call composition; else bounded enrichment.
- **False compliance claims** — enforce the honesty boundary above; legal exposure if a green
  pill ever implies an unverified installed alarm type.
- **Jurisdiction mapping** — `ruleFor` must handle Sensor `States` name/abbrev variance with an
  `OTHER` fallback that says "rules not modelled", never guesses.

## Verification (end-to-end)
1. **Unit** (`compliance-rules.test.ts`, `compliance.test.ts`): VIC 12-month-from-successTestDate;
   construction-date tier boundaries (pre-1997/post-1997/post-2014); 10-year age rule from
   manufaturingDate/expireDate; coverage-gap (buildDate present, 0 devices); `OTHER` fallback.
2. **API route tests** (mirror `monitor-routes.test.ts` with a fake SensorClient): agency-scoped
   cache key, single-flight coalesce, `ComplianceBackoffError`→503+Retry-After, `degraded` flag,
   traceability logs naming property ids.
3. **Manual** via the `run`/`verify` skill: test agency **59120** first, then Haven **37413**
   (~3.1k devices) — load the view watching safer-ops logs for `sensor.*` call counts inside a
   5-min window, open several evidence drawers, run the CSV export, and reconcile
   overdue/coverage/expiry counts against a Sensor spot-check.

## Parked (not in this plan)
SA + NT smoke-alarm rules and all-state penalties (research gap — needs a targeted pass); the
IoT/remote-test legal question (needs a direct regulator query, not web research); NSW/QLD/TAS/WA
rule-object population (research done, slots into the framework when multi-state demand arrives).
