# Completion photos + notes for the safer-ops installer flow

## Context

The native Sensor installer apps (Android/iOS) let the installer attach **notes + up to 10 photos** when completing an installation job. The safer-ops "safer flow" currently completes the job bare (`PUT /users/jobs/complete` with only `{jobId}`). We're adding the same evidence capture to safer-ops.

Key discovery: **no Sensor backend changes needed.** The existing `PUT /users/jobs/complete` already accepts `serviceStaffNotes` (optional, stored in `tbl_jobs.serviceStaffNotes`, VARCHAR 1000) and `images: [{mediaFile, mediaDate}]` (creates `Media` rows, `listingType='job'`, async timestamp overlay). Photos go to S3 via `POST /users/presigned_url` → PUT to the signed URL (5-min expiry). Job detail `GET /users/jobs/{id}` returns notes + images with signed GET URLs.

Decisions made with the user:
- Notes and photos both **optional** (keep the 3-tap happy path).
- Photos upload **by proxy through the safer-ops API** (browser → multipart → API → presign → server-side S3 PUT). No S3 CORS changes; full traceability logging.
- After completion, the kit panel **shows the evidence read back** from Sensor (lazy fetch).

Design choices:
- Upload at pick time; client holds `{mediaFile, mediaDate}` refs until Complete sends them. Reload before Complete orphans S3 objects — harmless, documented.
- Server generates filenames `{numericJobId}.{uuid}.jpeg` (iOS convention); complete re-validates each `mediaFile` matches `^{kit.jobId}\.[uuid]\.jpe?g$` so an installer can't attach another job's keys.
- Client-side canvas compression (max 1920px, JPEG q0.8, no deps) — normalizes iOS HEIC too.
- Sensor is sole source of truth — **no Prisma schema change**; traceability via logs naming exact `mediaFile`s (per CLAUDE.md rule).
- Notes max 500 chars (native UI parity). Never send empty-string notes (Sensor Joi rejects `""`).

Repo: `/home/yevgen/dev/sensorsyn/code/safer-ops`. Tests are `node:test` with `FakeSensorClient` + `app.inject`. `@fastify/multipart` is NOT yet a dependency (Fastify default bodyLimit 1MiB → multipart plugin with own limits is the right path).

## Files to modify

### 1. `packages/shared/src/index.ts` — types
```ts
export interface KitCompletionImageRef { mediaFile: string; mediaDate: string; }
export interface KitCompleteInput { notes?: string; images?: KitCompletionImageRef[]; }
export interface KitPhotoUploadResult { images: KitCompletionImageRef[]; }
export interface KitCompletionEvidence {
  notes: string | null;
  images: Array<{ id: string; url: string; mediaDate: string | null }>;
}
export const KIT_COMPLETION_MAX_PHOTOS = 10;
export const KIT_COMPLETION_MAX_NOTE_CHARS = 500;
```

### 2. `apps/api/src/sensor-client.ts` — three changes
- **`uploadJobImages({jobId, files: [{data: Buffer, mimetype}]}, options?)`**: `assertWriteAllowed()`; generate `{numericJobId}.{randomUUID()}.jpeg` names; `postJson("/users/presigned_url", {files: names})`; per file a **raw `fetch` PUT** (NOT through `requestJson` — no Sensor token must reach S3), `content-type: application/octet-stream` (matches Android + presign). Log per file `{operation: "sensor.s3_put", jobId, mediaFile, bytes, status, ms, correlationId}`; non-2xx → error log + `SensorClientError("s3_upload_failed", ..., 502)`, fail whole call. Return `[{mediaFile, mediaDate: ISO-now}]`. Presign 5-min expiry is consumed immediately server-side — safe.
- **Extend `completeJob`** (line ~447) → `completeJob(jobId, extras?: {serviceStaffNotes?, images?}, options?: WriteOptions)`. Body spreads notes only when non-empty, images only when non-empty array. **Preserve the 402 → idempotent-success catch.**
- **`getJobEvidence(jobId): Promise<KitCompletionEvidence>`**: `getJson("/users/jobs/{id}")`, unwrap like `normalizeJob`, extract `serviceStaffNotes ?? null` + `images[] → {id, url: image.mediaFile (already a signed URL), mediaDate}`.
- **`sensor-client-fake.ts`**: override all three; `uploadJobImagesCalls` / `completeJobCalls: [{jobId, extras}]` capture arrays (pattern: `pairStockCalls`); deterministic fake refs `{jobId}.fake-uuid-N.jpeg`; canned evidence.

### 3. `apps/api/src/kits.ts` — service layer
- **`uploadKitPhotos(sensorClient, kitId, files, logger?)`**: `requireEditableKit`; status must be `attached|testing|tested` else `KitError("kit_not_onsite", ..., 409)`; `kit.jobId` required else `KitError("reservation_incomplete", ..., 409)`; delegate to `uploadJobImages`; RESULT log `{operation: "kits.photos.result", kitId, jobId, uploaded: [mediaFile names]}`.
- **Extend `completeKit`** (line ~1648) with `input?: KitCompleteInput`: validate each `images[].mediaFile` against `^${kit.jobId}\.[0-9a-f-]{36}\.jpe?g$` → `KitError("invalid_photo_ref", ..., 400)`; pass `{serviceStaffNotes: input?.notes?.trim() || undefined, images: input?.images}` to `sensorClient.completeJob`; RESULT log with `noteChars` + `imageFiles`.
- **`getKitEvidence(kitId)`**: load kit, require `jobId`, delegate to `getJobEvidence`.

