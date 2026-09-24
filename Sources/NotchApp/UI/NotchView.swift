import SwiftUI
import AppKit

/// One grid for the whole surface.
///
/// Everything — content beside the cutout and content below it — is measured from
/// these, so the elapsed clock's left edge is the artwork's left edge and the
/// remaining clock's right edge is the artist's right edge. Previously the flanks
/// were centred in their own space while the body used its own padding, and
/// nothing lined up with anything.
///
/// The three that decide the panel's HEIGHT live in `ChromeRules` and are
/// re-exported here, because `chromecheck` compiles against that file alone and a
/// check written against copies of these numbers cannot fail.
enum Grid {
    static let margin = ChromeRules.margin
    static let gutter: CGFloat = 12
    static let art = ChromeRules.art
    static let title = ChromeRules.titleLine
    static let artist = ChromeRules.artistLine
    /// Previous and next.
    static let controls = ChromeRules.controlDiameter
    /// Play/pause. The one control you reach for, and the only one that should
    /// look like it — three identical discs read as three equal things.
    static let primary = ChromeRules.primaryDiameter
    /// Shuffle and repeat: modes, not transport, so they sit smaller and outside
    /// the group — now literally outside it, on the right margin.
    static let mode = ChromeRules.modeDiameter
    /// The artwork fills its row exactly, so it is square without being centred
    /// in a taller box.
    ///
    /// It used to be 8pt shorter than the row: at 62 wide it reached x=78 and
    /// the panel-centred control row's first disc landed at 78.5 — touching. A
    /// five-control row started at 94.5 instead, so the sleeve could have the
    /// row's full height and still leave 8.5pt of air. A three-control row
    /// starts at 136.5, and the sleeve took 20 of the 44 that freed.
    static let artwork: CGFloat = ChromeRules.art

    /// Gap between the cutout band and the body.
    ///
    /// Sized to the ink's actual reach. With no spikes the mass only extends
    /// about 13pt past the cutout, so most of the old 46pt was reserving room for
    /// something that no longer exists — which is what made the top bar read as
    /// so tall when expanded.
    ///
    /// Must clear the ferrofluid's reach, not just the cutout's, or the band ends
    /// up half on colour and half on black fluid. Lives in `ChromeRules` with the
    /// rest of the vertical budget.
    static let bandGap = ChromeRules.bandGap
    static let bottom = ChromeRules.bottom
}

struct NotchRootView: View {

    var controller: NotchController
    var media: MediaManager
    var fluid: FerrofluidSim

    @Namespace private var glass
    @ViewState private var scrubbing = false
    @ViewState private var scrubFraction: CGFloat = 0
    @ViewState private var seekHovering = false

    /// What the trace and the clocks should show: the drag position while
    /// scrubbing, otherwise real playback. Without this the times keep counting
    /// the old position and you can't drag to a specific second.
    private var shownFraction: Double {
        scrubbing ? Double(scrubFraction) : (media.skipTrace ?? media.smoothProgress)
    }
    private var shownPosition: Double {
        scrubbing ? Double(scrubFraction) * media.duration : media.smoothPosition
    }

    private var size: CGSize { controller.currentSize }
    private var expanded: Bool { controller.isExpanded }
    private var band: CGFloat { controller.notchSize.height }

