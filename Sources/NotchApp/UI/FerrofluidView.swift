import SwiftUI

/// One continuous body of ink around the cutout.
///
/// A single closed path displaced along its own normal: bass heaves the whole
/// surface, and every band raises a smooth mound where it sits on the rim. There
/// are no spikes and no particles — the expression is entirely in how the outline
/// itself swells and settles, which is what a magnet under a shallow pool
/// actually looks like before the field gets strong enough to break it.
///
/// Nothing is assembled from circles and nothing detaches. A tight blur/threshold
/// pass keeps the edge hard so it reads as liquid rather than as a gradient.
struct FerrofluidView: View, Animatable {

    var sim: FerrofluidSim
    var notchSize: CGSize
    var panelSize: CGSize
    /// 0 retracted, 1 expanded, and every value in between.
    ///
    /// This was a Bool, so on every expand each peak jumped from the two vertical
    /// runs beside the camera onto the bottom edge in a single frame while the
    /// shell spent 420ms morphing around a surface that had already finished. The
    /// signature element was the one thing that did not move when the panel did.
    /// As an animatable scalar the peaks migrate around the real outline, and an
    /// expand interrupted by a collapse retargets them mid-journey.
    var openness: CGFloat

    var animatableData: CGFloat {
        get { openness }
        set { openness = newValue }
    }

    /// Reduce Motion keeps every state change but takes the travel out of it:
    /// peaks still break the surface on the beat, they just don't reach as far.
    /// The ink never becomes inert — an ambiguous visualiser is worse than a
    /// lively one.
    var reduceMotion: Bool = false
    /// The cutout's corner, from the controller, so the ink and the shell round
    /// their shared edge by the same amount.
    var cornerRadius: CGFloat = Geometry.cornerRadius
    /// The track's colour, for the rim glow. The ink itself is always black —
    /// only the light around it is tinted.
    var tint: Color = .white

    /// Wide enough to keep the outline liquid.
    ///
    /// The blur/threshold pair is what makes the edge read as a surface with
    /// tension rather than as a drawn curve: it rounds every junction between
    /// adjacent mounds instead of leaving the polygon's own corners. A straight
    /// step edge holds its position under any symmetric blur at threshold 0.5,
    /// so the cutout's own edges do not move — which is why the camera guarantee
    /// can be drawn through this pass at all.
    /// Internal so `Geometry` can leave exactly this much room at the panel edge
    /// — the silhouette is blurred by it before the alpha threshold takes it
    /// back, so ink that stops at the edge still bleeds past it.
    static let blur: CGFloat = 3.4

    var body: some View {
        // Read HERE, not by the parent. `isSettled` is computed from swell,
        // impact and every site, all mutated sixty times a second — so
        // reading it from NotchRootView's body kept the whole panel invalidating
        // every frame even after the colour field was moved into its own leaf.
        TimelineView(.animation(minimumInterval: 1.0 / 60.0, paused: sim.isSettled)) { _ in
            canvas
        }
        .frame(width: panelSize.width, height: panelSize.height)
        .allowsHitTesting(false)
    }

