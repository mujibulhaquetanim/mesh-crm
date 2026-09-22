# `-transparent` matched the logo's own white and punched the Z out of it

- **Date**: 2026-09-22
- **Phase**: 7 (Branding pass, Layer 3 — real artwork)
- **Area**: frontend (static assets)

## Symptom

No error. That is the entry.

Lifting the new Zasmate artwork off its opaque JPEG background with the obvious
recipe produced a PNG that passed every check worth making casually — it opened,
it had an alpha channel, it was exactly 512×512:

```sh
convert docs/brand/zasmate_bubble.jpeg -fuzz 12% -transparent '#F7F7F7' mark.png
identify -format '%wx%h %[channels]' mark.png
# 512x512 srgba
```

Composited onto the dark sidebar, the logo had a hole where its letter should
be. Measured:

```text
opaque pixels — naive -transparent : 30.0%
opaque pixels — floodfill          : 68.9%
```

## Root cause

`-transparent` matches a colour **globally**, not a region. The masters sit on
`#F7F7F7`, and the logo's "Z" and the speech-bubble interior are the same
near-white, so they were matched too and made transparent along with the
background. Nothing distinguishes them by colour — only by *connectivity to the
edge*.

A second, quieter instance of the same class: building the dark-surface lockup
by repainting "all dark ink" also repainted the mark's lower orbit dot, whose
core (`#035471`, 24.7% luma) is darker than it looks next to a near-black
tagline at 12.3%. Threshold tuning could not separate them reliably — at every
cut from 14% to 22% some mark pixels still moved.

## Fix

`scripts/brand/generate-icons.sh`, which now generates every raster in
`public/` from the two masters in `docs/brand/`:

- Background removal is an edge-connected floodfill, seeded from a 1px border
  added in the same pipe so all four outer regions connect to one seed:

  ```sh
  -alpha set -bordercolor '#F7F7F7' -border 1 \
  -fuzz 12% -fill none -floodfill +0+0 '#F7F7F7' \
  -shave 1x1 -trim +repage
  ```

- The dark-lockup recolour is gated **geometrically as well as by luminance**:
  only right of the run of fully transparent columns between mark and text,
  which the generator detects rather than hardcodes. The mark is then
  byte-identical in both variants, which is asserted, not assumed.

- Every icon is pinned to `-define png:color-type=6`. Without it ImageMagick
  wrote a *palette* PNG wherever the colour count was low enough to be smaller —
  which at 16×16 it was, so two of thirty came out colour-type 3 while the rest
  were RGBA. That is not wrong as a PNG, but it means anything reading the
  pixels back has to grow a palette decoder to check a favicon.

## Verification

`spec/brand/brand_assets_spec.rb` counts pixels that are near-white **and**
opaque — the white Z is what disappears, so the white Z is what it counts:

```sh
bundle exec rspec spec/brand/brand_assets_spec.rb
```

Measured 8–12% across the icon set depending on size, against **exactly 0** for
the broken build. The floor is 0.05: what it has to clear is zero, so width is
free, and the smallest icon (32×32) sits at 0.0801 — a floor of 0.08 would have
been a coin flip on every re-render.

Proved the guard fails before trusting it — swapped a naive-built favicon in and
confirmed it was flagged at `0.0000`, then regenerated.

## Notes / related

- `docs/fork/WHITE_LABEL.md` — "Status — real brand artwork, renamed to Zasmate".
- `docs/fork/error-log/2026-08-23-login-sso-still-shows-chatwoot-logo.md` — the
  pass this one completes. It shipped a deliberate placeholder and listed the
  real files as pending; it also left `apple-touch-icon.png` at 0 bytes as
  "unreferenced", which is true of `<link>` tags but not of Safari's
  by-convention probe of that exact path.
- `docs/fork/REBRAND_PRODUCTION.md` — none of this reaches a running instance
  until four `installation_configs` rows are updated.
