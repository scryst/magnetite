import CoreGraphics

/// Chrome layout rules as pure arithmetic, so `tools/chromecheck.swift` can assert them.
enum ChromeRules {

    static func drawsTrace(hasTrack: Bool, hasShell: Bool, width: CGFloat) -> Bool {
        hasTrack && hasShell && width > 0
    }

    /// The retracted shell's size. Height is pinned to the hardware: `collapsed` is a
    /// 190x32 fallback pill on a display without a notch, where the real band can be
    /// shorter, so the idle size is clamped like the peek.
    static func retractedSize(collapsed: CGSize, band: CGFloat, hasContent: Bool) -> CGSize {
        hasContent
            // A peek fills the band exactly, not the 32 pt cutout: the trace rides this edge
            // and a point short leaves a hairline of desktop beneath it.
            ? CGSize(width: collapsed.width + miniPlayerWidening, height: band)
            // Idle it is the cutout, clamped to the band.
            : CGSize(width: collapsed.width, height: min(collapsed.height, band))
    }

    /// How much wider than the cutout the shell grows while it has content, split
    /// between two flanks. The right flank binds: 11 pt of padding plus the hour-format
    /// clock (about 36 pt) leaves about 3 pt of slack in a 50 pt flank.
    static let miniPlayerWidening: CGFloat = 100

    /// How much vertical room the retracted shell is allowed. `measured` is
    /// `frame.maxY - visibleFrame.maxY`, the menu-bar band, except with auto-hide on,
    /// where it reads 0 on the plain desktop. The fallback is the cutout rather than the
    /// shell's own height, which would make the clamp in `retractedSize` compare a value
    /// with itself. A display with no band and no cutout has nowhere the shell can sit
    /// that is not a window, and answers 0.
    static func retractedBand(measured: CGFloat, cutout: CGFloat?) -> CGFloat {
        measured > 1 ? measured : (cutout ?? 0)
    }

    // MARK: The expanded panel's vertical budget
    //
    // These live here, not in `Grid`, because `chromecheck` compiles against this file
    // alone and a check against copies of the view's numbers cannot fail.

    /// Gap between the cutout band and the body.
    static let bandGap: CGFloat = 24
    /// The artwork row's height, the body's only tier. Play is centred on the panel,
    /// so the control row's left edge is fixed at `width/2 - rowWidth/2` and the
    /// artwork can only grow into what that leaves (`artworkFits`). Narrowing the row
    /// is what gives the sleeve room; the text column beside it must stay within this
    /// height (`textColumnFits`).
    static let art: CGFloat = 88
    /// Heights the two type tiers' frames claim, here so `textColumnFits` can be asserted.
    static let titleLine: CGFloat = 19
    static let artistLine: CGFloat = 16
    static let bottom: CGFloat = 14
    /// Panel height BELOW the cutout band.
    static let expandedBody: CGFloat = bandGap + art + bottom

    // MARK: The expanded panel's horizontal budget

    /// The invisible scrub strip along the panel's bottom edge. It is the last child of
    /// the root ZStack, so it hit-tests above everything under it. Play's hit circle
    /// reaches down to h-10, and the strip maps x straight to a fraction, so a taller
    /// strip turns a pause press into a jump to 50%. 10 pt centred 5 pt off the bottom
    /// is [h-10, h].
    static let seekStripHeight: CGFloat = 10
    static let seekStripCentre: CGFloat = 5

    /// Gap between the top of the scrub strip and the lowest control it could steal a
    /// press from; negative means it is stealing.
    static func seekStripClearance(bottom: CGFloat, padding: CGFloat,
                                   stripHeight: CGFloat, stripCentre: CGFloat) -> CGFloat {
        (bottom - padding) - (stripCentre + stripHeight / 2)
    }

    static let panelWidth: CGFloat = 372
    static let margin: CGFloat = 16
    /// The control row, in the pieces `Grid` reads.
    static let modeDiameter: CGFloat = 22
    static let controlDiameter: CGFloat = 26
    static let primaryDiameter: CGFloat = 31

    /// The disc is inset 4 pt inside its frame; the ring is tap target without drawing.
    static let controlInset: CGFloat = 4

    static func slot(_ diameter: CGFloat) -> CGFloat { diameter + controlInset * 2 }

