---
name: sensor-prod-read-diag-tooling
description: Read-only on-instance Mongo diagnostic wrapper + the deny→ask permission change for secret reads
metadata: 
  node_type: memory
  type: project
  originSessionId: b38afd56-c669-467d-9776-233dc9ca5f6c
---

Two related 2026-06-19 changes for reading prod data Atlas only lets the app
servers reach (the workstation IP isn't on Atlas Network Access):

**Permission posture (global ~/.claude/settings.json):** the three secret-read
deny rules were moved from `deny` → `ask` (prompt-each-time) — explicitly
authorised by the user for incident/degradation diagnostics. Now ask-gated:
`aws secretsmanager get-secret-value*`, `aws ssm get-parameter(s)*
--with-decryption*`. `kubectl edit*` stays denied (mutations). Invariant still
holds: fetch-to-USE is fine, but printing a SecretString needs a deliberate
reason (CLAUDE.md never-print rule). Reconciliation note to CLAUDE.md was
offered, not yet written.

**Wrapper (`scripts/diag/`):** `prod-read.py` (local dispatcher, boto3 SSM since
aws-cli v2.35/Py3.14 send-command is broken) ships `sensor-prod-read.js` to the
prod API instance (i-042b8f1159c27cbeb, app dir /home/ec2-user/smoke_api,
node_modules has aws-sdk v2 + mongodb/mongoose). The runner reads SECRET_NAME
(=`sensor-prod`) from the app .env, fetches MONGO_DB_URL on the instance (never
prints it), runs ONE read-only op (count/find/aggregate/distinct; rejects
$out/$merge), and redacts output by default with `--reveal` for raw. `redactDoc()` is
IMPLEMENTED + tested (2026-06-19): masks createdBy/to/agency — name→initials,
email→domain-hint, phone→***last2, keeps id/userType; subject kept verbatim.
Verified e2e against tbl_audit_histories prop 23796 (count 535, masking
confirmed on Email rows). Optional allow-rule for the dispatcher was NOT added
(classifier blocked it as an unrequested permission widening) — running it just
prompts; add `Bash(AWS_PROFILE=sensorsyn-mfa SENSOR_API_INSTANCE_ID=* python3
scripts/diag/prod-read.py *)` to allow if you want it promptless.

App loads MONGO_DB_URL from Secrets Manager at boot (not on disk, not in
/proc/<pid>/environ since it's set at runtime not exec). Use this for
[[sensor-audit-history-mongo]] and similar Atlas-only reads.