    private var canvas: some View {
        let sites = sim.sites
        let pointerRim = sim.pointerRim
        let pointerPull = CGFloat(sim.pointerPull)
        let swell = CGFloat(sim.swell)
        let raised = CGFloat(sim.raised)
        let impact = CGFloat(sim.impact)
        // The ink's own openness, which trails the shell's. Clamped to `openness`
        // so it can never lead the chrome — that clamp plus the retracted clip is
        // what keeps ink out of the menu bar, structurally rather than by tuning.
        let inkOpen = max(0, min(openness, CGFloat(sim.inkOpen)))
        // Hoisted with the other sim reads. `glow` is already the drawLayer
        // closure's parameter, hence the name.
        let haloAlpha = CGFloat(FerrofluidSim.glowAlpha(impact: sim.impact,
                                                        openness: Double(inkOpen)))

        return Canvas { context, size in
            let geometry = Geometry(notch: notchSize, panel: size, openness: inkOpen,
                                    cornerRadius: cornerRadius)

            let lobes = geometry.lobes(of: sites)
            let surface = { (position: Double, lateral: CGFloat, headroom: CGFloat,
                             detail: CGFloat) -> CGFloat in
                geometry.displacement(reduce: reduceMotion,
                                      at: position,
                                      lobes: lobes,
                                      swell: swell,
                                      raised: raised,
                                      lateral: lateral,
                                      detail: detail,
                                      headroom: headroom,
                                      pointerRim: pointerRim,
                                      pointerPull: pointerPull)
            }

            // The silhouette, painted once and reused: the glow behind and the
            // ink in front are the *same* shape, so the halo can never drift out
            // of register with the body it belongs to.
            // Built ONCE. At 144 samples this matters twice over: the glow lights
            // on transients and would otherwise rebuild the whole outline a second
            // time on exactly the frames that are already busiest.
            let outline = geometry.poolPath(displacement: surface)
            let paint: (GraphicsContext, Color) -> Void = { ctx, color in
                ctx.fill(outline, with: .color(color))
            }

            // 1. The glow, behind everything.
            //
            // Scaled by openness rather than gated on it, so the halo arrives
            // with the panel. Retracted it is fully off — there is no room for a
            // glow that is immediately cut at the menu-bar line. Its strength is
            // the audio's own transient, so it swells on the hit and fades; it
            // never pulses on its own.
            // Only on a real hit. The glow is for emphasising the impact of
            // parts of songs; at a 0.01 threshold it was lit almost continuously,
            // which is both wrong for that and a full extra silhouette paint plus
            // a blur on every frame. The gate now lives in `glowAlpha`, which
            // eases across it rather than switching.
            if haloAlpha > 0.002 {
                context.drawLayer { glow in
                    // Radius rides the transient too, not just opacity. A beat
                    // and a button press used to bloom to exactly the same size
                    // and differ only in brightness; letting the halo spread as
                    // well is what makes a strike land harder than a snare.
                    glow.addFilter(.blur(radius: 11 + 14 * impact))
                    glow.blendMode = .plusLighter
                    glow.opacity = haloAlpha
                    paint(glow, tint)
                }
            }

            // 2. The camera guarantee: crisp, unfiltered, exact.
            context.fill(Path(roundedRect: geometry.core,
                              cornerRadius: geometry.cornerRadius),
                         with: .color(.black))

            // 3. The ink itself, through blur -> threshold so peaks fuse into one
            //    surface with a liquid neck instead of stacking as separate parts.
            context.drawLayer { ink in
                ink.addFilter(.alphaThreshold(min: 0.5, color: .black))
                ink.addFilter(.blur(radius: Self.blur))

                // Retracted, nothing the fluid does may reach below the menu-bar
                // band — that space belongs to browser tabs and window chrome.
                // Interpolating, not gated: at openness 0 this is exactly the
                // menu-bar band the retracted state must never exceed; at 1 it is
                // the whole panel. In between it opens with the shell instead of
                // switching on one frame.
                ink.clip(to: Path(CGRect(
                    x: 0, y: -60,
                    width: size.width,
                    height: 60 + geometry.core.maxY
                        + (size.height - geometry.core.maxY) * inkOpen)))
                ink.fill(Path(roundedRect: geometry.core,
                              cornerRadius: geometry.cornerRadius),
                         with: .color(.black))
                paint(ink, .black)
            }

        }
    }


}

/// Internal rather than private so `tools/geometrycheck.swift` can drive it
/// headlessly. Every regression in this file has been a geometry regression that
/// only showed up on screen.
struct Geometry {
    /// Matches the physical cutout's own bottom corners, which are filleted
    /// rather than square. At zero margin the
    /// ink is exactly the cutout, so its corners have to be the cutout's too —
    /// square ink reads as black nubs poking out past the housing.
    static let cornerRadius: CGFloat = 6
    static let outlineSamples = 144

    let core: CGRect
    let openness: CGFloat
    let panel: CGSize
    let cornerRadius: CGFloat

    /// The pool's own top edge, which sits above the screen.
    ///
    /// Internal because `geometrycheck` measures the visible flank from it. The
    /// join itself is measured from the SCREEN edge — anchoring it here was
    /// tried, and made the ink arrive on screen already wide.
    let top: CGFloat
    let sideRun: CGFloat
    private let arcRun: CGFloat
    private let bottomRun: CGFloat
    var total: CGFloat { sideRun * 2 + arcRun * 2 + bottomRun }

