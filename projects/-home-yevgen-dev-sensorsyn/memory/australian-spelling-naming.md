---
name: australian-spelling-naming
description: "Use Australian/British spelling in new code identifiers, types, and comments (normalise, not normalize)"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 37a45498-e9ae-422d-b657-dcf4449c5278
---

The user wants **Australian/British spelling** in code I author — identifiers, type names, and comments: `normalise`/`normalised`, `behaviour`, `unauthorised`, `colour`, `cancelled`, `licence`, etc. (not the American `-ize`/`-or`).

**Why:** stated preference (Safer Homes is an AU company). Given when reviewing the installer-serial-lookup plan ("Use Australian like naming i.e normalise instead of normalize").

**How to apply:** new functions/vars/types/comments → British spelling. BUT **reuse existing symbols under their current (often American) names** — e.g. the existing `normalizeSerial` helper in `code/safer-ops/apps/api/src/kits.ts` stays `normalizeSerial`; don't rename established code just to re-spell it (churn/diff noise). Only new names you introduce follow the convention. Applies across the repos in this workspace.
