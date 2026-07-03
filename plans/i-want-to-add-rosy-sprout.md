# MQTT Monitor for safer-ops

## Context

During kit preparation (and other on-site/depot flows) the operator drives the hub
over MQTT indirectly — `pair`, `verify`, `test` all go safer-ops API → Sensor backend →
broker → hub. Today none of that traffic is visible in safer-ops; to diagnose a stuck
pairing you have to tap the broker by hand (the live-trace rig). We want an **optional,
in-app diagnostics monitor** that shows the incoming/outgoing MQTT messages for a chosen
hub, so you can watch the device react live while you click through the prep workflow.

**Decisions (confirmed with user):**
- **UX:** a pinnable / collapsible **right-side drawer**, opened from a toolbar button in
  the app shell. Seeded with the focused kit's hub serial, but the serial is editable.
  Lives in the shell so it stays open across views.
- **Transport:** **cursor-based HTTP polling** (~1s), matching the app's existing
  TanStack-Query polling. No websockets/SSE.
- **Availability:** enabled in **prod but gated to depot-tier operators** (`requireDepot`),
  behind an env flag so it stays inert unless broker creds are configured.

**Key architectural fact:** the safer-ops backend (`apps/api`, Fastify 5, ESM) has **no
MQTT connection today** — it is a pure REST bridge to Sensor via `SensorClient`. The broker
is used only by the separate `sensor-alarm-backend`, which we **do not touch**. safer-ops
will open its own **passive, read-only mirror** subscription to the same broker.

**Broker facts** (from `sensor-alarm-backend/src/services/mqtt/subscriber.ts`):
- Topics: outgoing commands `sg/sas/cmd/<hubSerial>`, hub responses `sg/sas/resp/<hubSerial>`.
  Hub serial = `topic.split("/")[3]`. Payloads are JSON with `CMD` (VERIFY/ADD/REMOVE/TEST/
  ALARMS/ALERT/TAMPERED/BATTERY/…), plus `STATUS`, `INDEX`, `ALARMSERIAL`, `BATTERY`, etc.
- The real backend subscribes via the **shared** group `$share/sensorGroup/sg/sas/resp/+`.
  **safer-ops must use a PLAIN (non-`$share`) subscription** to `sg/sas/resp/+` and
  `sg/sas/cmd/+` so it gets its own copy and never steals from the shared group. safer-ops
  must **NEVER publish** — read-only mirror.

---

## Backend

### 1. Shared types — `packages/shared/src/index.ts`
Add (ISO-string timestamps, matching `MonitorResponse` style):
```ts
export type MqttTraceDirection = "incoming" | "outgoing"; // resp=incoming, cmd=outgoing
export interface MqttTraceMessage {
  seq: number; at: string; hubSerial: string; direction: MqttTraceDirection;
  topic: string; cmd: string | null; payload: unknown; // parsed JSON, or { raw: string }
}
export interface MqttTraceResponse {
  enabled: boolean; connected: boolean; messages: MqttTraceMessage[]; cursor: number;
}
```

### 2. Config / env — `apps/api/src/config.ts`
Add to `AppConfig` + `config` (reuse `parsePositiveInteger`):
- `mqttMonitorEnabled` ← `SAFER_OPS_MQTT_MONITOR_ENABLED === "true"` (default false)
- `mqttHost?`, `mqttPort` (default 8883), `mqttUsername?`, `mqttPassword?`
- `mqttTraceBufferMax` ← `MQTT_TRACE_BUFFER_MAX` default 5000
- **Effective-enabled** = `mqttMonitorEnabled && Boolean(mqttHost && mqttUsername && mqttPassword)`.
- Surface `mqttMonitorEnabled` + host presence (never the password) in `config-summary.ts`.
- Add `mqtt` to `apps/api/package.json` deps (same lib the backend uses).

> **Infra prerequisite (not code):** prod safer-ops pods need network reachability to the
> broker host/port + the `MQTT_*` creds and `SAFER_OPS_MQTT_MONITOR_ENABLED=true` in the
> prod env. Until then the route returns `enabled:false` and the UI shows "disabled".

