---
name: no-staging-commands-in-handoffs
description: "Don't spell out git add/staging commands when handing off — the user stages themselves"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: e1816bf4-a5fe-47d0-b000-0a73e175e132
---

When prepping a change for the user to commit, do NOT include `git add`/staging command blocks in the summary. The user knows how to stage and finds the spelled-out commands noise.

**Why:** redundant — the user does their own commits/pushes ([[global rule]]) and is fluent with git.

**How to apply:** report what changed and why, the verification status, and a suggested commit message if useful. Skip the staging commands. Still flag anything they'd want to consciously include/exclude (e.g. a stray version bump, PII in docs/samples).
