# Plan: Pin & fix the slow agency dashboard / report endpoints

## Context

During the AWS cost review we traced the "hot" Smoke-API instance and the 60s ALB 504s to
two backend endpoints, not crons:

- **`GET /api/v1/users/dashboard/agency`** — avg **27s**, p99 **64s**, 2,102 calls/24h, 1,397 of them >5s.
- **`GET /api/v1/users/report/summary`** — p99 **60s**.

Root cause (confirmed in code): `fetchDashBoardDataForAgency` fans out **27 independent
queries** via `Promise.all`, so total latency = the single slowest query. Several do
`Shadow.findAll → Properties.findAll → count` (multi round-trip) per call and some use
unindexable date functions. The report has an unbounded `tbl_jobs.findAll` + JS aggregation.
Traffic is otherwise light (3.8 req/s peak), so this is a query-efficiency problem, and the
second ASG instance is currently absorbing these expensive bursts (a reason to keep min=2).

**Goal:** (a) pin exactly which sub-query is the straggler, and (b) add a short-TTL Redis
cache in front of both endpoints (using the near-idle prod Redis) to collapse the repeated
504s and CPU immediately — then land a targeted query/index fix for the pinned straggler.

This is a **Class-C** change to a production smoke-alarm backend. Hard requirement: **response
shape must not change**. Part A is log-only; Part B ships behind a default-OFF flag. Run
`sensor-regression-guard` before shipping. Deploys go via the normal Smoke-API CodeDeploy
(which now also exercises the golden-AMI retention Lambda for the first real time).

Decisions: pin via **both** instrumentation + DB logs; cache TTLs **60s dashboard / 300s report**.

## Files to modify

- `src/controllers/users/dashboard.controller..ts` (note the double-dot) — Part A timing + Part B cache.
- `src/entities/opsReport.entity.ts` — Part B cache (+ optional Part A timing on the jobs scan).
- `src/config/app.ts` and `interfaces/config/app.interface.ts` — new `CACHE` config (edit **both**; tsc-enforced).
- Reuse only (no change): `src/services/redis/main.redis.ts`, `src/utils/requestContext.ts`.

---

## Part A — Pin the slow sub-query (log-only, zero behavior change). Ship FIRST.

### A1. Instrumentation (needs a backend deploy)
In `fetchDashBoardDataForAgency`, after the `readonlyUserId` remap (~line 45), add a local
helper that times each promise and logs one structured line, reusing `getLogger()`
(`src/utils/requestContext.ts`) and the `process.hrtime.bigint()` idiom from
`src/middlewares/observability.ts`:

```ts
const log = getLogger();
const agencyId = sessionData?.agency ?? sessionData?.userId;
const timed = <T>(name: string, p: Promise<T>): Promise<T> => {
  const start = process.hrtime.bigint();
  const done = (failed?: boolean) =>
    log.info({ type: "dashboard_subquery", query: name,
      durationMs: Math.round(Number(process.hrtime.bigint() - start) / 1e6),
      agencyId, userType: sessionData?.userType, ...(failed && { failed: true }) }, "subquery");
  return p.then((v) => (done(), v), (e) => { done(true); throw e; });
};
```

Wrap each of the 27 `promise.push(...)` entries (lines ~67–148): `timed("name", entityCall())`,
keeping any existing `.catch(() => 0)` **outermost** so fallback values and push order are
byte-identical. Suggested names in order: `agentCount, tradePersonCount, propertiesCount,
pendingJobsCount, overdueJobsCount, leasedPropertiesCount, leasedExpiringThisMonth,
overDueLeaseCount, expiringLeaseCount, newAlarmCount, openJobsCount, allJobsCount,
completedJobsCount, noeRequiredJobsCount, jobsAverageTime, connectionStat, hubTestStat,
propsByStatus_invite, propsByStatus_all, propsByStatus_invited, propsByStatus_activeAccepted,
kpi_propsAll, kpi_propsInvited, kpi_propsRejected, kpi_connectionStatsByFlag, kpi_hubTestStat,
commUnreadCount`. (Optional: same one-line timing around the `tbl_jobs.findAll` in
`opsReport.entity.ts` ~lines 383–394, query name `report_jobsFindAll`.)

Why it's safe: entity calls are already started when the array literal evaluates, so `timed`
does not change *when* work starts or `Promise.all` semantics; it only measures each promise's
settle time = genuine per-query latency.

### A2. Aggregate in CloudWatch (log group `smoke-api-prod-pm2-out-log`)
```
fields query, durationMs, agencyId, userType
| filter type = "dashboard_subquery"
| stats avg(durationMs) as avgMs, max(durationMs) as maxMs, pct(durationMs,99) as p99Ms, count(*) as n by query
| sort maxMs desc
```
Plus a `by agencyId, query` variant to see if one tenant's data shape drives the tail.

### A3. DB-side (no deploy; run in parallel)
- **RDS MySQL slow log**: param group `slow_query_log=1`, `long_query_time=2`, export to CloudWatch;
  digest with Performance Insights / `pt-query-digest`. Expect the `DATEDIFF`/`DATE()` lease
  counts (`lease.entity.ts:743,781`) and the property/alarm aggregates to surface with missing indexes.
- **Atlas profiler** on `sensorproddb`, slow-ops @100ms: catches the 6 `countDocuments({createdAt:{$gte}})`
  in opsReport and the Mongo side of `fetchNewAlarmCount`; use Performance Advisor for index suggestions.

Let A bake ~24–48h across peak, then pin the straggler(s). Expected suspects:
`newAlarmCount`, `jobsAverageTime`, `propertiesCount` (×2), the lease date-function counts.

---

## Part B — Redis cache-aside for both endpoints (flag default OFF)

