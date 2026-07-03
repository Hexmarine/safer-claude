---
name: client-rename
description: "Clients can be renamed via an inline pencil on the detail header; goes through the profile PATCH whitelist, FK-safe, one import caveat"
metadata: 
  node_type: memory
  type: project
  originSessionId: 0382c8cc-8c8a-4e2a-965b-5ec85c8273f1
---

Implemented 2026-06-14: operators can rename a client via an inline pencil next to
the client-name title in the detail **header** (drawer `<h2>` / page `<h3>`), mirroring
the address/contact pen. `ClientNameEditor` lives in
`client-detail/ClientDetailHeaderPanels.tsx`; `onSaveProfile` (the existing
`saveProfile` in `ClientDrawer.tsx`) is threaded down through `ClientDetailSections`.

**Backend reuses the profile PATCH path** — NOT a new endpoint. `clientName` was added
to the `parseUpdateClientProfileInput` whitelist (`roster-client-profile-service.ts`)
and to `UpdateClientProfileInput` (`src/types/api-roster.ts`). `updateClientProfile`
does a collision pre-check inside its transaction against
`@@unique([serviceProviderId, clientName])` AND `.catch()`es a P2002 on the
transaction (concurrent-rename TOCTOU fallback, mirrors createClient) — both
return "Another client with that name already exists." instead of a 500. Audit
reuses `AUDIT_ACTIONS.clientUpdated` with `metadata.renamedTo`.

**Why it's safe:** every related table (schedule, facts, events, proposals, contacts,
addresses, invoices, match reviews) references the client by `id` (FK), not name; email
matching resolves to `clientId`. So a rename only touches `Client.clientName` — no
migration needed (existing column).

**Known caveat (not guarded):** roster-sheet import upserts on
`serviceProviderId_clientName` (`roster-import-service.ts`), so a *future* sheet import
listing the old name would re-create it as a duplicate. User deemed future imports
unlikely. Same applies to `seed-standing-facts.ts`'s provider+name fallback for
re-running old JSONL.

**Side fix:** `saveProfile`'s catch used to hardcode "Save failed", swallowing the
server error message (`requestJson` in `api-core.ts` throws on non-2xx with the
server's `error` as the Error message, so the `if (!res.ok)` branch was dead code). Now
it surfaces `err.message` — so collision (and any other server validation) reasons show
in the drawer's saveMsg line. Affects all profile edits (address/contact/notes), strictly
better. Relates to [[manual-schedule-editing]].
