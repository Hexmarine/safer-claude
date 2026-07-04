---
name: workstation-restic-backup
description: "Workstation has a portable off-AWS backup since 2026-07-04: restic → Backblaze B2, 6-hourly cron, client-side encrypted; restore on any Linux via runbook 15 Path A2; repo password lives ONLY in the user's password manager"
metadata: 
  node_type: memory
  type: project
  originSessionId: 7be13f6f-5a2b-47ad-bd20-d7e3dcadb3d0
---

Since 2026-07-04 the devbox has three durability layers:
1. **Git** — `~/.claude` whitelist repo (memory/plans/config) + `docs/` repo + code repos.
2. **restic → Backblaze B2** (portable, off-AWS): `scripts/backup-workstation.sh`
   via 6-hourly ubuntu crontab (`30 */6 * * *`); covers `~/.claude`, `~/.claude.json`,
   `~/.aws`, `~/.ssh`, `~/.kube`, `~/.zshrc`, `~/.gitconfig`, workspace `scripts/`,
   `ops-and-extracts/`, `docs/`. Retention 7d/4w/6m, prune in-job. Config/creds in
   `~/.config/restic-workstation/{env,password}` (0600; never print). Log:
   `~/.config/restic-workstation/backup.log`. First snapshot `99cd3c21` (827 MiB,
   6830 files); single-file restore verified byte-identical.
3. **EBS** — DLM "Seven Days Backup" daily 09:00 UTC (added 2026-07-04, see
   docs/applied-changes.md).

**Gotchas:**
- The restic **repo password exists only in the user's password manager** (+ the
  0600 file on-box). Losing it = backups unrecoverable. Never print it.
- The `!` bash-input runner is NON-INTERACTIVE — `read -s` prompts die at EOF.
  Interactive scripts must be run by the user in a real terminal, not via `!`.
- Full recovery procedure = `docs/runbooks/15-workstation-recovery.md`
  (Path A EBS / A2 restic-portable / B rebuild). See [[workstation-setup-ec2]].
