---
name: ux-worktree-run-setup
description: "How to run the safer-ops-ux worktree locally for UI polish, and the mock-auth Sensor-token gotcha"
metadata: 
  node_type: memory
  type: project
  originSessionId: f3155e0d-e4ef-4ef5-afa5-a4c4678895ca
---

UI polish happens in the `safer-ops-ux` worktree (branch `ux-polish`, off `main`), separate from the `safer-ops` main worktree. Periodically merge `ux-polish` into `main`.

Run setup for UI work (read-only, no prod writes):
- Env: copied from `../safer-ops/.env.local` (has the real Sensor service JWT + SSO config), then overrode `APP_MODE=prod-readonly`, `AUTH_MODE=mock`, added `MOCK_PERSONA=depot`. `.env.local` is gitignored.
- `pnpm install`; `pnpm db:start` (shared local Docker MySQL on 127.0.0.1:13306 — DB is local-only, NOT prod); `pnpm prisma:generate`; `pnpm migrate`; then `pnpm dev:api` + `pnpm dev:web` (background). Web on http://127.0.0.1:5175, API on 18080.
- Both worktrees share the same DB + ports (18080/5175) — don't run both at once.
- Flip `MOCK_PERSONA=installer` to exercise the installer "My jobs" nav/view. Switching persona means: restart the API with the new `MOCK_PERSONA`, then mint a FRESH login (the old session cookie stays valid under the same `SESSION_SECRET`, so `/api/me` keeps returning the old persona until you log out/in via the signed-out → Sign in flow).
- Cross-origin nav to the API (:18080) is gated by the Chrome-extension permission; click the in-app Sign-in link instead of navigating the tool to :18080/auth/login.

Non-obvious gotchas:
- The README's `APP_MODE=mock` is STALE. config.ts only accepts `prod-readonly`/`prod-controlled-write`; `dev-host.sh` (`pnpm dev`) is now real-Sensor-API-only and demands a real `SENSOR_API_TOKEN`.
- `FakeSensorClient` is now TEST-ONLY (injected via `opts.makeSensorClient`); there is no offline mock Sensor mode at runtime.
- With `AUTH_MODE=mock`, login does NOT capture a per-operator Sensor token, so `/api/devices` fails with "Operator Sensor token unavailable; re-login required" and the Devices view spins on "Loading devices". To get live device rows you must use real SSO login (`AUTH_MODE=sso`). Kits work under mock auth (stored in the local DB).
