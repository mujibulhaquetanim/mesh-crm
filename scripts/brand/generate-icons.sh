#!/usr/bin/env bash
#
# Regenerate every Zasmate brand asset this fork serves, from the two masters in
# docs/brand/. Run it from the repo root:
#
#   ./scripts/brand/generate-icons.sh
#
# It writes ONLY over filenames that already exist upstream, at their exact
# original pixel dimensions, because `app/views/layouts/vueapp.html.erb` and
# `public/manifest.json` reference them by name and size. Adding a file here
# without adding its <link> does nothing; changing a size silently breaks the
# tag that declares it.
#
# ── The masters (2026-09-28 artwork) ────────────────────────────────────────
#   docs/brand/zasmate-mark.png      the orange "Z" + sparkle
#   docs/brand/zasmate-wordmark.png  the orange ZASMATE wordmark
# Both are RGBA on a TRANSPARENT background, the same files as agentic-str's
# docs/logo_photos/. There is no keying step any more: the old JPEG masters sat
# on an opaque #F7F7F7 field and had to be floodfilled off it
# (docs/fork/error-log/2026-09-22-transparent-matches-globally-and-punches-out-the-logo.md).
#
# Trimming uses an alpha threshold rather than a plain `-trim`: the masters
# carry a few near-transparent specks outside the artwork, and a plain trim
# keeps the box they span. `spec/brand/brand_assets_spec.rb` checks the output
# is opaque orange artwork on a genuinely transparent background.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

if command -v magick >/dev/null 2>&1; then IM=(magick); else IM=(convert); fi

SRC_MARK="docs/brand/zasmate-mark.png"
SRC_WORDMARK="docs/brand/zasmate-wordmark.png"

# The palette's flame orange, for the PWA theme and tile colours
# (public/manifest.json, vueapp.html.erb).
BRAND_COLOUR="#F87D13"
# The unread-conversation dot that `faviconHelper.js` swaps in, ringed in white
# so it separates from the orange mark.
BADGE_RED="#FF4A4A"

for src in "$SRC_MARK" "$SRC_WORDMARK"; do
  [ -f "$src" ] || { echo "missing source master: $src" >&2; exit 1; }
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

# Crop to the pixels that are clearly opaque (alpha > 20%), cropping the
# ORIGINAL so soft edges keep their alpha but stray specks don't widen the box.
crop_to_art() {
  local box
  box="$("${IM[@]}" "$1" -alpha extract -threshold 20% -format '%@' info:)"
  "${IM[@]}" "$1" -crop "$box" +repage "$2"
}

crop_to_art "$SRC_MARK" "$WORK/mark-trimmed.png"
crop_to_art "$SRC_WORDMARK" "$WORK/wordmark-tight.png"
# A transparent margin (3% of the height) so letters cut by the crop aren't
# flush with the image edge.
read -r WW WH < <("${IM[@]}" "$WORK/wordmark-tight.png" -format '%w %h\n' info:)
"${IM[@]}" "$WORK/wordmark-tight.png" -bordercolor none -border "$(( WH * 3 / 100 ))" "$WORK/wordmark.png"

# The mark is slightly wide (the sparkle); every slot below is square, so centre
# it with 8% padding rather than let the resize squash it or the sparkle touch
# a favicon's edge.
read -r MW MH < <("${IM[@]}" "$WORK/mark-trimmed.png" -format '%w %h\n' info:)
SIDE=$(( (MW > MH ? MW : MH) * 108 / 100 ))
"${IM[@]}" "$WORK/mark-trimmed.png" \
  -background none -gravity center -extent "${SIDE}x${SIDE}" "$WORK/mark.png"

# ── Icon slots ──────────────────────────────────────────────────────────────
# One PNG per filename that already exists, at the size its own name claims.
#
# `png:color-type=6` is not cosmetic. Left to itself ImageMagick writes a PALETTE
# PNG whenever the colour count is low enough to be smaller that way, which at
# 16x16 it is — so two of these came out as colour-type 3 while the rest were
# RGBA. Everything downstream that reads the pixels back (the brand spec) then
# has to implement palette decoding to check a favicon. Pinning the type keeps
# one shape across the whole set for a few bytes.
emit() { "${IM[@]}" "$WORK/mark.png" -resize "${2}x${2}" -strip -define png:color-type=6 "$1"; }

