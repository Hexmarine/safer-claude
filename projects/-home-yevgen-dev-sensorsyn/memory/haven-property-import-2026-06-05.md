---
name: haven-property-import-2026-06-05
description: "The 23-property Haven Home Safe CSV import (done 2026-06-05) — column contract, no-fake-email tenant trick, and the NEW-status outcome"
metadata: 
  node_type: memory
  type: project
  originSessionId: f36d7861-f9b5-4f62-af73-178ecb331372
---

Added 23 properties (the "Bell St Preston / Lorraine St Frankston / White Cl
Lilydale" batch) to Haven Home Safe (agency 37413) via the CSV importer, using
our own login [[haven-ops-login-59256]]. Source + built file in
`ops-and-extracts/` (`Haven Home Safe Properties to be Added at 3.06.26.csv` ->
`haven-import-2026-06-05.csv`). Result: 23 properties, 20 leases (= 20 occupied;
3 vacant), 22 tenants all lease-linked, geocoded, 0 errors.

**CSV column contract that actually works** (importer = `uploadProperties` ->
`processUploadProperties` -> `checkPropertyAndAddUpdate`):
- `PROPERTY_ADDRESS` (required; geocoded to suburb/state/postcode automatically),
  `PROPERTY_ID` (**required** — maps to property `title`; missing it fails EVERY
  row with "Missing PROPERTY_ID"), `PROPERTY_GUID` (the dedupe/match key). We set
  PROPERTY_ID = PROPERTY_GUID = the agency's Property Reference (e.g. BELL320/101).
- **No-fake-email tenants:** the tenant block fires on `TENANT_GUID_1` OR
  `TENANT_EMAIL_1`. Supplying `TENANT_GUID_1` (+ NAME/PHONE/PHONE_CODE, no email)
  creates the tenant with email NULL — so we attached name+phone with zero fake
  emails and nothing to clean up. GUID pattern used: `HHS-<ref>-T<n>`. Secondary
  tenant = `*_2` columns (two rows had two tenants, one shared phone).
- Pad every row to the full header width or csvtojson drops fields.

**Upload flow (API, with our token):** `POST /api/v1/users/presigned_url`
`{files:[name]}` -> PUT bytes to the returned S3 url -> `POST
/api/v1/users/properties/upload-property` `{csvFile:name}` with header
`access_token: bearer <id_token>`. Returns 201 immediately; processing is async.
NOTE the route is `/users/presigned_url` (accountRoutes mounts at `/`, NOT
`/users/accounts/...`).

**Outcome status:** properties land at `PROPERTY_STATUS.NEW` (4) BY DESIGN
(properties.entity.ts:12850) — this is the normal "awaiting agency review/accept"
state, not stuck. They get activated (-> status 1) when accepted in the portal.
To bypass review and land ACTIVE directly, add a `PROPERTY_STATUS=1` column
(honored at :12851). Import-file record `tbl_property_files.id=20921` is stuck at
status 0 due to [[csv-import-email-throttle-aborts-finalize]] (cosmetic; data is
intact).
