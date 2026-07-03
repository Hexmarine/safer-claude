# Unify Gmail-thread MANUAL extraction with the AUTO thread extractor

## Verdict
Option 1 (swap only the extractor, keep downstream) is correct and minimal. Validated against the code. One refinement: factor the per-client routing into a shared helper and reuse the EXACT same routing in both paths. Recommendation on residual divergence (refineExistingStandingScheduleItems) is below: leave the manual path running it; do NOT move it into the AUTO path.

## Key facts confirmed from code
- thread-extractor already runs enrichStandingFactsWithStructuredContacts (line 91) and enrichment is idempotent (skips facts with .contact/.address). normalizeExtractedRegistryItems does NOT enrich. So feeding pre-enriched thread facts through normalize is safe and avoids a second enrichment call.
- LlmRegistryOperationalEvent/StandingFact already carry clientName?: string|null (llm-provider.ts 117/149).
- matchClientName(name, ClientRow[]) -> { result } with result.kind === "exact" giving result.clientId. ClientRow = {id, clientName}. Exact threshold >= 0.85.
- reconstructThreadFromDb(DbThread) needs: thread {id, gmailThreadId, subject, lastMessageAt, rawLabelsJson, messages[]}; messages {gmailMessageId, fromHeader, toHeader, bodyText, subject, snippet, internalDate}. Already exported.
- createGmailProposalFromExtractedItems (AUTO) builds extraction via normalizeExtractedRegistryItems then filterExtractionAgainstAcceptedState — same two functions Option 1 wants in the drafter preExtracted branch.
- draftClientRegistryProposalFromExtractor downstream for gmail_thread: addManualScheduleEditItem (manual-only, no-op), addGmailAddressUpdateItem (runs, guards double address_update), refineExistingStandingScheduleItems (runs for non-manual), refineManualScheduleEditItems (manual-only, no-op).
- createProposalSetFromDraft deletes existing draft sets by sourceId; createGmailProposalFromExtractedItems dedupes by clientId+threadId+sourceType. MANUAL path keeps its own upsertProposalSource + createProposalSetFromDraft, so dedupe stays sourceId-based (unchanged).

## Step 1 — shared routing helper
New exported function (place in client-event-repo.ts next to matchClientName, OR a small new module; repo file is the natural home since matchClientName lives there):

  export function routeRegistryItemsToClients(
    items: { operationalEvents: LlmRegistryOperationalEvent[]; standingFacts: LlmRegistryStandingFact[] },
    clients: { id: string; clientName: string }[],
  ): {
    opsByClient: Map<string, LlmRegistryOperationalEvent[]>;
    factsByClient: Map<string, LlmRegistryStandingFact[]>;
    matchedNameByClientId: Map<string, string>;
    matchedClientIds: Set<string>;
  }

Body = exactly the inline routeClientId/opsByClient/factsByClient loop from roster-update-service.ts 242-266 (exact match only, record matchedNameByClientId).
Refactor identifyAndExtract to call it (drop the inline version). This proves behavioural equivalence via the existing roster-update-service.test.ts.

## Step 2 — drafter preExtracted branch
Edit draftClientRegistryProposalFromExtractor (drafter.ts:354). Add optional 2nd param:

  preExtracted?: {
    operationalEvents: LlmRegistryOperationalEvent[];
    standingFacts: LlmRegistryStandingFact[];
    rawOutput?: string | null;
  }

When preExtracted is provided, build `extraction` WITHOUT calling extractRegistryItemsWithLlm:

  const normalized = normalizeExtractedRegistryItems({
    sourceType: input.sourceType,            // "gmail_thread"
    clientName: input.clientName,
    rawNote: input.rawText,
    fragments: [],
    currentSchedules: input.currentSnapshot.scheduleEntries.map(e => ({
      recurrenceType: e.recurrenceType, dayOfWeek: e.dayOfWeek,
      startTime: e.startTime, durationMinutes: e.durationMinutes, worker: e.worker,
    })),
    referenceDate: input.referenceDate ? new Date(input.referenceDate) : undefined,
    operationalEvents: preExtracted.operationalEvents,
    standingFacts: preExtracted.standingFacts,
  });
  const extraction = {
    ...filterExtractionAgainstAcceptedState(
      { operationalEvents: normalized.operationalEvents, standingFacts: normalized.standingFacts },
      input.currentSnapshot,
    ),
    rawOutput: preExtracted.rawOutput ?? "",
    unavailable: undefined as boolean | undefined,
    warning: undefined as string | undefined,
  };

