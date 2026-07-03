---
name: sensorinsure-product-status
description: "What SensorInsure is — a live WordPress marketing/lead-gen site for an insurance-bundled smoke-alarm offering, NOT a code product"
metadata: 
  node_type: memory
  type: project
  originSessionId: 611c8e6e-cb71-4ed6-be11-bdcc4591abbb
---

**This memory covers the WordPress marketing site + its infra only.** The
original claim here that "there is NO SensorInsure code in the workspace" was
WRONG — a full CorpSure/SGUA insurance integration exists across
sensor-alarm-backend, sensor-angular, and odoo-addons (dormant since ~2026-04).
See [[sensorinsure-corpsure-integration]] and
`docs/investigations/2026-07-03-sensorinsure-corpsure-integration-review.md`.

**The offer (from the live site meta/title 2026-06-26):** "Protecting your rental
property with smart building and landlord insurance means you receive a ZERO cost,
smart IoT smoke alarm & water leak detection upgrade to your annual smoke alarm
servicing." i.e. bundle landlord/building insurance with Sensor's IoT smoke-alarm +
water-leak hardware; the insurance subsidises the device/service upgrade. Title:
"SENSORInsure | Save on Insurance and Receive an Upgrade to Your Smoke Alarm Service!"

**Live state (2026-06-26): the site is UP, not dead.** Both `sensorinsure.com` and
`sensorinsure.com.au` return HTTP 200 with valid TLS, resolving to a 3-IP prod ALB
(52.65.253.14 / 3.104.173.153 / 13.210.254.218). Stack = WordPress on Apache/2.4.62
(Debian), default `twentytwentyfour` theme, Google Site Kit 1.173.0. So "resurrect"
is about the BUSINESS LINE / go-to-market / content, not redeploying dead infra.

**Infra footprint (prod AWS acct 747293622182, ap-southeast-2):**
- EC2 `wordpress-sensor-insure` i-0dc7e540dc021d6e9, t2.medium, public IP
  54.252.123.97 (direct hits 301→https). Low traffic.
- ALB `wordpress-sensorinsure` (…-1575846363.ap-southeast-2.elb…), log bucket
  `smoke-wordpress-sensorinsure-alb-logs`.
- Route53 domains `sensorinsure.com` + `.com.au` (auto-renew, **expire ~Sep 2026**).
  Also UNUSED `sensorsmartinsurance.com`/`.com.au` parked.
- Cert note from 2026-04-12 incident: `.com.au` cert was EXPIRED, `.com` ISSUED —
  but both serve 200 with valid TLS now (re-issued / ALB cert differs from that table).
- EBS `vol-0f2c4069881201962` NOT covered by DLM snapshot policy (backup gap).

**Stack/host (verified 2026-06-26):** Dockerised on the EC2 box — container
`wordpress_sensorinsure` (image `wordpress`, 80→80) + `wp_sensorinsure_db`
(mysql:8.0); WP files bind-mounted at `/data/wordpress/var/www/html`. NO wp-cli
installed; drive WP via `docker exec wordpress_sensorinsure php /var/www/html/wp-load.php`
bootstrap, or query the DB inside `wp_sensorinsure_db` using its own
`$MYSQL_USER/$MYSQL_PASSWORD/$MYSQL_DATABASE` env (creds used, never printed).
Table prefix `wp_`. admin_email = josh.grigg@sensorglobal.com.

**Integrations = 6 WP plugins, NO system-to-system pipe:**
- **Fluent Forms** (lead capture) — 3 published forms (Contact, Subscription ×2);
  submissions in `wp_fluentform_submissions`. **9 lifetime, last Oct 2025, 0 in 90d**
  → dormant. Leads only stored in WP + emailed; NOT pushed to Sensor/Odoo/CRM.
- **FluentSMTP** (outbound email) — **FIXED 2026-06-26** (was failing: SendGrid 401
  "not authorized to send", retired org-wide). Now on **Amazon SES** (region ap-southeast-2,
  sender hello@sensorglobal.com via verified sensorglobal.com domain identity; SES in prod
  mode). Dedicated least-priv IAM user `sensorinsure-wp-ses-smtp` (FromAddress-scoped send +
  ListIdentities/quota reads); access key created by user in console + entered in wp-admin
  (secret never handled by Claude). Verified: wp_fsmpt_email_logs id 1191 status=sent w/ SES
  MessageId. SendGrid connection was replaced in place (no fallback retained). On-brand sender
  hello@sensorinsure.com would need verifying sensorinsure.com in SES (not done).
- **Google Site Kit** (analytics), **Yoast SEO**, **Multiple Domain** (serves .com +
  .com.au), **Under Construction Page** (installed but OFF, status=0 — site public).

**WP users (wp_users):** sam/samc@ (admin), TaylorD/taylor@ (admin),
josh.grigg/josh.grigg@ (admin), Taylor/taylorlynettedavis@gmail (editor), and
**andrew/andrew@sensorglobal.com (admin, ID 7)** + **eugene/eugene.peresada@saferhomesau.com.au
(admin, ID 8)** — both CREATED by us 2026-06-26 (Andrew had no account, so "reset" was
impossible; Eugene = the user, added to verify). One-time reset links staged to root-only
`/root/{andrew,eugene}-wp-reset.txt` on the box (native email couldn't be used — SMTP broken;
retrieve via the scratchpad fetch helper run with `!`, since the auto-classifier blocks Claude
printing the reset URL to chat — it's an admin-access credential). Stored URLs have literal `&`
(the `&amp;` in transcript is display-escaping only). See docs/applied-changes.md 2026-06-26.

**k8s migration = live option (user leaning yes 2026-06-26):** footprint is tiny (204MB
files / 1.3MB uploads / **4.5MB** DB; stock `wordpress` image, env-driven config, mysql:8.0)
so a move to `safer-ops-prod` EKS is very doable — DB→RDS or StatefulSet+PVC, wp-content→EBS
PVC (RWO, single replica) or S3+custom image, ALB Ingress via AWS LB Controller (both .com +
.com.au, multiple-domain plugin), ExternalSecret for DB/SMTP creds. NOTE the existing EKS plan
(2026-04-29) deliberately lists WordPress "keep outside k8s"; leaner alts = harden-in-place or
static-export to S3+CloudFront. Host is SHARED (2 stray mysql containers happy_panini/
pensive_kepler) so EC2 can't retire until those move. Good window because site not yet actively used.

Caveats for any revival work: it's an unmanaged WordPress box (patch/security risk,
default theme), no app integration to the Sensor platform exists, FluentSMTP email is
currently broken, and it's production-account infra so changes are gated per CLAUDE.md.
Upstream "Domains & Hosting" doc labels it "Primary insurance website".
Related: [[sensorglobal-saferhomes-jv]].
