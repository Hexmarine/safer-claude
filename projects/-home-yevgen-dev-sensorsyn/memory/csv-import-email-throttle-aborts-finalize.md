---
name: csv-import-email-throttle-aborts-finalize
description: Backend bug — an SES 454 throttle during CSV-import post-processing throws an unhandled rejection that aborts finalize (PropertyFiles.status never flips to 1)
metadata: 
  node_type: memory
  type: reference
  originSessionId: f36d7861-f9b5-4f62-af73-178ecb331372
---

In `processUploadProperties` (properties.entity.ts ~14342+), after the per-row
loop creates properties/leases/tenants, it awaits `addPropertyInReviewOnCSVImport`
then `autoInviteNewPropertyAddedIntoSAAS` (sends invite emails) and ONLY THEN
sets `tbl_property_files.status = ACTIVE (1)`. When the email step hits SES
`454 Throttling failure: Maximum sending rate exceeded`, nodemailer throws an
**unhandled** rejection ("originated by ... a promise which was not handled"),
which aborts the chain BEFORE the status flip.

**Symptom:** import data is fully written and correct, but the
`tbl_property_files` record stays `status=0` and invite emails don't send. Seen on
the 2026-06-05 Haven import ([[haven-property-import-2026-06-05]], file id 20921,
errorCount 0). Cosmetic for the data; only the import-history record + invites are
affected. Properties still land at NEW(4) (that's by design, unrelated).

**Why it matters:** email/SES failures should be caught so import finalization
(status flip, dashboard refresh) still completes. Worth a backend fix:
wrap the invite/email post-steps in try/catch. To clear the cosmetic record
manually: `UPDATE tbl_property_files SET status=1 WHERE id=<fileId>`.
