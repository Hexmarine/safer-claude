# Add "Created" column to the sensor-angular Alerts list

## Context

The agency-facing Alerts list (`sensor-angular`, the "smoke-alarm" Angular app)
currently has no date/timestamp column — an operator can't tell when an alert
(DISCONNECT/RESET/TAMPERED/ALERT/LOW_BATTERY/BATTERY) actually happened without
opening the record. The backend (`sensor-alarm-backend`) already returns
`createdAt`/`updatedAt` on every alert row and already supports sorting on them
via a generic passthrough — so this is a pure frontend addition, no API change.

Decisions made with the user:
- Show **`createdAt`** only (the event time — most meaningful for an alert row),
  not a separate Updated column. No existing table in this app stacks two
  different timestamps in one cell, so we're not inventing that pattern.
- Reuse the one related precedent that does exist (inbox list): show the short
  date, and put the full precise date/time in a `matTooltip`. We'll extend that
  tooltip to also surface "Updated: ..." when `updatedAt` differs from
  `createdAt`, so the extra info is available without a second column.
- Column position: **right after Alert Type** (matches the admin Sensor Hub
  table, where Install Date sits right after Alert Type).
- Column is **sortable** — `createdAt` is a real column on `AlarmAlerts`
  (`tbl_alarm_alerts`), so the backend's existing generic
  `orderby`/`ordertype` fallback in `getAlarmAlertsList`
  (`sensor-alarm-backend/src/entities/alarms.entity.ts` ~line 3453) already
  handles it correctly with zero backend changes.

This only touches the agency alerts table (`AlertsTableDataSourceAdmin` /
`fetchAlertsList()`), not the separate admin "controllers" table in the same
component, which already has its own date columns.

## Changes

**1. `sensor-angular/src/app/modules/layout/modules/alerts/alerts-list/controllers-list.model.ts`**

In `AlertsTableDataSourceAdmin.columns` (~line 160), insert a new column right
after the `alertType` entry:
```ts
{
  title: TranslateService.data.CREATED_AT,
  id: 'createdAt',
  sorting: true,
  templateBy: 'createdAt',
},
```

**2. `sensor-angular/src/app/modules/layout/modules/alerts/alerts-list/view/alerts-list.component.html`**

In the agency `<app-table>` block (`*ngIf="userType !== 'admin'"`, ~line 255),
add a new `<ng-template appFor="createdAt">` alongside the existing
`alertType`/`deviceType`/etc. templates, following the inbox-list tooltip
pattern (`inbox-list.component.html:16-18`) for consistency:
```html
<ng-template appFor="createdAt" let-row="row">
  <span
    [matTooltip]="
      row.updatedAt && row.updatedAt !== row.createdAt
        ? ('Updated: ' + (row.updatedAt | date : 'MMMM d, y, h:mm:ss a'))
        : (row.createdAt | date : 'MMMM d, y, h:mm:ss a')
    "
  >
    {{ row.createdAt | customDate }}
  </span>
</ng-template>
```
`CustomDatePipe` (`mediumDate` format, `-` fallback for null) and
`MatTooltipModule` are already imported in `alerts-list.module.ts` — no module
changes needed.

**3. i18n labels**

Add `"CREATED_AT": "Created"` to both:
- `sensor-angular/src/assets/i18n/en.json`
- `sensor-angular/src/assets/i18n/ar.json`

(Both locale files must get the key — `TranslateService.data` is just
whichever JSON was fetched for the active locale, no cross-locale fallback.)

## Verification

1. Run the Angular app locally (`sensor-angular`, standard `ng serve` /
   project's existing dev script) and log in as an agency user (not admin) so
   `userType !== 'admin'` and the agency alerts table renders.
2. Navigate to the Alerts list. Confirm a "Created" column appears right after
   "Alert Type", showing a short date (or `-` for null) for each alert row.
3. Hover a "Created" cell — confirm the tooltip shows the full precise
   date/time, and shows an "Updated: ..." line when the row's `updatedAt`
   differs from `createdAt`.
4. Click the "Created" column header — confirm `mat-sort-header` toggles
   asc/desc, the network request carries `orderby=createdAt&ordertype=asc|desc`,
   and the row order visibly changes to match (oldest/newest first).
5. Confirm no other columns, the admin controllers table, or existing sort
   behavior on Alert Type / Property Address regressed.