    var body: some View {
        ZStack(alignment: .top) {
            chrome
            // Content only. The chrome, the trace and the playhead are the
            // silhouette — they claim to be hardware and must not move; the
            // sheet inside is what leans, and the clip is what keeps its edge
            // travel under the shell rather than past it.
            // The ZStack is not decoration: it is the container `content`'s
            // transitions need to exist in.
            //
            // `content` is one `if`/`else if` chain, and handed straight to
            // `SwipeLeanFrame` it became the ROOT of that view's body. A
            // conditional at a body's root has nothing to be inserted into or
            // removed from, so SwiftUI swaps the body instead of running a
            // removal — and the swap is one-sided: the arriving branch still
            // gets its insertion transition, the leaving one gets nothing. That
            // is exactly what the panel did. Filmed at 60fps, the expanded
            // player's contents vanished between two consecutive frames with no
            // intermediate opacity while the shell was still at full width,
            // leaving an empty gradient box for four frames before the shape
            // began to shrink — the open crossfaded correctly the whole time,
            // which is what made it read as a bad curve rather than a missing
            // container. Measured, not reasoned: a `Color` carrying the same
            // transition faded correctly one level up in this same ZStack while
            // the player cut, and started fading only once it was moved in
            // here beside `content`.
            SwipeLeanFrame(controller: controller, expanded: expanded) {
                ZStack(alignment: .top) { content }
            }
                .frame(width: size.width, height: size.height, alignment: .top)
                .clipShape(shape)
            // Always drawn when there's a track. Gating it on `expanded` meant it
            // faded in every time the panel opened; tracing the collapsed shape's
            // bottom edge too makes it a continuous element that simply follows
            // the silhouette as it morphs.
            // The trace needs a shell wide enough to carry it. In Focus Mode the
            // retracted shell is exactly the cutout, so the line ran behind the
            // camera housing and surfaced as a short stub with a curl on one end
            // — it read as a rendering fault rather than as progress. Draw it
            // only where there is something to draw it along.
            if trackDrawn {
                // Outside the timeline below, and before it: the unplayed
                // remainder is the same shape at every instant of the song, so
                // re-stroking it fifteen times a second would buy nothing, and
                // drawing it first is what puts it behind the fill.
                progressTrack
                // Display-rate so the trace glides instead of stepping with the
                // 1Hz poll.
                // 15Hz, not 60. The trace advances size.width / duration: on a
                // four-minute track that is 1.43pt/s, i.e. 0.024pt per frame at
                // 60Hz against a 0.5pt device pixel — 21 frames to move one
                // pixel. At 15Hz a one-minute track still advances 0.38pt per
                // frame, under a pixel, so it stays sub-pixel smooth while the
                // stroke and its radius-6 shadow are re-blurred a quarter as
                // often.
                TimelineView(.animation(minimumInterval: 1.0 / 15.0,
                                        paused: !media.isPlaying || scrubbing)) { _ in
                    // The tip belongs INSIDE this timeline, with the line it sits
                    // on. It was outside, so it only moved when the body happened
                    // to re-evaluate — which is the 1Hz media poll — and the dot
                    // stepped once a second along a line that was gliding.
                    ZStack {
                        progressEdge
                        playhead
                    }
                }
            }
            // The tip is not gated on expansion: gating it meant the dot still
            // faded in and out on every open, which is the same defect the
            // resting-width fix removed from hover. Width carries the state —
            // the trace's own retracted, swelling on hover and grab once there
            // is a panel to swell into — so it grows out of the line rather than
            // arriving on it. The seek strip stays gated so a collapsed notch is
            // never a drag target.
            // And gated on a duration, because `seek(toFraction:)` is: it guards
            // on `duration > 0` and returns. Offered without one — a live
            // stream, a radio station, a track whose length has not arrived yet —
            // the strip is a full-width drag target that does nothing, and it
            // publishes an adjustable "Playback Position" to VoiceOver that also
            // does nothing. A control that renders must do something, and through
            // the accessibility API the control is the only thing there is.
            if expanded, media.hasTrack, media.duration > 0 { seekStrip }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(expanded ? Motion.expand : Motion.collapse, value: expanded)
        .animation(Motion.swap, value: controller.liveActivity)
        .animation(Motion.swap, value: controller.notification)
        .animation(Motion.track, value: media.trackToken)
        // Losing the last track was a hard cut: nothing watched hasTrack, so the
        // idle card replaced the player between frames. Arrival agrees with the
        // track curve above; departure is fully damped, which is what something
        // going away should have.
        .animation(media.hasTrack ? Motion.track : Motion.collapse, value: media.hasTrack)
        .opacity(controller.isVisible ? 1 : 0)
    }

    /// Is the progress line drawing the bottom edge right now? The rim reads
    /// this to know whether that edge is already someone else's. One condition
    /// in one place, for the same reason `traceWidth` and `traceInset` are
    /// single-sourced: a rim and a track that disagree about who owns the bottom
    /// either double it or leave it bare.
    private var trackDrawn: Bool { media.hasTrack && hasShellForTrace }

    /// Is the shell wider than the bare cutout right now?
    private var hasShellForTrace: Bool {
        expanded || controller.liveActivity.isSome || controller.notification.isSome
    }

    private var shape: NotchShape {
        NotchShape(width: size.width,
                   height: size.height,
                   topCornerRadius: controller.topCornerRadius,
                   bottomCornerRadius: controller.bottomCornerRadius,
                   style: controller.style)
    }

    /// The song's colour, used to tint the glass.
    private var tint: Color { media.palette.colors.first ?? .accentColor }


    // MARK: Chrome

    /// Black at the cutout, tinted Liquid Glass everywhere else.
    ///
    /// The shell really is glass — it picks up the desktop behind it and carries
    /// the current track's colour. The one place it must not is the band around
    /// the camera housing: glass there would catch the wallpaper either side of
    /// the bezel and expose the housing as a black bar sitting on top of it. So a
    /// radial falloff keeps a black core at the cutout and lets the glass bloom
    /// outward from it.
    private var chrome: some View {
        ZStack(alignment: .top) {
            shape.fill(.black)

            // IMPORTANT: this explicit frame establishes the coordinate space the
            // masks resolve in. Without it the oversized `coverWash` frame becomes
            // the reference, and the bloom's centre — expressed as a fraction of
            // the panel height — lands far above the cutout.
            glassLayer
                .frame(width: size.width, height: size.height)
                .allowsHitTesting(false)

            FerrofluidView(sim: fluid,
                           notchSize: controller.notchSize,
                           panelSize: size,
                           openness: expanded ? 1 : 0,
                           reduceMotion: Motion.reduceMotion,
                           cornerRadius: controller.cutoutCornerRadius,
                           tint: tint)
                .clipShape(shape)
        }
        .overlay(alignment: .top) {
            // The rim also acknowledges the pointer. Hover opens after
            // `hoverDuration` (0.18s by default), and for that whole time the
            // notch gave back nothing at all — the one interaction that starts
            // every session had no "I saw that". A faint edge light is enough to
            // say the target is live without pre-empting the open.
            // The rim draws the silhouette the track does not. Slice 1 gave the
            // bottom edge and both corners to a full-length line, so the rim's
            // own bottom stop had nothing left to close: it composited under the
            // track and hung a quarter point past the silhouette, fattening the
            // one boundary the track had just been inset to land on exactly. It
            // is out by the bottom edge now, and back only for the idle card,
            // which has no track to close it. Retracted it stays out either way —
            // that edge is the menu bar's own line and the sliver above it
            // belongs to the trace.
            shape.stroke(
                LinearGradient(
                    stops: ChromeRules.rimStops(
                        expanded: expanded,
                        hovering: controller.isMouseInside,
                        // The RESTING stroke, not the live `traceWidth`: the
                        // handoff is where the trace's cap can reach, and the
                        // rim must not slide up and down the silhouette every
                        // time the pointer swells the line.
                        traceStrokeWidth: trackDrawn ? ChromeRules.traceStroke : nil,
                        height: size.height,
                        bottomRadius: controller.bottomCornerRadius)
                        .map { .init(color: .white.opacity($0.alpha),
                                     location: $0.location) },
                    startPoint: .top, endPoint: .bottom),
                lineWidth: 0.5)
                // The gradient resolved in the hosting view's box, not the
                // shape's — 452x176 against 344x122 — so every stop landed at the
                // wrong height and the rim never reached its own bottom stop.
                // `glassLayer` already carries this same treatment for the same
                // reason. `.top` is load-bearing: centred, the box floats 27pt
                // below the silhouette.
                .frame(width: size.width, height: size.height)
        }
        .animation(Motion.meter, value: controller.isMouseInside)
        .compositingGroup()
        .shadow(color: .black.opacity(expanded ? 0.5 : 0),
                radius: expanded ? 28 : 0, y: expanded ? 14 : 0)
    }

    /// Tinted Liquid Glass plus the blurred cover, blooming out of the cutout.
    private var glassLayer: some View {
        Color.clear
            .glassEffect(.regular.tint(tint.opacity(0.65)), in: shape)
            .overlay { coverWash }
            .compositingGroup()
            .mask(shape)
    }

    /// Four palette colours arranged over the mesh's nine cells.
    private var meshColors: [Color] {
        let p = media.palette.colors.isEmpty
            ? ArtworkPalette.fallback.colors : media.palette.colors
        func c(_ i: Int) -> Color { p[i % p.count] }
        return [c(0), c(1), c(2),
                c(3), c(0), c(1),
                c(2), c(3), c(0)]
    }

    /// A living colour field built from the song's own palette.
    ///
    /// This has to *move*. A static gradient — radial or vertical — is a shape
    /// sitting on the panel, not something with life in it. The mesh's control
    /// points drift on slow, mutually-prime sines so the field never visibly
    /// loops.
    ///
    /// Removing the blurred cover was tried and reverted; the note is here so it
    /// is not tried again blind. `blur(46)` across a frame this wide is about a
    /// tenth of the image, and the cover's hue spread collapses from 0.462 to
    /// 0.062 between a twentieth and a fourteenth, so what this lays down is
    /// close to the cover's global MEAN — for the record on the bench, a flat
    /// beige at hue 0.139. Rendering the stack without it through SwiftUI's own
    /// rasteriser predicted a gain. Built and measured on screen it went the
    /// other way: the hue bins carrying the field fell from 4 to 3 and the modal
    /// bin went from 36% to 76%.
    ///
    /// Two things the headless model could not see, and both matter more than
    /// this layer. `glassEffect` will not render offscreen, and it is tinted
    /// with ONE palette colour across the whole panel, so dropping this layer
    /// only uncovers a flatter wash than itself. And `opacity` below is
    /// 0.74 + 0.24 × loudness: every measurement above was taken with the music
    /// PAUSED, which is the mesh at its weakest and the glass at its most
    /// visible. A panel judged while nothing is playing is being judged in its
    /// worst case for colour. Measure with audio before touching this stack.
    ///
    /// It only animates while a track is actually playing; a drifting gradient
    /// behind a paused, collapsed notch is pure wasted energy.
    @ViewBuilder
    private var coverWash: some View {
        if media.hasTrack {
            ZStack {
                if let art = media.artwork {
                    Image(nsImage: art)
                        .resizable()
                        .scaledToFill()
                        .frame(width: size.width * 1.18, height: size.height * 1.18)
                        .blur(radius: 46)
                        .saturation(1.5)
                        .opacity(0.5)
                }

                MeshField(fluid: fluid, colors: meshColors)
            }
            // Additive blending blew the field out to near-white and destroyed
            // the text contrast. A scrim keeps the colour rich but dark enough
            // that white type still reads on it.
            //
            // It used to take its depth from `washLuminance`, on the reasoning
            // that a brighter wash needs a deeper scrim. `capped()` already pins
            // that input to the ceiling, so the term was very nearly a constant,
            // and the reasoning is now in `ArtworkPalette.scrimAlpha` next to the
            // arithmetic it governs. The view just asks for the two ends.
            .overlay {
                LinearGradient(
                    stops: [
                        .init(color: .black.opacity(
                            ArtworkPalette.scrimAlpha(expanded: expanded)),
                              location: 0),
                        .init(color: .black.opacity(
                            ArtworkPalette.scrimAlpha(depth: 1, expanded: expanded)),
                              location: 1),
                    ],
                    startPoint: .top, endPoint: .bottom)
            }
        }
    }


    /// Where along the *path* a given horizontal position falls.
    ///
    /// `.trim` parameterises by arc length, but the gesture is linear in x, and
    /// the shell's two bottom corners are quadratic quarter-turns roughly 1.62r
    /// long for only r of horizontal travel. Feeding a time fraction straight
    /// into `.trim` therefore ran the handle up to 8.7% slow: exact at the ends
    /// and the middle, and visibly behind the pointer everywhere else.
    private func cornerArc(_ r: CGFloat, upTo t: CGFloat, steps: Int = 24) -> CGFloat {
        // |B'(t)| = 2r * sqrt(t^2 + (1-t)^2) for a quarter-turn quadratic.
        guard t > 0 else { return 0 }
        var sum: CGFloat = 0
        for i in 0..<steps {
            let m = t * (CGFloat(i) + 0.5) / CGFloat(steps)
            sum += 2 * r * sqrt(m * m + (1 - m) * (1 - m))
        }
        return sum * t / CGFloat(steps)
    }

    private func edgeFraction(atX x: CGFloat) -> Double {
        // The trace is an INSET copy of the silhouette, so these are the inset
        // path's lengths, not the shell's. `NotchBottomEdge` shrinks the frame
        // and the corner by the same inset — the corner has to shrink, or the
        // arc is translated rather than offset — and a mapping written against
        // the shell's own width and radius answers for a path 2.5pt wider with
        // a corner 1.25pt rounder than the one actually drawn.
        let e = traceInset
        let w = max(size.width - e * 2, 1)
        let r = max(0, min(controller.bottomCornerRadius - e,
                           min((size.height - e) / 2, w / 2)))
        let cx = min(max(x - e, 0), w)
        guard r > 0 else { return Double(cx / w) }
        let corner = cornerArc(r, upTo: 1)
        let total = (w - 2 * r) + 2 * corner
        // x(t) = r*t^2 along each corner, so t = sqrt(dx / r).
        if cx <= r { return Double(cornerArc(r, upTo: sqrt(cx / r)) / total) }
        if cx >= w - r {
            return Double((total - cornerArc(r, upTo: sqrt((w - cx) / r))) / total)
        }
        return Double((corner + (cx - r)) / total)
    }

    /// The trim value that puts the playhead where the time actually is.
    private var edgeTrim: Double {
        edgeFraction(atX: CGFloat(shownFraction) * size.width)
    }

    /// Grab handle for the progress trace.
    ///
    /// The trace itself is a stroked path and a terrible hit target, so the
    /// gesture lives on a taller invisible strip pinned to the panel's bottom
    /// edge, mapped straight from x to a fraction of the track.
    private var seekStrip: some View {
        GeometryReader { proxy in
            // No x-origin term: the GeometryReader is framed to `size.width` a
            // few lines below, so `(proxy.size.width - w) / 2` was always zero
            // and the subtraction it fed was arithmetic on a constant nothing.
            let w = size.width
            Color.clear
                .contentShape(.rect)
                // Without this the scrubber is a bare drag target: playback
                // position was neither readable nor settable by any non-pointer
                // means, and the playhead only appears on hover.
                .accessibilityElement()
                .accessibilityLabel("Playback Position")
                .accessibilityValue(ExpandedPlayer.time(shownPosition)
                                    + " of " + ExpandedPlayer.time(media.duration))
                .accessibilityAdjustableAction { direction in
                    let step = 0.05
                    let target = direction == .increment
                        ? min(1, shownFraction + step)
                        : max(0, shownFraction - step)
                    media.seek(toFraction: target)
                }
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { g in
                            scrubbing = true
                            scrubFraction = min(max(g.location.x / max(w, 1), 0), 1)
                            // The ink follows the playhead. Harder than a hover:
                            // you are dragging the thing, so it should feel like
                            // the surface is being dragged with it.
                            fluid.setPointer(rim: Double(scrubFraction), strength: 1.5)
                        }
                        .onEnded { g in
                            // Release it. This used to hand the magnet back to
                            // the hover feed, which then overwrote the scrub's
                            // stronger pull on the next mouse move — but the
                            // hover magnet is gone, so nothing would ever clear
                            // it: the swell would stay raised for the rest of the
                            // session and isSettled would never come back, which
                            // also means the renderer never pauses.
                            fluid.setPointer(rim: nil)
                            let f = min(max(g.location.x / max(w, 1), 0), 1)
                            media.seek(toFraction: Double(f))
                            scrubbing = false
                        }
                )
                .onHover { seekHovering = $0 }
                // Sized to clear the transport rather than to be comfortable:
                // this strip is the topmost thing in the panel, so every point
                // it overlaps is a point the controls under it never see.
                .frame(width: w, height: ChromeRules.seekStripHeight)
                .position(x: proxy.size.width / 2,
                          y: size.height - ChromeRules.seekStripCentre)
        }
        .frame(width: size.width, height: size.height)
        // SwiftUI never delivers onEnded to a gesture whose view is removed
        // mid-drag, and this strip is conditionally present — a screen lock or
        // scripted collapse during a scrub takes it down with the drag in
        // flight. Without this reset, `scrubbing` stays true for the session:
        // the trace, clocks and VoiceOver value pin to the stale drag position,
        // the 15Hz timeline stays paused, and the ink keeps a 1.5-strength
        // pointer it can never settle under.
        .onDisappear {
            if scrubbing {
                scrubbing = false
                fluid.setPointer(rim: nil)
            }
            seekHovering = false
        }
    }

