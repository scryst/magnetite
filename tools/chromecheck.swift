import Foundation
import CoreGraphics

/// Headless checks on chrome layout and the animation vocabulary.
///
/// check.sh compiles this file against `ChromeRules` alone, so the view-facing
/// checks also scan `NotchView.swift` as text to confirm the view still calls
/// the rules that are tested here.
@main
enum ChromeCheck {
    static func main() {
        theRetractedShellNeverLeavesTheBand()
        theRetractedShellNeverOutgrowsWhatTheDisplayGaveIt()
        theTitleIsNeverBlank()
        theTitleTakesBothGatesFromTheRule()
        theExpandedPanelFitsItsContents()
        theArtworkClearsTheControls()
        theScrubStripDoesNotStealThePlayButton()
        theScrubStripIsNotOfferedWithoutADuration()
        playStaysOnThePanelCentreLine()
        aModeDoesNotMoveWhenItsNeighbourArrives()
        theModesClearTheTransport()
        theTypeFitsBesideTheSleeve()
        aModeYouCannotUseDoesNotLookLikeOneYouCan()
        theHeartSitsInRepeatsColumn()
        theTraceFitsBetweenTheCameraAndTheChrome()
        theTraceHasSomethingToRunAlong()
        theRetractedClockDoesNotStepAtThePollRate()
        theBandClocksDoNotStepAtThePollRate()
        thePanelHasAnEdgeOnAnyBackdrop()
        noRingOrMatteSurroundsThePrint()
        aTraceWithNoRoomIsNotDrawn()
        everyCurveAsksAboutReduceMotion()
        theSheetLeanStaysInsideTheMargins()
        theSheetTakesItsShiftFromTheRule()
        print("chromecheck: all checks passed")
    }

    /// The retracted shell never takes more room than the display gave it.
    ///
    /// The clamp in `retractedSize` is only as good as the band it is handed. With
    /// "Automatically hide and show the menu bar" on, `visibleFrame.maxY` equals
    /// `frame.maxY` and the band cannot be measured, so the fallback must be the
    /// hardware cutout (or nothing), never the shell's own height.
    static func theRetractedShellNeverOutgrowsWhatTheDisplayGaveIt() {
        // A band that can be measured is still the band.
        for band in stride(from: 20.0, through: 40.0, by: 0.5) {
            let allowed = ChromeRules.retractedBand(measured: CGFloat(band), cutout: 32)
            require(allowed == CGFloat(band),
                    "a measurable \(band)pt band was replaced by \(allowed)pt")
        }

        // A notched Mac keeps its notch when the menu bar goes: the cutout is
        // hardware, so it is still a legal home with no band to be found.
        require(ChromeRules.retractedBand(measured: 0, cutout: 32) == 32,
                "an unmeasurable band threw the cutout away too, so a notched Mac "
                + "loses the notch the whole app is named for whenever the menu bar "
                + "auto-hides")

        // The cutout is a ceiling: a larger shell cannot talk its way past it.
        for unmeasurable in [0.0, 0.5, 1.0] {
            let allowed = ChromeRules.retractedBand(measured: CGFloat(unmeasurable), cutout: 32)
            for own in [24.0, 32.0, 64.0, 120.0] {
                for hasContent in [false, true] {
                    let size = ChromeRules.retractedSize(
                        collapsed: CGSize(width: 190, height: CGFloat(own)),
                        band: allowed, hasContent: hasContent)
                    require(size.height <= 32 + 1e-9,
                            "with the band unmeasurable at \(unmeasurable)pt, a \(own)pt "
                            + "shell drew \(size.height)pt inside a 32pt cutout "
                            + "(content: \(hasContent)) — the clamp is being handed the "
                            + "very number it exists to clamp")
                }
            }
        }

        // No band and no cutout: every pixel it could take belongs to a window.
        let nothing = ChromeRules.retractedBand(measured: 0, cutout: nil)
        for hasContent in [false, true] {
            let size = ChromeRules.retractedSize(collapsed: CGSize(width: 190, height: 32),
                                                 band: nothing, hasContent: hasContent)
            require(size.height == 0,
                    "with no band and no cutout the retracted shell still claimed "
                    + "\(size.height)pt of somebody's window (content: \(hasContent))")
        }
    }

    /// The retracted shell is pinned to the menu-bar band in both branches, idle
    /// and peeking. On a display with no notch `collapsed` is a 190x32 fallback
    /// pill while the real band can be shorter; unclamped, the shell would hang
    /// onto the window chrome beneath it.
    static func theRetractedShellNeverLeavesTheBand() {
        let cutout = CGSize(width: 190, height: 32)
        for band in stride(from: 20.0, through: 40.0, by: 0.5) {
            for hasContent in [false, true] {
                let s = ChromeRules.retractedSize(collapsed: cutout,
                                                  band: CGFloat(band),
                                                  hasContent: hasContent)
                require(s.height <= CGFloat(band) + 1e-9,
                        "the retracted shell is \(s.height)pt in a \(band)pt band "
                        + "(content: \(hasContent))")
            }
        }
        // The notched Mac is untouched: 32pt cutout inside a 33pt band.
        let builtIn = ChromeRules.retractedSize(collapsed: cutout, band: 33, hasContent: false)
        require(builtIn == cutout, "the built-in display's idle shell changed (\(builtIn))")
        // A peek still widens, and only widens.
        let peek = ChromeRules.retractedSize(collapsed: cutout, band: 33, hasContent: true)
        // A property, not `cutout.width + miniPlayerWidening`, which would restate
        // the implementation and pass for any widening, including zero.
        require(peek.width > cutout.width + 40,
                "the peek is only \(peek.width - cutout.width)pt wider than the cutout, "
                + "which is not room for artwork and a clock either side of the camera")
        require(peek.width < 400, "the peek is \(peek.width)pt wide — wider than the display's "
                + "usable menu bar on a 13in Mac")
        // Exactly the band, not merely within it: the trace rides this edge, so a
        // point short leaves a hairline of desktop under the progress line.
        require(peek.height == 33, "the peek does not fill the band (\(peek.height) of 33)")
        for band in stride(from: 28.0, through: 40.0, by: 0.5) {
            let p = ChromeRules.retractedSize(collapsed: cutout, band: CGFloat(band),
                                              hasContent: true)
            require(p.height == CGFloat(band),
                    "a peek in a \(band)pt band is \(p.height)pt")
        }
    }

