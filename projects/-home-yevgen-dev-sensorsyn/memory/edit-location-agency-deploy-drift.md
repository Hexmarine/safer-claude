---
name: edit-location-agency-deploy-drift
description: "Lesson from a false drift alarm: when source seems missing but prod has it, check the branch + git log --all -S before concluding drift. edit-location-agency is live + on master."
metadata:
  node_type: memory
  type: feedback
  originSessionId: 7f2c795b-1095-4005-9ded-cc69a2bef7fb
---

Sensor `PATCH /api/v1/users/alarms/edit-location-agency` (agency-scoped location
edit + `saveAuditHistory` write) is **live in prod and merged to origin/master** in
commit `a06534130` (branch `featre/agency-alarm-location-editing` — note the typo).
An earlier recheck wrongly cried "drift/lost code": the code was invisible only
because the `code/sensor-alarm-backend` checkout was on `feature/deps-upgrade`.

**Why:** point-in-time worktree state is not repo state; a missing symbol on the
current branch proves nothing about master or prod.

**How to apply:** before concluding deploy drift or lost work, run
`git rev-parse --abbrev-ref HEAD` and `git log --all -S <token>`. Prod route
liveness probe: registered PATCH → 423 (auth gate), unmounted path → 404.

Still open: live e2e that an agency edit writes the audit-history row. See
[[saferops-reports-tab]] for the agency-scoped access model this reuses.
