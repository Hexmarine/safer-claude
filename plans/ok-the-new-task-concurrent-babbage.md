# Migrate cleaningsymphony.com.au to Firebase Hosting (static)

## Context

The marketing site `cleaningsymphony.com.au` went offline (the domain had lapsed and
returned `NXDOMAIN` at the `.au` registry; last SSL cert was issued ~March 2026). The
domain has now been **recovered**. The site is a small WordPress brochure site (Astra
theme, hosted on SiteGround) with only a handful of pages: **Home, About, Services,
Contact**. There is no dynamic functionality beyond (possibly) a contact form.

We want to get off SiteGround/WordPress and host it cheaply and reliably on **Firebase
Hosting** inside the **existing email-ops-summary GCP project**. Because the content is
static and rarely changes, converting WordPress to flat HTML/CSS is the right move:
near-zero cost, global CDN, automatic SSL, nothing to patch or keep secure.

### Decisions already made (from the user)
- **Source of truth:** full SiteGround access available → export the *real* WordPress site (files + DB), not a Wayback reconstruction.
- **Target:** static export → Firebase Hosting (no PHP/MySQL in production).
- **Domain:** already recovered and controllable → we do the DNS cutover.
- **GCP project:** reuse the existing email-ops-summary project (add a dedicated Firebase Hosting *site* within it so it never collides with the Cloud Run app).

### Out of scope / non-goals
- Keeping `wp-admin` editing in production (we're dropping dynamic WordPress).
- Migrating any domain email/MX (business email is a `@gmail.com` address, not domain-hosted) — but we must **preserve** any existing MX/SPF/TXT records during DNS edits.
- Redesigning the site. This is a faithful "lift and freeze" of the current content; a refresh can follow later.

## Repository layout

Keep the website **out of this app repo** to avoid mixing concerns and tripping the
Cloud Run CI on `push to main`. Create a sibling directory/repo:

```
~/dev/symphony/cleaningsymphony-web/
  public/            # the static export (Firebase "public" dir)
  firebase.json
  .firebaserc
  README.md          # how to re-export and redeploy
```

## Plan

### Phase 1 — Extract the static site from WordPress
Preferred path (cleanest, uses live WP):
1. Confirm the WordPress site is reachable on SiteGround (either via the live domain now
   that it's recovered, or via SiteGround's temporary/staging URL).
2. In `wp-admin`, install the **Simply Static** plugin (free). Configure:
   - Replace absolute URLs with **relative** paths (or with `https://cleaningsymphony.com.au`).
   - Deliver as a **local ZIP**.
3. Generate the export → download the ZIP → unpack into `cleaningsymphony-web/public/`.

Fallback path (if WP is not currently serving):
1. From SiteGround, download `wp-content` + a full **MySQL dump** (phpMyAdmin export or SiteGround backup).
2. Run WordPress locally with a throwaway `docker-compose` (`wordpress` + `mysql`), import the DB and files, fix the local site URL.
3. Run Simply Static locally, **or** crawl with `wget --mirror --convert-links --adjust-extension --page-requisites http://localhost:8080/`.

### Phase 2 — Clean up the static output
- Remove WordPress cruft that has no place in a static site: `wp-json/`, `xmlrpc.php`,
  `/feed/`, `/comments/feed/`, `wp-login`, `wp-admin`, any `?p=`/query-string artifacts.
- Verify all assets resolved locally (CSS/JS/images/fonts under `wp-content/...` or
  rewritten paths) — no requests still pointing at `siteground`/staging hosts.
- Rewrite any remaining absolute links to the production domain or make them relative.
- Add a `404.html`.
- Sanity-check the four real pages render offline: open `public/index.html`,
  `public/about/index.html`, `public/services/index.html`, `public/contact/index.html`.

### Phase 3 — Handle the contact form (static-friendly)
WordPress contact forms need a backend; Firebase Hosting is static. Replace with:
- **Default (recommended):** `tel:+61432744588` and `mailto:cleaningsymphony@gmail.com`
  links, plus the business address `207/130 Dudley St, West Melbourne VIC 3003`.
- **If a real submit form is wanted:** wire the existing `<form>` to a free
  form-to-email service (Web3Forms / Formspree) — no server needed. (A Cloud
  Function/Cloud Run handler is possible but overkill for a brochure site.)

### Phase 4 — Firebase Hosting setup (reuse email-ops project)
1. `cd ~/dev/symphony/cleaningsymphony-web && firebase login` (as the account with
   access to the email-ops GCP project).
2. Create a **named hosting site** inside the existing project so it's isolated from the
   Cloud Run app:
   `firebase hosting:sites:create cleaning-symphony` (target id, e.g. `cleaning-symphony`).
3. `firebase init hosting` → select the existing email-ops project, set `public` =
   `public`, configure as a **single-page = No** static site.
4. `firebase target:apply hosting cleaning-symphony cleaning-symphony` and reference the
   target in `firebase.json`.
5. `firebase.json` essentials:
   - `"public": "public"`
   - `"cleanUrls": true`, `"trailingSlash": true` (so `/about/` serves
     `about/index.html` the way WordPress permalinks did)
   - `"ignore"` the firebase config files
   - a `404.html` rewrite/error page

### Phase 5 — Deploy + preview, then go live
1. `firebase hosting:channel:deploy preview` → open the preview URL → click through all
   pages, check styling, images, links, contact links. Fix and re-export if needed.
2. `firebase deploy --only hosting:cleaning-symphony` to publish to the live
   `*.web.app`/`*.firebaseapp.com` URL.
3. Verify on the default Firebase URL before touching DNS.

### Phase 6 — Domain + DNS cutover
1. In Firebase Console → Hosting → the `cleaning-symphony` site → **Add custom domain**
   → add both `cleaningsymphony.com.au` (apex) and `www.cleaningsymphony.com.au`.
2. Add the verification/`A`/`TXT` records Firebase provides at wherever the domain's DNS
   is now managed (SiteGround DNS or the registrar's nameservers).
   - **Preserve existing MX/SPF/TXT records** if any are present, to avoid breaking mail.
   - Set the apex `A`/`AAAA` to Firebase's IPs; point `www` per Firebase's instructions
     (CNAME or redirect to apex).
3. Wait for DNS propagation; Firebase auto-provisions the Let's Encrypt SSL cert.

## Verification

- **Local:** open each exported page from `public/` in a browser — all four pages render
  with correct CSS/images, no broken asset paths.
- **Firebase preview channel:** every page loads; navigation, images, fonts, and
  contact links (`tel:`/`mailto:` or form submit) all work over HTTPS.
- **Live URL (pre-DNS):** confirm `https://<site>.web.app` serves the full site.
- **Post-cutover:**
  - `dig cleaningsymphony.com.au A +short` resolves to Firebase IPs.
  - `curl -I https://cleaningsymphony.com.au/` → `200`, valid cert, served by Firebase.
  - `https://www.cleaningsymphony.com.au/` resolves/redirects correctly.
  - Spot-check `/about/`, `/services/`, `/contact/` over HTTPS.
  - Confirm prior MX/mail records (if any) still resolve.

## Open items to confirm during execution
- Whether the recovered domain's WordPress is currently *serving* (decides Phase 1
  preferred vs fallback path).
- Whether the client wants a working submit form or just click-to-call/email is enough.
- Where the domain's DNS is actually managed now (SiteGround vs registrar nameservers),
  so the Phase 6 records are added in the right place.
