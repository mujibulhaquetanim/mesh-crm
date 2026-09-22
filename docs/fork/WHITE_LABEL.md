# White-Label / Branding Pass

Runs **last** (after enforcement + AI loop are stable). Config-first: exhaust
installation configs and i18n before touching code, and never rename routes,
headers, or payload keys for branding.

## Layer 1 — Installation configs (no code)

Defined in `config/installation_config.yml` (anchors around lines 17-53),
editable at runtime via Super Admin → App Config, or seedable per environment:

| Config | Use |
| --- | --- |
| `INSTALLATION_NAME` | Product name across UI (consumed by `useBranding`) |
| `BRAND_NAME` | Brand string in emails/footers |
| `LOGO`, `LOGO_DARK`, `LOGO_THUMBNAIL` | App logos (URLs) |
| `BRAND_URL`, `WIDGET_BRAND_URL` | "Powered by" targets and widget branding |
| `TERMS_URL`, `PRIVACY_URL` | Legal links |

Scripted, repeatable setup for the SaaS deploy uses the fork overlay service
`Custom::BrandingSetup` (`custom/app/services/custom/branding_setup.rb`). It
upserts the branding rows from ENV (keys named exactly as the configs:
`INSTALLATION_NAME`, `BRAND_NAME`, `LOGO`, `LOGO_DARK`, `LOGO_THUMBNAIL`,
`BRAND_URL`, `WIDGET_BRAND_URL`, `TERMS_URL`, `PRIVACY_URL`) and only touches a
key when its ENV var is set, so partial branding leaves upstream defaults in
place. Writing the DB row is required because ConfigLoader seeds these keys with
the "Chatwoot" defaults, which shadow `GlobalConfigService`'s ENV fallback, and
the frontend reads the DB directly via `GlobalConfig.get`. Updating
`InstallationConfig` fires `after_commit :clear_cache`, so the Redis cache
refreshes automatically.

```
INSTALLATION_NAME='Mesh CRM' BRAND_NAME='Mesh CRM' \
  docker compose run --rm rails bundle exec rails runner "Custom::BrandingSetup.call"
```

## Layer 2 — Frontend strings

- Prefer `replaceInstallationName` from `shared/composables/useBranding`
  (already the repo convention, see root CLAUDE.md) over editing copy that
  contains "Chatwoot".
- Only edit `en.json` (frontend) / `en.yml` (backend); other locales are
  community-managed.
- Onboarding and empty-state copy: audit with
  `rg -n "Chatwoot" app/javascript --type-add 'vue:*.vue' -t vue -t js | rg -v useBranding`
  and route each hit through the composable or i18n.

## Layer 3 — Static assets

Replace files in place (same names/paths — renames break references):

- `public/favicon*`, `public/apple-touch-icon*`, badge/monogram PNGs
- PWA manifest icons (`public/` + verify `DISPLAY_MANIFEST` config)
- Widget/SDK bubble assets if the widget is branded

Regenerate favicon variants from one source image with a generator
(e.g. `docker compose run --rm vite pnpm dlx pwa-asset-generator <logo.svg> public/`)
instead of hand-editing sizes; verify output names match the originals.

## Layer 4 — Emails

- Mailer layouts/templates: confirm they read `BRAND_NAME`/`GlobalConfig`
  (audit `app/views/mailers/`, `app/mailers/`); replace hardcoded "Chatwoot"
  with config reads in `custom/` view overrides
  (`config.paths['app/views'].unshift('custom/app/views')` — see
  ARCHITECTURE.md bootstrap).
- Sender name/address come from `MAILER_SENDER_EMAIL` / mailer configs in
  `.env` — environment, not code.

## Cautions

- `X-Chatwoot-*` webhook headers are a public contract — **do not rebrand**.
- Gem/module namespaces, route helpers, DB names: out of scope.
- After asset swaps run a full build
  (`docker compose run --rm vite pnpm build` or the dev server) and click
  through login, onboarding, widget, and one email preview to catch broken
  references.

## Acceptance

- No visible "Chatwoot" in: app shell, onboarding, empty states, widget,
  transactional emails, browser tab (title + favicon) — except legally
  required license/attribution surfaces you explicitly choose to keep.
