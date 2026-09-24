import CoreGraphics

/// The chrome rules that are easy to get wrong and impossible to see going
/// wrong — extracted as pure arithmetic so `tools/chromecheck.swift` can assert
/// them.
///
/// Every rule here encodes a defect that shipped. They were all found by reading
/// PRODUCT.md against the code rather than by any suite, because the five
/// existing suites cover physics, geometry, gestures, media and palette, and
/// these live in chrome layout.
enum ChromeRules {

    /// The retracted shell's size.
    ///
    /// Height is pinned to the hardware. `collapsed` is the cutout on a notched
    /// display but a 190x32 FALLBACK PILL on one without, where the real band can
    /// be shorter — so the idle size has to be clamped just as the peek is. It
    /// was not, and the shell's black underside sat on the window chrome below,
    /// which is the anti-reference word for word: a player that remains extended
    /// below the menu bar when it is not in use.
    static func retractedSize(collapsed: CGSize, band: CGFloat, hasContent: Bool) -> CGSize {
        hasContent
            // A peek fills the band EXACTLY. Not the cutout's height: the cutout
            // is 32 and the band is 33, and the trace rides this edge — a point
            // short leaves the shell and the progress line hovering above the
            // menu bar's own bottom line, with a hairline of desktop under them.
            ? CGSize(width: collapsed.width + peekWidening, height: band)
            // Idle it is the cutout, clamped so a fallback pill taller than the
            // band cannot hang onto the window chrome below.
            : CGSize(width: collapsed.width, height: min(collapsed.height, band))
    }

    /// How much wider than the cutout the shell grows while it has content.
    ///
    /// The band's HStack splits this evenly: two `.infinity` flanks either side
    /// of the reserved camera span, so each flank is half of this number. A
    /// flank holds 11pt of edge padding plus a 19pt artwork on the left, and
    /// the same padding plus the elapsed clock on the right — whose worst
    /// string is the hour format, seven glyphs of 10pt rounded monospaced
    /// digits, ~36pt. The right flank is the binding one: 11 + 36 leaves ~3pt
    /// of slack in a 50pt flank.
    ///
    /// It shipped at 132 with no derivation — 66 a side, 36pt of empty air
    /// past the artwork — and `hasContent` is "any live activity", not the
    /// peek moment, so the band held that width for as long as a track was
    /// loaded and sat on menu-bar items that a derived width leaves clear.
    static let peekWidening: CGFloat = 100

    /// How much vertical room the retracted shell is allowed, from what the
    /// display can actually tell us.
    ///
    /// `measured` is `frame.maxY - visibleFrame.maxY`. That is the menu-bar band
    /// — except with "Automatically hide and show the menu bar" on, where it
    /// reads 0 on the plain desktop and says nothing at all. The app already
    /// knows this: `NotchCoordinator.menuBarIsHidden` refuses to use the same
    /// signal for the same reason.
    ///
    /// The fallback used to be the shell's own collapsed height, which turned
    /// the clamp in `retractedSize` into a comparison against itself — `min(h,
    /// h)` is `h`, so the clamp that exists to keep the shell off window chrome
    /// passed it through untouched, in the one configuration where the strip
    /// under it belongs to whatever window is there.
    ///
    /// The cutout is the honest fallback because it is hardware: it is there
    /// whether or not the menu bar is, so drawing inside it covers nothing that
    /// was ever visible. A display with no band and no cutout has nowhere the
    /// shell can sit that is not somebody's window, and says so by answering 0.
    static func retractedBand(measured: CGFloat, cutout: CGFloat?) -> CGFloat {
        measured > 1 ? measured : (cutout ?? 0)
    }

    // MARK: The expanded panel's vertical budget
    //
    // These four live here rather than in `Grid` because `chromecheck` compiles
    // against this file ALONE — it cannot see NotchView or NotchController, so a
    // check written against copies of their numbers is a check that asserts
    // literals against literals and can never fail. It shipped that way.

