# Plan: Upgrade `sensor-prod` RDS MySQL 8.0.44 → 8.4.8 (Blue/Green)

## Context

AWS ends **standard support for RDS MySQL 8.0 on 2026-07-31** (~1 month out). The
Sensor alarm backend's production DB, `sensor-prod` (MySQL **8.0.44**,
`db.t3.medium`, Multi-AZ, gp3 20 GB), already has
`engine_lifecycle_support = "open-source-rds-extended-support"` set — so it will
**not** error after the cutoff, but it will start incurring **paid Extended
Support** charges (per-vCPU/hr, doubled on Multi-AZ) for sitting on a dead major
version, and is force-upgraded by 2029 regardless. This is a cost+hygiene driver,
not a hard outage cliff — so we have room to do it carefully.

**Goal:** move to **MySQL 8.4 LTS (8.4.8**, the AWS regional default) with
near-zero downtime, via an **RDS Blue/Green deployment**, preserving the writer
endpoint and keeping the application's alert→SMS pipeline intact.

The app stack is already 8.4-ready: `mysql2` 3.22.1 + `sequelize` 6.37.8 both
support `caching_sha2_password`; schema is utf8mb4; no removed SQL features. **No
application code changes are required.** The risks are operational (auth-plugin
migration + cutover handling), addressed below.

## Decisions (confirmed with user)

- **Method:** Blue/Green (test-before-cutover, ~1-min switchover, instant
  pre-switchover rollback, endpoint preserved). Accepts ~2× DB cost while green
  runs + Terraform state reconciliation after.
- **Target version:** 8.4.8 (AWS default/recommended).
- **Window:** late weeknight ~22:00–00:00 AEST (after on-site installers finish,
  before the heavy overnight cron batch on `i-0a1cd47cfadedf035`).

## Key facts (from live inspection + repo)

- Instance is **Terraform-managed** (imported):
  `code/infra/terraform/environments/prod/generated_data.tf:81`.
  `engine_version="8.0.44"` is **hard-pinned** (line 107);
  `allow_major_version_upgrade=null` (line 83). A console upgrade WILL drift —
  Terraform must be reconciled after.
- **Parameter group `prod-mysql-8-parameter-group` and option group
  `default:mysql-8-0` are NOT in IaC** (literal strings only,
  `generated_data.tf:122-123`). Custom params: `group_concat_max_len=100000`,
  `log_bin_trust_function_creators=1` (both valid in 8.4). A new **`mysql8.4`
  family** parameter group must be created out-of-band.
- App connects as master user **`admin`** (secret `sensor-prod`, key
  `DB_MYSQL_PASSWPRD` [sic]); endpoint
  `sensor-prod.c4h1sisawrbr.ap-southeast-2.rds.amazonaws.com`. Connection has
  **no TLS** and **no startup retry** (`code/sensor-alarm-backend/src/utils/BootStrap.ts:18-79`
  authenticates once, swallows errors, no exit).
- Load is light (connections avg ~3.74 / max 116; CPU avg ~5% / max 70% → keep
  `db.t3.medium`). 7-day PITR + `scripts/pre-optim-snapshot.sh` for a tagged
  manual snapshot.
- Nearest analog procedure: `docs/runbooks/02-rds-io1-gp3.md` (Multi-AZ
  modify/rollback framing). No engine-upgrade runbook exists yet → this plan
  becomes one.

## Approval model

RDS is in the **elevated** mutation set (CLAUDE.md). Every mutation below needs
the named ack **"go — RDS sensor-prod"**, and per house practice the user runs
the mutating commands via `!` (the harness blocks the agent). I prepare/verify
each step read-only and record applied changes in `docs/applied-changes.md`
afterward. All AWS commands below use `AWS_PROFILE=sensorsyn-mfa`.

---

## Phase 0 — Pre-flight (read-only, no approval needed)

1. **Gate:** confirm no active incident and no in-progress installs (Redis holds
   in-flight `<hub>_HUB_VERIFY` state). Run `scripts/health-check.sh
   --save-baseline` (per `docs/runbooks/00-baseline-capture.md`).
2. **AUTH-PLUGIN CHECK (the gating precheck) — DONE 2026-06-30, RESOLVED.**
   Ran read-only (`scripts/diag/sql-read.py` against `sensor-prod`). Result: **all
   client users authenticate via `mysql_native_password`** — `admin`
   (sensor-alarm-backend), `safer_ops_app` (safer-ops backend), `power.bi`,
   `wordpress_usr`, `mat.loftus`, `omar.shariff` (`rdsadmin@localhost` is
   `auth_socket`, RDS-internal). **No action required for this upgrade:** in the
   RDS **`mysql8.4`** parameter family, `mysql_native_password` defaults to **`ON`
   and is non-modifiable** (`describe-engine-default-parameters`), so RDS keeps
   the plugin enabled on 8.4 — every existing login continues to work with **no
   per-user `ALTER USER`, no TLS change, no app PR**.
   - **Deferred follow-up (separate work, NOT this upgrade):** `mysql_native_password`
     is removed in MySQL **9.x**, so before any future 9.x move all 6 clients must
     migrate to `caching_sha2_password` (blast radius: sensor-alarm-backend,
     safer-ops, Power BI, WordPress, + the plaintext/cold-cache RSA detail). Track
     separately.
3. Confirm 8.4.8 is a valid target (already verified:
   `describe-db-engine-versions` lists 8.4.3–8.4.9; 8.4.8 = regional default).

## Phase 1 — Prepare (mutations: go — RDS sensor-prod)

4. **Tagged safety snapshot:** `scripts/pre-optim-snapshot.sh` (creates
   `pre-optim-sensor-prod-<ts>`, `purpose=pre-optim`). Wait `completed`.
