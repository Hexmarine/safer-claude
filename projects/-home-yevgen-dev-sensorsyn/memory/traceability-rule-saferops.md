---
name: traceability-rule-saferops
description: "safer-ops traceability/observability rule: every op logs start+result+error, no silent catches, name the entity not the count"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 37a45498-e9ae-422d-b657-dcf4449c5278
---

The user requires the safer-ops backend to be diagnosable from pod logs alone (it's a bridge to the Sensor API + live hardware; field failures must be explained without a DB read or repro).

**Why:** debugging the prepared-kit flow live, a swallowed status read left a kit stuck `pending` while the hardware had actually connected — invisible in logs. Opaque 4xx/5xx with no log line is the recurring pain.

**How to apply:** the rule lives in `code/safer-ops/CLAUDE.md` (created 2026-05-26). Every operation logs START (operation tag + actorId + ids), RESULT (resulting state + per-item verdicts + offending **serials**, not just counts), and ERROR (warn for 4xx/expected, error for 5xx/unexpected, with code+statusCode+ids+path before responding). Hard rules: no silent `catch {}`/`catch { continue }`/`catch { return }` (must log first); no `reply.code(4xx)` without a log; outbound Sensor failures log method/path + Sensor's own code. Centralised error mappers `sendKitError` (kit-routes) and `sendSensorError` (job-routes) already log — new mappers must too.

**Cross-system trace (shipped 2026-05-30, #25/#26/#24/#27).** Every outbound Sensor call now logs centrally through `SensorClient.requestJson` (`sensor.request`/`sensor.error` with method/path/status/ms + correlationId; no bodies/tokens) — `SensorClientOptions` gained an optional `logger` + `correlationId`, injected in `routes.ts makeSensorClient` from `request.log`/`request.id`. Fastify `genReqId` (app.ts) mints a UUID per request (honoring an inbound `x-correlation-id`/`x-request-id`), so the `requestId` already on every safer-ops log line IS the trace id; it rides to Sensor as the `x-correlation-id` header. The Sensor backend persists it on **`tbl_device_operations.correlationId`** (migration `20260530_…`; pre-paired + stock verification routes read header-or-body via pure `resolveCorrelationId`, clamped to 191). **To trace a field issue across both systems:** take the `requestId` from a safer-ops log line → `SELECT * FROM tbl_device_operations WHERE correlationId='<id>'` (sensor-mysql) → its `tbl_device_operation_events` via `operationId`. Shipped on safer-ops `98f6047 "traceability"` and backend branch `feature/device-ops-observability` (`8086ac0fb`).

Still open: route-level log gaps (#77); #20 surface-to-support is BLOCKED — the `AuditEvent` model is unwired in source (only a stale `dist/repository.js` writes it), so it needs audit *writes* (#12) first. See [[saferops-ci-pnpm-packagemanager]].
