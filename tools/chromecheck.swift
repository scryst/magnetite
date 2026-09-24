import Foundation
import CoreGraphics

/// Headless checks on chrome layout and the animation vocabulary.
///
/// This suite exists because an audit against PRODUCT.md found four violations
/// that five other suites could not have caught: they cover physics, geometry,
/// gestures, media and palette, and every one of the four lived here.
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
        theHeartTrailsTheTitleNotTheMargin()
        theTraceFitsBetweenTheCameraAndTheChrome()
        theTraceHasSomethingToRunAlong()
        theRetractedClockDoesNotStepAtThePollRate()
        theBandClocksDoNotStepAtThePollRate()
        thePanelHasAnEdgeOnAnyBackdrop()
        theSleevesEdgeDoesNotDependOnTheAlbum()
        everyCurveAsksAboutReduceMotion()
        theSheetLeanStaysInsideTheMargins()
        theSheetTakesItsShiftFromTheRule()
        print("chromecheck: all checks passed")
    }

    /// The retracted shell never takes more room than the display gave it.
    ///
    /// `theRetractedShellNeverLeavesTheBand` proves the clamp works. It cannot
    /// see what the clamp is being HANDED, and the answer was the shell's own
    /// collapsed height whenever the band could not be measured — which is every
    /// plain desktop with "Automatically hide and show the menu bar" on, because
    /// `visibleFrame.maxY` then equals `frame.maxY`. `min(h, h)` is `h`, so the
    /// guard that exists to keep the retracted shell off window chrome passed the
    /// full pill through in the one configuration where the strip beneath it
    /// belongs to whatever window is there. The app knew the signal was
    /// meaningless there — `NotchCoordinator.menuBarIsHidden` refuses to use it
    /// for exactly this reason — and the geometry used it anyway.
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

        // And the cutout is a ceiling: a shell bigger than it cannot talk its
        // way past, however large it is asked to be.
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

        // No band and no cutout: every pixel it could take belongs to a window,
        // and it says so rather than taking them.
        let nothing = ChromeRules.retractedBand(measured: 0, cutout: nil)
        for hasContent in [false, true] {
            let size = ChromeRules.retractedSize(collapsed: CGSize(width: 190, height: 32),
                                                 band: nothing, hasContent: hasContent)
            require(size.height == 0,
                    "with no band and no cutout the retracted shell still claimed "
                    + "\(size.height)pt of somebody's window (content: \(hasContent))")
        }
    }

    /// Height is pinned to the hardware, in BOTH branches.
    ///
    /// On a display with no notch `collapsed` is a 190x32 fallback pill while the
    /// real band can be shorter, and the idle branch returned it unclamped — so
    /// the shell hung onto the window chrome underneath, which is the
    /// anti-reference verbatim and worst when nothing is playing.
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
        // A property, not a restatement. Asserting
        // `width == cutout.width + peekWidening` is the implementation written
        // twice and passes for any value of `peekWidening`, including zero.
        require(peek.width > cutout.width + 40,
                "the peek is only \(peek.width - cutout.width)pt wider than the cutout, "
                + "which is not room for artwork and a clock either side of the camera")
        require(peek.width < 400, "the peek is \(peek.width)pt wide — wider than the display's "
                + "usable menu bar on a 13in Mac")
        // EXACTLY the band, not merely within it. The trace rides this edge, so
        // a point short puts the progress line above the menu bar's bottom with
        // a hairline of desktop beneath it — which is what happened when both
        // branches were given the same clamp.
        require(peek.height == 33, "the peek does not fill the band (\(peek.height) of 33)")
        for band in stride(from: 28.0, through: 40.0, by: 0.5) {
            let p = ChromeRules.retractedSize(collapsed: cutout, band: CGFloat(band),
                                              hasContent: true)
            require(p.height == CGFloat(band),
                    "a peek in a \(band)pt band is \(p.height)pt")
        }
    }

    /// The panel is at least as tall as the thing it lays out.
    ///
    /// This check was written against LOCAL COPIES of Grid's and
    /// NotchController's numbers, under a comment claiming they were "Grid's own
    /// numbers". check.sh compiles this file against ChromeRules alone, so those
    /// files are not in the compilation unit and no edit to either could ever
    /// fail it: bandGap 24 -> 40, bottom 14 -> 30 and expandedBodyHeight 94 -> 60
    /// — a 66pt shortfall — all passed. The commit that added it claimed
    /// "verified to fail at 90", which was only true of editing the literal here.
    ///
    /// The four numbers now live in ChromeRules and Grid and NotchController read
    /// them, so this asserts the values the app actually lays out with.
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

    /// The artwork does not run into the first control.
    ///
    /// This one has gone wrong twice for the same reason: the control row is
    /// centred on the PANEL, so its left edge is fixed by the panel's width and
    /// the row's own width, and nothing about the artwork moves it. Adding a
    /// sixth control widened the row and pushed that edge left into the sleeve;
    /// growing the sleeve later walked into it from the other side. Both showed
    /// up as the shuffle glyph sitting on the album art.
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

    /// Play sits on the panel's centre line, and the centred group is transport
    /// only.
    ///
    /// The row is centred on the panel, so play is on the centre line only while
    /// the group is symmetric about it. That used to depend on what the player
    /// had answered: shuffle and repeat sat in this row and were hidden
    /// independently, so a player answering one and not the other — Apple Music
    /// reads the two through separate keys and either can come back nil — left
    /// [shuffle][gap][prev][play][next][gap], 165pt with play 15pt off its own
    /// middle.
    ///
    /// The modes are their own cluster on the right margin now, so symmetry is
    /// structural. Which means the OLD assertion — play off-centre is zero for
    /// every combination of answers — has become a tautology that would pass
    /// against any code at all. What still has to be defended is the reason it
    /// is a tautology: that nothing but previous, play and next is in the
    /// centred group.
    static func playStaysOnThePanelCentreLine() {
        let flank = ChromeRules.slot(ChromeRules.controlDiameter)
        require(ChromeRules.playOffCentre(leftOfPlay: flank, rightOfPlay: flank) == 0,
                "the shipped triad puts play "
                + "\(ChromeRules.playOffCentre(leftOfPlay: flank, rightOfPlay: flank))pt "
                + "off the panel centre line")

        // The rule still answers non-zero for a row that is not symmetric, or
        // the line above is measuring nothing. A mode disc on one end is the
        // exact shape the old defect had, and it is worth 15pt.
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

        // And the VIEW has to be built that way. chromecheck compiles
        // ChromeRules alone, so everything above passes forever while NotchView
        // quietly puts a mode back into the centred group — which is exactly
        // how the defect arrived. Same text-scan mechanism the curve lint uses
        // for the same reason.
        let code = strippedSource("Sources/NotchApp/UI/NotchView.swift")
        guard !code.isEmpty else { return }

        // Split at the two group properties rather than searching the whole
        // file: both groups mention buttons, so a file-wide `contains` cannot
        // tell which group a symbol is in — and which group it is in is the
        // entire claim.
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
        // File-level: the accessor that calls the rule is a property beside the
        // cluster, not inside it. Only the USE has to be in the cluster.
        require(code.contains("ChromeRules.modeSlots("),
                "the view no longer asks ChromeRules.modeSlots which slots to reserve, "
                + "so a mode moves 30pt when its neighbour is answered")
        require(cluster.contains("modeSlots.shuffle") && cluster.contains("modeSlots.repeat"),
                "the mode buttons are not gated on the reserved slots")
    }

    /// Neither mode moves when the player answers about the other one.
    ///
    /// The cluster is trailing-aligned, so its WIDTH decides where its left
    /// glyph lands. Reserve only the slot you can fill and shuffle draws in
    /// repeat's place, then jumps a whole slot left the moment repeat is
    /// answered. Same both-or-neither arithmetic that used to keep play
    /// centred, kept for a different reason and asserted against that reason.
    static func aModeDoesNotMoveWhenItsNeighbourArrives() {
        let slot = ChromeRules.slot(ChromeRules.modeDiameter)

        // The hazard first: unreserved, answering only shuffle makes the cluster
        // one slot narrower, and a trailing-aligned group that is narrower puts
        // its first glyph a whole slot further right.
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

        // And nothing is reserved when there is nothing to say at all, or the
        // panel holds 60pt open for two buttons that never come.
        let empty = ChromeRules.modeSlots(shuffling: nil, repeating: nil)
        require(!empty.shuffle && !empty.repeat,
                "a player that answers about neither mode still reserves \(empty)")
    }

    /// The two groups on the control line are two groups.
    ///
    /// Between them is the air the sleeve grew into; inside the cluster the two
    /// discs touch. If the gap between the groups ever falls to the gap inside
    /// one, the line reads as one uneven row of five again — which is the
    /// reading the modes were moved out of.
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

        // The cluster's own trailing disc lands on the margin, which is the line
        // the sleeve's left edge sits on.
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
        // And the nudge is what puts it there — trailing alignment alone leaves
        // the disc a padding ring short. Without this the line above is two
        // spellings of one sum and passes for any code at all.
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

    /// The column beside the sleeve holds what is stacked in it.
    ///
    /// Type grew with the sleeve, and nothing about growing type says stop: the
    /// `Spacer` between the tiers absorbs it silently until there is none, and
    /// then the control row is squeezed instead. That reads as crowding rather
    /// than as an overflow, which is how the panel stayed 4pt short of its own
    /// contents for so long.
    static func theTypeFitsBesideTheSleeve() {
        require(ChromeRules.textColumnFits(art: ChromeRules.art,
                                           title: ChromeRules.titleLine,
                                           artist: ChromeRules.artistLine,
                                           row: ChromeRules.primaryDiameter),
                "title \(ChromeRules.titleLine) + artist \(ChromeRules.artistLine) + row "
                + "\(ChromeRules.primaryDiameter) is taller than the \(ChromeRules.art)pt "
                + "column they sit in")

        // And the rule is not satisfied by everything: one tier too tall has to
        // fail it, or it is asserting that numbers exist.
        require(!ChromeRules.textColumnFits(art: ChromeRules.art,
                                            title: ChromeRules.art,
                                            artist: ChromeRules.artistLine,
                                            row: ChromeRules.primaryDiameter),
                "a title as tall as the whole column still 'fits' — the rule is measuring "
                + "nothing")
    }

    /// Off and unavailable are not two brightnesses of the same icon.
    ///
    /// The toggles shipped as three opacities of one glyph — 1.0 on, 0.38 off,
    /// 0.16 blocked. Photographed side by side on ONE ground at one instant,
    /// OFF and BLOCKED were the same dim icon. One means "press me"; the other
    /// means "pressing does nothing". PRODUCT.md: "every state change must
    /// still read".
    ///
    /// So this asserts the property that fixes it — each state differs from its
    /// neighbour in something OTHER than glyph opacity — rather than the three
    /// triples, which would be the implementation copied out and would pass for
    /// any values at all.
    static func aModeYouCannotUseDoesNotLookLikeOneYouCan() {
        let on = ChromeRules.modeStyle(on: true, blocked: false)
        let off = ChromeRules.modeStyle(on: false, blocked: false)
        let blocked = ChromeRules.modeStyle(on: false, blocked: true)

        // The whole finding, in one line: these two states must not be
        // separable by glyph opacity alone.
        require(off.rim != blocked.rim || off.fill != blocked.fill,
                "off (\(off)) and blocked (\(blocked)) differ only in glyph opacity — "
                + "which is the defect this check exists for")
        require(on.fill != off.fill || on.rim != off.rim,
                "on (\(on)) and off (\(off)) differ only in glyph opacity")

        // A legibility floor. 0.38 on the panel's ground is what "off" was, and
        // it read as absent rather than as a control at rest.
        require(off.glyph >= 0.55,
                "an available-but-off mode draws at \(off.glyph) — under the floor "
                + "that made it look like it was not there")
        // And it still has to be visibly below ON, or the fix has simply moved
        // the collision from off/blocked to on/off.
        require(on.glyph - off.glyph >= 0.2,
                "on (\(on.glyph)) and off (\(off.glyph)) are \(on.glyph - off.glyph) apart")
        // Blocked stays clearly recessed. It is allowed to render — the panel
        // has not lost a button just because Spotify refuses it here — but it
        // must not read as pressable.
        require(blocked.glyph < off.glyph - 0.2,
                "blocked (\(blocked.glyph)) is not clearly dimmer than off (\(off.glyph))")
        require(blocked.rim == 0,
                "blocked keeps \(blocked.rim) of its rim — the edge is the affordance, "
                + "and keeping it is what made it look pressable")
        // Every state must still be drawn. An invisible glyph is the panel
        // losing its buttons, which is the complaint that started all of this.
        for (name, st) in [("on", on), ("off", off), ("blocked", blocked)] {
            require(st.glyph > 0.15, "the \(name) glyph is \(st.glyph) — effectively unpainted")
        }

        // And the VIEW has to route through the rule, for the same reason the
        // slots lint exists: chromecheck compiles ChromeRules alone, so the
        // rule can stay perfect while NotchView goes back to its own opacities.
        // Comments stripped, because a doc comment naming the function once
        // satisfied this lint by itself.
        let code = strippedSource("Sources/NotchApp/UI/NotchView.swift")
        guard !code.isEmpty else { return }
        require(code.contains("ChromeRules.modeStyle("),
                "the mode toggles no longer ask ChromeRules.modeStyle how to draw, so "
                + "nothing keeps off and unavailable apart")
        // Both structural knobs have to REACH the buttons. The rule can return
        // rim 0 forever and every toggle still draws an edge if nothing forwards
        // it.
        //
        // Written as `code.contains("rim:")` this passed while both call sites
        // had their rim argument deleted: TransportButton's own `var rim:
        // Double` declaration contains that text. A lint the declaration
        // satisfies tests nothing about the call, which is the same shape as the
        // doc-comment bug in the slots lint above — and again only mutation
        // showed it.
        for knob in ["rim", "fill"] {
            let forwarded = code.components(separatedBy: "Style.\(knob)").count - 1
            require(forwarded >= 2,
                    "the style's \(knob) reaches \(forwarded) mode buttons, not both — "
                    + "so a state that differs only by \(knob) draws identically")
        }
    }

    /// The heart names the track it sits beside.
    ///
    /// `MarqueeText` is greedy by necessity, so the text column is always full
    /// width and the trailing heart was pinned to the panel's right margin —
    /// 185pt past the end of a short title. The view's own comment says the
    /// library belongs "beside the track it names"; the layout had quietly
    /// stopped doing it, and no arithmetic here would have shown that. A
    /// screenshot did.
    static func theHeartTrailsTheTitleNotTheMargin() {
        // The real column: panel less both margins, the sleeve, its gutter, the
        // heart's own slot and the stack spacing.
        let column = ChromeRules.panelWidth - ChromeRules.margin * 2
            - ChromeRules.art - 12 - ChromeRules.slot(ChromeRules.modeDiameter) - 6

        // The hazard is worth asserting first: if a short title does not move
        // the heart materially, nothing below is measuring anything. "Flower
        // Pot" at 15pt semibold is about 66pt.
        let shortTitle = ChromeRules.heartSlack(textWidth: 60, columnWidth: column)
        require(shortTitle > 100,
                "a 60pt title in a \(column)pt column slides the heart \(shortTitle)pt — "
                + "if that is now negligible this check is measuring nothing")

        for text in stride(from: 0.0, through: 400.0, by: 5) {
            let slack = ChromeRules.heartSlack(textWidth: CGFloat(text), columnWidth: column)
            require(slack >= 0, "text \(text)pt gives slack \(slack) — the heart moves RIGHT, "
                    + "off the panel's margin")
            require(slack <= column, "text \(text)pt slides the heart \(slack)pt out of a "
                    + "\(column)pt column")
            // The heart's anchor never crosses the words. Offsetting it by the
            // unused tail lands it exactly at the end of the text, never inside.
            require(column - slack >= min(CGFloat(text), column) - 0.001,
                    "text \(text)pt leaves the heart at \(column - slack)pt, on top of "
                    + "the title rather than after it")
        }

        // A title that fills or overflows has NO slack, so the heart renders
        // where it always did. This is the case that cannot be photographed on
        // demand without skipping somebody's music, so it is the case the
        // arithmetic has to carry.
        for text in [column, column + 1, column + 200] {
            require(ChromeRules.heartSlack(textWidth: text, columnWidth: column) == 0,
                    "a title of \(text)pt in a \(column)pt column still moves the heart")
        }
        // Wider words never buy more room.
        var previous = CGFloat.greatestFiniteMagnitude
        for text in stride(from: 0.0, through: 400.0, by: 5) {
            let slack = ChromeRules.heartSlack(textWidth: CGFloat(text), columnWidth: column)
            require(slack <= previous, "slack grew from \(previous) to \(slack) at \(text)pt")
            previous = slack
        }

        let code = strippedSource("Sources/NotchApp/UI/NotchView.swift")
        guard !code.isEmpty else { return }
        require(code.contains("ChromeRules.heartSlack("),
                "the heart no longer asks ChromeRules.heartSlack where to sit, so it is "
                + "back on the panel margin naming nothing")
        // It has to be an OFFSET. Anything that changes LAYOUT takes width away
        // from the column the marquee measures against, which is how the title
        // vanished the first time.
        require(code.contains("offset(x: -heartSlack)"),
                "the heart's slack is no longer applied as an offset — a layout change "
                + "here narrows the marquee's box")

        // The slack is measured off a HIDDEN MIRROR of each line, because the
        // visible label is greedy and its frame says nothing about how wide the
        // words are. That only works while the mirror is set in the same font
        // as the label it mirrors: change one and the heart trails a width no
        // line on the panel has. Nothing about the two declarations makes them
        // move together — they are forty lines apart — so count them.
        //
        // The sizes are re-read from the view rather than written here, so this
        // keeps holding when the type is next resized. Scoped to `trackLine`,
        // not the file: the panel sets .medium at four other sizes and two of
        // those are a matching pair, so a file-wide version of this passes on
        // the clocks alone while the artist and its mirror disagree.
        guard let line = section(code, from: "private var trackLine") else {
            require(false, "cannot find trackLine to check its type against its mirrors")
            return
        }
        for role in ["semibold", "medium"] {
            let sizes = line.components(separatedBy: "weight: .\(role)")
                .dropLast()
                .compactMap { chunk -> String? in
                    guard let open = chunk.range(of: "size: ", options: .backwards) else {
                        return nil
                    }
                    return String(chunk[open.upperBound...]
                        .prefix { $0.isNumber || $0 == "." })
                }
            require(sizes.count == 2,
                    "the \(role) tier is declared \(sizes.count) times in trackLine, not "
                    + "twice — one visible line and one hidden mirror is the whole "
                    + "arrangement the slack depends on")
            require(sizes[0] == sizes[1],
                    "the \(role) line is set at \(sizes[0]) and measured at \(sizes[1]) — "
                    + "the heart trails a width that is not the one on screen")
        }
    }

    /// The scrub strip stays below every control.
    ///
    /// The strip is invisible, full-width, and the last child of the root
    /// ZStack, so it hit-tests above the transport: every point of it that
    /// reaches the control row is a point the row never receives. At 22pt tall
    /// it covered the bottom 3pt of the play button's visible disc and 7pt of
    /// its tap target — and because the gesture maps x straight to a fraction of
    /// the track, and play sits on the panel's centre line, the press that
    /// should have paused the track seeked it to exactly 50% instead.
    ///
    /// The 4pt padding is the ring `TransportButton` puts outside its disc. It
    /// draws nothing and is still part of the target, so it is what the strip
    /// has to clear — not the visible circle.
    static func theScrubStripDoesNotStealThePlayButton() {
        let clearance = ChromeRules.seekStripClearance(
            bottom: ChromeRules.bottom, padding: 4,
            stripHeight: ChromeRules.seekStripHeight,
            stripCentre: ChromeRules.seekStripCentre)
        require(clearance >= 0,
                "the \(ChromeRules.seekStripHeight)pt scrub strip reaches \(-clearance)pt "
                + "into the control row's tap targets — a press on the bottom of play "
                + "seeks to 50% instead of pausing")
        // And it stays on the panel: a strip hanging past the bottom edge is a
        // drag target over whatever is behind the window.
        require(ChromeRules.seekStripCentre >= ChromeRules.seekStripHeight / 2,
                "the scrub strip hangs \(ChromeRules.seekStripHeight / 2 - ChromeRules.seekStripCentre)pt "
                + "below the panel")
    }

    /// The retracted progress line fits between the camera and the chrome —
    /// BOTH edges, which is what this check used to get half right.
    ///
    /// It asserted the top edge only: that no stroke reaches up into the cutout.
    /// A 2.5pt line pushed down until its top landed exactly on the cutout's
    /// bottom satisfied that perfectly and put its remaining 1.5pt below the
    /// 33pt band, on the title bar of whatever window was in front — the thing
    /// PRODUCT.md names in so many words. A rule with two edges needs two
    /// assertions; one of them passing is not the rule holding.
    static func theTraceFitsBetweenTheCameraAndTheChrome() {
        // The whole sweep, not the built-in display alone: the shell is clamped
        // to the menu bar while the cutout keeps ScreenMetrics' unclamped 190x32
        // fallback, so an external display runs this code with a band near 24
        // and a cutout describing nothing on screen. Swept for BOTH styles,
        // because "no sliver" means opposite things on the two: a pill has no
        // camera and keeps the full stroke; a notch whose adjusted cutout
        // swallows the band has a camera and no room under it, and the old
        // shared fallback drew the full stroke behind the housing there — the
        // exact defect this function exists to prevent, on the one input the
        // sweep never took.
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
                    // negative inset pushes it DOWN and widens it. Modelled with the
                    // wrong sign this check failed against correct code.
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

        // The sliver is the budget, and the line spends all of it. Asserted
        // against the built-in display's own numbers so a change to either rule
        // that leaves a gap — a line thinner than the room it has, which reads
        // as a hairline of desktop under the peek — is a failure too.
        let fitted = ChromeRules.retractedTraceWidth(shellHeight: 33, cutoutHeight: 32,
                                                     expandedWidth: 2.5, hasNotch: true)
        require(fitted == 1,
                "the retracted trace is \(fitted)pt in the 1pt between band and cutout")
    }

    /// The played fill has an unplayed remainder behind it, and the two are the
    /// same line.
    ///
    /// Drawn alone, a `.trim` from zero leaves the panel's bottom edge stroked
    /// for as much of its width as the song has played and bare for the rest, so
    /// the silhouette's break point travels as the track goes on and the tip
    /// starts each song as a speck on an unstroked corner. The remedy is only a
    /// remedy if the track is the SAME path at the SAME width and inset: a track
    /// with numbers of its own is concentric with its fill by luck, and stops
    /// being concentric the first time either number moves.
    static func theTraceHasSomethingToRunAlong() {
        let code = strippedSource("Sources/NotchApp/UI/NotchView.swift")
        // The declaration, exactly. Anchored on the name alone this matched a
        // `progressTrackDisabled` renamed out of the body's reach and went on
        // reading the orphan's own text — the lint following the rename while
        // the panel drew nothing.
        guard let track = section(code, from: "private var progressTrack: some View") else {
            require(false, "the progress trace has no track behind it")
            return
        }
        require(track.contains("lineWidth: traceWidth"),
                "the track sets its own width instead of the trace's")
        require(track.contains("inset: traceInset"),
                "the track sets its own inset instead of the trace's")
        // The remainder is the whole line. Trimmed, it would stop wherever the
        // fill does and there would be no remainder at all.
        require(!track.contains(".trim("),
                "the track is trimmed, so it ends where the fill ends")

        // Behind the fill, not over it: `ZStack` draws in source order, so this
        // is an ordering claim about the body and has to be read there.
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

        // And the line ends the same way in both states. The retracted tip was
        // a literal zero while the expanded one was a round knob — one value,
        // two grammars, depending only on whether the panel happened to be open.
        guard let tip = section(code, from: "private var playhead") else {
            require(false, "the trace has no playhead")
            return
        }
        require(tip.contains("traceWidth"),
                "the retracted playhead is not the trace's own width, so the peek "
                + "and the panel end the same line differently")
    }

    /// The panel's outline exists on ANY backdrop, and one value draws it.
    ///
    /// The rim was a top-lit highlight inherited from the prototype — 0.18 at the
    /// display's top row, 0.05 across the sides, 0.16 along the bottom — and
    /// slice 1 gave the bottom edge and both corners to a full-length track, so
    /// the sides became the whole of what the rim still drew and the sides were
    /// its dimmest stretch. A 0.5pt stroke at 0.05 over a dark window title bar
    /// is not an edge; over the light desktop below it the same stroke was
    /// obvious. That is how a backdrop-dependent outline passes review: it looks
    /// right wherever you happened to look.
    /// The retracted clock reads a moving value at display rate, not at the
    /// rate the poll happens to land.
    ///
    /// `media.position` is only rewritten when a snapshot arrives, and the poll
    /// loop is a 1s sleep plus the snapshot's own synchronous ScriptingBridge
    /// round trips — measured at 88-199ms against Spotify. So the band's clock
    /// stepped ~1.09s at a time, which rounds to +1 second on most polls and +2
    /// on roughly every eleventh, and that is exactly what it looked like: a
    /// clock that skips a second every ten or so.
    ///
    /// `MediaManager.smoothPosition` exists for this and the expanded player
    /// already used it; the collapsed one was left reading the raw value. Both
    /// halves are asserted, because either alone still steps: `smoothPosition`
    /// outside a timeline is re-read only when something else invalidates the
    /// body — which is the poll — and a timeline around the raw value re-reads a
    /// number that did not change. The progress trace has the same pairing, and
    /// the comment above it records the same defect in the playhead.
    ///
    /// Sliced to `CollapsedActivity` on purpose: the expanded player names
    /// `smoothPosition` twice, so a file-wide search is answered by code that is
    /// not the subject, and would pass with the band still reading raw.
    static func theRetractedClockDoesNotStepAtThePollRate() {
        let code = strippedSource("Sources/NotchApp/UI/NotchView.swift")
        guard !code.isEmpty else { return }
        guard let band = topLevelSection(code, from: "struct CollapsedActivity") else {
            require(false, "cannot find CollapsedActivity in NotchView.swift — "
                    + "this check reads a slice and just became a no-op")
            return
        }

        // The argument to the call, not the file's vocabulary: asking whether
        // the slice "contains" smoothPosition is answered by any other mention,
        // and would survive the clock going back to the raw value.
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

        // The band is the always-on state, and its cost is the one that was
        // taken from ~17% to ~5%. A clock that keeps re-reading while playback
        // is stopped spends that back for a value that cannot change.
        let head = band[timeline.lowerBound..<call.lowerBound]
        require(head.contains("paused:") && head.contains("isPlaying"),
                "the retracted clock's timeline is not paused on playback, so it "
                + "re-reads a frozen value while the player is stopped")
    }

    /// The expanded band's clocks are the same defect's third home.
    ///
    /// The file fixed poll-rate stepping twice — the playhead, then the
    /// collapsed clock — and each fix was applied to one clock while its
    /// sibling kept stepping, because a green check about one call site says
    /// nothing about the next. The band clocks froze `shownPosition` at init
    /// and re-sampled at poll cadence, skipping a second about every eleventh
    /// poll, in the state where the panel is open and someone is looking.
    ///
    /// Two halves again, because either alone still steps: a TimelineView over
    /// a Double captured at init re-renders the same stale second with a fresh
    /// date, and a live read outside a timeline is only re-evaluated when the
    /// poll invalidates the body. And the scrub still owns the clocks while a
    /// drag is in flight — `shownPosition` exists so a scrub can land on a
    /// second — so the live read must lose to it only then.
    static func theBandClocksDoNotStepAtThePollRate() {
        let code = strippedSource("Sources/NotchApp/UI/NotchView.swift")
        guard !code.isEmpty else { return }
        guard let player = topLevelSection(code, from: "struct ExpandedPlayer") else {
            require(false, "cannot find ExpandedPlayer in NotchView.swift — "
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

        // The value read at render time, not the one frozen at init: the head
        // must bind the live position, and the call must not render the frozen
        // parameter directly — a timeline over a stale Double is the no-op
        // shape of this fix.
        let head = player[timeline.lowerBound..<call.lowerBound]
        require(head.contains("media.smoothPosition"),
                "the band clocks never read media.smoothPosition inside their "
                + "timeline, so the schedule re-renders a value only the poll "
                + "rewrites")
        let argument = player[call.upperBound...].prefix { $0 != ")" }
        require(!argument.contains("shownPosition"),
                "the elapsed clock renders \(argument), the parameter frozen at "
                + "init — the timeline ticks, the second does not")

        // Paused while nothing plays, and paused while a scrub is in flight —
        // the drag is the one moment the frozen parameter is the truth.
        require(head.contains("paused:") && head.contains("isPlaying")
                    && head.contains("scrubbing"),
                "the band clocks' timeline is not paused on both playback and "
                + "scrubbing, so it either burns frames on a stopped player or "
                + "fights the drag for the clocks")
    }

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
                        // A changed stop COUNT snaps instead of interpolating when
                        // the panel morphs, so the branches have to agree on it.
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
                        // One value from the top to the handoff. This is the
                        // defect: any schedule that dims the rim between those two
                        // points is a highlight following an edge, not an edge.
                        require(stops[0].alpha == stops[1].alpha,
                                "the rim is \(stops[0].alpha) at the top and "
                                + "\(stops[1].alpha) at the handoff — it dims along the "
                                + "outline at \(at)")
                        if expanded {
                            require(stops[0].alpha >= ChromeRules.rimFloor,
                                    "the expanded rim draws the sides at \(stops[0].alpha), "
                                    + "under the \(ChromeRules.rimFloor) floor, at \(at)")
                            // The bottom edge belongs to whoever is drawing it. Lit
                            // under a track it doubles the rail; dark with no track
                            // the silhouette simply stops.
                            require((stops[2].alpha > 0) == (track == nil),
                                    "the rim closes the bottom at \(stops[2].alpha) at \(at)")
                        } else {
                            // Retracted the outer half of a centred stroke is on the
                            // window chrome below the band, so the bottom is never
                            // the rim's — hovered or not.
                            require(stops[2].alpha == 0,
                                    "the retracted rim draws the shell's bottom edge "
                                    + "at \(stops[2].alpha) at \(at)")
                            // Not `== rimHoverAlpha`: comparing the schedule's
                            // output to the constant it is built from is true for
                            // any value of that constant, including zero. The
                            // rule is the shipped acknowledgement's own strength —
                            // for the whole of `hoverDuration` this is the only
                            // thing the notch gives back, so it may rise and it
                            // may not fall.
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

    /// The sleeve's edge looks the same on a white cover and a black one.
    ///
    /// It was `strokeBorder(white 0.28 -> 0.04, 0.5pt)` drawn ON the artwork, and
    /// an alpha stroke over an image composites to `art * (1 - a) + a`: a step of
    /// 0.04 on a pale cover, which is no edge, and a bright seam on a dark one.
    /// The edge's presence was a property of the album and no alpha value fixes
    /// that — only an opaque ring, which cannot take its tone from what is under
    /// it. Both edges of that rule are asserted here: the ring exists at every
    /// size, and it never grows into a matte around the print.
    static func theSleevesEdgeDoesNotDependOnTheAlbum() {
        let bevel = ChromeRules.sleeveBevel
        require(bevel.top > bevel.bottom,
                "the sleeve's bevel is lit from below (\(bevel))")
        require(bevel.bottom >= bevel.top / 3,
                "the bevel fades to \(bevel.bottom) against a top of \(bevel.top) — "
                + "a highlight that dies is the top-lit stroke again, not a thickness")
        require(bevel.top > 0 && bevel.top < 1 && bevel.bottom > 0,
                "the sleeve's bevel is not a tone (\(bevel))")

        for s in stride(from: 8.0, through: 140.0, by: 0.5) {
            let size = CGFloat(s)
            let mount = ChromeRules.sleeveMount(size: size)
            let lifted = ChromeRules.sleeveShadow(size: size).opacity > 0
            require(mount.bevel > 0, "a \(size)pt sleeve has no edge at all")
            // One predicate, two consumers. Two literal thresholds on the same
            // question is the "one number in two places waiting to disagree" this
            // file forbids twice already.
            require((mount.innerLine > 0) == lifted,
                    "at \(size)pt the mount and the cast shadow disagree about which "
                    + "sleeve is the panel's subject")
            let ring = mount.bevel + mount.innerLine
            require(ring * 2 < size * 0.2,
                    "the mount takes \(ring * 2)pt of a \(size)pt tile — that is a matte")
            if size <= ChromeRules.sleeveFull {
                require(ring <= 0.5,
                        "the peek's \(size)pt tile gained a \(ring)pt frame")
            }
        }
        // Wide enough to be opaque where it matters: under 1pt the ring is a
        // single device pixel at 2x and composites with what is under it, which
        // is the mechanism this whole check exists to remove.
        require(ChromeRules.sleeveMount(size: ChromeRules.art).bevel >= 1,
                "the panel's own sleeve carries a sub-pixel bevel")

        guard let art = topLevelSection(strippedSource("Sources/NotchApp/UI/NotchView.swift"),
                                        from: "private struct Artwork") else {
            require(false, "cannot find the sleeve to check its edge")
            return
        }
        require(!art.contains("strokeBorder"),
                "the sleeve's edge is a stroke over the print again, so its contrast "
                + "is the album's to decide")
        for rule in ["ChromeRules.sleeveMount(", "ChromeRules.sleeveBevel",
                     "ChromeRules.sleeveShadow("] {
            require(art.contains(rule),
                    "the sleeve does not ask for \(rule), so nothing here can fail it")
        }
        // The mount is three layers now, and an unflattened shadow casts from
        // each of them — blurring the bevel's own dark bottom into the wash,
        // which is the tone the whole treatment rests on.
        guard let flatten = art.range(of: "compositingGroup"),
              let shadow = art.range(of: ".shadow(") else {
            require(false, "the sleeve is not flattened before it casts a shadow")
            return
        }
        require(flatten.lowerBound < shadow.lowerBound,
                "the sleeve casts its shadow before it is flattened, so every layer "
                + "of the mount casts one")
    }

    /// One of the two forms of the text is always on screen.
    ///
    /// The label was hidden on overflow alone while the scroller also required
    /// not-Reduce-Motion, so with Reduce Motion on, any title wider than its
    /// column rendered as nothing: "never replace the interface with an inert or
    /// ambiguous state".
    static func theTitleIsNeverBlank() {
        // Not a sweep. `marqueeShowsSomething` is
        // `showsScroller || !hidesStaticLabel`, and while both gates delegate to
        // the same predicate the result does not depend on the inputs at all —
        // 7,442 iterations of it were 7,442 evaluations of the same constant.
        //
        // What the assertion is really for is DIVERGENCE: it fails the moment
        // the two gates are keyed on different things again, which is exactly
        // how an overflowing title came to render as nothing under Reduce
        // Motion. A handful of representative cases states that just as well.
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

    /// Animation curves come from `Motion`, which is the one place they are
    /// written. An inline spring is a curve that bypassed it.
    ///
    /// PRODUCT.md no longer promises Reduce Motion support, so this is not
    /// enforcing that promise — the mechanism is kept because it already exists
    /// and costs one branch, and this keeps the vocabulary in one file, which is
    /// what stopped the button press ringing past its rest size on every press
    /// while every neighbouring curve behaved.
    static func everyCurveAsksAboutReduceMotion() {
        let fm = FileManager.default
        var offenders: [String] = []
        var scanned = 0
        for dir in ["Sources/NotchApp/UI", "Sources/NotchApp/Notch", "Sources/NotchApp/App"] {
            // Not `continue`. These are relative paths, so run from anywhere but
            // the repo root every one of them fails to resolve and the lint
            // passes having read nothing — silently, which is the worst way for
            // a check to be satisfied.
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

    /// A strip you cannot scrub is not offered.
    ///
    /// `MediaManager.seek(toFraction:)` guards on `duration > 0` and returns, so
    /// on a track with no duration — a live stream, a radio station, a track
    /// whose length has not arrived yet — every drag on the strip does nothing.
    /// It was gated on `hasTrack` alone, which is true for all of those.
    ///
    /// Worse through the accessibility API than on screen. The strip publishes
    /// an `accessibilityAdjustableAction` labelled "Playback Position", so
    /// VoiceOver announces a control, offers to move it, and reports no error
    /// when it does not move — and there, that element is the entire interface
    /// for this. PRODUCT.md asks for readable contrast and native control
    /// semantics in the same breath as "a control that renders must do
    /// something".
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

    /// The title's two gates come from the rule, not from the view.
    ///
    /// `theTitleIsNeverBlank` holds the ChromeRules half, and holds it well: its
    /// own comment concedes the predicate is constant under the current code and
    /// explains that what it really watches for is DIVERGENCE — it fails the
    /// moment the two gates are keyed on different things again.
    ///
    /// What it cannot see is whether the view still ASKS. The bug that shipped
    /// was in MarqueeText, not in ChromeRules: the label keyed on overflow alone
    /// and the scroller on overflow AND not-Reduce-Motion, so with Reduce Motion
    /// on, any title wider than its column faded out for an overlay that was
    /// never drawn — a blank row where the song title goes, which is "an inert or
    /// ambiguous state" twice over. Re-inlining either gate brings that back with
    /// every rule in ChromeRules still perfectly consistent with itself.
    ///
    /// Every sibling rule with a view counterpart — modeSlots, modeStyle,
    /// heartSlack, rimStops, sleeveMount — has a lint like this one. The rule
    /// whose defect actually shipped did not.
    static func theTitleTakesBothGatesFromTheRule() {
        let code = strippedSource("Sources/NotchApp/UI/MarqueeText.swift")
        require(code.contains("ChromeRules.marqueeHidesStaticLabel("),
                "MarqueeText no longer asks ChromeRules whether to hide the static "
                + "label, so the gate it applies can drift from the one that is checked")
        require(code.contains("ChromeRules.marqueeShowsScroller("),
                "MarqueeText no longer asks ChromeRules whether to show the scroller, "
                + "so the gate it applies can drift from the one that is checked")
        // `marqueeScrolls` is overflow ALONE. Both gates are supposed to reach it
        // only through `marqueeScrolling`, which also asks about Reduce Motion.
        require(!code.contains("ChromeRules.marqueeScrolls("),
                "MarqueeText keys a gate on marqueeScrolls, which does not ask about "
                + "Reduce Motion — the exact pairing that left the title row blank")
    }

    /// The sheet's lean under a live swipe never leaves the margins beside it.
    ///
    /// The caps are the margins' slack, not chosen numbers, so they are held
    /// against the layout that produces the slack. Expanded, content sits
    /// `margin` off the shell edge and its nearest disc keeps a `controlInset`
    /// ring of air. Retracted, the slack is the flanks' own edge padding —
    /// a view literal, so it is READ from the view rather than restated here;
    /// a copy would keep this passing after the flanks tightened.
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
    /// real HUD state — the refusal lives in `SwipeRecogniser.sheetShift`, and
    /// a leaf that stopped consulting it would lean the HUD's meter under the
    /// camera housing with every rule still consistent with itself.
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

    /// A source file with its comments removed.
    ///
    /// Every text-scan lint here needs this, and needs it for the same reason:
    /// written against the raw file, a lint asserting the view CALLS a rule was
    /// satisfied by the doc comment three lines above the call that named it.
    /// Deleting the call left the check passing, and only mutating the view
    /// found that out.
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

    /// One member's text, from its declaration to the next declaration beside
    /// it.
    ///
    /// The terminator is the point. A lint asking "is shuffle inside the
    /// CENTRED group" against the whole file is answered yes by the cluster
    /// forty lines below it — which is the same shape as the doc-comment bug
    /// above: a check whose subject is wider than its claim.
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

    /// One TOP-LEVEL declaration's text.
    ///
    /// `section` terminates on the next member indented beside its anchor, which
    /// is right for a member and useless for a type: anchored at a struct, the
    /// struct's own first property ends the section and the lint's subject is one
    /// line wide — the same "subject that does not match the claim" defect as its
    /// wider cousin, from the other side.
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
