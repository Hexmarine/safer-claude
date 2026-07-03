---
name: installer-identity-model
description: "The three-id Sensor installer identity (login userId vs tradePersonId vs traderPerson) and how safer-ops resolves kit ownership + the on-site test read around it (#62/#83)"
metadata: 
  node_type: memory
  type: project
  originSessionId: 37a45498-e9ae-422d-b657-dcf4449c5278
---

One Sensor installer is **three different ids** (all `tbl_admins.id`): the **login userId** (the SSO `sub`, what safer-ops stores as `OperatorSession.subject`, e.g. trade.test = `59203`), a **tradePersonId** (e.g. `59123`), and a **serviceStaffId** (e.g. `59204`). A sub-account's `tbl_admins.traderPerson` points at its **parent trade person's** id. A job (`tbl_jobs`) is assigned via `tradePersonId`/`serviceStaffId` — NOT the login userId — so none of the three match directly.

**Sensor complete-auth** (`sensor-alarm-backend` middlewares/auth.ts `COMPLETE_JOB`): allows if `session.userId == job.tradePersonId` **OR** `session.traderPerson == job.tradePersonId`. That `traderPerson` link is why login `59203` can complete a job assigned to `59123`.

**safer-ops resolution (#62, shipped 2026-05-27):**
- **The kit owner is stamped from the job's assignee** (`kit.serviceStaffId = job.assigneeId = its tradePersonId`). NOTE: as of the 2026-05-28 pivot this happens at **attach**, not reserve — reserve is gone (see [[prepared-kit-fungible-pool-pivot]]). No hand-typed installer id.
- **Ownership check mirrors Sensor**: `installerOwnsKit` = `kit.serviceStaffId === subject || === traderPerson`; kit-list scoping filters `serviceStaffId IN [subject, traderPerson]` (`kit-routes.ts`).
- **`traderPerson` is captured by decoding the exchanged Sensor token** — the backend embeds `traderPerson` in the USER_LOGIN JWT, so `sensor-exchange.ts` reads it and stashes it in the session claims (`OperatorSession.traderPerson`). No backend change needed for that.

**On-site test read (#83):** `/users/alarms/status-by-serial?propertyId` is `STOCK.view`-gated (installer lacks it) + `assertPropertyVisible` (agency-only). Fix: the route admits the **assigned installer** (`assignedInstallerJobIds` — open jobs where `tradePersonId|traderPerson == userId` or `serviceStaffId == userId`) past the STOCK gate, and `getStatusBySerials` scopes returned rows to those `jobId`s (no cross-job leak). safer-ops reads on the operator token. Merged via Sensor PR #6028; the cleaner-but-deferred alternative is to poll the native-app endpoints instead (see task #85).

Live proof: trade.test (`subject 59203`, `traderPerson 59123`) reserved→attached→tested→**completed** job 6370 (`tradePersonId 59123`) end-to-end. Related: [[stranded-device-detach-recovery]], [[sensor-write-auth-agency-token]], [[installation-flows-old-and-new]].
