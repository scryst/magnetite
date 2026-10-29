import SwiftUI
import AppKit

/// One grid for the whole surface, so the elapsed clock's left edge is the artwork's
/// left edge and the remaining clock's right edge is the artist's right edge. The
/// values that decide the panel's height live in `ChromeRules` and are re-exported,
/// because `chromecheck` compiles against that file alone.
enum Grid {
    static let margin = ChromeRules.margin
    static let gutter: CGFloat = 12
    static let art = ChromeRules.art
    static let title = ChromeRules.titleLine
    static let artist = ChromeRules.artistLine
    /// Previous and next.
    static let controls = ChromeRules.controlDiameter
    /// Play/pause: the one control you reach for, and the only one that should look
    /// like it.
    static let primary = ChromeRules.primaryDiameter
    /// Shuffle and repeat: modes, not transport, so they sit smaller and outside the
    /// group, on the right margin.
    static let mode = ChromeRules.modeDiameter
    /// The artwork fills its row exactly, so it is square.
    static let artwork: CGFloat = ChromeRules.art

    /// Gap between the cutout band and the body; it must clear the ferrofluid's reach,
    /// not just the cutout. Lives in `ChromeRules` with the rest of the vertical budget.
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
    /// Where the line stood when a scrub began, so the landing knows which way it moved.
    @ViewState private var seekFrom: Double = 0
    @ViewState private var seekHovering = false
    /// When the running pour started; nil at rest. `pourSettled` is the state the last
    /// pour finished in, so the frame before `onChange` lands already reads as the
    /// pour's first frame rather than its last.
    @ViewState private var pourStart: Date?
    @ViewState private var pourSettled = false