    /// Grab handle at the playhead.
    ///
    /// Drawn as a near-zero-length trim of the *same* path, stroked with a round
    /// cap — so it sits exactly on the trace and follows the silhouette's curve
    /// without any position maths of its own.
    private var playhead: some View {
        NotchBottomEdge(width: size.width,
                        height: size.height,
                        bottomCornerRadius: controller.bottomCornerRadius,
                        // The TRACE's inset, not its own: the handle grows out of
                        // the line, so both have to be drawn on the same path.
                        inset: traceInset)
            .trim(from: max(0, edgeTrim - 0.0015), to: max(0.0016, edgeTrim))
            // The handle GROWS OUT OF the trace; it never fades.
            //
            // At rest its width is the trace's own, so it is simply the bright
            // tip of the line — always present, never announced. Hovering swells
            // it into a grabbable handle and grabbing swells it further. There is
            // deliberately no opacity term: a dot that fades in was always there,
            // and reads as a light being switched on. A dot that grows was
            // brought there by the pointer, and reads as a response.
            // Retracted it was zero — the peek's line simply stopped, while the
            // panel's ended in a round knob. One accent, two grammars, for the
            // same value in the same song. At rest the handle IS the trace's own
            // width, so giving the peek the same tip costs it nothing it has
            // room for: the sliver the line already occupies.
            .stroke(.white, style: StrokeStyle(
                lineWidth: expanded ? (scrubbing ? 12 : (seekHovering ? 9 : 2.5))
                                    : traceWidth,
                lineCap: .round))
            .shadow(color: tint.opacity(0.9), radius: scrubbing || seekHovering ? 6 : 0)
            .animation(Motion.seek, value: seekHovering)
            .animation(Motion.seek, value: scrubbing)
            .allowsHitTesting(false)
    }

    /// Playback progress drawn along the shell's own bottom edge.
    /// One width, so the stroke and the inset that keeps it inside the shell can
    /// never disagree.
    ///
    /// Retracted, the shell is the menu-bar band with the camera sitting on it,
    /// and the line has only the sliver between the two to live in — a point on
    /// the built-in display. It is sized to that sliver rather than drawn at its
    /// expanded width and shoved downward until the top clears, which is what it
    /// used to do and what put a point and a half of it on the window chrome.
    private var traceWidth: CGFloat {
        let full: CGFloat = scrubbing ? 4 : (seekHovering ? 3.4 : ChromeRules.traceStroke)
        guard !expanded else { return full }
        return ChromeRules.retractedTraceWidth(shellHeight: size.height,
                                               cutoutHeight: controller.notchSize.height,
                                               expandedWidth: full,
                                               hasNotch: controller.style == .notch)
    }

    /// Half the stroke, in both states — see `ChromeRules.traceInset`.
    private var traceInset: CGFloat { ChromeRules.traceInset(strokeWidth: traceWidth) }