This reproduces the {operationalEvents: drafts, standingFacts: drafts} shape extractRegistryItemsWithLlm returns (filterExtractionAgainstAcceptedState returns {operationalEvents, standingFacts}; add rawOutput/unavailable/warning to match). Imports needed in drafter.ts: normalizeExtractedRegistryItems (already imports extractRegistryItemsWithLlm from same module — add to that import), LlmRegistryOperationalEvent/StandingFact types.
Everything after (the items pipeline lines 379-398) is UNCHANGED and consumes `extraction` identically.
Refactor the existing LLM path into the else branch so only the source of `extraction` differs.

## Step 3 — createGmailClientRegistryProposal
Edit draft-service.ts:222. Keep the leading client lookup + mismatch/confirmation_required block intact. After confirmation passes:
(a) Expand the emailThread.findUnique include to the reconstructThreadFromDb shape: add to the top-level select id, gmailThreadId, subject, lastMessageAt, rawLabelsJson; expand messages select to gmailMessageId, fromHeader, toHeader, bodyText, subject, snippet, internalDate (keep clientEmailEvents + resolvedProvider for the existing mismatch checks).
   NOTE: the current findUnique uses `include` (resolvedProvider, clientEmailEvents, messages). reconstructThreadFromDb needs scalar fields too — switch to a `select` that includes BOTH the scalars and the relations, or keep `include` and rely on default scalar selection (include returns all scalars by default, so the thread already has id/gmailThreadId/subject/lastMessageAt/rawLabelsJson). The only real change is the messages sub-select must add gmailMessageId, toHeader, subject, snippet (it currently selects only fromHeader, internalDate, bodyText). buildGmailThreadProposalRawText still works on the richer message rows.
(b) Build provider roster mirroring identifyAndExtract 187-204:
    prisma.client.findMany({ where: { serviceProviderId: client.serviceProviderId }, select: { id, clientName, serviceStatus, scheduleEntries: where isActive select id/recurrenceType/dayOfWeek/worker/startTime/durationMinutes/fortnightlyWeek } })
    map to ClientContextEntry[].
(c) const reconstructed = reconstructThreadFromDb(thread);
    const extraction = await extractThreadRegistryItems({ thread: reconstructed, providerName: client.serviceProvider.name, roster });
(d) Route to THIS client only via the shared helper:
    const { opsByClient, factsByClient } = routeRegistryItemsToClients(
      { operationalEvents: extraction.operationalEvents, standingFacts: extraction.standingFacts },
      clientRows /* all provider clients */,
    );
    const ops = opsByClient.get(clientId) ?? [];
    const facts = factsByClient.get(clientId) ?? [];
   Routing against the full provider roster (not just [client]) is important so a thread naming several clients does not mis-route another client's items onto this client by being the only candidate. Keep only items whose matched clientId === target clientId.
(e) rawText for storage stays buildGmailThreadProposalRawText(thread) (unchanged), but the extraction now sees the richer reconstructed thread. Pass preExtracted into the drafter:
    const draft = await draftClientRegistryProposalFromExtractor(input, {
      operationalEvents: ops, standingFacts: facts, rawOutput: extraction.rawOutput,
    });
   input is still built from getClientDraftInput(clientId, rawText, "gmail_thread"); rawText still feeds normalize's rawNote/currentSnapshot context. upsertProposalSource + createProposalSetFromDraft are UNCHANGED.

## Residual divergence recommendation
refineExistingStandingScheduleItems runs in the MANUAL path (non-manual sourceType) but NOT in the AUTO createGmailProposalFromExtractedItems path. Recommendation: LEAVE AS-IS. Do NOT move it into the AUTO path in this change.
- Rationale: it only fires when the client has exactly ONE standing schedule and retargets an unanchored schedule_change "add" to that entry. It is a safe single-target refinement. Adding it to AUTO is a behaviour change to the AUTO path that is out of scope for fixing the missed-event-types bug and risks regressing AUTO proposals. The two paths will still differ by this one refinement, but the manual path's version is strictly a superset (more anchoring), which is the safer side for an operator-initiated draft.
- If full parity is later desired, move refineExistingStandingScheduleItems into createGmailProposalFromExtractedItems as a separate follow-up with its own AUTO-path tests.