    init(notch: CGSize, panel: CGSize, openness: CGFloat,
         cornerRadius: CGFloat = Geometry.cornerRadius) {
        self.openness = openness
        self.panel = panel
        self.cornerRadius = cornerRadius
        let centerX = panel.width / 2
        // Zero margin: the resting ink *is* the cutout, so colour begins on the
        // same line the housing ends on and there is no black skirt hanging past
        // the notch. Nothing is lost by matching exactly — the area inside the
        // cutout is physically black either way; what must never happen is panel
        // colour appearing within it.
        let inset: CGFloat = 0
        let below: CGFloat = 0
        core = CGRect(x: centerX - notch.width / 2 - inset,
                      y: -30,
                      width: notch.width + inset * 2,
                      height: 30 + notch.height + below)
        top = core.maxY - min(core.height, notch.height + below + 6)
        let radius = cornerRadius
        sideRun = max(0, (core.maxY - top) - radius)
        arcRun = .pi * radius / 2
        bottomRun = max(0, core.width - 2 * radius)
    }

    /// The topmost point of the outline that is actually on screen, as a rim
    /// fraction. Seats are held at or below it: a lobe thrown past the top of the
    /// run tilts the surface instead of crowning it, and it is the loudest band
    /// that goes, since band 0 seats closest to the lip.
    var visibleTopU: Double { Double((2 - top) / total) }

    /// Where a site sits on the outline, blended between the two seatings.
    ///
    /// Expanded, sites live on the bottom run AND climb both vertical sides.
    ///
    /// They used to be packed into `side * 0.85 ... 1 - side * 0.85`, which put 13
    /// of 17 on the bottom run and seated the outermost pair 21pt down a side that
    /// is only 26pt visible — so with lobes reaching ±15pt, no warp could ever
    /// arrive on the vertical edges and only the bottom moved. Widening the span
    /// to `side * 0.5` puts two sites on each side, high enough that their mounds
    /// cover the full visible edge, and the whole silhouette deforms again.
    /// Retracted
    /// there is no vertical room, so they live on the two vertical runs beside
    /// the camera; positions there are continuous along each run and derived from
    /// the site's own rim, NOT an index-to-slot ladder (the old `flankSeat` put
    /// four spikes at 0, 1/3, 2/3, 1 on both sides — an exact mirror of one fixed
    /// comb — and dropped the middle 9 of 17 sites entirely).
    ///
    /// The two are **interpolated**, not switched. Both are positions along the
    /// same parameterised outline, so blending them walks each peak around the
    /// silhouette as the panel opens instead of teleporting it between two rules.
    func seatU(_ rim: Double) -> Double {
        let side = Double(sideRun / total)
        // Three sites per vertical run, not two.
        //
        // Spread evenly, the sides get sites in proportion to their length — the
        // two verticals are 12.3% of the rim each, so 2.1 sites — and two lobes
        // on a 32pt run merge into a single mass however hard they are driven.
        // This is a piecewise-linear warp that hands each side the first and last
        // 3/17 of the spectrum, so there are three peaks to tell apart. It stays
        // monotonic and continuous (at `q` it is exactly `side`, at `1 - q`
        // exactly `1 - side`), so a band still walks smoothly along the outline
        // as its neighbours rise and fall.
        let q = 3.0 / Double(FerrofluidSim.siteCount)
        // The top of the run that is actually on screen. A fixed 0.03 put band
        // 0's seat at y = 1.8pt and its jitter can reach 5.4pt, so its peak
        // landed above the panel and the loudest band in the mix contributed a
        // slope instead of a crown.
        let lip = visibleTopU
        let open: Double
        if rim < q {
            open = lip + (rim / q) * (side - lip)
        } else if rim > 1 - q {
            open = 1 - lip - ((1 - rim) / q) * (side - lip)
        } else {
            open = side + ((rim - q) / (1 - 2 * q)) * (1 - 2 * side)
        }

        let visibleTop = Double((3 - top) / total)
        let span = max(0.004, side - visibleTop)
        let closed = rim < 0.5
            ? visibleTop + rim * 2 * span
            : 1 - (visibleTop + (1 - rim) * 2 * span)

        let t = Double(min(1, max(0, openness)))
        return closed + (open - closed) * t
    }

