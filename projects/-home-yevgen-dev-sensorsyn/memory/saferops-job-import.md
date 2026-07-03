---
name: saferops-job-import
description: "The safer-ops bulk JOB import (work orders) — ops CSV/xlsx column contract, how it maps to Sensor POST /users/jobs, and the jobTime-epoch / contractor-by-name / maintenance-products gotchas"
metadata: 
  node_type: memory
  type: project
  originSessionId: f36d7861-f9b5-4f62-af73-178ecb331372
---

Building a **job (work-order) import** into safer-ops (chosen 2026-06-06 over a
one-off script) so ops can bulk-create jobs against EXISTING properties. Distinct
from the property import ([[haven-property-import-2026-06-05]]).

**Ops file shape** (`ops-and-extracts/Job Import Test .xlsx`, sheet "Job Import"):
`Property Information` (="`<propertyId>, <address>`", id is GIVEN), `Job Type`
("Maintenance"…), `Due Date` (Excel serial), `Contractor Information`
("Syncom Pty Ltd (Electrician)" — a BUSINESS name, not email/id), `Job Code`
(e.g. `EXRSA1HSWL1`, internal work-scope code, no system field → fold into notes),
`Job Requirement` (free text → notes). 2nd sheet "Other job data" is reference
(device counts, scope flags) — not imported.

**Architecture (existing):** browser parses sheet (SheetJS) →
`POST /api/jobs/import/preview` {rows} → server `resolveRows` (pure: property by
address+postcode, installer by EMAIL, jobType hardcoded INSTALLATION) → operator
confirms → `/commit` → `sensorClient.createJob` → Sensor `POST /users/jobs`.
Depot-persona only; commit needs `appMode==="prod-controlled-write"`. Files:
`apps/api/src/job-import.ts` (resolver), `job-import-routes.ts` (routes),
`apps/web/src/lib/spreadsheet.ts` (parser), `apps/web/src/views/BulkJobView.tsx`
(UI), types in `packages/shared/src/index.ts`.

**The extension (this workstream):** accept the ops shape — propertyId-given
(skip address match, just scope-check), `jobType` string→enum, contractor
by-name (match installer `businessName`/`name`, strip "(trade)" suffix), Job
Code+Requirement→notes.

**Gotchas (verified in code):**
- `jobTime` is `tbl_jobs.jobTime` **BIGINT NOT NULL = epoch MILLISECONDS**
  (`Help.ts:1513` currentTimeStamp = `moment().unix()*1000`), stored verbatim by
  the entity (no conversion). The EXISTING importer passes ISO date strings →
  latent bug (BIGINT truncates "2026-…" to 2026). Fix = normalize jobTime→epoch
  ms server-side in the commit route (Excel serial / ISO / epoch all → ms).
- `createJob` (sensor-client.ts:296) has exactly ONE caller (the import commit),
  so changing its jobTime/jobType handling can't destabilize the kit flow.
- `JOB_TYPE` enum (sensor app.ts:313): INSTALLATION=1, MAINTAINANCE=2 (note
  spelling), ADD_PRODUCT=3, RECONNECTION=4.
- Maintenance job (type 2) CAN be created with an empty `products[]` — the
  controller (`jobs.controller.ts:152-170`) only validates alarmIds IF products
  are present. So a notes-only maintenance job is valid; device-linked products
  (real alarmId/locationId on the property) are a later enhancement, not derivable
  from this CSV.
- Sensor enforces ONE open job per property (`jobs.controller.ts:198-206`); the
  importer marks/“duplicate”s on a pre-existing open job.
- Our import token = HHS login [[haven-ops-login-59256]] (agency 37413); commit
  re-checks every propertyId is in the agent's scoped property list.

**Contractor matching = STRICT (decided 2026-06-06).** No fuzzy/auto-guess
(honors the repo's "never guess a write" rule). Resolver matches installer by
email first, else by EXACT normalized businessName/name (parenthetical trade
suffix like "(Electrician)" is stripped). If it doesn't match → `bad_installer`;
ops must fix the sheet (exact registered business name, or the installer email).

**Verified against prod 2026-06-06 (tunnel reads, run by Eugene):**
- Property **21753** = CHAN23/118, agency **37413** ✓, agent 39423, status 1
  (ACTIVE) → in scope for our HHS token, won't hit property_out_of_scope.
- Syncom assignable tradeperson under 37413 = **id 53410, business_name
  "Syncom Group Pty Ltd", email jack.davis@syncom.com.au** (tbl_costing-linked).
  A 2nd "Syncom" (59123 Kristyn Heywood) is NOT costing-linked to 37413 so it's
  absent from the agency-scoped installer list (no cross-agency collision).
- GOTCHA proven: the ops sheet's "Syncom Pty Ltd" ≠ registered "Syncom **Group**
  Pty Ltd" → strict match fails. To import the test job, set the sheet's
  Contractor to "Syncom Group Pty Ltd" OR email jack.davis@syncom.com.au.

**tradeperson-list path gotcha (fixed 2026-06-06):** safer-ops `listInstallers`
called `/users/tradeperson-list` → **404** with our agency token. Correct path is
the double-nested `/users/users/tradeperson-list` (registered in
sensor-alarm-backend routes/users/v1/users.routes.ts under `AdminUserAuth`; the
inner `/users` is the usersRoutes mount → `/api/v1/users/users/tradeperson-list`).
The single-segment path doesn't exist; `/api/v1/admins/users/tradeperson-list` is
the super/sub-admin `AdminAuth` variant (423 for agency tokens). Both call the
same entity `users.entity.ts:2360 getTraderpersonList` (BusinessDetails include,
costing-scoped to the agency).

**VALIDATED E2E in prod 2026-06-06:** job **6384** created via the safer-ops
Bulk-job UI (depot login 59256) from `ops-and-extracts/job-import-2026-06-06.csv`.
tbl_jobs row confirmed: propertyId 21753, jobType 2, jobTime **1785456000000**
(=2026-07-31, epoch-ms conversion proven), tradePersonId 53410, agentId 39423
(auto from property), agencyId 37413, status 1, notes
"[EXRSA1HSWL1] Remove smoke alarm, hub swap & install water leak detector",
createdBy 59256. GOTCHA seen on the way: ops first exported sheet2 (reference
data) not sheet1 (the import format) → all-invalid; must use sheet1's columns.

**Codex review (2026-06-06):** [P2] commit accepted any int jobType → FIXED
(commitRowSchema now refines jobType to the JOB_TYPE enum + route test). [P1]
unrelated: `/api/monitor` (live-monitor workstream, routes.ts:189) lacks the
depot persona gate — flagged to that stream, not this change.
