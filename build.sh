#!/bin/bash
# Build Magnetite and assemble a runnable .app bundle.
#
# The SwiftPM target is still `NotchApp` — an internal module name, and the
# thing it draws really is the notch. What ships is named Magnetite, so the binary
# is copied in under that name to match `CFBundleExecutable`; that string is
# what Activity Monitor and the crash reporter show.
#
# There is no Xcode project here on purpose: this machine has Command Line Tools
# only, so `xcodebuild` is unavailable. SwiftPM produces the executable and we
# assemble the bundle around it, which is all a menu-bar app actually needs.
set -euo pipefail

cd "$(dirname "$0")"

CONFIG="${1:-release}"
STAGE_RELEASE="${2:-}"
if [[ $# -gt 2 ]]; then
  echo "error: expected at most two arguments, got $#" >&2
  echo "  usage: ./build.sh [debug|release] [--stage-release]" >&2
  exit 2
fi
if [[ "$CONFIG" != "debug" && "$CONFIG" != "release" ]]; then
  echo "error: configuration must be debug or release" >&2
  echo "  usage: ./build.sh [debug|release] [--stage-release]" >&2
  exit 2
fi
if [[ -n "$STAGE_RELEASE" && "$STAGE_RELEASE" != "--stage-release" ]]; then
  echo "error: unknown argument '$STAGE_RELEASE'" >&2
  echo "  usage: ./build.sh [debug|release] [--stage-release]" >&2
  exit 2
fi
if [[ "$CONFIG" == "debug" && "$STAGE_RELEASE" == "--stage-release" ]]; then
  echo "error: --stage-release requires a release build" >&2
  exit 2
fi
# `.noindex`, and the suffix is the whole point: Spotlight skips any directory
# whose name ends in it. Assembled anywhere else, the freshly built bundle is
# indexed alongside the copy the user actually installed, and every launcher —
# Spotlight, Launchpad, Alfred — offers two identical Magnetites with no way to
# tell which is the real one. `.gitignore` does nothing about that; it keeps the
# artifact out of Git, not out of the index.
APP="build.noindex/Magnetite.app"

echo "==> swift build -c $CONFIG"
swift build -c "$CONFIG"

BIN="$(swift build -c "$CONFIG" --show-bin-path)/NotchApp"
if [[ ! -x "$BIN" ]]; then
  echo "error: built binary not found at $BIN" >&2
  exit 1
fi

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/Magnetite"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# Before signing, not after: resources are part of what the signature covers, so
# an icon copied in afterwards invalidates it.
cp Resources/Magnetite.icns "$APP/Contents/Resources/Magnetite.icns"
# The terms travel with the artifact: a downloaded zip that carries only a
# binary is an unlicensed binary, whatever the website said.
cp LICENSE "$APP/Contents/Resources/LICENSE"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# Signing.
#
# Two paths. The default is an ad-hoc signature: enough to run locally, and TCC
# will still prompt for Automation. Gatekeeper REJECTS it — `spctl --assess`
# returns 3 — so an ad-hoc build downloaded from a website needs the user to
# allow it by hand in System Settings. That is a real cost, and it is the reason
# the second path exists.
#
# The second path is Developer ID + notarisation, and it turns on only when the
# credentials are present in the environment:
#
#   MAGNETITE_IDENTITY       "Developer ID Application: Name (TEAMID)"
#   MAGNETITE_NOTARY_PROFILE a notarytool keychain profile, stored once with
#                            `xcrun notarytool store-credentials`
#
# Neither is read from a file and neither is ever printed here. Set them in the
# shell that runs a release and nowhere else.
ENTITLEMENTS="Resources/Magnetite.entitlements"

if [[ -n "${MAGNETITE_IDENTITY:-}" ]]; then
  echo "==> codesign (Developer ID, hardened runtime)"
  # --options runtime is what notarisation requires, and it is also what makes
  # the entitlements file necessary: under the hardened runtime the audio tap
  # and the Apple Events calls are refused unless the binary is entitled.
  codesign --force --timestamp --options runtime \
    --entitlements "$ENTITLEMENTS" \
    --sign "$MAGNETITE_IDENTITY" "$APP"
  codesign --verify --deep --strict --verbose=2 "$APP"
else
  echo "==> codesign (ad-hoc — Gatekeeper will reject this build)"
  codesign --force --deep --sign - "$APP" 2>/dev/null
fi

# Packaging. ditto rather than `zip`, because zip drops the symlinks and
# extended attributes a bundle's signature is stored in — a zipped-with-zip app
# arrives at the far end with a broken signature.
VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ZIP="build.noindex/Magnetite-$VERSION.zip"
echo "==> packaging $ZIP"
rm -f "$ZIP"
ditto -c -k --keepParent --sequesterRsrc "$APP" "$ZIP"

if [[ -n "${MAGNETITE_NOTARY_PROFILE:-}" ]]; then
  if [[ -z "${MAGNETITE_IDENTITY:-}" ]]; then
    echo "error: MAGNETITE_NOTARY_PROFILE is set but MAGNETITE_IDENTITY is not." >&2
    echo "       Apple will not notarise an ad-hoc signature; there is nothing to staple to." >&2
    exit 1
  fi
  echo "==> notarytool submit (this waits on Apple)"
  xcrun notarytool submit "$ZIP" --keychain-profile "$MAGNETITE_NOTARY_PROFILE" --wait

  # Staple the ticket to the .app, then RE-ZIP: the ticket lands inside the
  # bundle, so the archive built before stapling does not contain it and the
  # download would still need a round trip to Apple on first launch.
  echo "==> stapling"
  xcrun stapler staple "$APP"
  rm -f "$ZIP"
  ditto -c -k --keepParent --sequesterRsrc "$APP" "$ZIP"
  xcrun stapler validate "$APP"
fi

# Verify the archive, not merely its source bundle. The ZIP is the trust
# boundary users cross: extract it with the same native tool that packages it,
# then make every release gate inspect those shipped bytes.
VERIFY_ROOT="$(mktemp -d -t magnetite-package)"
cleanup() { rm -rf "$VERIFY_ROOT"; }
trap cleanup EXIT
ditto -x -k "$ZIP" "$VERIFY_ROOT"
PACKAGED_APP="$VERIFY_ROOT/Magnetite.app"
if [[ ! -x "$PACKAGED_APP/Contents/MacOS/Magnetite" ]]; then
  echo "error: $ZIP did not unpack to a complete Magnetite.app" >&2
  exit 1
fi
codesign --verify --deep --strict --verbose=2 "$PACKAGED_APP"
ARCHIVE_SHA256="$(shasum -a 256 "$ZIP" | awk '{print $1}')"

echo
echo "==> gatekeeper assessment"
if [[ -n "${MAGNETITE_IDENTITY:-}" && -n "${MAGNETITE_NOTARY_PROFILE:-}" ]]; then
  # The release gate. A build made with credentials is the one meant to be
  # staged, and one Gatekeeper rejects must never get there — so under `set -e`
  # a rejection kills the run before anyone can stage what it packaged. The
  # tolerant branch below is for ad-hoc builds only.
  spctl --assess --type execute --verbose=4 "$PACKAGED_APP"
  xcrun stapler validate "$PACKAGED_APP"
else
  # The honest check. Exit 3 means Gatekeeper rejects the build, which is
  # expected and correct for an ad-hoc signature — it is reported, never
  # swallowed.
  spctl --assess --type execute --verbose=4 "$PACKAGED_APP" || \
    echo "    (rejected — expected without Developer ID + notarisation)"
fi

# A normal build is disposable. Staging is explicit and immutable: rebuilding
# the same version to different bytes must be answered by a version bump, never
# by quietly replacing the artifact the site and GitHub Release already name.
if [[ "$STAGE_RELEASE" == "--stage-release" ]]; then
  RELEASE_ZIP="site/downloads/Magnetite-$VERSION.zip"
  if [[ -e "$RELEASE_ZIP" ]]; then
    RELEASE_SHA256="$(shasum -a 256 "$RELEASE_ZIP" | awk '{print $1}')"
    if [[ "$RELEASE_SHA256" != "$ARCHIVE_SHA256" ]]; then
      echo "error: $RELEASE_ZIP already contains different bytes" >&2
      echo "       bump CFBundleShortVersionString before staging a new release" >&2
      exit 1
    fi
    echo "==> release already staged at $RELEASE_ZIP"
  else
    cp "$ZIP" "$RELEASE_ZIP"
    echo "==> staged release at $RELEASE_ZIP"
  fi
fi

echo
echo "built:    $APP"
echo "packaged: $ZIP"
echo "sha256:   $ARCHIVE_SHA256"
echo "run:      open $APP        (or ./$APP/Contents/MacOS/Magnetite for logs)"