    /// Gap between the cutout band and the body.
    static let bandGap: CGFloat = 24
    /// The artwork row's height; the body's only tier.
    ///
    /// It was 56, which the text column filled exactly — title 17, artist 14,
    /// controls 25 — leaving no room to give the transport a primary. 62 buys
    /// the play button its 31, and the artwork grows with it.
    ///
    /// 68 because the sleeve is the panel's one image and it was the smallest
    /// thing on it.
    ///
    /// The width for it does not come from the gutter. Play is centred on the
    /// PANEL, so the control row's left edge is fixed at `width/2 - rowWidth/2`
    /// no matter what sits to its left — the artwork can only grow into whatever
    /// that leaves, and at 344 wide that was 54. The panel had to get wider
    /// first; `artworkFits` is the arithmetic, and chromecheck asserts it.
    ///
    /// 88 because the row stopped being seven things wide. Widening the PANEL
    /// buys the sleeve nothing on its own: the space left of the row and the
    /// space right of it are `panelWidth/2 - 109.5` each, so every point of
    /// panel goes half to the sleeve and half to the emptiness beside it — the
    /// void is `art + clearance` at any width. Narrowing the ROW is the only
    /// move that gives the sleeve room without giving the void the same room,
    /// and taking the two mode toggles out of it narrowed it by 88pt. Half of
    /// that is the sleeve's; the other half became the air the modes now sit in.
    static let art: CGFloat = 88
    /// The two type tiers above the transport, as the heights their frames claim.
    ///
    /// Here rather than in `Grid` so `textColumnFits` can be asserted: the
    /// column beside the sleeve is exactly `art` tall and holds these two plus
    /// the control row, and nothing else stops type from growing past it.
    static let titleLine: CGFloat = 19
    static let artistLine: CGFloat = 16
    /// Margin below the body.
    static let bottom: CGFloat = 14
    /// Panel height BELOW the cutout band.
    static let expandedBody: CGFloat = bandGap + art + bottom

    // MARK: The expanded panel's horizontal budget

    /// The invisible scrub strip along the panel's bottom edge.
    ///
    /// It was 22pt tall centred 6pt off the bottom — [h-17, h+5] — and it is the
    /// LAST child of the root ZStack, so it hit-tests above everything under it.
    /// The control row sits `bottom` off the panel floor and each
    /// `TransportButton` carries 4pt of padding outside its disc, so play's hit
    /// circle reached down to h-10 and its VISIBLE disc to h-14. The strip
    /// covered both: clicking the bottom few points of the play button ran the
    /// drag gesture instead, which maps x straight to a fraction — and play sits
    /// on the panel's centre line, so the press that should have paused the track
    /// jumped it to exactly 50% instead.
    ///
    /// 10pt centred 5pt off the bottom is [h-10, h]: the whole strip below every
    /// control's hit area, and no longer hanging off the bottom of the panel
    /// either.
    static let seekStripHeight: CGFloat = 10
    static let seekStripCentre: CGFloat = 5

    /// Gap between the top of the scrub strip and the lowest control it could
    /// steal a press from. Negative means it is stealing them.
    ///
    /// `padding` is the ring each TransportButton adds outside its disc, which is
    /// part of the tap target even though it draws nothing.
    static func seekStripClearance(bottom: CGFloat, padding: CGFloat,
                                   stripHeight: CGFloat, stripCentre: CGFloat) -> CGFloat {
        (bottom - padding) - (stripCentre + stripHeight / 2)
    }

    static let panelWidth: CGFloat = 372
    static let margin: CGFloat = 16
    /// The control row, in the pieces the view is actually built from.
    ///
    /// These lived in NotchView's `Grid` while the width they add up to lived
    /// here as the literal 195, with the sum written out in a comment — one
    /// number in two places, and the geometry checks were reading the copy the
    /// view does not lay out with. `Grid` now reads these.
    static let modeDiameter: CGFloat = 22
    static let controlDiameter: CGFloat = 26
    static let primaryDiameter: CGFloat = 31
    // `controlGap` — 14pt of blank between the triad and a mode on either side —
    // is gone with the row that needed it. It was sized to beat the 4pt
    // difference between a mode disc and a transport disc, because at 7pt the
    // five buttons read as one evenly spaced row of unevenly sized things. The
    // modes are their own cluster now and the air between the groups comes from
    // the margin they sit on, so a constant nothing lays out with would only be
    // a second copy of a number waiting to disagree with the first.

    /// The disc is inset 4pt inside its frame — a ring that draws nothing and is
    /// still part of the tap target.
    static let controlInset: CGFloat = 4

    /// A control's full frame: its disc plus the padding ring either side.
    static func slot(_ diameter: CGFloat) -> CGFloat { diameter + controlInset * 2 }