    /// The drag position while scrubbing, otherwise real playback, so you can drag to a
    /// specific second.
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
            TimelineView(.animation(paused: pourStart == nil)) { frame in
                chrome(pour: pour(at: frame.date))
            }
            // Content only; the chrome, trace and playhead are the silhouette and do not move.
            // The ZStack is the container `content`'s transitions need: as the root of
            // `SwipeLeanFrame`'s body, an `if`/`else if` chain has nothing to be inserted into
            // or removed from, so SwiftUI swaps the body and the leaving branch gets no
            // transition.
            SwipeLeanFrame(controller: controller, expanded: expanded) {
                ZStack(alignment: .top) {
                    content
                    miniClock
                    if media.hasTrack {
                        PanelClocks(media: media,
                                    shownPosition: shownPosition,
                                    scrubbing: scrubbing,
                                    band: band,
                                    notchWidth: controller.notchSize.width,
                                    width: size.width,
                                    visible: expanded)
                    }
                }
            }
                .frame(width: size.width, height: size.height, alignment: .top)
                .clipShape(shape)
            // Outside the lean frame: the slot it follows already carries the lean.
            ZStack(alignment: .topLeading) {
                if let slot = coverSlot {
                    CoverLayer(media: media)
                        .matchedGeometryEffect(id: slot, in: glass, isSource: false)
                        .transition(.scale(scale: 0.84).combined(with: .opacity))
                }
            }
                .frame(width: size.width, height: size.height, alignment: .topLeading)
                .clipShape(shape)
                .allowsHitTesting(false)
            // Drawn whenever there is a track, so it does not fade in on every open; it
            // follows the silhouette as it morphs. It needs a shell wide enough to carry it (in
            // Focus Mode the retracted shell is the cutout and the line would show as a stub
            // behind the housing). Hidden, never removed: a removed line is re-inserted at the
            // open panel's bottom edge while the shell is still growing from the notch.
            if media.hasTrack {
                ZStack(alignment: .top) {
                    // Outside the timeline: the unplayed remainder never changes. Drawn first so
                    // it sits behind the fill.
                    progressTrack
                    // Display-rate so the trace glides instead of stepping with the 1 Hz poll. 15 Hz,
                    // not 60: on a four-minute track it moves 0.024 pt per frame at 60 Hz against a
                    // 0.5 pt device pixel, and still stays sub-pixel smooth at 15 Hz.
                    TimelineView(.animation(minimumInterval: 1.0 / 15.0,
                                            paused: !media.isPlaying || scrubbing || !trackDrawn)) { _ in
                        // The tip sits inside the timeline with its line, or it would step at the 1 Hz poll.
                        ZStack {
                            progressEdge
                            playhead
                        }
                    }
                }
                // On the edge from the first frame of a morph: it is the edge, so it travels
                // with it. Held back until the pour settled, it arrived late.
                .opacity(trackDrawn ? 1 : 0)
            }
            // The tip is not gated on expansion (that would fade the dot in on every open);
            // width carries the state. The seek strip stays gated so a collapsed notch is never
            // a drag target, and on a duration because `seek(toFraction:)` ignores calls
            // without one: for a live stream the strip would be a drag target and VoiceOver
            // element that do nothing.
            if expanded, media.hasTrack, media.duration > 0 { seekStrip }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .animation(expanded ? Motion.expand : Motion.collapse, value: expanded)
        .onAppear { pourSettled = expanded }
        .onChange(of: expanded) { _, open in
            let start = Date.now
            pourStart = start
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(Pour.timeline(opening: open).duration))
                guard pourStart == start else { return }
                pourStart = nil
                pourSettled = open
            }
        }
        .animation(Motion.swap, value: controller.isMiniPlayerShown)
        .animation(Motion.swap, value: controller.notification)
        .animation(Motion.track, value: media.trackToken)
        // Losing the last track must not be a hard cut: arrival uses the track curve,
        // departure is fully damped.
        .animation(media.hasTrack ? Motion.track : Motion.collapse, value: media.hasTrack)
        .opacity(controller.isVisible ? 1 : 0)
    }

    /// Where the one sleeve sits: the panel's, the mini player's, or nowhere.
    private var coverSlot: CoverSlot? {
        guard media.hasTrack, !controller.notification.isSome else { return nil }
        if expanded { return .open }
        return controller.isMiniPlayerShown ? .mini : nil
    }

    /// Whether the progress line is drawing the bottom edge, so the rim knows whether it
    /// is already taken. One condition in one place, or both would draw it or neither.
    private var trackDrawn: Bool {
        ChromeRules.drawsTrace(hasTrack: media.hasTrack, hasShell: hasShellForTrace, width: traceWidth)
    }

    private var hasShellForTrace: Bool {
        expanded || controller.isMiniPlayerShown || controller.notification.isSome
    }

    private var shape: NotchShape { shape(sag: 0) }

    private func shape(sag: CGFloat) -> NotchShape {
        var s = NotchShape(width: size.width,
                           height: size.height,
                           topCornerRadius: controller.topCornerRadius,
                           bottomCornerRadius: controller.bottomCornerRadius,
                           style: controller.style)
        s.sag = sag
        return s
    }

    private var tint: Color { media.palette.colors.first ?? .accentColor }
    /// The played line: the cover's most vivid colour at full brightness, so the line
    /// belongs to the record rather than being a white rule, and still stands off the
    /// darker wash made of the same colours. A grey sleeve has no hue to lend: white.
    private var lineTint: Color {
        let vivid = media.palette.colors
            .compactMap { NSColor($0).usingColorSpace(.sRGB) }
            .max { $0.saturationComponent * $0.brightnessComponent
                   < $1.saturationComponent * $1.brightnessComponent }
        // A greyscale sleeve's palette tints its greys up to 0.16 in whatever hue the
        // noise leans, so below 0.2 the sleeve has no colour to lend and the floor
        // below would invent one (a black-and-white cover drew a green line).
        guard let vivid, vivid.saturationComponent > 0.2 else { return .white }
        return Color(hue: vivid.hueComponent,
                     saturation: min(0.7, max(0.45, vivid.saturationComponent)),
                     brightness: 1)
    }

    private func pour(at date: Date) -> Pour {
        let timeline = Pour.timeline(opening: expanded)
        guard let start = pourStart else {
            return expanded == pourSettled ? .rest(open: expanded) : timeline.value(time: 0)
        }
        let t = date.timeIntervalSince(start)
        return t >= timeline.duration ? .rest(open: expanded) : timeline.value(time: t)
    }

    // MARK: Chrome

    /// Black at the cutout, tinted Liquid Glass elsewhere. Glass around the camera
    /// housing would catch the wallpaper either side of the bezel and expose the housing
    /// as a black bar, so a radial falloff keeps a black core at the cutout.
    private func chrome(pour: Pour) -> some View {
        let shape = shape(sag: pour.sag)
        return ZStack(alignment: .top) {
            shape.fill(.black)

            // This frame establishes the coordinate space the masks resolve in; without it the
            // oversized `coverWash` frame becomes the reference.
            // Taller than the shell by the deepest sag, so the colour reaches the edge where
            // it hangs below its corners; the outer frame keeps the layout at `size`.
            glassLayer(shape)
                .frame(width: size.width, height: size.height + 20, alignment: .top)
                .frame(width: size.width, height: size.height, alignment: .top)
                .allowsHitTesting(false)
                // A bare notch is black: unscoped, the tint rides the spring's tail down to the
                // cutout and leaves a ring round the camera.
                .animation(shellTinted ? .easeOut(duration: 0.12) : .easeOut(duration: 0.16)) {
                    $0.opacity(shellTinted ? 1 : 0)
                }

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
            // The rim also acknowledges the pointer: for the whole hover delay the notch would
            // otherwise give back nothing. It draws the silhouette the track does not: the
            // track owns the bottom edge and both corners, so the rim's bottom stop is out
            // (it would composite under the track). It returns only for the idle card, which
            // has no track, and stays out when retracted.
            shape.stroke(
                LinearGradient(
                    stops: ChromeRules.rimStops(
                        expanded: expanded,
                        hovering: controller.hoverWillOpen,
                        // The resting stroke, not the live `traceWidth`, so the rim does not slide as the
                        // line swells.
                        traceStrokeWidth: trackDrawn ? ChromeRules.traceStroke : nil,
                        height: size.height,
                        bottomRadius: controller.bottomCornerRadius)
                        .map { .init(color: .white.opacity($0.alpha),
                                     location: $0.location) },
                    startPoint: .top, endPoint: .bottom),
                lineWidth: 0.5)
                // The gradient would otherwise resolve in the hosting view's box rather than the
                // shape's. `.top` matters: centred, the box floats below the silhouette.
                .frame(width: size.width, height: size.height)
        }
        .animation(Motion.meter, value: controller.isMouseInside)
        .compositingGroup()
        .shadow(color: .black.opacity(expanded ? 0.5 : 0),
                radius: expanded ? 28 : 0, y: expanded ? 14 : 0)
    }

    /// Whether the shell shows anything beyond the cutout: open, the mini player, or a
    /// volume or brightness HUD. Otherwise it is the notch, and black.
    private var shellTinted: Bool {
        expanded || controller.notification.isSome
            || (controller.isMiniPlayerShown && media.hasTrack)
    }

    private func glassLayer(_ shape: NotchShape) -> some View {
        Color.clear
            .glassEffect(.regular.tint(tint.opacity(0.3)), in: shape)
            .overlay { coverWash }
            .compositingGroup()
            .mask(shape)
    }

    /// Frames per second for the colour field. Closed and settled it shows through a
    /// 0.62 scrim in a band a couple of dozen points tall, where 30 is indistinguishable
    /// and half the work; it runs all day, so that half is most of the app's idle cost.
    private var fieldRate: Double { expanded || pourStart != nil ? 60 : 30 }

    /// The palette's brightest colour, which a hit throws across the card.
    private var bloomColor: Color {
        let p = media.palette.colors.isEmpty ? ArtworkPalette.fallback.colors : media.palette.colors
        return p.max { a, b in
            let x = NSColor(a).usingColorSpace(.sRGB), y = NSColor(b).usingColorSpace(.sRGB)
            return (x?.brightnessComponent ?? 0) < (y?.brightnessComponent ?? 0)
        } ?? p[0]
    }

    private var meshColors: [Color] {
        let p = media.palette.colors.isEmpty
            ? ArtworkPalette.fallback.colors : media.palette.colors
        func c(_ i: Int) -> Color { p[i % p.count] }
        // A black-and-white sleeve's palette is light, not hue, ordered brightest first.
        // Only the centre point, the one that wanders furthest, carries the highlight, so
        // it reads as a pool of light moving over dark metal; spread over the corners as
        // well, it lit the whole card evenly and nothing seemed to move.
        if media.palette.monochrome {
            return [c(3), c(1), c(3),
                    c(1), c(0), c(2),
                    c(3), c(2), c(3)]
        }
        return [c(0), c(1), c(2),
                c(3), c(0), c(1),
                c(2), c(3), c(0)]
    }

    /// A living colour field built from the song's own palette. The mesh's control
    /// points drift on slow, mutually-prime sines so it never visibly loops, and only
    /// while a track plays.
    ///
    /// The blurred cover is kept: at `blur(46)` it lays down close to the cover's global
    /// mean, and `glassEffect` alone is tinted with a single palette colour. The opacity
    /// below is 0.74 + 0.24 x loudness, so a paused panel shows the weakest colour.
    @ViewBuilder
    private var coverWash: some View {
        if media.hasTrack {
            ZStack {
                if let art = media.artwork {
                    // A black-and-white sleeve's only identity is where its light falls,
                    // which a blur flattens to grey; contrast brings the layout back.
                    CoverField(fluid: fluid, art: art, size: size, rate: fieldRate)
                        .contrast(media.palette.monochrome ? 1.6 : 1)
                }

                // Over the cover the mesh is the motion, not the colour; alone it is both.
                // A black-and-white sleeve blurs to one dark sheet, so there the mesh
                // carries the sleeve's own light and is most of what shows.
                MeshField(fluid: fluid, colors: meshColors, rate: fieldRate)
                    .opacity(media.artwork == nil ? 1 : media.palette.monochrome ? 0.9 : 0.42)

                if expanded {
                    HitBloom(fluid: fluid, color: bloomColor, size: size)
                }
            }
            // A scrim keeps the colour rich but dark enough for white type; additive
            // blending blows the field out. See `ArtworkPalette.scrimAlpha`.
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
            .overlay { Grain() }
        }
    }


    /// Where along the path a horizontal position falls. `.trim` parameterises by arc
    /// length but the gesture is linear in x, and the bottom corners are quadratic
    /// quarter-turns about 1.62r long for r of horizontal travel, so a time fraction
    /// fed straight to `.trim` runs the handle up to 8.7% slow.
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
        // The trace is an inset copy of the silhouette, so these are the inset path's
        // lengths: the corner shrinks with the frame, not the shell's own radius.
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

    private var edgeTrim: Double {
        edgeFraction(atX: CGFloat(shownFraction) * size.width)
    }

    /// Grab handle for the progress trace. The trace is a poor hit target, so the
    /// gesture lives on a taller invisible strip at the panel's bottom edge.
    private var seekStrip: some View {
        GeometryReader { proxy in
            let w = size.width
            Color.clear
                .contentShape(.rect)
                // Readable and settable without a pointer.
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
                            let f = min(max(g.location.x / max(w, 1), 0), 1)
                            if scrubbing {
                                scrubFraction = f
                            } else {
                                // First contact: the head travels to the pointer and the
                                // clocks roll there, rather than both teleporting.
                                seekFrom = shownFraction
                                var t = Transaction(animation: Motion.seek)
                                t.rollsClocks = true
                                withTransaction(t) {
                                    scrubbing = true
                                    scrubFraction = f
                                }
                            }
                            // The ink follows the playhead, harder than a hover.
                            fluid.setPointer(rim: Double(scrubFraction), strength: 1.5)
                        }
                        .onEnded { g in
                            // Release the magnet explicitly: nothing else clears the scrub's stronger pull,
                            // so `isSettled` would never return and the renderer never pause.
                            fluid.setPointer(rim: nil)
                            let f = min(max(g.location.x / max(w, 1), 0), 1)
                            media.seek(toFraction: Double(f))
                            scrubbing = false
                            // Landing is an event: the ink heaves the way the song moved.
                            let moved = Double(f) - seekFrom
                            if abs(moved) > 0.01 {
                                fluid.surge(min(0.9, 0.45 + abs(moved)),
                                            direction: moved > 0 ? 1 : -1)
                            }
                        }
                )
                .onHover { seekHovering = $0 }
                // Sized to clear the transport: this strip is topmost, so every point it covers
                // is one the controls under it never see.
                .frame(width: w, height: ChromeRules.seekStripHeight)
                .position(x: proxy.size.width / 2,
                          y: size.height - ChromeRules.seekStripCentre)
        }
        .frame(width: size.width, height: size.height)
        // SwiftUI never delivers `onEnded` to a gesture whose view is removed mid-drag, and
        // this strip is conditional (a screen lock or scripted collapse removes it).
        // Without this reset `scrubbing` stays true and pins the trace, clocks and
        // pointer to the stale drag.
        .onDisappear {
            if scrubbing {
                scrubbing = false
                fluid.setPointer(rim: nil)
            }
            seekHovering = false
        }
    }

    /// Grab handle at the playhead: a true circle centred on the line's end, drawn by a
    /// shape that animates with the edge, so it never leaves the line mid-morph. Retracted
    /// it is the line's own width, so the peek and the panel end the line the same way.
    /// Hover and grab grow the dot, never the line.
    private var playhead: some View {
        EdgeDot(edge: traceEdge,
                at: max(0.0001, edgeTrim),
                diameter: expanded ? (scrubbing ? 14 : (seekHovering ? 11 : 7)) : traceWidth)
            .fill(expanded ? lineTint.mix(with: .white, by: 0.55) : lineTint)
            .animation(Motion.seek, value: seekHovering)
            .animation(Motion.seek, value: scrubbing)
            .allowsHitTesting(false)
    }

    /// Playback progress along the shell's own bottom edge, with one width so the
    /// stroke and the inset that keeps it inside the shell cannot disagree.
    /// Retracted, the line has only the sliver between the cutout and the band, so it
    /// is sized to that rather than pushed down until its top clears.
    private var traceWidth: CGFloat {
        let full = ChromeRules.traceStroke
        guard !expanded else { return full }
        return ChromeRules.retractedTraceWidth(shellHeight: size.height,
                                               cutoutHeight: controller.notchSize.height,
                                               expandedWidth: full,
                                               hasNotch: controller.style == .notch)
    }

    /// Half the stroke in both states; see `ChromeRules.traceInset`.
    private var traceInset: CGFloat { ChromeRules.traceInset(strokeWidth: traceWidth) }

    /// The unplayed remainder of the line. Without it the bottom edge is stroked only as
    /// far as the track has played and the playhead starts as a detached speck. Same
    /// path, inset, width and gate as the fill, from `traceWidth`/`traceInset`.
    private var progressTrack: some View {
        NotchBottomEdge(width: size.width,
                        height: size.height,
                        bottomCornerRadius: controller.bottomCornerRadius,
                        inset: traceInset)
            .stroke(.white.opacity(0.2),
                    style: StrokeStyle(lineWidth: traceWidth, lineCap: .round))
            .animation(Motion.seek, value: scrubbing)
            .animation(Motion.seek, value: seekHovering)
            .allowsHitTesting(false)
    }

    private var traceEdge: NotchBottomEdge {
        NotchBottomEdge(width: size.width,
                        height: size.height,
                        bottomCornerRadius: controller.bottomCornerRadius,
                        inset: traceInset)
    }

    /// The played line: one stroke fading in smoothly from where the track began to full
    /// strength at the playhead. One gradient, not segments, which stepped visibly. No
    /// glow: a halo round the head read as an effect laid on top.
    private var progressEdge: some View {
        let e = max(0.0001, edgeTrim)
        let headX = traceEdge.path(in: CGRect(origin: .zero, size: size))
            .trimmedPath(from: 0, to: e).currentPoint?.x ?? 0
        let reach = max(0.001, headX / max(1, size.width))
        return ZStack {
            traceEdge
                .trim(from: 0, to: e)
                .stroke(LinearGradient(colors: [lineTint.opacity(0.25), lineTint],
                                       startPoint: .leading,
                                       endPoint: UnitPoint(x: reach, y: 0.5)),
                        style: StrokeStyle(lineWidth: traceWidth, lineCap: .round))
        }
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
                               fluid: fluid,
                               showsLyrics: controller.hasLyrics)
                    // Staged behind the shell on the way in and unstaged on the way out, so the
                    // content leaves first and the shell closes on nothing.
                    .transition(.asymmetric(
                        insertion: .opacity
                            .combined(with: .offset(y: 6 * Motion.travel))
                            .animation(Motion.content.delay(Pour.contentLag)),
                        removal: .opacity
                            .combined(with: .offset(y: -10 * Motion.travel))
                            .animation(Motion.content.speed(1.6))))
            } else {
                IdleCard(topInset: band)
                    .transition(.asymmetric(
                        insertion: .offset(y: 10 * Motion.travel)
                            .combined(with: .opacity)
                            .animation(Motion.content.delay(Pour.contentLag + 0.03)),
                        removal: .offset(y: 6 * Motion.travel)
                            .combined(with: .opacity)
                            .animation(Motion.content.speed(1.7))))
            }
        } else if controller.notification.isSome {
            HUDStrip(controller: controller, notchWidth: controller.notchSize.width)
                // Opacity only at this level: a `.scale` anchors on the view's centre, which here
                // is the camera cutout. `HUDStrip` gives each half a directional entrance.
                .transition(.opacity.animation(Motion.swap))
        } else if controller.isMiniPlayerShown, media.hasTrack {
            CollapsedActivity(layer: .artwork,
                              media: media,
                              notchWidth: controller.notchSize.width,
                              glass: glass)
                // On the shell's own vocabulary, so a peek cleared and re-shown retargets instead
                // of restarting a fixed fade.
                .transition(.asymmetric(
                    insertion: .scale(scale: 0.84, anchor: .center)
                        .combined(with: .opacity)
                        .animation(Motion.swap),
                    removal: .scale(scale: 0.90, anchor: .center)
                        .combined(with: .opacity)
                        .animation(Motion.collapse.speed(1.3))))
        }
    }

    /// The mini player's elapsed clock, on its own layer so it can leave and arrive on
    /// its own timing: inside the cover's container it would share that container's
    /// centre-anchored scale and slide toward the camera. Opacity only; gone before the
    /// panel's content shows on open, back once that content has left on close.
    @ViewBuilder
    private var miniClock: some View {
        if !expanded, !controller.notification.isSome,
           controller.isMiniPlayerShown, media.hasTrack {
            CollapsedActivity(layer: .clock,
                              media: media,
                              notchWidth: controller.notchSize.width,
                              glass: glass)
                .transition(.asymmetric(
                    insertion: .opacity.animation(Motion.miniClockIn),
                    removal: .opacity.animation(Motion.miniClockOut)))
        }
    }

}

