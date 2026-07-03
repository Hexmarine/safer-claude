---
name: audit-export-puppeteer-chrome-missing
description: "RESOLVED 2026-06-22: Audit-History PDF export silent failure — durable fixes deployed (archive-read guard + resolvePdfExecutablePath); the reusable levers and gotchas"
metadata:
  node_type: memory
  type: project
  originSessionId: b38afd56-c669-467d-9776-233dc9ca5f6c
---

**Incident closed.** Full root-cause trail archived to
`docs/investigations/2026-06-20-audit-export-silent-failure-root-cause.md`.
Both causes fixed + verified in prod (2026-06-20 → 06-22):

1. **Primary (code):** `getAuditHistoryToExport` unguardedly queried the unreachable
   archive cluster. Fixed: guarded + resilient read (PR #6037, `797ac64c3`).
2. **Secondary (env):** `puppeteer.launch()` had no `executablePath`; managed Chrome
   missing for ec2-user and regressed on every ASG churn. Durable fix `ed4b5489b`:
   `Help.ts resolvePdfExecutablePath()` (env → `/usr/bin/google-chrome-stable` →
   managed cache) on both launch sites — AMI-baked system Chrome, churn-proof.

**Durable levers/gotchas (still true):**
- Stuck-export lockout: any failure leaves `tbl_admins.auditExprotProgress=1` → 402
  forever. Reset: `UPDATE tbl_admins SET auditExprotProgress=0 WHERE id=<adminId>`
  (`scripts/diag/sensor-admin-flag-reset.js`).
- **`Promise.allSettled` does NOT catch synchronous throws** — a `bufferCommands=false`
  Mongoose collection throws sync while building the array. Wrap each read in an
  `async` fn (`readCollection`) so throws become rejections. Cost a deploy cycle.
- Atlas Online Archive / Data Federation endpoint has its OWN IP access list
  (separate from the cluster's) — API nodes are not on it; see [[atlas-online-archive-design]].
- API-node diag: real pm2 logs are `/var/log/api-dev-{out,error}*.log` (not ~/.pm2);
  baked AMI logs replay historical error counts on every fresh node — check line
  timestamps vs boot time. Misspelled secret key `DB_MYSQL_PASSWPRD` exists.

Residual (accepted): a full end-to-end export+email re-run after the 06-22 deploy was
not done (launch + flag-clear verified; the 06-20 e2e on prop 23796 proved the chain).
See [[sensor-audit-history-mongo]], [[sso-duplicate-email-login-shadowing]].
