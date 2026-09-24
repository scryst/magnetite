# Magnetite — the app

A macOS notch music player targeting **macOS 26+** so it can use real Liquid
Glass rather than a hand-rolled material.

```bash
./build.sh release        # builds the app and ZIP under build.noindex/
open build.noindex/Magnetite.app
```

Command Line Tools only — no Xcode, no `xcodebuild`. SwiftPM produces the binary
and `build.sh` assembles the bundle around it.

Release staging is deliberately separate. After bumping the bundle version,
`./build.sh release --stage-release` copies the verified ZIP into
`site/downloads/`; it refuses to replace different bytes under an existing
version.

## Design thesis

The notch is not an obstacle to work around; it is the **origin** the panel grows
from.

- **One shell that wraps the cutout.** Artwork sits in the flank to the left of
  the camera, the elapsed clock in the flank to the right, and the player body
  below. The menu bar either side stays readable.
- **The band around the camera is pure black.** Album colour is masked by a
  *radial* falloff centred on the cutout, so the housing sits in black and the
  colour blooms outward. Colour immediately beside the housing is precisely what
  makes it read as a foreign black bar.
- **Progress traces the shell's own bottom edge.** The panel is its own scrubber,
  so no vertical space is spent on a track. The unplayed remainder is that same
  edge at lower alpha, drawn under the fill — without it the line simply stopped
  where the song had got to, and at the start of a track the playhead sat on a
  bare corner as a detached speck. Retracted, the line is sized to the sliver
  between band and cutout rather than drawn at its expanded width and pushed
  down until the top clears, which left a point and a half of it on the window
  chrome below the menu bar.
- **The silhouette is one line, drawn by two things.** The progress track owns
  the bottom edge and both corners; the rim owns the sides and the top above
  them, at one flat value, so the outline does not change strength where they
  meet. The rim used to be a top-lit highlight — brightest along the display's
  top row, where the panel abuts the bezel and separates from nothing, dimmest
  across the sides — which left the right edge unlocatable against a dark window
  title bar while it stayed obvious against the light desktop below. An edge
  that exists only where the backdrop is brighter is the backdrop's edge.
- **The sleeve's edge is the tile's own thickness.** An opaque bevel and the
  line it shadows onto the print, both inside the artwork's footprint. It was a
  white hairline drawn ON the cover, and a stroke with alpha over an image takes
  its contrast from the image: invisible on a pale sleeve, a hard bright seam on
  a black one. The tile's edge is not the album's to decide.
- **The window never resizes.** It is created once at full size; every morph is
  SwiftUI interpolating the shape inside it. Resizing an `NSWindow` per frame is
  the main source of jank in notch apps.
- **Retracted, it still reads as a player**: artwork in the left flank, the
  elapsed clock in the right, camera between them, colour flowing around both —
  all inside the cutout's own height.
- **Un-hovered, it never leaves the menu bar.** Peeks and HUDs widen *within* the
  cutout's own height, using the flanks either side of the camera. Anything
  hanging below the band sits on browser tabs and window chrome — exactly where
  people's hands are.
- **Straight sides.** The shell drops vertically from the display edge. An
  earlier concave top fillet flared outward and read as the panel splaying at the
  shoulders.
- **Progress is always drawn**, tracing whichever silhouette is current, so it
  morphs with the shape instead of fading in every time the panel opens. Hovering
  the bottom edge reveals a playhead knob; dragging scrubs, and the clocks follow
  the drag so you can land on a specific second.

## Measuring the notch

```bash
tools/notchruler                          # print metrics for every display
tools/notchruler --overlay                # draw guides on screen for 20s
tools/notchruler --overlay --seconds 60
```

Pink = cutout edges, cyan = the menu-bar band, ticks every 10pt. The overlay is
click-through, so it never blocks what's underneath. On this machine:

```
NOTCH   x=663.5  y=950.0  w=185.0  h=32.0      (370 × 64 px @2x)
        left x=663.5   right x=848.5
        screen midX=756.0   notch midX=756.0   (centred)
```

## Interaction

**Hover** opens the panel; **the menu command and `magnetite://toggle` pin it**, so a
deliberate open stays until it is toggled again or you click away. Without the pin
a toggle undid itself: the pointer is at the menu, i.e. outside the notch, so the
mouse-exit path collapsed it 850ms later.

**Two-finger swipes** over the notch skip tracks (horizontal) and toggle playback
(vertical), with an alignment haptic on fire. Deltas are normalised to *device*
direction, because `scrollingDeltaX` already has the user's natural-scrolling
preference baked in and the same physical movement otherwise produces opposite
signs on two machines. Momentum events are ignored outright — macOS keeps sending
large deltas after the fingers lift, and re-arming on `.ended` made one swipe skip
several tracks.

Retracted, the panel is `ignoresMouseEvents`, so only a *global* monitor sees a
scroll over it — and a global monitor cannot consume the event. A swipe therefore
also reaches whatever is beneath. Over the menu bar that is almost always nothing,
and the alternative, making the retracted notch opaque to the mouse, costs more
than it buys.

## Getting out of the way

