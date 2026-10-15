#!/bin/sh
# Install or update Magnetite.
#
#   curl -fsSL https://magnetite.app/install.sh | sh    # latest release
#   ./install.sh --from-source                          # inside a clone
#
# Why a script instead of only a zip: a browser download is quarantined, and
# macOS will not open an app that is not notarised until you approve it in
# System Settings. curl does not quarantine what it fetches, and a build made on
# your own Mac never was, so both paths here open on the first try. The release
# path still checks the archive against its published SHA-256 and verifies the
# code signature before anything is copied into place.
#
# Environment:
#   MAGNETITE_DEST     install folder (default /Applications, or ~/Applications
#                      when /Applications is not writable)
#   MAGNETITE_VERSION  a specific release, e.g. 0.1.0 (default: latest)
set -eu

REPO="scryst/magnetite-releases"
BUNDLE_ID="com.laks.magnetite"
APP="Magnetite.app"

say() { printf '==> %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

FROM_SOURCE=0
for arg in "$@"; do
  case "$arg" in
    --from-source) FROM_SOURCE=1 ;;
    -h|--help)
      echo "usage: curl -fsSL https://magnetite.app/install.sh | sh"
      echo "       ./install.sh [--from-source]   (inside a clone)"
      echo "env:   MAGNETITE_DEST=<folder>  MAGNETITE_VERSION=<x.y.z>"
      exit 0 ;;
    *) die "unknown argument '$arg' (try --help)" ;;
  esac
done

# The app's own floor: Liquid Glass needs macOS 26, and the build is arm64 only.
[ "$(uname -s)" = Darwin ] || die "Magnetite runs on macOS only."
[ "$(uname -m)" = arm64 ] || die "Magnetite needs a Mac with Apple silicon."
OS_VERSION="$(sw_vers -productVersion)"
[ "${OS_VERSION%%.*}" -ge 26 ] || die "Magnetite needs macOS 26 or later; this Mac runs $OS_VERSION."

WORK="$(mktemp -d -t magnetite-install)"
# Cleanup on exit; a signal must END the run, not clean up and carry on into
# an install from a deleted folder.
trap 'rm -rf "$WORK"' EXIT
trap 'exit 130' INT TERM

# HTTPS only, and bounded: a stalled connection fails instead of hanging.
fetch() { curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 15 --max-time 600 --retry 2 "$@"; }

if [ "$FROM_SOURCE" -eq 1 ]; then
  cd "$(dirname "$0")"
  [ -x ./build.sh ] || die "--from-source must run from a Magnetite checkout (no ./build.sh here)."
  command -v swift >/dev/null 2>&1 || die "Swift not found. Install the Command Line Tools: xcode-select --install"
  say "building from source"
  ./build.sh release
  SOURCE_APP="$PWD/build.noindex/$APP"
else
  if [ -n "${MAGNETITE_VERSION:-}" ]; then
    TAG="v${MAGNETITE_VERSION#v}"
  else
    # The /latest page redirects to the newest tag. Reading the redirect needs
    # no API token and has no rate limit to trip over.
    LATEST="$(fetch -I -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest")" \
      || die "could not reach GitHub to find the latest release."
    TAG="${LATEST##*/}"
  fi
  VERSION="${TAG#v}"
  # Exactly x.y.z: the version lands in URLs and file names below.
  printf '%s' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
    || die "could not work out the release version (got '$TAG')."
  BASE="https://github.com/$REPO/releases/download/$TAG"
  ZIP="Magnetite-$VERSION.zip"

  say "downloading Magnetite $VERSION"
  fetch -o "$WORK/$ZIP" "$BASE/$ZIP" || die "download failed: $BASE/$ZIP"
  fetch -o "$WORK/$ZIP.sha256" "$BASE/Magnetite-$VERSION.sha256" \
    || die "checksum download failed: $BASE/Magnetite-$VERSION.sha256"

  EXPECTED="$(awk 'NR==1 {print $1}' "$WORK/$ZIP.sha256")"
  ACTUAL="$(shasum -a 256 "$WORK/$ZIP" | awk '{print $1}')"
  [ -n "$EXPECTED" ] && [ "$EXPECTED" = "$ACTUAL" ] \
    || die "checksum mismatch for $ZIP (expected ${EXPECTED:-nothing}, got $ACTUAL). Nothing was installed."
  say "checksum ok ($ACTUAL)"

  ditto -x -k "$WORK/$ZIP" "$WORK/unpacked"
  SOURCE_APP="$WORK/unpacked/$APP"
fi

[ -x "$SOURCE_APP/Contents/MacOS/Magnetite" ] || die "$SOURCE_APP is not a complete Magnetite.app."
codesign --verify --deep --strict "$SOURCE_APP" 2>/dev/null \
  || die "the app's code signature does not verify. Nothing was installed."

DEST="${MAGNETITE_DEST:-/Applications}"
if [ -z "${MAGNETITE_DEST:-}" ] && [ ! -w "$DEST" ]; then
  DEST="$HOME/Applications"
fi
mkdir -p "$DEST"
[ -w "$DEST" ] || die "cannot write to $DEST. Set MAGNETITE_DEST to a folder you own."

# Replace a running copy cleanly: ask it to quit, and wait for it to go, so the
# old binary is never deleted out from under a live process.
if [ "$(osascript -e "application id \"$BUNDLE_ID\" is running" 2>/dev/null)" = "true" ]; then
  say "quitting the running Magnetite"
  osascript -e "tell application id \"$BUNDLE_ID\" to quit" >/dev/null 2>&1 || true
  i=0
  while [ "$(osascript -e "application id \"$BUNDLE_ID\" is running" 2>/dev/null)" = "true" ]; do
    i=$((i + 1))
    [ "$i" -le 20 ] || die "Magnetite did not quit. Quit it from its menu-bar icon and run this again."
    sleep 0.25
  done
fi

# Copy beside the old app first, then swap, so a failed copy leaves the
# installed version untouched. The old app is moved aside, not deleted, until
# the new one is in place: a failure between the two leaves it restorable.
say "installing to $DEST/$APP"
rm -rf "$DEST/.$APP.new" "$DEST/.$APP.old"
ditto "$SOURCE_APP" "$DEST/.$APP.new"
[ -e "$DEST/$APP" ] && mv "$DEST/$APP" "$DEST/.$APP.old"
if ! mv "$DEST/.$APP.new" "$DEST/$APP"; then
  [ -e "$DEST/.$APP.old" ] && mv "$DEST/.$APP.old" "$DEST/$APP"
  die "could not move the new app into $DEST. The previous version was kept."
fi
rm -rf "$DEST/.$APP.old"

open "$DEST/$APP"
cat <<EOF

Magnetite is running. Look for its M in the menu bar, then hover the notch.

The first time music plays, macOS asks to let Magnetite control Spotify or
Music, and to record system audio for the visualiser. Audio never leaves
your Mac.

Update:     run this installer again
Uninstall:  quit Magnetite from its menu, then delete $DEST/$APP
EOF
