---
name: sensor-admin-property-list-export
description: "How to export an agency's full property list from the Sensor admin API + the unstable-sort paging bug (must pass orderby=id)"
metadata: 
  node_type: memory
  type: reference
  originSessionId: f36d7861-f9b5-4f62-af73-178ecb331372
---

Exporting **all properties for an agency** from the Sensor admin API.

**Endpoint:** `GET https://api.sensorglobal.com/api/v1/admins/properties/list?page=N&limit=100&agency=<AGENCY_ID>&orderby=id&ordertype=asc`
- Auth header (non-standard): `access_token: bearer <JWT>`. Needs an admin token (`userType: 8`); the `/users/properties/...` paths 423 for admin tokens.
- Token must come from a **live admin.sensorglobal.com session** — a JWT with a dead `sessionId` returns `423 {type: UNAUTHORIZED_TOKEN, "Session Expired"}` even when `exp` is still in the future (Sensor checks `sessionId` server-side). Re-pasting the same JWT won't help; re-login to get a new `sessionId`.
- Response: `data.count` = total; rows at `data.data[]` (each has `id`, `title`, `address`, `status`, `agencyDetails`, …).
- **Page size is hard-capped at 100** regardless of `limit`. So you must page.

**⚠️ The unstable-sort paging bug (the "something funny" with paging):**
With no sort param the backend orders by `ORDER BY propertyStatus, status` (`properties.entity.ts` `propertyListQuery`, ~line 1896) — **both non-unique**, so MySQL `LIMIT/OFFSET` straddles ties: pages overlap and skip rows. Symptom: paging through e.g. 1178 rows collects 1178 rows but only ~730 **unique** ids (~38% silently missing, equal number duplicated). Each offset is deterministic, so a brute-force re-page union does NOT recover the missing rows.
**Fix:** always pass `orderby=id&ordertype=asc`. The entity's `else` branch (`query.order = [[orderby, ordertype]]`) passes the column straight through, so `id` (the PK) gives a total order → stable paging → full coverage. Allowed query params come from the `ReqPropertiesList` Joi allowlist (`swagger_schemas/users.schema.ts`): `limit,page,search,orderby,ordertype,status,fromDate,toDate,agency,landlord,leaseStatus,country,state,city,...` — unknown keys (e.g. `sortBy`) 400 with `"<key>" is not allowed`.

**Default count semantics:** with no `status` param the WHERE is `agency=<id> AND status NOT IN ('2','3')` (DELETED='2', BLOCKED='3'; `constants/app.ts` LISTING_STATUS). So `data.count` already excludes deleted/blocked.

**DB validation (table `tbl_properties`, col `agency`, `status`):**
```sql
SELECT COUNT(*) FROM tbl_properties WHERE agency=37413 AND status NOT IN ('2','3');
```
Use the repo tunnel: `source ./scripts/load-prod-env.sh && ./scripts/db-tunnel-start.sh mysql` then the `sensor-mysql` helper (127.0.0.1:13308, db smokealarmprod). Both `load-prod-env.sh` (defines the `sensor-mysql` fn) and the query must run in ONE shell invocation — the fn and tunnel don't persist across separate Bash calls. `./scripts/db-tunnel-stop.sh` when done.

**Haven Home Safe = agency `37413`** (1178 properties as of 2026-06-02; statuses 1→900, 4→49, 8→228, 10→1). Verified: API-with-`orderby=id` export id-set == DB id-set exactly (0 diff). See [[saferops-test-accounts-and-duplicates]] for the test agency 59120.

**Augmenting with tenant name + mobile** (no extra API calls — it's already in the `/admins/properties/list` payload). Each property row carries `leaseDetails[].leaseTenants[]`, joined server-side to **active leases only** (`Lease.status='1'`) and **primary tenants only** (`LeaseTenants.userType='primary'`); in practice ≤1 tenant per property (1161/1178 have one). Two sources per tenant: `leaseTenants[].Details` = LIVE `tbl_admins` row (name/phone/phoneCode), and `leaseTenants[].tenantDetails` = a JSON SNAPSHOT taken at lease creation. They diverge (~27 different numbers, some formatting, some live-blank/snapshot-has). Best: prefer live, **fall back to snapshot per-field on empty** — and beware live "missing" is stored as empty-string `""` (and junk `"0"`), NOT null, so jq `//` won't fall back; normalize→validate→fallback instead. Phones are bare (no leading 0, no country code); AU-local = prepend `0`, keep existing `0`, strip `61` prefix, then require `^0[0-9]{9}$` (this also drops `"0"` junk; ~10 are 03… landlines not 04 mobiles). Result for 37413: 1129 valid phones (1119 mobile/10 landline), 49 blank, 20 blank-name (17 no-tenant + 3 empty tenant records). DB cross-check via `tbl_properties p JOIN tbl_lease l(status='1') JOIN tbl_lease_tenants lt(userType='primary') JOIN tbl_admins a` — CSV matched DB live values on all rows except the intended snapshot-fallback recoveries (1 name, 13 phones where live was blank/`0`). Output: `haven-home-safe-properties-tenants.csv`; jq builder at `tmp/augment.jq`.
