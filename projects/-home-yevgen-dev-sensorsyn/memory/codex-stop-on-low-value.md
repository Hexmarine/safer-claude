---
name: codex-stop-on-low-value
description: When to STOP iterating on codex review findings instead of fixing every one
metadata: 
  node_type: memory
  type: feedback
  originSessionId: e097111e-3354-4441-a46c-63f64ec949b7
---

When running `codex review` in a fix→re-review loop, **stop once the remaining
findings are non-essential / low-probability** (rare races, defensive edge cases,
cosmetic nits) rather than chasing every pass to zero. Judge each finding by
likelihood × impact; fix the real ones, and explicitly call it "good enough for
review" when what's left is increasingly improbable.

**Why:** codex resurfaces progressively narrower edge cases each round — past a
point it wastes time/tokens for marginal correctness gain. The user agreed (this
session, after ~6 rounds on intricate cross-system on-site-add logic): "if codex
is picking on non-essential low probability, let's stop and not waste time."

**How to apply:** after each codex round, triage — high-prob or data-loss/strand
bugs → fix; rare concurrency races / theoretical-only / style → summarize them for
the user and STOP, don't auto-fix. Surface the judgement ("remaining findings are
low-probability races; stopping") so the user can override.

Related: [[codex-review-finishing-step]].