    /// The panel is at least as tall as the thing it lays out. The four numbers
    /// live in `ChromeRules` and Grid and NotchController read them, so this
    /// asserts the values the app lays out with, not local copies.
    static func theExpandedPanelFitsItsContents() {
        require(ChromeRules.expandedBodyFits(body: ChromeRules.expandedBody,
                                             gap: ChromeRules.bandGap,
                                             art: ChromeRules.art,
                                             bottom: ChromeRules.bottom),
                "the panel body is \(ChromeRules.expandedBody)pt for "
                + "\(ChromeRules.bandGap + ChromeRules.art + ChromeRules.bottom)pt of content "
                + "— the gap carries a minLength, so the content is squeezed instead")
        require(ChromeRules.expandedBody
                <= ChromeRules.bandGap + ChromeRules.art + ChromeRules.bottom + 6,
                "the panel body is \(ChromeRules.expandedBody)pt for "
                + "\(ChromeRules.bandGap + ChromeRules.art + ChromeRules.bottom)pt of content "
                + "— that much slack leaves the body floating")
    }

    /// The artwork does not run into the first control. The control row is
    /// centred on the panel, so its left edge depends on the panel and row widths
    /// only; adding a control or growing the sleeve can close the gap.
    static func theArtworkClearsTheControls() {
        let clearance = ChromeRules.artworkClearance(panelWidth: ChromeRules.panelWidth,
                                                     margin: ChromeRules.margin,
                                                     art: ChromeRules.art,
                                                     rowWidth: ChromeRules.controlRowWidth,
                                                     inset: ChromeRules.controlInset)
        require(ChromeRules.artworkFits(panelWidth: ChromeRules.panelWidth,
                                        margin: ChromeRules.margin,
                                        art: ChromeRules.art,
                                        rowWidth: ChromeRules.controlRowWidth,
                                        inset: ChromeRules.controlInset),
                "a \(ChromeRules.art)pt sleeve in a \(ChromeRules.panelWidth)pt panel leaves "
                + "\(clearance)pt before the first control — they overlap below 0")
    }

    /// Play sits on the panel's centre line because the centred group is
    /// transport only (previous, play, next). The modes live in their own cluster
    /// on the right margin, so symmetry is structural; what needs defending is
    /// that nothing else creeps back into the centred group.
    static func playStaysOnThePanelCentreLine() {
        let flank = ChromeRules.slot(ChromeRules.controlDiameter)
        require(ChromeRules.playOffCentre(leftOfPlay: flank, rightOfPlay: flank) == 0,
                "the shipped triad puts play "
                + "\(ChromeRules.playOffCentre(leftOfPlay: flank, rightOfPlay: flank))pt "
                + "off the panel centre line")

        // The rule must still answer non-zero for an asymmetric row, or the line
        // above measures nothing.
        let lopsided = ChromeRules.playOffCentre(
            leftOfPlay: flank + ChromeRules.slot(ChromeRules.modeDiameter),
            rightOfPlay: flank)
        require(abs(lopsided) > 8,
                "one more control on the left moves play \(lopsided)pt — if that is now "
                + "negligible this whole check is measuring nothing")

        require(ChromeRules.controlRowWidth
                == ChromeRules.slot(ChromeRules.controlDiameter) * 2
                + ChromeRules.slot(ChromeRules.primaryDiameter),
                "controlRowWidth (\(ChromeRules.controlRowWidth)) is no longer previous, "
                + "play and next — and it is what the artwork is solved against")

        // The view has to be built that way too: this file compiles ChromeRules
        // alone, so the rule checks above cannot see NotchView.
        let code = strippedSource("Sources/NotchApp/UI/NotchView.swift")
        guard !code.isEmpty else { return }

        // Split at the two group properties: both groups mention buttons, so a
        // file-wide `contains` cannot tell which group a symbol is in.
        guard let triad = section(code, from: "private var transportTriad"),
              let cluster = section(code, from: "private var modeCluster") else {
            require(false, "the control row is no longer built from transportTriad and "
                    + "modeCluster, so this check cannot tell the two groups apart")
            return
        }
        for symbol in ["backward.fill", "play.fill", "forward.fill"] {
            require(triad.contains(symbol), "the centred group has lost \(symbol)")
        }
        for symbol in ["shuffle", "repeat"] {
            require(!triad.contains(symbol),
                    "\(symbol) is back inside the centred group — the group is centred "
                    + "on the panel, so anything on one end of it walks play off the "
                    + "centre line")
            require(cluster.contains(symbol), "the mode cluster has lost \(symbol)")
        }
        require(triad.contains("-(Grid.artwork + Grid.gutter) / 2"),
                "the centred group no longer takes back the sleeve and gutter, so it is "
                + "centred on its own column rather than on the panel")
        require(cluster.contains("alignment: .trailing"),
                "the mode cluster is no longer trailing-aligned, so it does not sit on "
                + "the margin")
        // File-level: the accessor that calls the rule sits beside the cluster,
        // not inside it. Only the use has to be in the cluster.
        require(code.contains("ChromeRules.modeSlots("),
                "the view no longer asks ChromeRules.modeSlots which slots to reserve, "
                + "so a mode moves 30pt when its neighbour is answered")
        require(cluster.contains("modeSlots.shuffle") && cluster.contains("modeSlots.repeat"),
                "the mode buttons are not gated on the reserved slots")
    }

    /// Neither mode moves when the player answers about the other one. The
    /// cluster is trailing-aligned, so its width decides where its left glyph
    /// lands; both slots are reserved whenever either mode is answered.
    static func aModeDoesNotMoveWhenItsNeighbourArrives() {
        let slot = ChromeRules.slot(ChromeRules.modeDiameter)

        // Unreserved, answering only shuffle would make the cluster one slot
        // narrower and shift its first glyph a whole slot right.
        let unreserved = ChromeRules.modeClusterWidth(shuffle: true, repeat: false)
        let both = ChromeRules.modeClusterWidth(shuffle: true, repeat: true)
        require(both - unreserved == slot,
                "reserving one slot instead of two costs \(both - unreserved)pt — if that "
                + "is zero this check is measuring nothing")

        let answers: [Bool?] = [nil, false, true]
        var widths: Set<CGFloat> = []
        for shuffling in answers {
            for repeating in answers where shuffling != nil || repeating != nil {
                let slots = ChromeRules.modeSlots(shuffling: shuffling, repeating: repeating)
                let width = ChromeRules.modeClusterWidth(shuffle: slots.shuffle,
                                                         repeat: slots.repeat)
                widths.insert(width)
                require(slots.shuffle && slots.repeat,
                        "shuffling \(shuffling.map(String.init) ?? "nil"), repeating "
                        + "\(repeating.map(String.init) ?? "nil") reserves \(slots)")
            }
        }
        require(widths.count == 1,
                "the cluster is \(widths.sorted()) wide depending on what the player "
                + "answered, so its glyphs move between answers")

        // Nothing is reserved when the player answers about neither mode.
        let empty = ChromeRules.modeSlots(shuffling: nil, repeating: nil)
        require(!empty.shuffle && !empty.repeat,
                "a player that answers about neither mode still reserves \(empty)")
    }