The notch hides itself on screen lock, screensaver, and when a display's menu-bar
band is gone — i.e. a fullscreen app. There is no preference for it: a setting for
something the app can simply know is a setting nobody should have to find.

Hidden means **ordered out**, not faded. A transparent panel still hover-expands
and still hit-tests, which put an invisible 344×122 click-eater at the top of
fullscreen video.

Two deliberate limits. **Fullscreen is evaluated per display**, because putting a
video fullscreen on one monitor is not a reason to uncover the camera cutout on
another. And with *Automatically hide and show the menu bar* enabled the geometric
signal cannot distinguish fullscreen from the desktop, so it is not used rather
than guessed at. **Mission Control is not handled**: there is no robust public
signal for it, and the only known route is tailing the unified log, whose format
is not something to build on across releases.

## Checks

`./check.sh` runs the Swift suites below with no display attached, which matters —
the screen slept partway through more than one verification session — and then
two Node suites over the marketing site, followed by their mutation harness.

Compilation uses the normal toolchain. Test execution uses `tools/check-runtime`
to restrict home-directory reads, block preference/credential services, Apple
Events and all network access, and use private temporary writes. Run compiled suites
through that launcher too; a direct binary launch bypasses the boundary. See
the README's Checks section for the focused isolation check and platform limits.

- `fluidcheck` — the drive measures change not loudness, the surface is not a comb,
  silence is genuinely still, bands drain at different rates, a skip leans the way
  it went, the ink washes in behind the shell, the halo fades rather than switching,
  and nothing clears the settled gate without leaving something to recompute it.
  It also replays 240 frames of REAL captured levels (`Resources/real-levels.txt`),
  because constructed spectra miss the case that matters most — sustained music,
  where a saturated body lift flattens the crowns into a wall.
- `geometrycheck` — where the lobes sit on the silhouette and how far it may travel:
  the sides move at all, the crown walks with frequency, the lobes resolve without
  spiking, the ink leaves the bezel on a curve, and the outline never turns more
  than 40 degrees in one sample. Containment is asserted at eleven values of
  openness, including retracted.
- `chromecheck` — the retracted shell never leaves the menu-bar band, the panel is
  as tall as what it lays out, the trace clears the camera cutout and is sized to
  the sliver it actually has rather than inset out of trouble, the unplayed track
  runs the whole edge at the fill's own width and inset and stays under it, the
  title is never blank, and animation curves come from `Motion` rather than being
  written inline.
- `mediacheck` — skip directions expire and are taken once, optimistic holds release
  when the player agrees and when the track changes, an unanswerable control is
  never drawn. It drives a real `MediaManager` with an INERT bridge, so it cannot
  command a live player.
- `librarycheck` — delayed Spotify membership answers remain with the requesting
  player and track. It controls the provider response, disables live observation,
  and awaits the actual library task before checking accepted or rejected results.
  Settings and account access are doubled; real inert reads and artwork are checked.
- `palettecheck` — no cover can outshine the type, the fallback describes its own
  colours, a monochrome cover gets its own palette.
- `gesturecheck` — direction, axis dominance, drift rejection, one swipe one gesture.

- `controllercheck` — the per-display state machine, which is the one part of the
  app that is pure state and went uncovered longest on the assumption that
  anything importing AppKit needs a running app to drive it. Hiding forgets where
  the pointer was, a hidden notch cannot be opened, hiding closes what is open,
  the expansion callback fires only on real transitions, the menu toggle stays
  open until toggled back, a HUD never lands behind the open panel or reports
  more than full, the peek turns on and off, every stored setting survives the
  rename, and the URL scheme the app answers is the one it registered.

- `portcheck` — the marketing site's port of the simulation, geometry, camera and
  palette against goldens dumped from the Swift by `site/test/portprobe.swift`,
  plus the claims the page prints: the macOS floor against `Package.swift`, the
  download link against the build on disk, its version against `Info.plist`, its
  size, and the hardware every download button asks for against `ScreenMetrics`
  — the button gates are written for N buttons and currently hold at one. The
  gates about wiring rather than about numbers: the frame loop cannot be started
  twice, the entrance animation fires only when the capture actually lands, and
  the Reduce Motion still is a painted frame of the fluid rather than the
  resting outline — an unopened simulation renders as the retracted band, and a
  blank panel passes every numeric assertion ever written about it.
  It also executes the page's three WebMCP discovery tools, holds them to the
  current `document.modelContext` surface, and proves they register once without
  crossing the human-only download, install, launch, or native-control boundary.

- `bandscheck` — the browser AudioWorklet's ring, FFT, twelve-band partition and
  silence decay against golden rows emitted by the real `AudioTap` over sixteen
  committed PCM fixtures. The optional two-track soundtrack uses this path to
  drive the page's existing ferrofluid simulation live.

The site's `mutate` harness runs last in `./check.sh`, proving each named check
rejects its deliberate regressions while accepting valid alternatives. It changes
temporary copies only and fails the gate for stale targets as well as failed
expectations.

For app changes, reproduce the defect before accepting the new check. The
focused library-response comparison reverts the ownership guard to prove its
stale-answer cases fail; it does not claim an independent mutation for every
assertion. The site mutation coverage is supplied by the harness above.