// MARK: - Expanded player

private struct ExpandedPlayer: View {
    var media: MediaManager
    /// The scrub position while dragging, so the clocks can land on a specific second.
    var shownPosition: Double
    /// Whether a scrub is in flight: the one time `shownPosition` outranks the live clock.
    var scrubbing: Bool
    var band: CGFloat
    /// Measured width of the cutout (`tools/notchruler`); the band row reserves exactly
    /// this span so nothing drifts under the camera.
    var notchWidth: CGFloat
    var panelWidth: CGFloat
    /// Shared with `CollapsedActivity` so the artwork morphs between its two sizes
    /// instead of crossfading.
    var glass: Namespace.ID
    var fluid: FerrofluidSim
    /// Whether the panel was sized with the lyrics stage. The lines themselves may still
    /// be on their way for a new track.
    var showsLyrics: Bool


    /// A press is an event, so it goes in the same door as a drum hit: the surface
    /// heaves and the rim glow blooms. No haptic here; `NotchGestures` ticks because a
    /// swipe that worked and one that missed feel identical, whereas a button lights.
    private func strike(_ strength: Double, direction: Double = 0) {
        fluid.surge(strength, direction: direction)
    }

    /// Both mode slots or neither (`ChromeRules.modeSlots`). A mode Spotify refuses in
    /// the current context still draws, styled as unpressable.
    private var modeSlots: (shuffle: Bool, `repeat`: Bool) {
        ChromeRules.modeSlots(shuffling: media.shuffling, repeating: media.repeating)
    }

