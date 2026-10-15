#!/bin/sh
# Point install.sh at a release: rewrite its PIN_VERSION and PIN_SHA256 lines.
#
#   tools/pin-installer.sh <install.sh> <x.y.z> <sha256>
#
# build.sh --stage-release calls this with the staged archive's digest, and
# tools/installcheck.sh calls it on temporary copies. Each line must exist
# exactly once; anything else means the installer was edited by hand into a shape
# this cannot pin safely, and it stops rather than guess.
set -eu

[ $# -eq 3 ] || { echo "usage: tools/pin-installer.sh <install.sh> <x.y.z> <sha256>" >&2; exit 2; }
file="$1"; version="$2"; sha="$3"
printf '%s' "$version" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
  || { echo "error: '$version' is not x.y.z" >&2; exit 2; }
printf '%s' "$sha" | grep -Eq '^[0-9a-f]{64}$' \
  || { echo "error: '$sha' is not a lowercase SHA-256" >&2; exit 2; }
[ -f "$file" ] || { echo "error: $file not found" >&2; exit 2; }

for key in PIN_VERSION PIN_SHA256; do
  [ "$(grep -c "^$key=\"[^\"]*\"\$" "$file")" -eq 1 ] \
    || { echo "error: $file must contain exactly one '$key=\"...\"' line" >&2; exit 1; }
done

tmp="$(mktemp -t pin-installer)"
trap 'rm -f "$tmp"' EXIT
sed -e "s/^PIN_VERSION=\"[^\"]*\"\$/PIN_VERSION=\"$version\"/" \
    -e "s/^PIN_SHA256=\"[^\"]*\"\$/PIN_SHA256=\"$sha\"/" "$file" > "$tmp"
# cat, not mv: keeps the file's mode and ownership.
cat "$tmp" > "$file"
grep -qx "PIN_VERSION=\"$version\"" "$file" && grep -qx "PIN_SHA256=\"$sha\"" "$file" \
  || { echo "error: pin rewrite of $file did not take" >&2; exit 1; }
