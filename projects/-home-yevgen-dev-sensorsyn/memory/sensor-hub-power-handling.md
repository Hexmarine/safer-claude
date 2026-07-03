---
name: sensor-hub-power-handling
description: "How sensor-alarm-backend handles hub mains/battery power (POWER events, 24h DC-battery escalation) + the POWER_STATE_CHANGE prune bug fix staged 2026-06-22"
metadata: 
  node_type: memory
  type: project
  originSessionId: cd25251d-49d4-49ba-ba98-a884d49ffce6
---

Hub power (mains vs backup battery) handling in sensor-alarm-backend. `POWERSTATE` 1=AC, 2=battery; HUB-ONLY (child smoke alarms have no mains — see [[sensor-device-state-schema-gotchas]]). Two state sources: discrete `CMD:POWER` events (pushed on mains transition) AND VERIFY heartbeat replies carry POWERSTATE (refresh `powerState` via verifyAlarm — see [[sensor-hub-connectivity-heartbeat-model]]).

**POWER event handler (subscriber.ts:499):** writes `powerState` to hub tbl_alarms row + tbl_alarm_logs; **immediate alert only on POWERSTATE==2** (mains lost → "switched to backup battery"), gated by bonded property + COMPLETED/CLOSED install job + alertConfiguration (SMS allowlist-gated, email ungated). POWERSTATE==1 (restore) is SILENT. Always calls `checkHubBatteryPowerAndScheduleNotification`.

**24h sustained-outage escalation:** `checkHubBatteryPowerAndScheduleNotification` (subscriber.ts:5544) maintains Redis key `POWER_STATE_CHANGE` = array of `{controllerId, stateChangeTime}` — adds/refreshes on POWERSTATE==2, REMOVES on POWERSTATE==1 (restore cancels timer). `POST /hub-power-state-cron` → `hubPowerStateCron` (alarms.controller.ts:1381) scans it; hub on battery >24h (86400000ms) → `sendDCBatteryNotificationToAgent(propertyId)` (escalated agent email).

**KEY SUBTLETY:** power alerts are driven by TRANSITION EVENTS, not observed state. A VERIFY reply reporting POWERSTATE=2 updates `powerState` but triggers NO alert and NO escalation timer (those only seed from the CMD:POWER handler). So a hub that boots already on battery (e.g. unplugged stock hub) reads powerState=2 silently. (Observed live: hub 002632449900C0012406 on battery 97% via heartbeat, no POWER event → no alert.)

**BUG FIX 2026-06-22 — since COMMITTED to master; the always-false filter is gone from committed code (verified 2026-07-03: master worktree clean, master == origin/master):** `hubPowerStateCron` prune filter at alarms.controller.ts:1409 was `(item) => item.controllerId !== item.controllerId` (param `item` shadowed the for-loop `item` → x!==x → always false → filter never pruned → 24h DC-battery email re-sent every cron tick for hubs >24h on battery). Fixed to `(entry) => entry.controllerId !== item.controllerId` (matches correct sibling subscriber.ts:5604). sensor-regression-guard verdict: SAFE, class C correctness-restoring, contract-neutral, REDUCES notification volume. This bug was NEVER previously fixed (git blame 2024-08-06; only a lint-only `let`→`const` touch since) despite a lineage of OTHER power fixes (SENS-5402/5318/2802/2786/1773). **FOLLOW-UP (not fixed, ticket-worthy):** the fix now EXPOSES a latent multi-hub bug — the loop rebuilds `updatedArray` from the ORIGINAL full array each iteration and writes the whole array back, so if ≥2 hubs cross 24h in one run only the LAST is pruned (earlier ones survive + re-notify). Correct shape = mutate one accumulator in-loop, write once.
