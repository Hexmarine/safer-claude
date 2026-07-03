# safer-ops "Properties" tab + per-property audit drawer

## Context

The per-property report currently lives in safer-ops' **History** tab: a
client-side property *picker* that, once a property is chosen, shows its device
roster, open issues, and alarm-event timeline. The operator wants a proper
**property book**: a paged, searchable list of all properties in their depot
(agency) scope, where clicking a row opens a slide-in **drawer** (same UX as the
existing MQTT monitor drawer) showing that property's detail — starting with the
information from Sensor's own **audit report** plus the live device/alert data.

This is an **additive safer-ops-only** change. It consumes **existing** Sensor
endpoints the operator (AGENCY-class, `AdminUserAuth`) token already reaches —
no Sensor backend change, **no Sensor deploy** in v1.

**Confirmed product decisions:**
1. **Fold the History tab into the drawer** and remove the standalone History tab.
2. Drawer shows **audit data + live device/alert data** — 4 sections: Overview,
   Audit log, Devices, Issues & events.
3. v1 search = address / title / owner-tenant / landlord / agent name + exact id
   (all server-side). **Device-serial search deferred to v2.**
4. **On-screen only** — no PDF export in v1.

## Sensor endpoints consumed (existing, do NOT modify)
- `GET /users/properties/list` — `AdminUserAuth` + `PROPERTY:view`. Server-side
  `search/page/limit/orderby/ordertype`, returns `{data,count,page}`. Replaces
  the unpaged `property-list-dropdown` for the new list.
- `GET /users/properties/audit-history` — `AdminUserAuth` + `PROPERTY:details` +
  **`AUDIT_HISTORY` feature flag**. Returns audit rows (type EMAIL/SMS/JOB/NOTES/
  ALERT/EVENT, subject, createdBy/to, product.serialNumber, createdAt, …).
- `GET /users/properties/details?id=` — `AdminUserAuth` + `PROPERTY:details`.
  Full property incl. landlords[] + leaseDetails[] (tenant), status, importSource,
  installedAt.

## Surface A — `packages/shared/src/index.ts` (additive types)
Keep `SensorPropertySummary`, `EventHistoryItem`, `AlertEvent`,
`PropertyHistoryResponse`, `ALERT_EVENT_TYPES` unchanged. Add:
- `PropertyListItem` (id, title, address, status, alarmStatus, leaseStatus,
  importSource, agencyId, ownerName, agentName, createdAt, updatedAt)
- `PropertyListResponse` `{ data: PropertyListItem[]; page: number; total: number }`
- `AuditItem` (id, occurredAt, type, subject, status, statusString, eventType,
  actorName/actorEmail/actorType, toName, deviceSerial, jobId,
  eventTriggerSource, attachmentCount)
- `PropertyDetail` (id, title, address, status, importSource, installedAt,
  alarmTestDate, agencyId, agencyName, agentName, landlords[], leases[] with
  tenants[])
- `PropertyAuditResponse` `{ data: { property: PropertyDetail; audit: AuditItem[];
  auditTruncated: boolean } }`

## Surface B — `apps/api`

### `sensor-client.ts` (new methods + normalizers; mirror `normalizeEventHistory`)
- **Keep `listProperties()` and `getProperty()` unchanged** — `listProperties`
  is used internally by job-import (`job-import-routes.ts:82,150` need the whole
  property book to resolve addresses / build a scope Set); `getProperty` backs
  the existing `/history` route. Do **not** repoint them.
- `listPropertiesPaged({search,page,limit,orderby="updatedAt",ordertype="desc"})`
  → `/users/properties/list` → `normalizePropertyListPage` (count→total, nested
  `landlordDetails.name`→ownerName, `agencyDetails.agentAdminList[0].name`→agentName).
- `getPropertyAuditHistory({propertyId,fromDate,toDate,type,page,limit})` →
  `/users/properties/audit-history` (ordertype=desc) → `normalizeAuditRow`
  (`_id`→id, `createdBy.name`→actorName, `product.serialNumber`→deviceSerial,
  `attachments.length`→attachmentCount, status null-guard).
- `getPropertyDetail(id)` → `/users/properties/details?id=` → richer
  `normalizePropertyDetail` (landlords/leaseDetails→tenants/agency/agent). Returns
  `null` on empty data (route 404s, mirroring `getProperty`).

### `routes.ts`
- **Change `GET /api/properties` in place** to accept `?search&page&limit`
  (Zod `propertiesQuerySchema`, limit max 100 default 25) and return
  `{ data, page, total }` via `listPropertiesPaged`. Safe: the only web consumer
  of the old `{data:[]}` shape is the History picker being deleted (+ one route
  test assertion to update). Keep the SensorClientError→status / 502 fallback.
- **Add `GET /api/properties/:propertyId/audit`** after the `/history` route:
  reuse `resolveHistoryRange` + the `ALERT_LIMIT+1` truncation probe; compose
  `getPropertyDetail` (404 if null) + `getPropertyAuditHistory`; return
  `{ data: { property, audit, auditTruncated } }`. Optional `?type=` filter.
- **Keep `GET /api/properties/:propertyId/history` exactly as-is** — the drawer's
  Devices + Issues&events sections reuse it verbatim.

## Surface C — `apps/web`

