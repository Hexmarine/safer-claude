---
name: prod-baseline-rebuild-2026-05
description: "Rebuild prod client baseline from updated Excel + Claude-built standing facts, then deploy (local build DONE 2026-05-30; prod Phase 6 pending)"
metadata: 
  node_type: memory
  type: project
  originSessionId: 59277a1d-4a4d-4987-8a7c-9e2520e40c79
---

Rebuilding the prod client baseline before shipping the `feat/clients-refactring` branch. Plan: `~/.claude/plans/add-one-more-phase-tender-teapot.md`.

**Two new scripts (committed-pending):**
- `scripts/export-client-fact-inputs.ts` (npm `registry:export-fact-inputs`) — read-only dump of per-client {notes VERBATIM, address, contactInfo, scheduleSummary, hasSignal} to gitignored JSONL.
- `scripts/seed-standing-facts.ts` (npm `registry:seed-facts`) — reads facts JSONL, matches client by clientId→externalId→(providerSlug,clientName), upserts a per-client synthetic `ClientRegistrySource` (sourceType `claude_baseline_facts`, sourceKey `claude_baseline_facts:<clientId>`, contentHash=clientId for the `@@unique([providerId,sourceType,contentHash])`), deletes prior facts scoped to that source, inserts as `reviewStatus:"accepted"`, `appliedToClientAt:now`. Idempotent (re-run replaces only its own source's facts). `--dry-run`/`--apply`. Junk guard drops a fact whose normalized text == the client's provider name/slug or is <4 chars (defends against provider-name-in-notes pollution).

**Why accepted (not pending):** `baseline-export.ts` only carries standingFacts with reviewStatus ∈ {accepted, auto_accepted}, so facts must be accepted to travel in the package.

**Fact build = Claude Workflow, NOT Gemini.** 35 sub-agents, one per 25-client batch (`tmp/agent/batch-NN.jsonl`→`batch-NN.facts.jsonl`), strict schema `{clientId, facts:[{factType,text,confidence}]}`, verbatim text slices, conservative confidence (0.5–0.7). ~660k subagent tokens, ~4 min. Agents correctly SKIP operational-event notes (cancel/hold/reschedule belong to the email pipeline) and only emit true standing facts → 283 facts / 245 clients of 624 noted (right ratio, not under-extraction).

**Local build (Phases 1–5) DONE & verified 2026-05-30.** `tmp/baseline-package.json`: 28 providers, 865 clients, 886 active schedules, 283 accepted standing facts (245 sources), 151 accepted operational events, 353 contacts, 815 addresses, 1116 registry sources. All facts accepted; no junk/empty providers. Fact types: contact_instruction 111, service_instruction 51, billing_note 41, general_note 37, preference 36, access_instruction 4, risk_note 3. Local DB now holds this state.

**Phase 6 (PROD) DONE 2026-05-31.** What actually ran:
1. `roster:reset-suggestions` via `with-gcp-db.sh` → cleared 401 proposalSets / 439 emailEvents / 1542 reviews / 396 gmail sources; clients + threads preserved.
2+3. **Deploy + migration are GitHub Actions (`.github/workflows/ci.yml`), NOT manual.** On push→main the deploy job runs `bash scripts/with-gcp-db.sh npm run prisma:deploy` (the migration) THEN builds image + `gcloud run deploy`. Pushing commit `cb96237` ("wip client refactorings") auto-ran the Phase F column-drop AND deployed new code — CI run concluded success (5m41s). `prisma migrate status` against prod = "Database schema is up to date!". **Do NOT run scripts/deploy.sh or prisma:gcp_deploy manually — CI owns both.** (Plan's "deploy-then-migrate" is satisfied: CI runs migrate before deploy in the same job, and reset-suggestions already emptied ClientEmailEvent so the column-drop is safe.)
4. `registry:baseline-apply --package tmp/baseline-package.json --apply --confirm-clear-clients` → SUCCESS. Apply's own post-tx `targetAfter`: providers 28, clients 865, activeScheduleEntries 886, contacts 353, addresses 815, registrySources 1116, acceptedOperationalEvents 151, **acceptedStandingFacts 283** (targetBefore was 0). Claude facts now live in prod.

No history reprocess + no prod backup (operator decisions). New email flow generates suggestions for review going forward.

**CRITICAL OPS GOTCHA — `with-gcp-db.sh` proxy leaks.** It starts cloud-sql-proxy on 127.0.0.1:5433 and does NOT reliably clean it up; orphans (one was 1d8h old, pid 9500) stack → "address already in use" makes EVERY subsequent with-gcp-db.sh call fail fast. Symptoms look like "stuck"/failed steps even though a prior step succeeded. Before each with-gcp-db.sh call, ensure 5433 is free. Cleanup `pkill -f cloud-sql-proxy` returns exit 144 under the harness pipefail zsh wrapper (cosmetic — the kill works); verify with `ss -ltn | grep :5433`. Local docker postgres is on 5432 (separate). Inline `node -e` must use ESM `import`/`writeFileSync`, not `require` (repo is type:module) — a require-based probe silently fails. When proxy errors muddy logs, trust the DB re-query or the apply script's own targetAfter, not stderr.

**PII:** all `tmp/*.jsonl`, `tmp/agent/`, `tmp/baseline-package.json` are gitignored real client data — never commit. See [[clients-refactor-and-local-surface]], [[prod-migrations-separate-from-app-deploy]].
