---
name: extraction-pipeline-b-minimization
description: "Client-registry extraction pipeline stages, the prompt-vs-code principle, and the eval harness used to migrate logic safely"
metadata: 
  node_type: memory
  type: project
  originSessionId: e1816bf4-a5fe-47d0-b000-0a73e175e132
---

The client-registry extraction pipeline (email → proposal) has 5 stages: **1 pre-process** (classify → resolve provider → assemble roster/currentSchedules/fragments → build prompt), **2 LLM extract** (Gemini gemini-2.5-flash → `{operationalEvents, standingFacts}`; two prompts: `extract-thread-registry-items.txt` for the bulk/reprocess path, `extract-registry-note-items.txt` for the manual/single-client drawer), **3 post-process** (3a per-event `normalizeOperationalEvent` in `event-rules.ts`; 3b cross-event set rules in `client-registry-llm-postprocess.ts`), **4 map** to proposal items (`client-registry-proposal-mapper.ts` — contacts/addresses land here), **5 dedup-vs-accepted + persist** (`upsertProposalSource`).

**Guiding principle (agreed with user):** *prompt decides MEANING, code enforces SHAPE/INVARIANTS, humans resolve AMBIGUITY.* "Job A" (canonicalization: dates/times/enums; guardrails: dedupe, conservative-date gate, idempotency) stays deterministic. "Job B" (semantic classification, intent detection, entity parsing done via regex) is being moved into the LLM (prompt or structured output), with the brittle regex demoted to a backstop. Stronger model (pro) did NOT help — failures were prompt/logic gaps, not capability; stay on flash.

**Eval harness** (the migration gate): `npm run registry:notes -- --fixture docs/samples/registry-sweep-eval-cases.jsonl --llm`. Fixture lives in `docs/samples/` (gitignored PII). Each case = note + currentSchedules + `expected` (exact event/fact counts + per-field asserts incl. structured `contact`/`address` sub-fields). `--models a,b` A/Bs models. Non-deterministic cases (rejected-offer, noise, incidental-note count) are inherently flaky — don't over-fit.

**Tranches shipped & prod-validated (2026-06):** T1 entities → structured contact/address (LLM emits fields; mapper prefers them, regex fallback) + a **dedicated `extractContacts` pass** (`gemini-provider-contact-service.ts` + `client-registry-contact-enrichment.ts`, focused prompt, fires only on contact/address facts lacking structure). T2 intent → `confirmationStatus: "rejected"` + one-line invariant drop (regex kept as backstop, LLM ~2/3 reliable). T3 classification → worker-handover prompt reinforcement (+ UI title fix: `RosterAnalysisReviewSections.getItemTitle` now shows "Worker change"/"Update schedule" by eventType, not just operation) + hospital→hold. T4 reason/charge → **already correct** (LLM-emitted; `normalizeChargePolicy` only backfills-when-empty).

**Backlog:** delete contact + rejected-offer regex once prod-confident (or give rejected-offer a dedicated pass); over-fragmentation (one setup email → many tiny standing facts); vague "confirmed new address" with no address captured. Related: [[two-apply-systems-clientemailevent-vs-proposals]], [[clients-refactor-and-local-surface]].