### New `views/PropertiesView.tsx` (fork `DevicesView` list pattern)
`page`/`searchInput`/`search` state; `submitSearch` resets page to 1; query
`["properties", page, search]` → `/api/properties?page&limit&search`; `.device-table`
(Title/Address/Status/Owner/Agent), row `onClick` opens the drawer; `.pager`
controls; `LoadErrorState` on error. Search box maps 1:1 to the server `search`
param (no client-side filtering). **Drawer open/pin state stays local to
PropertiesView** (single opener — unlike the multi-opener MQTT drawer that's
lifted to App.tsx).

### New `views/PropertyDrawer.tsx` (fork `MqttMonitorDrawer` chrome)
Overlay/pinned/close/header chrome from `MqttMonitorDrawer.tsx:114-136`. Two
TanStack queries keyed by `propertyId` (+ resolved range): `["property-audit",…]`
→ `/audit`, and the existing `["property-history",…]` → `/history`. Body sections:
- **Overview** — from `audit.property` (PropertyDetail): address/title, status,
  importSource, installedAt, alarmTestDate, owner/landlords, tenant/leases, agency/agent.
- **Audit log** — `audit.audit` (AuditItem[]) timeline: When/Type/Subject/Actor/
  Detail; `auditTruncated` banner. **Render this section's error non-fatally** so
  the other 3 still show if the `AUDIT_HISTORY` flag 403s (see Risks).
- **Devices** — salvage `DeviceSnapshotTable` from `PropertyHistoryView.tsx`.
- **Issues & events** — salvage `AlertHistoryTable` + `EventHistoryTable` + the
  Alerts/All `mode-toggle` + truncation banners + the optional from/to range form
  (drives `appliedRange` for both queries).

### `App.tsx` wiring
Remove `"history"` from the `WorkspaceView` union, depot `allowedViews`, nav
button, dispatcher, and `viewTitle/viewSubtitle`; drop the `PropertyHistoryView`
import. Add `"properties"` everywhere (icon e.g. `Building2`, title "Properties"
/ "Agency property book"), dispatch `<PropertiesView/>`. (`viewTitle/viewSubtitle`
are exhaustive switches — TS will flag any missed case at build.)

## Styling — `styles.css`
Add a **parallel `.property-drawer*`** block (copy `.mqtt-drawer*` ~3327-3498,
wider `--property-drawer-width: 460px`, matching `.shell:has(...)` pad + mobile
full-width) rather than generalizing `.mqtt-drawer*` (keeps the working
diagnostics drawer untouched). **Reuse** `.device-table`, `.device-search`,
`.pager`, `.mode-toggle`, `.notice.error`, `.empty`. Add a small sub-tab/section
header style for the 4 drawer sections; body needs `overflow-y:auto; min-height:0`.

## Tests (`apps/api`)
- `sensor-client-fake.ts`: add `listPropertiesPaged` (page slice + total + call
  recorder), `getPropertyAuditHistory` (slice by limit/page; supports a 501-row
  truncation case), `getPropertyDetail` (null for `missing*` ids). Leave
  `listProperties`/`getProperty` fakes alone.
- `sensor-client.test.ts`: path/param/normalization for the 3 new methods.
- route test: fix the existing `/api/properties` assertion to the paged shape;
  add `search/page/limit` pass-through; add `/audit` cases (200 shape,
  `auditTruncated` at 501, 404 for missing, inverted-range 400, `?type=` forwarded).

## Collaboration handoff (Learn by Doing)
During implementation I'll hand off **one** focused decision via a single
`TODO(human)`: the `AuditItem` → display mapping in the Audit-log section
(which `type`/`status` combinations render as which human label/severity, and the
column layout) — a domain-judgement piece, mirroring the `ALERT_EVENT_TYPES`
handoff from the prior feature.

## Risks & dependencies
- **AUDIT_HISTORY flag + PROPERTY:details (HIGH):** the `/audit-history` route is
  feature-flag + permission gated. **Probe first** with a real operator token
  (`curl …/users/properties/audit-history?propertyId=<known>&limit=1`) — 200 vs
  402/403. Drawer renders the Audit section error non-fatally regardless.
- **Open-issues alert-scoping leak (MEDIUM, inherited, not introduced here):**
  `getAlarmAlertsList` filters `propertyId` on a `required:false` nested include,
  so `/users/alarms/alerts` leaks agency-wide alerts into the Issues section. Rides
  in via the reused `/history` route. Tracked as the separately-diagnosed Sensor
  backend fix (own approval + deploy); not blocking v1.
- **safer-ops-only:** no Sensor code change / deploy.

## Verification
- `pnpm --filter @safer-ops/shared build` → `pnpm --filter @safer-ops/api test`
  (sensor-client + route tests green) → `pnpm --filter @safer-ops/web build`
  (exhaustive `viewTitle/viewSubtitle` switch forces the union migration to be
  complete).
- Live probe of `/users/properties/audit-history` for the flag (above).
- Manual: Properties tab lists/pages/searches; row opens the drawer; all 4
  sections populate; Alerts/All toggle + date range work; pin/close behave;
  History tab gone; **bulk job-import still works** (regression check on the
  untouched `listProperties`).
- `codex review --uncommitted` per repo before commit-ready.

## Out of scope (v2)
- Device-serial search (resolve serial→property via the device-list endpoint).
- PDF export from the drawer (wire to Sensor's existing audit-PDF export / S132).
- The Sensor backend alert-scoping fix (separate, already diagnosed).
