import SwiftUI

/// One continuous body of ink around the cutout.
///
/// A single closed path displaced along its own normal: bass heaves the whole
/// surface and every band raises a smooth mound where it sits on the rim. No
/// spikes, particles or detached parts. A tight blur and alpha threshold keep the
/// edge hard so it reads as liquid rather than a gradient.
struct FerrofluidView: View, Animatable {

    var sim: FerrofluidSim
    var notchSize: CGSize
    var panelSize: CGSize
    /// 0 retracted, 1 expanded, and everything between. Animatable, so the peaks
    /// migrate around the real outline as the shell morphs (and retarget if an expand
    /// is interrupted) instead of jumping between the two seatings in one frame.
    var openness: CGFloat

    var animatableData: CGFloat {
        get { openness }
        set { openness = newValue }
    }

    /// Reduce Motion keeps every state change but takes the travel out of it: peaks
    /// still break the surface on the beat, they just reach less far.
    var reduceMotion: Bool = false
    /// The cutout's corner, from the controller, so ink and shell round their shared
    /// edge by the same amount.
    var cornerRadius: CGFloat = Geometry.cornerRadius
    /// The track's colour, for the rim glow. The ink itself is always black.
    var tint: Color = .white

    /// Blur radius. With the alpha threshold it rounds every junction between mounds,
    /// while a straight step edge holds its position under a symmetric blur at
    /// threshold 0.5, so the cutout's own edges do not move. Internal so `Geometry`
    /// can leave this much room at the panel edge.
    static let blur: CGFloat = 3.4

