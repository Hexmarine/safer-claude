---
name: saferops-prod-secret-sync
description: how to push new env/secrets to safer-ops prod (Flux + ESO from Secrets Manager) and force a sync — incl. the SSM-vs-Secrets-Manager trap
metadata: 
  node_type: memory
  type: project
  originSessionId: e097111e-3354-4441-a46c-63f64ec949b7
---

safer-ops prod runs on k8s, GitOps via **Flux**, env delivered by **External Secrets Operator**. The `ClusterSecretStore` `safer-ops-prod` is **`service: SecretsManager`** and the `ExternalSecret` `safer-ops-app` extracts JSON key **`safer-ops/prod/app`** → materialized k8s Secret `safer-ops-app`, consumed via `envFrom`. Refresh interval **1h**. kubectl context `safer-ops-prod`, namespace `safer-ops`, deployment `safer-ops-api` (replicas: 1).

**Trap:** ESO reads **AWS Secrets Manager**, NOT **SSM Parameter Store**. Params edited in Parameter Store never reach the cluster. New env vars must go into the Secrets Manager JSON secret `safer-ops/prod/app`.

**Force-sync procedure** (after updating the secret):
1. `kubectl annotate externalsecret safer-ops-app -n safer-ops force-sync="$(date +%s)" --overwrite` — pull now instead of waiting up to 1h.
2. `kubectl describe secret safer-ops-app -n safer-ops | grep -i <KEY>` — confirm key landed (describe shows names+sizes only, no values; full `get -o jsonpath={.data}` is blocked by the prod-read classifier).
3. `kubectl rollout restart deployment/safer-ops-api -n safer-ops` — **required**: `envFrom` secret changes do NOT roll pods on their own.

MQTT monitor in prod needs these keys in the secret: `SAFER_OPS_MQTT_MONITOR_ENABLED` (literal `"true"`), `MQTT_HOST`, `MQTT_USERNAME`, `MQTT_PASSWORD`, optional `MQTT_PORT`/`MQTT_PROTOCOL` (`apps/api/src/config.ts`). Enabled + verified in prod 2026-06-09. Related: [[saferops-live-trace-rig]].