    /// The transport and the mode cluster read as two groups: the gap between
    /// them must exceed the gap inside the cluster, and the cluster's last disc
    /// lands on the margin the sleeve's left edge sits on.
    static func theModesClearTheTransport() {
        let cluster = ChromeRules.modeClusterWidth(shuffle: true, repeat: true)
        let gap = ChromeRules.modeClusterGap(panelWidth: ChromeRules.panelWidth,
                                             margin: ChromeRules.margin,
                                             rowWidth: ChromeRules.controlRowWidth,
                                             inset: ChromeRules.controlInset,
                                             clusterWidth: cluster)
        require(ChromeRules.modeClusterClears(panelWidth: ChromeRules.panelWidth,
                                              margin: ChromeRules.margin,
                                              rowWidth: ChromeRules.controlRowWidth,
                                              inset: ChromeRules.controlInset,
                                              clusterWidth: cluster),
                "\(gap)pt between the transport and the modes — at or under the "
                + "\(ChromeRules.controlInset * 2)pt inside the cluster they stop reading "
                + "as two groups")

        let margin = ChromeRules.panelWidth - ChromeRules.margin
        func discEdge(offset: CGFloat) -> CGFloat {
            ChromeRules.modeClusterDiscEdge(panelWidth: ChromeRules.panelWidth,
                                            margin: ChromeRules.margin,
                                            inset: ChromeRules.controlInset,
                                            offset: offset)
        }
        require(discEdge(offset: ChromeRules.controlInset) == margin,
                "nudged out by its inset the cluster's last disc ends at "
                + "\(discEdge(offset: ChromeRules.controlInset)), not on the \(margin)pt margin")
        // Trailing alignment alone leaves the disc a padding ring short; without
        // this the assertion above would be two spellings of one sum.
        require(discEdge(offset: 0) == margin - ChromeRules.controlInset,
                "with no nudge the disc ends at \(discEdge(offset: 0)) rather than "
                + "\(ChromeRules.controlInset)pt short of the margin — the offset the view "
                + "applies is not doing anything")

        let code = strippedSource("Sources/NotchApp/UI/NotchView.swift")
        guard !code.isEmpty, let section = section(code, from: "private var modeCluster")
        else {
            require(false, "cannot find the mode cluster to check its margin")
            return
        }
        require(section.contains("offset(x: ChromeRules.controlInset)"),
                "the cluster no longer pushes out by its padding ring, so its disc stops "
                + "4pt short of the margin the sleeve's edge holds")
    }

    /// The column beside the sleeve holds what is stacked in it. The `Spacer`
    /// between the tiers absorbs growing type silently until none is left, and
    /// the control row is then squeezed, which reads as crowding rather than
    /// overflow.
    static func theTypeFitsBesideTheSleeve() {
        require(ChromeRules.textColumnFits(art: ChromeRules.art,
                                           title: ChromeRules.titleLine,
                                           artist: ChromeRules.artistLine,
                                           row: ChromeRules.primaryDiameter),
                "title \(ChromeRules.titleLine) + artist \(ChromeRules.artistLine) + row "
                + "\(ChromeRules.primaryDiameter) is taller than the \(ChromeRules.art)pt "
                + "column they sit in")

        // The rule must reject a tier that is too tall, or it only asserts that
        // numbers exist.
        require(!ChromeRules.textColumnFits(art: ChromeRules.art,
                                            title: ChromeRules.art,
                                            artist: ChromeRules.artistLine,
                                            row: ChromeRules.primaryDiameter),
                "a title as tall as the whole column still 'fits' — the rule is measuring "
                + "nothing")
    }

    /// Off and unavailable are not two brightnesses of the same icon. "On" and
    /// "off" mean press me; "blocked" means pressing does nothing, so each state
    /// must differ from its neighbour in something other than glyph opacity
    /// (PRODUCT.md: every state change must still read). Asserted as properties,
    /// not as the three style triples, which would copy the implementation.
    static func aModeYouCannotUseDoesNotLookLikeOneYouCan() {
        let on = ChromeRules.modeStyle(on: true, blocked: false)
        let off = ChromeRules.modeStyle(on: false, blocked: false)
        let blocked = ChromeRules.modeStyle(on: false, blocked: true)

        require(off.rim != blocked.rim || off.fill != blocked.fill,
                "off (\(off)) and blocked (\(blocked)) differ only in glyph opacity — "
                + "which is the defect this check exists for")
        require(on.fill != off.fill || on.rim != off.rim,
                "on (\(on)) and off (\(off)) differ only in glyph opacity")

        // Legibility floor: below it "off" reads as absent rather than at rest.
        require(off.glyph >= 0.55,
                "an available-but-off mode draws at \(off.glyph) — under the floor "
                + "that made it look like it was not there")
        // Still visibly below ON, or the collision just moves from off/blocked to
        // on/off.
        require(on.glyph - off.glyph >= 0.2,
                "on (\(on.glyph)) and off (\(off.glyph)) are \(on.glyph - off.glyph) apart")
        // Blocked is recessed and loses its rim, the affordance that says
        // pressable, but is still drawn.
        require(blocked.glyph < off.glyph - 0.2,
                "blocked (\(blocked.glyph)) is not clearly dimmer than off (\(off.glyph))")
        require(blocked.rim == 0,
                "blocked keeps \(blocked.rim) of its rim — the edge is the affordance, "
                + "and keeping it is what made it look pressable")
        for (name, st) in [("on", on), ("off", off), ("blocked", blocked)] {
            require(st.glyph > 0.15, "the \(name) glyph is \(st.glyph) — effectively unpainted")
        }

        // The view has to route through the rule. Comments are stripped, since a
        // doc comment naming the function would satisfy the lint by itself.
        let code = strippedSource("Sources/NotchApp/UI/NotchView.swift")
        guard !code.isEmpty else { return }
        require(code.contains("ChromeRules.modeStyle("),
                "the mode toggles no longer ask ChromeRules.modeStyle how to draw, so "
                + "nothing keeps off and unavailable apart")
        // Both structural knobs must reach the buttons. `code.contains("rim:")`
        // is satisfied by TransportButton's own `var rim: Double` declaration, so
        // count the forwarded `Style.<knob>` uses instead.
        for knob in ["rim", "fill"] {
            let forwarded = code.components(separatedBy: "Style.\(knob)").count - 1
            require(forwarded >= 2,
                    "the style's \(knob) reaches \(forwarded) mode buttons, not both — "
                    + "so a state that differs only by \(knob) draws identically")
        }
    }

