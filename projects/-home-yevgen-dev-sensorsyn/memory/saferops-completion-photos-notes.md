---
name: saferops-completion-photos-notes
description: safer-ops completion photos+notes feature — Sensor complete API accepts evidence; proxy S3 upload design; jobs-detail agency-branch timestamp-swap bug; evidence read needs admin-route for SUB_ADMIN depot operators
metadata: 
  node_type: memory
  type: project
  originSessionId: 3e7ae728-22e0-442f-8046-733c978c4fb5
---

Completion photos + notes added to the safer-ops installer flow (built 2026-06-10, [[installation-flows-old-and-new]]). Mirrors the native app's Complete Job screen.

Key facts (verified in sensor-alarm-backend source):
- `PUT /users/jobs/complete` already accepts `serviceStaffNotes` (Joi rejects empty string — omit when blank) and `images: [{mediaFile, mediaDate}]` → Media rows (listingType 'job') + async timestamp overlay to `timestamp/{name}`. **No Sensor backend change needed.**
- `POST /users/presigned_url` `{files:[names]}` → `data:[{url,imageName}]`, 5-min S3 PUT urls, auth middleware commented out.
- `GET /users/jobs/{id}` returns serviceStaffNotes + images with mediaFile swapped to a signed GET url for ALL user types. **Backend quirk:** the AGENCY/TRADE_PERSON branch's `if (jobData?.images && jobData.length > 0)` is buggy (object has no .length) so the timestamp-variant swap never runs there — those sessions get the ORIGINAL image signed (no 404-while-overlay-pending window). AGENT/SERVICE_STAFF branches do swap.

safer-ops design decisions:
- Browser → safer-ops API multipart (`POST /api/kits/:kitId/photos`, @fastify/multipart, 10MB/file, ≤10 files) → API presigns + PUTs to S3 server-side via raw fetch (NO Sensor token/correlation header to S3). Avoids S3 CORS changes.
- Filenames server-generated `{jobId}.{uuid}.jpeg` (iOS convention); completeKit re-validates each ref against `^{jobId}.{uuid}.jpe?g$` → `invalid_photo_ref` 400.
- Refs held client-side until Complete; reload pre-complete orphans S3 objects (harmless, no Media row until complete). Notes ≤500 chars (native parity), both optional.
- Read-back: lazy `GET /api/kits/:kitId/evidence` (completed/assigned only), React Query key includes kit.jobId (codex P2: kit reuse must not serve old job's evidence).
- Client compresses via canvas (max 1920px JPEG q0.8, `apps/web/src/lib/image.ts`) — handles iOS HEIC via createImageBitmap.

Status: tests green, typecheck/build clean, codex-clean. **Prod e2e of the write path NOT yet run** — plan step: real installer phone test, verify log chain kits.photos→sensor.s3_put→kits.complete.result under one correlationId, check tbl_jobs.serviceStaffNotes + Media rows, photos visible in native app.

**PROD BUG found+fixed 2026-06-11 (first real exercise):** evidence read 404'd for every depot viewer. `GET /users/jobs/:id` dispatches on the session userType — AGENT/SERVICE_STAFF/AGENCY/TRADE_PERSON only; SUB_ADMIN/SUPER_ADMIN tokens are 423'd by AdminUserAuth before the controller (only COMMON_ROUTES = audit-history/invoice-download are exempt), and the userType switch's `default:` throws 400. Depot operators are SaferHomes SUB_ADMINs → can never use the user-side read. Fix (sensor-client `getJobEvidence`): decode the minted token's `userType` claim (`decodeSensorTokenPayload`; SUPER_ADMIN=1, SUB_ADMIN=8) → admin sessions go straight to `GET /admins/jobs/:id` (AdminAuth admits ONLY those two; same payload shape, controller signs image urls); others use /users with a 400/404/423→admin fallback that preserves the original error unless the fallback 5xxs. Don't probe-first: requestJson treats 423 as expiry and force-refreshes (spends the rotating OIDC refresh token) — the polling evidence view would re-mint per read.

Gotcha hit during testing: full `pnpm test` needs the local MariaDB up (`bash scripts/db-start.sh`, port 13306) — without it logins 500 after 10s; and two concurrent suite runs stomp each other (both `deleteMany` the "Route test" kit prefix in beforeEach) producing FK-violation 500s that look like real bugs.