    /// The centred row: previous, play, next. A centred row reserves `rowWidth/2` either
    /// side of the centre line whether or not anything is drawn there, so the mode
    /// toggles sit apart as a cluster on the right margin. Three controls symmetric
    /// about play keep it on the centre line whatever the player reports.
    static let controlRowWidth: CGFloat =
        slot(controlDiameter) + slot(primaryDiameter) + slot(controlDiameter)

    /// Which mode slots the cluster reserves: both or neither. It is trailing-aligned, so
    /// its width decides where its left glyph sits; reserving one slot would jump
    /// shuffle 30 pt when the player answers about repeat. Spotify answers both
    /// together, Apple Music through separate keys that can each be nil. The missing
    /// slot is blank space, not a placeholder button.
    static func modeSlots(shuffling: Bool?, repeating: Bool?) -> (shuffle: Bool, repeat: Bool) {
        let any = shuffling != nil || repeating != nil
        return (any, any)
    }

    static func modeClusterWidth(shuffle: Bool, repeat repeating: Bool) -> CGFloat {
        (shuffle ? slot(modeDiameter) : 0) + (repeating ? slot(modeDiameter) : 0)
    }

    /// Air between the transport's last disc and the cluster's first. The cluster is
    /// nudged out by `controlInset` so its disc, not its padding ring, meets the margin.
    static func modeClusterGap(panelWidth: CGFloat, margin: CGFloat, rowWidth: CGFloat,
                               inset: CGFloat, clusterWidth: CGFloat) -> CGFloat {
        let transportEnd = panelWidth / 2 + rowWidth / 2 - inset
        let clusterStart = (panelWidth - margin + inset) - clusterWidth + inset
        return clusterStart - transportEnd
    }

    /// Where the cluster's trailing disc ends for a given outward nudge. The last slot is
    /// 4 pt wider than its disc, so the view pushes out by that inset. Written as a
    /// function of the offset: an equality between two spellings of one sum reduces
    /// to `(A + i) - i == A` and cannot fail.
    static func modeClusterDiscEdge(panelWidth: CGFloat, margin: CGFloat,
                                    inset: CGFloat, offset: CGFloat) -> CGFloat {
        (panelWidth - margin + offset) - inset
    }

    /// The groups must not touch: the gap between them has to beat the gap inside one.
    static func modeClusterClears(panelWidth: CGFloat, margin: CGFloat, rowWidth: CGFloat,
                                  inset: CGFloat, clusterWidth: CGFloat) -> Bool {
        modeClusterGap(panelWidth: panelWidth, margin: margin, rowWidth: rowWidth,
                       inset: inset, clusterWidth: clusterWidth) > inset * 2
    }

    /// The column beside the sleeve is exactly `art` tall. Type that outgrows it is
    /// absorbed by the `Spacer` until the control row is squeezed, which reads as
    /// crowding rather than overflow.
    static func textColumnFits(art: CGFloat, title: CGFloat, artist: CGFloat,
                               row: CGFloat) -> Bool {
        art >= title + artist + row
    }

    /// How far the library heart slides back toward the track it names. `MarqueeText`
    /// claims the full width, so the heart would otherwise sit at the right margin,
    /// far from a short title. Applied as an offset, which moves rendering and
    /// hit-testing but not layout. A title that fills its column has no slack.
    static func heartSlack(textWidth: CGFloat, columnWidth: CGFloat) -> CGFloat {
        max(0, columnWidth - textWidth)
    }

    /// A mode toggle's three states as glyph opacity, the white wash behind it and the
    /// share of the rim stroke that survives. Luminance alone cannot carry three
    /// legible steps (raising OFF far enough to read walks it into ON), so each state
    /// differs structurally:
    ///
    ///   ON       lit      a wash behind the glyph
    ///   OFF      outlined full rim, legible glyph
    ///   BLOCKED  bare     no rim, as native controls show disabled
    ///
    /// ON does not take the artwork accent: `ArtworkPalette` caps colours under a
    /// luminance ceiling so white type stays legible, which makes them dark washes.
    static func modeStyle(on: Bool, blocked: Bool)
        -> (glyph: Double, fill: Double, rim: Double) {
        if blocked { return (0.22, 0, 0) }
        if on { return (1, 0.16, 1) }
        return (0.62, 0, 1)
    }

