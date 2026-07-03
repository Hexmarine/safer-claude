---
name: saferops-e2e-verified-2026-05-31
description: Full depot→installer happy path verified end-to-end in prod against real hardware (2026-05-31) + the 8 UX/logic findings raised
metadata: 
  node_type: memory
  type: project
  originSessionId: 37a45498-e9ae-422d-b657-dcf4449c5278
---

On 2026-05-31 the complete prepared-kit flow was driven end-to-end in **prod against real hardware** (hub `000289307390C0012406` + smoke `000000008628A0012405`), observed live across safer-ops logs + MQTT + Sensor DB (see [[saferops-live-trace-rig]]).

- **Depot** (agency.test, persona depot): detach → delete (frees the hub serial) → re-add → pair (a Sensor-`not_found` smoke still pairs fine via firmware ADD — the inventory check is advisory, doesn't gate pairing) → off-site verify → **reset ×2** (idempotent, no drift) → re-pair → re-verify.
- **Installer** (trade.test, login subject 59203 / traderPerson 59123, persona installer): My jobs → accept job 6378 → attach (pre-paired verification op, ~7s) → on-site test (real alarm self-test, ~3 min to report, passed) → complete → **job 6378 → status 5 (Completed)** at property 23814.

Everything traced cleanly; `correlationId` threaded throughout; zero state drift on the happy path.

**8 UX/logic findings raised (tasks #115–#122), all being fixed this session:** #115 off-job test blocked by self-imposed open-job check (Sensor `testAlarm` only needs propertyId; jobId optional) · #116 Devices detach-by-serial leaves the safer-ops kit stale + no reconcile path for completed kits (store drift) · #117 hub vs alarm both labelled "Connected" (should be Connected/Paired) · #118 pairing gesture copy is smoke-specific · #119 native window.confirm → themed in-app dialog · #120 installer My Jobs shows raw/stale status codes · #121 kit lookup double-entry (results + browse not deduped) · #122 "Re-run test" enabled mid-test → duplicate test-alarm fires.