    /// The heart holds one place on every track, in the repeat toggle's column. It
    /// used to trail the title, so it jumped with each song's length and the button
    /// was never where the hand last found it.
    static func theHeartSitsInRepeatsColumn() {
        let code = strippedSource("Sources/NotchApp/UI/NotchView.swift")
        guard !code.isEmpty, let track = section(code, from: "private var trackLine")
        else {
            require(false, "cannot find trackLine to check where the heart sits")
            return
        }
        require(track.contains("diameter: Grid.mode"),
                "the heart is no longer a mode-sized disc, so it cannot share repeat's column")
        require(track.contains("offset(x: ChromeRules.controlInset)"),
                "the heart no longer pushes out by its padding ring, so its disc stops "
                + "\(ChromeRules.controlInset)pt short of the margin repeat's disc meets")
        require(!track.contains("onGeometryChange"),
                "trackLine measures its text again — the heart is moving with the title")
    }

    /// The scrub strip stays below every control. It is invisible, full-width and
    /// the last child of the root ZStack, so it hit-tests above the transport;
    /// any overlap with the control row would turn a press on play into a seek.
    ///
    /// The 4pt padding is the ring `TransportButton` puts outside its disc. It
    /// draws nothing but is part of the target, so that is what the strip must
    /// clear, not the visible circle.
    static func theScrubStripDoesNotStealThePlayButton() {
        let clearance = ChromeRules.seekStripClearance(
            bottom: ChromeRules.bottom, padding: 4,
            stripHeight: ChromeRules.seekStripHeight,
            stripCentre: ChromeRules.seekStripCentre)
        require(clearance >= 0,
                "the \(ChromeRules.seekStripHeight)pt scrub strip reaches \(-clearance)pt "
                + "into the control row's tap targets — a press on the bottom of play "
                + "seeks to 50% instead of pausing")
        // And it stays on the panel: past the bottom edge it would be a drag
        // target over whatever is behind the window.
        require(ChromeRules.seekStripCentre >= ChromeRules.seekStripHeight / 2,
                "the scrub strip hangs \(ChromeRules.seekStripHeight / 2 - ChromeRules.seekStripCentre)pt "
                + "below the panel")
    }

    /// The retracted progress line fits between the camera and the chrome, and
    /// both edges are asserted: it must not reach up into the cutout, and it must
    /// not spill below the menu-bar band onto the window beneath.
    static func theTraceFitsBetweenTheCameraAndTheChrome() {
        // Sweep the whole band range, not only the built-in display: the shell is
        // clamped to the menu bar while the cutout keeps ScreenMetrics' unclamped
        // 190x32 fallback, so an external display runs with a band near 24 and a
        // cutout that describes nothing on screen. Both styles are swept because
        // "no sliver" means opposite things: a pill has no camera and keeps the
        // full stroke; a notch whose cutout swallows the band has no room under
        // the camera and draws nothing.
        for band in stride(from: 20.0, through: 40.0, by: 0.5) {
            let shell = CGFloat(band), cutout: CGFloat = 32
            for full in [CGFloat(2.5), 3.4, 4] {
                for hasNotch in [true, false] {
                    let w = ChromeRules.retractedTraceWidth(shellHeight: shell,
                                                            cutoutHeight: cutout,
                                                            expandedWidth: full,
                                                            hasNotch: hasNotch)
                    if !hasNotch {
                        require(w > 0, "a \(shell)pt pill band draws the trace at \(w)pt "
                                + "— invisible, with no camera to justify it")
                    } else if shell <= cutout {
                        require(w == 0,
                                "a notched \(shell)pt band whose cutout fills it draws a "
                                + "\(w)pt trace — every point of it is behind the housing")
                        continue
                    } else {
                        require(w > 0, "a \(shell)pt band draws the trace at \(w)pt — invisible")
                    }
                    // `NotchBottomEdge` lays the path out at `height - inset`, so a
                    // negative inset pushes it down and widens it.
                    let centre = shell - ChromeRules.traceInset(strokeWidth: w)
                    let top = centre - w / 2, bottom = centre + w / 2
                    require(bottom <= shell + 0.001,
                            "a \(w)pt retracted trace on a \(shell)pt band reaches \(bottom) — "
                            + "\(bottom - shell)pt of it is drawn on the window chrome "
                            + "below the menu bar")
                    // Only where a camera is actually above the shell.
                    if hasNotch, shell > cutout {
                        require(top >= cutout - 0.001,
                                "a \(w)pt trace reaches \(top), which is \(cutout - top)pt "
                                + "inside the cutout")
                    }
                }
            }
        }
        let e = ChromeRules.traceInset(strokeWidth: 2.5)
        require(e == 1.25, "the expanded trace stopped hugging the silhouette (\(e))")

        // The line spends all of the sliver between band and cutout: a thinner
        // line would leave a hairline of desktop under the peek.
        let fitted = ChromeRules.retractedTraceWidth(shellHeight: 33, cutoutHeight: 32,
                                                     expandedWidth: 2.5, hasNotch: true)
        require(fitted == 1,
                "the retracted trace is \(fitted)pt in the 1pt between band and cutout")
    }