## Edge cases
- Thread tagged with a client-name variant not exact-matching target -> items dropped (matchClientName non-exact). Acceptable; identical to AUTO behaviour. Result is an empty proposal, same as today's note-extractor empties but now correct because both paths use one matcher.
- Multi-client thread -> only target's items kept (routing by clientId). Correct.
- stored rawInputText vs richer extractor context: rawInputText persisted = buildGmailThreadProposalRawText (truncated, last 2 messages) for operator display; extractor now sees full reconstructed thread (4000 char/msg). This is intentional and matches AUTO. normalize's rawNote = rawText (display text) — fine, rawNote is only used for fallback/dedup heuristics, not the extraction itself (extraction already happened).
- existing-draft dedupe: MANUAL path still deletes by sourceId in createProposalSetFromDraft. No double-delete; do NOT add the clientId+threadId deleteMany here (that belongs to the AUTO helper only).
- enrichment: thread extractor enriches facts once; normalize does not re-enrich. No double LLM call.
- unavailable handling: if extractThreadRegistryItems returns unavailable, ops/facts are likely empty and rawOutput set; preExtracted branch still produces an (empty) draft. Optionally surface extraction.warning -> draft.warning by threading it through preExtracted; minor, optional.

## Tests
1. drafter.test.ts: add a preExtracted-branch test. Pass gmailInput(...) plus preExtracted operationalEvents containing an event type the note extractor would miss (e.g. public_holiday_cancel / new_service); assert the resulting item appears and that NO LLM call path is exercised (REGISTRY_LLM_PROVIDER=mock already). Assert refineExistingStandingScheduleItems still anchors a single-schedule add (reuse tuesdaySchedule). Assert addGmailAddressUpdateItem still guards.
2. draft-service.test.ts: this suite mocks draftClientRegistryProposalFromExtractor, buildContext, buildDraftInput, prisma. Add mocks for extractThreadRegistryItems (new import) and the routing helper / matchClientName, and for prisma.client.findMany (roster). Update mockEmailThreadFindUnique threadRow() to include the new message fields + thread scalars. Assert: (a) createGmailClientRegistryProposal calls extractThreadRegistryItems (the thread extractor) and NOT the note extractor; (b) draftFromExtractor is called WITH a preExtracted arg containing routed ops/facts; (c) mismatch/confirmation_required tests still pass unchanged (extractor must NOT be called before confirmation).
3. roster-update-service.test.ts: after refactoring identifyAndExtract to use routeRegistryItemsToClients, this existing suite (routes Alice->c-alice, Bob->c-bob via mockMatchClientName) must still pass — it pins routing equivalence.
4. New focused test for routeRegistryItemsToClients (client-event-repo or new test): exact match routes, non-exact drops, multi-client splits, matchedNameByClientId populated.

## Verification
- npx vitest run test/unit/client-registry-proposal-drafter.test.ts test/unit/client-registry-proposal-draft-service.test.ts test/unit/roster-update-service.test.ts test/unit/client-registry-llm-extractor.test.ts
- npx tsc --noEmit (type-check the preExtracted shape + new findUnique select)
- Manual: trigger the operator "generate proposals" button on a thread with public_holiday_cancel/new_service and confirm a non-empty proposal matching AUTO.

## Critical files
- /home/yevgen/dev/symphony/email-ops-summary/src/services/client-registry-proposal-drafter.ts
- /home/yevgen/dev/symphony/email-ops-summary/src/services/client-registry-proposal-draft-service.ts
- /home/yevgen/dev/symphony/email-ops-summary/src/services/roster-update-service.ts
- /home/yevgen/dev/symphony/email-ops-summary/src/repos/client-event-repo.ts
- /home/yevgen/dev/symphony/email-ops-summary/src/services/client-registry-thread-proposal.ts