    var body: some View {
        // Read here, not by the parent: `isSettled` is derived from fields rewritten
        // every frame, and reading it in `NotchRootView`'s body would invalidate the whole
        // panel each frame.
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
        // The ink's own openness, which trails the shell's. Clamped to `openness` so it
        // never leads the chrome, which keeps ink out of the menu bar structurally.
        let inkOpen = max(0, min(openness, CGFloat(sim.inkOpen)))
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

            // Built once and reused: the glow and the ink are the same shape, so the halo
            // cannot drift out of register.
            let outline = geometry.poolPath(displacement: surface)
            let paint: (GraphicsContext, Color) -> Void = { ctx, color in
                ctx.fill(outline, with: .color(color))
            }

            // 1. The glow, behind everything. Scaled by openness so it arrives with the panel,
            // and off when retracted, where it would be cut at the menu-bar line. Its strength
            // is the audio's transient, never a clock; the gate lives in `glowAlpha`.
            if haloAlpha > 0.002 {
                context.drawLayer { glow in
                    // Radius rides the transient too, so a strike lands harder than a snare.
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

            // 3. The ink itself, through blur then threshold so peaks fuse into one surface
            //    with a liquid neck.
            context.drawLayer { ink in
                ink.addFilter(.alphaThreshold(min: 0.5, color: .black))
                ink.addFilter(.blur(radius: Self.blur))

                // Retracted, nothing may reach below the menu-bar band (browser tabs and window
                // chrome). Interpolated rather than gated: at openness 0 this is exactly the band,
                // at 1 the whole panel.
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

            // 4. The wet surface. Polished black liquid shows its surroundings as soft
            //    reflections inside each bulge, never as a line along the edge (rim specular
            //    is a standing rejection). Each lobe carries a reflection of the cover's colour
            //    part way out from the cutout, sized to the lobe and well clear of the edge,
            //    so it slides and swells with the surface; the body carries one broad one that
            //    the bass heave stretches. Never over the cutout: that is the camera.
            guard inkOpen > 0.05 else { return }
            // Lifted toward white: a reflection is the light, not the cover's darkest shade.
            let light = tint.mix(with: .white, by: 0.4)
            context.drawLayer { sheen in
                sheen.clip(to: outline)
                sheen.clip(to: Path(roundedRect: geometry.core, cornerRadius: geometry.cornerRadius),
                           options: .inverse)
                sheen.addFilter(.blur(radius: 3))
                sheen.blendMode = .plusLighter
                sheen.opacity = Double(inkOpen)
                for reflection in geometry.reflections(lobes: lobes, swell: swell, surface: surface) {
                    sheen.fill(Path(ellipseIn: reflection.rect),
                               with: .radialGradient(
                                   Gradient(colors: [light.opacity(reflection.strength),
                                                     light.opacity(0)]),
                                   center: CGPoint(x: reflection.rect.midX, y: reflection.rect.midY),
                                   startRadius: 0,
                                   endRadius: max(reflection.rect.width, reflection.rect.height) / 2))
                }
            }
        }
    }


}

/// Internal so `tools/geometrycheck.swift` can drive it headlessly.
struct Geometry {
    /// Matches the physical cutout's filleted bottom corners. At zero margin the ink is
    /// exactly the cutout, so square ink would poke out past the housing.
    static let cornerRadius: CGFloat = 6
    static let outlineSamples = 144

    let core: CGRect
    let openness: CGFloat
    let panel: CGSize
    let cornerRadius: CGFloat

    /// The pool's own top edge, which sits above the screen. Internal because
    /// `geometrycheck` measures the visible flank from it. The join itself is measured
    /// from the screen edge; anchoring it here makes the ink arrive already wide.
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
        // Zero margin: the resting ink is the cutout, so colour begins where the housing
        // ends and no black skirt hangs past it. The cutout interior is physically black
        // either way; panel colour must never appear within it.
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

    /// The topmost point of the outline that is on screen, as a rim fraction. Seats
    /// stay at or below it: a lobe thrown past the top of the run tilts the surface
    /// instead of crowning it, and band 0 (the loudest) seats closest to the lip.
    var visibleTopU: Double { Double((2 - top) / total) }

    /// Where a site sits on the outline, blended between the two seatings.
    ///
    /// Expanded, sites live on the bottom run and climb both vertical sides, two per
    /// side, high enough for their mounds to cover the visible edge. Retracted there
    /// is no vertical room, so they live on the two vertical runs beside the camera.
    /// The two are interpolated, not switched, so each peak walks around the
    /// silhouette as the panel opens.
    func seatU(_ rim: Double) -> Double {
        let side = Double(sideRun / total)
        // Three sites per vertical run: spread evenly, a side gets about 2.1 and two lobes
        // on a 32 pt run merge into one mass. This piecewise-linear warp hands each side
        // the first and last 3/17 of the spectrum, staying monotonic and continuous (at
        // `q` it is `side`, at `1 - q` it is `1 - side`).
        let q = 3.0 / Double(FerrofluidSim.siteCount)
        // The top of the run that is on screen. A fixed 0.03 would seat band 0 at 1.8 pt,
        // where its jitter puts the peak above the panel and it contributes a slope.
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

    /// Retracted, only the sideways component of the surface may move; any downward
    /// component would push ink below the menu bar. Expanded, the vertical sides swing
    /// further than the bottom: the bottom run is 178 pt of the 261 pt rim and the
    /// sides 32 pt each, and the flank beside the cutout has more room (77 pt against
    /// a tanh ceiling of 46). Keyed on `abs(normal.dx)`, which runs smoothly 1, 0, 1
    /// around the corners.
    func lateralLift(_ normal: CGVector) -> CGFloat {
        abs(normal.dx) * openness
    }

    func lateralGate(_ normal: CGVector) -> CGFloat {
        // Blended, so the warp turns from sideways-only to unrestricted as the panel opens.
        abs(normal.dx) + (1 - abs(normal.dx)) * openness
    }
    /// How far below the bezel the per-band detail comes in.
    static let anchorRun: CGFloat = 10
    /// Steepest the silhouette may climb away from the bezel, in points out per point
    /// down. The ink travels up to about 57 pt sideways against a 26 pt visible side,
    /// so a fixed-length join would read as a shelf; the join scales with the travel.
    static let edgeSlope: CGFloat = 4
    /// How wide the ink already is where it meets the bezel, as a fraction of its full
    /// travel. Never zero, which chokes the top.
    static let edgeFloor: CGFloat = 0.35


    /// The curve where the ink leaves the bezel, as a fraction of `amount`.
    ///
    /// Displacement runs along the rim's normal, horizontal on the vertical runs, so a
    /// widened surface is a slab meeting the screen's top edge at a right angle. The
    /// run is `amount / edgeSlope`, measured from the screen's edge. Anchored there
    /// with a shallow slope it exceeds half the 26 pt visible side and chokes the top;
    /// started off screen, the ink arrives wide with a hard first row. The floor makes
    /// it open on screen from a width already carrying the music; at zero it would
    /// also anchor the relaxation sweep at zero.
    func edgeFillet(at point: CGPoint, amount: CGFloat) -> CGFloat {
        let run = max(0.5, abs(amount) / Self.edgeSlope)
        let t = min(1, max(0, point.y / run))
        return Self.edgeFloor + (1 - Self.edgeFloor) * (t * t * (3 - 2 * t))
    }

    /// How much per-band detail this piece of rim may carry, 0 at the bezel. The
    /// whole-body swell ignores it: offsetting a rounded shape keeps it rounded, so the
    /// body widens the notch and the curve survives, whereas narrow lobes at the bezel
    /// put bumps on the one corner the hardware also draws.
    func edgeDetail(at point: CGPoint) -> CGFloat {
        let t = min(1, max(0, point.y / Self.anchorRun))
        // Smootherstep: at full drive (about 57 pt) smoothstep's 0.07 one point below the
        // bezel still shows a 4 pt flare; this leaves 0.5 pt and reaches full by 10 pt.
        return t * t * t * (t * (t * 6 - 15) + 10)
    }

    /// How far this piece of rim may travel outward before the panel's edge. The panel
    /// clips the ink, so anything past this is a flat vertical wall. Feeding it into
    /// the ceiling makes containment a property of the geometry rather than of a gain
    /// tuned for one panel width.
    func headroom(from point: CGPoint, along normal: CGVector) -> CGFloat {
        var limit = CGFloat.greatestFiniteMagnitude
        if normal.dx > 0.001 { limit = min(limit, (panel.width - point.x) / normal.dx) }
        if normal.dx < -0.001 { limit = min(limit, point.x / -normal.dx) }
        // Downward only: above the panel is the bezel, handled by the retracted gate.
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

    /// The active sites' seats and heights, resolved once per frame. `seatU` depends
    /// only on `site.rim` and `openness`, so computing it inside the sample loop would
    /// repeat up to 17 distinct values over a thousand times per path.
    func lobes(of sites: [FerrofluidSim.Site])
    -> [(seat: Double, height: CGFloat, spread: CGFloat, reach: Double)] {
        sites.compactMap { site in
            guard site.height > 0.003 else { return nil }
            // `fan` offsets the seat by a fraction of the lattice spacing so the lobes sit on
            // an irregular rank, not a comb. Scaled to the local seat spacing: a flat value
            // that is 30% of the bottom-run spacing is 47% of the side spacing and could fuse
            // two lobes.
            let step = 1.0 / Double(FerrofluidSim.siteCount - 1)
            let local = abs(seatU(min(1, site.rim + step)) - seatU(site.rim))
            let jitter = site.fan * 0.3 * local
            // Clamped into the visible body: the jitter (+-5.4 pt) could otherwise throw a lobe
            // off the top of the run.
            let seat = min(1 - visibleTopU, max(visibleTopU, seatU(site.rim) + jitter))
            // How sideways this lobe's own seat is. Taken from the seat, not the sample, so
            // the lobe keeps one width across its span and stays a symmetric mound.
            let sideness = abs(rim(at: seat).normal.dx) * openness
            // `spread` and its cutoff depend only on the lobe, so they are computed here
            // rather than per sample; `base` is the one term that needs the frame.
            let base = 34 - 13 * openness
            let spread = base * (1 + 0.35 * CGFloat(site.height))
                              * (1 + 0.22 * CGFloat(site.fan))
                              * (1 + 1.0 * sideness)
            // Past this the wider Gaussian is under 1e-4, which a 144-sample outline cannot
            // express.
            let reach = 5.0 / Double(spread)
            return (seat, CGFloat(site.height), spread, reach)
        }
    }

    /// Bass heaves the whole body and every active band raises a broad Gaussian mound
    /// in that same surface: a warp, never a pile of blobs.
    func displacement(reduce: Bool = false,
                      at position: Double,
                      lobes: [(seat: Double, height: CGFloat, spread: CGFloat, reach: Double)],
                      swell: CGFloat,
                      raised: CGFloat,
                      /// How sideways this piece of rim is, 0 on the bottom run and 1 on the
                      /// verticals, already scaled by openness.
                      lateral: CGFloat = 0,
                      /// How much per-band detail this point may carry. The body swell ignores it,
                      /// so the notch widens smoothly.
                      detail: CGFloat = 1,
                      /// Distance to the panel edge along the normal. The surface saturates before it,
                      /// so it is never cut flat.
                      headroom: CGFloat = .greatestFiniteMagnitude,
                      pointerRim: Double = 0.5,
                      pointerPull: CGFloat = 0) -> CGFloat {
        // Narrow enough that a band is its own lobe, and narrower the harder it hit: at a
        // broad spread neighbouring mounds overlap and seventeen peaks sum into one hill.
        // Width coupled to height is the Rosensweig signature.
        var mound: CGFloat = 0
        // The neck between them. A Mexican-hat basis (narrow positive core, wider negative
        // surround) lets the outline curve inward: the surface between two peaks is
        // pulled down, which is what gives a row of humps surface tension.
        for lobe in lobes {
            // Reach is tuned to the seat spacing (about 11 pt on a vertical run). Below about
            // 0.9 the three side peaks fuse into one hump; much above it they separate into
            // isolated bumps, the spike comb this renderer exists to avoid. Lobes are culled
            // by distance, since only the nearest few contribute.
            guard abs(lobe.seat - position) < lobe.reach else { continue }
            let d = (lobe.seat - position) * lobe.spread
            let core = exp(-d * d)
            // Shallow and only just wider than the core: a deep surround makes each neighbour
            // subtract enough that the sum collapses and the ink stops leaving the cutout.
            let surround = exp(-d * d * 0.35) * 0.18
            mound += lobe.height * CGFloat(core - surround)
        }

        // The pointer's own swell: wider and gentler than a band's lobe, since it is a
        // hand rather than a frequency.
        if pointerPull > 0.002 {
            let d = (pointerRim - position) * 4.6
            mound += pointerPull * 0.8 * CGFloat(exp(-d * d))
        }

        // Driven hard: the content layer draws above the ink, so overlap with the title is
        // fine and tanh only has to keep the reach inside the panel.
        let travel: CGFloat = reduce ? Motion.travel : 1
        // Retracted is a menu bar, not a canvas: scaling with openness gives one behaviour,
        // restrained in the band and unrestrained in the panel.
        let room = 0.42 + 0.58 * openness
        // Less body, more crown: a larger bass term lifts the outline so far that the
        // per-band peaks ride on it as shallow ripples.
        // The swell is a bass hit now, not a level, so it can be big: a kick heaves the body
        // well past the band and drains back.
        let bass: CGFloat = swell * 16
        let drain: CGFloat = raised * 4
        // Raised together with the ceiling below, so taller crowns are not clipped flat
        // by tanh.
        let lobeSum: CGFloat = mound * 27 * detail
        // The sides are driven harder before saturation, not scaled after it: scaling the
        // finished displacement stretches an output tanh has already crushed. Feeding the
        // gain into tanh's argument puts ordinary levels in the steep part of the curve
        // and lets the ceiling rise where the 77 pt flank has room. Bottom run: lateral 0.
        let raw: CGFloat = (bass - drain + lobeSum) * travel * room * (1 + 1.2 * lateral)
        // 3 pt of margin for the blur. With no room at all (retracted, the shell is as wide
        // as the cutout) this goes to zero, since there is no lit area for ink to appear
        // against. The ceiling stays within what the geometry can round off; a 57 pt bulge
        // on a 26 pt visible side could not open smoothly.
        let ceiling: CGFloat = min((34 + 14 * lateral) * room * (1 + 0.9 * swell),
                                   max(0, headroom - FerrofluidView.blur))
        // Inward, and further on the sides so the body pinches rather than only bulging.
        // The camera guarantee is drawn crisp outside the filter chain.
        func inward() -> CGFloat { max((-7 - 7 * lateral) * room, raw * 0.55) }

        if ceiling < 0.01 { return raw < 0 ? inward() : 0 }
        if raw < 0 { return inward() }
        return ceiling * tanh(raw / ceiling)
    }

    /// Where the wet surface shows a reflection, and how bright: one per standing lobe,
    /// placed part way out along its normal and kept inside the bulge, plus one broad
    /// one under the body.
    func reflections(lobes: [(seat: Double, height: CGFloat, spread: CGFloat, reach: Double)],
                     swell: CGFloat,
                     surface: (Double, CGFloat, CGFloat, CGFloat) -> CGFloat)
    -> [(rect: CGRect, strength: Double)] {
        var result: [(rect: CGRect, strength: Double)] = []
        for lobe in lobes where lobe.height > 0.12 {
            let (point, normal) = rim(at: lobe.seat)
            let amount = surface(lobe.seat, lateralLift(normal), headroom(from: point, along: normal),
                                 edgeDetail(at: point)) * lateralGate(normal)
            guard amount > 6 else { continue }
            // Part way out, on the near side of the tip, and no larger than the bulge.
            let centre = CGPoint(x: point.x + normal.dx * amount * 0.4,
                                 y: point.y + normal.dy * amount * 0.4)
            let along = min(amount * 1.4, 34)
            let across = min(amount * 0.55, 14)
            let size = abs(normal.dx) > 0.5 ? CGSize(width: across, height: along)
                                            : CGSize(width: along, height: across)
            var rect = CGRect(x: centre.x - size.width / 2, y: centre.y - size.height / 2,
                              width: size.width, height: size.height)
            // Clear of the cutout, which the layer clips out: a reflection cut by it would
            // show the cutout's straight edge.
            if rect.intersects(core) {
                if normal.dy > 0.5 { rect.origin.y = max(rect.minY, core.maxY + 1) }
                else if normal.dx < 0 { rect.origin.x = min(rect.minX, core.minX - rect.width - 1) }
                else { rect.origin.x = max(rect.minX, core.maxX + 1) }
            }
            result.append((rect,
                           Double(min(0.8, 0.3 + 0.5 * lobe.height))))
        }
        // The body's own reflection: a wide soft band under the cutout, stretched by the heave.
        // Only on a deep heave: on a shallow body it would be a streak along the edge.
        let body = surface(0.5, 0, headroom(from: CGPoint(x: core.midX, y: core.maxY),
                                            along: CGVector(dx: 0, dy: 1)), 1) * openness
        if body > 16 {
            let width = core.width * 0.6
            let height = min(body * 0.45, 20)
            result.append((CGRect(x: core.midX - width / 2, y: core.maxY + body * 0.5 - height / 2,
                                  width: width, height: height),
                           Double(0.22 + 0.4 * min(1, swell))))
        }
        return result
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

        // The bezel join first, then relax the whole outline; the sweep runs last so
        // what ships is smooth by construction.
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

        // Relax the outline; this is the only smoothing pass. Capping how fast displacement
        // changes does not cap how hard the outline turns: around the corner arcs the
        // normal rotates about 15 degrees per sample while the lateral gate falls from 1
        // to 0. Eight light passes; endpoints are held so the outline closes with the shell.
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