    /// Retracted, only the sideways component of the surface may move: a warp
    /// with any downward component would push ink below the menu bar and onto
    /// the window chrome underneath.
    /// Expanded, the vertical sides swing further than the bottom does.
    ///
    /// The bottom run is 178pt of the 261pt rim and the two sides are 32pt each,
    /// so an even displacement spends almost everything on the bottom and the
    /// sides barely register — the panel reads as a bar with a lively underside
    /// rather than a body of ink. There is also far more room out there: the
    /// flank beside the cutout is 77pt, against a tanh ceiling of 46.
    ///
    /// Keyed on `abs(normal.dx)`, which runs smoothly 1 -> 0 -> 1 around the two
    /// corners, so the lift arrives as a continuous swell and never as a step.
    /// Retracted this is 0 everywhere, so none of it applies in the menu bar.
    func lateralLift(_ normal: CGVector) -> CGFloat {
        abs(normal.dx) * openness
    }

    func lateralGate(_ normal: CGVector) -> CGFloat {
        // Blended, so the warp turns from sideways-only to unrestricted as the
        // panel opens rather than switching.
        abs(normal.dx) + (1 - abs(normal.dx)) * openness
    }
    /// How far below the bezel the per-band DETAIL comes in.
    static let anchorRun: CGFloat = 10
    /// Steepest the silhouette may climb away from the bezel: points out per
    /// point down.
    ///
    /// The ink travels up to ~57pt sideways while the visible side of the cutout
    /// is 26pt tall, so a fixed-length join is always near-horizontal — the ink
    /// juts out as a shelf and reads as a sharp edge against the top of the
    /// screen no matter how the fade is shaped. The join has to scale with how
    /// far the ink is actually going.
    static let edgeSlope: CGFloat = 4
    /// How wide the ink already is where it meets the bezel, as a fraction of its
    /// full travel. Never zero — that is what choked the top.
    static let edgeFloor: CGFloat = 0.35


    /// The curve where the ink leaves the bezel, as a fraction of `amount`.
    ///
    /// Displacement runs along the rim's normal, and on the vertical runs that
    /// normal is horizontal — so a widened surface is a SLAB, a vertical side
    /// meeting the screen's top edge at a right angle. Widening it only moves
    /// that corner sideways.
    ///
    /// The run is `amount / edgeSlope`, so a big bulge gets a proportionally
    /// longer curve and the join keeps its shape at every drive.
    ///
    /// Measured from the SCREEN's edge, and short.
    ///
    /// Two failed shapes bracket this one. Anchored at the screen edge with a
    /// shallow slope, the run was over half the 26pt of visible side, so the top
    /// never reached full width and the shape read as choked at the neck. Started
    /// 6pt off screen instead, the ink arrived already wide and the first visible
    /// row was a hard edge — it came onto the screen sharply, with the curve
    /// hidden behind the bezel where it did no good.
    ///
    /// It has to open ON screen, and from a width that is already carrying the
    /// music — hence the floor. Taken to zero it did two harmful things: the top
    /// of the notch could not widen at all, and it handed the surface-tension
    /// relaxation an anchor of zero right at the screen edge, so the sweep then
    /// throttled everything below it as well. The shoulder was being choked
    /// twice, once by each mechanism.
    ///
    /// From `edgeFloor` the ink is already most of the way out where it meets the
    /// bezel and opens the rest over `amount / edgeSlope`, so the top widens with
    /// the music AND the join is a curve. The relaxation sweep, which is what
    /// actually guarantees no corner anywhere on the rim, is left free to do its
    /// job instead of fighting a zero.
    func edgeFillet(at point: CGPoint, amount: CGFloat) -> CGFloat {
        let run = max(0.5, abs(amount) / Self.edgeSlope)
        let t = min(1, max(0, point.y / run))
        return Self.edgeFloor + (1 - Self.edgeFloor) * (t * t * (3 - 2 * t))
    }

    /// How much per-band detail this piece of rim may carry, 0 at the bezel.
    ///
    /// The whole-body swell deliberately ignores this. The two terms do different
    /// things to a silhouette: offsetting a rounded shape outward keeps it
    /// rounded, so the body term WIDENS the notch and the curve survives the
    /// widening — while narrow per-band lobes at the bezel put bumps on the one
    /// corner the hardware also draws, which is what stopped it reading as a
    /// notch under sound.
    ///
    /// So the ink still moves at the top edge; the shape it moves into is still a
    /// curve. Smootherstep rather than smoothstep: the ceiling has come down
    /// since, but the point stands — a gentle ramp still lets a visible bump
    /// through one point below the bezel, which is the one place it shows.
    func edgeDetail(at point: CGPoint) -> CGFloat {
        let t = min(1, max(0, point.y / Self.anchorRun))
        // Smootherstep, not smoothstep. At full drive the raw displacement is
        // ~57pt, so smoothstep's 0.07 one point below the bezel still showed a
        // 4pt flare; this leaves 0.5pt there and reaches full by 10pt.
        return t * t * t * (t * (t * 6 - 15) + 10)
    }

