#!/bin/bash
# Every check, headless. Runs without a display, which matters: the failures
# these cover were all found by measuring, not by looking.
set -e
cd "$(dirname "$0")"
mkdir -p .build/checks

# Build the module first, because the suites below cannot stand in for it.
#
# Each suite compiles an explicit file list, so a source file no suite happens to
# list is never compiled by check.sh at all — and thirteen of them were not,
# including every window, view and delegate the app draws itself with. That is
# not theoretical: a94fea4 records mediacheck going green while missing a file
# MediaManager had come to depend on, and NotchGestures.swift went its whole life
# uncompiled here, so a change to the recogniser's call site could only be caught
# by running swift build by hand. Building first means nothing reaches a suite
# without having compiled.
echo "==> swift build"
swift build

swiftc -O -parse-as-library tools/fluidcheck.swift \
  Sources/NotchApp/Audio/FerrofluidSim.swift \
  Sources/NotchApp/Audio/AudioLevels.swift \
  Sources/NotchApp/Audio/AudioTap.swift \
  -o .build/checks/fluidcheck
swiftc -O -parse-as-library tools/geometrycheck.swift \
  Sources/NotchApp/UI/FerrofluidView.swift \
  Sources/NotchApp/Notch/NotchShape.swift \
  Sources/NotchApp/Audio/FerrofluidSim.swift \
  Sources/NotchApp/Audio/AudioLevels.swift \
  Sources/NotchApp/Audio/AudioTap.swift \
  -o .build/checks/geometrycheck
swiftc -O -parse-as-library tools/gesturecheck.swift \
  Sources/NotchApp/Notch/SwipeRecogniser.swift \
  Sources/NotchApp/Support/ChromeRules.swift \
  -o .build/checks/gesturecheck
swiftc -O -parse-as-library tools/mediacheck.swift \
  Sources/NotchApp/Media/MediaManager.swift \
  Sources/NotchApp/Media/MediaBridge.swift \
  Sources/NotchApp/Media/SpotifyWeb.swift \
  Sources/NotchApp/Media/ScriptingBridgeProtocols.swift \
  Sources/NotchApp/Media/ArtworkPalette.swift \
  Sources/NotchApp/Support/Settings.swift \
  Sources/NotchApp/Notch/NotchShape.swift \
  -o .build/checks/mediacheck
swiftc -O -parse-as-library tools/librarycheck.swift tools/librarycheck-doubles.swift \
  Sources/NotchApp/Media/MediaManager.swift \
  Sources/NotchApp/Media/MediaBridge.swift \
  Sources/NotchApp/Media/ScriptingBridgeProtocols.swift \
  Sources/NotchApp/Media/ArtworkPalette.swift \
  Sources/NotchApp/Notch/NotchShape.swift \
  -o .build/checks/librarycheck
swiftc -O -parse-as-library tools/chromecheck.swift \
  Sources/NotchApp/Support/ChromeRules.swift \
  -o .build/checks/chromecheck
swiftc -O -parse-as-library tools/controllercheck.swift \
  Sources/NotchApp/Notch/NotchController.swift \
  Sources/NotchApp/Notch/ScreenMetrics.swift \
  Sources/NotchApp/Notch/NotchShape.swift \
  Sources/NotchApp/Notch/SwipeRecogniser.swift \
  Sources/NotchApp/Support/ChromeRules.swift \
  Sources/NotchApp/Support/Settings.swift \
  Sources/NotchApp/Support/Transition.swift \
  -o .build/checks/controllercheck
swiftc -O -parse-as-library tools/palettecheck.swift \
  Sources/NotchApp/Media/ArtworkPalette.swift \
  -o .build/checks/palettecheck

# Compilation uses the normal trusted toolchain. Execute every suite inside the
# same native boundary, including child processes and temporary mutation copies.
./tools/check-runtime /bin/bash <<'CHECK_RUNTIME'
set -e
/usr/bin/python3 -I tools/runtimecheck.py
.build/checks/gesturecheck
.build/checks/geometrycheck
.build/checks/fluidcheck
.build/checks/mediacheck
.build/checks/librarycheck
.build/checks/chromecheck
.build/checks/controllercheck
.build/checks/palettecheck

# The site's port of the fluid, against dumps from the Swift above. It belongs
# in this gate rather than in someone's memory: its whole job is to notice when
# the app moves out from under the page, and a check you have to remember to run
# by hand reports nothing on the day the app actually moves. Unconditional on
# purpose — a missing node must fail here, not quietly skip.
echo "==> site"
node site/test/portcheck.mjs
node site/test/bandscheck.mjs

# Prove the site's checks still reject their named regressions. The harness
# changes temporary copies only; stale mutation targets must fail this gate too.
echo "==> site mutations (results print after all runs)"
node site/test/mutate.mjs
CHECK_RUNTIME
