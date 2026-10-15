import Foundation
import SwiftUI

/// Headless checks on the ferrofluid's *geometry* — where the lobes sit on the
/// silhouette and how far the surface may travel.
///
/// Everything here was a bug that shipped and could only be seen on screen.
/// The physics in `fluidcheck` was fine each time; the seating was not.
@main
@MainActor
enum GeometryCheck {
    static let notch = CGSize(width: 190, height: 32)
    static let expanded = CGSize(width: 344, height: 130)

    static func main() {
        theSidesMoveAtAll()
        theInkLeavesTheBezelOnACurve()
        theCrownFollowsFrequency()
        theSideLobesResolve()
        jitterNeverCollidesTwoSeats()
        noSeatIsThrownOffTheBody()
        theInkStaysInsideThePanel()
        theTraceOffsetsTheSilhouetteRatherThanTranslatingIt()
        thePillTraceDrawsTheSilhouettesOwnCorner()
        print("geometrycheck: all checks passed")
    }

    // MARK: helpers

    static func sites(_ heights: [Double]) -> [FerrofluidSim.Site] {
        (0..<FerrofluidSim.siteCount).map { i in
            let rim = Double(i) / Double(FerrofluidSim.siteCount - 1)
            return FerrofluidSim.Site(rim: rim, band: i % 12,
                                      fan: Double((i * 7) % 13) / 13 * 2 - 1,
                                      height: heights[i], field: 0, isUp: true)
        }
    }

    static func flat(_ v: Double) -> [Double] {
        [Double](repeating: v, count: FerrofluidSim.siteCount)
    }

    /// Displacement sampled along one run of the outline.
    /// Displacement along one run.
    ///
    /// This calls `displacement` directly, so it sees the physics WITHOUT the
    /// bezel fillet or the outline relaxation that `poolPath` applies. That is
    /// deliberate — these three checks are about where the crown sits and how the
    /// lobes resolve, which are properties of the field. Anything about the
    /// SHAPE that ships has to go through `poolPath`, as
    /// `theInkLeavesTheBezelOnACurve` and `wholeOutlineIsSmooth` do; a check
    /// written against a re-derivation of the maths cannot test the maths.
    static func profile(_ g: Geometry, heights: [Double],
                        swell: CGFloat = 0.55, raised: CGFloat = 0.30,
                        from: Double, to: Double, steps: Int = 120) -> [CGFloat] {
        let lobes = g.lobes(of: sites(heights))
        return (0...steps).map { k in
            let pos = from + (to - from) * Double(k) / Double(steps)
            let n = g.rim(at: pos).normal
            let pt = g.rim(at: pos).point
            return g.displacement(at: pos, lobes: lobes, swell: swell, raised: raised,
                                  lateral: g.lateralLift(n),
                                  headroom: g.headroom(from: pt, along: n)) * g.lateralGate(n)
        }
    }

    /// The visible part of the left vertical run, top of the panel to the corner.
    static func leftEdge(_ g: Geometry, _ heights: [Double]) -> [CGFloat] {
        profile(g, heights: heights, from: g.visibleTopU, to: Double(g.sideRun / g.total))
    }

    // MARK: checks

    /// The regression that started all of this: "we had the base warp out, now
    /// only bottom area moves". 13 of 17 seats had ended up on the bottom run
    /// with lobes too narrow to reach the verticals, so the sides only inflated
    /// uniformly — bigger, but never undulating, which reads as dead.
    static func theSidesMoveAtAll() {
        let g = Geometry(notch: notch, panel: expanded, openness: 1)
        let edge = leftEdge(g, flat(0.55))
        let swing = edge.max()! - edge.min()!
        require(swing > 8, "the left edge barely undulates (swing \(swing)pt)")
        require(edge.max()! > 25, "the left edge hardly leaves the cutout (max \(edge.max()!)pt)")
    }