    /// How far play's centre sits from the control row's centre; anything but zero is
    /// play off the panel's centre line. Takes what flanks play, so it fails if
    /// anything is added to one end of the row.
    static func playOffCentre(leftOfPlay: CGFloat, rightOfPlay: CGFloat) -> CGFloat {
        (rightOfPlay - leftOfPlay) / 2
    }

    /// Air between the artwork's right edge and the first control's disc. The row is
    /// centred on the panel, so the artwork's size is solved for this.
    static func artworkClearance(panelWidth: CGFloat, margin: CGFloat, art: CGFloat,
                                 rowWidth: CGFloat, inset: CGFloat) -> CGFloat {
        (panelWidth / 2 - rowWidth / 2 + inset) - (margin + art)
    }

    static func artworkFits(panelWidth: CGFloat, margin: CGFloat, art: CGFloat,
                            rowWidth: CGFloat, inset: CGFloat) -> Bool {
        artworkClearance(panelWidth: panelWidth, margin: margin, art: art,
                         rowWidth: rowWidth, inset: inset) >= 8
    }

    /// The expanded panel must be at least as tall as what it lays out; the gap below
    /// the band has a `minLength`, so a short panel squeezes the content instead.
    static func expandedContentHeight(band: CGFloat, gap: CGFloat,
                                      art: CGFloat, bottom: CGFloat) -> CGFloat {
        band + gap + art + bottom
    }

    /// `band` cancels on both sides: the body must hold the gap, the artwork row and
    /// the bottom margin.
    static func expandedBodyFits(body: CGFloat, gap: CGFloat,
                                 art: CGFloat, bottom: CGFloat) -> Bool {
        body >= gap + art + bottom
    }

    /// The width the progress trace may use while retracted: the sliver between the
    /// cutout and the band (`band - cutout`, one point on the built-in display). A
    /// stroke above the cutout's bottom is hidden by the housing; one past the band is
    /// drawn on window chrome.
    ///
    /// With no sliver, the reason matters. On a pill display the fallback cutout
    /// describes nothing on screen, so the line keeps its expanded width. On a notched
    /// display the adjusted cutout has swallowed the band, so the width is 0.
    static func retractedTraceWidth(shellHeight: CGFloat, cutoutHeight: CGFloat,
                                    expandedWidth: CGFloat, hasNotch: Bool) -> CGFloat {
        guard hasNotch else { return expandedWidth }
        let sliver = shellHeight - cutoutHeight
        guard sliver > 0 else { return 0 }
        return min(expandedWidth, sliver)
    }

    /// How far above the shell's bottom edge the trace is drawn: half the stroke, so its
    /// outer boundary lands on the silhouette. `NotchBottomEdge` reads a negative inset
    /// as "push the path down and widen it".
    static func traceInset(strokeWidth: CGFloat) -> CGFloat { strokeWidth / 2 }

    // MARK: The outline
    //
    // The progress track owns the bottom edge and both corners, the rim owns everything
    // above them. These rules keep them agreeing on where the handoff is.

    struct RimStop: Equatable {
        var location: CGFloat
        var alpha: Double
    }

    /// The rim's value when expanded. Flat on purpose: a schedule dimmer at the sides
    /// (0.05) lands as two half-covered device pixels on a 0.5 pt stroke and the edge
    /// disappears over a dark title bar.
    static let rimAlpha: Double = 0.20

    /// The rim while the pointer is inside and the panel has not opened yet. For the
    /// whole of `hoverDuration` it is all the notch gives back, so it must not go lower.
    static let rimHoverAlpha: Double = 0.15

    /// No part of the outline the rim draws may fall below this: the hairline's
    /// legibility floor (the track is 2.5 pt, the rim 0.5 pt).
    static let rimFloor: Double = 0.16

    /// The progress trace's resting stroke, shared with the rim's handoff.
    static let traceStroke: CGFloat = 2.5

    /// Where the rim starts handing the silhouette over, as a depth up from the bottom
    /// edge. The trace's round cap puts ink one stroke width above the corner tangent;
    /// with no trace the depth is the corner itself and the rim closes the bottom.
    static func rimHandoffDepth(bottomRadius: CGFloat,
                                traceStrokeWidth: CGFloat?) -> CGFloat {
        bottomRadius + (traceStrokeWidth ?? 0)
    }