### 4. `apps/api/src/kit-routes.ts` + app setup — routes
- `pnpm --filter @safer-ops/api add @fastify/multipart`; register in `buildApp` before routes: `limits: {fileSize: 10*1024*1024, files: 10}`.
- **`POST /api/kits/:kitId/photos`** — dedicated handler (multipart can't ride `runKitAction`), but reusing runKitAction's exact authz: `requireUser` → non-depot must pass `installerOwnsKit` (404 otherwise; do NOT use `requireKitReadable` — it admits claimable pool kits). START log `kits.photos`; iterate `request.files()`; reject bad mimetype (only `image/jpeg`/`image/png`) → logged 400 `unsupported_photo_type`; size-limit truncation → 400 `photo_too_large`; >10 parts → 400 `too_many_photos`; respond `{data: {images}}`. Errors via `sendKitError`. Web sends one file per request (per-photo progress/retry); server accepts up to 10.
- **Complete route** (line 527): keep `runKitAction`; zod-parse body first: `z.object({notes: z.string().trim().max(500).optional(), images: z.array(z.object({mediaFile: ..., mediaDate: ...})).max(10).optional()}).optional()`; parse failure → logged 400 `invalid_complete_body`; pass into `completeKit`.
- **`GET /api/kits/:kitId/evidence`** — same depot-or-owner authz; 409 `kit_not_completed` unless `status === "completed"`; RESULT log `{kitId, jobId, imageCount, imageIds}`; respond `{data: KitCompletionEvidence}`.

### 5. `apps/web/src/lib/api.ts` — `apiUpload<T>(path, form: FormData)` (fetch POST, no content-type header, same error mapping).

### 6. `apps/web/src/lib/image.ts` (new) — `compressPhoto(file): Promise<Blob>`: `createImageBitmap` → canvas scale to max-dim 1920 → `toBlob("image/jpeg", 0.8)`; decode failure falls back to original if ≤10MB else error.

### 7. `apps/web/src/views/KitDetailPanel.tsx` + `styles.css` — UI
- State: `completionNotes` string; `photos: [{key, previewUrl, status: uploading|uploaded|failed, ref?}]`; reset on `kit.id` change (existing `useEffect` pattern ~line 80).
- **Pre-complete section** in the On-site FlowPanel (when installer + bound + status `attached|testing|tested`), under the Test/Complete `flow-actions`: textarea (maxLength 500 + counter), "Add photos" button → hidden `<input type="file" accept="image/*" capture="environment" multiple>`; per pick: objectURL preview → `compressPhoto` → `apiUpload` to `/photos` → flip to uploaded/failed (tap-to-retry); thumbnail grid with remove (X). Disable picker at 10.
- **Gate Complete** while any photo is `uploading` (extend the complete-step disabled condition; hint text).
- **Wire complete**: `runAction` mutationFn (line 103) → `apiPost(path, action === "complete" ? completeBody() : undefined)`; `completeBody()` = `{notes: trimmed || undefined, images: uploaded refs}` (omit empty). Clear state + revoke objectURLs on success. Body stays `undefined` for all other actions — no behavior change.
- **Post-complete gallery**: `useQuery(["kit-evidence", kit.id], enabled: status==="completed", staleTime 5min)` → render under `ReservationSummary` (~line 804): notes block + thumb grid linking to signed URLs (`target="_blank"`). `onError`-hide tolerant thumbs (Sensor's timestamp overlay is async — brief 404 right after complete is native-parity). Render nothing when empty.
- CSS: `.completion-notes`, `.photo-grid`, `.photo-thumb`, `.photo-thumb-remove`, `.photo-thumb.failed` in `styles.css`, matching existing vars + mobile `@media` block (~line 2679).

## Tests

`apps/api/src/kit-routes.test.ts` (node:test + FakeSensorClient + `app.inject`):
- Photos: kit driven to `attached` → hand-built multipart Buffer payload (explicit boundary header, no new dev dep) → 200 with refs; `ready` kit → 409; `text/plain` part → 400; non-owner installer → 404.
- Complete: body `{notes, images}` → assert `fake.completeJobCalls[0].extras`; foreign-jobId mediaFile → 400 `invalid_photo_ref`; **no body still completes (regression)**.
- Evidence: completed → 200; non-completed → 409.

`apps/api/src/sensor-client.test.ts` (scripted-fetch pattern ~line 42): `uploadJobImages` — presign→PUT order, S3 PUT has **no** `access_token` header + octet-stream content-type, filename regex, 403 PUT → 502 error. `completeJob` — body includes notes/images, omits empty notes, 402 → alreadyComplete.

## Verification

1. `pnpm --filter @safer-ops/api test` + typecheck; `pnpm --filter @safer-ops/web typecheck` + build.
2. Mock mode (`APP_MODE=mock AUTH_MODE=mock`): full draft→pair→attach→test flow; add notes + 2 photos; Complete; evidence gallery renders.
3. Prod sandbox (`prod-controlled-write`), real installer login on a phone: attach sandbox kit, 2 camera photos (network tab: <1MB after compression), complete with notes. Verify pod-log chain `kits.photos` → `sensor.request POST /users/presigned_url` → `sensor.s3_put` → `kits.complete.result` under one requestId/x-correlation-id; verify `tbl_jobs.serviceStaffNotes` + Media rows in sensor-mysql; confirm the photos show on the job in the Sensor portal; reload kit → evidence gallery reads back.
4. Negative: re-complete (402 idempotent), foreign-kit upload (404), 11th photo blocked in UI.

## Risks
- Presign 5-min expiry: consumed immediately server-side — safe.
- S3 orphans on reload/remove-before-complete: accepted, harmless.
- Sensor async timestamp overlay → brief broken thumb post-complete (native parity; onError hide).
- 10-photo cap enforced client-side + at complete (zod max 10); upload route caps per-request only — uploads alone create no Media rows, so no integrity issue.
