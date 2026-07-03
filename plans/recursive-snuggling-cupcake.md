# Feature: Propose creating a NEW client from an email (resolve new_service / new-client disambiguation)

## Context

When an email contains a `new_service` (or schedule_change) for a person who is **not yet a client**, the pipeline today:
- extracts the event correctly, tags it with the `clientName`,
- creates a `ProviderMatchReview` (`reviewType: "uncertain_client_match"`) so it appears in the **Identify** queue,
- but **silently drops** that event at the routing step (`routeRegistryItemsToClients` keeps only exact ≥0.85 matches), so the schedule/contact/address it extracted are thrown away.

A "Create New Client" path already exists in the Identify UI (`ClientCreateDrawer`, pre-filled with the extracted **name** only). The end-to-end already half-works: operator creates the client → resolves the review → the existing deferred `createGmailClientRegistryProposal` re-extracts and now routes the schedule/contact to the new client.

**Gaps this closes:**
1. **No proactive signal** — a brand-new name looks identical to a misspelling of an existing client; the operator must eyeball candidate scores.
2. **Extracted onboarding data is discarded** — the create form only pre-fills the name; address/contact/schedule from the same email are lost and must be re-typed.

**Decisions made with the user:**
- **Onboarding = reuse path + prefill.** Flag likely-new in the Identify queue; pre-fill the create form with extracted name + address + contact; the schedule lands via the existing post-resolve proposal (operator applies it). No new proposal kind; the apply path is unchanged.
- **Trigger = low score + service event.** Flag likely-new only when the best candidate is below ~0.6 **and** the review has a service-implying event (`new_service`/`schedule_change`).
- **Extraction-stage answer:** stop discarding unmatched items — stash them on the review as onboarding hints, making prefill deterministic (no extra LLM call). Extraction logic itself is otherwise unchanged.
- Client creation stays **operator-confirmed** (never auto-create).

## Approach

### 1. Persist onboarding hints on the review (extraction stage) — stop discarding
- Add nullable JSON column `onboardingHintsJson Json?` to `ProviderMatchReview` (`prisma/schema.prisma`, ~line 660). Migration auto-applies in CI (see [[prod-migrations-separate-from-app-deploy]]).
- Populate it where the review is created. The review is built in `upsertClientEmailEvents` (`src/repos/client-event-repo.ts:267-283`) from operational events only. To also capture address/contact, pass the thread extraction's `standingFacts` into that function from `identifyAndExtract` (`src/services/roster-update-service.ts`), and when creating a non-exact review attach hints:
  - `clientName`, `serviceEvents`: the dropped service-implying ops for this name (day/time/duration/worker/serviceType/recurrence),
  - `address` / `contact`: the structured fields from `standingFacts` whose `clientName` matches (these already carry structured `address`/`contact` via `enrichStandingFactsWithStructuredContacts`).
- Keep hints small (the few fields the create form + a schedule preview need), not the raw LLM blob.

### 2. Classify "likely new client" (queue-build stage)
- Add a pure helper `classifyLikelyNewClient(item)` (next to the queue builder in `src/services/analysis-identify-service.ts`): returns `true` when **(top `candidateClients[].confidence` < `NEW_CLIENT_CANDIDATE_THRESHOLD` (0.6), or no candidates) AND `groupedEvents` contains a type in `SERVICE_IMPLYING_EVENT_TYPES`** (`new_service`, `schedule_change`; tunable — consider `worker_change`, `extra_service`).
- Surface on the API type: add `likelyNewClient: boolean` and `onboardingHints` (name/address/contact/scheduleSummary) to `IdentifyReviewItem` (`src/types/api-analysis.ts:20`); populate both in `getIdentifyQueue`. Data is already in the payload (`confidence`, `candidateClients`, `groupedEvents`) plus the new `onboardingHintsJson`.

### 3. Surface the suggestion + prefill (UI stage)
- In the Identify review row (`client/src/components/RosterAnalysisSections.tsx` + its content/renderer), when `likelyNewClient` is true, render a prominent **"Looks like a new client — create"** CTA at the top of the review (today the action is buried in the `...` menu via `handleOpenCreateClient`). Keep the candidate list visible so the operator can override to an existing client.
- Extend `ClientCreateDrawer` (`client/src/components/ClientCreateDrawer.tsx`) with `initialAddress`/`initialContact` props; pass them from `item.onboardingHints`. Show the extracted **schedule** read-only ("will be drafted as a proposal after creation") so the operator knows it isn't lost.

### 4. Create + resolve (reuse — no extraction-stage rework)
- Unchanged. `createClient` (`src/services/roster-service.ts:350`) → `handleClientCreated` pre-selects the new client → operator clicks **Resolve** → `resolveIdentification` (`src/services/analysis-identify-service.ts`) sets the thread provider, accepts the review, and the existing deferred `createGmailClientRegistryProposal` re-extracts → the schedule/`new_service`/contact now route to the now-existing client → proposal drafted → operator applies.
- `isStub`: leave `false` (the field has no promotion lifecycle; the client is fully real once the operator fills the form). Note as deliberate non-use.

### Out of scope
- No new `new_client` proposal kind and no change to the proposal **apply** path (apply still only mutates existing clients).
- No auto-creation; everything is operator-confirmed.
- Optimization (later): reuse `onboardingHintsJson` inside `createGmailClientRegistryProposal` to skip the post-resolve re-extraction.

## Critical files
- `prisma/schema.prisma` — `onboardingHintsJson` column on `ProviderMatchReview`.
- `src/repos/client-event-repo.ts` — attach hints when creating the non-exact review (accept `standingFacts`).
- `src/services/roster-update-service.ts` — pass extraction `standingFacts` into `upsertClientEmailEvents`.
- `src/services/analysis-identify-service.ts` — `classifyLikelyNewClient` + populate `likelyNewClient`/`onboardingHints` in `getIdentifyQueue`.
- `src/types/api-analysis.ts` — extend `IdentifyReviewItem`.
- `client/src/components/RosterAnalysisSections.tsx` (+ content/renderer) — prominent CTA when likely-new; pass hints to drawer.
- `client/src/components/ClientCreateDrawer.tsx` — `initialAddress`/`initialContact` + schedule preview.

## Verification
1. `npx tsc -p tsconfig.json --noEmit`.
2. Unit tests:
   - `classifyLikelyNewClient`: low score + `new_service` → true; high score → false; low score + contact-only event → false; no candidates + `new_service` → true.
   - hints population: a non-exact review for a name with a `new_service` op + address/contact standing facts persists `onboardingHintsJson` with those fields; an exact match persists none.
   - `getIdentifyQueue` maps `likelyNewClient`/`onboardingHints` onto the item.
3. Local e2e against the prod snapshot (see [[clients-refactor-and-local-surface]]): pick/synthesize a thread naming a non-existent client with a `new_service`, run `postProcessThreadRoster`, confirm the Identify queue item has `likelyNewClient: true` + populated hints; create the client; resolve; confirm a schedule proposal is drafted for the new client.
4. Prod migration auto-applies via CI on merge; no manual step.