- All routes and API responses byte-compatible with pre-branding behavior
  (regression suite green).

## Status — "Mesh CRM" pass

> **Renamed 2026-08-11: `Meta CRM` → `Mesh CRM`.** The pass originally branded the
> installation "Meta CRM". That was a fifth name — the product register in
> `../../../agentic-str/docs/README.md` §Naming lists only Mesh CRM (product),
> meta-saas (system), `mesh-*` (deploy hosts) and Meshever (business). Since
> `INSTALLATION_NAME` is unset in every env file, the hardcoded literals were
> live vendor-visible copy rather than defaults, so the rename touched 23 code
> files (44 strings). **The "Verified (Docker up)" line below predates the
> rename** — it was confirmed against `Meta CRM`.
>
> **Re-verified 2026-08-20 against `Mesh CRM`, on the prod-local stack**
> (`docker-compose.prod-local.yaml`, RAILS_ENV=production, throwaway Postgres,
> develop `06133e6e5b`). Measured, not assumed:
>
> - `Custom::BrandingSetup` applied 2 config changes; the served page then
>   carries `INSTALLATION_NAME`/`BRAND_NAME` = `Mesh CRM` (was `Chatwoot`).
> - Headless-browser click-through: `document.title` = `Mesh CRM`; login
>   heading renders "Login to Mesh CRM". A bare `/app/login` visit never shows
>   the form at all — `EXTERNAL_LOGIN_URL` bounces it to the platform
>   dashboard (`?email=` skips the bounce, which is how the form was checked).
> - MFA TOTP issuer: `otpauth://totp/Mesh%20CRM:…&issuer=Mesh%20CRM`.
> - All three deletion/compliance emails render with `Mesh CRM` subjects and
>   bodies; the only "Chatwoot" left was the test account's own name. NOTE for
>   anyone rendering these by hand: invoke via `.with(account: a)` — the
>   mailer's `ensure_current_account` RESETS `Current` from params, so a bare
>   call dies on `Current.account` nil inside `settings_url`.
> - `spec/mailers/administrator_notifications`: 27 examples, 0 failures.
> - Locale audit: 0 `Chatwoot` display strings left in `en` locale JSONs
>   (identifiers like `isOnChatwootCloud` and config keys remain, sanctioned).
> - ⚠ **The screenshot still shows the Chatwoot LOGO on the login screen** —
>   `LOGO`/`LOGO_THUMBNAIL` fall back to `/brand-assets/logo_thumbnail.svg`
>   because Layer 3 (below) is still pending brand image files. The wordmark
>   IS the word "chatwoot", so the first screen a vendor sees carries it until
>   those assets exist. Same for the favicon.

Done in code (brand = "Mesh CRM"):

- Layer 1 mechanism: `Custom::BrandingSetup` (run with `INSTALLATION_NAME` /
  `BRAND_NAME` set — this also flips `isACustomBrandedInstance`, auto-hiding
  Chatwoot-only surfaces: update/upgrade banners, year-in-review, "powered by"
  promos via `CustomBrandPolicyWrapper` / `usePolicy`).
- Frontend i18n: all user-facing `Chatwoot` display strings in dashboard,
  widget, and survey `en.json` → `Mesh CRM` (word-boundary only; keys,
  interpolation vars, and `window.chatwootSettings` left intact).
- Frontend literals: survey logo alt, MFA backup-codes filename text,
  sender-name / campaign / article-search / codepen example strings.
- Backend i18n: integration description strings in `config/locales/en.yml`.
- MFA TOTP issuer (shown in authenticator apps): `Custom::Mfa::ManagementService`
  overlay now uses the installation name (extension point added to
  `app/services/mfa/management_service.rb`).
- Transactional emails: account-deletion / compliance mailers rebranded via
  `custom/app/views` liquid overrides (bodies use
  `global_config['BRAND_NAME'] | default: 'Chatwoot'`) plus
  `Custom::AdministratorNotifications::AccountNotificationMailer` for the
  subjects (extension point on the OSS mailer). Needed the custom view-path
  bootstrap: `config.paths['app/views'].unshift('custom/app/views')` in
  `config/application.rb`. Overrides live at the mailer prefix (no `mailers/`
  segment) because `ApplicationMailer` appends `app/views/mailers` as a root.
