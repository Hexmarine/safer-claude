---
name: sim-provider-omondo
description: "SIMs in hubs today are Omondo pre-activated, not KORE — there is no live SIM-activation step in the install flow."
metadata: 
  node_type: memory
  type: project
  originSessionId: ddbb32c0-32fd-480f-b0df-04d317f10ea7
---

Hubs in production today ship with **Omondo SIMs** that are **pre-activated**.
There is **no SIM activation step** in the canonical install flow — the hub
just connects to LTE on first power-up.

**Why:** The KORE-based activation flow described in older docs (e.g.
`docs/investigations/2026-05-02-sim-activation-flow.md`, which talks about a
`ready → active` transition on controller install) reflects an earlier
provider relationship that is no longer in use. The current fleet uses
Omondo, which simplifies install (no activation API call, no `simStatus`
state machine on the critical path).

**How to apply:**
- When mapping the install flow, **do not** include a SIM-activation step or
  treat `tbl_alarms.simStatus` transitions as part of the on-site install
  critical path.
- Treat `2026-05-02-sim-activation-flow.md` and any KORE references as
  historical context, not current behaviour. Flag the discrepancy if asked
  to update install-flow docs.
- If the user later asks about SIM provisioning, billing, or carrier
  switching, this is the current reality — Omondo, pre-activated.

**Legacy units still carry KORE/Twilio SIMs (verified 2026-05-26):** older
hubs (e.g. serial `000000000892C0012304`, created 2023) have a Twilio Super SIM
(`simId` "HS…" prefix) on the KORE platform, reactivated via
`alarmEntity.changeSimStatus(simId, ACTIVE)` (calls the carrier API; gated to
`sid.startsWith("HS")`) during `installationJob`. Such a unit found in the wild
showed `simStatus=inactive`, last connection Dec 2024 → its blue comms light
flashes forever and it never answers a VERIFY (needs ~3 min to go *solid* blue
when healthy). So: a hub that won't connect on the bench is likely a legacy
KORE unit with a deactivated SIM — **not** an Omondo pre-activated one. Pick an
Omondo unit for prepared-kit testing; don't try to bench-test legacy KORE hubs
without carrier-side SIM reactivation.

**SIM swap KORE→Omondo on already-installed hubs (analyzed 2026-05-30): safe, "just works".**
The hub is identified everywhere by its **serial**, never the SIM — MQTT topics
`sg/sas/{cmd,resp}/{serial}` (`subscriber.ts`), one global broker credential,
online/offline + alarms + commands all serial-keyed. Nothing in *ongoing*
operation reads `simStatus` or the carrier. So a physical swap to a pre-activated
Omondo SIM (power-cycle, confirm a VERIFY round-trips) keeps the hub working.
- **The only hard KORE coupling is the NATIVE install gate**: `addControllerOnProperty`
  calls `verifySim(simId)` → KORE API → rejects `402 SIM_NOT_EXIST` if not in KORE
  (`alarms.entity.ts:1701`). It fires ONLY at (re)install — a swap doesn't re-run it.
  **safer-ops attach does NOT call verifySim** (no gate) → that's why fresh Omondo
  installs "just work" via safer-ops. ⚠️ Do NOT native-reinstall a swapped hub, and
  the admin "Reset SIM" (`alarms.controller.ts:2878`, gated `simStatus==ACTIVE` + pokes
  KORE) won't work for it — use safer-ops or relax the gate.
- **No Omondo API integration exists** — backend only knows KORE. Swapped hubs keep
  stale `tbl_alarms.simId/simStatus` (old "HS…" KORE values); harmless but meaningless.
- **Billing SIM hooks are non-throwing/benign**: `changeSimStatus` (`alarms.entity.ts:2365`)
  catches internally and *returns* the error (and `!startsWith("HS")` just returns) — it
  never rejects. Invoice-paid/suspend handlers (`invoiceSetting.controller.ts:209/426`,
  property decommission, jobs.entity) `await` it but ignore the result and re-VERIFY the
  device over MQTT regardless → a swapped hub at most logs a KORE error + a cosmetically
  stale "SIM activated/{oldSimId}" line. No handler abort, no device impact.
- **Cleanup after swap**: suspend/cancel the displaced KORE SIMs (stop billing — the swap
  tells KORE nothing); optionally null the stale simId. Clean end-state for the JV = make
  the install gate provider-agnostic / drop KORE verify+billing (migration project, not
  needed for the swap itself).

See [[installation-flows-old-and-new]], [[sensor-write-auth-agency-token]].
