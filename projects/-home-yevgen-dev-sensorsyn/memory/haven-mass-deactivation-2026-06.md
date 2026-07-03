---
name: haven-mass-deactivation-2026-06
description: "INCIDENT (RECOVERED 2026-06-10): partial CSV import deactivated all 1178 pre-existing Haven properties + closed 242 jobs; restored exactly via PITR clones. Durable lesson: Sensor import = FULL-portfolio-snapshot reconcile"
metadata:
  node_type: memory
  type: project
  originSessionId: 3121effc-806f-44f1-950b-cfb41e9c42eb
---

**Closed incident.** Full timeline + recovery detail archived to
`docs/investigations/2026-06-04-haven-mass-deactivation-and-recovery.md`;
extracts/pre-images/SQL in `backups/incident-20260604/`.

**Durable lessons (the reason this memory exists):**
- **Sensor CSV property import = FULL portfolio snapshot.** Any existing agency
  property absent from the file is deactivated (immediately if non-ACTIVE; ACTIVE
  ones via `tbl_property_review` + a ~48h sweep). Collateral: open jobs auto-CLOSED
  ("Property no longer in Sensor Global"), SIM deactivation attempted. NEVER upload
  a partial CSV without the guards — [[property-import-safety-tooling]] is mandatory.
- The same reconcile runs UNGUARDED in the daily PropertyMe/PropertyTree syncs
  (standing risk; per-agency off-switch = `tbl_import_source.status=0`).
  `tbl_admins.autoDeactivation` only changes timing (immediate vs 48h review).
- **Recovery lever:** `tbl_properties.previousStatus` preserves the pre-deactivation
  status exactly → restorable via `status=previousStatus`; closed jobs identified by
  rejectReason + completionDate. RDS PITR clones = clean source of truth.
- 2026-06-10 restore: 1178 properties, 242 jobs, 2118 alarms — 0 mismatches vs
  clone; all 902 hub SIMs unaffected. T+48h re-check was pending at write time.

See [[haven-property-import-2026-06-05]], [[csv-import-email-throttle-aborts-finalize]].