- Config-driven already (covered once `BrandingSetup` runs): app `<title>`,
  email confirmation brand, mailer footer (`layouts/mailer/base.liquid` reads
  `BRAND_NAME`).

Verified (Docker up): `Custom::BrandingSetup` applied on dev; `spec/custom` +
`spec/mailers/administrator_notifications` green (branding transparent when
config unset, so upstream specs pass); MFA issuer and deletion emails render
"Mesh CRM" on dev; eslint 0 errors.

## Status — Layer 3 assets shipped (2026-08-23)

The owner reported the Chatwoot logo still rendering on the login screen after
account creation / SSO redirect — exactly the gap flagged in the "Mesh CRM"
re-verification above. Root cause confirmed: `LOGO`, `LOGO_DARK`, and
`LOGO_THUMBNAIL` (installation-config defaults, seeding the DB rows the Vue app
reads via `GlobalConfig`) all point at `/brand-assets/*.svg`, and those SVG
files still contained the literal Chatwoot wordmark/mark — no config or code
change was missing, only the asset content.

Fix (Layer 3, in place, same paths, `fix/login-brand-placeholder` branch):

- `public/brand-assets/logo.svg`, `logo_dark.svg` — replaced the "chatwoot"
  wordmark with a "Mesh CRM" placeholder wordmark (violet circle "M" mark +
  text; `logo_dark.svg` uses white wordmark text for dark backgrounds). Same
  `viewBox`/aspect (`0 0 2559 581`) as the originals, so no layout shift.
- `public/brand-assets/logo_thumbnail.svg` — replaced the Chatwoot "C" mark
  with the "M" mark only, same `viewBox` (`0 0 16 16`).
- `public/favicon-{16,32,96,512}x{16,32,96,512}.png` (self-square, e.g.
  `favicon-16x16.png`), `favicon-badge-{16,32,96}x{16,32,96}.png`,
  `android-icon-*.png`, `apple-icon-*.png`, `ms-icon-*.png` — regenerated from
  the new mark via `convert` (ImageMagick's built-in MSVG renderer; no
  `rsvg-convert` binary on this box, but the render was verified visually),
  one PNG per original filename/dimension — no code or `installation_config.yml`
  changes needed since the config only stores the path, not the image.
- `public/manifest.json` — `name`/`short_name` "Chatwoot" → "Mesh CRM";
  `background_color`/`theme_color` swapped to the new mark's violet
  (`#5B4FE9`, was Chatwoot's `#2781F6`). `icons[].src` paths unchanged (same
  filenames, new pixels).
- `public/browserconfig.xml` — untouched; it only references `ms-icon-*.png`
  by path, which now render the new mark.

Not touched (out of scope for this pass, or upstream files this fork avoids
editing without an overlay): `app/views/layouts/vueapp.html.erb`'s inline
`#2781F6` `theme-color`/`msapplication-TileColor` meta tags (Chatwoot's blue,
not the logo — leaving unless the owner also wants browser-chrome color
rebranded); `public/apple-touch-icon.png` / `apple-touch-icon-precomposed.png`
(both already 0-byte placeholders upstream, not Chatwoot-branded, unreferenced
by any `<link>` tag). Visual proof (the actual rendered login screen) needs the
controller's post-rebuild e2e screenshot — not run from this pass.

Deferred:

