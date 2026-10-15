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

`./check.sh` first checks the shell scripts: `sh -n install.sh`, `bash -n` on the
build, deploy and check scripts, `plutil -lint` on the plists, and
`tools/installcheck.sh`, which runs `install.sh` against a fake release in a
throwaway folder (shimmed `curl`, `lsappinfo`, `open`; no network, no real
Applications folder). Its cases cover a good pin, a checksum mismatch, a
truncated download, a wrong bundle, a running copy and a failed launch;
`installcheck.sh --mutations` breaks temporary copies of the installer and
requires the matching case to fail. Every suite command gets `</dev/null`, so
none can swallow the script `check.sh` feeds the sandbox. After that it runs
eight app suites, two site suites and the site mutation harness. It builds
normally, then executes tests through the macOS sandbox. Home-directory
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

The app is ad-hoc signed, not notarised. `install.sh` is therefore the trust
anchor: it carries `PIN_VERSION` and `PIN_SHA256`, the fingerprint of the one
release it installs, so a swapped release zip cannot also swap its checksum. A
default install downloads that version only, checks it against the pin and
refuses a mismatch. Before copying anything it also checks the unpacked bundle:
identifier `com.laks.magnetite`, the expected version, an `arm64` slice and a
valid signature. `MAGNETITE_VERSION=<other>` falls back to the `.sha256` beside
that release and warns that this only catches a damaged download.

Ship a version in this order:

1. Bump `CFBundleShortVersionString`, then `./build.sh release --stage-release`.
   It builds, asserts `arm64` and the `LSMinimumSystemVersion` deployment target,
   checks Gatekeeper (exit 0, or 3 for an ad-hoc build, nothing else), stages
   `site/downloads/Magnetite-$VERSION.zip` and `.sha256`, and rewrites the two
   `PIN_` lines in `install.sh` through `tools/pin-installer.sh`. A staged
   version is immutable: different bytes for an existing version fail.
2. Run `./check.sh`, then commit `install.sh` and `site/downloads/` together.
3. Push to `origin/main`.
4. Create the release `v$VERSION` in `scryst/magnetite-releases` as a draft with
   the zip and the `.sha256`. Check that the zip asset's `digest` equals the
   pin (the tag route hides drafts, so list the releases):
   `gh api repos/scryst/magnetite-releases/releases --jq '.[] |
   select(.tag_name == "v$VERSION") | .assets[] | [.name, .digest]'` must show
   `sha256:$PIN_SHA256` for the zip. Then publish it; releases are
   immutable once published.
5. `./deploy.sh`. It refuses unless HEAD is an ancestor of, or equal to,
   `origin/main` (after `git fetch origin main`), the release exists and is not a
   draft, and its zip digest equals both the committed zip and the pin in
   `install.sh` at HEAD. It then publishes `git archive` of the committed
   `site/`, with `install.sh` from git, and polls the live page and installer
   with a `?v=<commit>` cache-buster for up to three minutes.

`./deploy.sh --dry-run` runs the same checks and stages a payload without
publishing; a failed push or release check is a warning there, an error in a
real run. Use the wrapper rather than pointing a host at the working tree: it
excludes tests, the local server and verification ZIP. An interrupt exits with
130 and cleans up through a separate `EXIT` trap.

Normal builds do not touch the tracked release copy or `install.sh`. GitHub
Releases is the binary download authority. Source, tests, rendered proof and
deployment are separate.

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