    /// How far this piece of rim may travel outward before it reaches the edge
    /// of the panel it is drawn in.
    ///
    /// The panel clips the ink (`.clipShape(shape)`), so anything past this is
    /// cut flat — a straight vertical wall down the side of a body of liquid.
    /// It used to be avoided by hand: pick a lateral gain, multiply by the tanh
    /// ceiling, check the product against the 77pt flank beside the cutout. That
    /// reasoning was only ever valid for one panel width, and retracted — where
    /// the shell is exactly as wide as the cutout and the flank is 0 — it was
    /// wrong: at full drive the surface pressed 7pt past the shell and was cut.
    /// Feeding this into the ceiling instead makes containment a property of the
    /// geometry rather than of a constant somebody has to keep re-deriving.
    func headroom(from point: CGPoint, along normal: CGVector) -> CGFloat {
        var limit = CGFloat.greatestFiniteMagnitude
        if normal.dx > 0.001 { limit = min(limit, (panel.width - point.x) / normal.dx) }
        if normal.dx < -0.001 { limit = min(limit, point.x / -normal.dx) }
        // Downward only. Above the panel is the bezel, which is off screen and
        // already handled by the retracted gate.
        if normal.dy > 0.001 { limit = min(limit, (panel.height - point.y) / normal.dy) }
        return max(0, limit)
    }

    func rim(at position: Double) -> (point: CGPoint, normal: CGVector) {
        let radius = cornerRadius
        var distance = CGFloat(min(1, max(0, position))) * total

        if distance < sideRun {
            return (CGPoint(x: core.minX, y: top + distance),
                    CGVector(dx: -1, dy: 0))
        }
        distance -= sideRun

        if distance < arcRun {
            let angle = CGFloat.pi - (distance / arcRun) * (.pi / 2)
            let center = CGPoint(x: core.minX + radius,
                                 y: core.maxY - radius)
            return (CGPoint(x: center.x + cos(angle) * radius,
                            y: center.y + sin(angle) * radius),
                    CGVector(dx: cos(angle), dy: sin(angle)))
        }
        distance -= arcRun

        if distance < bottomRun {
            return (CGPoint(x: core.minX + radius + distance, y: core.maxY),
                    CGVector(dx: 0, dy: 1))
        }
        distance -= bottomRun

        if distance < arcRun {
            let angle = CGFloat.pi / 2 - (distance / arcRun) * (.pi / 2)
            let center = CGPoint(x: core.maxX - radius,
                                 y: core.maxY - radius)
            return (CGPoint(x: center.x + cos(angle) * radius,
                            y: center.y + sin(angle) * radius),
                    CGVector(dx: cos(angle), dy: sin(angle)))
        }
        distance -= arcRun

        return (CGPoint(x: core.maxX, y: core.maxY - radius - distance),
                CGVector(dx: 1, dy: 0))
    }