    /// The notch widens with the sound, and the ink leaves the bezel on a curve.
    ///
    /// Driven through `poolPath`, which is what actually builds the outline. An
    /// earlier version of this check recomputed the displacement itself, fillet
    /// and all — so deleting the fillet from the renderer changed nothing it
    /// looked at and it passed a mutation that removed the very thing it was
    /// written to protect. A check that mirrors the code cannot test the code.
    static func theInkLeavesTheBezelOnACurve() {
        let g = Geometry(notch: notch, panel: expanded, openness: 1)

        /// The outline's left edge, as horizontal distance out from the cutout,
        /// sampled by height. Taken from the real path.
        func leftEdge(heights: [Double], swell: CGFloat) -> [(y: CGFloat, out: CGFloat)] {
            let lobes = g.lobes(of: sites(heights))
            let path = g.poolPath { position, lateral, headroom, detail in
                g.displacement(at: position, lobes: lobes, swell: swell, raised: 0,
                               lateral: lateral, detail: detail, headroom: headroom)
            }
            var points: [(CGFloat, CGFloat)] = []
            path.forEach { element in
                let p: CGPoint?
                switch element {
                case .move(let to): p = to
                case .line(let to): p = to
                case .curve(let to, _, _): p = to
                case .quadCurve(let to, _): p = to
                case .closeSubpath: p = nil
                }
                // Left flank only, and only the part that is on screen.
                if let p, p.x < g.core.midX, p.y >= 0, p.y <= 20 {
                    points.append((p.y, g.core.minX - p.x))
                }
            }
            return points.sorted { $0.0 < $1.0 }.map { (y: $0.0, out: $0.1) }
        }

        let loud = leftEdge(heights: flat(1.0), swell: 1)
        require(loud.count > 4, "the outline gave too few samples on the left flank")

        // It still widens. Without this the rule below is satisfied by ink that
        // never moves.
        let widest = loud.map(\.out).max() ?? 0
        require(widest > 15, "the notch barely widens under drive (\(widest)pt)")

        // The bound below is written against `edgeSlope`, which is the declared
        // contract — so raising it would move its own goalposts. Pin the value
        // too: past about 6pt out per point down the join stops reading as a
        // curve at all, whatever the implementation faithfully does with it.
        // The shoulder has to open on screen and still be a shoulder. Too
        // shallow and the top of the notch never reaches full width — it reads as
        // choked; too steep and it is a chamfer. Both ends of that have shipped.
        // The floor exists so the top of the notch widens with the music; it was
        // 0 twice and choked both times. It is bounded above because past ~0.45
        // the ink arrives at the bezel already wide, which is the slab edge.
        // Two-sided. The upper bound arrived when the lower one was dropped, and
        // a floor of 0 would sail through it — 0 is exactly the value that
        // choked the top of the notch and had to be fixed twice.
        require(Geometry.edgeFloor >= 0.2, "edgeFloor is \(Geometry.edgeFloor) — at that "
                + "floor the top of the notch cannot widen with the music")
        require(Geometry.edgeFloor <= 0.45,
                "edgeFloor is \(Geometry.edgeFloor) — the ink arrives at the bezel "
                + "already wide, which is a slab edge")
        require(Geometry.edgeSlope >= 3 && Geometry.edgeSlope <= 10,
                "edgeSlope is \(Geometry.edgeSlope) — outside the range that reads as a shoulder")

        // The whole outline, not just this flank.
        //
        // Every assertion in this check sampled the left flank between y=0 and
        // y=20. Expanded, the mass that is actually on screen droops off the
        // BOTTOM run — so the region being complained about was the one region
        // nothing tested, and this check passed while the ink was visibly
        // angular. That is the gap that let "fixed" be reported when it was not.
        wholeOutlineIsSmooth()

        // No sharp edge from the top of the screen to the ink.
        //
        // Stated as a slope bound measured from the bezel itself, which needs no
        // sample at y = 0 — and there is none: the rim is sampled every 1.8pt, so
        // the first point on the visible flank sits at y = 1.2. An earlier
        // version looked for a sample below y = 1, found none, fell through to
        // its default and passed every mutation including deleting the fillet
        // outright. The 1.2 allows for smoothstep running above its own average
        // slope through the middle of the join.
        for p in loud {
            // Measured from the POOL's top, 6pt above the screen, which is where
            // the join starts — anchoring it at the visible edge pinned the ink
            // exactly where it shows most and the notch never widened at the top.
            // The floor is deliberate: the ink is already most of the way out at
            // the bezel so the top widens with the music. Smoothness is the
            // outline relaxation's job, not this one's.
            let bound = widest * Geometry.edgeFloor
                      + Geometry.edgeSlope * p.y * 1.3 + 2
            require(p.out <= bound,
                    "the ink is \(p.out)pt out only \(p.y)pt below the bezel "
                    + "(bound \(bound)pt) — that is a slab edge, not a curve")
        }
    }

