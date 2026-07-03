# Service Type as a managed entity

## Context

"Service type" (personal_care, individual_social_support, transport, …) is the
category attached to a client's schedule line and to extracted operational
events. Today it is a **hardcoded const** (`REGISTRY_SERVICE_TYPES`, 7 values)
duplicated across server contracts, a client-side label map, and the LLM prompt
text — plus two hardcoded matching functions (abbreviation normalization and
free-text inference). Adding or renaming a type, or teaching the pipeline a new
shorthand (e.g. "ISS"), requires a code change and a deploy.

We are promoting service type to a **global, admin-managed entity** editable in
Settings. Decisions locked with the user: **(1) Full scope** — the entity is the
single source of truth for the dropdown, display labels, write validation, the
LLM prompt vocabulary, and normalization; **(2) Editable aliases** per type,
seeded from today's abbreviation map and injected into the prompt; **(3) Global**
— one shared list (matches today's single const).

The design constraint that shapes everything: `normalizeRegistryServiceType` and
`inferRegistryServiceTypeFromText` are **synchronous** and called from hot paths
(`client-registry-llm-mapper.ts:32`, `gemini-provider-helpers.ts:430`,
`client-registry-proposal-apply-schedule.ts`, `-proposal-preview.ts`,
`-note-extractor.ts`, `roster-client-schedule-service.ts:122`). To avoid making
all those async, we back them with an **in-memory cache** hydrated from the DB,
keeping the existing exported function names/signatures so call sites don't
change. The hardcoded list stays in the codebase as the **seed + fallback**.

Invoice validation does **not** read serviceType today — no impact there.

## Approach

### 1. Schema + migration
- New global model in `prisma/schema.prisma`:
  ```
  model ServiceType {
    id        String   @id @default(cuid())
    value     String   @unique   // canonical slug, e.g. "personal_care"
    label     String              // display, e.g. "Personal care"
    aliases   String[] @default([]) // ["pc", "personal care"]
    sortOrder Int      @default(0)
    isActive  Boolean  @default(true)
    createdAt DateTime @default(now())
    updatedAt DateTime @updatedAt
  }
  ```
  Global (not scoped to gmailAccount/provider). `serviceType` columns on
  `ClientScheduleEntry` / `ClientOperationalEvent` / `ThreadItem` /
  `CurrentReportEntry` stay as free `String?` — **no FK**, so existing rows and
  soft-deactivated types never break. Deactivation = `isActive=false` (soft),
  never hard-delete, so historical references still resolve a label.
- `npx prisma migrate dev --name add_service_type_entity`. CI auto-runs
  `prisma migrate deploy` on push to main — just commit the migration folder.

### 2. Seed
- Add a seed step (extend `src/db/seed.ts`) that upserts the 7 current values,
  each with `label` from `client/src/lib/serviceTypes.ts` and `aliases` derived
  from the current `normalizeRegistryServiceType` map (e.g. personal_care →
  `["pc"]`, individual_social_support → `["iss","ss","social support"]`,
  general_cleaning → `["gc"]`, domestic_assistance →
  `["da","home care","cleaning"]`, spring_cleaning → `["carpet"]`). Idempotent
  upsert keyed on `value`. Seed runs locally; for prod, run the seed once
  post-migrate (note in handoff).

### 3. Server registry service + cache (the core)
- New `src/services/service-type-registry.ts`:
  - module-level cache: `ServiceTypeRow[]` + derived `Map<value,label>` and an
    alias→value map (aliases + value + spaced label all fold to the canonical
    value).
  - `refreshServiceTypeCache()` (async) loads active rows from DB; called at
    boot and after every mutation.
  - **Sync** accessors backed by the cache: `listServiceTypes()`,
    `getServiceTypeVocabulary()` (for the prompt), `labelForServiceType(value)`,
    and the matching logic.
  - **Fallback**: if the cache is empty (cold start before hydration), fall back
    to the hardcoded `REGISTRY_SERVICE_TYPES` + built-in alias map, so sync
    callers never see an empty list.
- Refactor `src/services/client-registry-contracts.ts`: keep
  `REGISTRY_SERVICE_TYPES` (now the **seed/fallback default**), and rewrite
  `normalizeRegistryServiceType` / `inferRegistryServiceTypeFromText` to delegate
  to the registry cache (data-driven alias + keyword matching) while preserving
  their **exact names and sync signatures**. This is why none of the ~8 call
  sites need edits. `RegistryServiceType` type relaxes to `string` (validated at
  runtime against the cache) — check for type fallout at the call sites that
  import the literal union.
- Hydrate cache at boot: call `refreshServiceTypeCache()` in `src/app.ts` /
  `src/index.ts` startup (non-blocking; fallback covers the race).

### 4. LLM prompt — dynamic vocabulary
- Inject the live vocabulary into the prompt **payload** (not the static text),
  mirroring how `partialDatePolicy`/`currentSchedules` are passed:
  add a `serviceTypes` field to `RegistryPromptPayload` in
  `src/services/client-registry-prompt-builder.ts`
  (`buildRegistryPromptPayload`) = `getServiceTypeVocabulary()` →
  `[{value,label,aliases}]`.
- In `src/summarization/prompts/extract-registry-note-items.txt`, replace the
  hardcoded "Service terminology: ISS means…" block (lines ~94–97) with a
  generic instruction: "Use only canonical serviceType values from the
  `serviceTypes` list in the payload; map the listed aliases to their canonical
  value." Apply the same to `extract-thread-registry-items.txt` and ensure that
  extractor's payload also carries `serviceTypes`.

### 5. API routes (admin CRUD, reuse noise-list pattern)
- In `src/routes/api-roster-routes.ts` (next to the noise-list block ~480–538):
  - `GET /roster/service-types` — list (read, no admin gate; used by client UI)
  - `POST /roster/service-types` — create (`requireAdminApi`)
  - `PATCH /roster/service-types/:id` — edit label/aliases/sortOrder/isActive (admin)
  - `DELETE /roster/service-types/:id` — deactivate (soft) (admin)
  - Each mutation calls `refreshServiceTypeCache()` and `recordAudit(...)`.
- Service-layer CRUD lives in `service-type-registry.ts` (or a thin sibling),
  validating `value` is a unique slug and aliases are normalized lower-case.

### 6. Client UI
- `client/src/lib/serviceTypes.ts`: keep `SERVICE_TYPE_OPTIONS` as a **fallback
  seed**; add a `setServiceTypeOptions(rows)` hydrator and have
  `serviceTypeLabel` read the hydrated map (so labels render before fetch, then
  refine). 
- `client/src/api-roster.ts`: add `getServiceTypes()`, `createServiceType()`,
  `updateServiceType()`, `deleteServiceType()`.
- Hydrate the options on app load (fetch `GET /roster/service-types` where the
  roster workspace / settings bootstrap) → `setServiceTypeOptions`. The dropdown
  in `client/src/components/client-current-summary-profile.tsx:665` and the
  formatters in `clients-workspace/AllClientsFormatters.ts` then reflect live
  data with zero structural change.
- New `ServiceTypesSettingsSection` in
  `client/src/pages/settings/SettingsPageSections.tsx`, modeled on
  `NoiseListSettingsSection`: list rows; add (value+label+aliases); edit
  label/aliases/sort; activate/deactivate toggle. Wire into `SettingsPage.tsx`.

## Critical files
- `prisma/schema.prisma` — new `ServiceType` model + migration
- `src/services/service-type-registry.ts` — **new**, cache + sync accessors + CRUD
- `src/services/client-registry-contracts.ts` — delegate normalize/infer to cache; const becomes seed/fallback
- `src/services/client-registry-prompt-builder.ts` — inject `serviceTypes` into payload
- `src/summarization/prompts/extract-registry-note-items.txt` + `extract-thread-registry-items.txt` — generic vocabulary instruction
- `src/routes/api-roster-routes.ts` — CRUD routes (noise-list pattern)
- `src/db/seed.ts` — seed 7 types + aliases
- `src/app.ts` / `src/index.ts` — boot hydration
- `client/src/lib/serviceTypes.ts` — hydrator + fallback
- `client/src/api-roster.ts` — API client fns
- `client/src/pages/settings/SettingsPageSections.tsx` (+ `SettingsPage.tsx`) — settings section

## Untouched on purpose
- Invoice validation (no serviceType usage today)
- The ~8 sync call sites of `normalizeRegistryServiceType` / `inferRegistryServiceTypeFromText` (names/signatures preserved)
- DB columns stay free `String?` (no FK, no data migration)

## No-degradation sweep (before/after LLM classification)

Hard requirement: the change must not degrade how the pipeline classifies
serviceType. The `registry-notes-harness` (`npm run registry:notes`) runs the
real extraction over notes from the local DB / email snapshot and emits
`serviceType` per operational event as JSON (`case-loader.ts:379`,
`output.ts:372`).

- **Baseline (before):** on `main` (or pre-change worktree state), run the
  harness against the local 90-day snapshot with `--json --out-dir
  artifacts/svc-before` over a fixed, broad case set (`--from-db` /
  `--from-email-db`, no client filter, fixed model + concurrency for
  determinism). Capture serviceType per (case, event).
- **After:** rerun identically into `artifacts/svc-after` once the entity +
  cache + prompt-injection changes are in (with the DB seeded so the cache is
  populated).
- **Diff:** compare per-event serviceType across the two runs. Pass criterion:
  no event that previously resolved to a valid type now resolves to `null` or a
  different type. Any value-string drift (e.g. label-casing) must map to the
  same canonical value. Write a small diff step (or `jq`) over the two JSON
  artifacts keyed by case id + event index.
- **Gap log:** while diffing, record classification **gaps** — events left
  `null`, free-text that clearly implies a type the model missed, aliases the
  current logic doesn't catch, and any value the model emits that isn't in the
  canonical set. Surface these as a short findings list (candidate new
  aliases/types) — do not silently fix; report them with the after-results.

## Verification
1. Run the no-degradation sweep above; before/after diff shows no regressions.
2. `npx prisma migrate dev` applies cleanly; run seed → 7 rows present with aliases.
2. **Type safety / build:** `npm run build` (server) + client build pass after the `RegistryServiceType`→`string` relaxation.
3. **Schedule write:** in the client detail schedule editor, the dropdown lists DB types; saving a row persists the canonical value; an unknown value is rejected (`roster-client-schedule-service.ts` path).
4. **Settings CRUD:** add a new type (e.g. `meal_preparation`, alias "meals") in the new Settings section → it appears in the schedule dropdown without a redeploy; deactivating hides it from the dropdown but existing rows still render their label.
5. **Pipeline/alias:** run a manual registry proposal (`POST /roster/clients/:id/proposals/manual`) with text using the new alias ("meals") → extracted event maps to `meal_preparation`. Confirms cache-backed normalization + prompt injection. Use the local DB's 90-day prod snapshot for realistic input.
6. **Audit:** confirm mutations write AuditLog rows.
