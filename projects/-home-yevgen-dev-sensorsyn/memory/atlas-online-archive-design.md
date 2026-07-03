---
name: atlas-online-archive-design
description: "What the Sensor prod Atlas Online Archive actually archives (logs, NOT audit history), the 90-day move-not-copy clamp, why it's unreachable from the app, and why audit history must stay in main"
metadata:
  node_type: memory
  type: reference
  originSessionId: b38afd56-c669-467d-9776-233dc9ca5f6c
---

Confirmed 2026-06-20 from the Atlas UI + prod data. The `sensor-prod` cluster (M10, ap-southeast-2) has an **Atlas Online Archive** (Data Federation, federated endpoint `atlas-online-archive-67343af0…a.query.mongodb.net` = `MONGO_DB_ARCHIVE_URL`). It archives THREE collections, each `createdAt` / **90-day** age limit, daily schedule:
- `sensorproddb.tbl_alarm_logs` (~866MB), `tbl_logs` (~832MB), `tbl_job_logs` (~17MB). **NOT `tbl_audit_histories`.**

**Online Archive MOVES, doesn't copy** (deletes from the cluster after the age limit). Proven by main-cluster oldest createdAt: tbl_alarm_logs=2026-03-22, tbl_logs=2026-03-22, tbl_job_logs=2026-03-18 (~90d clamp; older only in archive). But **tbl_audit_histories oldest=2026-01-30** (the migration floor — nothing older exists anywhere) = FULLY RETAINED in main, ~2.43M docs.

**The federated archive endpoint is UNREACHABLE from the API nodes** — TCP connects to the Atlas LB IPs (13.54.14.65 / 52.64.205.136) then the endpoint CLOSES the connection. Data Federation has its OWN access config, separate from the cluster Network Access list (which already has the NAT egress 13.210.248.111 — that's why MAIN works). So ALL app-side archive reads fail (confirmed for tbl_alarm_logs too, not just audit). **DECISION 2026-06-20: leave it** — don't need >90d log history in-app; audit is all in main. To enable old log history later: add 13.210.248.111 to the Data Federation network access (+ check the archive DB user role).

**DO NOT add tbl_audit_histories to the Online Archive.** Because Online Archive deletes from main after 90d AND the app can't read the archive, archiving it would CLAMP audit exports to 90 days (losing the compliance trail from the app). Keeping it hot is correct (compliance = read across full range; flat access curve, not the steep recency curve of logs).

**Code-vs-infra drift:** ticket SENS-4520 (commits 99c42f10d/a1eab6962) wired `AuditHistoryModelArchived` on the shared archive connection alongside `AlarmLogsModelArchived`/`CommonLogsModelArchived`, treating audit history as archivable like the logs — but no archive rule was ever created for it. So `getAuditHistoryToExport`'s archive read is dead (non-existent archived collection + unreachable connection); neutralised by the resilience fix in [[audit-export-puppeteer-chrome-missing]]. Optional cleanup: drop the AuditHistoryModelArchived read (main-only). Rationale for archiving the logs at all: cost (S3 ~10–20× cheaper than M10 cluster storage; avoids tier upgrades for high-volume append-only event logs ~17MB/day alarm_logs) + perf (hot working set fits M10 RAM). See [[sensor-audit-history-mongo]].