    /// The centred row: previous, play, next. Nothing else.
    ///
    /// It used to be five — the two mode toggles bracketed the transport,
    /// "which is where every player puts them". That reading cost more than it
    /// was worth. A row centred on the panel reserves `rowWidth/2` either side
    /// of the centre line whether or not anything is drawn there, and the two
    /// mode slots plus their gaps are 88 of the 195: 44pt taken off the sleeve's
    /// side of the panel, to hold two 22pt glyphs that are not transport.
    ///
    /// The modes now sit as their own cluster on the right margin — which is
    /// where Apple Music's now-playing bar puts them, so "controls stay
    /// familiar" survives the move — and the sleeve grew 68 → 88 into the room
    /// they gave back, at the same panel width.
    ///
    /// The move also retires a whole defect class. Play was on the centre line
    /// only while the row stayed symmetric about it, which is why hiding one
    /// mode and not the other had to be forbidden. Three controls symmetric
    /// about play are symmetric unconditionally: there is no longer an answer
    /// the player can give that moves it.
    static let controlRowWidth: CGFloat =
        slot(controlDiameter) + slot(primaryDiameter) + slot(controlDiameter)

    /// Which mode slots the CLUSTER reserves — both, or neither, never one.
    ///
    /// Same arithmetic as when this kept play centred, and a different reason
    /// now that it cannot. The cluster is trailing-aligned on the margin, so its
    /// width decides where its LEFT glyph sits: reserve one slot and shuffle
    /// draws where repeat belongs, then jumps 30pt left the moment the player
    /// answers about repeat. Spotify answers both together; Apple Music reads
    /// them through separate keys and either can come back nil, so that jump is
    /// a state the app really reaches.
    ///
    /// The missing one's slot is reserved with blank space rather than a
    /// placeholder button. Reserving space is not rendering a control, so
    /// "a control that renders must do something" is untouched.
    static func modeSlots(shuffling: Bool?, repeating: Bool?) -> (shuffle: Bool, repeat: Bool) {
        let any = shuffling != nil || repeating != nil
        return (any, any)
    }

    /// The mode cluster's width, from the slots it is reserving.
    static func modeClusterWidth(shuffle: Bool, repeat repeating: Bool) -> CGFloat {
        (shuffle ? slot(modeDiameter) : 0) + (repeating ? slot(modeDiameter) : 0)
    }

    /// Air between the transport's last disc and the cluster's first.
    ///
    /// The cluster is nudged outward by `controlInset` so its trailing DISC
    /// lands on the margin rather than its invisible padding ring — the sleeve's
    /// left edge is on the margin, and one of the two would otherwise be 4pt
    /// short of a line the other one holds.
    static func modeClusterGap(panelWidth: CGFloat, margin: CGFloat, rowWidth: CGFloat,
                               inset: CGFloat, clusterWidth: CGFloat) -> CGFloat {
        let transportEnd = panelWidth / 2 + rowWidth / 2 - inset
        let clusterStart = (panelWidth - margin + inset) - clusterWidth + inset
        return clusterStart - transportEnd
    }

    /// Where the cluster's trailing DISC ends, for a given nudge outward.
    ///
    /// Trailing alignment lands the last SLOT on the column's edge, and the
    /// slot is 4pt wider than the disc inside it — so the glyph column stops
    /// 4pt short of the margin the sleeve's left edge sits on exactly. The view
    /// pushes out by that inset to close it. Written as a function of the
    /// offset rather than as an equality between two spellings of the same sum,
    /// because that version reduces to `(A + i) - i == A` and cannot fail.
    static func modeClusterDiscEdge(panelWidth: CGFloat, margin: CGFloat,
                                    inset: CGFloat, offset: CGFloat) -> CGFloat {
        (panelWidth - margin + offset) - inset
    }

    /// The two groups must not touch, and the cluster must stay a cluster: the
    /// gap between the groups has to beat the gap inside one.
    static func modeClusterClears(panelWidth: CGFloat, margin: CGFloat, rowWidth: CGFloat,
                                  inset: CGFloat, clusterWidth: CGFloat) -> Bool {
        modeClusterGap(panelWidth: panelWidth, margin: margin, rowWidth: rowWidth,
                       inset: inset, clusterWidth: clusterWidth) > inset * 2
    }