    /// The unplayed remainder of the line.
    ///
    /// The trace used to be drawn alone: a `.trim` from zero with nothing behind
    /// it, so the bottom edge of the panel was stroked for exactly as much of
    /// its width as the track had played and bare for the rest. The silhouette's
    /// break point slid rightward as the song went on, and at the start of a
    /// track the playhead sat on the corner with no line under it at all — a
    /// detached speck on the one list of things this player is never allowed to
    /// look like.
    ///
    /// Same path, same inset, same width, same gate as the fill, lower alpha.
    /// Every one of those is `traceWidth`/`traceInset` rather than a number of
    /// its own, because a track that can disagree with its fill is two lines
    /// that are concentric only by luck.
    private var progressTrack: some View {
        NotchBottomEdge(width: size.width,
                        height: size.height,
                        bottomCornerRadius: controller.bottomCornerRadius,
                        inset: traceInset)
            .stroke(.white.opacity(0.16),
                    style: StrokeStyle(lineWidth: traceWidth, lineCap: .round))
            .animation(Motion.seek, value: scrubbing)
            .animation(Motion.seek, value: seekHovering)
            .allowsHitTesting(false)
    }

    private var progressEdge: some View {
        NotchBottomEdge(width: size.width,
                        height: size.height,
                        bottomCornerRadius: controller.bottomCornerRadius,
                        inset: traceInset)
            .trim(from: 0, to: max(0.0001, edgeTrim))
            .stroke(
                LinearGradient(colors: [tint, tint.opacity(0.75)],
                               startPoint: .leading, endPoint: .trailing),
                style: StrokeStyle(lineWidth: traceWidth, lineCap: .round))
            // Expanded only. The trace is drawn retracted too — the peek keeps
            // `hasShellForTrace` true for as long as a track is loaded — and a
            // 6pt glow on a line that sits at the bottom of the menu-bar band
            // spills onto the window chrome below it. The playhead's own shadow
            // is already conditional for the same reason.
            .shadow(color: tint.opacity(0.8), radius: expanded ? 6 : 0)
            // Same curve as the handle, so the line and its tip swell as one
            // gesture rather than as two things that happen to coincide.
            .animation(Motion.seek, value: scrubbing)
            .animation(Motion.seek, value: seekHovering)
            .allowsHitTesting(false)
    }

    // MARK: Content

    @ViewBuilder
    private var content: some View {
        if expanded {
            if media.hasTrack {
                ExpandedPlayer(media: media,
                               shownPosition: shownPosition,
                               scrubbing: scrubbing,
                               band: band,
                               notchWidth: controller.notchSize.width,
                               panelWidth: size.width,
                               glass: glass,
                               fluid: fluid)
                    // Staged behind the shell on the way in — the panel opens,
                    // then its contents arrive — and unstaged on the way out so
                    // the content leaves first and the shell closes on nothing.
                    // Everything used to start and stop on the same frame.
                    .transition(.asymmetric(
                        insertion: .opacity
                            .combined(with: .offset(y: 6 * Motion.travel))
                            .animation(Motion.content.delay(0.07)),
                        // Leaves upward, into the closing shell, rather than
                        // dissolving where it stands while the shell retracts
                        // without it. Still unstaged and still faster than the
                        // arrival, so the content is gone before the shape is.
                        removal: .opacity
                            .combined(with: .offset(y: -10 * Motion.travel))
                            .animation(Motion.content.speed(1.6))))
            } else {
                IdleCard(topInset: band)
                    // Arrives like the player does, rather than being the one
                    // piece of expanded content that simply appears at rest —
                    // and leaves differently from how it came, damped and faster.
                    .transition(.asymmetric(
                        insertion: .offset(y: 10 * Motion.travel)
                            .combined(with: .opacity)
                            .animation(Motion.content.delay(0.10)),
                        removal: .offset(y: 6 * Motion.travel)
                            .combined(with: .opacity)
                            .animation(Motion.content.speed(1.7))))
            }
        } else if controller.notification.isSome {
            HUDStrip(controller: controller, notchWidth: controller.notchSize.width)
                // Opacity only at this level. A .scale here anchors on the view's
                // centre, and the centre of this strip is the camera cutout — so
                // the whole HUD grew out of, and shrank into, the one point
                // nothing may ever be drawn on. The two halves get their own
                // directional entrances inside HUDStrip instead, so the strip
                // extrudes sideways out of the cutout's edges the way the shell
                // itself does.
                .transition(.opacity.animation(Motion.swap))
        } else if controller.liveActivity == .isPlaying, media.hasTrack {
            CollapsedActivity(media: media,
                              notchWidth: controller.notchSize.width,
                              glass: glass)
                // On the shell's own vocabulary, and asymmetric. The flanks are
                // extruded sideways out of the cutout on the same spring the
                // width is using, so a peek cleared and immediately re-shown
                // retargets with it instead of restarting a fixed fade.
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.84, anchor: .center)
                        .combined(with: .opacity)
                        .animation(Motion.swap),
                    removal: .scale(scale: 0.90, anchor: .center)
                        .combined(with: .opacity)
                        .animation(Motion.collapse.speed(1.3))))
        }
    }

}

// MARK: - Expanded player

private struct ExpandedPlayer: View {
    var media: MediaManager
    /// Reflects the scrub position while dragging, so the clocks let you land on
    /// a specific second rather than reading stale playback.
    var shownPosition: Double
    /// Whether a scrub is in flight — the one time `shownPosition` outranks the
    /// live clock, and the one time the band's timeline pauses.
    var scrubbing: Bool
    /// Height of the physical cutout; the band the camera lives in.
    var band: CGFloat
    /// Measured width of the cutout (`tools/notchruler`). The band row reserves
    /// exactly this span so nothing can ever drift under the camera, rather than
    /// relying on a `Spacer` that only happens to be big enough today.
    var notchWidth: CGFloat
    var panelWidth: CGFloat
    /// Shared with `CollapsedActivity` so the artwork — which exists in both
    /// states at different sizes and positions — morphs between them instead of
    /// crossfading between two places.
    var glass: Namespace.ID
    var fluid: FerrofluidSim


    /// A press is an event, so it goes in the same door a drum hit does.
    ///
    /// The ink is the app's one signature element and until now it answered only
    /// the music — press a button and the thing that makes this app itself did
    /// not move. A strike gives the control weight: the surface heaves and the
    /// rim glow blooms, from the same gesture.
    ///
    /// It used to tick the trackpad too. A haptic belongs to a gesture that has
    /// no other confirmation — `NotchGestures` still ticks, because a swipe that
    /// worked and a swipe that missed are otherwise identical under the fingers.
    /// A button is not that: it moves, it lights, and the ink answers it. The
    /// tick was a third report of something already said twice.
    private func strike(_ strength: Double, direction: Double = 0) {
        fluid.surge(strength, direction: direction)
    }

    /// Both mode slots or neither — see `ChromeRules.modeSlots`. A mode Spotify
    /// refuses in the current context still draws, so the panel has not lost a
    /// button; `ChromeRules.modeStyle` is what makes it read as unpressable.
    private var modeSlots: (shuffle: Bool, `repeat`: Bool) {
        ChromeRules.modeSlots(shuffling: media.shuffling, repeating: media.repeating)
    }

    /// The three-state rule lives in `ChromeRules.modeStyle`, asserted by
    /// chromecheck; this only turns its numbers into a colour.
    private func modeStyle(on: Bool, blocked: Bool)
        -> (tint: Color, fill: Double, rim: Double) {
        let s = ChromeRules.modeStyle(on: on, blocked: blocked)
        return (.white.opacity(s.glyph), s.fill, s.rim)
    }

    /// Read at the call site, where the button only renders once the mode is
    /// known — the `?? false` never decides anything visible.
    private var shuffleStyle: (tint: Color, fill: Double, rim: Double) {
        modeStyle(on: media.shuffling ?? false, blocked: media.shuffleBlocked)
    }

    private var repeatStyle: (tint: Color, fill: Double, rim: Double) {
        modeStyle(on: media.repeating ?? false, blocked: media.repeatBlocked)
    }

    /// Intrinsic widths of the two lines, and the column they sit in.
    ///
    /// Measured with the same idiom `MarqueeText` uses internally — a hidden,
    /// `fixedSize` mirror — because the visible label is greedy and its frame
    /// therefore says nothing about how wide the words actually are. The mirror
    /// is the INTRINSIC width, never the scroller's position, so the heart does
    /// not jitter while a long title is mid-pass.
    @ViewState private var titleWidth: CGFloat = 0
    @ViewState private var artistWidth: CGFloat = 0
    @ViewState private var textColumnWidth: CGFloat = 0

