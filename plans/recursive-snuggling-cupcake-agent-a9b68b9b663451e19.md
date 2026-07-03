# Plan: Fix silently-lost registry proposal drafts (Bug 1) + investigate extractor divergence (Bug 2)

## Root cause (confirmed)
`identifyAndExtract` (src/services/roster-update-service.ts:271-293) drafts proposals inside a
`setImmediate(bindLogContext(...))` loop — fire-and-forget. `postProcessThreadRoster` is itself
launched fire-and-forget via `void postProcessThreadRoster(...)` in thread-persistence.ts:281.
On Cloud Run (default request-scoped CPU; deploy.sh and ci.yml set neither `--no-cpu-throttling`
nor `--min-instances`), CPU is throttled once the HTTP response is sent, so the tail of
deferred `setImmediate` drafts never run → `ClientEmailEvent` rows exist but no
`ClientRegistryProposalSet`. The full-reprocess loop already awaits postProcess serially
(roster-reprocess-service.ts:326-334), so only the inner `setImmediate` keeps it from being
deterministic — which is why reprocess-roster.ts still needs its count-stabilization poll.

## Recommendation for requirement #2: Option (a) — await `postProcessThreadRoster`
Change `void postProcessThreadRoster(...)` to `await postProcessThreadRoster(...)` in
thread-persistence.ts. Rationale:
- `postProcessThreadRoster` already try/catches internally and never throws, so awaiting it
  cannot break the sync loop (sync-service.ts:133 stays safe; the existing "marks run failed
  when persistence fails" test is unaffected because postProcess swallows its own errors).
- The full-reprocess and reprocess-roster paths already run postProcess serially per thread, so
  serialization is an established, tolerated cost — Option (a) makes the auto-sync path match.
- Hourly incremental runs are low-volume (~107 threads at the high end, usually far fewer). The
  added cost per thread is dominated by DB work (extraction already ran before drafting; drafting
  in createGmailProposalFromExtractedItems does NOT re-call the LLM). No extra LLM call is added
  by awaiting.
- Option (b) (return the promise, collect, Promise.allSettled in sync loop) preserves throughput
  but adds plumbing through PersistThreadResult and the sync loop, and the throughput win is
  marginal at this volume. Not worth the surface area now. Note Option (b) for a future change if
  full-reprocess timeouts ever become a concern.
- Job timeout risk: full reprocess already serializes postProcess today, so Option (a) adds no new
  timeout risk beyond the existing reprocess path. The hourly job stays well within limits.

## Bug 1 — ordered implementation steps

### Step 1 — Await drafting inside `identifyAndExtract`
File: src/services/roster-update-service.ts (lines ~271-303).
Replace the `setImmediate` loop with a collected-promise + `Promise.allSettled` block, keeping
per-client error isolation:

- Build the matched client id set as today (`matchedClientIds`).
- For each clientId, push a promise calling `createGmailProposalFromExtractedItems({...})` with the
  SAME args currently passed. Wrap each in try/catch (or rely on allSettled) so one failure does
  not abort others. `createGmailProposalFromExtractedItems` returns `{ ok, itemCount, error? }`
  and does not throw on the not-found path, but the LLM-free DB writes can throw — keep the catch.
- `const settled = await Promise.allSettled(draftPromises);`
- Tally outcomes: `draftedCount` (ok && itemCount>0), `emptyCount` (ok && itemCount===0),
  `failedCount` (rejected OR ok===false). For each failure, emit `logger.error({ threadId,
  clientId, error/err }, "auto-draft registry proposal failed")` (error-level, not warn — see
  Step 3).
- Remove the now-unused `bindLogContext` import (line 1) — `Promise.allSettled` runs inside the
  existing `withLogContext` scope from `postProcessThreadRoster`, so log context is preserved
  without per-callback binding. Verify no other use (grep already confirms line 273 is the only
  use besides the import).

Signature of `identifyAndExtract` stays `Promise<void>`. `createGmailProposalFromExtractedItems`
signature is unchanged (src/services/client-registry-thread-proposal.ts:19).

### Step 2 — Await post-processing in the request lifecycle
File: src/services/thread-persistence.ts line 281.
Change:
    void postProcessThreadRoster({ threadId, gmailAccountId, thread });
to:
    await postProcessThreadRoster({ threadId: persistedThread.id, gmailAccountId: params.gmailAccountId, thread: params.thread });
Keep it AFTER the `store.transaction(...)` commit (drafting reads committed ClientEmailEvent /
provider rows). `persistThreadSummary` already returns `Promise<PersistThreadResult>`; no
signature change. The sync loop at sync-service.ts:133 already awaits `persistThreadSummary`, so
post-processing now completes before runMailboxProcessing returns and before the /jobs/process
response is sent (jobs.ts:18-23).

Note: the in-memory store test (thread-persistence.test.ts) does NOT stub postProcessThreadRoster.
With Option (a) it will now actually invoke postProcess → resolveProvider / prisma. Must guard:
see Step 5 (inject postProcess as an option or mock the module) so the unit test stays hermetic.

### Step 3 — Make draft failures visible (pragmatic)
- In `identifyAndExtract`, extend the existing `roster.post_process.completed` log
  (roster-update-service.ts:295-303) with `draftedCount`, `emptyProposalCount`,
  `draftFailedCount`.
- Emit `logger.error` per failed client (replacing the swallowed `logger.warn(... "skipping")`).
- Lightweight persistent signal: do NOT add a new table. If a durable signal is wanted, reuse the
  existing `providerMatchReview` stub pattern only if it fits; otherwise the structured error log
  on the `roster.post_process.completed` event + per-failure error logs are sufficient and
  greppable in Cloud Logging. Keep it pragmatic — no new schema this round.

### Step 4 — reprocess-roster.ts cleanup (optional, low-risk)
File: scripts/reprocess-roster.ts. Once drafting is awaited, the count-stabilization poll
(lines 139-147) and the header comment (lines 16-18) about setImmediate are obsolete. Optionally
remove the poll and update the comment. Not required for correctness; safe to leave but the
comment will be misleading. Recommend updating the comment at minimum.

## Bug 2 — investigation steps (no full fix required this round)
Two stranded threads drafted EMPTY sets when remediated via `createGmailClientRegistryProposal`
(re-extraction path) although the thread-level extractor had produced a `public_holiday_cancel`
and a `new_service`. Two distinct draft paths exist:
- Auto-sync: `extractThreadRegistryItems` (thread-level, multi-client, no re-extract) →
  `createGmailProposalFromExtractedItems` → `normalizeExtractedRegistryItems` →
  `filterExtractionAgainstAcceptedState` → mappers (client-registry-thread-proposal.ts:33-57).
- Manual/per-thread: `createGmailClientRegistryProposal` (client-registry-proposal-draft-service.ts:222)
  → `getClientDraftInput` → `draftClientRegistryProposalFromExtractor`
  (client-registry-proposal-drafter.ts:354) which RE-CALLS the LLM via
  `extractRegistryItemsWithLlm` (note-style, per-client) then `filterExtractionAgainstAcceptedState`.

Investigation (read-only; use roster:reprocess --subject on the two known threads against the local
90-day snapshot DB, and add temporary debug logging only in a throwaway branch — do not commit):
1. Re-run `extractThreadRegistryItems` for the two threads; confirm it still yields
   public_holiday_cancel / new_service (baseline).
2. Run `createGmailClientRegistryProposal` for the same (client, thread); capture the re-extraction
   LLM raw output. Determine whether the note-style per-client extractor emits the items at all
   (LLM divergence) vs emits-then-dropped.
3. If emitted: check `filterExtractionAgainstAcceptedState` — was the event already in
   `recentOperationalEvents` (isSameRegistryOperationalEvent) or the fact in
   `acceptedStandingFacts` (registryStandingFactKey)? The accepted-state dedupe
   (client-registry-accepted-state-dedupe.ts:20-37) is the most likely silent dropper because by
   the time of manual remediation the auto-sync ClientEmailEvent may already count as "recent".
4. If still present after filter: check the mappers
   (mapRegistryOperationalEventToProposalItem / mapRegistryStandingFactToProposalItem) for
   public_holiday_cancel / new_service handling, and normalizeExtractedRegistryItems for the
   auto path.
5. Conclusion to reach: which stage drops each item (re-extraction LLM vs normalize vs accepted-
   state filter vs mapper).

Recommendation to evaluate: unify the manual/per-thread regenerate path to REUSE
`extractThreadRegistryItems` (the thread-level extractor) instead of re-extracting per client —
i.e. have `createGmailClientRegistryProposal` route through the same
`createGmailProposalFromExtractedItems` path used by auto-sync. This removes the extractor
divergence entirely and is the likely correct long-term fix; scope/sequence it after Bug 1 lands
and after the investigation pinpoints the stage (so we know unification actually resolves it and
isn't masking an accepted-state-filter issue that would affect both paths).

## Tests to add / update
Existing patterns:
- test/unit/thread-persistence.test.ts — in-memory store injected via `options.store`; does NOT
  stub postProcessThreadRoster (relies on it being fire-and-forget today).
- test/unit/sync-service.test.ts — `createMailboxProcessingRunner(overrides)` with
  `persistThreadSummary` fully mocked; asserts run results and that failures mark the run failed.
- roster-update-service.ts has NO direct unit test today (only roster-reprocess-service.test.ts,
  roster-thread-classifier.test.ts, etc. nearby).

Changes:
1. thread-persistence.test.ts — make hermetic under Option (a). Either (preferred) add an injectable
   `postProcessThreadRosterFn` option to `persistThreadSummary` defaulting to the real import, and
   pass a `vi.fn()` in the existing two tests; OR `vi.mock("../../src/services/roster-update-service.js")`
   at top of the test file. Then add a NEW test asserting the injected postProcess fn is awaited
   (called and resolved) BEFORE persistThreadSummary resolves — e.g. resolve a deferred promise and
   assert ordering, proving no setImmediate reliance.
2. New test/unit/roster-update-service.test.ts (or extend) for `identifyAndExtract`:
   - Mock `extractThreadRegistryItems`, `resolveProvider`, `upsertClientEmailEvents`,
     `createGmailProposalFromExtractedItems`, and prisma client lookups.
   - Assert: after `identifyAndExtract` (or postProcessThreadRoster) RESOLVES,
     `createGmailProposalFromExtractedItems` has ALREADY been awaited for every matched client
     (call count == matched client count) — i.e. synchronous-on-resolve, no setImmediate. Use fake
     timers WITHOUT advancing them to prove drafts don't depend on a deferred tick.
   - Assert per-client error isolation: one rejected/`{ok:false}` draft does not prevent the
     others from being called, and `draftFailedCount` is logged (spy on logger.error).
   - Assert the `roster.post_process.completed` log includes draftedCount / emptyProposalCount /
     draftFailedCount.
3. sync-service.test.ts — no change strictly required (persistThreadSummary is mocked there). Keep
   the "marks run failed when persistence fails" test as the guard that awaiting postProcess does
   not change run-failure semantics (postProcess never throws, so unaffected).

## Cloud Run config (secondary hardening)
deploy.sh (lines 68-90) and ci.yml (lines 100-108) deploy WITHOUT `--no-cpu-throttling` and
WITHOUT `--min-instances`, so CPU is request-scoped (throttled after response) — this is what made
the fire-and-forget drafts die. The await fix removes the dependency on post-response CPU, so this
is secondary. Optional hardening (one of):
- Add `--no-cpu-throttling` (CPU always allocated) to deploy.sh deploy_args and the ci.yml
  `gcloud run deploy` flags — protects any future fire-and-forget work but increases cost.
Recommendation: do NOT change infra as the primary fix; the await change is sufficient and
deterministic. Optionally note `--no-cpu-throttling` as defense-in-depth in the PR description but
leave it out unless the team wants the cost tradeoff.

## End-to-end verification
1. Unit: `npx vitest run test/unit/thread-persistence.test.ts test/unit/roster-update-service.test.ts test/unit/sync-service.test.ts` (and full `npm test`).
2. Local DB (90-day prod snapshot): start local DB (scripts/db-start.sh). Re-run the two known
   stranded threads:
   `npm run roster:reprocess -- --subject "<thread A subject>" --subject "<thread B subject>"`
   With the await fix, the script's final JSON `generated.proposalSets`/`proposalItems` should be
   correct WITHOUT relying on the stabilization poll. Confirm a `ClientRegistryProposalSet` (draft)
   now exists for the (thread, client) pairs that previously had only ClientEmailEvent rows
   (e.g. the permanent_cancel surfaces).
3. Broader: `npm run roster:reprocess -- --limit 20` and confirm proposalSets count matches matched
   clients deterministically across two runs (idempotent: createGmailProposalFromExtractedItems
   deletes existing draft set first, thread-proposal.ts:61-63).
4. Query DB to assert: for each thread with ClientEmailEvent rows produced this run there is a
   corresponding draft ClientRegistryProposalSet (no stranded pairs) — this is the Bug-1 acceptance
   check.

## Critical files for implementation
- /home/yevgen/dev/symphony/email-ops-summary/src/services/roster-update-service.ts
- /home/yevgen/dev/symphony/email-ops-summary/src/services/thread-persistence.ts
- /home/yevgen/dev/symphony/email-ops-summary/src/services/client-registry-thread-proposal.ts
- /home/yevgen/dev/symphony/email-ops-summary/test/unit/thread-persistence.test.ts
- /home/yevgen/dev/symphony/email-ops-summary/scripts/reprocess-roster.ts