    /// The active sites' seats and heights, resolved once for the frame.
    ///
    /// `seatU` reads only `site.rim` and `openness`, both fixed for the whole
    /// frame, but it used to sit inside the loop the 73-sample path drives — so
    /// it ran up to 1,241 times per path to produce at most 17 distinct values.
    func lobes(of sites: [FerrofluidSim.Site])
    -> [(seat: Double, height: CGFloat, spread: CGFloat, reach: Double)] {
        sites.compactMap { site in
            guard site.height > 0.003 else { return nil }
            // `fan` was declared, seeded and read by nothing — the anti-comb
            // jitter it documents had never actually been applied. It offsets the
            // seat by a fraction of the lattice spacing, so the lobes sit on an
            // irregular rank rather than a perfect comb.
            // Scaled to the LOCAL seat spacing, not to a fixed slice of the rim.
            //
            // A flat 0.35/17 is +-5.4pt, which is 30% of the 18pt spacing on the
            // bottom run — an anti-comb nudge, as intended — but 47% of the 11.5pt
            // spacing on a side, where it could throw two lobes 3pt apart and
            // fuse them into one no matter how narrow they were made. Measuring
            // the step to the next seat keeps it at 30% everywhere.
            let step = 1.0 / Double(FerrofluidSim.siteCount - 1)
            let local = abs(seatU(min(1, site.rim + step)) - seatU(site.rim))
            let jitter = site.fan * 0.3 * local
            // Clamped into the visible body: the jitter is +-5.4pt and the top
            // seat sits 3pt below the panel edge, so without this a lobe can be
            // thrown off the top of the run, where all it does is tilt the
            // surface it should have crowned.
            let seat = min(1 - visibleTopU, max(visibleTopU, seatU(site.rim) + jitter))
            // How sideways this lobe's OWN seat is. Taken from the seat and not
            // from the sample position, so the lobe keeps one width across its
            // whole span and stays a symmetric mound; deriving it per-sample
            // would make the same lobe narrower on one flank than the other.
            let sideness = abs(rim(at: seat).normal.dx) * openness
            // `spread` and its cutoff are constant for the whole frame but used
            // to be recomputed inside the sample loop — 17 lobes x 145 samples,
            // for a value depending only on the lobe. `base` is the one term
            // that needs the frame, and openness is fixed for it.
            let base = 34 - 13 * openness
            let spread = base * (1 + 0.35 * CGFloat(site.height))
                              * (1 + 0.22 * CGFloat(site.fan))
                              * (1 + 1.0 * sideness)
            // Past this the wider of the two Gaussians is under 1e-4, so the
            // lobe contributes nothing a 144-sample outline can express.
            let reach = 5.0 / Double(spread)
            return (seat, CGFloat(site.height), spread, reach)
        }
    }

