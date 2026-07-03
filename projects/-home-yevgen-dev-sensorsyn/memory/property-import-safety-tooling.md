---
name: property-import-safety-tooling
description: "MANDATORY guard scripts around any Sensor property CSV upload: scripts/property-import-preflight.sh (blast-radius diff BEFORE upload) + property-import-postcheck.sh (48h emergency brake AFTER); runbook docs/runbooks/14-property-import-safety.md"
metadata: 
  node_type: memory
  type: project
  originSessionId: 3121effc-806f-44f1-950b-cfb41e9c42eb
---

Built 2026-06-10 after [[haven-mass-deactivation-2026-06]]. The Sensor CSV property import is a FULL-SNAPSHOT reconcile — any agency property whose GUID isn't in the uploaded file gets deactivated (ACTIVE ones after a 48h `tbl_property_review` grace, the rest immediately; open jobs closed, SIM-deactivation attempted). Errored uploads still reconcile.

**Why:** a 23-row file nuked Haven's 1,178-property portfolio; nothing in the product warns at upload time.

**How to apply — around EVERY property CSV upload** (env: `source ./scripts/load-prod-env.sh` + mysql tunnel):
- BEFORE: `./scripts/property-import-preflight.sh <file.csv> <agency-id>` — parses the CSV's **PROPERTY_GUID** column (the reconcile key; PROPERTY_ID is only the title) and diffs against live GUIDs using the backend's own selection (`status NOT IN ('0','11')`). Exit 2 + full missing list = DO NOT UPLOAD. Also flags dup/empty GUIDs and GUIDs owned by another agency (conflict path).
- AFTER: `./scripts/property-import-postcheck.sh <agency-id>` — file-row counts, status distribution, and pending sweep targets (`tbl_property_review` status=0 + isCurrentImport=1) with hours-left; prints (never executes) the `isCurrentImport=0` emergency-brake SQL that saves the ACTIVE wave if run within 48h.

Both read-only; validated against the real incident data (preflight on the incident CSV reproduces exactly 1,178 missing / 900+278 split). Full procedure incl. PITR recovery shape: `docs/runbooks/14-property-import-safety.md` (indexed in runbooks README).

**Portal gotcha found while verifying recovery:** the agency portal's "Added On" column actually binds `updatedAt` (sensor-angular `property/property-list/property-list.model.ts` ~54) — after any bulk touch the whole list shows that date as "Added On". Cosmetic; `createdAt` is intact.
