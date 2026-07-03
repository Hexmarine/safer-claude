---
name: memory-hygiene-process
description: "How to maintain this memory store (agreed 2026-07-03): index = one-line hooks ≤200 chars; detail flows file → docs/investigations, never up into the index; archive+shrink on incident close; 16KB index tripwire"
metadata: 
  node_type: memory
  type: feedback
  originSessionId: 7be13f6f-5a2b-47ad-bd20-d7e3dcadb3d0
---

Agreed with the user 2026-07-03 after a compaction (index had hit 27KB vs a
24.4KB load limit and was silently truncating; long index entries had also
fossilised — two contradicted their own topic files).

**The rules (apply at write-time, not in bulk cleanups):**

1. **Direction of detail.** `MEMORY.md` line = hook only (≤200 chars, no
   root-cause dumps). Topic file = durable facts, gotchas, levers. Full
   incident/investigation narrative = `docs/investigations/` (dated file +
   a row in its README index). Detail flows downward, never up.
2. **Archive on close.** When an incident or investigation resolves, the SAME
   session writes/updates the docs file, shrinks the memory to lesson +
   pointer, and rewrites the index line.
3. **Corrections land everywhere.** When a finding is corrected, update the
   index hook and the file's `description:` in the same session as the body —
   a stale one-liner re-asserts the wrong claim every session.
4. **Git owns workflow state.** Do not trust memory claims like "uncommitted"/
   "deploy pending" — verify with `git status` / `git log -S` / the pipeline
   before repeating or acting on them (a 2026-07-03 audit found 7 memories
   asserting "uncommitted" for work long since merged). Memory records the
   lesson; git records the status.
5. **Size tripwire.** Keep `MEMORY.md` ≤16KB. Above that, run a gardening
   pass: verify files↔index both ways, shrink fat lines, archive closed
   items, delete memories duplicating CLAUDE.md/repo docs, fix dangling
   `[[links]]`.

**Why:** the index is the always-loaded L1 cache; topic files load on recall;
docs are the durable disk. Writing richest at L1 both truncates the tail
(oldest durable knowledge drops first) and lets stale claims persist.

**How to apply:** gardening is ON-DEMAND (no scheduled automation — write-time
habits should make bulk cleanups rare). When closing out an incident memory,
follow the pattern of e.g. [[haven-mass-deactivation-2026-06]] /
[[audit-export-puppeteer-chrome-missing]]: pointer to the docs archive up top,
then only the durable lessons.
