# Monitor UI: apply UX review fixes + property-grouped wall

## Context

A ux-operator-reviewer pass on the safer-ops Monitor ("wall of glass") found 2 must-fix and 5 should-fix issues. The user wants all 7 applied, plus a redesign of the health grid: **group devices by property** (one tile per property, worst state wins, tap to expand its devices), since operators dispatch per home and a flat 60-device grid covers <2% of a Haven-scale portfolio.

Everything is frontend-only — `MonitorResponse.devices` already carries `propertyId`/`propertyAddress` per device, so grouping is client-side. No API or shared-types changes required.

**Files to modify:**
- `code/safer-ops/apps/web/src/views/MonitorView.tsx` — almost all the work
- `code/safer-ops/apps/web/src/styles.css` — feed severity tones, property-tile/expand styles (monitor section ~line 2993–3245)
- `code/safer-ops/apps/web/src/App.tsx` — pass an `onOpenDevices` callback (view switching is `setView` state, not a router)

## Changes

### 1. (Must) Transient poll failure must not wipe the wall — `MonitorView.tsx:106-119`
In react-query v5 a failed background refetch sets `isError` while keeping `data`. Reorder the guards:
- Full `LoadErrorState` only when `monitor.isError && !data`.
- When `isError && data`: render the wall from stale data with an amber pill in the monitor bar: `Connection lost — showing last known state, retrying…` (reuse `.monitor-degraded` styling; distinct copy from the backend-degraded case, which keeps `Feed delayed — showing last known state, reconnecting…`). The existing `Updated {generatedAt}` stamp already stays at the last good snapshot, so staleness is honest.

### 2. (Must) Tone the feed by severity, not all-red — `MonitorView.tsx:295-324` + CSS
Add a severity helper keyed off `eventCode`: `ALERT`/`TAMPERED` → `alert` (red, as now); `DISCONNECT`/`LOW_BATTERY`/`BATTERY` → `warn` (amber, `--warning-text`); `RECONNECT`/test/other → `ok`/neutral; cleared → existing green. Apply in both `FeedRow` and `ActiveRow` (an active DISCONNECT in "Active now" should be amber too). New CSS variants `.monitor-feed-row-warn` / `.monitor-feed-row-ok` alongside the existing `-alert`/`-clear`.

### 3. Show alert AND tamper counts simultaneously — `MonitorView.tsx:148-160`
Fifth tile is always "Active alerts" (`summary.alerting`); add a sixth "Active tamper" tile (`summary.tampered`) rendered when `tampered > 0`. Red/pulse on whichever is non-zero (`.monitor-summary` is an auto-fit grid, a sixth tile reflows fine).

### 4. Disclose sampled health honestly — `MonitorView.tsx:133, 148-171`
When `scanned < total`:
- Panel sub becomes a sentence: `Showing health for the first 372 of 3,123 devices` (`toLocaleString`).
- Online / Offline / Low battery tiles get a small suffix line `of 372 checked` (add optional `sub` prop to `Tile`).

### 5. Serial visible without hover
The hover-only `title` goes away with property tiles; the expanded device rows (see §8) show the serial inline along with state, alarm type and location. No tooltip-only data anywhere.

### 6. Day-aware timestamps — `formatTime` at `MonitorView.tsx:407-411`
Add `formatWhen(iso)`: today → `14:02`; yesterday → `yesterday 14:02`; older → `8 Jun 14:02` (via `toLocaleString`, en-AU conventions come from the locale). Use it for `since …` in ActiveRow and the `Updated …` stamp (which can age across midnight while degraded). Session feed rows keep the seconds-precision `formatTime`.

### 7. "+N more" links to Devices — `MonitorView.tsx:179` + `App.tsx:264-265`
Overflow tile becomes a button: `+361 more properties — see Devices`. `MonitorView` gets `onOpenDevices: () => void`; App passes `() => setView("devices")`.

### 8. Property-grouped wall (replaces per-device grid)
- Group `data.devices` (the scanned set) client-side by `propertyId` (fallback `propertyAddress`); `null` → one **"In depot / not at a property"** bucket labelled as such (still severity-ranked like any group — an alert anywhere must surface — but shown with its own label and muted tone when healthy).
- Per group compute worst state by reusing the existing `deviceState()`/severity order (alert > tamper > battery > offline > ok) and an affected count.
- Sort groups by worst severity, then address; show up to `GRID_LIMIT` (60) property tiles, overflow per §7.
- Tile = `<button>` (44px+ tap target, `aria-expanded`): state label + affected fraction when unhealthy (`ALERT · 1 of 4 devices`), address (prominent), device count.
- Tap expands: an expanded card spanning the full grid row (`grid-column: 1 / -1`) directly after the tile, listing each device as a row — state glyph + state label, alarm type · location, **serial** (fix #5). Tap again or a close affordance collapses. Respect existing `prefers-reduced-motion` handling.
- Panel sub shows `N properties · M devices monitored` when fully covered; the §4 sentence otherwise.
- Reuse the existing `.device-tile-*` state colour classes for property tiles to minimise CSS churn; add styles for the expanded card + device rows.
- Summary tiles, pill, toasts, "Active now" and the session feed are unchanged (device/event-based as before).

## Out of scope
No backend changes (`apps/api/src/monitor.ts` untouched); summary semantics unchanged.

## Verification
1. `pnpm -r build` (or the repo's typecheck script) in `code/safer-ops` — web is TS-strict; no web test suite exists.
2. `pnpm --filter @safer-ops/api test` — confirm monitor API tests still pass (should be no-op).
3. Run the dev stack in mock mode (fake Sensor client) and eyeball the Monitor view: property tiles group + expand, feed tones (simulate reconnect/disconnect vs alert), sixth tamper tile, sampled-health wording, "+N more — see Devices" navigation, kill the API mid-poll to confirm the wall stays up with the "Connection lost" pill instead of the error screen.
4. Self-review, then `codex review --uncommitted` (house finishing step); fix essential findings only.
5. User does the commit.
