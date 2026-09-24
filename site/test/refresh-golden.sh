#!/bin/bash
# Regenerates site/test/golden from the REAL Swift sim and geometry.
#
# Run this whenever the app's physics or outline moves. A diff in the golden
# files is the app changing under the website, which is exactly the signal worth
# having — the site claims every moving mark on it is one instance of the
# shipping simulation, and this is what keeps that true.
set -e
cd "$(dirname "$0")/../.."
mkdir -p .build/checks

swiftc -O -parse-as-library site/test/portprobe.swift \
  Sources/NotchApp/UI/FerrofluidView.swift \
  Sources/NotchApp/Notch/NotchShape.swift \
  Sources/NotchApp/Audio/FerrofluidSim.swift \
  Sources/NotchApp/Audio/AudioLevels.swift \
  Sources/NotchApp/Audio/AudioTap.swift \
  -o .build/checks/portprobe

# `sim-held` is the app's OWN cadence — every captured frame stepped twice,
# because the render clock is 60Hz and AudioLevels republishes at 30. It is a
# separate mode from `sim` and not a variant of it: a port can agree on 240
# changing frames and disagree the first time a frame repeats, which is the
# defect theReplayIsSteppedLikeTheApp exists to catch. It was missing from this
# list while its golden existed, so that file was hand-made once and nothing
# here would ever have noticed it going stale — a golden outside this loop is a
# gate that quietly stops tracking the app.
for mode in sim sim-held surge-forward surge-back open pointer geom; do
  .build/checks/portprobe "$mode" > "site/test/golden/$mode.txt"
  echo "  $mode -> $(wc -l < "site/test/golden/$mode.txt" | tr -d ' ') lines"
done

# The analyser the playlist port answers to: the real tap DSP over the
# committed PCM fixtures. Regenerate the fixtures themselves only deliberately
# (gen-fixtures.mjs) — they are canon, and rewriting them rewrites these too.
swiftc -O -parse-as-library site/test/bandsprobe.swift \
  Sources/NotchApp/Audio/AudioTap.swift \
  -o .build/checks/bandsprobe

for fixture in site/test/fixtures/*.f32; do
  name="$(basename "$fixture" .f32)"
  .build/checks/bandsprobe "$fixture" > "site/test/golden/bands-$name.txt"
  echo "  bands-$name -> $(wc -l < "site/test/golden/bands-$name.txt" | tr -d ' ') lines"
done

# The captured audio the site replays comes from the app's own resource.
node site/test/gen-levels.mjs
