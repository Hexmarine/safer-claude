---
name: sensorinsure-corpsure-integration
description: "SensorInsure IS a full code product (CorpSure/SGUA landlord insurance) — wired across backend/Angular/Odoo, crons still firing, commercially dormant since ~2026-04; full detail in docs/investigations/2026-07-03"
metadata: 
  node_type: memory
  type: project
  originSessionId: 74a2b629-d58c-4074-988b-4a4a499aff0c
---

**SensorInsure = a real, fully-wired landlord-insurance integration**, not just
the WordPress site ([[sensorinsure-product-status]] covers the marketing-site
infra; its old "no code product" claim was wrong). Authoritative detail:
`docs/investigations/2026-07-03-sensorinsure-corpsure-integration-review.md`.

**Model:** landlord redirects their existing annual building & landlord premium
to CorpSure (broker) / SGUA (underwriter); CorpSure pays Sensor **$14.99/mo per
insured property** (weekly consolidated Odoo invoice), landlord's subscription
zeroed via −$14.99 rebate products (Odoo product ids 45/46) + "free" hardware.
Two funnels: `insurance_first` (insurance hook acquires the property) vs
`providerPays` (upsell to existing customer; wins if both flags set).

**Live state (measured 2026-07-02):** wired but dormant. 53 agencies flagged;
3,787 invites → 304 submissions → **2 policies ever issued** (2025-03) → 9
invoices (last 2025-07). Activity collapsed 2026-04. CorpSure sync cron (external
infra cron → `/users/properties/sync-corpsure-insurance-data`) and Odoo weekly
"corpsure data - SaaS sync" cron both still fire; feature flags in LaunchDarkly
(`insuranceViaAPI`, `CorpsureAutoAcceptance`).

**Gotchas if touched:**
- `res_company.insurance_contact` NULL everywhere → weekly CorpSure billing has
  no payee (latent break for any revival).
- NEXU enrichment is a stub — `getPropertyDetailsFromNexu` never called,
  `nexuData` always `[]`. `MANUAL_CORPSURE_API` flag dead.
- `syncCorpsureInsuranceData` swallows errors (empty catch) and aborts the whole
  loop on first non-200; CorpSure auth can hang on 200-without-token.
- CorpSure/NEXU env vars (incl. misspelled `CORPSURE_ISURANCE_DATA_URL`) missing
  from `.env.example`.
- Consumed invites are DESTROYED → funnel analytics unrecoverable.

**Direction (2026-07-04):** any revival is driven from the SAFERHOMES side
(safer-ops), not Sensor — reuse Sensor as-is, change it only where tailoring
requires; prefer the proven pattern of additive Sensor endpoints (Class A) +
safer-ops UI/schedulers over Class-C edits to shared core
(`properties.entity.ts`).

**Why it stalled (diagnosis):** timing (offers fire at invite, not at the
landlord's insurance-renewal window) + funnel break (redirect to CorpSure's
hosted form; unanswerable rebuild-cost questions that NEXU was meant to
pre-fill). Top revival levers: renewal-date-triggered offers (the
`Properties.currentPolicyExpiryDate` field already exists) and wiring NEXU.