    /// The heart trails the wider of the two lines, not the artist alone: a
    /// 22pt disc tucked against a 12.5pt line collides with the descenders of
    /// a longer title directly above it.
    private var heartSlack: CGFloat {
        ChromeRules.heartSlack(textWidth: max(titleWidth, artistWidth),
                               columnWidth: textColumnWidth)
    }

    /// Title, artist, and the library heart beside them.
    ///
    /// The heart sits here rather than in the transport row. In the row it was a
    /// sixth control on a five-control frame: the group is centred on the panel,
    /// so one more disc on the right pushed the whole thing 11pt left into the
    /// artwork and left the air on the other side. Modes bracket the transport
    /// symmetrically; the library is not a mode, and beside the track it names is
    /// where every other player puts it.
    private var trackLine: some View {
        HStack(alignment: .center, spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                    MarqueeText(text: media.title,
                                font: .system(size: 15, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(height: Grid.title)
                        // Optical, not geometric: centring the line box in a 17pt
                        // frame left the cap line 3.5pt below the artwork's top
                        // edge, and the glyphs' side bearing left their stems 1pt
                        // right of the disc row. Type beside an image is measured
                        // against the image's hard edges, not against its own box.
                        .offset(y: -3.5)
                        .padding(.leading, -1)
                        // The words arrive with the song instead of being
                        // swapped underneath it. Title leads; the artist follows
                        // a beat later, so the pair reads as one arrival rather
                        // than two things changing at once.
                        .id(media.trackToken)
                        .transition(.asymmetric(
                            insertion: .offset(y: 8 * Motion.travel)
                                .combined(with: .opacity),
                            removal: .offset(y: -6 * Motion.travel)
                                .combined(with: .opacity)))

                    MarqueeText(text: media.artist,
                                font: .system(size: 12.5, weight: .medium))
                        .foregroundStyle(.white.opacity(0.76))
                        .id(media.trackToken)
                        .transition(.asymmetric(
                            insertion: .offset(y: 8 * Motion.travel)
                                .combined(with: .opacity)
                                .animation(Motion.content.delay(0.06)),
                            removal: .offset(y: -6 * Motion.travel)
                                .combined(with: .opacity)))
                        .frame(height: Grid.artist)
                    }
                    .background {
                        // Zero-cost probes: the column's width, and what the two
                        // lines would measure if nothing constrained them.
                        ZStack(alignment: .leading) {
                            Color.clear
                                .onGeometryChange(for: CGFloat.self) { $0.size.width }
                                    action: { textColumnWidth = $0 }
                            Text(media.title)
                                .font(.system(size: 15, weight: .semibold))
                                .lineLimit(1).fixedSize().hidden()
                                .onGeometryChange(for: CGFloat.self) { $0.size.width }
                                    action: { titleWidth = $0 }
                            Text(media.artist)
                                .font(.system(size: 12.5, weight: .medium))
                                .lineLimit(1).fixedSize().hidden()
                                .onGeometryChange(for: CGFloat.self) { $0.size.width }
                                    action: { artistWidth = $0 }
                        }
                    }

                    Spacer(minLength: 0)

                    // Only where the player can actually answer. Without a
                    // Spotify connection there is nothing to ask, so rather than
                    // a heart that lies there is no heart; it appears on its own
                    // the moment the library answers.
                    if let liked = media.liked {
                        TransportButton(symbol: liked ? "heart.fill" : "heart",
                                        label: liked ? "Remove from Favourites"
                                                     : "Add to Favourites",
                                        diameter: Grid.mode, glyph: 10.5,
                                        tint: liked ? .pink : .white.opacity(0.55)) {
                            media.toggleLike()
                            // Heavier than a skip. Adding to your library is the
                            // one press here that changes something outside this
                            // app.
                            strike(liked ? 0.7 : 1.15)
                        }
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                        // Rendering and hit-testing move; layout does not. The
                        // column keeps its full width and the marquee keeps a
                        // definite box, so this cannot reintroduce the zero-width
                        // title.
                        .offset(x: -heartSlack)
                    }
        }
        .frame(height: Grid.title + Grid.artist)
    }

    /// Previous, play, next — and nothing else, ever.
    ///
    /// Play sits on the PANEL's centre line, which it can only do while this
    /// group is symmetric about play. It used to also carry shuffle and repeat,
    /// so symmetry depended on what the player had answered about two modes,
    /// and a player that answered one and not the other put play 15pt off the
    /// line. Three transport controls are symmetric whatever anyone answers;
    /// `ChromeRules.playOffCentre` is the arithmetic and chromecheck asserts
    /// that adding a fourth thing to either end fails.
    ///
    /// The column this sits in begins after the sleeve and the gutter, so its
    /// own centre is half of those right of the panel's. The offset takes that
    /// back, derived rather than written down — the sleeve has changed size
    /// three times and this followed it each time.
    private var transportTriad: some View {
        // Zero spacing plus 4pt of padding inside each button: same 33pt pitch,
        // but the hit circles touch instead of leaving 4pt dead gaps between
        // them.
        HStack(spacing: 0) {
            TransportButton(symbol: "backward.fill",
                            label: "Previous Track",
                            diameter: Grid.controls, glyph: 9.5) {
                media.previous()
                strike(0.8, direction: -1)
            }
            TransportButton(symbol: media.isPlaying ? "pause.fill" : "play.fill",
                            label: media.isPlaying ? "Pause" : "Play",
                            diameter: Grid.primary, glyph: 12.5,
                            prominent: true) {
                // No strike. Play is the one control whose real answer is the
                // music: press it and the ink comes alive from the audio a beat
                // later, press it again and the ink settles. Slamming the
                // reservoir first announced the change before the change, and
                // the swipe that does the same thing never did —
                // `NotchGestures.togglePlayback` calls `playPause` and surges
                // nothing. The button was the outlier.
                media.playPause()
            }
            TransportButton(symbol: "forward.fill",
                            label: "Next Track",
                            diameter: Grid.controls, glyph: 9.5) {
                media.next()
                strike(0.8, direction: 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .offset(x: -(Grid.artwork + Grid.gutter) / 2)
    }

    /// Shuffle and repeat, as one group on the panel's right margin.
    ///
    /// They used to bracket the transport, "which is where every player puts
    /// them". Two things were wrong with that. The row is centred on the panel,
    /// so their two slots and the gaps beside them reserved 44pt on the
    /// SLEEVE's side of the centre line to hold a pair of 22pt glyphs that are
    /// not transport — and the panel already had that much empty on the other
    /// side, 76.5pt of nothing between the last control and the margin. The
    /// modes fill it, the sleeve takes the room they gave back, and Apple
    /// Music's now-playing bar groups them exactly here, so nothing about this
    /// is unfamiliar.
    ///
    /// Dimmed rather than absent when off: a mode you cannot see is a mode you
    /// forget you left on. Both slots or neither, from `ChromeRules.modeSlots`
    /// — trailing-aligned, the cluster's WIDTH is what decides where its left
    /// glyph lands, so reserving one slot would draw shuffle in repeat's place
    /// and jump it 30pt left the moment the player answered about repeat. The
    /// unanswered one's slot is held open with blank space; reserving space is
    /// not rendering a control, so nothing here claims to do something it
    /// cannot.
    private var modeCluster: some View {
        HStack(spacing: 0) {
            if modeSlots.shuffle, let shuffling = media.shuffling {
                TransportButton(symbol: "shuffle",
                                label: media.shuffleBlocked
                                    ? "Shuffle unavailable here"
                                    : shuffling ? "Shuffle On" : "Shuffle Off",
                                diameter: Grid.mode, glyph: 8,
                                tint: shuffleStyle.tint,
                                fill: shuffleStyle.fill,
                                rim: shuffleStyle.rim) {
                    media.toggleShuffle()
                    strike(0.55)
                }
                .disabled(media.shuffleBlocked)
            } else if modeSlots.shuffle {
                Color.clear.frame(width: ChromeRules.slot(Grid.mode),
                                  height: ChromeRules.slot(Grid.mode))
            }

            if modeSlots.repeat, let repeating = media.repeating {
                TransportButton(symbol: "repeat",
                                label: media.repeatBlocked
                                    ? "Repeat unavailable here"
                                    : repeating ? "Repeat On" : "Repeat Off",
                                diameter: Grid.mode, glyph: 8,
                                tint: repeatStyle.tint,
                                fill: repeatStyle.fill,
                                rim: repeatStyle.rim) {
                    media.toggleRepeat()
                    strike(0.55)
                }
                .disabled(media.repeatBlocked)
            } else if modeSlots.repeat {
                Color.clear.frame(width: ChromeRules.slot(Grid.mode),
                                  height: ChromeRules.slot(Grid.mode))
            }
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
        // Out by the padding ring, so the DISC lands on the margin the sleeve's
        // left edge sits on. Trailing-aligned without this, the glyph column
        // stops 4pt short of a line the other side of the panel holds exactly,
        // and the two edges disagree by a visible hair.
        .offset(x: ChromeRules.controlInset)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Cutout band: the two halves of one clock, flanking the camera.
            //
            // The left slot held a five-bar meter. It was a mirrored equaliser —
            // bars scaled about a centre line — which is the first entry in
            // PRODUCT.md's anti-references, and it sat one inch from the
            // ferrofluid doing the same job worse. "The ferrofluid earns the
            // spectacle"; a meter beside it is a second answer to a question
            // already answered.
            // 10Hz from the display clock, for the same reason the collapsed
            // clock runs that way: the poll lands every ~1.09s, so a clock
            // sampled at poll cadence visibly skips a second roughly every
            // eleventh tick. The timeline only schedules the redraw — the value
            // has to be read LIVE inside the closure, because the closure
            // captures `shownPosition` frozen at init and a new date over a
            // stale Double still renders the stale second.
            TimelineView(.animation(minimumInterval: 1.0 / 10.0,
                                    paused: !media.isPlaying || scrubbing)) { _ in
                let pos = scrubbing ? shownPosition : media.smoothPosition
                HStack(spacing: 0) {
                    Text(ExpandedPlayer.time(pos))
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        // The tier's opacity lives in ArtworkPalette beside the
                        // scrim it is read against, so palettecheck gates the
                        // real value rather than a hand copy.
                        .foregroundStyle(.white.opacity(ArtworkPalette.chromeTypeAlpha))
                        // Flexible, so the flanks resolve against the SAME padded
                        // edges the body below uses. Hard-coding `flank - margin`
                        // subtracted the margin a second time inside a container
                        // that was already padded, and the elapsed clock ended up
                        // 50pt from the right edge while the remaining clock —
                        // its own matched pair — sat at 16pt.
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // A readout jumps; it does not dissolve. Both halves
                        // carry it — see the note under the timeline.
                        .contentTransition(.identity)
                        .transaction { $0.animation = nil }

                    // The camera's span, reserved and left empty.
                    Color.clear.frame(width: notchWidth)

                    // Its matched half. One datum split in two, so both keep the
                    // same weight and tier — at different ones the elapsed time
                    // outranked the artist's name.
                    // Empty for a live stream: it has no end to count down to,
                    // and "-0:00" read as a track about to finish.
                    Text(media.duration > 0
                         ? "-" + ExpandedPlayer.time(max(0, media.duration - pos)) : "")
                        .font(.system(size: 10.5, weight: .medium, design: .rounded))
                        .monospacedDigit()
                        .foregroundStyle(.white.opacity(ArtworkPalette.chromeTypeAlpha))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .contentTransition(.identity)
                        .transaction { $0.animation = nil }
                }
                .frame(height: band)
            }
            // A readout jumps; it does not dissolve. Under an animation a
            // `Text` whose string changes is crossfaded — both glyph runs
            // painted at once. Overlaid exactly that is invisible, which is why
            // the transport's own skip button always looked clean. But a swipe
            // commits WHILE `SwipeLeanFrame` is easing the sheet back from its
            // lean, so the two runs land at different x and separate into
            // "2:0100" for a fifth of a second — on the one beat the ratchet
            // exists to show.
            //
            // The fix belongs on the Texts, and the first attempt put it here
            // instead: `.animation(nil, value: media.trackToken)` on this
            // TimelineView. It compiled, read correctly, and did nothing —
            // filmed at 58fps the doubled run was still there for twelve
            // frames. `.animation(_:value:)` only suppresses animation
            // attributed to THAT value changing, and the glyphs do not change
            // because `trackToken` changed; they change because `pos` jumps to
            // zero, re-read inside the timeline's own redraw, which still
            // carries whatever ambient animation is open around it. A
            // back-swipe two minutes in makes that plain: it restarts the
            // track already playing, `identity` does not change, so
            // `trackToken` never increments, and a suppression scoped to it
            // has nothing whatever to fire on. The suppression has to sit
            // where the content change happens and be unconditional:
            // `.contentTransition(.identity)` says a changed string is not a
            // thing to interpolate, and the `.transaction` strips any
            // animation inherited from an ancestor's transaction. Layout
            // still animates from the parent — only the glyph swap is
            // instant, which is what a clock should do.
            //
            // Do not re-verify this by reading it. It was source-verified once
            // already and was wrong; only a swipe filmed and looked at proves it.

            Spacer(minLength: Grid.bandGap)

            // Body: the artwork is SQUARE and the column is 62 tall, so they no
            // longer end on the same line — the artwork gave up its width to
            // clear the control row and cannot give up its height without
            // becoming a rectangle. Centred in the row instead, which puts 4pt
            // above and below rather than 8 under it, and reads as placed rather
            // than as fallen short.
            HStack(alignment: .top, spacing: Grid.gutter) {
                Artwork(image: media.artwork, palette: media.palette,
                        size: Grid.artwork, radius: 12)
                    .frame(height: Grid.art)
                    .matchedGeometryEffect(id: "artwork", in: glass)
                    .id(media.trackToken)
                    // The sleeve is the track, so pressing it opens the track.
                    // Spotify takes its own URI and lands on the song; Music
                    // reveals it in the library.
                    .onTapGesture {
                        media.openInPlayer()
                        // A press is an event, same door a drum hit goes through.
                        // Leaving this one silent would make the largest control
                        // on the panel the only one the ink ignores.
                        strike(1)
                    }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel(Text(media.source.map { "Open in \($0.displayName)" }
                                             ?? "Open in player"))
                    .help(media.source.map { "Open in \($0.displayName)" } ?? "Open in player")
                    // Right-click rather than a seventh button. The row is the
                    // one place on this panel that cannot afford more chrome,
                    // and a share link is something you reach for deliberately.
                    .contextMenu {
                        Button {
                            media.openInPlayer()
                            strike(1)
                        } label: {
                            Label(media.source.map { "Open in \($0.displayName)" }
                                  ?? "Open in Player", systemImage: "arrow.up.forward.app")
                        }
                        if let url = media.shareURL {
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(url.absoluteString,
                                                               forType: .string)
                                strike(0.6)
                            } label: {
                                Label("Copy Link", systemImage: "link")
                            }
                        }
                    }
                    // A card lifted off a card, not a cross-fade: the old sleeve
                    // grows past its frame and dissolves while the new one comes
                    // up underneath it. The removal runs faster so it has cleared
                    // before the arrival settles — at equal speed both take 0.52s
                    // and the two covers ghost through each other.
                    .transition(.asymmetric(
                        insertion: .scale(scale: 1 - 0.14 * Motion.travel)
                            .combined(with: .opacity),
                        removal: .scale(scale: 1 + 0.10 * Motion.travel)
                            .combined(with: .opacity)
                            .animation(Motion.track.speed(1.6))))

                VStack(alignment: .leading, spacing: 0) {
                    trackLine

                    Spacer(minLength: 0)

                    // Two groups on one line, and only one of them is centred.
                    //
                    // They cannot be one stack: a single row can centre its
                    // middle child on the panel or pin its last child to the
                    // margin, not both. Overlaid instead — each group takes the
                    // full width and aligns itself inside it, so neither one's
                    // contents can move the other's.
                    ZStack {
                        transportTriad
                        modeCluster
                    }
                    .frame(height: Grid.primary)
                    .animation(Motion.swap, value: media.liked)
                    .animation(Motion.swap, value: media.shuffling)
                    .animation(Motion.swap, value: media.repeating)
                }
                .frame(height: Grid.art)
            }
        }
        .padding(.horizontal, Grid.margin)
        .padding(.bottom, Grid.bottom)
    }

    static func time(_ seconds: Double) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let s = Int(seconds.rounded())
        return s >= 3600
            ? String(format: "%d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60)
            : String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Collapsed live activity

/// Artwork and elapsed time hugging either side of the physical cutout.
/// Nothing may sit in the middle — that's where the camera lives.
private struct CollapsedActivity: View {
    var media: MediaManager
    var notchWidth: CGFloat
    var glass: Namespace.ID

    var body: some View {
        HStack(spacing: 0) {
            Artwork(image: media.artwork, palette: media.palette, size: 19, radius: 5.5)
                .matchedGeometryEffect(id: "artwork", in: glass)
                .frame(maxWidth: .infinity, alignment: .leading)

            // The camera's span, reserved and left empty.
            Color.clear.frame(width: notchWidth)

            // Was the meter. Left empty the peek is artwork, camera, then a
            // void, which reads as something failing to load; the elapsed clock
            // balances it and is the one thing worth knowing at a glance from
            // the menu bar.
            //
            // NOT gated on isPlaying, which it inherited from the meter. That
            // gate was right for a meter — "a meter with no signal should not be
            // there at all" — and wrong for a clock, which still says where you
            // are in the track and arguably matters MORE while paused, since
            // that is when you want to know where you left off. With the gate it
            // vanished on pause and the right flank went empty, which is the
            // exact void this element was put here to fill.
            // Read at display rate from the interpolated position, not once per
            // poll from the raw one.
            //
            // `media.position` only changes when a poll lands, and the poll loop
            // is a 1s sleep plus the snapshot's own synchronous ScriptingBridge
            // round trips — measured at 88-199ms against Spotify, so the clock
            // advanced in ~1.09s steps. Rounded to whole seconds that reads as
            // +1 most of the time and +2 roughly every eleventh poll, as the
            // extra 0.09s accumulates past a second boundary. It is the same
            // defect recorded above the progress timeline, where the playhead
            // "only moved when the body happened to re-evaluate": a continuously
            // moving value sampled at the poll rate.
            //
            // The expanded player already read `smoothPosition`; this one was
            // left behind. 10Hz, not the trace's 15: the string changes once a
            // second, so this only has to land the boundary invisibly, and the
            // retracted band is the state whose cost actually matters. Paused
            // with playback, where `smoothPosition` returns the stored value and
            // there is nothing to re-read.
            TimelineView(.animation(minimumInterval: 1.0 / 10.0,
                                    paused: !media.isPlaying)) { _ in
                Text(ExpandedPlayer.time(media.smoothPosition))
                    .font(.system(size: 10, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(media.isPlaying ? 0.62 : 0.4))
                    .animation(Motion.swap, value: media.isPlaying)
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 11)
        .frame(maxHeight: .infinity)
    }
}

/// What the panel shows when nothing is playing: small, quiet and deliberate —
/// not the full player with every field blank.
private struct IdleCard: View {
    var topInset: CGFloat
    var body: some View {
        HStack(spacing: 9) {
            // Chrome tier, both of them. This card predates the type system and
            // carried two opacities of its own, so the glyph and its label read
            // as two different ranks of the same sentence.
            Image(systemName: "music.note")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(ArtworkPalette.chromeTypeAlpha))
            Text("Nothing playing")
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(.white.opacity(ArtworkPalette.chromeTypeAlpha))
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.top, topInset)
    }
}

// MARK: - Pieces

private struct Artwork: View {
    var image: NSImage?
    var palette: ArtworkPalette
    var size: CGFloat
    var radius: CGFloat

    private var mount: (bevel: CGFloat, innerLine: CGFloat) {
        ChromeRules.sleeveMount(size: size)
    }
    private var mountInset: CGFloat { mount.bevel + mount.innerLine }
    private var cast: (opacity: Double, radius: CGFloat, y: CGFloat) {
        ChromeRules.sleeveShadow(size: size)
    }

    var body: some View {
        // Three concentric layers, each radius reduced by the same amount as its
        // frame so the corners stay concentric. The top-lit rim's old job — sell
        // the tile as a physical object — is intact; it has moved off the print
        // and onto the tile's own thickness, where it cannot be washed out by a
        // light cover or cut a seam across a dark one.
        ZStack {
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(LinearGradient(
                    colors: [Color(white: ChromeRules.sleeveBevel.top),
                             Color(white: ChromeRules.sleeveBevel.bottom)],
                    startPoint: .top, endPoint: .bottom))

            // The shadow the bevel casts on the print — and the print's ground
            // where there is no image, which is what the black fill used to be.
            // The darkest of the three tones on purpose: the artwork's only
            // neighbour is darker than any cover, so the failure mode is a
            // contour going invisible, never a seam lighting up.
            RoundedRectangle(cornerRadius: radius - mount.bevel, style: .continuous)
                .fill(.black)
                .frame(width: size - mount.bevel * 2, height: size - mount.bevel * 2)

            face
                .frame(width: size - mountInset * 2, height: size - mountInset * 2)
                .clipShape(.rect(cornerRadius: radius - mountInset, style: .continuous))
        }
        .frame(width: size, height: size)
        // Flatten first. A shadow on a bare stack casts from every layer, and the
        // one that matters here would blur the bevel's own dark bottom into the
        // wash — the tone the mount rests on. `chrome` does the same two lines
        // above its shadow for the same reason.
        .compositingGroup()
        .shadow(color: .black.opacity(cast.opacity), radius: cast.radius, y: cast.y)
    }

    @ViewBuilder
    private var face: some View {
        if let image {
            Image(nsImage: image)
                .resizable()
                .interpolation(.high)
                .aspectRatio(contentMode: .fill)
                // Dark covers vanish against the black shell; lift them just
                // enough to read without washing the artwork out.
                .brightness(palette.luminance < 0.16 ? 0.06 : 0)
        } else {
            LinearGradient(colors: [palette.colors.first ?? .gray,
                                    (palette.colors.dropFirst().first ?? .gray).opacity(0.5),
                                    .black],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .overlay {
                    Image(systemName: "music.note")
                        .font(.system(size: size * 0.3, weight: .medium))
                        .foregroundStyle(.white.opacity(0.62))
                }
        }
    }
}

private struct TransportButton: View {
    var symbol: String
    /// Spoken name. The glyph alone is meaningless to VoiceOver, and the middle
    /// button's meaning flips with playback — the symbol morph is purely visual,
    /// so the state has to be said out loud.
    var label: String
    var diameter: CGFloat
    var glyph: CGFloat
    /// White for transport. The heart is the one control whose colour carries
    /// state rather than decoration.
    var tint: Color = .white
    /// Play/pause only.
    ///
    /// Regular glass over a dark wash is a dark disc, and five of them at one
    /// size read as five equal things — but the panel has exactly one action you
    /// reach for. A brighter rim and a faint fill give it presence without
    /// inventing a new control shape, which is the half of the product bar the
    /// ferrofluid does not carry.
    var prominent: Bool = false
    /// A white wash behind the glyph, and the strength of the rim stroke.
    ///
    /// The mode toggles need these because their three states are three
    /// different KINDS of control, not three brightnesses of one — see
    /// `modeStyle`. Transport keeps the defaults and is unchanged.
    var fill: Double = 0
    var rim: Double = 1
    var action: () -> Void

    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .accessibilityHidden(true)
                .font(.system(size: glyph, weight: .semibold))
                .foregroundStyle(tint)
                // A real morph between play and pause, not a crossfade.
                .contentTransition(.symbolEffect(.replace.magic(fallback: .replace)))
                .frame(width: diameter, height: diameter)
                // The glass belongs to the label, so press and hover deform the
                // same object. Outside the Button it stayed put while the glyph
                // scaled, so the disc and its contents came apart under a press.
                .glassEffect(.regular.interactive(), in: .circle)
                // A lit top edge. Regular glass over a dark wash is a dark disc:
                // in the shipping stills the transport was the LEAST visible
                // thing on the panel, which is the wrong thing to be least
                // visible. A rim catching light from above gives each control an
                // edge and a direction, at the cost of one stroke.
                .overlay {
                    Circle().fill(.white.opacity(prominent ? 0.07 : fill))
                }
                .overlay {
                    Circle().stroke(
                        LinearGradient(colors: [.white.opacity((prominent ? 0.55 : 0.30) * rim),
                                                .white.opacity((prominent ? 0.10 : 0.05) * rim)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: prominent ? 0.9 : 0.6)
                }
                .padding(4)
                .contentShape(.circle)
        }
        // The press state comes from the style. An `onLongPressGesture` layered
        // on top — which is how this was written — consumes the click before the
        // Button ever sees it, so the controls silently did nothing.
        .buttonStyle(PressableCircleStyle())
        .accessibilityLabel(label)
        .scaleEffect(hovering ? 1.07 : 1)
        .animation(Motion.reduceMotion ? .easeOut(duration: 0.12)
                                       : .spring(response: 0.28, dampingFraction: 0.7),
                   value: hovering)
        .onHover { hovering = $0 }
    }
}

private struct PressableCircleStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.88 : 1)
            // Branched like the hover right above it. At damping 0.6 the disc
            // rings past its rest size on every press, which is visibly periodic
            // motion and travel that Reduce Motion is supposed to remove — and
            // this is the one curve in the file that was not already asking.
            .animation(Motion.reduceMotion ? .easeOut(duration: 0.10)
                                           : .spring(response: 0.22, dampingFraction: 0.6),
                       value: configuration.isPressed)
    }
}

// MARK: - HUD

/// Volume / brightness strip shown in the collapsed notch.
private struct HUDStrip: View {
    var controller: NotchController
    var notchWidth: CGFloat

    private var symbol: String {
        switch controller.notification {
        case .didChangeBrightness:
            return "sun.max.fill"
        case .didChangeVolume:
            if controller.hudIsMuted || controller.hudProgress <= 0.001 { return "speaker.slash.fill" }
            if controller.hudProgress < 0.34 { return "speaker.wave.1.fill" }
            if controller.hudProgress < 0.67 { return "speaker.wave.2.fill" }
            return "speaker.wave.3.fill"
        case .none:
            return "circle"
        }
    }

    var body: some View {
        HStack(spacing: 0) {
            Image(systemName: symbol)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.white)
                .contentTransition(.symbolEffect(.replace))
                // Flexible, exactly like the meter on the other side. A fixed 16
                // here made the flanks asymmetric, which slid the reserved cutout
                // span 39pt left of the actual camera for every notch width — so
                // the meter's first 39pt were drawn under the housing.
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.offset(x: 14 * Motion.travel).combined(with: .opacity))

            Color.clear.frame(width: notchWidth)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.18))
                    // Muted drains the meter. Mute is a binary read at a glance
                    // from across a room in the 2.2s the HUD is up; leaving the
                    // big bright element reading full and putting the truth on an
                    // 11pt glyph means the loudest thing on screen is lying.
                    Capsule()
                        .fill(.white)
                        .frame(width: controller.hudIsMuted
                               ? 3
                               : max(3, proxy.size.width * controller.hudProgress))
                        .shadow(color: .white.opacity(controller.hudIsMuted ? 0 : 0.5),
                                radius: 4)
                }
                .frame(height: 4)
                .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(maxWidth: .infinity)
            // Mirrors the icon: this half sits right of the cutout, so it is
            // extruded rightward out of it. The two together read as the strip
            // emerging from behind the camera rather than growing out of it.
            .transition(.offset(x: -14 * Motion.travel).combined(with: .opacity))
        }
        .padding(.horizontal, 11)
        .frame(maxHeight: .infinity)
        .animation(Motion.meter, value: controller.hudProgress)
        .animation(Motion.meter, value: controller.hudIsMuted)
    }
}