5. **Create the 8.4 parameter group** (low-risk; touches no data):
   ```
   aws rds create-db-parameter-group --db-parameter-group-name prod-mysql-84-parameter-group \
     --db-parameter-group-family mysql8.4 --description "sensor-prod MySQL 8.4"
   aws rds modify-db-parameter-group --db-parameter-group-name prod-mysql-84-parameter-group \
     --parameters "ParameterName=group_concat_max_len,ParameterValue=100000,ApplyMethod=immediate" \
                  "ParameterName=log_bin_trust_function_creators,ParameterValue=1,ApplyMethod=immediate"
   ```
   Diff against the live 8.0 group to confirm no other custom params were missed.

## Phase 2 — Build & validate green (mutations: go — RDS sensor-prod)

6. **Create the Blue/Green deployment**, green at 8.4.8 with the new param group:
   ```
   aws rds create-blue-green-deployment \
     --blue-green-deployment-name sensor-prod-bg-84 \
     --source <sensor-prod ARN> \
     --target-engine-version 8.4.8 \
     --target-db-parameter-group-name prod-mysql-84-parameter-group
   ```
   RDS provisions green as a replica (Multi-AZ inherited) and upgrades it to 8.4.8.
7. **Wait** for green `Available` and replication lag ~0
   (`describe-blue-green-deployments`, `describe-db-instances` on the green id).
8. **Validate green** (read-only against the green endpoint via a tunnel):
   - `SELECT VERSION();` = 8.4.8; confirm the 2 custom params applied.
   - Smoke-test the two `ONLY_FULL_GROUP_BY` raw queries
     (`src/controllers/users/settings.controller.ts:2386` offer-settings list;
     `src/entities/alarmTestHistory.entity.ts:39`).
   - Spot-check spatial (`ST_GeomFromText`) reads.
9. **Auth migration — NOT NEEDED** (Phase 0.2 resolved: RDS 8.4 keeps
   `mysql_native_password` ON by default, non-modifiable). All clients authenticate
   unchanged after switchover. No `ALTER USER`, no TLS PR for this upgrade. Just
   confirm on green that an `admin` login succeeds (it will).

## Phase 3 — Cutover (mutation: go — RDS sensor-prod)

10. **Freeze restarts across the window** (prevents the no-retry degraded-boot
    trap): suspend ASG instance replacement
    (`Suspend ReplaceUnhealthy,Terminate,HealthCheck` on the API ASG) and pause
    the cron box (live id **`i-0392d1fca678f1a21`** = `smoke-prod-api-cron-server`;
    the `i-0a1cd47cfadedf035` in prod-services-access.md is stale) scheduled jobs.
    *(Own go; reverse in
    Phase 5.)* Do not deploy during the window.
11. **Switch over:**
    ```
    aws rds switchover-blue-green-deployment \
      --blue-green-deployment-identifier <id> --switchover-timeout 300
    ```
    ~1 min. RDS renames green → `sensor-prod` (endpoint preserved); blue becomes
    `sensor-prod-old<...>`. Running app processes ride through via pool re-connect.

## Phase 4 — Verify (read-only)

12. DB: connections normal, no replication errors, CPU sane; CloudWatch alarms
    (`generated_alarms.tf`) return to OK.
13. **App alert→SMS pipeline** (the silent-failure lesson from
    `docs/investigations/2026-04-12-mysql-sms-root-cause.md`): trigger a test
    alarm and confirm `tbl_alarm_alerts` rows are created and an SMS/email is
    enqueued — not just "DB is up".
14. Hub VERIFY/heartbeat working; offer-settings page loads (GROUP BY query).
15. Re-run `health-check.sh` at +0 / +15 min / +1 h vs the saved baseline.

## Phase 5 — Reconcile & clean up

16. **Terraform reconciliation** (`environments/prod`): set
    `engine_version = "8.4.8"` (line 107), `parameter_group_name =
    "prod-mysql-84-parameter-group"` (line 123), `allow_major_version_upgrade =
    true` (line 83); optionally flip `engine_lifecycle_support` to
    `"open-source-rds-standard-support"` (line 106, now back in standard support).
    `terraform plan` must show **no destructive change**. If Blue/Green's
    resource-id swap makes TF plan a replacement, `terraform state rm
    aws_db_instance.sensor_prod` + re-import by identifier `sensor-prod` (the
    instance was originally imported anyway).
17. **Un-freeze** ASG processes + cron box (reverse step 10).
18. **Soak ~1 week**, then delete the retained blue
    (`sensor-prod-old<...>`) — *separate* go — RDS sensor-prod. Keep the
    pre-optim snapshot ~1 week.
19. Record in `docs/applied-changes.md` (approval ref, applied-by, execution
    location, systems affected, verification, undo). Promote this plan into a new
    `docs/runbooks/` MySQL-upgrade runbook.

## Rollback

- **Before switchover (Phases 1–2):** delete the Blue/Green deployment — green is
  discarded, **blue is untouched**. Zero production impact.
- **After switchover (Phase 3+):** blue is retained but **no longer replicating**,
  so data written post-switchover would be lost on a revert. Treat the first
  ~15 min as a fast go/no-go: if the app/alert pipeline misbehaves, re-point to
  blue (or PITR/snapshot restore) immediately. Keep the window short and watch
  Phase 4 checks live. This asymmetry is the reason green is fully validated in
  Phase 2 before we commit.

## Verification summary (how we know it worked)

`SELECT VERSION()` = 8.4.8 on the preserved endpoint; CloudWatch alarms OK;
baseline health-check matches at +0/+15m/+1h; **a test alarm produces a
`tbl_alarm_alerts` row + outbound SMS/email**; hub VERIFY + offer-settings page
work; `terraform plan` clean.
