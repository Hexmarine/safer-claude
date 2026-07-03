---
name: sensor-audit-history-mongo
description: "Where property \"Audit History\" data actually lives in Mongo and how to query it read-only from prod"
metadata: 
  node_type: memory
  type: project
  originSessionId: b38afd56-c669-467d-9776-233dc9ca5f6c
---

The admin property page "Audit History" tab + "Export Pdf" read from MongoDB
Atlas, main db `sensorproddb`, collection **`tbl_audit_histories`** (PLURAL,
~2.42M docs). The sensor-alarm-backend code/model name is the SINGULAR
`tbl_audit_history` — Mongoose auto-pluralizes to the physical collection, so
querying the literal singular via the native driver returns count:0 / empty
(false negative). `estimatedDocumentCount` on the whole collection is the tell.

Fields: propertyId is a **Number** (not string); `type` ∈ {Event, Email, Job,
Notes, Alert, Sms, Action}; Events carry `eventType` (VERIFY/TEST/ADD/ALARMS/
TAMPERED/BATTERY/ALERT/POWER/REMOVE/HUSH). `hideFromAuditHistory: true` rows are
filtered OUT of the UI tab and the PDF export (getAuditHistoryToExport excludes
them) — so the visible history is fewer than the raw count; it's a filter, not a
delete. PII lives in nested `createdBy`/`to` ({name,email,phone}) + `agency`;
`subject` is descriptive event text (no contact PII).

Archive: the secret also has `MONGO_DB_ARCHIVE_URL` (a SEPARATE Atlas cluster,
~52.64.205.136). getAuditHistory reads main + archive, but the archive cluster
REFUSES connections from the API instance IP — our diag path sees main only.
Fine for recent properties; old rows could be archive-only and invisible.

How to read it (Atlas blocks the workstation IP, allows the app servers): run
on the prod API instance via SSM — `scripts/diag/prod-read.py` /
`sensor-prod-read.js` (see [[sensor-prod-read-diag-tooling]]). Export PDF
mechanics (puppeteer + pdf-merger, async email via S132): in the code, see
[[sensor-outgoing-comms-map]].

Example: property 23796 = 535 rows (37 hidden), 2026-05-03 → 2026-06-19.
