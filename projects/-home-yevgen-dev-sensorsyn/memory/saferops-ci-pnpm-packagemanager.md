---
name: saferops-ci-pnpm-packagemanager
description: safer-ops CI/deploy fails ERR_PNPM_BAD_PM_VERSION when package.json packageManager drifts from the pnpm/action-setup pinned version
metadata: 
  node_type: memory
  type: project
  originSessionId: 37a45498-e9ae-422d-b657-dcf4449c5278
---

safer-ops CI (`.github/workflows/ci.yml`) pins pnpm via `pnpm/action-setup@v4` with `version: 10.28.0`. The deploy fails with **`ERR_PNPM_BAD_PM_VERSION` / "Multiple versions of pnpm specified"** when `package.json` `"packageManager"` disagrees with that pin.

**Why it recurs:** the local pnpm (10.28.1, via corepack/volta) silently rewrites `package.json` `"packageManager": "pnpm@10.28.1"` whenever pnpm runs, and that edit rides along in a commit (it happened twice — once on the import-fix commit `73728af`). CI's deliberate pin is 10.28.0, so the mismatch blocks the build.

**How to apply / fix:** keep the two in lockstep. The minimal unblock is reverting `package.json` `"packageManager"` to `pnpm@10.28.0` to match CI (one line). Prevent recurrence with ONE of: `corepack prepare pnpm@10.28.0 --activate` locally, OR `manage-package-manager-versions=false` in `.npmrc`, OR bump `ci.yml`'s `version:` to match and keep them aligned. When prepping a safer-ops commit/deploy, **check `git diff package.json` for an unintended `packageManager` bump.** Also watch for an incidental `"version"` bump (harmless) and the untracked `samples/` dir (contains real agency-59120 property CSV — never `git add` it). Relates to the global rule (~/.claude/CLAUDE.md): the user does commits.
