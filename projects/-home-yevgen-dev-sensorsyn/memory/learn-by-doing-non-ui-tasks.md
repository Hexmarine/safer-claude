---
name: learn-by-doing-non-ui-tasks
description: "Learn-by-Doing / TODO(human) hand-offs must be non-UI (logic/backend/algorithm/data), never CSS or visual styling"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 7f2c795b-1095-4005-9ded-cc69a2bef7fb
---

When the Learning output style calls for a "Learn by Doing" / `TODO(human)` hand-off, give the user **non-UI** tasks — backend logic, algorithms, data-shape / validation decisions, auth/guard rules, business logic. **Do not** hand off CSS, visual styling, hover/focus treatments, layout, or copy. Complete UI/styling work myself.

**Why:** stated preference 2026-06-26 after I handed off the pencil/Cancel hover-and-focus CSS treatment in the safer-ops device-location editor ("update the rule to give me non-ui tasks").

**How to apply:** still do the 2–10 line collaboration hand-offs the output style asks for, but pick the meaningful *non-visual* decision (e.g. a guard condition, a parsing/normalisation step, an edge-case branch, a data-merge rule). If the only open decision is visual, just implement it and skip the hand-off.