### 3. Mirror subscriber + ring buffer — new `apps/api/src/mqtt-monitor.ts`
Injectable interface so tests never open a socket (mirrors the `makeSensorClient` seam):
```ts
export interface MqttTraceSource {
  isEnabled(): boolean; isConnected(): boolean;
  read(serial: string, since: number, limit: number): MqttTraceMessage[];
  latestSeq(): number;
  capture(topic: string, payload: Buffer | string, at?: Date): void; // test seam
  stop(): Promise<void>;
}
```
- **`MqttTraceBuffer`** (pure, unit-testable): one global bounded array + a monotonic `seq`.
  - `capture`: `parts = topic.split("/")`; `direction = parts[2]==="cmd" ? "outgoing" : "incoming"`;
    `hubSerial = parts[3]`. Try `JSON.parse`; on success `cmd = parsed.CMD ?? null`; on failure
    **log `warn` `mqtt.monitor.parse_failed` (include topic) — no silent catch** and store
    `payload = { raw: text }, cmd = null`. Push `{ seq: ++seq, at, hubSerial, direction, topic,
    cmd, payload }`; if over `bufferMax`, `shift()` oldest (cursor is `seq`, so trimming is safe).
  - `read(serial, since, limit)`: filter `seq > since && hubSerial === serial`, slice `limit`
    (default 200, max 500). Per-hub filtering on read → one global buffer + one global cursor.
  - `latestSeq()` → `seq`.
