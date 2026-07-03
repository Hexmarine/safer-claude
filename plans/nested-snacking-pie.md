# Notifier flap dampening (+ fleet-health hysteresis)

## Context

A water-leak sensor at 23/49 Stewart Drive Werribee (`000000026205A0042406`) is
genuinely **hardware-flapping** — confirmed from the raw MQTT event history in
Mongo `tbl_alarm_logs`: status toggles detected↔cleared (1↔2) every ~16–200 s,
**17–85 transitions/hour sustained all day** (`eventTriggerSource: "HUB"`). This
is not a notifier artifact, not truncation, not the deep-cap bug — the notifier
faithfully relays a real, fast-toggling upstream signal, producing dozens of
🚨 New alerts / ✅ Recovered posts per device per day in the Google Chat ALERTS
space.

The current flap guard (`flapCooldownMs`, 15 min) only silences **reopens**
within the window; it never dampens the **✅ Recovered** posts, and it has **no
notion of a device that has flapped many times** — so every 60 s tick that
samples "cleared" posts a recovery and every post-cooldown "active" posts a new
alert. We want to collapse a flapping episode to **1–2 posts total**.

The Sensor backend already defines flapping — `FLAPPING_ALERT_CONFIG`
(`code/sensor-alarm-backend/src/constants/app.ts:2815`): **≥3 events/1h** or
**≥5 events/24h**, pause 60 min / 24 h. (That gate pauses customer *emails*, not
`tbl_alarm_alerts.eventStatus`, which is why our notifier still sees the churn.)
We mirror those constants so thresholds are platform-consistent, not arbitrary.

A second, independent noise stream rides along: the fleet-health offline count
oscillates **±11** (749↔760) and `notifierFleetChangeThreshold=10` sits one below
the amplitude, so every bounce posts. Fixed here too with simple hysteresis.

**This is safer-ops (exempt from the sensor-regression-guard requirement). The
change is strictly additive: any condition that toggles once or twice must behave
exactly as today — flap logic engages only at the 3rd edge in 1 h / 5th in 24 h.**

## Decisions (user-confirmed)
- **Silent until stable**: one "⚠️ Flapping suppressed" notice on entry, then no
  real-time posts until the incident is stable for the dwell window (60 min),
  then one resolution. The standing reminder is the existing morning digest
  (open incidents are already rendered — no digest change needed).
- **Dedicated Chat section**: a new "⚠️ *Flapping (muted)*" section in the ALERTS
  message, separate from 🚨 New alerts / ✅ Recovered.

## Changes — all in `apps/api/src`

### 1. Per-incident flap state (`notifier-state.ts` + `notifier-transitions.ts`)
Store flap state inside the existing free-form `NotifierIncidentRow.details`
(no Prisma/schema change). Add typed helpers near `consecutiveCount`/`alarmDetails`:
- `details.flapTransitions?: number[]` — epoch-ms of recent transition edges,
  **pruned to 24 h and capped to `flapHistoryCap` (20)** on every record → bounded
  blob despite rows never being deleted.
- `details.flapping?: boolean`, `details.flapNotifiedAt?: number`,
  `details.flapLastEdgeAt?: number`, `details.flapLastState?: "active" | "clear"`.
- Helpers: `flapState(row)`, `recordEdge(transitions, nowMs, cfg)` (append+prune+cap),
  `isFlapping(transitions, nowMs, cfg)` (count `<1h` ≥ `flap1hLimit` OR total
  (already ≤24h) ≥ `flap24hLimit`), `flapWindowSummary(transitions, nowMs)`
  (which window tripped + count, for the headline).

### 2. Flapping state machine in `planTransitions` (`notifier-transitions.ts:264-313`)
Three states on each incident; **non-flapping falls through to today's exact code.**

- **Reopen branch (`:267-284`)** — when `existing.clearedAt` (a clear→reopen edge):
  record the edge; compute `flappingNow = isFlapping(...)`.
  - If `flappingNow`: keep the incident **open & sticky** via `flapReopenIncident`
    with `details.flapping=true`; emit the single "⚠️ Flapping suppressed" post to
    `toNotify` **once** (gated on `flapNotifiedAt==null && !existing.suppressed`),
    otherwise push to `suppressedReopens` (silent).
  - Else (1st–2nd edge): unchanged — existing `reopenWithinCooldown` →
    `suppressedReopens`, else `maybeNotify`.
- **Ongoing-active branch (`:286-296`)** — gate `maybeNotify` on `!flapping`
  (a flapping episode must never re-page). If `flapping` and no edge for
  `≥ flapStableDwellMs` → **exit stably-active**: set `details.flapping=false`,
  leave the open alert, post nothing.
- **Clear loop (`:298-310`)** — the core gap. **Critical model decision:** while
  `flapping`, a momentary absence must **not** set `clearedAt` (branch 3 `continue`s
  past any `clearedAt` row → a cleared flapper would become untouchable and never
  resolve). So:
  - `flapping` incident absent this tick: keep it **open** (refresh `lastSeenAt`,
    set `flapLastState="clear"`, record the active→clear edge), **suppress the
    `toClear` post**. Then if stable for `≥ flapStableDwellMs` → **exit
    stably-cleared**: now set `clearedAt`, push exactly one `✅ Recovered` to
    `toClear`, set `details.flapping=false`.
  - Non-flapping absent incident: unchanged (`clearedAt=now` + `toClear`).