    /// Bass heaves the whole body and every active band raises a broad Gaussian
    /// mound in that same surface. This is a warp, never a pile of blobs.
    func displacement(reduce: Bool = false,
                      at position: Double,
                      lobes: [(seat: Double, height: CGFloat, spread: CGFloat, reach: Double)],
                      swell: CGFloat,
                      raised: CGFloat,
                      /// How sideways this piece of rim is, 0 on the bottom run
                      /// and 1 on the verticals, already scaled by openness.
                      lateral: CGFloat = 0,
                      /// How much per-band detail this point may carry. The body
                      /// swell ignores it, so the notch widens smoothly.
                      detail: CGFloat = 1,
                      /// Distance to the panel edge along the normal. The surface
                      /// saturates before it, so it is never cut flat.
                      headroom: CGFloat = .greatestFiniteMagnitude,
                      pointerRim: Double = 0.5,
                      pointerPull: CGFloat = 0) -> CGFloat {
        // Narrow enough that a band is its own lobe, and narrower the harder it
        // hit.
        //
        // At spread 12 each mound had a FWHM of ~42pt while the sites sit ~14.5pt
        // apart — every mound overlapped three neighbours on each side, so
        // seventeen peaks summed into one hill and the 6.94:1 height range the
        // sim computes was smeared away before it reached the screen. (11:1 was
        // that range while criticalField was 0.30; see FerrofluidSim.)
        //
        // The height coupling is the Rosensweig signature and it was missing
        // entirely: a loud hit was a scaled-up copy of a quiet one. A weak lobe
        // spreads into a broad ripple; a full peak pulls in tight and becomes its
        // own spire. Width tells you how hard the band hit, not just height.
        var mound: CGFloat = 0
        // The neck between them.
        //
        // Every term here used to be non-negative and every basis a bump, so the
        // outline was mathematically incapable of curving inward — and inward
        // curvature is the one thing a magnetised liquid always has. Ink drawn up
        // into a peak comes from somewhere: the surface between two peaks is
        // pulled DOWN. A Mexican-hat basis (a narrow positive core inside a wider
        // negative surround) gives exactly that, and it is what turns a row of
        // humps into something with surface tension.
        for lobe in lobes {
            // Narrower on the sides, so the three peaks there read as three.
            //
            // Reach is tuned to land on the seat spacing, not below it: on a
            // vertical run the sites sit ~11pt apart, and at 1.0 a neighbouring
            // lobe still contributes ~47% at the trough between two peaks — a
            // scalloped edge on one connected body. Below ~0.9 the three fuse
            // into a single hump; much above it they separate into isolated
            // bumps, which is the spike comb this renderer exists to not be.
            // Culled by distance. Every lobe was evaluated at every sample —
            // two `exp` calls each, 4,930 per frame — for a contribution that is
            // zero for all but the few nearest ones.
            guard abs(lobe.seat - position) < lobe.reach else { continue }
            let d = (lobe.seat - position) * lobe.spread
            let core = exp(-d * d)
            // Shallow and only just wider than the core. The first attempt used
            // a broad, deep surround, and with seventeen lobes on the rank every
            // neighbour then subtracted ~0.15 — the sum collapsed and the ink
            // stopped leaving the cutout entirely. A neck belongs BESIDE a peak,
            // not across the whole surface.
            let surround = exp(-d * d * 0.35) * 0.18
            mound += lobe.height * CGFloat(core - surround)
        }

        // The pointer's own swell. Wider and gentler than a band's lobe, because
        // it is a hand rather than a frequency — it should read as the surface
        // leaning toward you, not as another instrument.
        if pointerPull > 0.002 {
            // Broader and shallower than before: a hand leaning on the surface,
            // not a finger poking it. Combined with the lag on `pointerRim` this
            // reads as the mass being drawn along rather than pinned to the
            // cursor.
            let d = (pointerRim - position) * 4.6
            mound += pointerPull * 0.8 * CGFloat(exp(-d * d))
        }

        // Driven hard. Overlapping the title is fine — the content layer draws
        // above the ink, so white type stays legible on black — which means the
        // reach only has to stay inside the panel, not out of the text. tanh
        // still bounds it so the shape can never be cut flat by the shell's clip.
        let travel: CGFloat = reduce ? Motion.travel : 1
        // Retracted is a menu bar, not a canvas.
        //
        // At full amplitude the ink covered 102% of the retracted shell — it had
        // swallowed the strip, crowding the artwork and leaving colour only in
        // wedges at the ends. Expanded there is room for the drama; retracted the
        // mass should hug the cutout and merely breathe. Scaling with openness
        // gives one behaviour that is restrained in the band and unrestrained in
        // the panel, rather than two tunings to keep in step.
        let room = 0.42 + 0.58 * openness
        // Less body, more crown.
        //
        // At `swell * 15` against `mound * 23` the bass lifted the whole outline
        // so far that the per-band peaks rode on it as ripples — measured, five
        // crowns at 5.9pt of prominence on a mass travelling 30-44pt. The crowns
        // are what carry the music; a big uniform body only makes them shallow.
        let bass: CGFloat = swell * 12
        let drain: CGFloat = raised * 4
        // Raised with the ceiling below, so taller crowns are not simply clipped
        // flat by tanh — which is what happens when this goes up on its own.
        let lobeSum: CGFloat = mound * 27 * detail
        // The sides are driven harder BEFORE the saturation, not scaled after it.
        //
        // Multiplying the finished displacement was self-defeating: tanh had
        // already crushed everything toward 46, so the factor only stretched an
        // output that was barely varying, and the cap it implied (46 * 1.5 = 69)
        // left nothing to raise it further with. Feeding the gain into tanh's
        // argument instead means ordinary listening levels land in the steep part
        // of the curve, which is where the motion is, and the ceiling itself can
        // be raised on the sides where the 77pt flank has room for it. The bottom
        // run is untouched: lateral is 0 there, so gain 1 and the base ceiling.
        let raw: CGFloat = (bass - drain + lobeSum) * travel * room * (1 + 1.2 * lateral)
        // 3pt of margin for the blur, which spreads the silhouette before the
        // alpha threshold takes it back.
        // Where there is no room at all — retracted, the shell is exactly as wide
        // as the cutout — this goes to zero and the surface simply does not travel
        // outward. Nothing is lost: with no flank there is no lit area for the ink
        // to appear against, so the only thing a warp could produce there is a
        // straight clipped wall.
        // 46/70 was more travel than the space can round off. The visible side
        // is 26pt and the outline is relaxed after the fact, so a
        // 57pt bulge could not open smoothly anywhere on the rim — it had to
        // corner. Aggression past what the geometry can curve does not read as
        // aggressive, it reads as torn paper.
        let ceiling: CGFloat = min((34 + 14 * lateral) * room, max(0, headroom - FerrofluidView.blur))
        // Inward, and further inward on the sides so the body pinches rather
        // than only bulging. Written once: it was spelled out identically here
        // and in the no-headroom early return above, which is two places to
        // update when the pinch depth changes. The cutout stays black through it
        // — the camera guarantee is drawn crisp, outside the filter chain.
        func inward() -> CGFloat { max((-7 - 7 * lateral) * room, raw * 0.55) }

        if ceiling < 0.01 { return raw < 0 ? inward() : 0 }
        // Negative values survive now — clamped only so the surface cannot be
        // pulled inside the camera guarantee, which is drawn separately anyway.
        // And it may neck further in on the sides, so the body pinches rather
        // than only bulging. The cutout stays black regardless — the camera
        // guarantee is drawn crisp, outside the filter chain.
        if raw < 0 { return inward() }
        return ceiling * tanh(raw / ceiling)
    }

