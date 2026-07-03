# Plan: Client editing via the proposal pipeline (MCP propose + guarded apply)

## Context

The operational MCP toolset is live but **read + 4 safe actions only** — the agent
can't change a client. The user wants conversational edits ("summarise this thread
and add a note that they prefer no Wednesdays", "schedule Andrea Tuesdays 9am").

The app is **review-first**: client changes enter as *proposals* an operator
accepts, never as direct writes. So the agent plugs into that pipeline — it
**drafts** proposals (which mutate nothing until applied), and can **apply only
low-risk kinds** (notes / standing facts); schedule / status / contact / address
changes are drafted by the agent but must be applied in the web UI.

Decision (locked by user): **propose + guarded apply**, auto-apply limited to
low-risk kinds. All new tools are guarded writes (named OAuth operator only,
audited, per-call approval in ChatGPT) — except the read-only proposal listing.

Reuses existing services (no new pipeline):
- `createManualClientRegistryProposal(clientId, text)` — drafts from plain English via the same extractor the UI uses (`client-registry-proposal-draft-service.ts:200`).
- `createGmailClientRegistryProposal(clientId, threadId)` — drafts from a thread; **takes the internal `EmailThread.id`** (`:222`), so resolve `gmailThreadId` → id first.
- `applyClientRegistryProposal(proposalSetId, { itemIds, appliedBy })` — applies a draft (`client-registry-proposal-apply-service.ts:84`).
- Proposal item kinds: `notes | standing_fact | schedule | event | contact | address` (`ClientRegistryProposalItem.kind`).

## Changes

### New tools — `src/mcp/tools/proposal-tools.ts` (registered in server.ts)

Read:
1. **`list_client_proposals(clientId)`** — draft / partially_applied sets for a
   client with their items: `{ setId, sourceType, status, items: [{ id, kind,
   operation, status, explanation, confidence, warnings }] }`. So the agent can
   show what's pending and get ids to apply. New thin query (or reuse the proposal
   query service) in a small `src/services/client-proposal-read-service.ts`.

Guarded writes (operator-only via `registerWriteTool`):
2. **`propose_client_change(clientId, text)`** → `createManualClientRegistryProposal`.
   Returns the drafted set + items so the agent can read back what it proposed.
   Audit `roster.proposal.created`.
3. **`propose_from_thread(clientId, gmailThreadId)`** → resolve internal thread id
   (`prisma.emailThread.findFirst({ where: { gmailThreadId } })`) →
   `createGmailClientRegistryProposal`. Covers "summarise this thread → propose".
   Audit `roster.proposal.created`.
4. **`apply_proposal({ proposalSetId, itemIds? })`** → load the set's targeted
   items; **proceed only if every targeted item's `kind` ∈ {notes, standing_fact}**,
   else return an error pointing to the UI ("this proposal includes
   schedule/status/contact/address changes — review and apply those in the web
   UI"). On pass, call `applyClientRegistryProposal(proposalSetId, { itemIds,
   appliedBy: operator.email })`. Audit `roster.proposal.applied`.

`LOW_RISK_KINDS = new Set(["notes", "standing_fact"])`. The kind check loads items
by `proposalSetId` (+ optional `itemIds`) before applying.

### Knowledge — `src/mcp/instructions.ts` + `docs/operator-playbook.md`
- Add the propose-first workflow: resolve client (`find_client`) → optionally read
  (`get_thread`) → `propose_client_change` / `propose_from_thread` → review with
  `list_client_proposals` → `apply_proposal` (notes/facts) **or** tell the operator
  to apply schedule/status changes in the UI.
- State clearly: drafting changes nothing until applied; auto-apply is limited to
  notes/standing-facts.

### Audit
- Reuse `roster.proposal.created` / `roster.proposal.applied` (already in
  `AUDIT_ACTIONS`). **No new audit actions, no DB migration.** Add `clientId` /
  `kind`-free safe keys to `AUDITABLE_ARG_KEYS` if useful (`proposalSetId` stays
  redacted as an id).

## Out of scope
- Auto-applying schedule / status / contact / address proposals (UI only).
- Direct (non-proposal) client mutation. Bulk apply across clients.

## Verification
1. **Build/typecheck** `npm run build`.
2. **Integration (extend `test/integration/mcp.test.ts`, `it.skipIf(!dbReachable)`):**
   - Tool list grows by 4 (23 → 27); the 3 new writes have `readOnlyHint:false`,
     `list_client_proposals` is read-only.
   - `propose_client_change` (operator) drafts a set with items + writes a
     `roster.proposal.created` audit row; service-token caller is rejected.
   - **apply guard:** seed a proposal with a `schedule` item → `apply_proposal`
     returns the UI-only error (nothing applied); seed a `standing_fact`/`notes`
     item → `apply_proposal` applies it and writes `roster.proposal.applied`.
3. **Local boot smoke** (static token = read-only): `list_client_proposals` returns
   shape; a write tool is rejected for the static token. (Full propose→apply needs
   an operator token / OAuth, exercised in tests.)
4. **Prod (user commits/pushes; CI deploys, no migration):** in ChatGPT, "find
   client X, summarise the latest thread and propose a note that they prefer no
   Wednesdays" → draft appears (and in the web review queue); "apply that note" →
   applied + audited to the operator; "schedule Andrea Tuesdays 9am for them" →
   drafts a schedule proposal but apply is deferred to the UI.
