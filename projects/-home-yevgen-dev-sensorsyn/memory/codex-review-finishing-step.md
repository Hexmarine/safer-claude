---
name: codex-review-finishing-step
description: "On substantial changes, run a codex review pass per repo before declaring done — it reliably catches cross-layer bugs my own tests miss"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 37a45498-e9ae-422d-b657-dcf4449c5278
---

For substantial changes in this project, the user wants a **`codex review --uncommitted`** pass on each affected repo as the finishing step — after self-review, before declaring the work done. (The codex CLI is installed at `~/.volta/bin/codex`, v0.135.x; the user already uses it.)

**Why:** across this session it found a real bug **every time** (3/3 on the role chooser, 1/1 on observability) — and always the kind a same-author review + green unit tests sail past: a Joi route schema that rejected the new `accountId`, a refresh path that regressed legacy sessions, an `email_verified:'yes'` claim format mismatch (codex cross-read the SSO-provider repo to catch it), and a header value bypassing the column-width clamp. The pattern is **cross-layer gaps** — validation vs handler, one repo's contract vs the other's, prod claim format vs the check — exactly what passes typecheck/tests but breaks in prod.

**How to apply:** finish the code → self-review the diff → `cd <repo> && codex review --uncommitted` for each changed repo (it reviews staged+unstaged+untracked; `| tail` buffers until done, so run in background and read the output file). Fix every real finding (re-typecheck/test), then re-run codex on the repo whose load-bearing code changed to confirm clean. Caveats: it can't combine `--uncommitted` with a prompt; watch the persisted cwd between runs; it also flags unrelated untracked files (e.g. real-data `samples/` CSV) — triage those separately. Pair with the global rule (~/.claude/CLAUDE.md): the user does commits/pushes after the review.
