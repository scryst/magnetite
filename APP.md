# How the app is built

Magnetite targets macOS 26 or later so it can use the system's Liquid Glass
material. It builds with the Command Line Tools alone: SwiftPM produces the
binary and `build.sh` wraps it in an app bundle.

```bash
./build.sh release        # app and ZIP under build.noindex/
open build.noindex/Magnetite.app
```

Testing and releases are covered in [docs/ENGINEERING.md](docs/ENGINEERING.md).
Design rules are in [PRODUCT.md](PRODUCT.md).

## Layout

- **One shell around the cutout.** Artwork sits to the left of the camera, the
  elapsed time to the right, and the player body below. The band level with
  the camera is pure black, so the housing disappears into it.
- **The window never resizes.** It is created once at full size and every
  change of shape is SwiftUI animating the path inside it. Resizing an
  `NSWindow` every frame causes visible stutter.
- **Progress runs along the bottom edge.** The edge is the scrubber: hover it
  to show the playhead, drag to seek, and the clocks follow the drag.
- **Closed, it stays in the menu bar.** The mini player (on by default) shows
  the cover and elapsed time beside the camera, within the notch's height. With
  it off, the closed notch is exactly the camera cutout.
- **The cover is the tile.** Rounded corners, no ring or matte.

## Interaction

- **Hover** opens the panel. The menu command and `magnetite://toggle` open it
  pinned, so it stays until toggled again or you click elsewhere. With Open on
  Hover off, a click on the notch opens it.
- **Two-finger swipes** skip tracks (sideways) and play or pause (up or down).
  Deltas are normalised to the device direction, because `scrollingDeltaX`
  already includes the natural-scrolling preference. Momentum events are
  ignored so one swipe is one action.
- Closed, the panel ignores mouse events, so swipes are read by a global
  monitor, which cannot consume them. Over the menu bar there is almost never
  anything underneath.

## Getting out of the way

The notch hides on screen lock, the screensaver, and when a display's menu bar
is gone (a fullscreen app). Hidden means ordered out, not transparent, so it
cannot catch clicks. Fullscreen is judged per display. With "Automatically hide
and show the menu bar" turned on, fullscreen can't be detected reliably, so it
isn't attempted. Mission Control has no public signal and is not handled.

## Ferrofluid

The black shape around the cutout is one outline displaced along its normal.
Bass lifts the whole surface; each of twelve frequency bands raises a mound at
its own point on the rim. The layer is blurred and passed through
`alphaThreshold`, which gives the edge surface tension. The rectangle covering
the camera is drawn outside that chain so the blur can never expose its
corners.

Each band is driven by its change against a 2.5-second baseline rather than its
loudness, so sustained music keeps moving instead of pinning every band high. A
track change injects one transient, and the ordinary physics does the rest.

## Colour

The background is two counter-rotating `MeshGradient` layers built from the
cover's palette. `ArtworkPalette.spread` widens hue and brightness for
near-monochrome covers, otherwise the gradient has nothing to move between.
The band beside the camera stays black.

## Control

```bash
open "magnetite://expand"     # also: toggle, collapse
```

Settings and the music source are in the **M** menu-bar item.

## What's wired

| Area | How |
|---|---|
| Now playing (Spotify, Apple Music) | ScriptingBridge, off the main actor, with a send timeout |
| Artwork and palette | Spotify artwork URL or Music `artworks()`; hue-bucketed palette |
| Transport | Play, pause, next, previous, seek, with optimistic UI |
| Volume HUD | CoreAudio property listener; no permission needed |
| Brightness HUD | Private `DisplayServices` via `dlsym`, read-only, fails quietly |
| Ferrofluid | CoreAudio process tap → vDSP FFT → twelve bands |
| Library | Favourites through Music, or through a connected Spotify Web API app; shuffle and repeat |
| Artists | Each credited artist opens in Spotify or Music; unresolved names open a search |
| Multiple displays | One controller and panel per screen, keyed by display UUID |

Spotify's liked songs, shuffle and repeat state aren't available through
ScriptingBridge, so those need a Spotify Web API connection. Apple Music
credits are split on commas, a spaced `&` and `feat.`; a band name containing
those can't be told apart from a collaboration.

## Not included

- System-wide MediaRemote through a Control Center XPC helper. It is fragile
  and unnecessary while Spotify and Music work over ScriptingBridge.
- Media-key interception (needs Accessibility), calendar, battery and AirPods
  activities, and a settings window. Everything lives in the menu.
- An equaliser meter. It would compete with the ferrofluid and break the first
  rule in [PRODUCT.md](PRODUCT.md).

## Notes for contributors

- `@State` is a macro in the macOS 26 SDK whose plugin ships with Xcode, not the
  Command Line Tools. `Support/ViewState.swift` replaces it. `@Namespace`,
  `@Environment`, `@Binding` and `@AppStorage` work as normal.
- `SBApplication` must be declared to conform to your ScriptingBridge protocol,
  or `as?` quietly returns nil.
- Spotify returns `duration` as `Int` milliseconds and Music as `Double`
  seconds under the same selector. Read it through KVC and normalise.
- A `GeometryReader` has no ideal width, so inside an `HStack` it collapses to
  zero. `MarqueeText` lays out as ordinary text for that reason.
- Other notch utilities draw at a very high window level and will paint over
  Magnetite. Quit them while debugging.
- `tools/notchruler` prints each display's notch metrics; `--overlay` draws
  guides on screen for 20 seconds.