## Ferrofluid visualiser

The black mass around the cutout is **one continuous outline**, displaced along
its own normal: bass heaves the whole surface, and each of twelve frequency bands
raises a smooth mound where its site sits on the rim. There are no spikes, no
cones and no particles — the expression is entirely in how the outline itself
swells and settles, which is what a magnet under a shallow pool looks like before
the field is strong enough to break it.

The layer is blurred and run through `alphaThreshold`, which is what makes the
edge read as a surface with tension rather than a drawn curve. The camera
guarantee — a rounded rect covering the cutout — is drawn **crisp and outside
that chain**: inside it the blur erodes convex corners before the threshold
restores them, which at zero margin let panel colour through the cutout's bottom
corners.

Zero margin is deliberate. The resting ink *is* the cutout, so colour begins on
the line the housing ends on. Retracted, the ink layer is clipped to the menu-bar
band and only the sideways component of the warp is allowed, because that space
belongs to browser tabs and window chrome.

The drive is a **per-band z-score** against a 2.5s baseline, not the raw level.
Music sits at 0.5–0.8 forever, so keying off absolute loudness pinned every site
above threshold permanently — measured at 16 of 17 — and froze the surface into a
static wall no rendering change could revive.

A track change calls `surge()`, which injects a transient the same way a drum hit
does. Only the trigger is scripted; the motion that follows is the ordinary
physics.

## The colour field

Built from the cover's palette as two counter-rotating `MeshGradient` layers at
60fps, with a slow intensity breath on top. Two details make it work:

- **Guaranteed hue spread.** A near-monochrome cover extracts four nearly
  identical colours, and a gradient built from those has nothing to animate
  *between* — the field moves but you can't see it. `ArtworkPalette.spread`
  fans hue and brightness apart where the source doesn't supply enough variation.
- **Black across the cutout band only.** The notch is a hole in the display;
  nothing can be drawn there, so the only way to hide it is for its band to be
  black — which also matches the menu bar either side. A radial halo *around*
  the housing (tried, discarded) makes it more obvious, not less.

Measured frame-to-frame delta went from ~1.0/255 (invisible) to 2.1–5.1 per
0.35s after the spread fix.

## Control

```bash
open "magnetite://expand"     # also: toggle, collapse
```

Plus a menu-bar item for feature toggles and music-source selection.

## What's wired

| Area | State |
|---|---|
| Now playing (Spotify + Apple Music) | ScriptingBridge, off-main-actor with send timeout |
| Artwork + palette | Spotify URL fetch / Music `artworks()`; hue-bucketed palette → mesh glow |
| Transport | play/pause, next, previous, seek — optimistic UI |
| Volume HUD | CoreAudio property listener; **no permission required** |
| Brightness HUD | private `DisplayServices` via `dlsym`, read-only, fail-soft |
| Ferrofluid | CoreAudio process tap → vDSP FFT → 12 bands; one continuous reservoir warped by a metaball pass |
| Library | favourite through Music scripting or a connected Spotify Web API account; shuffle, repeat, and open the track in its player |
| Swipe gestures | two-finger skip and play/pause from an `NSEvent` scroll monitor, with haptics |
| Multi-display | one controller + panel per screen, keyed by display UUID |
| Hover / peek / HUD | generation-guarded cancellable transitions |

Spotify library state is unavailable through local ScriptingBridge. A connected
Spotify Web API account supplies library membership and save/remove operations
through `SpotifyWeb`. `MediaManager` checks delayed membership reads against the
current query generation, player and track before displaying the result. Spotify
library features require that Web API connection.

## Not built

Stage 7 of the blueprint — the `com.apple.controlcenter.*` XPC helper for
system-wide MediaRemote — is deliberately absent. It's the most fragile piece and
unnecessary while Spotify and Music work over ScriptingBridge.

Also absent: media-key interception (needs Accessibility), calendar/battery/AirPods
activities, and a settings window — everything is on the menu-bar menu.

The bar meter is absent **deliberately**. It was a mirrored equaliser, which is
the first entry in PRODUCT.md's anti-references, and it sat beside the ferrofluid
answering the same question worse. The design principle is explicit: controls stay
familiar while the ferrofluid earns the spectacle.

## Hard-won notes

- `@State` is a macro in the macOS 26 SDK and its plugin ships with Xcode, not
  CLT. `Support/ViewState.swift` is a drop-in replacement. `@Namespace`,
  `@Environment`, `@Binding`, `@AppStorage` are unaffected.
- `SBApplication` must be **declared** to conform to your ScriptingBridge
  protocol or `as?` silently returns nil and the whole media pipeline goes dark.
- Spotify returns `duration` as `Int` milliseconds, Music as `Double` seconds,
  under the same selector — read it via KVC and normalise per source.
- A `GeometryReader` has no ideal width; inside an `HStack` it gets zero and
  vanishes. `MarqueeText` lays out as ordinary text for exactly this reason.
- Don't run another notch utility alongside this one. They tend to sit at window
  layer ~2147483629 and will paint straight over Magnetite, which makes for
  spectacularly confusing debugging.