/// The content sheet's shear under a live two-finger swipe.
///
/// A leaf for the same reason `MeshField` is one: `swipeLean` is written on
/// every trackpad delta, and reading it from `NotchRootView`'s body would
/// re-evaluate the whole panel per delta. Only this frame invalidates; the
/// content inside is built by the parent and passed through untouched.
///
/// The rule — onset gate, HUD refusal, caps — lives in
/// `SwipeRecogniser.sheetShift`, driven end-to-end by gesturecheck. One term
/// is applied here instead, where no check can reach it: `Motion.travel`,
/// which damps the whole shear to 0.4 under Reduce Motion. It belongs to the
/// view because it is a preference about motion rather than a decision about
/// what the gesture means — but it does mean `sheetShift`'s caps are the
/// ceiling of the shear, not the number that reaches the screen.
private struct SwipeLeanFrame<Content: View>: View {
    var controller: NotchController
    var expanded: Bool
    @ViewBuilder var content: () -> Content

    var body: some View {
        let shift = SwipeRecogniser.sheetShift(
            for: controller.swipeLean,
            expanded: expanded,
            hudShowing: controller.notification.isSome) * Motion.travel
        content()
            .offset(x: shift)
            // Following is jitter absorption; the release back to zero is the
            // one transition worth easing, whichever way the swipe ended.
            .animation(shift == 0 ? Motion.leanRelease : Motion.leanFollow,
                       value: shift)
    }
}

