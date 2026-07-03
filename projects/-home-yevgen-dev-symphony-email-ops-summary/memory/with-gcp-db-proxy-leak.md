---
name: with-gcp-db-proxy-leak
description: "with-gcp-db.sh used to exec the command, so the cleanup trap never ran and the Cloud SQL proxy leaked on port 5433"
metadata: 
  node_type: memory
  type: project
  originSessionId: e1816bf4-a5fe-47d0-b000-0a73e175e132
---

`scripts/with-gcp-db.sh` (the prod-DB tunnel wrapper used by `prisma:gcp_deploy`, `roster:reprocess` against prod, etc.) historically ended with `exec "$@"`, which **replaced** the bash process with the command — so the `trap cleanup EXIT` never fired and the `cloud-sql-proxy` (a background child) was orphaned, holding `127.0.0.1:5433` after the run. The next invocation then failed with `bind: address already in use`.

Fixed 2026-06-04: (1) added a `reclaim_port` pre-flight that kills any lingering listener on `PROXY_PORT` before starting (lsof/fuser), (2) replaced `exec "$@"` with running the command as a child and propagating its exit code, so the EXIT trap now reaps the proxy, (3) `trap cleanup EXIT INT TERM`.

**Why:** harness `!` runs can also SIGKILL the parent without running traps, so the pre-flight reclaim is the durable safety net.

**How to apply:** if a `with-gcp-db.sh` run ever fails with "address already in use" on 5433, an orphaned proxy is the cause — `lsof -ti tcp:5433 -sTCP:LISTEN | xargs kill` clears it. PROXY_PORT overridable via env. Related: [[prod-deploy-via-github-actions]], [[mcp-server]].
