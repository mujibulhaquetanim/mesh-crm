# Login/SSO screens still showed the Chatwoot logo after account creation

- **Date**: 2026-08-23
- **Phase**: 7 (Branding pass, Layer 3)
- **Area**: frontend (static assets)

## Symptom

Owner report: after account creation / SSO redirect into the CRM, the login
screen shows the Chatwoot logo (blue circle + "chatwoot" wordmark), not Mesh
CRM. Matches the caveat already flagged in `WHITE_LABEL.md`'s 2026-08-20
re-verification: "The screenshot still shows the Chatwoot LOGO on the login
screen."

## Root cause

Not a code or config bug — the config was already correct. `LOGO`,
`LOGO_DARK`, `LOGO_THUMBNAIL` (`config/installation_config.yml`) point at
`/brand-assets/logo.svg`, `logo_dark.svg`, `logo_thumbnail.svg`, and both
login views (`app/javascript/v3/views/login/{Index,Saml}.vue`) render
`globalConfig.logo` / `globalConfig.logoDark` from those same configs — no
hardcoded logo path anywhere in the Vue login/SSO views. The SVG **files
themselves** still contained Chatwoot's actual logo artwork (the "chatwoot"
wordmark path data and the "C" icon mark), because Layer 3 of the branding
pass (WHITE_LABEL.md) was explicitly deferred pending brand image files.

## Fix

Replaced the brand-asset SVGs in place (same filenames/paths, same
`viewBox`/aspect — no config or code changes needed):

- `public/brand-assets/logo.svg`, `logo_dark.svg` — Chatwoot wordmark → "Mesh
  CRM" placeholder wordmark (violet "M" mark + text; dark variant uses white
  text).
- `public/brand-assets/logo_thumbnail.svg` — Chatwoot "C" mark → "M" mark.

Also replaced the favicon/PWA icon set, which was independently
Chatwoot-branded (the round "C" mark baked into PNGs, plus literal
`"Chatwoot"` strings in `manifest.json`):

- `public/favicon-{16,32,96,512}x*.png`, `favicon-badge-{16,32,96}x*.png`,
  `android-icon-*.png`, `apple-icon-*.png`, `ms-icon-*.png` — regenerated from
  the new "M" mark via ImageMagick (`convert`, its built-in MSVG SVG
  renderer — no `rsvg-convert` binary on this box), one PNG per original
  filename/exact pixel dimension.
- `public/manifest.json` — `name`/`short_name` `"Chatwoot"` → `"Mesh CRM"`,
  `background_color`/`theme_color` `#2781F6` → `#5B4FE9` (the new mark's
  violet).

Full detail and file-by-file rationale in `WHITE_LABEL.md`'s "Status — Layer 3
assets shipped" section.

## Verification

Asset/config-only change; no Ruby or Vue/JS source files touched, so no
`ruby -c` or frontend spec/lint run applies. Verified instead:

```sh
identify -format "%f %wx%h\n" public/favicon-96x96.png public/apple-icon-152x152.png ...
# every regenerated PNG matches its original filename's exact WxH
```

```sh
grep -n "globalConfig.logo\|globalConfig.logoDark" \
  app/javascript/v3/views/login/Index.vue app/javascript/v3/views/login/Saml.vue
# both views read the logo from config — confirms no hardcoded bypass, so the
# asset swap is the complete fix
```

Visual proof (the actual rendered login screen) is a post-rebuild e2e
screenshot — not run from this pass; flagging for the controller/CI step that
does asset builds + click-through.

## Notes / related

- `docs/fork/WHITE_LABEL.md` — Layer 3 status, full asset inventory.
- `docs/fork/IMPLEMENTATION_PLAN.md`, `README.md`, `SPEC.md` — status
  registers updated to drop "brand asset files" from the deferred/remaining
  list.
- Not touched: `app/views/layouts/vueapp.html.erb`'s inline `#2781F6`
  `theme-color`/`msapplication-TileColor` meta tags (browser-chrome color,
  not the logo); `public/apple-touch-icon.png` /
  `apple-touch-icon-precomposed.png` (already 0-byte upstream, unreferenced).
