---
name: sensorglobal-saferhomes-jv
description: Company context — SensorGlobal built the product; now a JV with Safer Homes operates it; we are the Safer Homes technical side.
metadata: 
  node_type: memory
  type: project
  originSessionId: 37a45498-e9ae-422d-b657-dcf4449c5278
---

The SensorSyn product (smoke-alarm hubs/sensors IoT platform) was originally
developed by **SensorGlobal (Sensor Global Pty Ltd)** — the hubs/sensors and
firmware were often built via **third parties** (`code/firmware` is empty because
firmware source lives with a 3rd-party vendor; the `docs/upstream/` technical
PDFs are vendor-provided).

SensorGlobal has formed a **joint venture with Safer Homes (GitHub org
`SaferHomesAu`)**. The JV now owns/operates the product and continues all
development and support. The user (peresada@gmail.com) and Claude are working on
this **from the Safer Homes technical side** — reviewing and taking over the
platform.

**Why:** This frames the entire repo. The AWS account detach (from Ingram
Micro's AWS Org), the MongoDB "JV custody" cutover to a JV-controlled Atlas, and
the SensorGlobal→JV handover investigations all stem from this transition.

**How to apply:** When docs say "JV-controlled" / "JV Atlas" / "standalone AWS
account under JV control", JV = SensorGlobal + Safer Homes. Treat SensorGlobal as
the prior owner/operator. Note the docs do NOT yet explicitly state two things
the user told us: (1) that Safer Homes is the named JV partner, and (2) that the
hubs/sensors/firmware were 3rd-party-developed — the docs currently log these as
open gaps/questions (`docs/gaps-detailed.md`, `docs/questions.md`).

**Post-JV people & vendors (confirmed by the user 2026-05-29):**
- On the SensorGlobal side, **only CEO Andrew Cox remains**. The rest of the
  original ~15-person org named in the pre-JV `docs/upstream/` docs (founder
  Cameron Davis, COO Tom McEvoy, Dev Mgr/access-contact Sam Collins) are no
  longer involved — treat any contact in those docs as stale.
- **Safer Homes now does ALL maintenance, development, and support** (incl.
  organising the support function).
- **Appinventiv** (former software-dev / MSP vendor that ran the
  `sensorglobal.msp@appinventiv.com` prod on-call) is **fully separated — no
  ongoing relationship; all its access must be revoked** (the on-call path is
  defunct). Recorded in `docs/infra/company-and-ownership.md` + `gaps.md` §4.
See [[prepared-kit-fungible-pool-pivot]] for current product direction.
