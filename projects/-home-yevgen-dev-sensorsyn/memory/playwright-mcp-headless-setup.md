---
name: playwright-mcp-headless-setup
description: "How browser automation works on this headless EC2 box — use the Playwright MCP (headless Chromium), NOT claude-in-chrome; the executable-path fix that made it work"
metadata: 
  node_type: memory
  type: project
  originSessionId: 60286e75-76eb-4972-96c0-5f812d8a1940
---

Browser automation on the [[workstation-setup-ec2]] box (no DISPLAY, no desktop
Chrome, no GUI):

- **Use the Playwright MCP (`mcp__playwright__*`), not `claude-in-chrome`.**
  `claude-in-chrome` is an *attach-to-your-desktop-Chrome-via-extension* bridge —
  it launches nothing and has nothing to attach to on a headless server. Playwright
  *launches its own* Chromium and runs headless with no display. Confirmed working
  2026-06-21.
- **The fix that was needed:** `@playwright/mcp` defaults to the branded **"chrome"**
  channel (`/opt/google/chrome/chrome`), which isn't installed. `--browser` only
  accepts branded channels (chrome/msedge/firefox/webkit), NOT "chromium". Playwright's
  *bundled* Chromium IS installed (`~/.cache/ms-playwright/chromium-1228/chrome-linux/chrome`,
  Chromium 149). Fix = add `--executable-path <that path>` to the playwright MCP args.
- **Config location:** `/home/ubuntu/.claude.json` → `mcpServers.playwright.args`
  (also the `projects["/home/ubuntu"].mcpServers.playwright` entry). Server reads config
  at launch only → after editing, reconnect via `/mcp` (or restart session) before it
  takes effect. Full args now: `@playwright/mcp@latest --headless --isolated
  --executable-path .../chromium-1228/chrome-linux/chrome --output-dir
  /home/ubuntu/dev/sensorsyn/.playwright-mcp`.
- **Artifacts:** MCP output root is the workspace root `/home/ubuntu/dev/sensorsyn`
  (NOT a git repo — artifacts can't dirty any nested repo). `--output-dir` now
  contains screenshots + logs under `.playwright-mcp/`. Screenshot filenames must be
  relative / inside an allowed root (`/tmp` is rejected).
- `--isolated` = no saved profile, so any authenticated flow needs creds supplied
  each run. Subagents must `ToolSearch` the `mcp__playwright__*` tools themselves
  (session-connected but deferred).

Enables browser-driven `/verify` and live `ux-operator-reviewer` passes. See
[[safer-ops-local-boot-profile]] for the verify-safe way to boot safer-ops to drive.
