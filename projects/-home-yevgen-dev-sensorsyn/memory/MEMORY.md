# Memory Index

Hooks only — the facts live in the topic files; closed incidents are archived in `docs/investigations/`.

## Preferences & working style
- [Memory hygiene process](memory-hygiene-process.md) — index = one-line hooks ≤200 chars; detail flows file → docs/investigations, never up; archive+shrink on incident close; 16KB tripwire → gardening pass.
- [Learn-by-Doing = non-UI tasks](learn-by-doing-non-ui-tasks.md) — TODO(human) hand-offs must be logic/backend/data/auth decisions, never CSS/styling/layout/copy; do UI work myself.
- [Australian spelling in code](australian-spelling-naming.md) — new identifiers/comments use AU/British spelling (normalise); keep existing American-spelled symbols as-is.
- [Codex review = finishing step](codex-review-finishing-step.md) — run `codex review --uncommitted` per changed repo after self-review on substantial changes.
- [Codex: stop on low-value findings](codex-stop-on-low-value.md) — stop the fix→re-review loop at non-essential/low-probability findings; triage by likelihood×impact.
- [Check branch before crying drift](edit-location-agency-deploy-drift.md) — edit-location-agency IS live + on master (`a06534130`); check current branch + `git log --all -S` before concluding lost code.