for s in 16 32 96 512; do emit "public/favicon-${s}x${s}.png" "$s"; done
for s in 36 48 72 96 144 192; do emit "public/android-icon-${s}x${s}.png" "$s"; done
for s in 57 60 72 76 114 120 144 152 180; do emit "public/apple-icon-${s}x${s}.png" "$s"; done
for s in 70 144 150 310; do emit "public/ms-icon-${s}x${s}.png" "$s"; done
emit "public/apple-icon.png" 192
emit "public/apple-icon-precomposed.png" 192

# These two are 0 bytes upstream — an empty body is worse than a 404, because
# Safari probes /apple-touch-icon.png by convention when no <link> matches and
# caches what it gets. 180 is the size that convention expects.
emit "public/apple-touch-icon.png" 180
emit "public/apple-touch-icon-precomposed.png" 180

# ── Badge variants ──────────────────────────────────────────────────────────
# `dashboard/helper/AudioAlerts/faviconHelper.js` swaps favicon-NxN.png for
# favicon-badge-NxN.png while conversations are unread, so the badge set must
# exist at exactly the sizes the plain set declares in the <link> tags.
badge() {
  local out="$1" s="$2" d r
  d=$(( s * 42 / 100 ))              # dot diameter, matched to upstream's badge
  r=$(( d / 2 ))
  "${IM[@]}" "$WORK/mark.png" -resize "${s}x${s}" \
    -fill "$BADGE_RED" -stroke white -strokewidth "$(( s >= 32 ? 2 : 1 ))" \
    -draw "circle $(( s - r - 1 )),$(( r + 1 )) $(( s - r - 1 )),1" \
    -strip -define png:color-type=6 "$out"
}
for s in 16 32 96; do badge "public/favicon-badge-${s}x${s}.png" "$s"; done

# ── The configured brand assets ─────────────────────────────────────────────
# `config/installation_config.yml` points LOGO / LOGO_DARK / LOGO_THUMBNAIL at
# these three paths and the Vue views render whatever is there, so the filenames
# and extensions are a contract — keep them .svg even though the artwork is
# raster. An <image> element carrying a base64 PNG satisfies both.
#
# The login views size the logo `w-auto h-8`, so only the ratio matters, not the
# absolute numbers.
svg_wrap() {
  local png="$1" out="$2" w h b64
  read -r w h < <("${IM[@]}" "$png" -format '%w %h\n' info:)
  b64="$(base64 -w0 "$png")"
  cat > "$out" <<SVG
<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink"
     width="${w}" height="${h}" viewBox="0 0 ${w} ${h}">
  <image width="${w}" height="${h}" xlink:href="data:image/png;base64,${b64}"/>
</svg>
SVG
}

mkdir -p public/brand-assets

# Rendered at h-8 and h-16; 160px tall carries a 2x display comfortably without
# inlining a megabyte of base64 into every login page.
"${IM[@]}" "$WORK/wordmark.png" -resize x160 -strip "$WORK/logo-light.png"
svg_wrap "$WORK/logo-light.png" "public/brand-assets/logo.svg"

# The dark-mode logo is the same artwork: the orange wordmark reads on white
# and on a dark surface alike. The file stays separate because
# config/installation_config.yml points LOGO_DARK at it. (The old lockup had a
# navy tagline that needed repainting for dark mode; the new one has none.)
cp "$WORK/logo-light.png" "$WORK/logo-dark.png"
svg_wrap "$WORK/logo-dark.png" "public/brand-assets/logo_dark.svg"

# LOGO_THUMBNAIL is also the 512x512 <link rel="icon"> in vueapp.html.erb, so it
# is the square mark at that size, not a shrunken lockup.
"${IM[@]}" "$WORK/mark.png" -resize 512x512 -strip "$WORK/thumb.png"
svg_wrap "$WORK/thumb.png" "public/brand-assets/logo_thumbnail.svg"

echo "Brand colour for manifest.json / vueapp.html.erb / Logo.vue: $BRAND_COLOUR"
echo "Regenerated:"
git status --short public/ | sed 's/^/  /'
