# Plan: Rename a client (inline pencil on the name header)

## Context

There is currently **no way to rename a client** in the app. `Client.clientName`
is set once (manual `createClient`, roster-sheet import, or seed) and is then
immutable: the profile PATCH endpoint explicitly rejects any field outside
`notes`/`primaryContact`/`primaryAddress` ("Use client registry proposals to
change operational client fields."), and the name renders as a static header
heading with no edit affordance. To fix a typo or a changed legal name today you
must edit the DB directly or delete + recreate. The request: add a proper,
first-class rename — an inline pencil next to the client-name title, mirroring the
existing address/contact pen.

### Why this is safe (investigated)
Every related table (ClientScheduleEntry, ClientStandingFact, ClientOperationalEvent,
ClientEmailEvent, ClientContact, ClientAddress, registry proposals/sources,
WorkerInvoiceLine, ProviderMatchReview) references the client by **`id` (FK)**, not
by name. Email→proposal matching resolves to `clientId`; the LLM only receives the
name as throwaway context. So a rename touches exactly one column: `Client.clientName`.

### Two real constraints (handled below, not engineered around)
1. **Unique key** `@@unique([serviceProviderId, clientName])` (`prisma/schema.prisma:416`)
   — a rename must reject a collision with a friendly error.
2. **Roster-import idempotency** keys on `serviceProviderId_clientName`
   (`roster-import-service.ts:108`). A *future* sheet import listing the old name would
   re-create it as a duplicate. Per the user, future sheet imports are unlikely — this
   is documented as a known caveat, not guarded in code. (Same applies to the
   `seed-standing-facts.ts` provider+name fallback for re-running old JSONL inputs.)

### Decisions
- **Placement**: inline pencil next to the client-name title in the header (drawer
  `<h2>` and page `<h3>`), confirmed with user.
- **Backend**: extend the existing profile PATCH path (add `clientName` to the
  whitelist) rather than a new endpoint — reuses route, audit, refetch plumbing.
- **Audit**: reuse `AUDIT_ACTIONS.clientUpdated`; include an old→new name snapshot in
  the audit metadata so a rename is traceable (identity change).

## Backend changes

### 1. `src/types/api-roster.ts`
Add `clientName?: string | null;` to `UpdateClientProfileInput` (~line 322).

### 2. `src/services/roster-client-profile-service.ts`
- **Whitelist** (`parseUpdateClientProfileInput`, line 125): add `"clientName"`.
- Parse it: trim, reject empty/whitespace-only (`clientName must not be empty.`).
  Reuse the `parseProfileStringField` helper, then enforce non-null/non-empty
  (unlike notes, the name cannot be cleared). Add `parsed.clientName` to the result.
- **`updateClientProfile`** (line 146):
  - Inside the transaction, when `clientName` is present and differs from
    `client.clientName`, do a **collision check**:
    `tx.client.findFirst({ where: { serviceProviderId: client.serviceProviderId, clientName: next, id: { not: clientId } }, select: { id: true } })`.
    On hit, abort with a friendly error. Implement by having the `$transaction`
    callback return a discriminated result (e.g. `{ kind: "collision" }`) or throw a
    typed sentinel caught outside; map it to
    `{ ok: false, error: "Another client with that name already exists." }`.
  - Set `clientData.clientName = next` so the existing `tx.client.update` at line 224
    persists it (no new write needed).
  - The existing best-effort `flagPendingEmailProposalsAsStale` (line 235) already runs
    for any profile edit — applies to renames too, no change.
- `findUnique` at line 151 already loads the client record, which includes the scalar
  `serviceProviderId` needed for the collision check.

### 3. `src/routes/api-roster-routes.ts`
The `PATCH /roster/clients/:id` handler is already generic and needs **no structural
change**. Enrich the audit metadata so a rename is legible: when
`parsed.clientName` is set, include `{ fields, renamedTo: parsed.clientName }` (and,
if cheap, the previous name — surfaced from the `updateClientProfile` result; otherwise
just `renamedTo`). Keep `AUDIT_ACTIONS.clientUpdated`.

## Frontend changes

### 4. `client/src/api-roster.ts`
No new fn — `updateClient(id, fields)` already sends arbitrary
`UpdateClientProfileInput`. `clientName` rides along once the type includes it.

### 5. Thread the save handler to the header
The header (`ClientDetailHeaderPanels.tsx` `ClientDetailHeader`) currently receives
`client` + `saveMsg` but **no save callback**. The existing `saveProfile`
(`ClientDrawer.tsx`, used by both drawer and page variants — already calls
`load()` refetch + `onClientUpdated` + sets `saveMsg`) must be passed down:
`ClientDetailContent` → `ClientDetailSections` (passes it today to the record-summary
section) → also pass to `ClientDetailHeader` as `onSaveProfile`.

### 6. Inline name editor in the header — `ClientDetailHeaderPanels.tsx`
- Add optional `onSaveProfile?: ProfileSaveHandler` prop.
- Local `useState` `editingName` toggle (header owns its own edit state; the
  record-card editors are independent).
- **Read mode**: render the existing `<h2>`/`<h3>` title plus a small pencil button
  beside it (reuse the `EditIcon` exported from `client-current-summary-profile.tsx`
  and the `client-current-edit-button` class used by the address pen). Only show the
  pencil when `onSaveProfile` is provided (so any read-only header stays clean).
- **Edit mode**: replace the title with a single `<input>` seeded from
  `client.clientName` + the shared `ProfileEditorActions` (save ✓ / cancel ✕). On
  submit: `await onSaveProfile({ clientName: trimmed })` then exit edit mode; on
  empty input disable save. Errors (incl. name collision) surface via the existing
  `saveMsg` line already rendered at `ClientDetailHeaderPanels.tsx:63` — `saveProfile`
  sets `saveMsg` to the server error and throws, so the editor stays open. The
  refetched `client.clientName` repaints the title automatically.
- Minor CSS: a flex wrapper so the input + actions sit on the title row (the drawer
  already has `client-drawer-title-row`; the page variant uses an inline flex style).
  Add a small rule in `client/src/styles/client-detail-current.css` only if needed
  for input width.

## Key files
- `src/types/api-roster.ts`
- `src/services/roster-client-profile-service.ts` (whitelist + parse + collision check)
- `src/routes/api-roster-routes.ts` (audit metadata only)
- `client/src/components/client-detail/ClientDetailHeaderPanels.tsx` (pencil + editor)
- `client/src/components/ClientDetailSections.tsx` (pass `onSaveProfile` to header)
- `client/src/components/client-current-summary-profile.tsx` (reuse exported `EditIcon` / `ProfileEditorActions` / `ProfileSaveHandler`)
- `client/src/styles/client-detail-current.css` (optional input sizing)

## Reuse (don't reinvent)
- `updateClient` (`client/src/api-roster.ts`) — generic PATCH client fn.
- `saveProfile` / `load()` / `onClientUpdated` (`ClientDrawer.tsx`) — save + refetch + saveMsg.
- `ProfileEditorActions`, `EditIcon`, `ProfileSaveHandler` (`client-current-summary-profile.tsx`).
- `flagPendingEmailProposalsAsStale` (already wired in `updateClientProfile`).
- Collision-check shape mirrors `migrateClient`'s existing check (`roster-service.ts:400`).

## No DB migration
Pure use of an existing column — **no Prisma schema change, no migration.** (Unlike
the schedule-editing change, this is push-and-go once code lands.)

## Verification
1. Server + `client/` typecheck/build clean.
2. `/run` the app, open a client drawer: click the new pencil by the name → edit →
   save → title updates, "Saved" shows, drawer/list reflect the new name after refetch.
3. Rename to a name already used by another client of the **same provider** → expect
   the friendly "Another client with that name already exists." error, editor stays open,
   no write.
4. Empty/whitespace name → save disabled / rejected.
5. Confirm a rename **flags pending email proposals stale** (same as an address edit).
6. Confirm related data is intact post-rename (schedule, facts, events still attached —
   they key on `id`).
7. Confirm the audit log records the rename (action `client.updated`, metadata includes
   `renamedTo`).
8. Unit test: extend `parseUpdateClientProfileInput` coverage for `clientName`
   (accepts trimmed name, rejects empty); add a collision-rejection case for
   `updateClientProfile` if a service-level test harness exists.
