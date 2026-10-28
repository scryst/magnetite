#!/bin/sh
# Install or update Magnetite.
#
#   curl -fsSL https://magnetite.app/install.sh | sh    # the release pinned below
#   ./install.sh --from-source                          # inside a clone
#
# Why a script instead of only a zip: a browser download is quarantined, and
# macOS will not open an app that is not notarised until you approve it in
# System Settings. curl does not quarantine what it fetches, and a build made on
# your own Mac never was, so both paths here open on the first try.
#
# Authenticity: this script carries the fingerprint of the release it installs.
# The download is checked against PIN_SHA256 below, not against a file fetched
# from the same place as the zip, so someone who could swap the zip could not
# also swap its checksum. `./build.sh release --stage-release` rewrites the two
# PIN_ lines; deploy.sh refuses to publish a script whose pin is not the digest
# of the published release.
#
# Environment:
#   MAGNETITE_DEST     install folder (default: where Magnetite already is, else
#                      /Applications, or ~/Applications when that is not writable)
#   MAGNETITE_VERSION  a different release, e.g. 0.1.0. It has no built-in
#                      fingerprint, so it is checked against the checksum file
#                      published beside it, which catches a damaged download but
#                      not a tampered release.
PIN_VERSION="0.1.6"
PIN_SHA256="b928c1553f101f676bc9c10de93c14214a37cf1d5030034116637d148325dab8"
set -eu

REPO="scryst/magnetite-releases"
BUNDLE_ID="com.laks.magnetite"
APP="Magnetite.app"
# Only tests change this: it keeps installcheck.sh away from the real /Applications.
SYSTEM_APPS="${MAGNETITE_SYSTEM_APPS:-/Applications}"

say() { printf '%s\n' "$*"; }
die() { printf '\n%s\n' "$*" >&2; exit 1; }

# HTTPS only, and bounded: a stalled connection fails instead of hanging.
fetch() { curl -fsSL --proto '=https' --tlsv1.2 --connect-timeout 15 --max-time 600 --retry 2 "$@"; }

# The pid of the running Magnetite, or nothing. Asks LaunchServices directly, so
# no Apple Event is sent and macOS shows no Automation prompt for the terminal.
running_pid() {
  _asn="$(lsappinfo find "bundleid=$BUNDLE_ID" 2>/dev/null | sed -n 1p || true)"
  [ -n "$_asn" ] || return 0
  lsappinfo info -only pid "$_asn" 2>/dev/null \
    | grep -Eo '"?pid"? *= *[0-9]+' | sed -n 1p | grep -Eo '[0-9]+$' || true
}

# plist_value <app> <key>
plist_value() { /usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist" 2>/dev/null || true; }

# Refuse anything that is not the Magnetite this installer means to put in place.
# verify_bundle <app> <expected version, or empty to skip the version check>
verify_bundle() {
  _app="$1"
  _exe="$_app/Contents/MacOS/Magnetite"
  [ -x "$_exe" ] && [ -f "$_app/Contents/Info.plist" ] \
    || die "The download wasn't a complete copy of Magnetite, so nothing was installed."
  [ "$(plist_value "$_app" CFBundleIdentifier)" = "$BUNDLE_ID" ] \
    || die "The download isn't Magnetite (wrong app identifier), so nothing was installed."
  if [ -n "$2" ] && [ "$(plist_value "$_app" CFBundleShortVersionString)" != "$2" ]; then
    die "The download isn't Magnetite $2 (wrong version), so nothing was installed."
  fi
  case " $(lipo -archs "$_exe" 2>/dev/null || true) " in
    *" arm64 "*) ;;
    *) die "The download doesn't run on Apple silicon, so nothing was installed." ;;
  esac
  codesign --verify --deep --strict "$_app" >/dev/null 2>&1 \
    || die "The app's signature is damaged, so nothing was installed."
}

# Runs on every exit, including a signal. Puts the previous app back if the new
# one never arrived, and removes scratch files.
cleanup() {
  if [ -n "${OLD_APP:-}" ] && [ -e "${OLD_APP:-}" ] && [ ! -e "${TARGET:-}" ]; then
    mv "$OLD_APP" "$TARGET" 2>/dev/null \
      && printf '\n%s\n' "Magnetite was not updated. Your previous version was put back." >&2 || true
  fi
  [ -z "${NEW_APP:-}" ] || rm -rf "$NEW_APP" 2>/dev/null || true
  [ -z "${WORK:-}" ] || rm -rf "$WORK" 2>/dev/null || true
}

