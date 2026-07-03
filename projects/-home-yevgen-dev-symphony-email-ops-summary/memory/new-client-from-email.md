---
name: new-client-from-email
description: Propose creating a NEW client from an unmatched new_service email — likelyNewClient flag + onboarding hints stashed on the review
metadata: 
  node_type: memory
  type: project
  originSessionId: 52a3cba6-4947-4de7-8ea6-5148a40739dc
---

Feature built 2026-06-16: when an email carries a `new_service`/`schedule_change` for a person who isn't a client yet, the Identify queue now proactively suggests creating them and pre-fills the form.

**Key design decisions (non-obvious):**
- **Reuse path, not a new proposal kind.** The apply path was left untouched (it only mutates existing clients). Flow: operator creates the client from the Identify queue → resolves the review → the *existing* deferred `createGmailClientRegistryProposal` re-extracts and now routes the schedule to the now-existing client → operator applies that proposal. So the schedule lands as a normal proposal (second click), not at create time.
- **Extraction-stage answer = stop discarding.** Routing (`routeRegistryItemsToClients`) drops non-exact names. Instead of re-extracting later, we stash the dropped onboarding items (schedule + structured address/contact) on the review as `onboardingHintsJson` (new `ProviderMatchReview` JSON column, migration `20260615221446`). Built by `buildOnboardingHintsByName` (`src/services/client-onboarding-hints.ts`) in `identifyAndExtract`, passed into `upsertClientEmailEvents`.
- **Gate = low score + service event** (high precision): `classifyLikelyNewClient` in `analysis-service-helpers.ts` — top candidate confidence < `NEW_CLIENT_CANDIDATE_THRESHOLD` (0.6) AND a `SERVICE_IMPLYING_EVENT_TYPES` event present (new_service/schedule_change/worker_change/extra_service). Avoids flagging coordinators/family or misspellings of existing clients.
- **`isStub` deliberately left false** — the field exists but has no promotion lifecycle; created clients are fully real once the operator fills the form.
- Surfaced on `IdentifyReviewItem` as `likelyNewClient` + `onboardingHints`; the "Create New Client" path/`ClientCreateDrawer` already existed (now prefilled + a prominent CTA banner when likelyNewClient).

Ties to [[registry-proposals-dropped-on-sync]] (routing-drop behaviour) and [[two-apply-systems-clientemailevent-vs-proposals]]. Status: implemented locally, tsc+tests+DB e2e green; **not yet committed/deployed** (user commits). Migration auto-applies in prod via CI ([[prod-migrations-separate-from-app-deploy]]).
