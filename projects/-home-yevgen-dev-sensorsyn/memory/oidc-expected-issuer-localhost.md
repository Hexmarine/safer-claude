---
name: oidc-expected-issuer-localhost
description: Sensor backend needs OIDC_EXPECTED_ISSUER=http://localhost:4100 in the sensor-prod secret for the per-user SSO token exchange to verify
metadata: 
  node_type: memory
  type: project
  originSessionId: 37a45498-e9ae-422d-b657-dcf4449c5278
---

The Sensor backend's `/users/sso/exchange` (`sso.controller.ts verifySsoIdToken`)
verifies safer-ops' OIDC id_token in two steps: fetch JWKS from
`${OIDC_ISSUER}/jwks`, then check the token's `iss` against
`OIDC_EXPECTED_ISSUER || OIDC_ISSUER`.

The SSO at `https://auth.sensorglobal.com` (mis)stamps tokens with
`iss=http://localhost:4100` (its `OIDC_ISSUER` is set to that dev value). So the
`sensor-prod` secret must carry **two distinct** issuer keys:

- `OIDC_ISSUER=https://auth.sensorglobal.com` — the *reachable* base used for the
  JWKS fetch + discovery (must NOT be localhost or the JWKS fetch dies on the EC2 box).
- `OIDC_EXPECTED_ISSUER=http://localhost:4100` — matches the bogus `iss` the SSO
  actually emits, so the issuer check passes.

Confirmed 2026-05-23: with `OIDC_EXPECTED_ISSUER` absent, exchange failed
`jwt issuer invalid (expected https://auth.sensorglobal.com, token iss=http://localhost:4100)`.
Adding it + `sudo pm2 reload all` on both ASG instances fixed it (session row
flipped to `has_sensor_tok=1`, 423 admin-wall reached as expected).

The proper-but-deferred fix is to make the SSO stamp `iss=https://auth.sensorglobal.com`
(changes discovery/JWKS/every client's tokens → coordinated change). Until then
the localhost value is correct: it binds the exchange to exactly what this SSO
emits. Reload via `scripts/sensor-restart.sh`. Related: [[sensor-write-auth-agency-token]].
