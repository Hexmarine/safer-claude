---
name: installation-flows-old-and-new
description: Two smoke-alarm install flows — existing native-app on-site pairing vs the new safer-ops pre-paired-kit flow we are building.
metadata: 
  node_type: memory
  type: project
  originSessionId: 37a45498-e9ae-422d-b657-dcf4449c5278
---

The platform is moving smoke-alarm installation from on-site pairing to
depot-prepared kits.

**Existing flow (production):** Agency → TradePerson → ServiceStaff job. Installer
uses the **native mobile app** on-site; `POST /users/v1/alarms` →
`installationJob`; the hub RF-pairs its sensors **at the property** (slow/flaky
step), then backend `VERIFY` → `ALARMS` → `syncAlarmList`. Already documented in
`docs/diagrams/flow-job-lifecycle.puml`, `flow-device-installation.puml`,
`flow-alarm-test.puml` and `docs/investigations/2026-04-09-{platform-architecture-and-data-flow,alarm-event-traces,mqtt-device-communications}.md`
+ `2026-05-02-sim-activation-flow.md` — no separate write-up needed.

**New flow (in progress — our work):** `code/safer-ops` (the "sensor-ops"
service: React PWA + Fastify + Prisma/MySQL, SaferHomesAu org). Kits (1 hub + N
sensors) are pre-paired & tested in a depot. As of 2026-05-28 the depot does NOT
reserve a kit to a property — kits are **fungible** and sit in an open ready pool;
the installer picks any ready kit on-site and **attach** binds it to the job's
property/owner. See [[prepared-kit-fungible-pool-pivot]] (supersedes the old
depot-`reserved`-to-job step). Apply/attach → safer-ops → sensor API
`/device-operations/pre-paired-verifications` → poll → `/attach`. The sensor-API
side is the `deviceOperations` feature on branch `feature/additional-pairing-mode`
of `sensor-alarm-backend` (verify → match-gate → attach; attach reuses
`installationJob`). safer-ops has `mock` / `prod-readonly` /
`prod-controlled-write` modes.

**Why:** This is the active build. Direction is sound (pairing moves off-site).

**How to apply:** When discussing "the new flow" / "pre-paired kits" / "device
operations", this is it. Known risks before production: no on-site recovery when
a kit fails verification (`MISMATCHED` is terminal); `subscriber.ts` swallows
interception errors (must fail-open); the "pre-pairing survives storage/transit"
assumption is unverified (3rd-party firmware); maintenance/replacement-job scope
unclear; two install paths will coexist and need a boundary. Recommended: ship as
an additive greenfield-only option with the native app as fallback first.
Durability & recovery plan (strict-now-extensible-later, recovery ladder, phased):
`docs/investigations/2026-05-20-installation-flow-durability-plan.md`.
See [[sensorglobal-saferhomes-jv]].
