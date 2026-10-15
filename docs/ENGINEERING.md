# Engineering and release notes

The user-facing overview is in [README.md](../README.md). [APP.md](../APP.md)
explains the native app's geometry, physics, lifecycle and design decisions.

## Build and verification

SwiftPM builds against the Command Line Tools, without an Xcode project.

```sh
./build.sh release
./check.sh
./tools/check-runtime .build/checks/mediacheck
./tools/check-runtime /usr/bin/python3 -I tools/runtimecheck.py
```

`./check.sh` runs eight app suites, two site suites and the site mutation harness.
It builds normally, then executes tests through the macOS sandbox. Home-directory
contents outside the checkout and selected Node executable, credential and
preference services, Apple Events and network access are blocked. Toolchain and
system reads remain available; external-volume reads are not restricted by this
boundary. Repository inputs are read-only; temporary copies hold mutations and
preference fallbacks. Provider tokens and interpreter options are not inherited.
Setup failure stops the gate. Catchable cancellation stops its process group;
an uncatchable kill or host crash can leave private temporary files behind.

Launching compiled suites directly bypasses that boundary. This requires macOS
`sandbox-exec`, Command Line Tools' Python 3 and Node.js. The sandbox complements
inert test doubles; it does not prove live player behavior.

| Suite | What it checks |
| --- | --- |
| `fluidcheck` | Physics, real captured audio and silence settling |
| `geometrycheck` | Notch and panel outline at every margin |
| `gesturecheck` | Swipe decisions and one gesture per swipe |
| `mediacheck` | Media rules, retries and transitions through an inert bridge |
| `librarycheck` | Delayed Spotify answers retain their player/track ownership |
| `chromecheck` | Layout, type, controls and marquee |
| `controllercheck` | Window lifecycle, hover, pinning and visibility |
| `palettecheck` | Artwork palette contrast against the app's own type |
| `portcheck` | Site simulation, layout contracts, media, discovery and release claims |
| `bandscheck` | Browser audio analyser against real Swift tap dumps |
| `mutate` | Named site checks reject regressions and accept valid alternatives |

For site-only iteration:

```sh
node site/test/portcheck.mjs
node site/test/bandscheck.mjs
node site/test/mutate.mjs
python3 site/serve.py 4173
```

Review actual browser output at desktop and phone widths. Headless checks cannot
prove readability, footage quality, audio timing or physical notch alignment.

## Release mechanics

`./deploy.sh --dry-run` verifies the committed site and stages a payload without
publishing. `./deploy.sh` publishes it. Use the wrapper rather than pointing a
host at the working tree: it uses `git archive`, excludes tests, the local server
and verification ZIP, and checks that the committed page reaches production.

Normal builds do not touch the tracked release copy. After a version bump,
`./build.sh release --stage-release` stages `site/downloads/` and refuses to
replace an existing version with different bytes. GitHub Releases is the binary
download authority. Source, tests, rendered proof and deployment are separate.

`magnetite://toggle`, `magnetite://expand` and `magnetite://collapse` control the
native UI for verification. Use them only when the user's playback/UI state can
be preserved and restored.

## Lessons from measurement

- Absolute audio levels pinned 16 of 17 peaks. The visualiser now measures
  per-band change against a 2.5-second baseline.
- A half-filled FFT block leaked bass into every band. A ring buffer supplies
  a full Hann window.
- Observation invalidates on assignment, not only on change. Rewriting settled
  state 60 times a second defeated paused rendering.
- Artwork could outshine its own text; a monochrome cover inherited the previous
  track's colour. Contrast and fallback-palette checks cover both cases.

## Naming and migrations

Magnetite is the mineral in ferrofluid. The SwiftPM module remains `NotchApp`
and the `Notch*` types name the surface; renaming them would churn check paths
without changing the product. `build.sh` names the bundle executable Magnetite.
`Ferrofluid*` names the physical phenomenon, not an old product brand.

Keep both migrations: preferences moved `com.laks.NotchApp` → `com.laks.ferro`
→ `com.laks.magnetite`; the Application Support directory moved `NotchApp` →
`Ferro` → `Magnetite`. Old names are read newest-first because users may arrive
from either. The URL scheme deliberately retains no old alias, avoiding two
installed apps claiming the same global registration.
