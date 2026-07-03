---
name: pms-integrations-propertyme-propertytree-status
description: PropertyMe & Property Tree import integrations — architecture + live health; PME has been DEAD since 2026-04-09
metadata: 
  node_type: memory
  type: project
  originSessionId: 611c8e6e-cb71-4ed6-be11-bdcc4591abbb
---

Sensor's two external property-management (PMS) imports live entirely in
`sensor-alarm-backend` (`entities/properties.entity.ts`), both one-directional
(vendor → Sensor) feeding the shared CSV-import pipeline (`processUploadProperties`).
A third source `consolecloud` exists but is enabled only on 4 internal Sensor
test/sandbox agencies (not real tenants). Full write-up:
`docs/investigations/2026-06-24-property-management-integrations-propertyme-propertytree.md`.

**Health check method:** read `tbl_property_files` (every sync writes a batch row;
status string `0`=in-progress/never-finished, `1`=success, `2`=zero-record/fail),
token tables (`tbl_propertyme_api_tokens`, `tbl_propertytree_api_keys`), and the
cron-box crontab. Enablement lives in `tbl_import_source` (source/status/agencyId).
Read-only via `scripts/diag/sql-read.py` → prod-api node i-0690fb2a2654ab2ad.

**Live status as of 2026-06-24:**
- **PropertyMe = BROKEN since 2026-04-09 21:00 UTC (~11 weeks), root-caused 2026-06-24.**
  37 agencies enabled but `tbl_property_files type='propertyme'` has NO row (success or
  fail) since that instant; all 40 tokens still authorized=1 but none refreshed since
  the same instant. ELIMINATED: not cron/route (returns HTTP 200 every min, fire-and-
  forget, no auth mw); not code (git: 0 commits 03-25→04-20); not config (sensor-prod
  secret loaded via libs/secretManager.ts Object.assign onto process.env HAS all 8
  PROPERTYME_API_* + 3 PROPERTYTREE_* keys; on-disk .env is 46-byte stub w/
  SECRET_NAME=sensor-prod). MECHANISM (code): getTokenByRefreshToken swallows err→returns
  undefined → getPropertyMeToken `.data` TypeError swallowed→returns undefined →
  syncPropertyMeCron `if(!token)continue` skips agency silently (PME has no failure-
  ticket/email, unlike PT). CONFIRMED ROOT CAUSE (live refresh probe 2026-06-24,
  test agency 23738 → login.propertyme.com/connect/token): **HTTP 400 invalid_client**.
  Client creds (CLIENT_ID/SECRET both 36-char GUIDs in sensor-prod secret) present & well-
  formed, endpoint correct → PropertyMe has REVOKED/EXPIRED/REGENERATED the OAuth client (or
  deactivated the app) ~Apr9. invalid_client = client rejected before grant ⇒ shared failure
  ⇒ why all 37 died same instant. Probe consumed no token (failed at client-auth, zero side
  effects). FIX (not executed, elevated): get fresh client creds from PropertyMe → update
  PROPERTYME_API_CLIENT_SECRET/ID in sensor-prod Secrets Manager (GO-Secrets Manager) →
  restart api nodes (loads secret at boot via Object.assign, EC2/PM2 not envFrom) → re-probe;
  if then invalid_grant, refresh tokens also expired ⇒ re-authorize all 37 agencies via OAuth
  consent. DURABLE: add PME failure surfacing (none today). Logs useless (app doesn't log
  token SQL; even PT's working queries absent).
- **Property Tree = working for 5 of 13 enabled.** Healthy daily: Taylor & Thomas
  (1701), Blue Fox NSW (36058)/QLD (36245), McFall (39311), Harcourts Signature
  (55586). Stalled: Dowling Medowie (8344, last 2026-06-13). Never sync (0 runs):
  686, Alice PM (3543), 10515, 18469, 30731, Bartrop (38265), 50695 — 5 have null
  business_name so the exact-name match in getPropertyTreeToken can't pass (silent
  skip). PT token row refreshed daily (healthy).

**Why it hid:** both syncs are fire-and-forget 200; PME doesn't even write a failure
row and (unlike PT) has no failure-ticket/email. No end-to-end health signal exists
for either — this was the first check. Haven (37413) is NOT a PMS agency; it uses
`csv` import. Other risks (code-verified): PME full-snapshot reconcile commented out
(`properties.entity.ts:~14366`); PT single shared token row (`:17057`); PT
secondary-tenant off-by-one (`:18229`). See [[haven-mass-deactivation-2026-06]],
[[daily-email-volume-overdue-job-reminders]].