    /// The column beside the sleeve is exactly `art` tall and stacks three
    /// things in it. Type that grows past the sleeve does not overflow visibly —
    /// the `Spacer` between the tiers absorbs it until there is none left, and
    /// then the control row is squeezed instead, which reads as crowding rather
    /// than as an overflow. The same shape as the 4pt the panel was short.
    static func textColumnFits(art: CGFloat, title: CGFloat, artist: CGFloat,
                               row: CGFloat) -> Bool {
        art >= title + artist + row
    }

    /// How far the library heart slides back toward the track it names.
    ///
    /// `MarqueeText` claims `maxWidth: .infinity`, and has to: an earlier
    /// version with no ideal width was handed zero inside an `HStack` and the
    /// title vanished. The side effect is that the text column is ALWAYS full
    /// width, so the trailing heart was pinned to the panel's right margin —
    /// 185pt past the end of a short title, alone above the empty right side,
    /// naming nothing in particular. The view's own comment says the library
    /// belongs "beside the track it names"; the layout quietly stopped doing
    /// that, and only a screenshot shows it.
    ///
    /// Slack is the unused tail of the column, applied by the view as an
    /// OFFSET. An offset moves rendering and hit-testing but not layout, so the
    /// column keeps its full width, the marquee keeps a definite box to measure
    /// against, and nothing else on the panel moves — which is the whole reason
    /// this is arithmetic on the side rather than a new stack.
    ///
    /// A title that fills or overflows its column has no slack, so the heart
    /// renders exactly where it always did. That case is the shipped layout by
    /// construction, not by inspection.
    static func heartSlack(textWidth: CGFloat, columnWidth: CGFloat) -> CGFloat {
        max(0, columnWidth - textWidth)
    }

    /// A mode toggle's three states, as the three things that draw them:
    /// glyph opacity, the white wash behind it, and how much of the rim stroke
    /// survives. Pure numbers, so the rule can be asserted without SwiftUI.
    ///
    /// This shipped as three opacities of one glyph — 1.0 on, 0.38 off, 0.16
    /// blocked. Photographed side by side on one ground, OFF and BLOCKED were
    /// the same dim icon: the first means "press me", the second means
    /// "pressing does nothing", and no part of the picture separated them.
    /// PRODUCT.md: "every state change must still read".
    ///
    /// Luminance alone cannot carry three legible steps, because raising OFF
    /// far enough to be read walks it into ON. So each state differs
    /// STRUCTURALLY from its neighbour:
    ///
    ///   ON       lit      — a wash behind the glyph
    ///   OFF      outlined — full rim, legible glyph
    ///   BLOCKED  bare     — no rim at all, which is how every native control
    ///                       says disabled, and it costs no new shape
    ///
    /// ON is not given the artwork accent: `ArtworkPalette` caps every colour
    /// under a luminance ceiling so white type stays legible ON it, which makes
    /// those colours dark washes. A glyph in one would be less visible than the
    /// white it replaced.
    static func modeStyle(on: Bool, blocked: Bool)
        -> (glyph: Double, fill: Double, rim: Double) {
        if blocked { return (0.22, 0, 0) }
        if on { return (1, 0.16, 1) }
        return (0.62, 0, 1)
    }

    /// How far play's centre sits from the control row's own centre. Anything
    /// but zero is play off the panel's centre line, because the row is centred
    /// on it.
    ///
    /// Takes what actually flanks play rather than which modes are showing.
    /// While the modes were in the row this answered 15pt for a player that
    /// reported shuffle and not repeat; now nothing the player can say changes
    /// either side, and a rule phrased in terms of the old inputs would be a
    /// constant zero dressed as a calculation. Phrased this way it still fails
    /// the moment anything is added to one end of the row.
    static func playOffCentre(leftOfPlay: CGFloat, rightOfPlay: CGFloat) -> CGFloat {
        (rightOfPlay - leftOfPlay) / 2
    }

    /// Air between the artwork's right edge and the first control's disc.
    ///
    /// The row is centred on the panel, so this is what the artwork's size has
    /// to be solved for — not the other way round. It went negative twice: once
    /// when a sixth control widened the row, and once when the artwork was grown
    /// without the panel growing with it. Both read as the sleeve and the shuffle
    /// glyph touching.
    static func artworkClearance(panelWidth: CGFloat, margin: CGFloat, art: CGFloat,
                                 rowWidth: CGFloat, inset: CGFloat) -> CGFloat {
        (panelWidth / 2 - rowWidth / 2 + inset) - (margin + art)
    }

