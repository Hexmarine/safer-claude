---
name: odoo-prod-db-access
description: "How to actually reach the Odoo prod Postgres (sensorglobal_live) — the private-IP tunnel trick, creds location, and the send-command breakage"
metadata: 
  node_type: memory
  type: reference
  originSessionId: aefd794f-3eef-4b2d-9179-4fbd76c1de90
---

Reaching the **Odoo prod Postgres** (CRM/ERP at sensorglobal.com) is NOT like the
Sensor MySQL tunnel — runbook 07's recipe is stale/wrong. What actually works:

- **DB:** `sensorglobal_live`, user `odoo16prod`, on RDS `odoo-production`
  (instance id `odoo-production`), **private IP `10.0.0.168:5432`**, SG
  `sg-08a034fb6f6fe51ac` (not publicly accessible).
- **Creds live in the Odoo container, not on disk.** There is no
  `/etc/odoo/odoo.conf` on the host — it's a Dockerized deploy
  (`ghcr.io/mplus-oss/odoo:16.0`, container `data-odoo-16e` on the Odoo box).
  Get them with `sudo docker exec data-odoo-16e cat /odoo/odoo.conf | grep db_`
  (or `... env | grep -i ODOOCONF__options__db`).
- **Only one jump host can reach the Odoo RDS:** the Odoo box itself
  `i-0c5073e95aba77614` (it's in allowed SG `sg-06539917f5b54f58a`; API servers
  and the old runbook host `i-0b53bd5e7a9b9dec0`=GONE cannot). AND you must
  forward to the **private IP, not the DNS name** — the host can't resolve the
  RDS hostname (container uses the VPC resolver, host doesn't), so DNS-based
  forward fails with "Connection to destination port failed". By-IP works:
  ```
  aws ssm start-session --target i-0c5073e95aba77614 \
    --document-name AWS-StartPortForwardingSessionToRemoteHost \
    --parameters '{"host":["10.0.0.168"],"portNumber":["5432"],"localPortNumber":["15432"]}'
  ```
- **No local psql?** Run it through docker: `docker run --rm --network host -e
  PGPASSWORD postgres:16-alpine psql "host=127.0.0.1 port=15432 user=odoo16prod
  dbname=sensorglobal_live" -c "..."`.
- **Creds cached** at `~/.config/sensorsyn/odoo-prod.env` (ODOO_DB_USER/PASS/NAME),
  auto-loaded by `scripts/load-prod-env.sh` (it adds ODOO_DB_* + reads that file;
  the SSM auto-fetch there is best-effort/opt-in via ODOO_SSM_FETCH=1).

**`aws ssm send-command` is broken on this laptop** (AWS CLI v2.31 + Python 3.14
→ "badly formed help string", even `--generate-cli-skeleton` fails). Use
`start-session` for everything; that's why the cred-fetch and tunnels use it.

**Enterprise seat count = `res_users WHERE active AND NOT share`.** Deactivate to
free a seat with `UPDATE res_users SET active=false WHERE id IN (...)` (archive,
reversible) — never DELETE (FK refs everywhere). 2026-06-06: trimmed 9→7, archived
259 eugene.peresada + 260 kristyn.heywood. See [[sensorglobal-saferhomes-jv]].
