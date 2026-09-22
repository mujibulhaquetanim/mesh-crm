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
# ── Why floodfill and not `-transparent` ────────────────────────────────────
# The masters are JPEGs on an opaque #F7F7F7 field. The obvious recipe,
# `-fuzz 12% -transparent '#F7F7F7'`, matches that colour GLOBALLY — and the
# logo's "Z" and the speech-bubble interior are the same near-white, so they go
# transparent too and you ship a logo you can see through. It still opens, still
# has an alpha channel, still has the right dimensions. Measured: 30% opaque
# against 69% for the correct lift.
#
# `-floodfill +0+0` spreads only through *connected* colour, so it takes the
# outer field and stops at the bubble's edge. The 1px border added first makes
# all four outer regions connected to the seed.
#
# `spec/brand/brand_assets_spec.rb` counts the white Z in the output, so the
# naive recipe cannot come back unnoticed.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/../.."

if command -v magick >/dev/null 2>&1; then IM=(magick); else IM=(convert); fi

SRC_MARK="docs/brand/zasmate_bubble.jpeg"
SRC_WORDMARK="docs/brand/zasmate_logo.jpeg"
BG="#F7F7F7"
FUZZ="12%"

# Sampled from the artwork: the bubble's dominant cyan. Used for the PWA theme
# and tile colours, which upstream still had on Chatwoot's #2781F6.
BRAND_CYAN="#19A6D3"
# The unread-conversation dot that `faviconHelper.js` swaps in.
BADGE_RED="#FF4A4A"

for src in "$SRC_MARK" "$SRC_WORDMARK"; do
  [ -f "$src" ] || { echo "missing source master: $src" >&2; exit 1; }
done

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

key_out() {
  "${IM[@]}" "$1" \
    -alpha set -bordercolor "$BG" -border 1 \
    -fuzz "$FUZZ" -fill none -floodfill +0+0 "$BG" \
    -shave 1x1 -trim +repage "$2"
}

key_out "$SRC_MARK" "$WORK/mark-trimmed.png"
key_out "$SRC_WORDMARK" "$WORK/wordmark.png"

# The mark trims to a non-square box (the orbit dots overhang right); every slot
# below is square, so centre it rather than let the resize squash it.
read -r MW MH < <("${IM[@]}" "$WORK/mark-trimmed.png" -format '%w %h\n' info:)
SIDE=$(( MW > MH ? MW : MH ))
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
    -fill "$BADGE_RED" -stroke none \
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

# The dark-mode logo is a SEPARATE FILE, not a CSS filter: the lockup's tagline
# is near-black navy and disappears on a dark surface. Repaint just that ink,
# behind two gates — geometric (only right of the gap between mark and text, so
# the mark's navy orbit dot survives; its core is 24.7% luma, darker than it
# looks) and luminance (the tagline is 12.3%, the darkest ZASMATE blue 35.8%).
read -r LW LH < <("${IM[@]}" "$WORK/logo-light.png" -format '%w %h\n' info:)
GAP="$("${IM[@]}" "$WORK/logo-light.png" -alpha extract -scale x1! -threshold 1% txt:- 2>/dev/null |
  awk -F'[,:( ]+' '
    NR > 1 { empty[$1] = ($4 == 0) ? 1 : 0; if ($1 > max) max = $1 }
    END {
      best = -1
      for (x = 1; x < max; x++) {
        if (empty[x]) { if (!run) start = x; run++ }
        else if (run) { if (run > best) { best = run; mid = int((start + x - 1) / 2) } ; run = 0 }
      }
      print (best > 0) ? mid : 0
    }')"
[ "$GAP" -gt 0 ] || { echo "could not find the mark/text gap in the lockup" >&2; exit 1; }

"${IM[@]}" "$WORK/logo-light.png" -alpha off -colorspace gray -threshold 25% -negate "$WORK/ink.png"
"${IM[@]}" "$WORK/ink.png" -fill black -draw "rectangle 0,0 ${GAP},${LH}" "$WORK/ink-gated.png"
"${IM[@]}" "$WORK/logo-light.png" -alpha extract "$WORK/alpha.png" 2>/dev/null
"${IM[@]}" "$WORK/ink-gated.png" "$WORK/alpha.png" -compose Multiply -composite "$WORK/ink-mask.png"
"${IM[@]}" -size "${LW}x${LH}" xc:"#C8DCE8" "$WORK/plate.png"
"${IM[@]}" "$WORK/logo-light.png" "$WORK/plate.png" "$WORK/ink-mask.png" \
  -compose Over -composite -strip "$WORK/logo-dark.png"
svg_wrap "$WORK/logo-dark.png" "public/brand-assets/logo_dark.svg"

# LOGO_THUMBNAIL is also the 512x512 <link rel="icon"> in vueapp.html.erb, so it
# is the square mark at that size, not a shrunken lockup.
"${IM[@]}" "$WORK/mark.png" -resize 512x512 -strip "$WORK/thumb.png"
svg_wrap "$WORK/thumb.png" "public/brand-assets/logo_thumbnail.svg"

echo "Brand colour for manifest.json / vueapp.html.erb: $BRAND_CYAN"
echo "Regenerated:"
git status --short public/ | sed 's/^/  /'
