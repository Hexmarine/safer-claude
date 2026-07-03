---
name: prod-deploy-via-github-actions
description: "prod deploys via .github/workflows/ci.yml on push to main, not deploy.sh; --set-* replaces all env/secrets"
metadata: 
  node_type: memory
  type: project
  originSessionId: 1769fb3b-18a0-44eb-b1d6-92c988578f10
---

Prod (Cloud Run `email-ops-summary`, project `email-ops-summary-492707`, region
`australia-southeast1`) deploys **only** via `.github/workflows/ci.yml` on push
to `main` — there is **no** build trigger and `git push` alone doesn't deploy
the app code path; the workflow's `deploy` job (gated `needs: build-and-test`)
builds the image from HEAD's short SHA and runs `gcloud run deploy`.

`scripts/deploy.sh` + `.env.gcloud` are a **manual fallback only** — CI does not
use them. Don't edit deploy.sh expecting it to affect prod.

**Gotcha that cost a whole session:** the deploy step uses
`gcloud run deploy --set-env-vars "…" --set-secrets "…"`, which **REPLACE the
entire env/secret set** (everything not listed is dropped). So any new env var or
secret (e.g. `MCP_ENABLED`, `MCP_AUTH_TOKEN`) MUST be added to the literal
strings in `ci.yml` — setting it manually via `gcloud run services update` or
just putting the secret in Secret Manager is wiped by the next deploy. The
runner SA has **project-level** `secretmanager.secretAccessor`, so a new secret
is readable without per-secret IAM. The workflow also re-applies
`APP_BASE_URL`/OAuth redirect URIs via a second `services update` after deploy.

Corollary: `build-and-test` runs `npm test` with **no Postgres service**, so any
test that hits a real DB fails CI and blocks `deploy`. DB-backed tests must mock
prisma or self-skip when the DB is unreachable. See [[mcp-server]].