    /// No corner anywhere on the rim, at any drive.
    static func wholeOutlineIsSmooth() {
        for openness in [0.0, 1.0] {
            let g = Geometry(notch: notch, panel: expanded, openness: CGFloat(openness))
            for heights in [flat(1.0), [1, 0.05, 0.9, 0.1, 0.85, 0.05, 0.95, 0.1, 0.8,
                                        0.05, 0.9, 0.1, 0.85, 0.05, 0.9, 0.1, 0.8]] {
                let lobes = g.lobes(of: sites(heights))
                let path = g.poolPath { position, lateral, headroom, detail in
                    g.displacement(at: position, lobes: lobes, swell: 1, raised: 0,
                                   lateral: lateral, detail: detail, headroom: headroom)
                }
                var pts: [CGPoint] = []
                path.forEach { e in
                    switch e {
                    case .move(let p), .line(let p): pts.append(p)
                    case .curve(let p, _, _): pts.append(p)
                    case .quadCurve(let p, _): pts.append(p)
                    case .closeSubpath: break
                    }
                }
                let rim = Array(pts.prefix(Geometry.outlineSamples + 1))
                // TURN ANGLE, not step length.
                //
                // Step length is the wrong metric and it cost an afternoon: on
                // the corner arcs the normal itself rotates ~15 degrees per
                // sample, so at 40pt of displacement a point moves 12.8pt along a
                // perfectly smooth arc. That is coarse sampling of a curve, not a
                // corner. What makes an outline read as sharp is how hard it
                // turns between one segment and the next.
                var worst: Double = 0, worstAt = -1, worstY: CGFloat = 0
                for i in 1..<(rim.count - 1) {
                    let a = rim[i - 1], b = rim[i], c = rim[i + 1]
                    let u = CGPoint(x: b.x - a.x, y: b.y - a.y)
                    let v = CGPoint(x: c.x - b.x, y: c.y - b.y)
                    let lu = hypot(u.x, u.y), lv = hypot(v.x, v.y)
                    guard lu > 0.001, lv > 0.001 else { continue }
                    let cosine = min(1, max(-1, (u.x * v.x + u.y * v.y) / (lu * lv)))
                    let turn = acos(Double(cosine)) * 180 / .pi
                    if turn > worst { worst = turn; worstAt = i; worstY = b.y }
                }
                require(worst <= 40,
                        "the outline turns \(worst) degrees at sample \(worstAt) "
                        + "(y = \(worstY)) at openness \(openness) — that is a corner")
            }
        }
    }

    /// Which band is loud must decide WHERE on the side the crown sits. Without
    /// this the edge carries no information: every spectrum produced the same
    /// ramp toward the corner and the side read as one uniform bulge.
    static func theCrownFollowsFrequency() {
        let g = Geometry(notch: notch, panel: expanded, openness: 1)
        func crown(_ loud: Int) -> Double {
            var h = flat(0.15); h[loud] = 0.9
            let edge = leftEdge(g, h)
            let peak = edge.firstIndex(of: edge.max()!)!
            return Double(peak) / Double(edge.count - 1)
        }
        let low = crown(0), mid = crown(1), high = crown(2)
        require(low < mid && mid < high,
                "the crown does not walk down the edge with frequency (\(low), \(mid), \(high))")
        require(high - low > 0.25,
                "the crown barely moves between the lowest and highest side band (\(high - low))")
    }

