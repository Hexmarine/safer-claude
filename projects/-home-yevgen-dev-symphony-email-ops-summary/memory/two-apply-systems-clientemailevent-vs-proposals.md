---
name: two-apply-systems-clientemailevent-vs-proposals
description: "Two parallel \"apply email-derived client change\" systems exist; the ClientEmailEvent apply path + its UI are orphaned and being removed"
metadata: 
  node_type: memory
  type: project
  originSessionId: 59277a1d-4a4d-4987-8a7c-9e2520e40c79
---

The client-registry surface has TWO mechanisms for turning email signal into client-record changes, because the newer proposal system was built on top of an older email-event system that was never fully removed.

- **System A — `ClientEmailEvent` (older, being retired):** `applyClientEvent`/`dismissClientEvent`/`bulkApplyEvents` (`src/repos/client-event-repo.ts:276`, `src/services/roster-review-service.ts`) write directly to legacy `Client` fields + `ClientScheduleEntry`. Its UI (`client/src/pages/RosterReviewsPage.tsx` + the whole `RosterReview*` component cluster) is **orphaned** — defined but never routed; `/clients/reviews` redirects to `/clients/analysis` (`App.tsx:34`). Backend routes `/roster/reviews*` and `/roster/events/*` are still live but only the orphaned UI called them. `acceptReview`/`rejectReview` are superseded by the live `resolveIdentification`/`markIdentificationNoAction` (`src/services/analysis-identify-service.ts`).
- **System B — `ClientRegistryProposal` (current):** `applyClientRegistryProposal` (`src/services/client-registry-proposal-apply-service.ts`) writes to structured registry tables. Manual editing (`createManualClientRegistryProposal`) and Gmail drafting both go through `draftClientRegistryProposalFromExtractor`. **Manual editing never touches ClientEmailEvent** — it is System B only.

Decision (2026-05-29): demote `ClientEmailEvent` to read-only **evidence** (thread→client matching, history display, auto-draft trigger) and delete System A's apply path + orphaned UI. `upsertClientEmailEvents`/`matchClientName`/`findProviderFromSubject` stay (live via `roster-update-service.ts`). Related cleanup targets: double Gmail LLM extraction (same thread extracted by `extractClientEvents` AND re-extracted in `createGmailClientRegistryProposal`), legacy-vs-structured field drift (apply writes `Client.address` but not `Client.contactInfo`/`notes`, so the LLM draft context reads stale data), stringly-typed `kind`/`status` apply switch. Schema cleanup of `ClientEmailEvent.appliedToRecord`/`dismissed` is a later migration — see [[prod-migrations-separate-from-app-deploy]].
