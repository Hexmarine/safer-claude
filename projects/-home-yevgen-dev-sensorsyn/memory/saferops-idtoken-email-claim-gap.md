---
name: saferops-idtoken-email-claim-gap
description: Why the safer-ops account-chooser silently never fired in prod — the SSO id_token carries no email claim — and the two-repo fix
metadata: 
  node_type: memory
  type: project
  originSessionId: e9366c96-5c49-46d4-bf5f-0ce419a1ae80
---

**RESOLVED & VERIFIED IN PROD 2026-05-31.** Both halves deployed (sso-provider `claimsParameter` enabled + safer-ops requesting `email`/`email_verified` as id_token claims). Confirmed live: Kristyn's `kristyn.heywood@gmail.com` login now logs `auth.account_choice.pending count:3 candidateIds:["59119","59120","59123"]` (dead sub 59118 correctly excluded) → chooser shown → she picked 59120 (Agency) and logged in. The id_token now carries the verified email. ⚠️ The sso-provider deploy that shipped this also triggered the outage in [[sso-provider-unpinned-rebuild-trap]] — read that before any future IdP rebuild. The root-cause write-up below is retained for reference:

**Root cause (the Kristyn login case):** the safer-ops account-chooser / email-aware Sensor token exchange was **deployed but silently dead in prod** because the SSO **id_token carries no `email`/`email_verified` claim**.

Chain:
- `sensor-alarm-backend` `/users/sso/exchange` (`sso.controller.ts`) resolves which account to mint for from the **id_token's** verified email (`decoded.email` + `isEmailVerifiedClaim(decoded.email_verified)` → `verifiedEmail`). Null verified email ⇒ it skips the candidate lookup and falls back to the **legacy IdP-resolved `sub`** path (`resolveSsoExchange` → `legacy`).
- The SSO provider (`sso-provider`, oidc-provider v7.14.3) runs with oidc-provider's default **`conformIdTokenClaims: true`**, so scope-derived claims (`email`, `profile`) are served **only from the userinfo endpoint** and omitted from a code-flow id_token. `oidc.config.ts` emits `email_verified:'yes'` but only inside the userinfo `claims()` path.
- safer-ops merges userinfo locally (`oidc.ts` `claims = {...idClaims, ...userInfo}`) so it *logs* the email — but `auth.ts` sends the **raw id_token** to the backend, which never sees userinfo. ⇒ `verifiedEmail` is **always null in prod for every login**.

So for single-account users the legacy `sub` mint hits the right row (fine), but it **breaks exactly the duplicate-email/dead-sub case the chooser was built for**: kristyn.heywood@gmail.com → IdP `sub`=59118 (DELETED) → legacy mint → `[sso/exchange] mint blocked: account id=59118 status=2` → safer-ops `auth.persona.unresolved` → depot. The chooser has **never actually engaged in prod**; the earlier "e2e chooser works" was the mock/fake path. Corrects the optimistic "RESOLVED by the role chooser" line in [[saferops-test-accounts-and-duplicates]].

**How it was proven (repeatable):** read real prod id_tokens from safer-ops' own session store and decode them — `kubectl --context safer-ops-prod -n safer-ops exec -i <safer-ops-api pod> -c api -- node - < probe.js`, where probe builds the PrismaMariaDb adapter from the pod's `DATABASE_URL` (mirror `apps/api/src/db.ts`; require `@prisma/client` + `@prisma/adapter-mariadb` by absolute `.pnpm` path — deployed bundle has no top-level node_modules symlinks), reads `user_sessions.claims._oidcIdToken`, and prints `Object.keys(payload)`. Every session's id_token keys were `[at_hash,aud,auth_time,exp,iat,iss,nonce,sub]` — **no email**; the merged session claims *did* have email (from userinfo). Print keys/booleans only, never the token/email value (prod-PII classifier; SSM RunShellScript on the Sensor EC2 box and `env | grep DATABASE` are both blocked).

**Fix (option 2 — targeted, two repos; deploy sso-provider FIRST):**
1. `sso-provider` `src/configs/oidc.config.ts` → `features.claimsParameter: { enabled: true }` (off by default; needed for the provider to honour a `claims` request param).
2. safer-ops `apps/api/src/oidc.ts` `buildAuthorizationUrl` → add `claims={"id_token":{"email":{"essential":true},"email_verified":{"essential":true}}}`. An explicit id_token claims request is honoured regardless of `conformIdTokenClaims`. Backend exchange code is unchanged.
Order matters: if safer-ops sends the `claims` param before the provider enables `claimsParameter`, the authorize request can be rejected. Alternative considered & rejected: `conformIdTokenClaims:false` (one line, but enlarges the id_token for ALL clients incl. the native app). Re-run the decode probe after deploy to confirm the id_token now carries `email`. Refresh path also relies on the grant persisting the requested claims.

See [[sensor-account-inactive-symptoms]], [[saferops-live-trace-rig]].