/// The moving colour field, as its own view.
///
/// This is a leaf on purpose. `flowPhase` and `brightness` are mutated sixty
/// times a second, and reading them from `NotchRootView`'s body made the entire
/// panel — artwork, type, transport, glass, shape — re-evaluate every frame.
/// Measured symptom: retracted cost nearly as much CPU as expanded despite being
/// a fifth of the area, because the cost was view-graph work rather than pixels.
/// Keeping the reads down here means only the field invalidates.
private struct MeshField: View {
    var fluid: FerrofluidSim
    var colors: [Color]

    var body: some View {
        // Runs exactly when there is sound. Gating on `media.isPlaying` instead
        // would let the audio-driven phase advance unseen while another app makes
        // noise, then jump when the player resumes.
        TimelineView(.animation(minimumInterval: 1.0 / 60.0,
                                paused: !fluid.hasSound)) { _ in
            // Audio-integrated, never wall-clock: the field advances as far as
            // the music pushes it and stalls when the music stops.
            let t = fluid.flowPhase
            // Two fields at different rates: one large slow sweep, one faster
            // counter-rotating layer on top. A single mesh reads as a gradient
            // wobbling; two reading against each other reads as something moving.
            ZStack {
                MeshGradient(width: 3, height: 3,
                             points: Self.meshPoints(phase: t * 0.78),
                             colors: colors)
                    .blur(radius: 13)

                MeshGradient(width: 3, height: 3,
                             points: Self.meshPoints(phase: -t * 1.19 + 2.4),
                             colors: colors.reversed())
                    .blur(radius: 19)
                    .opacity(0.6)
                    .blendMode(.overlay)
            }
            .saturation(1.6)
            // Intensity is measured loudness. This was `sin(t * 1.3)` — a bare
            // 4.8s sinusoid, the exact "visibly periodic motion" the contract
            // rules out.
            .opacity(0.74 + 0.24 * fluid.brightness)
        }
    }

    static func meshPoints(phase: Double) -> [SIMD2<Float>] {
        let a = Float(sin(phase) * 0.30)
        let b = Float(cos(phase * 0.71) * 0.30)
        let c = Float(sin(phase * 1.37 + 0.9) * 0.27)
        let d = Float(cos(phase * 1.13 + 2.1) * 0.27)
        let e = Float(sin(phase * 0.53 + 1.7) * 0.24)
        let f = Float(cos(phase * 1.61 + 0.3) * 0.24)
        return [
            .init(0, 0),        .init(0.5 + a, 0),        .init(1, 0),
            .init(0, 0.5 + b),  .init(0.5 + c, 0.5 + d),  .init(1, 0.5 - f),
            .init(0, 1),        .init(0.5 - e, 1),        .init(1, 1),
        ]
    }
}