    /// The played fill has an unplayed remainder behind it, and the two are the
    /// same line. A `.trim` from zero alone leaves the bottom edge bare past the
    /// playhead, so the silhouette's break point travels as the track plays. The
    /// track must be the same path at the same width and inset as the fill, not
    /// a copy with numbers of its own.
    static func theTraceHasSomethingToRunAlong() {
        let code = strippedSource("Sources/NotchApp/UI/NotchView.swift")
        // Anchored on the whole declaration: the name alone also matched a
        // renamed `progressTrackDisabled` outside the body's reach.
        guard let track = section(code, from: "private var progressTrack: some View") else {
            require(false, "the progress trace has no track behind it")
            return
        }
        require(track.contains("lineWidth: traceWidth"),
                "the track sets its own width instead of the trace's")
        require(track.contains("inset: traceInset"),
                "the track sets its own inset instead of the trace's")
        // Trimmed, the remainder would stop where the fill does.
        require(!track.contains(".trim("),
                "the track is trimmed, so it ends where the fill ends")

        // Behind the fill, not over it. `ZStack` draws in source order, so this is
        // a claim about the body.
        guard let body = section(code, from: "var body: some View") else {
            require(false, "cannot find NotchView's body")
            return
        }
        guard let trackAt = body.range(of: "progressTrack"),
              let fillAt = body.range(of: "progressEdge") else {
            require(false, "the body draws no trace")
            return
        }
        require(trackAt.lowerBound < fillAt.lowerBound,
                "the track is drawn over the fill, not behind it")

        // The line ends the same way retracted and expanded.
        guard let tip = section(code, from: "private var playhead") else {
            require(false, "the trace has no playhead")
            return
        }
        require(tip.contains("traceWidth"),
                "the retracted playhead is not the trace's own width, so the peek "
                + "and the panel end the same line differently")
    }

    /// The retracted clock reads a moving value at display rate, not at the poll
    /// rate. `media.position` is rewritten only when a snapshot arrives (a 1s
    /// sleep plus the synchronous ScriptingBridge round trips, 88-199ms against
    /// Spotify), so a clock reading it steps about 1.09s at a time and skips a
    /// second every eleventh poll or so.
    ///
    /// Both halves are asserted, since either alone still steps:
    /// `smoothPosition` outside a timeline is re-read only when the poll
    /// invalidates the body, and a timeline around the raw value re-reads a
    /// number that did not change. Sliced to `CollapsedActivity`, because the
    /// expanded player names `smoothPosition` too and a file-wide search would
    /// pass with the band still reading raw.
    static func theRetractedClockDoesNotStepAtThePollRate() {
        let code = strippedSource("Sources/NotchApp/UI/NotchView.swift")
        guard !code.isEmpty else { return }
        guard let band = topLevelSection(code, from: "struct CollapsedActivity") else {
            require(false, "cannot find CollapsedActivity in NotchView.swift — "
                    + "this check reads a slice and just became a no-op")
            return
        }

        // Check the call's argument, not the slice's vocabulary: any other
        // mention of smoothPosition would satisfy a plain `contains`.
        guard let call = band.range(of: "ExpandedPlayer.time(") else {
            require(false, "the retracted band no longer renders a clock at all")
            return
        }
        let argument = band[call.upperBound...].prefix { $0 != ")" }
        require(argument.contains("smoothPosition"),
                "the retracted clock renders \(argument), which is only rewritten "
                + "when a poll lands — so it advances in ~1.09s steps and visibly "
                + "skips a second about every eleventh poll")

        guard let timeline = band.range(of: "TimelineView") else {
            require(false, "the retracted clock is not inside a TimelineView, so "
                    + "the interpolated position is re-read only when the poll "
                    + "invalidates the body — which is the stepping it was "
                    + "supposed to fix")
            return
        }
        require(timeline.lowerBound < call.lowerBound,
                "the retracted band has a TimelineView, but the clock is not "
                + "inside it")

        // The band is the always-on state, so a timeline that keeps ticking while
        // playback is stopped spends CPU on a value that cannot change.
        let head = band[timeline.lowerBound..<call.lowerBound]
        require(head.contains("paused:") && head.contains("isPlaying"),
                "the retracted clock's timeline is not paused on playback, so it "
                + "re-reads a frozen value while the player is stopped")
    }

    /// The expanded band's clocks have the same poll-rate stepping hazard as the
    /// retracted one, so they get the same two-part check: a timeline, and a live
    /// read inside it. A timeline over a `Double` captured at init re-renders the
    /// same stale second, and a live read outside a timeline is only re-evaluated
    /// when the poll invalidates the body. The scrub still owns the clocks while a
    /// drag is in flight (`shownPosition` lets it land on a second), so the live
    /// read yields only then.
    static func theBandClocksDoNotStepAtThePollRate() {
        let code = strippedSource("Sources/NotchApp/UI/NotchView.swift")
        guard !code.isEmpty else { return }
        // The band clocks are their own always-present layer, so they can ride
        // the shell's edges on close instead of keeping the panel's last layout.
        guard let player = topLevelSection(code, from: "struct PanelClocks") else {
            require(false, "cannot find PanelClocks in NotchView.swift — "
                    + "this check reads a slice and just became a no-op")
            return
        }
        guard let call = player.range(of: "ExpandedPlayer.time(") else {
            require(false, "the expanded band no longer renders a clock at all")
            return
        }
        guard let timeline = player.range(of: "TimelineView") else {
            require(false, "the band clocks are not inside a TimelineView, so they "
                    + "re-render only when the poll re-inits the player — the "
                    + "~1.09s stepping this file has now fixed three times")
            return
        }
        require(timeline.lowerBound < call.lowerBound,
                "the expanded band has a TimelineView, but the clocks are not "
                + "inside it")

        // The head must bind the live position, and the call must not render the
        // parameter frozen at init.
        let head = player[timeline.lowerBound..<call.lowerBound]
        require(head.contains("media.smoothPosition"),
                "the band clocks never read media.smoothPosition inside their "
                + "timeline, so the schedule re-renders a value only the poll "
                + "rewrites")
        let argument = player[call.upperBound...].prefix { $0 != ")" }
        require(!argument.contains("shownPosition"),
                "the elapsed clock renders \(argument), the parameter frozen at "
                + "init — the timeline ticks, the second does not")

        // Paused while nothing plays, and while a scrub is in flight, the one
        // moment the frozen parameter is the truth.
        require(head.contains("paused:") && head.contains("isPlaying")
                    && head.contains("scrubbing"),
                "the band clocks' timeline is not paused on both playback and "
                + "scrubbing, so it either burns frames on a stopped player or "
                + "fights the drag for the clocks")
    }