## Workstation, access & tooling
- [Workstation setup (EC2)](workstation-setup-ec2.md) — AWS needs AWS_PROFILE=sensorsyn-mfa (12h MFA via aws-mfa-login.sh; default profile has zero perms); kubeconfig=safer-ops-prod; tier2-guard hook deliberately unwired.
- [Prod read diag tooling](sensor-prod-read-diag-tooling.md) — scripts/diag/ read-only on-instance Mongo wrapper (prod-read.py); secret reads ask-gated; fetch-to-use OK, never print values.
- [Playwright MCP headless setup](playwright-mcp-headless-setup.md) — browser automation on this headless box = Playwright MCP with --executable-path to ms-playwright chromium; claude-in-chrome has nothing to attach to.
- [Odoo prod DB access](odoo-prod-db-access.md) — forward to RDS private IP 10.0.0.168 via Odoo box i-0c5073e95aba77614; creds in container data-odoo-16e; seat count = active AND NOT share.
- [sensor-mcp service](sensor-mcp-service.md) — read-only ops MCP live at sensor-mcp.sensorglobal.com (EKS, static bearer, 7 tools); blocked by Sensor /admins/* 504 hang; SQL tools dark (no replica).
- [AWS cost shape + AMI sprawl](aws-cost-shape-and-ami-sprawl.md) — acct ~$5k/mo; AMI purge done 2026-06-27 (4686→585) + prod-api retention lambda; 6 sibling lambdas unpruned; CLI flaky → boto3.

## Sensor platform model
- [SensorGlobal / Safer Homes JV](sensorglobal-saferhomes-jv.md) — who built the product, who owns it now, our role in it.
- [Hub connectivity/heartbeat model](sensor-hub-connectivity-heartbeat-model.md) — liveness = SERVER-POLLED VERIFY; heartbeat + retry crons flip DISCONNECTED on 60s no-response; lastConnectionTestDate = last SEND not last answer.
- [Hub power handling](sensor-hub-power-handling.md) — POWERSTATE hub-only, alerts transition-driven; 24h-on-battery agent email; prune-filter fix committed; latent multi-hub prune bug still open.
- [Device-state schema gotchas](sensor-device-state-schema-gotchas.md) — tbl_alarms status enum-ordinal trap (quote it!); connectedStatus/disconnectionEmailSent are sticky flags; real liveness = hub heartbeat date.
- [Device MQTT event history](device-mqtt-event-history-tbl-alarm-logs.md) — Mongo tbl_alarm_logs = per-device activate/recover stream; flapping config pauses EMAILS not eventStatus; sensor 26205 = real hardware flapping.
- [Audit History in Mongo](sensor-audit-history-mongo.md) — Atlas tbl_audit_histories (PLURAL — Mongoose pluralises, code model says singular); propertyId is Number; hideFromAuditHistory filters UI/export.
- [Atlas Online Archive design](atlas-online-archive-design.md) — archives ONLY alarm/system/job logs (90d, MOVES not copies); do NOT archive tbl_audit_histories; federated endpoint unreachable from API nodes.
- [Portal test mechanics](portal-test-mechanics-and-post-swap-failures.md) — VERIFY+TEST are QoS0, 6-min timeout; tests <5min after hub boot/SIM swap fail spuriously; payload-># CloudWatch filter = inbound ground truth.
- [SYSTEMIC: hub lowBattery bug](hub-lowbattery-string-compare-systemic-bug.md) — ~2340 hubs spuriously lowBattery=1: varchar batteryStatus compared lexically; display-only; fix committed (`0b135df65`/#6045); mass flag cleanup still pending.
- [Outgoing comms map](sensor-outgoing-comms-map.md) — Email=SES (no send gate), SMS=SNS (SEND_SMS gate), Push=FCM, MQTT; noisy recurring comms are cron-PULLED /*-cron endpoints, crontab not in repo.
- [SMS gating + failed-SMS report](sensor-sms-gating-and-failure-report.md) — SEND_SMS ON allowlist-scoped since 06-17, set in the SECRET not .env; only Kristyn's number active; report buildable but MessageId discarded.
- [Swap comms pause levers](swap-comms-pause-cron-levers.md) — S162 + daily disconnect emails are cron-driven, not alertConfiguration-gated; lever = suspend crons on the cron box; no SEND_EMAIL flag.
- [Pre-test comm manual trigger](sensor-pretest-comm-manual-trigger.md) — set alarmTestDate=now+24h then hit test-alarm-notify-cron FROM the cron box (IP-allowlisted); verify in tbl_logs; auto cron PAUSED (#SWAP-PAUSE).
- [Write-auth: agency token](sensor-write-auth-agency-token.md) — /users/* writes need an AGENCY/AGENT-class token, not the SUB_ADMIN service token.
- [OIDC_EXPECTED_ISSUER=localhost:4100](oidc-expected-issuer-localhost.md) — the sensor-prod secret key that makes the per-user SSO token exchange verify (SSO stamps a localhost iss).
- [Account inactive symptoms](sensor-account-inactive-symptoms.md) — safer-ops "defaulted persona + error serial" = non-ACTIVE Sensor account; confirm via tbl_admins.status.
- [Admin property-list export](sensor-admin-property-list-export.md) — /admins/properties/list MUST pass orderby=id or unstable-sort paging drops ~38%; Haven Home Safe = agency 37413.
- [SIM provider: Omondo](sim-provider-omondo.md) — fleet is Omondo (not KORE), pre-activated; KORE→Omondo swap safe; only the native install verifySim gate is KORE-coupled.
- [Installation flows old & new](installation-flows-old-and-new.md) — existing native-app on-site flow vs the safer-ops pre-paired-kit flow.
- [Installer identity model](installer-identity-model.md) — the 3-id installer (login userId vs tradePersonId vs traderPerson); kit owner = job.tradePersonId.
- [SSO duplicate-email shadowing](sso-duplicate-email-login-shadowing.md) — login resolves an email to the LOWEST-id tbl_admins row incl. soft-DELETED → shadows active personas; login has no status gate.
- [sso-provider rebuild trap](sso-provider-unpinned-rebuild-trap.md) — unpinned deps: a rebuild grew a UNIQUE grantId index → all prod logins 500'd; fix = drop Mongo index + pin; rollback doesn't undo Atlas state.
- [JWT key leak (remediated)](sensor-prod-jwt-key-in-repo.md) — active signing key Secrets-Manager-only since 06-14, leaked key dead; reset-flow token-compare weakness + non-prod keys still open.
- [SES 454 storm](ses-454-flapping-crash-email-storm.md) — real ~06-04 incident (flapping-crash let disconnect emails flood SES; fixed); the "18.9k live" was baked-AMI log HISTORY — check timestamps vs boot.
- [Daily email volume + bounce](daily-email-volume-overdue-job-reminders.md) — ~600/day = 83% overdue-job reminders (stale pools closed 06-20; 189 Syncom left); 8% bounce = suppression-list re-bounces; SES→SQS capture live.
- [Audit export (fixed)](audit-export-puppeteer-chrome-missing.md) — RESOLVED 06-22: archive-read guard + resolvePdfExecutablePath; stuck auditExprotProgress=1 → 402 lockout, reset lever inside.
- [Structured logging phase 1](sensor-backend-structured-logging.md) — pino + correlation committed (`51ccf370b`) + SQL/Mongoose log-volume fix deployed 07-02; Sentry inaccessible → CloudWatch Logs Insights is the sink; handlers LOG-ONLY.
- [pnpm audit/overrides](sensor-backend-pnpm-audit-overrides.md) — audit 143→43, 0 crit (unused vm2 removed); pnpm 11 reads overrides from pnpm-workspace.yaml NOT package.json.

## PMS integrations & property imports
- [PMS integrations status](pms-integrations-propertyme-propertytree-status.md) — PropertyMe DEAD since 04-09 (OAuth, fire-and-forget so silent); PropertyTree only 5/13 agencies (exact business_name match); health via tbl_property_files.
- [PropertyTree daily re-stamp](propertytree-sync-daily-updatedat-restamp.md) — sync unconditionally updates the whole portfolio daily → "Added On" (updatedAt) re-stamped; use activeCount to spot recurrence; fix is Class-C.
- [Property-import safety tooling](property-import-safety-tooling.md) — MANDATORY preflight/postcheck around any property CSV upload (full-snapshot reconcile!); 48h emergency brake; runbook 14.
- [INCIDENT: Haven mass deactivation](haven-mass-deactivation-2026-06.md) — RECOVERED 06-10 via PITR; import = full-snapshot semantics; previousStatus = the restore lever.
- [Haven 23-property import](haven-property-import-2026-06-05.md) — working CSV column contract (PROPERTY_ID required!), TENANT_GUID no-fake-email trick, NEW(4) post-import by design.
- [CSV import throttle aborts finalize](csv-import-email-throttle-aborts-finalize.md) — SES 454 in import post-processing = unhandled rejection → PropertyFiles.status stuck 0 (data intact).
- [Haven ops login 59256](haven-ops-login-59256.md) — our HHS-scoped Sensor login (support+haven@saferhomesau.com.au, agency 37413), minted inbox-free via SQL clone + JWT reset.
- [Haven device-swap baseline](haven-device-swap-baseline.md) — pre-swap serial snapshot CSVs (3,123 devices / 902 props) in ops-and-extracts/ = the diff reference for verifying replacements.

## safer-ops
- [Local boot profile](safer-ops-local-boot-profile.md) — NO offline mode (API hits real prod); verify-safe = AUTH_MODE=mock + APP_MODE=prod-readonly; checked-in .env.local is the PROD profile — override inline.
- [Prod secret sync](saferops-prod-secret-sync.md) — Flux+ESO from Secrets Manager key safer-ops/prod/app (NOT SSM); force-sync = annotate externalsecret + rollout restart.
- [CI pnpm pin](saferops-ci-pnpm-packagemanager.md) — deploy fails when package.json packageManager drifts from ci.yml's pinned pnpm; local pnpm silently re-bumps it (check git diff).
- [Traceability rule](traceability-rule-saferops.md) — log start+result+error, no silent catches, name the serial; requestId == x-correlation-id == tbl_device_operations.correlationId.
- [Live trace rig](saferops-live-trace-rig.md) — observe a live prod flow via safer-ops-api pod logs + MQTT + sensor-mysql; the pmsi-* pods are an UNRELATED project.
- [Test accounts & duplicates](saferops-test-accounts-and-duplicates.md) — test agency 59120; one-email-many-accounts SSO gotcha; ~120 Appinventiv accounts still active (JV gap).
- [Prepared-kit internals doc](prepared-kit-backend-internals-doc.md) — firmware protocol, dual DB/firmware binding model; ADD STATUS 2 stuck-pairing gotcha + stock-pairing reconcile fix.
- [Fungible-pool pivot](prepared-kit-fungible-pool-pivot.md) — no depot reserve: open ready pool, binding at on-site attach; attach + pair are async fire-and-poll; Reset is destructive.
- [Stranded-device recovery](stranded-device-detach-recovery.md) — out-of-scope installed hub: serial detach/Reset/Abort no-op; in-app "Return hub to stock" (detachHubByDeviceId) is the recovery.
- [On-site add-device](saferops-onsite-add-device.md) — installer bonds loose devices via POST /users/alarms (not SUB_ADMIN add-alarm); addedOnSite flag; re-bond window anchors on lastCheckedAt.
- [E2E verified 2026-05-31](saferops-e2e-verified-2026-05-31.md) — full depot→installer happy path proven in prod on real hardware; the 8 UX/logic findings #115–#122.
- [id_token email-claim gap](saferops-idtoken-email-claim-gap.md) — account-chooser never fired in prod (id_token omitted email under conformIdTokenClaims); the two-repo claimsParameter fix.
- [Agency header pill](saferops-agency-header-pill.md) — header shows the logged-in agency name (wrong-org guardrail); agency id from token claim, name resolved best-effort in /api/me.
- [Job import](saferops-job-import.md) — bulk work-order import: ops CSV contract → Sensor POST /users/jobs; jobTime=epoch-ms gotcha; contractor-by-businessName; validated e2e (job 6384).
- [Completion photos+notes](saferops-completion-photos-notes.md) — evidence passed as-is to the complete API; proxy-S3 upload; SUB_ADMIN evidence-read routed via /admins/jobs/:id; write-path prod e2e pending.
- [My-jobs page dilution](saferops-myjobs-page-dilution.md) — Sensor pages ALL statuses then client filters = dilution (3 of ~200 visible); fix status_filter=10 + pagination + limit 200.
- [Live monitor (Vic Homes demo)](saferops-live-monitor-vichomes-demo.md) — portfolio wall of glass; Sensor WAF rate rule (500/5min/IP) tripped by fan-out → snapshot cache + backoff; alertType gotcha.
- [Reports tab](saferops-reports-tab.md) — agency-scoped portfolio report via new Sensor GET /users/report/summary; all agency staff allowed, contractors 403; count by STATE not event-type.
- [Property Operational column](saferops-property-operational-column.md) — Tier 0 status pills + Tier 1 device rollup via new GET /users/report/operational-summary; battery NEVER shown (lowBattery bug); deploy Sensor first.
- [Chat notifier](saferops-chat-notifier.md) — Google Chat alarm-event + backend-health alerts/digests for Haven; built + codex-clean, committed; live state unverified.

## Business context
- [SensorInsure WordPress site](sensorinsure-product-status.md) — the LIVE WordPress lead-gen site + infra (ALB+EC2); domains expire ~Sep 2026; its old "no code product" claim corrected → see next line.
- [SensorInsure/CorpSure integration](sensorinsure-corpsure-integration.md) — full code product across backend/Angular/Odoo; CorpSure pays Sensor $14.99/mo/property; dormant since ~2026-04 (2 policies ever); crons still firing; insurance_contact NULL + NEXU stubbed; doc = investigations/2026-07-03.
