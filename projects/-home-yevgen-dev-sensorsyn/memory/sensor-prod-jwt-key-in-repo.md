---
name: sensor-prod-jwt-key-in-repo
description: "REMEDIATED 2026-06-14 — committed prod OIDC/JWT signing key externalised to Secrets Manager + rotated out (dead); active key SM-only; reset-flow weakness + non-prod keys still open"
metadata:
  node_type: memory
  type: reference
  originSessionId: f36d7861-f9b5-4f62-af73-178ecb331372
---

**Remediation complete 2026-06-14.** Full exposure history, Phase-0 externalisation,
3-phase rotation, and the key-mapping incident are archived to
`docs/investigations/2026-06-14-sso-jwt-key-leak-remediation.md` (plan:
`~/.claude/plans/wondrous-tinkering-yeti.md`).

**Durable state:**
- Active prod signing key = `biM4zB_XMt8XRg1l-rW6SWB7Ml4KDgOxU5LIpyy546w`,
  generated fresh, **Secrets-Manager-only** (never committed). The committed
  `vXYg`/`sqy3` keys in git are dead (can't sign or verify).
- Key config lives in `SSO_SIGNING_JWKS` (JSON array, [0]=active signer, all verify;
  in BOTH `sensor-prod` and `sensor-prod-sso` secrets) + provider `SSO_COOKIE_KEYS`
  (also rotated). Verifiers resolve by header `kid` → rotation-safe.
- **Backend and provider MUST share the same signing key** — backend
  `TokenManager.verifyToken` validates provider OIDC tokens (cbpf login). Putting a
  different key in `sensor-prod` broke ALL agent logins for ~50 min on 2026-06-14.
  When rotating: exercise a TokenManager-verify flow, not just the provider JWKS.
- Both services EC2+pm2 via CodeDeploy BLUE/GREEN — diagnose GREEN instances only;
  provider is a single instance so pm2 restart = few-sec login blip (prefer pipeline).

**Still open (low-pri):**
- `resetPassword`/`resetPasswordWithOTP` (`userAccounts.entity.ts`) verify JWT
  signature but never compare the embedded token to `tbl_admins.token` (only
  non-empty check) — reset-flow weakness, unfixed.
- Non-prod committed keys (qa/sandbox/uat) unrotated; git history not scrubbed.

See [[oidc-expected-issuer-localhost]], [[sso-provider-unpinned-rebuild-trap]].