    /// The panel's outline exists on any backdrop, and one value draws it. A
    /// top-lit highlight that dims along the sides is invisible over a dark
    /// window title bar, so the rim must hold a single alpha from the top to the
    /// handoff, and the bottom edge belongs to whoever draws it (the rim or the
    /// trace, never both and never neither).
    static func thePanelHasAnEdgeOnAnyBackdrop() {
        // Every geometry the rim is drawn in: the expanded panel, the idle card,
        // the peek and the idle shell, at radii from a fallback pill's to the
        // panel's own.
        for h in stride(from: 30.0, through: 200.0, by: 2.0) {
            let height = CGFloat(h)
            for r in stride(from: 0.0, through: 24.0, by: 3.0) {
                let radius = CGFloat(r)
                for track in [CGFloat?.none, ChromeRules.traceStroke] {
                    for (expanded, hovering) in [(true, false), (true, true),
                                                 (false, true), (false, false)] {
                        let stops = ChromeRules.rimStops(expanded: expanded,
                                                         hovering: hovering,
                                                         traceStrokeWidth: track,
                                                         height: height,
                                                         bottomRadius: radius)
                        let at = "\(height)x\(radius), expanded \(expanded), "
                               + "hovering \(hovering), track \(String(describing: track))"
                        // A changed stop count snaps instead of interpolating when
                        // the panel morphs, so every branch must agree on it.
                        require(stops.count == 3, "the rim has \(stops.count) stops at \(at)")
                        require(stops[0].location <= stops[1].location
                                && stops[1].location <= stops[2].location,
                                "the rim's stops run backwards at \(at)")
                        for s in stops {
                            require(s.location >= 0 && s.location <= 1,
                                    "a rim stop sits at \(s.location) at \(at)")
                            require(s.alpha >= 0 && s.alpha <= 1,
                                    "a rim stop is \(s.alpha) at \(at)")
                        }
                        // One value from the top to the handoff; any dimming
                        // between them is a highlight, not an edge.
                        require(stops[0].alpha == stops[1].alpha,
                                "the rim is \(stops[0].alpha) at the top and "
                                + "\(stops[1].alpha) at the handoff — it dims along the "
                                + "outline at \(at)")
                        if expanded {
                            require(stops[0].alpha >= ChromeRules.rimFloor,
                                    "the expanded rim draws the sides at \(stops[0].alpha), "
                                    + "under the \(ChromeRules.rimFloor) floor, at \(at)")
                            // Lit under a track the bottom doubles the rail; dark
                            // with no track the silhouette simply stops.
                            require((stops[2].alpha > 0) == (track == nil),
                                    "the rim closes the bottom at \(stops[2].alpha) at \(at)")
                        } else {
                            // Retracted, the outer half of a centred stroke lands
                            // on the window chrome below the band, so the bottom is
                            // never the rim's, hovered or not.
                            require(stops[2].alpha == 0,
                                    "the retracted rim draws the shell's bottom edge "
                                    + "at \(stops[2].alpha) at \(at)")
                            // Not `== rimHoverAlpha`, which would hold for any value
                            // of the constant, zero included. The rule is that the
                            // hover rim is the notch's only acknowledgement during
                            // `hoverDuration`: it may rise and may not fall.
                            require(hovering ? stops[0].alpha >= 0.15 : stops[0].alpha == 0,
                                    "the retracted rim is \(stops[0].alpha) at \(at)")
                        }
                    }
                }
            }
        }

        // The handoff is where the trace's cap can reach, not a tuned constant.
        let withTrack = ChromeRules.rimHandoffDepth(bottomRadius: 24,
                                                    traceStrokeWidth: ChromeRules.traceStroke)
        let without = ChromeRules.rimHandoffDepth(bottomRadius: 24, traceStrokeWidth: nil)
        require(withTrack == 24 + ChromeRules.traceStroke,
                "the handoff no longer clears the trace's own cap (\(withTrack))")
        require(without == 24,
                "with nothing on the bottom edge the rim stops short of the corner (\(without))")

        // And the view asks for the schedule rather than writing one.
        let code = strippedSource("Sources/NotchApp/UI/NotchView.swift")
        guard let chrome = section(code, from: "private var chrome: some View") else {
            require(false, "cannot find the chrome to check its rim")
            return
        }
        require(chrome.contains("ChromeRules.rimStops("),
                "the rim's schedule is written in the view, where nothing can fail it")
    }

    /// A trace with no room to draw (zero width) never reaches the rasteriser, and
    /// the view takes that decision from `ChromeRules.drawsTrace`.
    static func aTraceWithNoRoomIsNotDrawn() {
        let code = strippedSource("Sources/NotchApp/UI/NotchView.swift")
        require(!ChromeRules.drawsTrace(hasTrack: true, hasShell: true, width: 0),
                "a zero-width trace still reaches the rasterizer")
        require(ChromeRules.drawsTrace(hasTrack: true, hasShell: true, width: 1),
                "the valid 1pt progress trace disappeared")
        let gate = section(code, from: "private var trackDrawn: Bool") ?? ""
        require(gate.contains("ChromeRules.drawsTrace(") && gate.contains("width: traceWidth"),
                "the view does not suppress a trace with no room to draw")
    }

    /// The image fills its tile at both 19pt and 88pt; only its corners are cut.
    static func noRingOrMatteSurroundsThePrint() {
        guard let art = topLevelSection(strippedSource("Sources/NotchApp/UI/NotchView.swift"),
                                        from: "private struct Artwork") else {
            require(false, "cannot find the sleeve to check its edge")
            return
        }
        for border in ["sleeveMount", "sleeveBevel", "mountInset", "strokeBorder", ".stroke(", ".fill(.black)"] {
            require(!art.contains(border), "noRingOrMatteSurroundsThePrint: artwork still draws \(border)")
        }
        require(art.contains("face\n            .frame(maxWidth: .infinity, maxHeight: .infinity)"),
                "the print does not fill the tile's full footprint")
        // The sleeve must be sized outside the matched geometry, or the effect
        // can move it between mini player and panel but never resize it, leaving
        // two covers, the 19pt one in the corner of the 88pt one.
        let code = strippedSource("Sources/NotchApp/UI/NotchView.swift")
        let matched = code.components(separatedBy: ".matchedGeometryEffect(id: \"artwork\", in: glass)")
        require(matched.count == 3, "expected the sleeve matched in exactly two places")
        for after in matched.dropFirst() {
            require(after.drop(while: \.isWhitespace).hasPrefix(".frame(width:"),
                    "a sleeve is sized inside its matched geometry, so it cannot morph")
        }
        require(ChromeRules.sleeveShadow(size: 19).opacity == 0
                && ChromeRules.sleeveShadow(size: 88).opacity > 0,
                "only the large cover should cast a lift shadow")
        guard let flatten = art.range(of: "compositingGroup"),
              let shadow = art.range(of: ".shadow(") else {
            require(false, "the sleeve is not flattened before it casts a shadow")
            return
        }
        require(flatten.lowerBound < shadow.lowerBound,
                "the sleeve casts its shadow before it is flattened, so every layer "
                + "of the mount casts one")
    }