- Owner-set values: `BRAND_URL`, `WIDGET_BRAND_URL`, `TERMS_URL`, `PRIVACY_URL`
  (via `BrandingSetup` ENV) and the `hello@chatwoot.com` support address in the
  inactivity-deletion email (left until the fork's support contact is known).
- `MAILER_SENDER_EMAIL` must be set on deploy (the OSS `from` fallback is
  `Chatwoot <accounts@chatwoot.com>`).
- Captain empty-state help content and Twilio template demo payloads — link to
  external Chatwoot docs / are sample data; leave until content is reworked.

---

## Status — real brand artwork, renamed to Zasmate (2026-09-22)

The 2026-08-23 pass above shipped a *placeholder*: a violet circle with a
lettered "M", explicitly standing in "pending brand image files". Those files
arrived, so this pass replaces the placeholder with the real mark and takes the
product name with it — the artwork reads ZASMATE, and the install already serves
from `zasmate.com`.

Everything raster is now **generated, not drawn**:
`scripts/brand/generate-icons.sh` derives every icon from the two masters in
`docs/brand/`. Re-running it is the supported way to refresh the set; editing a
PNG by hand will be silently overwritten the next time anyone does.

Two things about that pipeline are worth knowing, because both fail *silently* —
they produce valid PNGs of the right size with an alpha channel, and look fine
until someone opens them:

- **Lift the artwork with a floodfill, never `-transparent`.** The masters sit
  on an opaque `#F7F7F7` field. `-fuzz 12% -transparent '#F7F7F7'` matches that
  colour globally, and the logo's "Z" and the speech-bubble interior are the
  same near-white — so they go transparent too and the logo has a hole where its
  letter should be. Measured: 30% opaque against 69% for an edge-connected
  floodfill.
- **`logo_dark.svg` is a different file, not a CSS filter.** The lockup's
  tagline is near-black navy and vanishes on a dark surface. Repainting it by
  luminance alone also pales out the mark's navy orbit dot (its core is 24.7%
  luma — darker than it looks), so the recolour is gated *geometrically* too, on
  the run of transparent columns between mark and text. The generator finds that
  gap rather than assuming it.

`spec/brand/brand_assets_spec.rb` guards the output by counting pixels that are
near-white **and** opaque — the white Z is what disappears, so the white Z is
what gets counted. A correct build measures 8–12% depending on size; the broken
one measures exactly 0. Verified red on the naive recipe before being trusted.

Shipped in this pass:

- `public/brand-assets/logo.svg`, `logo_dark.svg`, `logo_thumbnail.svg` — the
  real mark. Still `.svg` because `config/installation_config.yml` points at
  those paths, but the payload is now a base64 PNG in an `<image>` element. The
  login views size the logo `w-auto h-8`, so the aspect change is free.
- All 30 root-level icons regenerated at their exact original dimensions —
  including `ms-icon-144x144.png`, which the layout uses as
  `msapplication-TileImage` and which the 2026-08-23 list missed.
- `public/apple-touch-icon.png` and `-precomposed.png` — **were 0 bytes**. The
  previous pass left them as "unreferenced by any `<link>`", which is true but
  not the whole story: Safari probes `/apple-touch-icon.png` by convention when
  no tag matches, and caches what it gets, so an empty body is worse than a 404.
  Now 180×180.
- `config/installation_config.yml` — `INSTALLATION_NAME` and `BRAND_NAME` were
  **still `'Chatwoot'`**, and `BRAND_URL`/`WIDGET_BRAND_URL` still pointed at
  `chatwoot.com`. All four now Zasmate. These were on the Deferred list above.
- `app/views/layouts/vueapp.html.erb` — the inline `#2781F6` `theme-color` and
  `msapplication-TileColor`, which the last pass deliberately left.
- `app/javascript/dashboard/components-next/icon/Logo.vue` — the inline fallback
  SVG was **Chatwoot's own blue bubble**, rendered whenever `LOGO_THUMBNAIL` is
  unset. An install that lost its config fell back to someone else's brand.
- `public/manifest.json` — name/short_name, and the theme colours off the
  placeholder violet onto the artwork's cyan `#19A6D3`.
- 48 "Mesh CRM" strings across 23 i18n and Vue files.

Not touched, deliberately:

- **`#2781F6` elsewhere** — email templates, the portal-colour default, the Dyte
  bubble, label suggestions. That is an accent colour, not the logo; recolouring
  it is a theme change and wants its own pass.
- **`public/browserconfig.xml`** — its `<TileColor>` is `#ffffff`, not Chatwoot
  blue, and the `msapplication-TileColor` meta tag overrides it on the live page
  anyway.
- **The DB.** `INSTALLATION_NAME`, `BRAND_NAME` and the `LOGO*` paths are
  `InstallationConfig` ROWS; this YAML only seeds a fresh install. A running
  instance keeps whatever is in its table until those rows are updated. See
  `docs/fork/REBRAND_PRODUCTION.md`.
