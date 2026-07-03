---
name: safer-ops-local-boot-profile
description: How to boot safer-ops locally for /verify or UX review — there is NO offline mode; mock auth + prod-readonly is the verify-safe profile
metadata: 
  node_type: memory
  type: project
  originSessionId: 60286e75-76eb-4972-96c0-5f812d8a1940
---

Booting `code/safer-ops` locally (pnpm monorepo: apps/web + apps/api + packages/shared,
Prisma). Verified working 2026-06-21 driven headlessly via [[playwright-mcp-headless-setup]].

**There is NO fully-offline mode.** `.env.example` says it outright: "there is no mock
Sensor backend — the API always talks to the real Sensor API." So safer-ops always needs
a real `SENSOR_API_TOKEN` and makes real calls to `api.sensorglobal.com`. Blast radius is
controlled by two flags, NOT by network isolation:

- `APP_MODE`: `prod-readonly` (safe, no writes) | `prod-controlled-write` (attach/pair/
  test/complete perform REAL Sensor device-operation writes to prod — dangerous).
- `AUTH_MODE`: `mock` (mints a local session, `MOCK_PERSONA=depot|installer`, no SSO) |
  `sso` (real prod SSO login via auth.sensorglobal.com).

**Verify-safe profile = `AUTH_MODE=mock` + `APP_MODE=prod-readonly`.** Local depot/installer
session, zero prod SSO, real prod reads only, no write capability. Squarely inside the
"read & diagnose" rule.

**WARNING:** the checked-in `.env.local` (as of 2026-06-21) is the PROD profile —
`APP_MODE=prod-controlled-write` + `AUTH_MODE=sso` + real token. Do NOT boot it as-is for
a demo. Override inline, leave the file untouched:
```
cd code/safer-ops; set -a; source .env.local; set +a
export AUTH_MODE=mock APP_MODE=prod-readonly MOCK_PERSONA=depot
pnpm dev   # run in background
```

Boot facts: MySQL runs in Docker (`safer-ops-mysql`, `127.0.0.1:13306`, was already up).
Web → `http://127.0.0.1:5175`, API → `:18080`, Vite proxies `/api` + `/auth`. Deps already
installed. `pnpm dev` = `scripts/dev-host.sh`; dev scripts do NOT source `.env*` — they
trust the shell env and fail loud. Comes up in ~1s.

**First step of any verify run:** hit `GET http://127.0.0.1:18080/api/status` — cheap proof
the profile is safe. Safe profile shows `sso: "SSO mock"` + `sensorApi: up (NNN)` =
"local session, prod reads only" before a single page loads. `pnpm dev:web` alone renders
the UI shell but API screens fail (no data) and makes zero prod calls.