### B1. Config (edit both files)
`interfaces/config/app.interface.ts` — add optional `CACHE?: { DASHBOARD_ENABLED?: boolean;
AGENCY_DASHBOARD_TTL?: number; REPORT_SUMMARY_TTL?: number }`.
`src/config/app.ts` — add to the frozen `APP`:
```ts
CACHE: {
  DASHBOARD_ENABLED: process.env.CACHE_DASHBOARD_ENABLED === "true",   // default false
  AGENCY_DASHBOARD_TTL: parseInt(process.env.CACHE_AGENCY_DASHBOARD_TTL) || 60,
  REPORT_SUMMARY_TTL: parseInt(process.env.CACHE_REPORT_SUMMARY_TTL) || 300,
},
```

### B2. Dashboard cache (`dashboard.controller..ts`)
Reuse `getDataFromRedis` / `setDataInRedisWithExpireTime` from `../../services` (node-redis v4
singleton; helper does setEx + JSON.stringify and already returns null on Redis error).
After the remap (~line 45), before any compute:
```ts
const cacheEnabled = !!APP.CACHE?.DASHBOARD_ENABLED;
const cacheKey = `dashboard_agency:v1:${sessionData.userId}:${sessionData.userType}:${sessionData.roleId}:${sessionData?.agency ?? 0}:${params?.toggleAllProp ? 1 : 0}`;
if (cacheEnabled) { try { const c = await getDataFromRedis(cacheKey); if (c) return JSON.parse(c); } catch (_) {} }
```
At the return (~line 165), assign the existing object literal to `const result`, then
`if (cacheEnabled) { try { await setDataInRedisWithExpireTime({ key: cacheKey, value: result, expirationTime: APP.CACHE?.AGENCY_DASHBOARD_TTL ?? 60 }); } catch (_) {} }` and `return result;`.

**Key is auth-safe**: effective post-remap `userId` uniquely identifies the principal;
`userType:roleId:agency` add defense-in-depth for readonly-impersonation; `toggleAllProp`
changes 5 result fields so it's in the key. `v1:` prefix allows namespace-bust on shape change.
Dashboard response has no timestamp → a hit is byte-identical to a miss.

### B3. Report cache (`opsReport.entity.ts` `fetchReportSummary`)
Keep `const agencyId = this.resolveAgencyId(sessionData)` FIRST (preserves the 403 for
non-agency staff — errors are never cached). Then the same read/write pattern with
`cacheKey = report_summary:v1:${agencyId}` and `expirationTime = REPORT_SUMMARY_TTL ?? 300`.
Whole-agency report → keying on `agencyId` alone is correct; client-supplied `agencyId` param
is ignored by `resolveAgencyId` so it can't poison the key.
**Caveat to document:** the `generatedAt` ISO field reflects cache-population time on a hit
(value as stale as the TTL; shape unchanged). Recommended: accept this (it's a "generated at"
field). Do **not** stamp-after-read for v1.

### B4. Graceful degradation & staleness
All four touchpoints are try/catch around the cache → on any Redis problem they fall through to
the DB path (today's exact behavior); helpers also self-guard (≤3s ping timeout worst case,
negligible vs 27–64s). Invalidation is **TTL-only** — post-mutation numbers may lag up to the
TTL (60s dashboard / 300s report); acceptable for aggregates. Document in the PR.

---

## Sequencing

1. Ship **Part A** (log-only) via CodeDeploy; enable RDS slow log + Atlas profiler.
2. Bake 24–48h → run A2 queries → **pin** the straggler(s).
3. In parallel, ship **Part B** with flag OFF (dead code; verify it builds/deploys under PM2).
4. Set `CACHE_DASHBOARD_ENABLED=true` (+ restart PM2) → caps p99 at first-miss latency per
   (agency,toggle) per TTL; removes the repeated 504s and most CPU at ~1.5 loads/min.
5. Land the targeted **index/query fix** for the pinned straggler (separate Class-C change).
   Cache then becomes a cushion rather than a dependency.

**Rollback:** `CACHE_DASHBOARD_ENABLED=false` + PM2 restart → instant revert, zero code change.
Part A needs no rollback (log-only).

---

## Verification

Run **`sensor-regression-guard`** on both endpoints. Then:

1. **Shape unchanged (hard req):** capture each endpoint body flag-OFF, flag-ON cache-MISS,
   flag-ON cache-HIT. Dashboard: deep-equal across all three. Report: equal except `generatedAt`
   value on hit (assert valid ISO + all other fields equal).
2. **Positional integrity:** confirm the dashboard `promise.push` order is unchanged and every
   pre-existing `.catch(()=>0)` remains at the same index (response reads `resolvedPromiseData[0..26]`
   by ordinal — a reorder/dropped catch silently shifts fields).
3. **Auth-scoped keys:** two agency users → different dashboard keys, no cross-read; `toggleAllProp`
   true/false → distinct keys + distinct kpiMetrics; readonly-impersonation keys on the EFFECTIVE
   identity; report keys differ per agency; client `agencyId` param can't change the report key.
4. **403 still fires** for non-agency staff on `report/summary` with caching ON (throw precedes cache).
5. **Cache-miss == today:** flag ON + Redis flushed → first call identical to flag OFF.
6. **Redis-down fallback:** point to a dead Redis with flag ON → both endpoints still return correct
   DB responses, no 500s, bounded added latency.
7. **Part A sanity:** `dashboard_subquery` lines present with sane durationMs; Insights aggregates;
   no PII in log fields (ids/durations only).
8. **Build:** `tsc` passes (proves both config files edited together).

End-to-end: exercise via the safer-ops UI / direct API against prod-readonly or a real agency
login (e.g. Haven 37413, which has the large portfolio that triggers the 27s path).