- **`LiveMqttTraceSource`**: `mqtt.connect(host, {username,password,port,reconnectPeriod:1000})`.
  - `on("connect")` → subscribe **plain** `["sg/sas/resp/+","sg/sas/cmd/+"]` qos 0; log `info`.
  - `on("message", (t,buf) => buffer.capture(t,buf))`.
  - `on("error")` → `error` log, do **not** `end()` (let reconnect recover); `on("reconnect")`/
    `on("close")` → log + track `connected`. `isConnected()` → `client.connected`.
  - **Never calls `publish`** (comment this so a future edit doesn't add one). `stop()` → `end()`.
- **`DisabledMqttTraceSource`**: `isEnabled()=false`, empty reads, no-op stop. Returned when
  the flag/creds are absent.
- **`makeMqttTraceSource(logger)`**: returns Live (started) when effective-enabled, else Disabled.

### 4. Lifecycle — `apps/api/src/app.ts`
- Extend `buildApp` opts: `{ makeSensorClient?, mqttTraceSource? }`.
- `const mqttTrace = opts?.mqttTraceSource ?? makeMqttTraceSource(app.log);` (inject-or-default,
  exactly like `makeSensorClient`).
- `app.addHook("onClose", async () => { await mqttTrace.stop(); });` (clean broker disconnect).
- Pass `mqttTrace` into `registerRoutes`.

### 5. Route — new `apps/api/src/mqtt-monitor-routes.ts` (registered from `routes.ts`)
`GET /api/hub/:serial/mqtt-trace?since=<seq>&limit=`
- zod (match `routes.ts` style): `serial` string 1–120; `since` coerce int ≥0 default 0;
  `limit` coerce int 1–500 default 200; `safeParse` → 400 `invalid_mqtt_trace` with a `warn`.
- `requireUser` then `requireDepot(user, reply)` (`apps/api/src/auth.ts:52`) → 403 `depot_required`.
- **START** log `info` `mqtt.trace.read` (`actorId`, `serial`, `since`, `enabled`, `connected`).
- Body: `{ enabled: source.isEnabled(), connected: source.isConnected(),
  messages: source.read(serial, since, limit), cursor: source.latestSeq() }`.
- **RESULT** log `mqtt.trace.read.result` (`count`, `cursor`, distinct `cmd`s — name entities,
  per `CLAUDE.md`). Unexpected error → `error` log + 500. When disabled/offline the route still
  returns **200** with `enabled/connected` flags + empty `messages` (flags carry state, not HTTP).

---

## Frontend

### 6. Shell wiring — `apps/web/src/App.tsx`
- Lift state into `Dashboard()`: `focusedHubSerial`, `drawerOpen`, `drawerPinned`.
- Pass `onFocusHub={setFocusedHubSerial}` to `KitsView`; in `KitsView` an effect calls it with
  `kit.data.data.hubSerial` when a kit resolves (seeds the drawer with the open kit's hub).
- Add a topbar toggle button (lucide `Activity`/`Radio`), rendered only when `persona === "depot"`.
- Mount the drawer as a sibling inside `<main className="shell">` so it persists across views:
  `{persona === "depot" && (drawerOpen || drawerPinned) && <MqttMonitorDrawer .../>}`.

### 7. Drawer — new `apps/web/src/views/MqttMonitorDrawer.tsx`
Props `{ seedSerial, pinned, onPinChange, onClose }`.
- `serial` state seeded from `seedSerial` but kept editable (an `edited` ref so re-seeding stops
  once the operator types). `cursorRef` + `rows` accumulated client-side.
- Polling like `MonitorView`:
  ```ts
  useQuery({
    queryKey: ["mqtt-trace", serial],
    queryFn: () => apiGet<MqttTraceResponse>(
      `/api/hub/${encodeURIComponent(serial)}/mqtt-trace?since=${cursorRef.current}&limit=200`),
    enabled: serial.trim().length > 0, refetchInterval: 1000,
    refetchIntervalInBackground: true, retry: 1
  })
  ```
  On success append `data.messages` (cap client list ~1000), set `cursorRef.current = data.cursor`.
  On `serial` change reset `rows=[]`, cursor=0. `enabled===false` → "disabled (no broker creds)";
  `enabled && !connected` → "broker offline, retrying…".
- Render: header (title, editable serial input, **pin** toggle, **close**, connection dot);
  scrolling list of rows = time · direction arrow (← in / → out) · `cmd` · payload preview;
  click a row to expand raw `<pre>{JSON.stringify(payload,null,2)}</pre>`. Auto-scroll to newest
  unless scrolled up. Reuse `useToast`, existing token CSS classes.

### 8. CSS — `apps/web/src/styles.css`
`.mqtt-drawer` (fixed right, full height, ~380px, slide-in transform); `--pinned` (in-flow, shell
reserves space) vs `--overlay` (fixed + shadow); `__header`, `__serial-input`, `__list`, `__row`,
`__row--in`/`__row--out` (left-border color in/out), `__cmd`, `__time`, `__payload`; reuse
`.status-dot` for the connection indicator.

---

## Tests — `apps/api/src/mqtt-monitor.test.ts` (+ route)
Follow `monitor-routes.test.ts` (`node:test`, `buildApp({...})`, `login(app)`, `app.inject`).
- **Ring buffer (pure):** `capture` resp→incoming / cmd→outgoing, serial = `parts[3]`, monotonic
  `seq`, `read` filters by serial + `seq>since`, unparseable payload → `{raw}` + `cmd:null` (and
  logs, doesn't throw), over-`bufferMax` trims oldest while cursor keeps advancing.
- **Route:** inject a fake `MqttTraceSource` via the new `buildApp({ mqttTraceSource })` seam.
  401 unauthenticated; 403 installer session (`depot_required`); 200 returns
  `{enabled,connected,messages,cursor}`; `since=cursor` returns no duplicates; serial-filtered;
  disabled source → 200 `enabled:false`, empty. Default `makeMqttTraceSource` returns Disabled
  unless flagged, so the existing `buildApp()` suite never opens a socket — no other test changes.

## Reuse
`buildApp` injection seam (like `makeSensorClient`) · `requireUser`+`requireDepot` (auth.ts) ·
zod `safeParse`→400 (routes.ts) · TanStack `useQuery`+`refetchInterval`+client cursor
(MonitorView) · START/RESULT/ERROR `operation:` logs, no silent catches (CLAUDE.md) · broker
connect style from subscriber.ts but **plain sub, read-only, never publish**.

## Risks
- **Broker reachability** in prod → gated by env flag; route returns `enabled:false`, UI shows
  disabled. Infra prerequisite, not code.
- **Shared-subscription stealing** → use plain `sg/sas/resp/+` + `sg/sas/cmd/+`, never `$share`.
  Enforce + comment; make it a code-review checkpoint.
- **Buffer memory** → capped at `bufferMax` with oldest-trim; `seq` cursor makes trimming safe.
- **Multi-pod buffers are per-pod** → with >1 replica the operator sees only the pod its poll hits.
  Acceptable for diagnostics; note in PR. If it matters later: sticky-session or single diag replica.

## Verification
1. **Local:** `pnpm` install (adds `mqtt`). Set `SAFER_OPS_MQTT_MONITOR_ENABLED=true` + `MQTT_*`
   pointing at the broker (mock-auth login is depot by default → `MOCK_PERSONA=depot`).
2. Run API + web; open a kit in Kits → confirm the drawer toggle appears (depot only) and seeds
   the hub serial. Trigger a `pair`/`verify`/`test` and watch cmd (→) and resp (←) rows stream in.
3. Edit the serial field → confirm it re-targets and resets the feed.
4. With the flag off → route returns `enabled:false`, drawer shows "disabled".
5. `pnpm test` in `apps/api` → ring-buffer + route tests pass. Run `codex review --uncommitted`
   in `apps/api` and `apps/web` as the finishing step.