    static func artworkFits(panelWidth: CGFloat, margin: CGFloat, art: CGFloat,
                            rowWidth: CGFloat, inset: CGFloat) -> Bool {
        artworkClearance(panelWidth: panelWidth, margin: margin, art: art,
                         rowWidth: rowWidth, inset: inset) >= 8
    }

    /// The expanded panel must be at least as tall as what it lays out.
    ///
    /// It was 4pt short, and nothing said so: the gap below the band carries a
    /// `minLength`, so it cannot take up the slack, and the content is squeezed
    /// instead. It reads as crowding rather than as an overflow, which is exactly
    /// the kind of fault that survives — three independent design reviewers found
    /// it by arithmetic and it had never once been noticed on screen.
    static func expandedContentHeight(band: CGFloat, gap: CGFloat,
                                      art: CGFloat, bottom: CGFloat) -> CGFloat {
        band + gap + art + bottom
    }

    /// `band` cancels on both sides, so the rule is just: the body must hold the
    /// gap, the artwork row and the bottom margin.
    static func expandedBodyFits(body: CGFloat, gap: CGFloat,
                                 art: CGFloat, bottom: CGFloat) -> Bool {
        body >= gap + art + bottom
    }

    /// The width the progress trace may use while retracted.
    ///
    /// Retracted the shell IS the menu-bar band and the camera sits on top of
    /// it, so the only screen this line may occupy is the sliver between them —
    /// `band - cutout`, one point on the built-in display. Both of its edges are
    /// tight at once. A stroke whose top rises above the cutout's bottom is
    /// covered by the housing and the line reads as broken across the notch's
    /// own width; a stroke whose bottom falls past the band is drawn on the
    /// window chrome underneath the menu bar, which PRODUCT.md forbids by name.
    /// One width satisfies both, and it is the sliver itself.
    ///
    /// The previous answer kept the expanded stroke and pushed the PATH down
    /// until its top landed on the cutout. That pinned the top edge exactly and
    /// let the bottom edge fall 1.5pt onto the chrome — for as long as a track
    /// was loaded, not only during a peek. It survived because `traceInset`'s
    /// check asserted the top edge and never the bottom one: half a rule, and
    /// the half that was missing is the half PRODUCT.md actually names.
    ///
    /// The no-sliver answer depends on WHY there is no sliver, which the
    /// arithmetic alone cannot see. On a pill display the 190x32 fallback
    /// cutout describes nothing on screen — no camera to clear, and the line
    /// keeps the width it uses expanded. On a notched display the same
    /// numbers mean the adjusted cutout has swallowed the whole band (the
    /// height offsets exist precisely because `safeAreaInsets` disagrees
    /// across hardware), and the old fallback drew the full stroke behind the
    /// physical housing — the exact broken-across-the-notch defect the sliver
    /// sizing was built to prevent. A camera and no room under it means
    /// nothing may be drawn at all.
    static func retractedTraceWidth(shellHeight: CGFloat, cutoutHeight: CGFloat,
                                    expandedWidth: CGFloat, hasNotch: Bool) -> CGFloat {
        guard hasNotch else { return expandedWidth }
        let sliver = shellHeight - cutoutHeight
        guard sliver > 0 else { return 0 }
        return min(expandedWidth, sliver)
    }

    /// How far above the shell's bottom edge the progress trace is drawn: half
    /// the stroke, so the line's outer boundary lands on the silhouette rather
    /// than straddling it, and the whole of it stays inside the shell.
    ///
    /// One rule for both states now. The retracted case used to be a negative
    /// inset — the path pushed BELOW the shell so a stroke too wide for the band
    /// could still clear the camera — and `NotchBottomEdge` reads a negative
    /// inset as "push the path down and widen it", so the line left the
    /// silhouette in both axes at once. Sizing the retracted stroke to the
    /// sliver instead means there is nothing left for the inset to compensate
    /// for, and the branch that did the compensating is gone with it.
    static func traceInset(strokeWidth: CGFloat) -> CGFloat { strokeWidth / 2 }