    /// The rim's gradient, top to bottom. Three stops in every branch, since a changed
    /// stop count snaps instead of interpolating when `expanded` flips mid-morph.
    static func rimStops(expanded: Bool, hovering: Bool,
                         traceStrokeWidth: CGFloat?,
                         height: CGFloat, bottomRadius: CGFloat) -> [RimStop] {
        let alpha = expanded ? rimAlpha : (hovering ? rimHoverAlpha : 0)
        let depth = rimHandoffDepth(bottomRadius: bottomRadius,
                                    traceStrokeWidth: traceStrokeWidth)
        let handoff = height > 0 ? max(0, min(1, (height - depth) / height)) : 1
        // With nothing else on the bottom edge (the idle card has no track) the rim closes
        // it. Otherwise it is out by the bottom: expanded, the trace has it; retracted,
        // half a centred stroke would sit on window chrome.
        let tail = (expanded && traceStrokeWidth == nil) ? alpha : 0
        return [RimStop(location: 0, alpha: alpha),
                RimStop(location: handoff, alpha: alpha),
                RimStop(location: 1, alpha: tail)]
    }

    // MARK: The artwork's lift

    /// The size above which the sleeve is the panel's subject, not a thumbnail.
    static let sleeveFull: CGFloat = 30
    /// No bevel, ring or matte: the cover is the tile. Only the large one lifts.
    static func sleeveShadow(size: CGFloat)
    -> (opacity: Double, radius: CGFloat, y: CGFloat) {
        size > sleeveFull ? (0.55, 9, 4) : (0, 0, 0)
    }

    // MARK: The content sheet under a live swipe

    /// How far the sheet shears with the fingers, before the onset gate. Content only,
    /// never the shell or trace. Distance carries most of it and each banked detent adds
    /// a step. The caps are derived: expanded content sits `margin` (16) off the edge and
    /// its nearest disc keeps a 4 pt ring, leaving 12; retracted, the flanks hold 11 pt
    /// of padding and the same ring leaves 7. Past either, type slides under the bezel.
    static let swipeShiftCapExpanded: CGFloat = 12
    static let swipeShiftCapRetracted: CGFloat = 7

    static func swipeShift(direction: CGFloat, progress: CGFloat,
                           reached: Int, expanded: Bool) -> CGFloat {
        let cap = expanded ? swipeShiftCapExpanded : swipeShiftCapRetracted
        let perProgress: CGFloat = expanded ? 7.5 : 4
        let perDetent: CGFloat = expanded ? 1.5 : 1
        return direction * min(cap, perProgress * progress
                                    + perDetent * CGFloat(reached))
    }

    /// Whether the marquee's moving copy is on screen; the static label hides while it is.
    static func marqueeScrolls(textWidth: CGFloat, boxWidth: CGFloat) -> Bool {
        textWidth > 0 && boxWidth > 0 && textWidth - boxWidth > 1
    }

    /// The two gates the view applies. They must stay the same predicate, or an
    /// overflowing title renders as nothing under Reduce Motion.
    static func marqueeHidesStaticLabel(textWidth: CGFloat, boxWidth: CGFloat,
                                        reduceMotion: Bool) -> Bool {
        marqueeScrolling(textWidth: textWidth, boxWidth: boxWidth, reduceMotion: reduceMotion)
    }

    static func marqueeShowsScroller(textWidth: CGFloat, boxWidth: CGFloat,
                                     reduceMotion: Bool) -> Bool {
        marqueeScrolling(textWidth: textWidth, boxWidth: boxWidth, reduceMotion: reduceMotion)
    }

    static func marqueeScrolling(textWidth: CGFloat, boxWidth: CGFloat,
                                 reduceMotion: Bool) -> Bool {
        marqueeScrolls(textWidth: textWidth, boxWidth: boxWidth) && !reduceMotion
    }

    /// The text is legible in one of its two forms, never neither.
    static func marqueeShowsSomething(textWidth: CGFloat, boxWidth: CGFloat,
                                      reduceMotion: Bool) -> Bool {
        marqueeShowsScroller(textWidth: textWidth, boxWidth: boxWidth,
                             reduceMotion: reduceMotion)
        || !marqueeHidesStaticLabel(textWidth: textWidth, boxWidth: boxWidth,
                                    reduceMotion: reduceMotion)
    }
}