    /// One of the two forms of the title is always on screen. The static label
    /// and the scroller are gated by the same predicate, so with Reduce Motion on
    /// an overflowing title must fall back to the static label, never to nothing.
    static func theTitleIsNeverBlank() {
        // A handful of representative cases, not a sweep: while both gates share
        // one predicate the result is independent of the inputs. The assertion is
        // there to fail if the two gates are ever keyed on different things again.
        for (text, box) in [(200.0, 100.0), (100.0, 200.0), (0.0, 0.0), (101.0, 100.0)] {
            for reduce in [false, true] {
                require(ChromeRules.marqueeShowsSomething(textWidth: CGFloat(text),
                                                          boxWidth: CGFloat(box),
                                                          reduceMotion: reduce),
                        "text \(text) in a \(box) box with reduceMotion \(reduce) "
                        + "renders nothing at all")
            }
        }
        // Reduce Motion must take the movement out, not the words.
        require(!ChromeRules.marqueeScrolling(textWidth: 200, boxWidth: 100, reduceMotion: true),
                "Reduce Motion did not stop the marquee")
        require(ChromeRules.marqueeScrolling(textWidth: 200, boxWidth: 100, reduceMotion: false),
                "an overflowing title stopped scrolling entirely")
    }

    /// Animation curves come from `Motion`, the one place they are written; an
    /// inline spring bypasses it. PRODUCT.md no longer promises Reduce Motion
    /// support, but the mechanism costs one branch and keeping every curve in one
    /// vocabulary prevents a stray spring ringing past its rest size.
    static func everyCurveAsksAboutReduceMotion() {
        let fm = FileManager.default
        var offenders: [String] = []
        var scanned = 0
        for dir in ["Sources/NotchApp/UI", "Sources/NotchApp/Notch", "Sources/NotchApp/App"] {
            // Fail rather than `continue`: the paths are relative, so run from
            // anywhere but the repo root every one would fail to resolve and the
            // lint would pass having read nothing.
            guard let files = try? fm.contentsOfDirectory(atPath: dir) else {
                require(false, "cannot read \(dir) — run check.sh from the repo root")
                return
            }
            for file in files where file.hasSuffix(".swift") {
                // Motion's own declarations are the one place curves are written.
                if file == "NotchShape.swift" { continue }
                guard let body = try? String(contentsOfFile: "\(dir)/\(file)", encoding: .utf8)
                else { continue }
                scanned += 1
                let lines = body.components(separatedBy: "\n")
                for (n, line) in lines.enumerated() {
                    guard line.contains(".spring(") || line.contains(".bouncy(")
                            || line.contains(".interpolatingSpring(") else { continue }
                    // Branched right here, or within the two lines above it.
                    let window = lines[max(0, n - 2)...n].joined()
                    if window.contains("Motion.reduceMotion") { continue }
                    offenders.append("\(dir)/\(file):\(n + 1)")
                }
            }
        }
        require(scanned > 10, "the curve lint read only \(scanned) files")
        require(offenders.isEmpty,
                "curve written inline without asking about Reduce Motion — "
                + "use a Motion.* curve or branch on Motion.reduceMotion: "
                + offenders.joined(separator: ", "))
    }

    /// A strip you cannot scrub is not offered. `MediaManager.seek(toFraction:)`
    /// returns early when `duration` is not positive, so on a stream or a track
    /// whose length has not arrived a drag does nothing. Through the
    /// accessibility API the strip would still announce an adjustable
    /// "Playback Position" that never moves, so it must be gated on the duration
    /// as well as on `hasTrack`.
    static func theScrubStripIsNotOfferedWithoutADuration() {
        let code = strippedSource("Sources/NotchApp/UI/NotchView.swift")
        let gate = code.split(separator: "\n", omittingEmptySubsequences: false)
            .first { $0.contains("{ seekStrip }") }
        require(gate != nil,
                "the seek strip's call site has moved or changed shape; this check "
                + "reads the line that offers it and can no longer find it")
        require(gate?.contains("duration") == true,
                "the seek strip is offered without asking about the duration, so a "
                + "stream with none gets a full-width drag target and a VoiceOver "
                + "adjustable that both do nothing: \(gate ?? "")")
    }

    /// The title's two gates come from the rule, not from the view. The rule's
    /// own check cannot see whether `MarqueeText` still asks it, and re-inlining
    /// either gate would bring back the blank title under Reduce Motion with
    /// every rule still consistent with itself.
    static func theTitleTakesBothGatesFromTheRule() {
        let code = strippedSource("Sources/NotchApp/UI/MarqueeText.swift")
        require(code.contains("ChromeRules.marqueeHidesStaticLabel("),
                "MarqueeText no longer asks ChromeRules whether to hide the static "
                + "label, so the gate it applies can drift from the one that is checked")
        require(code.contains("ChromeRules.marqueeShowsScroller("),
                "MarqueeText no longer asks ChromeRules whether to show the scroller, "
                + "so the gate it applies can drift from the one that is checked")
        // `marqueeScrolls` is overflow alone; both gates must reach it only
        // through `marqueeScrolling`, which also asks about Reduce Motion.
        require(!code.contains("ChromeRules.marqueeScrolls("),
                "MarqueeText keys a gate on marqueeScrolls, which does not ask about "
                + "Reduce Motion — the exact pairing that left the title row blank")
    }

