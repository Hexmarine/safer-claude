---
name: sensor-backend-pnpm-audit-overrides
description: How sensor-alarm-backend pnpm vulnerabilities were cut 143->43 (0 crit); pnpm 11 reads overrides from pnpm-workspace.yaml NOT package.json; residuals + pre-existing build/test breakage
metadata: 
  node_type: memory
  type: project
  originSessionId: 0ddf147f-ac4a-44d6-aeb0-47563d153588
---

2026-06-26: cut `pnpm audit` on sensor-alarm-backend from **143 vulns (13 crit / 65 high) -> 43 (0 crit / 13 high)**. Changes are config-only (package.json, pnpm-lock.yaml, pnpm-workspace.yaml, tsconfig.json skipLibCheck) — NO source touched. **SHIPPED TO PROD 2026-06-26 ~23:12 UTC**: commit 9c067c2f1 → merged via PR #6046 (master 89bc0c4d9) → CodeBuild #391 SUCCEEDED → CodeDeploy d-KFT8LY28J Succeeded (blue/green, new nodes i-0320bea4f8a11add7 + i-0acf7c5fbe311f26d, Smoke_alarm online 0 restarts, API 401/33ms, no MODULE_NOT_FOUND/nodemailer/crash in pm2-error-log). Prod pipeline: CodeBuild project `Smoke-API` + CodeDeploy app/group both `Smoke-API` (ASG CodeDeploy_Smoke-API_d-7CWAXUR7J), triggers on merge to **master**. **LIVE SES SMTP SEND VERIFIED post-bump 2026-06-26**: one-off on node i-0320bea4f8a11add7 replicating MailManagerClass.createSesSmtpTransport (host/port 587/requireTLS/TLSv1.2/auth) under nodemailer 9.0.1 → transporter.verify() OK, sendMail accepted 1/rejected 0, SES `250 Ok`. So nodemailer v6→v9 SES path is good end-to-end. HOW (reusable rig): app gets SES creds NOT from env/.env (the 46-byte .env only holds SECRET_NAME) but from `src/libs/secretManager.ts` getSecretByARN() fetching SECRET_NAME from Secrets Manager via instance role then Object.assign(process.env, secret). To run any one-off needing prod config: load dotenv(APP/.env) → await getSecretByARN() → THEN require(APP/build/src/config). App dir /home/ec2-user/smoke_api (root-owned, CodeDeploy), config compiles to build/src/config, run as root. aws-sdk v2 EOL warning on stderr is benign.

What was done:
- **Removed `vm2`** (was `^3.9.19`) — declared but imported NOWHERE (grep: only ref was the package.json line; `pnpm why` = nothing depends on it). It was the source of ALL 13 criticals. vm2 is deprecated/unfixable (every version has open crit advisories) so removal, not bump, is the fix.
- **In-range direct bumps** via `pnpm update`: multer 2.1.1->2.2.0, form-data 4.0.5->4.0.6, axios 1.15.0->1.18.1, @xmldom/xmldom 0.8.12->0.8.13, multiparty 4.2.3->4.3.0.
- **Transitive overrides** for old coexisting copies: form-data@2, qs@6, ws@7+ws@8, lodash, undici@7, path-to-regexp@0.1.7, body-parser@1, basic-ftp@5, systeminformation@5, protobufjs@7, @grpc/grpc-js@1, fast-xml-builder@1, js-cookie@3, serialize-javascript@6, cross-spawn@5, tmp@0.0.33.

**GOTCHA (cost a wasted install): pnpm 11 IGNORES `pnpm.overrides` in package.json** when a `pnpm-workspace.yaml` exists — prints `The "pnpm" field in package.json is no longer read`. Overrides MUST go in `pnpm-workspace.yaml` under `overrides:`. That's where they live now (alongside the existing `allowBuilds:` block).

Residual 13 high (intentionally NOT fixed — all build/dev-time or major-jump-only):
- `tar@6.2.1` (6 advisories) — fix only in major v7; used solely by node-gyp/node-pre-gyp at build time (trusted npm tarballs).
- `undici@5.29.0` (3) — no in-major patch; pulled by `openapi-typescript` (dev codegen).
- `nodemailer` v6 (2) — fix needs MAJOR v7/v9. This is the ONE runtime prod dep left (core Sensor email/SES). Needs a deliberate Class-C regression decision before bumping.
- `parse-git-config` (1) — dev tooling, fix is major v1->v3.
- `hoek` (1) — deprecated; `hoek@6.1.4` does not exist on npm (latest is 6.1.3); real fix = parent migrate to @hapi/hoek.
- Bigger lever for the rest of the noise: `aws-sdk` v2 (devDep) -> @aws-sdk v3 migration (large, separate project).

Pre-existing breakage (NOT caused by these changes, confirmed by building/testing at HEAD too):
- `pnpm build` (`tsc`) emits exactly 1 error: socket.io@4.8.3 `dist/index.d.ts` `Module '"http"' has no default export` — tsconfig has no `esModuleInterop`/`skipLibCheck`; tsc still emits JS (no `noEmitOnError`). socket.io version is unchanged by the security work.
- `pnpm test:unit` dies immediately: `require is not defined in ES module scope` (ts-node/mocha ESM mismatch on this Node 24 box).