    // MARK: The outline
    //
    // The silhouette is one line drawn by two things: the progress track owns the
    // bottom edge and both corners, the rim owns everything above them. These are
    // the rules that keep them from disagreeing about where the handoff is and
    // what value it happens at.

    /// One stop on the rim's gradient, as a fraction of the shell's height.
    struct RimStop: Equatable {
        var location: CGFloat
        var alpha: Double
    }

    /// The rim's value, expanded. Flat on purpose.
    ///
    /// The shipped schedule ran 0.18 at the top, 0.05 at 58% and 0.16 at the
    /// bottom — brightest along the display's top row, where the panel abuts the
    /// bezel and separates from nothing, and dimmest across the sides, which are
    /// the whole of what the rim still draws now that the trace owns the bottom.
    /// On a 0.5pt centred stroke over a dark window title bar, 0.05 lands as two
    /// half-covered device pixels at 0.025 — the right edge was not locatable,
    /// while the same edge stayed obvious against the light desktop below it. An
    /// edge that exists only where the backdrop is brighter is the backdrop's
    /// edge, not the panel's.
    ///
    /// A value that varies along an outline is a highlight that happens to follow
    /// the edge. An edge is one value.
    static let rimAlpha: Double = 0.20

    /// The same rim while the pointer is inside and the panel has not opened yet.
    ///
    /// Today's PEAK, held all the way round instead of decaying to 0.03 over the
    /// sides. It must not go down: for the whole of `hoverDuration` this is the
    /// only thing the notch gives back.
    static let rimHoverAlpha: Double = 0.15

    /// No part of the outline the rim draws may fall below this.
    ///
    /// The hairline's own legibility floor, NOT the progress track's alpha: the
    /// track is 2.5pt and the rim is 0.5pt, so the same number is five times the
    /// ink and the two were never the same weight.
    static let rimFloor: Double = 0.16

    /// The progress trace's resting stroke, so the rim's handoff and the trace's
    /// own width are one number rather than two spellings of 2.5.
    static let traceStroke: CGFloat = 2.5

    /// Where the rim starts handing the silhouette over, as a depth measured up
    /// from the shell's bottom edge.
    ///
    /// The trace's round cap puts ink one whole stroke width above the shell's
    /// corner tangent — `traceInset` plus half the stroke — so that row is where
    /// something else first draws this edge. With nothing on that edge the depth
    /// is the corner itself and the rim closes the bottom too.
    static func rimHandoffDepth(bottomRadius: CGFloat,
                                traceStrokeWidth: CGFloat?) -> CGFloat {
        bottomRadius + (traceStrokeWidth ?? 0)
    }

    /// The rim's gradient, top to bottom.
    ///
    /// Three stops in every branch, deliberately: a changed stop count snaps
    /// instead of interpolating when `expanded` flips mid-morph.
    static func rimStops(expanded: Bool, hovering: Bool,
                         traceStrokeWidth: CGFloat?,
                         height: CGFloat, bottomRadius: CGFloat) -> [RimStop] {
        let alpha = expanded ? rimAlpha : (hovering ? rimHoverAlpha : 0)
        let depth = rimHandoffDepth(bottomRadius: bottomRadius,
                                    traceStrokeWidth: traceStrokeWidth)
        let handoff = height > 0 ? max(0, min(1, (height - depth) / height)) : 1
        // Expanded with nothing else on that edge — the idle card, which has no
        // track — the rim is what closes the bottom, so it holds its value to the
        // end. Otherwise it is out by the bottom edge: expanded the trace has it,
        // and retracted the outer half of a centred stroke would sit on the window
        // chrome below the band, which PRODUCT.md forbids by name.
        let tail = (expanded && traceStrokeWidth == nil) ? alpha : 0
        return [RimStop(location: 0, alpha: alpha),
                RimStop(location: handoff, alpha: alpha),
                RimStop(location: 1, alpha: tail)]
    }

    // MARK: The sleeve's edge

    /// The size above which the sleeve is the panel's subject rather than a
    /// thumbnail in the menu-bar band.
    ///
    /// One name for what were three separate `size > 30` ternaries in the view,
    /// so the mount and the cast shadow cannot drift apart about which sleeve is
    /// which. Inherited from the recovered prototype and never reviewed since: a
    /// threshold, not a measurement.
    static let sleeveFull: CGFloat = 30