    /// The sheet's lean under a live swipe never leaves the margins beside it.
    /// The caps are the margins' slack, so they are held against the layout that
    /// produces it. Expanded, content sits `margin` off the shell edge and its
    /// nearest disc keeps a `controlInset` ring of air. Retracted, the slack is
    /// the flanks' edge padding, a view literal that is read from the view
    /// rather than restated here.
    static func theSheetLeanStaysInsideTheMargins() {
        for expanded in [false, true] {
            let cap = expanded ? ChromeRules.swipeShiftCapExpanded
                               : ChromeRules.swipeShiftCapRetracted
            var previous: CGFloat = 0
            for progress in stride(from: CGFloat(0), through: 1, by: 0.01) {
                for reached in 0...3 {
                    for direction in [CGFloat(-1), 1] {
                        let shift = ChromeRules.swipeShift(
                            direction: direction, progress: progress,
                            reached: reached, expanded: expanded)
                        require(abs(shift) <= cap + 1e-9,
                                "the sheet leaned \(shift)pt past its \(cap)pt cap "
                                + "(expanded: \(expanded))")
                        require(shift == 0 || (shift > 0) == (direction > 0),
                                "the sheet leaned against the fingers: \(shift) "
                                + "for direction \(direction)")
                    }
                    // A banked detent never pulls the sheet back.
                    let below = ChromeRules.swipeShift(
                        direction: 1, progress: progress,
                        reached: max(0, reached - 1), expanded: expanded)
                    let here = ChromeRules.swipeShift(
                        direction: 1, progress: progress,
                        reached: reached, expanded: expanded)
                    require(here >= below - 1e-9,
                            "banking a detent moved the sheet backwards: "
                            + "\(here) after \(below)")
                }
                let shift = ChromeRules.swipeShift(direction: 1, progress: progress,
                                                   reached: 0, expanded: expanded)
                require(shift >= previous - 1e-9,
                        "the sheet retreated as the swipe advanced: \(shift) "
                        + "after \(previous)")
                previous = shift
            }
            require(ChromeRules.swipeShift(direction: 1, progress: 0,
                                           reached: 0, expanded: expanded) == 0,
                    "the sheet leans with no swipe in flight")
        }

        require(ChromeRules.swipeShiftCapExpanded
                    <= ChromeRules.margin - ChromeRules.controlInset,
                "the expanded cap (\(ChromeRules.swipeShiftCapExpanded)) spends "
                + "more than the margin's slack, so a full swipe slides content "
                + "under the bezel")

        guard let flanks = topLevelSection(
                strippedSource("Sources/NotchApp/UI/NotchView.swift"),
                from: "struct CollapsedActivity"),
              let padding = horizontalPadding(in: flanks) else {
            require(false, "CollapsedActivity or its edge padding has moved; "
                    + "this check reads the flank padding the retracted cap "
                    + "spends from")
            return
        }
        require(ChromeRules.swipeShiftCapRetracted
                    <= padding - ChromeRules.controlInset,
                "the retracted cap (\(ChromeRules.swipeShiftCapRetracted)) spends "
                + "more than the flanks' \(padding)pt edge padding leaves, so a "
                + "full swipe slides the peek under the bezel")
    }

    /// The first `.padding(.horizontal, N)` literal in a stretch of view code.
    static func horizontalPadding(in code: String) -> CGFloat? {
        guard let call = code.range(of: ".padding(.horizontal, ") else { return nil }
        let rest = code[call.upperBound...]
        guard let close = rest.firstIndex(of: ")") else { return nil }
        return Double(rest[..<close].trimmingCharacters(in: .whitespaces))
            .map { CGFloat($0) }
    }

    /// The view takes the sheet's shift from the rule, and passes the rule the
    /// real HUD state: the refusal lives in `SwipeRecogniser.sheetShift`, and a
    /// leaf that stopped consulting it would lean the HUD's meter under the
    /// camera housing while every rule stayed self-consistent.
    static func theSheetTakesItsShiftFromTheRule() {
        let code = strippedSource("Sources/NotchApp/UI/NotchView.swift")
        require(code.contains("SwipeRecogniser.sheetShift("),
                "the view no longer asks SwipeRecogniser.sheetShift, so the "
                + "shift it applies can drift from the one that is checked")
        guard let leaf = topLevelSection(code, from: "struct SwipeLeanFrame") else {
            require(false, "SwipeLeanFrame has moved or been renamed; this "
                    + "lint reads it")
            return
        }
        require(leaf.contains("notification.isSome"),
                "the leaf no longer passes the HUD's presence, so the refusal "
                + "the rule holds is never consulted")
    }

    /// A source file with its comments removed. The text-scan lints need this:
    /// against the raw file, a doc comment naming a call satisfies a lint that
    /// asserts the view makes it.
    static func strippedSource(_ path: String) -> String {
        guard let body = try? String(contentsOfFile: path, encoding: .utf8) else {
            require(false, "cannot read \(path) — run check.sh from the repo root")
            return ""
        }
        return body.split(separator: "\n", omittingEmptySubsequences: false)
            .map { line -> Substring in
                guard let slashes = line.range(of: "//") else { return line }
                return line[line.startIndex..<slashes.lowerBound]
            }
            .joined(separator: "\n")
    }

    /// One member's text, from its declaration to the next declaration beside it.
    /// Bounding the slice matters: asking whether shuffle is inside the centred
    /// group against the whole file is answered by the cluster below it.
    static func section(_ code: String, from marker: String) -> String? {
        guard let start = code.range(of: marker) else { return nil }
        let rest = code[start.upperBound...]
        var end = rest.endIndex
        for token in ["\n    private var ", "\n    private func ",
                      "\n    var ", "\n    func ", "\n    static func "] {
            if let next = rest.range(of: token), next.lowerBound < end {
                end = next.lowerBound
            }
        }
        return String(rest[..<end])
    }

    /// One top-level declaration's text. `section` stops at the next member
    /// indented beside its anchor, which for a type would end at the type's own
    /// first property.
    static func topLevelSection(_ code: String, from marker: String) -> String? {
        guard let start = code.range(of: marker) else { return nil }
        let rest = code[start.upperBound...]
        var end = rest.endIndex
        for token in ["\nstruct ", "\nprivate struct ", "\nfinal class ", "\nclass ",
                      "\nprivate class ", "\nenum ", "\nprivate enum ",
                      "\nextension ", "\nprivate extension "] {
            if let next = rest.range(of: token), next.lowerBound < end {
                end = next.lowerBound
            }
        }
        return String(rest[..<end])
    }

    static func require(_ ok: Bool, _ message: @autoclosure () -> String) {
        if !ok { print("chromecheck: \(message())"); exit(1) }
    }
}