    /// Scalloped, not fused and not a comb. Three equal side bands must read as
    /// more than one peak, while the trough between them stays well clear of the
    /// baseline — isolated bumps are the spike comb this renderer exists not to be.
    static func theSideLobesResolve() {
        let g = Geometry(notch: notch, panel: expanded, openness: 1)
        var h = flat(0.20); h[0] = 0.7; h[1] = 0.7; h[2] = 0.7
        let e = leftEdge(g, h)
        let peaks = (1..<(e.count - 1)).filter { e[$0] > e[$0 - 1] && e[$0] >= e[$0 + 1] }
        require(peaks.count >= 2, "the three side lobes fused into one hump")
        let troughs = (1..<(e.count - 1)).filter { e[$0] < e[$0 - 1] && e[$0] <= e[$0 + 1] }
        if let t = troughs.map({ e[$0] }).min(), let p = peaks.map({ e[$0] }).max() {
            require(t / p > 0.30, "the side lobes separated into isolated spikes (\(t / p))")
        }
    }

    /// The anti-comb jitter is a fraction of the LOCAL seat spacing. A flat
    /// fraction of the whole rim is 30% of the spacing on the bottom run but 47%
    /// of it on a side, where it threw two lobes 3pt apart and fused them however
    /// narrow they were made.
    static func jitterNeverCollidesTwoSeats() {
        let g = Geometry(notch: notch, panel: expanded, openness: 1)
        let seats = g.lobes(of: sites(flat(0.5))).map(\.seat).sorted()
        let gaps = zip(seats, seats.dropFirst()).map { $1 - $0 }
        let nominal = 1.0 / Double(FerrofluidSim.siteCount)
        require(gaps.min()! > nominal * 0.25,
                "two seats collided (smallest gap \(gaps.min()!) vs nominal \(nominal))")
    }

    /// A lobe thrown past the top of the run tilts the surface instead of
    /// crowning it, and it is always the loudest band that goes — band 0 sits
    /// closest to the lip.
    static func noSeatIsThrownOffTheBody() {
        for openness in stride(from: 0.0, through: 1.0, by: 0.25) {
            let g = Geometry(notch: notch, panel: expanded, openness: CGFloat(openness))
            for seat in g.lobes(of: sites(flat(0.5))).map(\.seat) {
                require(seat >= g.visibleTopU - 1e-9 && seat <= 1 - g.visibleTopU + 1e-9,
                        "a seat sits off the visible body at openness \(openness): \(seat)")
            }
        }
    }

    /// Retracted this had never been checked at all, and retracted is the state
    /// that must not paint over window chrome. Driven flat out at every openness,
    /// the outline has to stay inside the panel it is drawn in.
    static func theInkStaysInsideThePanel() {
        for openness in stride(from: 0.0, through: 1.0, by: 0.1) {
            let panel = CGSize(width: notch.width + (expanded.width - notch.width) * CGFloat(openness),
                               height: expanded.height)
            let g = Geometry(notch: notch, panel: panel, openness: CGFloat(openness))
            let lobes = g.lobes(of: sites(flat(1.0)))
            for k in 0...400 {
                let pos = Double(k) / 400
                let s = g.rim(at: pos)
                let n = s.normal
                let amount = g.displacement(at: pos, lobes: lobes, swell: 1.0, raised: 0,
                                            lateral: g.lateralLift(n),
                                            headroom: g.headroom(from: s.point, along: n))
                           * g.lateralGate(n)
                let x = s.point.x + n.dx * amount
                let y = s.point.y + n.dy * amount
                require(x >= -0.5 && x <= panel.width + 0.5,
                        "ink left the panel sideways at openness \(openness): x \(x) of \(panel.width)")
                require(y <= panel.height + 0.5,
                        "ink went below the panel at openness \(openness): y \(y) of \(panel.height)")
            }
        }
    }