    /// The tile's own thickness — an outer bevel, and the line it shadows onto
    /// the print — both INSIDE the sleeve's silhouette.
    ///
    /// The edge used to be `strokeBorder(white 0.28 -> 0.04, 0.5pt)` drawn over
    /// the artwork, and an alpha stroke over an image composites to
    /// `art * (1 - a) + a`: 0.89 on a 0.85 cover, a step of 0.04 that is simply
    /// gone, and 0.32 on a 0.05 cover, a hard bright seam. The edge's presence
    /// was a property of the album and no alpha value fixes that. An opaque ring
    /// cannot take its tone from what is under it.
    ///
    /// Inward, never outward: the sleeve's left edge holds the margin the mode
    /// cluster is nudged by `controlInset` to land on, so an outer ring would
    /// break an alignment this file goes out of its way to establish. Footprint,
    /// margin and `artworkClearance` are unchanged — the artwork gives up the
    /// ring, not the panel.
    static func sleeveMount(size: CGFloat) -> (bevel: CGFloat, innerLine: CGFloat) {
        size > sleeveFull ? (bevel: 1, innerLine: 0.5) : (bevel: 0.5, innerLine: 0)
    }

    /// The bevel's tone, top and bottom. Opaque greys, NOT alphas.
    ///
    /// The top keeps the 0.28 the old stroke's top stop had. What changed is that
    /// it is the tile's thickness rather than a wash over the print, so it is
    /// that value on every record instead of only on a black one.
    static let sleeveBevel: (top: Double, bottom: Double) = (0.28, 0.12)

    /// The shadow the tile casts on the wash. Not the defect, and it keeps its
    /// values; it lives here only so it shares `sleeveFull` with the mount.
    /// Inherited from the recovered prototype and never reviewed.
    static func sleeveShadow(size: CGFloat)
    -> (opacity: Double, radius: CGFloat, y: CGFloat) {
        size > sleeveFull ? (0.55, 9, 4) : (0, 0, 0)
    }

    // MARK: The content sheet under a live swipe

    /// How far the sheet shears with the fingers, before the onset gate.
    ///
    /// The swipe's only voice used to arrive AT the commit; while the fingers
    /// were still travelling the panel sat perfectly still, so an aborted swipe
    /// looked identical to no swipe at all. The sheet now leans the way the
    /// fingers go — content only, never the shell or the trace, which are the
    /// silhouette and must not move off the hardware they claim to be.
    ///
    /// Distance carries most of it and each banked detent adds a step, so the
    /// eye sees the same stairs the hand feels. The caps are derived, not
    /// chosen: expanded content sits `margin` (16) off the shell edge and its
    /// nearest disc keeps a 4pt ring, so 12 is the whole slack; retracted the
    /// flanks hold 11pt of edge padding and the same 4pt of air leaves 7. Past
    /// either, type slides under the bezel — the one place PRODUCT.md says
    /// nothing may go.
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

    /// Whether the marquee's moving copy is on screen.
    ///
    /// The static label is hidden while this is true. The two were keyed on
    /// different conditions — the label on overflow alone, the scroller on
    /// overflow AND not-Reduce-Motion — so with Reduce Motion on, any title wider
    /// than its column rendered as nothing at all.
    static func marqueeScrolls(textWidth: CGFloat, boxWidth: CGFloat) -> Bool {
        textWidth > 0 && boxWidth > 0 && textWidth - boxWidth > 1
    }

    /// The two gates the view actually applies, kept as separate names on
    /// purpose. They must stay the same predicate — the defect was that they
    /// diverged, the label keyed on overflow alone and the scroller on overflow
    /// AND not-Reduce-Motion, so with Reduce Motion on an overflowing title
    /// rendered as nothing at all.
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
    ///
    /// Written against the two gates rather than against one predicate, so it
    /// still fails if they are ever keyed on different things again.
    static func marqueeShowsSomething(textWidth: CGFloat, boxWidth: CGFloat,
                                      reduceMotion: Bool) -> Bool {
        marqueeShowsScroller(textWidth: textWidth, boxWidth: boxWidth,
                             reduceMotion: reduceMotion)
        || !marqueeHidesStaticLabel(textWidth: textWidth, boxWidth: boxWidth,
                                    reduceMotion: reduceMotion)
    }
}
