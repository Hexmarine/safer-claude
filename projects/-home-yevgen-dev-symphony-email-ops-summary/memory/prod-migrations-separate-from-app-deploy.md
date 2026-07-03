---
name: prod-migrations-separate-from-app-deploy
description: Prod Prisma migrations auto-apply via the GitHub Actions deploy job; just commit the migration folder
metadata:
  node_type: memory
  type: project
  originSessionId: 13563370-4aca-4125-8d9a-0e2b77e5b809
---

The canonical prod deploy is GitHub Actions on push to main ([[prod-deploy-via-github-actions]]),
and its `deploy` job **runs migrations automatically**: step "Run database migrations" =
`bash scripts/with-gcp-db.sh npm run prisma:deploy` (`prisma migrate deploy` against prod Cloud SQL
via the proxy), and it runs **before** the Docker build + Cloud Run deploy — so a new column lands
before the new code boots. (Verified in `ci.yml` 2026-06-08.)

**So for a normal change: just commit + push.** No manual `prisma:gcp_deploy` needed.

**The one real gotcha — commit the migration folder.** `prisma migrate deploy` only applies
migration files that are in the repo. The generated `prisma/migrations/<ts>/` dir is created
untracked by `prisma migrate dev`; if you forget to `git add` it, CI deploys code without the
schema change → runtime "column … does not exist" (which is what bit `WorkerInvoice.deputyEmployeeOverrideId`
in May 2026 under the older manual `scripts/deploy.sh` path, which shipped code only).

**Manual `PROJECT_ID=… npm run prisma:gcp_deploy` is only for out-of-band cases** — applying a
migration to prod without a code push, or hotfixing outside CI. Local dev applies via
`npm run prisma:migrate` (`prisma migrate dev` is gated by the permission classifier — the user runs it).