    /// The progress trace is the silhouette moved INWARD by its own half-width,
    /// everywhere — not just where the edge is straight.
    ///
    /// `NotchBottomEdge` insets its frame and then clamped the SHELL's corner
    /// radius against it, which translates the corner by (inset, -inset) instead
    /// of offsetting it: exact at both tangent points, `inset * sqrt(2)` along the
    /// normal at 45 degrees. The stroke's outer boundary therefore left the
    /// silhouette on both bottom corners — the property the type's own doc
    /// comment claims for it — while every assertion about the trace looked at
    /// the straight bottom run, where it held. Half a rule again, and the half
    /// that was missing is the half with the curves in it.
    static func theTraceOffsetsTheSilhouetteRatherThanTranslatingIt() {
        // 1.25 is the resting stroke's half-width, 1.7 the hover swell's and 2
        // the grab's — the inset animates, so the property has to hold at all
        // three rather than at the one the panel happens to rest in.
        for inset in [CGFloat(1.25), 1.7, 2] {
            for (width, height, radius) in [(CGFloat(372), CGFloat(159), CGFloat(24)),
                                            (232, 73, 18), (322, 33, 9)] {
                let shell = walk(NotchBottomEdge(width: width, height: height,
                                                 bottomCornerRadius: radius, inset: 0),
                                 steps: 1600)
                let trace = walk(NotchBottomEdge(width: width, height: height,
                                                 bottomCornerRadius: radius, inset: inset),
                                 steps: 240)
                for p in trace {
                    let d = distance(from: p, toPolyline: shell)
                    // Two edges, because the defect had a direction: too far in
                    // and the outline breaks into two lines round the corner, too
                    // far out and the stroke hangs past the shell.
                    // 1.12, from measurement on both sides: offset properly the
                    // ratio runs 1.000 to 1.061 — a quadratic quarter-turn is not
                    // quite a circular arc, so the exact offset is unreachable —
                    // and translated it reaches 1.190. The bound sits between the
                    // two with room on each side rather than hugging either.
                    require(d <= inset * 1.12,
                            "at inset \(inset) on a \(width)x\(height) shell the trace runs "
                            + "\(d)pt inside the silhouette — the corner is translated, "
                            + "not offset")
                    require(d >= inset * 0.95,
                            "at inset \(inset) on a \(width)x\(height) shell the trace runs "
                            + "\(d)pt from the silhouette, closer than its own half-width")
                }
            }
        }
    }

    /// The pill silhouette and the trace must draw the SAME bottom corner.
    ///
    /// `NotchShape`'s pill branch floors its radius at 10 so a menu-bar-height
    /// capsule still reads as a capsule; `NotchBottomEdge` and every other
    /// consumer of the same `bottomCornerRadius` never heard of the floor. With
    /// the cutout radius at its shipped default of 9, the silhouette rounds at
    /// 10 while the trace rounds at 9 − inset from a shifted centre, so the
    /// stroke's outer boundary leaves the shell at both bottom corners — tinted
    /// ink on the menu bar beside the pill. Same class as the translation
    /// defect above, in the one branch that check never walks.
    static func thePillTraceDrawsTheSilhouettesOwnCorner() {
        // The rule itself, pinned: floor 10, straight passthrough above the
        // floor, half-height clamp on shells too short to carry it.
        require(NotchShape.pillCornerRadius(height: 24, bottomCornerRadius: 9) == 10,
                "the pill floor moved off 10 — the capsule reading of a "
                + "menu-bar-height shell was a measured product decision")
        require(NotchShape.pillCornerRadius(height: 24, bottomCornerRadius: 12) == 12,
                "a radius above the floor no longer passes through the pill rule")
        require(NotchShape.pillCornerRadius(height: 16, bottomCornerRadius: 40) == 8,
                "the pill rule lost its half-height clamp")

        let h = CGFloat(24), w = CGFloat(322)
        for radius in [CGFloat(6), 9, 10, 12] {
            // What the controller hands every consumer for a pill.
            let handed = NotchShape.pillCornerRadius(height: h, bottomCornerRadius: radius)
            require(NotchShape.pillCornerRadius(height: h, bottomCornerRadius: handed) == handed,
                    "the pill rule is not idempotent at \(radius), so the "
                    + "silhouette disagrees with a controller that already applied it")
            let shape = NotchShape(width: w, height: h, topCornerRadius: 9,
                                   bottomCornerRadius: handed, style: .pill)
            let drawn = pillDrawnRadius(shape, width: w, height: h)
            for inset in [CGFloat(0), 1.25, 2] {
                let edge = NotchBottomEdge(width: w, height: h,
                                           bottomCornerRadius: handed, inset: inset)
                // The edge path opens with its move — (minX, maxY − br) — so
                // the drawn radius falls straight out of the first element.
                var start = CGPoint.zero
                var seenMove = false
                edge.path(in: CGRect(x: 0, y: 0, width: w, height: h)).forEach {
                    if case .move(let p) = $0, !seenMove { seenMove = true; start = p }
                }
                let traced = (h - inset) - start.y
                require(abs(drawn - (traced + inset)) <= 0.01,
                        "the pill silhouette rounds at \(drawn) while the trace at "
                        + "inset \(inset) rounds at \(traced) — radius \(radius) "
                        + "reaches the two shapes as two different corners")
            }
        }

        // The walk above proves the shapes agree when handed one value; this
        // proves the shipped wiring hands them one value. NotchController
        // cannot be compiled here (it needs a live screen), so it is read the
        // way fluidcheck reads the tap's queue structure.
        let controller = strippedSource("Sources/NotchApp/Notch/NotchController.swift")
        require(controller.contains("NotchShape.pillCornerRadius("),
                "NotchController.bottomCornerRadius no longer routes the pill "
                + "through NotchShape.pillCornerRadius — the trace, trim mapping "
                + "and rim are handed a corner the silhouette will not draw")
        let shapeSource = strippedSource("Sources/NotchApp/Notch/NotchShape.swift")
        require(!shapeSource.contains("Path(roundedRect:"),
                "the pill branch went back to Path(roundedRect:), whose corners "
                + "are a different curve family from the trace's quadratic "
                + "quarter-turns — no radius can make the trace sit on them")
    }

