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

Deferred:

- **Layer 3 assets** (logos, favicons, PWA manifest) — pending brand image files.
- Owner-set values: `BRAND_URL`, `WIDGET_BRAND_URL`, `TERMS_URL`, `PRIVACY_URL`
  (via `BrandingSetup` ENV) and the `hello@chatwoot.com` support address in the
  inactivity-deletion email (left until the fork's support contact is known).
- `MAILER_SENDER_EMAIL` must be set on deploy (the OSS `from` fallback is
  `Chatwoot <accounts@chatwoot.com>`).
- Captain empty-state help content and Twilio template demo payloads — link to
  external Chatwoot docs / are sample data; leave until content is reworked.
