---
name: workflow-agent-model-choice
description: "Pick an appropriate (cheaper) model for heavy multi-agent Workflow fan-outs; don't default to Opus"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 59277a1d-4a4d-4987-8a7c-9e2520e40c79
---

For heavy dynamic multi-agent Workflow fan-outs (e.g. the 35-agent client-standing-facts build), do NOT default to Opus for every sub-agent — it's often overkill and expensive. Pass `opts.model` on `agent()` to use a cheaper tier (e.g. Sonnet, or Haiku for simple structured-extraction work) when the per-agent task is well-scoped and schema-constrained.

**Why:** the facts build spent ~660k subagent tokens across 35 agents for straightforward verbatim-slice extraction into a strict schema — a smaller model would very likely match quality at a fraction of the cost.

**How to apply:** when authoring a Workflow, evaluate the per-agent task complexity and set `agent(prompt, { model: "sonnet" | "haiku", ... })` accordingly; reserve Opus for genuinely hard reasoning/synthesis steps. Worth a future eval comparing fact quality across models on a sample batch before the next large run. Relates to [[prod-baseline-rebuild-2026-05]].
