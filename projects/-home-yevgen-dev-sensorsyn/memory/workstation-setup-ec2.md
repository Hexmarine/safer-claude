---
name: workstation-setup-ec2
description: New EC2 dev workstation (2026-06-18) auth model + toolchain state; the AWS_PROFILE gotcha and the unwired tier2-guard hook
metadata: 
  node_type: memory
  type: project
  originSessionId: b9c93dd7-17e4-4d5b-9666-29c447f3480f
---

Dev workstation is now an EC2 box (`/home/ubuntu`, arm64/Ubuntu 24.04 noble) in
the **same AWS account** as Sensor + safer-ops (acct 747293622182,
ap-southeast-2). Migrated from an old `/home/yevgen` box on 2026-06-18.

**AWS auth gotcha (will bite you):** the `default` profile (IAM user
`peresada1@gmail.com`) has **zero read perms** — every describe/list returns
AccessDenied. ALL AWS work must run under `AWS_PROFILE=sensorsyn-mfa`, a 12h
MFA session minted by `./scripts/aws-mfa-login.sh` (interactive — user runs it
via `! ...`, MFA serial `arn:aws:iam::747293622182:mfa/dev-1`). That profile has
full read breadth (EKS safer-ops-prod, RDS sensor-prod + odoo-production, ECR,
EC2, Secrets, CW logs). When AWS calls suddenly 401/AccessDenied, the session
expired — re-mint. boto3: `boto3.Session(profile_name='sensorsyn-mfa')`.

**Toolchain installed 2026-06-18:** kubectl v1.36 (cluster is v1.35, +1 skew ok),
docker 29.1.3 (daemon active; `ubuntu` added to docker group — needs re-login,
else use sudo), helm v3.21, terraform v1.15 (HashiCorp apt repo). Pre-existing:
node 24, pnpm 11, python3.12, boto3 1.34, mysql8 client, mongosh, jq,
session-manager-plugin. kubeconfig context alias = `safer-ops-prod` (matches the
settings.json allow rules); its exec block carries `--profile sensorsyn-mfa`, so
kubectl also depends on a live MFA session.

**codex sandbox fix (2026-06-21):** `codex review` failed on this box with
"every command failed with a sandbox bwrap error" — codex sandboxes each command
in a bubblewrap user-namespace, but Ubuntu 24.04 sets
`kernel.apparmor_restrict_unprivileged_userns=1` (AppArmor blocks unconfined
binaries from creating unprivileged userns; `unprivileged_userns_clone=1` alone
is necessary-but-not-sufficient). Fixed by (1) `apt install bubblewrap` (was
missing → codex was using its bundled bwrap) and (2) persisting
`kernel.apparmor_restrict_unprivileged_userns=0` via `/etc/sysctl.d/`. After that
`codex review --uncommitted` runs clean. NOTE: disabling codex's sandbox via
`-c sandbox_mode=danger-full-access` is BLOCKED by the auto-mode classifier
(sandbox-weakening) — fix the host userns instead, don't bypass.

**aws-cli on Py3.14.5:** some subcommands still break (per
[[daily-email-volume-overdue-job-reminders]] — e.g. ssm send-command); boto3 is the
tested workaround. sts/eks/rds CLI calls do work — breakage is selective.

**tier2-guard hook is NOT wired (by choice):** `.claude/hooks/tier2-guard.py`
exists but is registered in no settings file (migration dropped it). User
decided 2026-06-18 to **leave it unwired** and rely on the server-side auto-mode
classifier + the settings.json deny rules (which DID block a sensor-prod
get-secret-value via boto3 during setup). Don't assume the mechanical Tier-2
backstop is firing.

DB/MQTT access pattern unchanged: `source ./scripts/load-prod-env.sh` then
SSM tunnels (`db-tunnel-start.sh`, `mqtt-tunnel-start.sh`). See
[[odoo-prod-db-access]] for the Odoo RDS forward.
