#!/usr/bin/env bash
# Build Resources/AppIcon.icns from the icon's source artwork.
#
#   app/dictation/make-icon.sh            use Resources/AppIcon.png, else Resources/AppIcon.svg
#   app/dictation/make-icon.sh <file>     use that .png or .svg
#
# The source is a 1024x1024 PNG (resized with sips, nothing to install) or an
# SVG (rendered with rsvg-convert: brew install librsvg). iconutil is macOS's.
# The .icns is committed: build.sh only copies it, so a CI runner without any
# of these tools still builds the app. After changing the artwork, run this and
# commit the new .icns.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
icns=$here/Resources/AppIcon.icns

src=${1:-}
if [ -z "$src" ]; then
    for candidate in "$here/Resources/AppIcon.png" "$here/Resources/AppIcon.svg"; do
        if [ -f "$candidate" ]; then src=$candidate; break; fi
    done
fi
[ -f "$src" ] || { echo "make-icon.sh: no source: put a 1024x1024 AppIcon.png in Resources/ or pass a file" >&2; exit 1; }
command -v iconutil >/dev/null || { echo "make-icon.sh: iconutil not found (macOS only)" >&2; exit 1; }

# render <pixels> <out.png>: the source at that size.
case "$src" in
    *.png)
        render() { sips -z "$1" "$1" "$src" --out "$2" >/dev/null; }
        ;;
    *.svg)
        command -v rsvg-convert >/dev/null || { echo "make-icon.sh: rsvg-convert not found (brew install librsvg)" >&2; exit 1; }
        render() { rsvg-convert -w "$1" -h "$1" "$src" -o "$2"; }
        ;;
    *)
        echo "make-icon.sh: the source must be a .png or a .svg: $src" >&2
        exit 1
        ;;
esac

work=$(mktemp -d "${TMPDIR:-/tmp}/ox-say-icon.XXXXXX")
iconset=$work/AppIcon.iconset
mkdir "$iconset"
cleanup() {
    rm -f "$iconset"/*.png
    rmdir "$iconset" "$work" 2>/dev/null || true
}
trap cleanup EXIT

# The sizes an .icns needs: each point size at 1x and at 2x (twice the pixels).
for points in 16 32 128 256 512; do
    render "$points" "$iconset/icon_${points}x${points}.png"
    render $((points * 2)) "$iconset/icon_${points}x${points}@2x.png"
done
iconutil -c icns "$iconset" -o "$icns"
echo "wrote $icns from $src"