Edge counting is driven by observed-presence change (`flapLastState`), so it works
whether the episode is held open or genuinely clearing.

### 3. Rendering — dedicated "⚠️ Flapping (muted)" section (`notifier.ts`)
In `buildAlertsMessage` (`sectionOf`, ~`:406-411`): route `toNotify` posts whose
`incident.details.flapping === true` into a new `"⚠️ *Flapping (muted)*"` section
instead of 🚨 New alerts. Headline builder `flappingHeadline(incident, count,
windowLabel)` → e.g.
`⚠️ <serial> — Water leak — <address> (47 transitions in the last hour; muted until stable for 60m — check the device)`.
At-least-once: set `details.flapNotifiedAt` in `advanceTerminalState` (`:494-500`)
only after a successful post (mirrors `notifiedAt`), so a Chat outage retries.

### 4. Config (`config.ts:144-149`, `config-summary.ts`, `TransitionConfig`)
Add env-backed knobs mirroring the backend; thread through `transitionCfg`
(`notifier.ts:131-135`) and the test `CFG`:
- `NOTIFIER_FLAP_1H_LIMIT=3`, `NOTIFIER_FLAP_24H_LIMIT=5`,
  `NOTIFIER_FLAP_STABLE_DWELL_MS=3_600_000` (60 min), `NOTIFIER_FLAP_HISTORY_CAP=20`.
- **Keep `flapCooldownMs`** (governs sub-threshold 1st–2nd-edge behaviour — must
  stay as-is for regression safety). Surface the new flap fields in
  `config-summary.ts` for observability.

### 5. Fleet-health hysteresis (`notifier.ts:358-401` + `notifier-transitions.ts`)
Stop the ±11 oscillation posting every bounce. Add a small pure helper
`fleetMoveConfirmed(current, last, pending, threshold, dwellTicks)` next to
`fleetHealthChanged` (`:205-211`), and extend `FleetCursor` (`:58`) with
`pendingOffline?/pendingLowBattery?/pendingTicks?`. In `runFleetHealth`: a move
past `threshold` posts only after the candidate **holds for `dwellTicks` (default
2) consecutive ticks**; an oscillation flips sign each tick and never confirms,
while a genuine large jump (e.g. +40) still posts within ~2 ticks. Config:
`NOTIFIER_FLEET_DWELL_TICKS=2`; keep `notifierFleetChangeThreshold=10`.

## Tests (`node:test`; `pnpm --filter @safer-ops/api test`)
Reuse existing helpers (`incident()`, `observation()`, `alert()`, `CFG`, `makeRig()`).

**`notifier-transitions.test.ts`** — add: 3rd edge in 1 h trips one muted notice;
already-flapping suppresses reopens; flapping suppresses momentary clears (no
Recovered); stably-cleared-past-dwell posts one Recovered + exits; stably-active-
past-dwell exits silently; **regression: 1–2 toggles behave exactly as today**;
24 h limit (5 edges) trips; history pruned/capped; baseline-`suppressed` flapper
stays silent; `fleetMoveConfirmed` holds-N-ticks (pure).

**`notifier.test.ts`** — end-to-end: a sensor toggling every tick across ~8
sweeps collapses to **exactly one** ⚠️ flapping post + zero mid-churn ✅, then
**one** ✅ after a stable-cleared hold (assert ≤2 device posts/episode); fleet
±11 alternation no longer posts every bounce while a single +40 still posts.

## Regression-safety / edge cases
- Non-flapping unchanged (locked by the 1–2-toggle test) — flap branches only run
  when `flapping===true`.
- `canClear===false` (degraded) and `nonAuthoritativeKeys`: all clear-side flap
  logic stays inside the existing `if (canClear)` block, after the
  non-authoritative guard — a degraded tick never advances/exits an episode.
- Truncated-feed reverify (`notifier.ts:262-266`) unaffected (re-adds active
  observations → ongoing-active branch).
- History bounded (prune 24 h + cap 20) despite rows never deleted.
- Flap-then-truly-resolved: edges stop, dwell elapses, one ✅, `flapping=false`
  persisted; stale edges age out so a next-day recurrence won't insta-trip.

## Verify end-to-end
1. `pnpm --filter @safer-ops/api test` green (esp. the new + the 1–2-toggle
   regression test). Run `codex review --uncommitted` in `code/safer-ops` after
   self-review (cross-layer bug catch).
2. **User commits/pushes** (I do not commit) → CI → Flux deploys api.
3. On the live pod, confirm against the same flapping serial:
   `notifier.transition.flap_suppressed` keeps firing but
   `notifier.transition.result {notified, recovered}` for
   `alert:000000026205A0042406:ALERT` drops to a single flapping notice then goes
   quiet; ALERTS space shows one "⚠️ Flapping (muted)" line, no recover/reopen
   churn; the device still appears in the morning digest.
4. Confirm fleet `±11` lines stop while a genuine large offline move still posts.
5. Independent of code: flag the faulty sensor to Haven ops for field replacement.

## Out of scope
- Notifier headless auth (prior plan — already shipped/deployed).
- Aggregating disconnect/low-battery alert *content* (task #14) — separate; this
  plan only fixes the fleet-health ±11 oscillation, not disconnect aggregation.
