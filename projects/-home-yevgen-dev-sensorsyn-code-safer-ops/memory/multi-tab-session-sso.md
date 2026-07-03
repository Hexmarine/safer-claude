---
name: multi-tab-session-sso
description: "Why depot+installer can't share one browser, and the auto-sign-in/SSO-restart fix for the login \"oops\""
metadata: 
  node_type: memory
  type: project
  originSessionId: 03423da5-b67c-4e2d-895e-e49dabe04230
---

safer-ops auth is a single HttpOnly `safer_ops_session` cookie (server-side
`user_sessions` row) scoped per browser cookie jar — **not per tab**, and cookies
aren't port-scoped (`apps/api/src/config.ts` note). So you cannot be depot in one
tab and installer in another tab of the same browser/profile: logout/login in one
tab affects all tabs. To run both personas at once, use separate cookie jars —
incognito window, a second Chrome profile, or locally `scripts/dev-host-secondary.sh`
(second origin + renamed cookie `safer_ops_session_2`).

The recurring login "OOPS! ... interaction session not found" (seen ~2026-05-28 on
safer-ops.sensorglobal.com) is the same shared-jar problem at the Sensor SSO
(`node-oidc-provider`) layer: two concurrent authorize interactions share the SSO's
browser cookie and clobber each other. Trigger: signing out in tab B logged out tab
A too, then tab A *auto*-redirected itself back into `/auth/login` (App.tsx
`shouldAutoSignIn`), creating a competing interaction that invalidated the
deliberate login in tab B.

**Why:** the auto-sign-in on any 401 silently started SSO flows, racing across tabs.
**How to apply:** fix (committed on a branch ~2026-05-28) was two parts —
1) `apps/web/src/App.tsx`: only auto-redirect on a *fresh* 401 (`hadSession` latch);
a tab that *lost* its session shows a manual "Session ended → Sign in" screen.
2) `apps/api/src/auth.ts` `finishLogin`: on `invalid_login_state` or a restartable
SSO `error` (`invalid_request`/`interaction_required`/`login_required`, not
`access_denied`), restart authorize once via a one-shot `safer_ops_login_retry`
cookie instead of dead-ending on the error.
