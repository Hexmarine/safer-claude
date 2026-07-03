# Add "Sync Deputy data" button to the Worker Invoices page

## Context

Refreshing Deputy reference data (employees / locations / areas) currently lives only in Settings → Deputy ("Sync reference data" button). Operators working on invoice validation need fresh Deputy data right where they use it — e.g. when a new worker or area was just added in Deputy and the invoice dropdowns don't show it yet. The ask: duplicate that refresh action as an additional button on the Worker Invoices page.

## Existing pieces to reuse (no new API)

- `syncDeputy()` — `client/src/api-deputy.ts:34` → `POST /api/deputy/sync` (admin-gated, `src/routes/api-deputy-routes.ts:71`; the page already calls other admin endpoints like worker-mappings, so no new auth concern).
- Settings handler to mirror: `handleDeputySync()` in `client/src/pages/SettingsPage.tsx:352-373` — toast on success with employee/location/area counts, toast on error, `syncing` flag.
- `loadDeputyEmployees()` already on the page (`client/src/pages/InvoicesPage.tsx:91-101`) — re-run after sync so the worker/area dropdowns pick up new data.
- Button styling: `ghost-button small-button icon-button`, same as the existing toolbar buttons.

## Change (single file)

`client/src/pages/InvoicesPage.tsx`:

1. Import `syncDeputy` alongside the existing `api-deputy` imports (line 3).
2. Add state `const [syncingDeputy, setSyncingDeputy] = useState(false);`.
3. Add `handleDeputySync()` modeled on the Settings one:
   - `setSyncingDeputy(true)`; call `syncDeputy()`;
   - on `!res.ok` → error toast;
   - on success → `await loadDeputyEmployees()` to refresh the dropdown data, then success toast with the counts (`res.status.counts`), same wording as Settings;
   - catch → error toast; finally → `setSyncingDeputy(false)`.
4. Add the button in the upload toolbar (`shift-import-upload-toolbar`, lines 376-407), next to the import label inside `shift-import-upload-primary` (so it sits with the primary actions and the conditional "Clear" button stays right-aligned):
   ```tsx
   <button
     type="button"
     className="ghost-button small-button"
     onClick={() => void handleDeputySync()}
     disabled={syncingDeputy || uploading}
   >
     {syncingDeputy ? "Syncing..." : "Sync Deputy data"}
   </button>
   ```

No CSS changes needed (toolbar is already a flex row with gap).

## Verification

- `npx tsc --noEmit` in `client/`.
- `npm test` (vitest) — no behavior under test changes, suite should stay green (561 tests).
- Manual: open /invoices, click "Sync Deputy data" → button shows "Syncing...", success toast with counts appears, and the worker dropdown (WorkerMatchPanel) reflects refreshed Deputy employees.
