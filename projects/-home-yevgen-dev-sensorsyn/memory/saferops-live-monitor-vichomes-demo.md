---
name: saferops-live-monitor-vichomes-demo
description: "The safer-ops \"Live monitor\" (portfolio wall-of-glass) built for the Vic Homes demo, and the alertType event-vs-device gotcha behind it."
metadata: 
  node_type: memory
  type: project
  originSessionId: 7f38293e-5cce-4419-8a5c-127e9787c642
---

For the **Vic Homes** (large agency, new to monitoring) demo we built a safer-ops
**portfolio Live monitor** — the "what you actually bought" closer after the
install flow. Depot/agency-only nav view `Monitor` (`MonitorView.tsx`): health
summary tiles + a severity-sorted device grid + a live event feed, polling
`GET /api/monitor` every 3s. The demo beat: do the install, then set off **real
smoke** → the alarm card + "Active alerts" tile + a feed row light red within
~1–3s, auto-clears when smoke dissipates. Decisions locked with the user:
portfolio scope (not single-property), real in-room hardware trigger, build one
real page (not mocks). Branding (co-brand "Vic Homes") still TODO — they'll
supply assets.

**It surfaces an already-working pipeline, not a mock.** A real activation:
hub MQTT `{"CMD":"ALERT",ALARMTYPE,STATE:1}` → backend persists `Alarms.alertStatus=1`
+ inserts an immutable `tbl_alarm_alerts` row + fires S037 (agent)/S042 (tenant)
notifications. safer-ops reads: `/users/alarms/list` (`alertStatus`→`issues:["Alert"]`,
agency-scoped) + **`GET /users/alarms/alerts`** (the event feed, agency-scoped,
`status/fromDate/propertyId` params). No backend change; SensorGlobal already
markets this 24/7-vision/tamper/remote-test story (sensorglobal.com/asset-managers).

**THE GOTCHA (cost two codex rounds): `tbl_alarm_alerts.alertType` is the EVENT
kind, not the device type.** It stores `EVENT_TYPE.*` strings — `ALERT` /
`TAMPERED` / `DISCONNECT` / `LOW_BATTERY` / `RESET` (see
`sensor-alarm-backend/src/constants/app.ts` EVENT_TYPE + `alarms.entity.ts`
`updateAlarmUsingIndex` alertObject). A real smoke event is `alertType="ALERT"`,
NOT "1"/"smoke". The smoke/CO/leak substance comes from the **serial's product
code** (A001 smoke, A002 CO, A003 smoke+CO, A004 leak — `kitDeviceCatalog`) or
the controller's `product` enrichment. shared helpers added:
`deviceInfoFromSerial`, `alertEventLabel`, `alertSubstanceLabel`, `alertHeadline`,
`kitDeviceTypeFromSerial`.

**Correctness lessons codex enforced (all fixed) — a safety monitor must never
look quiet during a live incident:** (1) count `alerting`/`tampered` over the
UNION of device-`issues` AND the active alert feed (keyed by serial), not just
the fetched device page; (2) page devices (≤600/kind) + page the active-alert
feed (≤500) so counts cover the portfolio, not page 1 — `summary.scanned` vs
`total` discloses any remainder; (3) show current actives on load via an
"Active now" section (the silent-seed transition log alone hid pre-existing
incidents); (4) the overall alert state = `alerting || tampered` (tamper alone
must not read "Live"); (5) `alertsTruncated` flag → client suppresses transition
diffing so a still-active alert falling off the trimmed feed can't emit a false
"Cleared". `summary` (server) is authoritative; the client stream is cosmetic.

Files (committed since; verified 2026-07-03): `apps/api/src/monitor.ts`
(`buildMonitorResponse` pure), `monitor.ts` route + `collectDevices`/
`collectActiveAlerts` pagers in `routes.ts`, `sensor-client.ts` `getAlarmAlerts`,
`MonitorView.tsx`, shared types/helpers, `monitor.test.ts` + `monitor-routes.test.ts`.
165 api tests green, typecheck/lint/build green, codex-clean.

