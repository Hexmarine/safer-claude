---
name: scheduled-inbox-processing
description: hourly Cloud Scheduler job that processes the inbox; /jobs/process now secured by JOB_SHARED_SECRET
metadata: 
  node_type: memory
  type: project
  originSessionId: 1769fb3b-18a0-44eb-b1d6-92c988578f10
---

Set up **hourly scheduled inbox processing** in prod on 2026-06-07 (reversing the
earlier "on-demand only" choice — it caused 8-day-stale data: last run 31 May,
690 unprocessed threads, 10k unread).

**Cloud Scheduler job** `symphony-process-inbox` (location `australia-southeast1`):
`0 * * * *` Australia/Melbourne → `POST https://operations.cleaningsymphony.com.au/jobs/process`
with header `Authorization: Bearer <JOB_SHARED_SECRET>`, body
`{"mode":"incremental","generateReport":true,"trigger":"scheduler"}`,
attempt-deadline 900s. (Cloud Scheduler API had to be enabled on the project.)

**Security fix:** `/jobs/process` was **publicly callable** (no `JOB_SHARED_SECRET`
in prod → `env.jobs.authEnabled=false` → `requireJobSecret` was a no-op). Now
secured: created `JOB_SHARED_SECRET` in Secret Manager, wired to Cloud Run
(`--update-secrets`, additive), and added it to `ci.yml`'s `--set-secrets`
(REQUIRED — `--set-secrets` replaces the whole set, so omitting it would drop the
secret on the next deploy and re-open the endpoint). Verified: no-auth POST → 401.
See [[prod-deploy-via-github-actions]].

**Gmail quota gotcha:** an incremental sync over a big gap / back-to-back triggers
hits `gmail.googleapis.com` "Queries per minute per user". A single hourly
incremental is fine; avoid hammering or large backfills through `/jobs/process`.

**Still open:** the pre-existing backlog (690 unprocessed / 10k unread) is NOT
caught up — scheduled incremental only handles new mail going forward; a one-off
batched/ranged backfill is a TODO (user deferred). Also `get_report` still labels
a stale snapshot "Last 24 hours" and its counts diverge from the dashboard's —
a reporting fix deferred. Cloud Run's ~300s request timeout caps synchronous
processing, so very large runs can still be cut off mid-flight.