    /// The three-state rule is `ChromeRules.modeStyle`; this turns it into a colour.
    private func modeStyle(on: Bool, blocked: Bool)
        -> (tint: Color, fill: Double, rim: Double) {
        let s = ChromeRules.modeStyle(on: on, blocked: blocked)
        return (.white.opacity(s.glyph), s.fill, s.rim)
    }

    private var shuffleStyle: (tint: Color, fill: Double, rim: Double) {
        modeStyle(on: media.shuffling ?? false, blocked: media.shuffleBlocked)
    }

    private var repeatStyle: (tint: Color, fill: Double, rim: Double) {
        modeStyle(on: media.repeating ?? false, blocked: media.repeatBlocked)
    }

    /// Title, artist and the library heart. The heart sits here, not in the transport
    /// row, which is centred on the panel: an extra disc there would shift the whole
    /// group.
    private var trackLine: some View {
        HStack(alignment: .center, spacing: 6) {
            VStack(alignment: .leading, spacing: 0) {
                    MarqueeText(text: media.title,
                                font: .system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(height: Grid.title)
                        // Optical, not geometric: centring the line box leaves the cap line 3.5 pt below
                        // the artwork's top edge and the stems 1 pt right of the disc row. Type beside an
                        // image is measured against the image's edges.
                        .offset(y: -3.5)
                        .padding(.leading, -1)
                        // The words arrive with the song; the artist follows the title by a beat.
                        .id(media.trackToken)
                        .transition(.asymmetric(
                            insertion: .offset(y: 8 * Motion.travel)
                                .combined(with: .opacity),
                            removal: .offset(y: -6 * Motion.travel)
                                .combined(with: .opacity)))

                    ArtistLine(media: media)
                        .foregroundStyle(.white.opacity(0.62))
                        .id(media.trackToken)
                        .transition(.asymmetric(
                            insertion: .offset(y: 8 * Motion.travel)
                                .combined(with: .opacity)
                                .animation(Motion.content.delay(0.06)),
                            removal: .offset(y: -6 * Motion.travel)
                                .combined(with: .opacity)))
                        .frame(height: Grid.artist)
                    }

                    Spacer(minLength: 0)

                    // Only where the player can answer: without a Spotify connection there is no
                    // heart rather than one that lies.
                    if let liked = media.liked {
                        TransportButton(symbol: liked ? "heart.fill" : "heart",
                                        label: liked ? "Remove from Favourites"
                                                     : "Add to Favourites",
                                        diameter: Grid.mode, glyph: 12,
                                        tint: liked ? .pink : .white.opacity(0.6)) {
                            media.toggleLike()
                            // Heavier than a skip: the one press here that changes something outside this app.
                            strike(liked ? 0.7 : 1.15)
                        }
                        .transition(.scale(scale: 0.4).combined(with: .opacity))
                        // One place on every track, in repeat's column: pushed out by its padding ring
                        // so the disc, not the ring, meets the margin, as the mode cluster's does.
                        .offset(x: ChromeRules.controlInset)
                    }
        }
        .frame(height: Grid.title + Grid.artist)
    }

    /// Previous, play, next, and nothing else. Play sits on the panel's centre line,
    /// which it can only do while this group is symmetric about play; three transport
    /// controls are symmetric whatever the player answers (`ChromeRules.playOffCentre`,
    /// asserted by chromecheck). The column begins after the sleeve and the gutter, so
    /// the offset takes half of those back.
    private var transportTriad: some View {
        // Zero spacing plus 4 pt of padding inside each button: the hit circles touch.
        HStack(spacing: 0) {
            TransportButton(symbol: "backward.fill",
                            label: "Previous Track",
                            diameter: Grid.controls, glyph: 13) {
                media.previous()
                strike(0.8, direction: -1)
            }
            TransportButton(symbol: media.isPlaying ? "pause.fill" : "play.fill",
                            label: media.isPlaying ? "Pause" : "Play",
                            diameter: Grid.primary, glyph: 19,
                            prominent: true) {
                // No strike: play's real answer is the music, and slamming the reservoir first
                // would announce the change before it happens. The swipe does the same.
                media.playPause()
            }
            TransportButton(symbol: "forward.fill",
                            label: "Next Track",
                            diameter: Grid.controls, glyph: 13) {
                media.next()
                strike(0.8, direction: 1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .center)
        .offset(x: -(Grid.artwork + Grid.gutter) / 2)
    }

    /// Shuffle and repeat, as one group on the panel's right margin. Bracketing the
    /// transport would reserve 44 pt on the sleeve's side of the centre line for
    /// glyphs that are not transport. Dimmed rather than absent when off, since a mode
    /// you cannot see is one you forget you left on. Both slots or neither
    /// (`ChromeRules.modeSlots`); an unanswered slot is blank space, not a control that
    /// claims to do something.
    private var modeCluster: some View {
        HStack(spacing: 0) {
            if modeSlots.shuffle, let shuffling = media.shuffling {
                TransportButton(symbol: "shuffle",
                                label: media.shuffleBlocked
                                    ? "Shuffle Not Available"
                                    : shuffling ? "Shuffle On" : "Shuffle Off",
                                diameter: Grid.mode, glyph: 10,
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
                                    ? "Repeat Not Available"
                                    : repeating ? "Repeat On" : "Repeat Off",
                                diameter: Grid.mode, glyph: 10,
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
        // Out by the padding ring so the disc lands on the sleeve's margin.
        .offset(x: ChromeRules.controlInset)
    }

    var body: some View {
        VStack(spacing: 0) {
            // `PanelClocks` draws the band's clocks on their own layer; this keeps their row.
            Color.clear.frame(height: band)
            Spacer(minLength: Grid.bandGap)

            HStack(alignment: .top, spacing: Grid.gutter) {
                // The sleeve's place and its gestures. The sleeve itself is `CoverLayer`, one
                // view for the mini player and the panel, so it travels instead of cross-fading.
                Color.clear
                    .contentShape(.rect(cornerRadius: 12, style: .continuous))
                    .matchedGeometryEffect(id: CoverSlot.open, in: glass)
                    .frame(width: Grid.artwork, height: Grid.art)
                    // The sleeve is the track, so pressing it opens the track in the player.
                    .onTapGesture {
                        media.openInPlayer()
                        strike(1)
                    }
                    .accessibilityAddTraits(.isButton)
                    .accessibilityLabel(Text(media.source.map { "Open in \($0.displayName)" }
                                             ?? "Open in player"))
                    .help(media.source.map { "Open in \($0.displayName)" } ?? "Open in player")
                    // Right-click rather than another button; this row cannot afford more chrome.
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

                VStack(alignment: .leading, spacing: 0) {
                    trackLine

                    Spacer(minLength: 0)

                    // Two groups on one line, only one of them centred. A single row cannot centre
                    // its middle child and pin its last to the margin, so they are overlaid.
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

            if showsLyrics {
                LyricsStage(media: media, shownPosition: shownPosition, scrubbing: scrubbing)
                    .padding(.top, ChromeRules.lyricsGap)
                    // Arrives as the shell grows to hold it, after the shell has started.
                    .transition(.asymmetric(
                        insertion: .opacity.animation(Motion.content.delay(Pour.contentLag + 0.05)),
                        removal: .opacity.animation(Motion.content.speed(1.8))))
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

// MARK: - Lyrics

/// The song's words under the player, in time with it. The sung line sits bright at the
/// stage's top edge with the next one dim beneath; when the song reaches a line the
/// whole column rolls up, each line a beat behind the one above, and the line that
/// was sung dissolves into the top edge. Read from the same position as the clocks
/// and the trace, so it follows seeks, scrubs, pauses and skips without its own state.
private struct LyricsStage: View {
    var media: MediaManager
    var shownPosition: Double
    var scrubbing: Bool

    var body: some View {
        // 20 Hz decides which line is up to a 50 ms step, inside the 0.25 s lead.
        TimelineView(.animation(minimumInterval: 1.0 / 20.0,
                                paused: !media.isPlaying || scrubbing || media.lyrics == nil)) { _ in
            let pos = scrubbing ? shownPosition : media.smoothPosition
            ZStack(alignment: .topLeading) {
                if let lyrics = media.lyrics {
                    let index = lyrics.index(at: pos)
                    LyricsColumn(lines: lyrics.lines,
                                 current: index,
                                 // Quantised so the column redraws only when a dot visibly moves.
                                 countIn: lyrics.breakProgress(at: pos, index: index)
                                     .map { ($0 * 60).rounded() / 60 },
                                 playing: media.isPlaying || scrubbing)
                        .equatable()
                        .id(media.trackToken)
                        .transition(.opacity.animation(Motion.content))
                }
            }
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .frame(height: ChromeRules.lyricsStage, alignment: .top)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Lyrics")
            .accessibilityValue(media.lyrics.map { $0.lines[$0.index(at: pos)].text } ?? "")
        }
        // Lines enter and leave through soft edges, never a hard clip.
        .mask {
            LinearGradient(stops: [.init(color: .clear, location: 0),
                                   .init(color: .black, location: LyricsColumn.anchor / ChromeRules.lyricsStage),
                                   .init(color: .black, location: 0.78),
                                   .init(color: .clear, location: 1)],
                           startPoint: .top, endPoint: .bottom)
        }
        .allowsHitTesting(false)
    }
}

private struct LyricsColumn: View, Equatable {
    var lines: [SyncedLyrics.Line]
    var current: Int
    var countIn: Double?
    var playing: Bool

    /// Measured line heights: lines wrap, so where the column must sit depends on them.
    @ViewState private var heights: [Int: CGFloat] = [:]

    /// Where the sung line's top sits in the stage: below the top fade.
    static let anchor: CGFloat = 8
    static let spacing: CGFloat = 7
    static let font = Font.system(size: 18, weight: .bold)
    /// One unwrapped line, for lines not yet measured.
    static let estimate: CGFloat = 22

    static func == (a: Self, b: Self) -> Bool {
        a.current == b.current && a.countIn == b.countIn && a.playing == b.playing
            && a.lines == b.lines
    }

    private func top(of index: Int) -> CGFloat {
        (0..<index).reduce(0) { $0 + (heights[$1] ?? Self.estimate) + Self.spacing }
    }

    /// The roll. Critically damped, so it never overshoots and never visibly springs;
    /// each line further down leaves a beat later, so the column moves as a ribbon
    /// rather than a block.
    private func roll(_ i: Int) -> Animation {
        if Motion.reduceMotion { return .easeOut(duration: 0.2) }
        let beat = Double(min(max(i - current + 1, 0), 4)) * 0.045
        return .spring(response: 0.62, dampingFraction: 1).delay(beat)
    }

    var body: some View {
        let shift = Self.anchor - top(of: current)
        VStack(alignment: .leading, spacing: Self.spacing) {
            ForEach(lines.indices, id: \.self) { i in
                row(i)
                    .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { h in
                        if heights[i] != h { heights[i] = h }
                    }
                    .offset(y: shift)
                    // Only a change of line rolls. A measurement landing moves the column
                    // unanimated, and before every line is measured nothing is drawn: opened
                    // mid-song, estimated heights would otherwise slide the column into place.
                    .animation(roll(i), value: current)
            }
        }
        .opacity(heights.count == lines.count ? 1 : 0)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .frame(height: ChromeRules.lyricsStage, alignment: .top)
    }

    @ViewBuilder
    private func row(_ i: Int) -> some View {
        let d = i - current
        // Sung: full white, dimmed only while paused so a pause reads here too. Next: a
        // step down, then fading out of reach. Past: gone as it rolls into the top edge.
        let opacity: Double = d == 0 ? (playing ? 1 : 0.62)
            : d == 1 ? 0.3 : d == 2 ? 0.12 : 0
        Group {
            if lines[i].isBreak {
                countInDots(lit: d == 0 ? (countIn ?? 0) : 0)
                    .frame(height: Self.estimate, alignment: .leading)
            } else {
                Text(lines[i].text)
                    .font(Self.font)
                    .tracking(-0.3)
                    .foregroundStyle(.white)
                    // The sung line may take two rows and shrinks a little before it would
                    // truncate. Lines still to come take one: a second row only reached the
                    // stage's bottom fade, so it showed as a line cut in half.
                    .lineLimit(d == 0 ? 2 : 1)
                    .minimumScaleFactor(0.8)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .opacity(opacity)
        .scaleEffect(d == 0 ? 1 : 0.94, anchor: .leading)
        .blur(radius: d < 0 ? 3 : d >= 2 ? 1.2 : 0)
        .animation(roll(i), value: playing)
    }

    /// An instrumental break as three dots that light in turn across the break's
    /// length, so it reads as a count-in to the next line. Driven by the song's
    /// position, never a clock, so it cannot pulse.
    private func countInDots(lit: Double) -> some View {
        HStack(spacing: 6) {
            ForEach(0..<3, id: \.self) { k in
                let f = min(max(lit * 3 - Double(k), 0), 1)
                Circle()
                    .fill(.white)
                    .frame(width: 7, height: 7)
                    .opacity(0.28 + 0.72 * f)
                    .scaleEffect(0.8 + 0.2 * f)
            }
        }
        .animation(.easeOut(duration: 0.25), value: lit)
    }
}

// MARK: - Pour

/// The ink leaving the cutout ahead of the shell. Drawn through the same blur and
/// threshold as the pool and joined to the cutout, so it reads as the pool's own neck
/// with a weight at its tip, never as a drop: the neck is wider than the blur can
/// sever, and it shrinks back with the tip rather than letting go of it.
enum CoverSlot: Hashable { case open, mini }

/// The one sleeve, sized by whichever `CoverSlot` it follows. Its corner and shadow are
/// read from the frame it has been given, so they grow with it.
private struct CoverLayer: View {
    var media: MediaManager

    var body: some View {
        GeometryReader { g in
            let side = g.size.width
            // 5.5 pt on the 19 pt mini sleeve, 12 on the panel's.
            let t = min(1, max(0, (side - 19) / (Grid.artwork - 19)))
            ZStack {
                Artwork(image: media.artwork, palette: media.palette,
                        size: side, radius: 5.5 + 6.5 * t)
                    .id(media.trackToken)
                    // A card lifted off a card: the old sleeve grows and dissolves while the new
                    // one comes up. The removal runs faster, or the covers ghost through each other.
                    .transition(.asymmetric(
                        insertion: .scale(scale: 1 - 0.14 * Motion.travel)
                            .combined(with: .opacity),
                        removal: .scale(scale: 1 + 0.10 * Motion.travel)
                            .combined(with: .opacity)
                            .animation(Motion.track.speed(1.6))))
            }
            .frame(width: side, height: g.size.height)
        }
    }
}

// MARK: - Collapsed live activity

/// Artwork and elapsed time either side of the cutout; nothing sits where the
/// camera is.
private struct CollapsedActivity: View {
    /// Drawn twice on one layout, once for the cover and once for the clock, because
    /// they exit differently: the cover morphs into the panel's, while the clock must
    /// be gone before the panel's own clock arrives, or the time reads twice.
    enum Layer { case artwork, clock }
    var layer: Layer
    var media: MediaManager
    var notchWidth: CGFloat
    var glass: Namespace.ID

    var body: some View {
        HStack(spacing: 0) {
            Group {
                if layer == .artwork {
                    Color.clear
                        .matchedGeometryEffect(id: CoverSlot.mini, in: glass)
                        .frame(width: 19, height: 19)
                } else {
                    Color.clear.frame(width: 19, height: 19)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Color.clear.frame(width: notchWidth)

            // The elapsed clock balances the artwork; an empty flank reads as something
            // failing to load. Not gated on `isPlaying`: a paused clock still says where you
            // left off. Read from the interpolated position at 10 Hz: `media.position` changes
            // only per poll (about 1.09 s), so a whole-second readout would skip a second
            // roughly every eleventh poll.
            Group {
                if layer == .clock {
                    TimelineView(.animation(minimumInterval: 1.0 / 10.0,
                                            paused: !media.isPlaying)) { _ in
                        Text(ExpandedPlayer.time(media.smoothPosition))
                            .font(.system(size: 10, weight: .medium, design: .rounded))
                            .monospacedDigit()
                            .foregroundStyle(.white.opacity(media.isPlaying ? 0.62 : 0.4))
                            .animation(Motion.swap, value: media.isPlaying)
                    }
                } else {
                    Color.clear
                }
            }
            .frame(maxWidth: .infinity, alignment: .trailing)
        }
        .padding(.horizontal, 11)
        .frame(maxHeight: .infinity)
    }
}

/// The panel's band: elapsed and remaining time flanking the camera. Its own layer,
/// always in the tree and faded by `visible`: a removed view keeps its last layout,
/// so on close the clocks would stay at full width while the shell shrinks through
/// them. Live, they lay out against the shell's moving edges.
private struct PanelClocks: View {
    var media: MediaManager
    var shownPosition: Double
    var scrubbing: Bool
    var band: CGFloat
    var notchWidth: CGFloat
    /// The shell's width. Only the shape's path animates, so plain layout would jump the
    /// clocks on the first frame of a close; animated here on the shell's own
    /// transaction, they sit on its moving edges.
    var width: CGFloat
    var visible: Bool

    private struct AnimatedWidth: ViewModifier, Animatable {
        var width: CGFloat
        var animatableData: CGFloat {
            get { width }
            set { width = newValue }
        }
        func body(content: Content) -> some View { content.frame(width: width) }
    }

    var body: some View {
        // 10 Hz from the display clock: the poll lands about every 1.09 s, so poll-rate
        // sampling skips a second now and then. The timeline only schedules the redraw;
        // the value must be read live inside the closure.
        TimelineView(.animation(minimumInterval: 1.0 / 10.0,
                                paused: !visible || !media.isPlaying || scrubbing)) { _ in
            let pos = scrubbing ? shownPosition : media.smoothPosition
            HStack(spacing: 0) {
                Text(ExpandedPlayer.time(pos))
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    // The tier's opacity lives in `ArtworkPalette` so palettecheck gates the real value.
                    .foregroundStyle(.white.opacity(ArtworkPalette.chromeTypeAlpha))
                    // One line at its own width: on a closing edge the flank is narrower than the
                    // time, which would wrap.
                    .lineLimit(1)
                    .fixedSize()
                    // Flexible, so the flanks resolve against the same padded edges the body uses.
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentTransition(.numericText())
                    .transaction { if !$0.rollsClocks { $0.animation = nil } }

                Color.clear.frame(width: notchWidth)

                // One datum split in two, so both halves share weight and tier. Empty for a live
                // stream, which has no end to count down to.
                Text(media.duration > 0
                     ? "-" + ExpandedPlayer.time(max(0, media.duration - pos)) : "")
                    .font(.system(size: 10.5, weight: .medium, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.white.opacity(ArtworkPalette.chromeTypeAlpha))
                    .lineLimit(1)
                    .fixedSize()
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .contentTransition(.numericText())
                    .transaction { if !$0.rollsClocks { $0.animation = nil } }
            }
            .frame(height: band)
        }
        // A readout jumps; it does not dissolve. A changed string under an animation is
        // crossfaded with both glyph runs painted, and a swipe commits while
        // `SwipeLeanFrame` is easing the sheet back, so the runs land at different x.
        // Suppression has to sit on the Texts (a `.transaction` that strips inherited
        // animation); `.animation(nil, value:)` on the timeline does not reach the redraw
        // that changes `pos`. A seek is the one exception (`rollsClocks`): it rolls the
        // digits to the new time, and no swipe ever carries it.
        .padding(.horizontal, Grid.margin)
        .modifier(AnimatedWidth(width: width))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        // Arrives with the panel's content and leaves faster, in place. Scoped to the
        // opacity so the width above is not retimed; out inside the mini clock's 0.16 s
        // delay.
        .animation(visible ? Motion.content.delay(Pour.contentLag) : Motion.content.speed(2.4)) {
            $0.opacity(visible ? 1 : 0)
        }
        .allowsHitTesting(false)
        .accessibilityHidden(!visible)
    }
}

/// What the panel shows when nothing is playing: small, quiet and deliberate.
private struct IdleCard: View {
    var topInset: CGFloat
    var body: some View {
        HStack(spacing: 9) {
            // Chrome tier for both glyph and label, so they read as one rank.
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

private struct ArtistLine: View {
    var media: MediaManager
    /// The one name under the pointer; hover belongs to a name, not the line.
    @ViewState private var hovered: Int?
    private let font = Font.system(size: 12.5, weight: .medium)

    private var credits: [(offset: Int, element: ArtistCredit)] { Array(media.artists.enumerated()) }

    /// Only the overflowing case scrolls; its names stay individually clickable links,
    /// with no hover styling because the marquee is moving under the pointer.
    private var linkedText: AttributedString {
        var line = AttributedString()
        for (index, credit) in credits {
            line += AttributedString(ArtistCredit.separator(before: index, count: media.artists.count))
            var name = AttributedString(credit.name)
            if let source = media.source { name.link = credit.url(in: source) }
            line += name
        }
        return line
    }

    /// Every name is its own view, so hovering one brightens that name alone. No
    /// underline: a brighter name and the pointing hand are the Mac cue.
    private var fittedLine: some View {
        HStack(spacing: 0) {
            ForEach(credits, id: \.offset) { index, credit in
                Text(ArtistCredit.separator(before: index, count: media.artists.count))
                Text(credit.name)
                    .foregroundStyle(.white.opacity(hovered == index ? 1 : 0.76))
                    .contentShape(Rectangle())
                    .onHover { inside in
                        if inside { hovered = index; NSCursor.pointingHand.set() }
                        else if hovered == index { hovered = nil; NSCursor.arrow.set() }
                    }
                    .onTapGesture { media.openArtist(credit) }
            }
        }
        .font(font)
        .lineLimit(1)
        .fixedSize()
        .animation(.easeOut(duration: 0.12), value: hovered)
        // Otherwise the highlight would stay on a name nobody is pointing at.
        .onDisappear { hovered = nil }
        .onChange(of: media.artistLine) { _, _ in hovered = nil }
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            fittedLine
            MarqueeText(text: media.artistLine, font: font, attributedText: linkedText)
                .tint(.white.opacity(0.76))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .environment(\.openURL, OpenURLAction { url in
            if let source = media.source,
               let credit = media.artists.first(where: { $0.url(in: source) == url }) {
                media.openArtist(credit)
            }
            return .handled
        })
        .accessibilityRepresentation {
            HStack {
                ForEach(credits, id: \.offset) { _, credit in
                    Button("Open \(credit.name) in \(media.source?.displayName ?? "player")") {
                        media.openArtist(credit)
                    }
                }
            }
        }
    }
}

private struct Artwork: View {
    var image: NSImage?
    var palette: ArtworkPalette
    var size: CGFloat
    var radius: CGFloat

    private var cast: (opacity: Double, radius: CGFloat, y: CGFloat) {
        ChromeRules.sleeveShadow(size: size)
    }

    /// Fills the frame it is given; callers size it after the matched geometry effect,
    /// or the effect would move the sleeve without resizing it.
    var body: some View {
        face
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipShape(.rect(cornerRadius: radius, style: .continuous))
        // Flatten the print and fallback before casting the large tile's shadow.
        .compositingGroup()
        .shadow(color: .black.opacity(cast.opacity), radius: cast.radius, y: cast.y)
    }

    @ViewBuilder
    private var face: some View {
        if let image {
            // The clear layer takes the tile's size and the print fills it from an
            // overlay, so a cover that is not square (a music video's 16:9 still) is
            // cropped to the tile instead of widening it.
            Color.clear.overlay {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fill)
                    // Dark covers vanish against the black shell; lift them slightly.
                    .brightness(palette.luminance < 0.16 ? 0.06 : 0)
            }
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
    /// Spoken name: the glyph alone means nothing to VoiceOver, and play/pause flips.
    var label: String
    var diameter: CGFloat
    var glyph: CGFloat
    /// White for transport. The heart is the one control whose colour carries state.
    var tint: Color = .white
    /// Play/pause only: the panel's one primary action gets a brighter rim and faint fill
    /// without a new control shape.
    var prominent: Bool = false
    /// A white wash behind the glyph and the rim stroke's strength, for the mode toggles
    /// (see `modeStyle`). Transport keeps the defaults.
    var fill: Double = 0
    var rim: Double = 0
    var action: () -> Void

    @ViewState private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .accessibilityHidden(true)
                .font(.system(size: glyph, weight: prominent ? .bold : .semibold))
                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
                .foregroundStyle(tint)
                .contentTransition(.symbolEffect(.replace.magic(fallback: .replace)))
                .frame(width: diameter, height: diameter)
                // Bare glyphs on the cover: a ring round every control was the loudest thing
                // on the card and said nothing. A disc appears under the pointer, and the mode
                // toggles keep theirs because it carries their state.
                .background {
                    Circle().fill(.white.opacity(max(fill, hovering ? (prominent ? 0.16 : 0.11) : 0)))
                }
                .overlay {
                    Circle().stroke(
                        LinearGradient(colors: [.white.opacity(0.30 * rim),
                                                .white.opacity(0.05 * rim)],
                                       startPoint: .top, endPoint: .bottom),
                        lineWidth: 0.6)
                }
                .padding(4)
                .contentShape(.circle)
        }
        // The press state comes from the style; an `onLongPressGesture` on top would
        // consume the click.
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
            // Branched like the hover above: damping 0.6 rings, which Reduce Motion removes.
            .animation(Motion.reduceMotion ? .easeOut(duration: 0.10)
                                           : .spring(response: 0.22, dampingFraction: 0.6),
                       value: configuration.isPressed)
    }
}

// MARK: - HUD

/// Volume or brightness strip shown in the collapsed notch.
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
                // Flexible, like the meter on the other side; a fixed width makes the flanks
                // asymmetric and slides the reserved cutout span off the real camera.
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.offset(x: 14 * Motion.travel).combined(with: .opacity))

            Color.clear.frame(width: notchWidth)

            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.18))
                    // Muted drains the meter: a full bright bar with the truth on an 11 pt glyph
                    // would make the loudest element lie.
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
            // Mirrors the icon: extruded rightward out of the cutout.
            .transition(.offset(x: -14 * Motion.travel).combined(with: .opacity))
        }
        .padding(.horizontal, 11)
        .frame(maxHeight: .infinity)
        .animation(Motion.meter, value: controller.hudProgress)
        .animation(Motion.meter, value: controller.hudIsMuted)
    }
}


/// The content sheet's shear under a live two-finger swipe. A leaf, like `MeshField`:
/// `swipeLean` changes on every trackpad delta, and reading it in
/// `NotchRootView`'s body would re-evaluate the whole panel.
///
/// The rule lives in `SwipeRecogniser.sheetShift`. `Motion.travel` is applied here,
/// as a motion preference: it damps the shear to 0.4 under Reduce Motion, so the
/// caps are a ceiling, not what reaches the screen.
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
            // Following is jitter absorption; only the release to zero is worth easing.
            .animation(shift == 0 ? Motion.leanRelease : Motion.leanFollow,
                       value: shift)
    }
}

/// The moving colour field, as its own view. A leaf on purpose: `flowPhase` and
/// `brightness` change every frame, and reading them in `NotchRootView`'s body
/// re-evaluated the whole panel; the cost was view-graph work, not pixels.
private struct MeshField: View {
    var fluid: FerrofluidSim
    var colors: [Color]
    var rate: Double

    var body: some View {
        // Runs exactly when there is sound: gating on `media.isPlaying` would advance the
        // phase unseen while another app plays, then jump. Held still under Reduce Motion.
        TimelineView(.animation(minimumInterval: 1.0 / rate,
                                paused: !fluid.hasSound || Motion.reduceMotion)) { _ in
            // Audio-integrated, never wall-clock.
            let t = fluid.flowPhase
            // Two fields at different rates; one mesh reads as a gradient wobbling, two read
            // against each other as something moving.
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
            // Intensity is measured loudness, not a periodic sinusoid.
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

/// The sleeve as the card's light. Three blurred copies turn and drift against each other
/// on the music's own clock, so the colour moves the way the ink does instead of sitting
/// in the middle as a glow; the swell breathes them and a hit brightens them in the frame
/// it lands, within the flash ceiling. Still when nothing plays and under Reduce Motion,
/// like the mesh.
private struct CoverField: View {
    var fluid: FerrofluidSim
    var art: NSImage
    var size: CGSize
    var rate: Double

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / rate,
                                paused: !fluid.hasSound || Motion.reduceMotion)) { _ in
            let t = fluid.flowPhase
            let swell = min(1, fluid.swell)
            let side = max(size.width, size.height)
            ZStack {
                copy(side: side * 1.6, turn: t * 22,
                     x: sin(t * 0.9) * 0.12, y: cos(t * 0.7) * 0.16,
                     scale: 1 + 0.12 * swell)
                copy(side: side * 1.0, turn: 180 - t * 34,
                     x: cos(t * 1.1 + 1.0) * 0.30, y: sin(t * 0.8 + 2.0) * 0.34,
                     scale: 1 + 0.26 * swell)
                    .opacity(0.8)
                copy(side: side * 0.7, turn: 90 + t * 50,
                     x: sin(t * 1.3 + 4.0) * 0.36, y: cos(t * 1.2 + 0.5) * 0.38,
                     scale: 1 + 0.4 * swell)
                    .opacity(0.7)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .blur(radius: 26)
            .saturation(1.5)
            // The hit's light, not the swell: the swell can pulse faster than the flash
            // ceiling allows across the whole card.
            .brightness(0.1 * min(1, fluid.light))
        }
    }

    /// One copy of the sleeve, `turn` degrees round, its centre `x`/`y` panel widths off.
    private func copy(side: CGFloat, turn: Double, x: Double, y: Double,
                      scale: Double) -> some View {
        Image(nsImage: art)
            .resizable()
            .scaledToFill()
            .frame(width: side, height: side)
            .rotationEffect(.degrees(turn))
            .scaleEffect(scale)
            .offset(x: x * size.width, y: y * size.width)
    }
}

/// Light the ink strikes into the card. Each hit throws the palette's brightest colour
/// out from under the cutout, where the ink meets the panel, and it drains down the card
/// as the transient decays; the swell sets how far it reaches. Audio is the only cause:
/// with nothing hitting it is gone. Open only: closed, it would be one more 30 Hz layer
/// all day for a band the scrim mostly hides. Screen-blended under the scrim, so the
/// type keeps its contrast however hard the hit.
private struct HitBloom: View {
    var fluid: FerrofluidSim
    var color: Color
    var size: CGSize

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60,
                                paused: !fluid.hasSound || Motion.reduceMotion)) { _ in
            // `light`, not `impact`: the flash ceiling lives there.
            let hit = min(1, fluid.light)
            let swell = min(1, fluid.swell)
            let reach = size.width * (0.22 + 0.38 * swell + 0.45 * hit)
            RadialGradient(colors: [color, color.opacity(0.55), color.opacity(0)],
                           center: UnitPoint(x: 0.5, y: 0.28), startRadius: 0, endRadius: reach)
                .scaleEffect(x: 1.6, y: 1, anchor: UnitPoint(x: 0.5, y: 0.28))
                .blendMode(.screen)
                .opacity(min(0.9, 0.12 * swell + 0.95 * hit))
                .allowsHitTesting(false)
        }
    }
}

/// Film grain over the colour field, so a blurred cover reads as a surface rather than a
/// gradient. One tile, made once with a fixed seed so every render is the same.
private struct Grain: View {
    static let tile: Image = {
        let side = 96
        var state: UInt32 = 0x9E37_79B9
        var pixels = [UInt8](repeating: 0, count: side * side)
        for i in pixels.indices {
            state = state &* 1_664_525 &+ 1_013_904_223
            pixels[i] = UInt8(truncatingIfNeeded: state >> 24)
        }
        let context = CGContext(data: &pixels, width: side, height: side, bitsPerComponent: 8,
                                bytesPerRow: side, space: CGColorSpaceCreateDeviceGray(),
                                bitmapInfo: CGImageAlphaInfo.none.rawValue)
        guard let image = context?.makeImage() else { return Image(systemName: "circle") }
        return Image(decorative: image, scale: 2)
    }()

    var body: some View {
        Rectangle()
            .fill(ImagePaint(image: Self.tile))
            .opacity(0.08)
            .blendMode(.overlay)
            .allowsHitTesting(false)
    }
}

/// Set on the transaction of a seek's first contact, the one change that should roll the
/// clocks' digits. Everything else they show jumps; see `PanelClocks`.
private struct RollsClocks: TransactionKey {
    static let defaultValue = false
}

extension Transaction {
    var rollsClocks: Bool {
        get { self[RollsClocks.self] }
        set { self[RollsClocks.self] = newValue }
    }
}
