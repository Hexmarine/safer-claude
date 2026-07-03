# Memory index

- [Scheduled inbox processing](scheduled-inbox-processing.md) — hourly Cloud Scheduler → /jobs/process (now secured by JOB_SHARED_SECRET); Gmail QPM quota; backlog still a TODO
- [No staging commands in handoffs](no-staging-commands-in-handoffs.md) — user stages themselves; skip the git add blocks
- [with-gcp-db proxy leak](with-gcp-db-proxy-leak.md) — exec'd the cmd so cleanup never ran; proxy orphaned 5433 (fixed)
- [Extraction pipeline B-minimization](extraction-pipeline-b-minimization.md) — 5 stages, prompt-vs-code principle, eval harness, tranches shipped

- [Invoice validation: non-clockable & area-day grouping](invoice-validation-nonclockable-and-grouping.md) — why transport rows are not_checkable and how split shifts avoid double-counting
- [Prod migrations are separate from app deploy](prod-migrations-separate-from-app-deploy.md) — CI deploy job auto-runs prisma migrate deploy before Cloud Run; just commit the migration folder
- [Two apply systems: ClientEmailEvent vs proposals](two-apply-systems-clientemailevent-vs-proposals.md) — older email-event apply path + UI is orphaned, being retired in favour of registry proposals
- [Clients refactor & local surface](clients-refactor-and-local-surface.md) — local DB holds real 90-day prod snapshot; iteration loop; §1 done; extraction-quality backlog
- [Prod baseline rebuild 2026-05](prod-baseline-rebuild-2026-05.md) — Excel re-import + Claude-built standing facts (283 facts); local build done, prod Phase 6 pending; new export-fact-inputs + seed-facts scripts
- [Workflow agent model choice](workflow-agent-model-choice.md) — don't default to Opus for heavy fan-outs; set opts.model (sonnet/haiku) for scoped structured-extraction agents
- [Usage-audit feature plan](usage-audit-feature-plan.md) — admin audit-log feature (Phase 1 viewing); implemented & verified 2026-05-31, PROD migration pending
- [Client-update gaps roadmap](client-update-gaps-roadmap.md) — 5 gaps to revisit (worker leave, serviceType, timeline, schedule capture, funding); Gap 1 design Qs unanswered
- [Apply targeter can't retarget a day change](apply-targeter-cannot-retarget-day-change.md) — schedule_change apply matches by the NEW day → a day move duplicates instead of replacing; why Fix 4 only warns
- [MCP server](mcp-server.md) — read-only /mcp server (11 service-wrapping tools, bearer auth, MCP_ENABLED flag) for Claude/ChatGPT operators; live in prod 2026-06-02
- [Prod deploy via GitHub Actions](prod-deploy-via-github-actions.md) — ci.yml on push to main (not deploy.sh); --set-env-vars/--set-secrets replace the whole set, and CI has no Postgres
- [Manual schedule editing](manual-schedule-editing.md) — direct-CRUD schedule pen (separate from proposals) + serviceType column on ClientScheduleEntry; migration auto-applies via CI
- [Client rename](client-rename.md) — inline pencil on detail header; reuses profile PATCH whitelist + collision check; FK-safe (no migration); future-sheet-import caveat; saveProfile now surfaces server errors
- [Registry proposals dropped on sync](registry-proposals-dropped-on-sync.md) — auto-sync writes ClientEmailEvents but the setImmediate proposal-draft is silently lost in the Cloud Run job; operators see no actionable update (Aldo cancel case)
- [New client from email](new-client-from-email.md) — likelyNewClient flag + onboardingHintsJson stashed on review; reuse-path onboarding, low-score+service-event gate