main() {
  FROM_SOURCE=0
  for arg in "$@"; do
    case "$arg" in
      --from-source) FROM_SOURCE=1 ;;
      -h|--help)
        echo "usage: curl -fsSL https://magnetite.app/install.sh | sh"
        echo "       ./install.sh [--from-source]   (inside a clone)"
        echo "env:   MAGNETITE_DEST=<folder>  MAGNETITE_VERSION=<x.y.z>"
        exit 0 ;;
      *) die "Unknown option '$arg'. Try --help." ;;
    esac
  done

  [ "$(id -u)" -ne 0 ] \
    || die "Please run this without sudo. Magnetite installs into your own Applications folder and needs no administrator rights."

  # The app's own floor: Liquid Glass needs macOS 26, and the build is arm64 only.
  [ "$(uname -s)" = Darwin ] || die "Magnetite runs on a Mac only."
  # hw.optional.arm64 stays 1 on Apple silicon even when this shell runs under
  # Rosetta, where `uname -m` would say x86_64.
  [ "$(sysctl -n hw.optional.arm64 2>/dev/null || echo 0)" = 1 ] \
    || die "Magnetite needs a Mac with Apple silicon (M1 or newer)."
  OS_VERSION="$(sw_vers -productVersion 2>/dev/null || true)"
  case "${OS_VERSION%%.*}" in
    ''|*[!0-9]*) say "Couldn't read this Mac's macOS version; carrying on." ;;
    *) [ "${OS_VERSION%%.*}" -ge 26 ] \
         || die "Magnetite needs macOS 26 or newer, and this Mac is on $OS_VERSION. Update macOS in System Settings, then run this again." ;;
  esac

  WORK="$(mktemp -d -t magnetite-install)"
  NEW_APP=""
  OLD_APP=""
  TARGET=""
  # A signal must END the run: `trap cleanup EXIT` alone would clean up and then
  # carry on into an install from a deleted folder.
  trap cleanup EXIT
  trap 'exit 130' INT TERM

  if [ "$FROM_SOURCE" -eq 1 ]; then
    cd "$(dirname "$0")"
    [ -x ./build.sh ] || die "--from-source must run from a Magnetite checkout (no ./build.sh here)."
    command -v swift >/dev/null 2>&1 || die "Swift isn't installed. Install the Command Line Tools with: xcode-select --install"
    say "Building Magnetite from source..."
    ./build.sh release
    SOURCE_APP="$PWD/build.noindex/$APP"
    VERSION="$(plist_value "$PWD/build.noindex/$APP" CFBundleShortVersionString)"
    EXPECT_VERSION="$VERSION"
  else
    VERSION="${MAGNETITE_VERSION:-$PIN_VERSION}"
    VERSION="${VERSION#v}"
    # Exactly x.y.z: the version lands in URLs and file names below.
    printf '%s' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$' \
      || die "'$VERSION' isn't a Magnetite version number (it should look like 0.1.3)."
    BASE="https://github.com/$REPO/releases/download/v$VERSION"
    ZIP="Magnetite-$VERSION.zip"

    say "Downloading Magnetite $VERSION..."
    fetch -o "$WORK/$ZIP" "$BASE/$ZIP" \
      || die "The download failed. Check your internet connection and try again."

    if [ "$VERSION" = "$PIN_VERSION" ]; then
      EXPECTED="$PIN_SHA256"
    else
      say "Note: this installer doesn't know the official fingerprint of Magnetite $VERSION."
      say "It will only be checked against the checksum published next to it, which"
      say "catches a damaged download but not a tampered one."
      fetch -o "$WORK/$ZIP.sha256" "$BASE/Magnetite-$VERSION.sha256" \
        || die "The download failed. Check your internet connection and try again."
      EXPECTED="$(awk 'NR==1 {print $1}' "$WORK/$ZIP.sha256")"
    fi
    ACTUAL="$(shasum -a 256 "$WORK/$ZIP" | awk '{print $1}')"
    if [ -z "$EXPECTED" ] || [ "$EXPECTED" != "$ACTUAL" ]; then
      die "The download didn't match the official release, so nothing was installed. Please try again."
    fi

    ditto -x -k "$WORK/$ZIP" "$WORK/unpacked" \
      || die "The download couldn't be unpacked, so nothing was installed. Please try again."
    SOURCE_APP="$WORK/unpacked/$APP"
    EXPECT_VERSION="$VERSION"
  fi

  verify_bundle "$SOURCE_APP" "$EXPECT_VERSION"

  # Update in place: if Magnetite is already installed, that is where the new
  # copy goes, so there is never a second Magnetite for Spotlight to offer.
  if [ -n "${MAGNETITE_DEST:-}" ]; then
    DEST="$MAGNETITE_DEST"
  elif [ -e "$SYSTEM_APPS/$APP" ]; then
    DEST="$SYSTEM_APPS"
  elif [ -e "$HOME/Applications/$APP" ]; then
    DEST="$HOME/Applications"
  elif [ -w "$SYSTEM_APPS" ]; then
    DEST="$SYSTEM_APPS"
  else
    DEST="$HOME/Applications"
  fi
  mkdir -p "$DEST" 2>/dev/null || true
  [ -w "$DEST" ] \
    || die "This account can't change $DEST, where Magnetite is. Move $APP to the Bin yourself, then run this again."
  TARGET="$DEST/$APP"
  NEW_APP="$DEST/.$APP.new"
  OLD_APP="$DEST/.$APP.old"

  # A previous run that died between its two moves left the old app aside.
  if [ -e "$OLD_APP" ] && [ ! -e "$TARGET" ]; then
    mv "$OLD_APP" "$TARGET" || die "Couldn't recover the earlier copy of Magnetite in $DEST."
  fi
  UPDATING=0
  [ ! -e "$TARGET" ] || UPDATING=1

  # Quit a running copy so its files are never replaced under it. SIGTERM goes to
  # the one pid LaunchServices reports; no Apple Events, so no Automation prompt.
  PID="$(running_pid)"
  if [ -n "$PID" ]; then
    say "Closing the running copy of Magnetite..."
    kill -TERM "$PID" 2>/dev/null || true
    i=0
    while kill -0 "$PID" 2>/dev/null; do
      i=$((i + 1))
      [ "$i" -le 20 ] \
        || die "Magnetite is still running, so nothing was changed. Quit it from the M in your menu bar, then run this again."
      sleep 0.25
    done
  fi

  # Copy beside the old app first, then swap, so a failed copy leaves the
  # installed version untouched. The old app is moved aside, not deleted, until
  # the new one is in place and has started; the EXIT trap puts it back if the
  # new one never arrives.
  say "Installing to $DEST..."
  rm -rf "$NEW_APP"
  ditto "$SOURCE_APP" "$NEW_APP" \
    || die "Couldn't copy Magnetite into $DEST. Nothing was changed."
  if [ "$UPDATING" -eq 1 ]; then
    rm -rf "$OLD_APP"
    mv "$TARGET" "$OLD_APP" || die "Couldn't replace the existing Magnetite in $DEST. Nothing was changed."
  fi
  mv "$NEW_APP" "$TARGET" \
    || die "Couldn't put the new Magnetite into $DEST. Your previous version was kept."

  open "$TARGET" >/dev/null 2>&1 || true
  i=0
  LAUNCHED=0
  while [ "$i" -lt 20 ]; do
    NOW="$(running_pid)"
    # Not the copy we just closed, which LaunchServices can list for a moment.
    if [ -n "$NOW" ] && [ "$NOW" != "$PID" ]; then LAUNCHED=1; break; fi
    i=$((i + 1))
    sleep 0.25
  done

  if [ "$LAUNCHED" -eq 0 ] && [ "$UPDATING" -eq 1 ]; then
    rm -rf "$TARGET"
    mv "$OLD_APP" "$TARGET"
    open "$TARGET" >/dev/null 2>&1 || true
    die "The new version didn't start, so your previous version was put back. Please try again in a minute."
  fi
  rm -rf "$OLD_APP"
  OLD_APP=""

  if [ "$LAUNCHED" -eq 0 ]; then
    say "Magnetite is installed in $DEST but didn't start by itself. Open it from there."
    return 0
  fi
  cat <<EOF

The first time music plays, macOS asks to let Magnetite control Spotify or
Music, and to record system audio for the visualiser. Audio never leaves
your Mac.

Update:     run this installer again
Uninstall:  quit Magnetite from its menu, then delete $TARGET

EOF
  if [ "$UPDATING" -eq 1 ]; then
    say "Magnetite $VERSION is updated in $DEST. Look for the M in your menu bar."
  else
    say "Magnetite $VERSION is installed in $DEST. Look for the M in your menu bar."
  fi
}

main "$@"