**Verify-live before stage:** confirm a physical smoke trigger flips `alertStatus`
+ writes `tbl_alarm_alerts` readable via the operator (agency) token (the
`/alerts` route needs ALARMS-view permission). Production upgrade = MQTT push
(safer-ops subscribes `sg/sas/resp/+` → SSE/WS, sub-second) vs the current 3s
poll. Related: [[saferops-e2e-verified-2026-05-31]], [[installation-flows-old-and-new]],
[[saferops-live-trace-rig]].

**PROD INCIDENT 2026-06-11 (WAF) + the fix now shipped:** a Haven-scoped (37413)
monitor session's un-cached fan-out (device pages × 2 kinds + 5 alert pages ≈
150 req/min) tripped Sensor's AWS WAF rate rule **`Sensor_Global_Prod_web_ACL_Rule`:
500 req / 5 min / IP → Block** — sustained 403s on `/users/alarms/*`, and the
continuing poll kept the window fed so it never recovered. Fix (deployed
d4e1fe6): `monitor.ts` snapshot cache keyed `agency:<id>` — devices TTL 30s,
alerts TTL 2.5s, single-flighted, failure cooldown 30s→120s serving the last
snapshot as `degraded:true` (web shows amber "Feed delayed" pill; degraded keeps
the stale `generatedAt`), no-stale cooldown → 503+Retry-After. Test agency 59120
never tripped it (1 page/kind ≈ 60/min). WAF allowlist of safer-ops egress IP =
still-open ask to the JV.

**UX overhaul 2026-06-12 (committed since, web-only — MonitorView.tsx/styles.css/App.tsx):**
after a ux-operator-reviewer pass, the wall is now **grouped by property** (one
tile per property, worst state wins with "ALERT · n of m" counting ONLY the
worst-state devices, tap-to-expand device rows carrying the serial; property-less
devices = one "In depot" bucket, sorted last per severity band; `assigned` flag
tracks bucket-ness because a real propertyId can come with a null address).
Plus: failed background poll no longer wipes the wall (LoadErrorState only when
`isError && !data`; else amber "Connection lost — showing last known state,
retrying…" pill — verified live by killing the API mid-poll); feed rows toned by
event severity (red=ALERT/TAMPERED, amber=DISCONNECT/battery, calm=reconnect/
test, green only "Cleared"); sixth "Active tamper" tile when tampered>0 (no
longer hidden during combined incidents); sampled-health disclosure on the
tiles themselves ("of 1,200 checked") + sentence header; day-aware timestamps
("since yesterday 14:02"); "+N more properties — see Devices" navigates via an
`onOpenDevices` prop (view switching is App-state, not a router). Verified in
the browser against live Haven data (1,200 scanned / 3,562, 540-property
overflow). Codex caught 2 grouping bugs (depot misclassification on null
address; mixed-severity count inflation) — both fixed, re-review clean.

**Stale-state cleanup 2026-06-11 (user-approved prod writes):** Haven had 1,085
`tbl_alarm_alerts` rows stuck `eventStatus='1'` (999 DISCONNECT, newest
2026-03-26 — old-fleet residue) making the wall show phantom incidents (4
alerting/17 tampered) AND costing 5 alert pages per poll. Resolved via
`eventStatus='0'` for agencyId=37413 createdAt<2026-06-01; plus 17 stale
`tbl_alarms.alertStatus='1'` and 76 `tamperedStatus='1'` device flags (zero had
any corroborating event ≥ June; left `tamperedStatus='2'` rows alone —
semantics unverified). GOTCHA: a trigger on `tbl_alarms` writes
`tbl_alarm_alerts`, so an UPDATE on tbl_alarms can't reference tbl_alarm_alerts
in a subquery (ERROR 1442) — materialize the id list first. Wall verified green
after: alerting 0 / tampered 0 / 700 offline (real dead old fleet; the
2026-06-12 swap wave's job).