    func poolPath(displacement: (Double, CGFloat, CGFloat, CGFloat) -> CGFloat) -> Path {
        var points: [CGPoint] = []
        points.reserveCapacity(Self.outlineSamples + 1)

        var amounts = [CGFloat](repeating: 0, count: Self.outlineSamples + 1)
        var surfaces = [(point: CGPoint, normal: CGVector)]()
        surfaces.reserveCapacity(Self.outlineSamples + 1)

        for sample in 0...Self.outlineSamples {
            let position = Double(sample) / Double(Self.outlineSamples)
            let surface = rim(at: position)
            surfaces.append(surface)
            amounts[sample] = displacement(position,
                                           lateralLift(surface.normal),
                                           headroom(from: surface.point, along: surface.normal),
                                           edgeDetail(at: surface.point))
                            * lateralGate(surface.normal)
        }

        // The bezel join first, then relax the whole outline — the sweep runs
        // LAST so the thing that ships is smooth by construction, whatever
        // shaped it.
        for sample in 0...Self.outlineSamples {
            amounts[sample] *= edgeFillet(at: surfaces[sample].point,
                                          amount: amounts[sample])
        }

        for sample in 0...Self.outlineSamples {
            let surface = surfaces[sample]
            let amount = amounts[sample]
            points.append(CGPoint(x: surface.point.x + surface.normal.dx * amount,
                                  y: surface.point.y + surface.normal.dy * amount))
        }

        // Relax the OUTLINE. This is the only smoothing pass.
        //
        // There was a second one first, capping how fast DISPLACEMENT could
        // change between samples. Measured against this one it is redundant:
        // disabling it moves the worst turn 29.4 to 28.8 degrees and the outline
        // area by 0.5%, because bounding displacement is not the same as bounding
        // turn and this pass already does the latter directly.
        //
        // Capping how fast displacement changes is not the same as capping how
        // hard the outline turns, and the difference is where every sharp edge
        // survived: around the corner arcs the normal rotates ~15 degrees per
        // sample and the lateral gate falls from 1 to 0, so points that are all
        // within the displacement cap still describe a 60-degree turn. Averaging
        // each point toward its neighbours attacks the turn directly, which is
        // the thing the eye actually reads as sharp.
        //
        // Eight light passes. Endpoints are held so the outline still closes
        // exactly where the shell does.
        for _ in 0..<8 {
            var relaxed = points
            for i in 1..<(points.count - 1) {
                relaxed[i] = CGPoint(
                    x: points[i].x + 0.38 * (points[i - 1].x + points[i + 1].x - 2 * points[i].x),
                    y: points[i].y + 0.38 * (points[i - 1].y + points[i + 1].y - 2 * points[i].y))
            }
            points = relaxed
        }

        var path = Path()
        guard points.count > 3 else { return path }
        path.move(to: points[0])
        for index in 0..<(points.count - 1) {
            let p0 = points[max(0, index - 1)]
            let p1 = points[index]
            let p2 = points[index + 1]
            let p3 = points[min(points.count - 1, index + 2)]
            let c1 = CGPoint(x: p1.x + (p2.x - p0.x) / 6,
                             y: p1.y + (p2.y - p0.y) / 6)
            let c2 = CGPoint(x: p2.x - (p3.x - p1.x) / 6,
                             y: p2.y - (p3.y - p1.y) / 6)
            path.addCurve(to: p2, control1: c1, control2: c2)
        }
        path.addLine(to: CGPoint(x: points.last!.x, y: -40))
        path.addLine(to: CGPoint(x: points[0].x, y: -40))
        path.closeSubpath()
        return path
    }

}
