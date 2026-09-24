#!/bin/bash
# Build Resources/Magnetite.icns from the 1024 master that icon.html renders.
#
#   site/test/make-icns.sh
#
# `sips` and `iconutil` both ship with macOS, which matters here: there is no
# Xcode on this machine, only Command Line Tools, and the whole build is
# arranged around that (see build.sh). No asset catalogue, no Icon Composer.
#
# The ten entries below are what `iconutil` expects, and all ten are required —
# a .icns missing 16x16 does not fall back gracefully, it hands the Finder a
# downsampled 1024 for a list row and the result looks soft next to every other
# icon in the column.
set -euo pipefail

cd "$(dirname "$0")/../.."

MASTER="site/test/icon-1024.png"
OUT="Resources/Magnetite.icns"
SET="$(mktemp -d)/Magnetite.iconset"

if [[ ! -f "$MASTER" ]]; then
  echo "error: $MASTER not found — render it from site/test/icon.html first" >&2
  exit 1
fi

mkdir -p "$SET"

# name                px   — the @2x entries are the same pixels as the next
#                            size up, which is what the format asks for.
while read -r name px; do
  [[ -z "$name" ]] && continue
  sips -s format png -z "$px" "$px" "$MASTER" --out "$SET/$name" >/dev/null
done <<'SIZES'
icon_16x16.png 16
icon_16x16@2x.png 32
icon_32x32.png 32
icon_32x32@2x.png 64
icon_128x128.png 128
icon_128x128@2x.png 256
icon_256x256.png 256
icon_256x256@2x.png 512
icon_512x512.png 512
icon_512x512@2x.png 1024
SIZES

iconutil -c icns "$SET" -o "$OUT"
rm -rf "$(dirname "$SET")"

echo "built: $OUT ($(stat -f%z "$OUT") bytes)"
