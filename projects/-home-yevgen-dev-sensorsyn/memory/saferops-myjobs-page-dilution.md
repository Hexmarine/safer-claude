---
name: saferops-myjobs-page-dilution
description: "My-jobs page-dilution bug (Shane saw 3 of ~200 open Syncom jobs) — Sensor pages ALL statuses createdAt DESC, safer-ops filtered open client-side; fix = status_filter=10 + pagination (2026-06-10)"
metadata: 
  node_type: memory
  type: project
  originSessionId: e6a7bb8c-3d39-4767-856c-ab3ae181f1d4
---

**Bug (reported 2026-06-10):** Shane Sykes (Haven's Syncom installer) saw only 3
jobs in safer-ops "My jobs" (6384, 6132, 6119) while Sensor showed ~196 pending
for Haven. Root cause = **page dilution**: `getMyJobs` fetched ONE page
(`/users/jobs?limit=25&page=1`, createdAt DESC, ALL statuses) then filtered
open client-side. Syncom (53410) has 566 jobs, ~200 open — the 25
most-recently-created rows were dominated by completed/rejected work, leaving
exactly 3 open survivors. NOT an identity/scoping problem.

**Shane's identity:** two accounts on shane.sykes@syncom.com.au — **53517
(userType 4 TRADE_PERSON, the SSO winner per lowest-id rule)** and 59289
(userType 5), both `traderPerson = 53410` (Syncom Group). Prod log proof:
`jobs.mine` subject 53517 / traderPerson 53410, `jobs.mine.result count:3`.
As an MTS-class login he legitimately sees ALL open Syncom jobs (incl. ones
serviceStaffId'd to other staff) — that's Sensor's model.

**Fix (sensor-client.ts getMyJobs + job-routes + InstallerView, 2026-06-10):**
- pass `status_filter=10` (= Sensor `JOB_LIST_CRITERIA_MTS.PENDING` →
  `status IN [PENDING, ACCEPTED, NOE_SCHEDULED]`) — server-side filter, BUT it
  only applies when `sessionData.userType == TRADE_PERSON(4)`
  (jobs.entity.ts switch); service-staff sessions ignore it silently;
- paginate (pageSize 50, `ceil(limit/50)+1` pages max) collecting open rows
  until `limit`, stop on short page — this is the fallback that still helps
  type-5 sessions;
- route limit max 50→200, InstallerView requests limit=200 (no pager in the
  on-site list; a low cap silently hides assigned work).

Sensor filter map for trade-person sessions lives at jobs.entity.ts ~1940
(`JOB_LIST_CRITERIA_MTS`: PENDING=10, OPEN=11 is agency-only). JOB_STATUS:
1 Pending, 2 Accepted, 3 Rejected, 5 Completed, 9 Closed.

**"Assigned to me" toggle (same day, Shane's follow-up ask):** `/api/jobs/mine?scope=mine|company`
(default company) + Mine/All pills in InstallerView (default Mine, counts on
both — never silently hides). "Mine" = job's `serviceStaffId` OR `assigneeId`
∈ {subject ∪ `_accountIds`} — **NOT traderPerson** (that's the whole company).
`_accountIds` = ALL same-email sibling account ids, captured from the login
chooser's candidate list in `chooseAccount` (auth.ts) and surfaced as
`OperatorSession.accountIds`; needed because portal "Assigned To" points at
Shane's TYPE-5 sibling (59289), not his login subject (53517). Pure filter =
`filterAssignedJobs` (job-routes.ts, unit-tested). **Codex-hardened (4 rounds,
each found a real bug):** (1) route fetches up to 500 (not the display limit)
BEFORE filtering, else assigned jobs past the cap vanish; (2) scope switch
clears `selectedJobId` (stale selection loses the Accept gate); (3) the
assigneeId fallback excludes the session's `traderPerson` (an owner whose
email also holds the COMPANY account would otherwise claim the whole pool as
"mine"); (4) but only when traderPerson !== subject (self-referential claim
must not veto a solo trade person's own jobs). **Caveats:** sessions from
before the claim existed have no accountIds → Mine undercounts until
re-login (logged as `jobs.mine.legacy_session`); Shane's Mine list = the 10
jobs serviceStaffId=59289 — 6384/6132/6119 are unassigned/Troy's, so they only
show under "All company jobs" until ops sets Assigned To. Open Syncom staff
load (2026-06-10): NULL 144, Troy 53562=16, 53561=12, Shane 59289=10, 53563=9.

**MySQL enum gotcha (burned twice this session):** `tbl_alarms.status` and
`tbl_admins.status` are `enum('0','1',...)` — numeric `WHERE status=1` matches
enum INDEX 1 = value '0'. Always compare as STRING: `status='1'`.

**Backlog truth (2026-06-10):** of Syncom's 196 open jobs, 191 installation
jobs sit on properties with ZERO active devices = genuine never-installed
backlog (all past due Feb–Apr) — NOT closable cruft. Close-out candidates on
device-bearing properties: 6132 (Sanders Rd install, 4 devices — likely done
but never completed), 4266, 5915 (1 device each, partial?).

Related: [[installer-identity-model]], [[saferops-job-import]],
[[saferops-test-accounts-and-duplicates]] (lowest-id SSO rule reconfirmed).