    /// The bottom corner radius a shape actually draws, recovered from its
    /// path: the bottom run's leftmost endpoint is (minX + radius, maxY).
    /// Element endpoints, not sampled trim points, so the answer is exact even
    /// at the capsule limit where the straight side vanishes.
    static func pillDrawnRadius(_ shape: NotchShape, width: CGFloat, height: CGFloat) -> CGFloat {
        let path = shape.path(in: CGRect(x: 0, y: 0, width: width, height: height))
        var ends: [CGPoint] = []
        path.forEach { element in
            switch element {
            case .move(let p), .line(let p): ends.append(p)
            case .quadCurve(let p, _), .curve(let p, _, _): ends.append(p)
            case .closeSubpath: break
            }
        }
        guard let maxY = ends.map(\.y).max() else { return .nan }
        let bottom = ends.filter { abs($0.y - maxY) < 0.01 }.map(\.x)
        return bottom.min() ?? .nan
    }

    /// The file with line comments removed, so a lint can neither be tripped
    /// nor satisfied by prose.
    static func strippedSource(_ path: String) -> String {
        guard let s = try? String(contentsOfFile: path, encoding: .utf8) else {
            require(false, "cannot read \(path)")
            return ""
        }
        return s.split(separator: "\n", omittingEmptySubsequences: false).map { line in
            if let r = line.range(of: "//") { return String(line[line.startIndex..<r.lowerBound]) }
            return String(line)
        }.joined(separator: "\n")
    }

    /// Points along a shape's real path, by arc length.
    static func walk(_ edge: NotchBottomEdge, steps: Int) -> [CGPoint] {
        let path = edge.path(in: CGRect(x: 0, y: 0, width: edge.width, height: edge.height))
        return (0...steps).compactMap {
            path.trimmedPath(from: 0, to: max(1e-6, CGFloat($0) / CGFloat(steps))).currentPoint
        }
    }

    /// Distance to the polyline's SEGMENTS, not to its vertices: measured to the
    /// vertices, the answer carries the sample spacing as a bias and the bound
    /// above would be measuring the sampling rate.
    static func distance(from p: CGPoint, toPolyline pts: [CGPoint]) -> CGFloat {
        var best = CGFloat.infinity
        for i in 1..<pts.count {
            let a = pts[i - 1], b = pts[i]
            let dx = b.x - a.x, dy = b.y - a.y
            let len = dx * dx + dy * dy
            let t = len > 0 ? max(0, min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len)) : 0
            best = min(best, hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy)))
        }
        return best
    }

    static func require(_ ok: Bool, _ message: @autoclosure () -> String) {
        if !ok {
            print("geometrycheck: \(message())")
            exit(1)
        }
    }
}
