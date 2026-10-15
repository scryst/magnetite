import Foundation
import SwiftUI

/// Headless checks on the ferrofluid's geometry: where the lobes sit on the
/// silhouette and how far the surface may travel. `fluidcheck` covers the
/// physics; these cover how it is seated.
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
    ///
    /// This calls `displacement` directly, so it sees the physics without the
    /// bezel fillet or outline relaxation that `poolPath` applies. That suits the
    /// checks that use it, which are about the field. Anything about the shape
    /// that ships must go through `poolPath`, since a check written against a
    /// re-derivation of the maths cannot test the maths.
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

    /// The sides must undulate, not just inflate. When most seats sit on the
    /// bottom run with lobes too narrow to reach the verticals, the sides grow
    /// uniformly and read as dead.
    static func theSidesMoveAtAll() {
        let g = Geometry(notch: notch, panel: expanded, openness: 1)
        let edge = leftEdge(g, flat(0.55))
        let swing = edge.max()! - edge.min()!
        require(swing > 8, "the left edge barely undulates (swing \(swing)pt)")
        require(edge.max()! > 25, "the left edge hardly leaves the cutout (max \(edge.max()!)pt)")
    }

    /// The notch widens with the sound, and the ink leaves the bezel on a curve
    /// rather than a slab edge.
    ///
    /// Driven through `poolPath`, which builds the real outline. Recomputing the
    /// displacement here would leave a renderer that dropped the fillet
    /// unnoticed.
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

        // It still widens; otherwise the bound below is met by ink that never
        // moves.
        let widest = loud.map(\.out).max() ?? 0
        require(widest > 15, "the notch barely widens under drive (\(widest)pt)")

        // The slope bound below is written against `edgeSlope`, so raising it
        // would move its own goalposts; the constants are pinned too. The floor
        // lets the top of the notch widen with the music (0 choked it). Above
        // about 0.45 the ink arrives at the bezel already wide, which is a slab
        // edge. Past roughly 6 pt out per point down, the join stops reading as
        // a curve.
        require(Geometry.edgeFloor >= 0.2, "edgeFloor is \(Geometry.edgeFloor) — at that "
                + "floor the top of the notch cannot widen with the music")
        require(Geometry.edgeFloor <= 0.45,
                "edgeFloor is \(Geometry.edgeFloor) — the ink arrives at the bezel "
                + "already wide, which is a slab edge")
        require(Geometry.edgeSlope >= 3 && Geometry.edgeSlope <= 10,
                "edgeSlope is \(Geometry.edgeSlope) — outside the range that reads as a shoulder")

        // The whole outline, not just this flank: expanded, the visible mass
        // droops off the bottom run, which the flank samples never touch.
        wholeOutlineIsSmooth()

        // No sharp edge from the top of the screen to the ink, stated as a slope
        // bound from the bezel itself. The rim is sampled every 1.8 pt, so the
        // first visible sample sits at y = 1.2; the 1.3 factor allows for
        // smoothstep running above its average slope through the middle of the
        // join.
        for p in loud {
            // Measured from the pool's top, 6 pt above the screen, where the join
            // starts. The floor is deliberate: the ink is already most of the way
            // out at the bezel so the top widens with the music. Smoothness is
            // the outline relaxation's job.
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
                // Measured as turn angle, not step length: on a corner arc the
                // normal rotates about 15 degrees per sample, so a point moves
                // 12.8 pt along a smooth arc at 40 pt of displacement. What makes
                // an outline read as sharp is how hard it turns between segments.
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

    /// Which band is loud decides where on the side the crown sits. Without
    /// this every spectrum produces the same ramp toward the corner and the side
    /// reads as one uniform bulge.
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

    /// The side lobes are scalloped: three equal bands must read as more than
    /// one peak, while the troughs stay well clear of the baseline. Isolated
    /// bumps would be the spike comb this renderer exists not to be.
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

    /// The anti-comb jitter is a fraction of the local seat spacing. A flat
    /// fraction of the whole rim is 30% of the spacing on the bottom run but 47%
    /// on a side, where it could throw two lobes 3 pt apart and fuse them.
    static func jitterNeverCollidesTwoSeats() {
        let g = Geometry(notch: notch, panel: expanded, openness: 1)
        let seats = g.lobes(of: sites(flat(0.5))).map(\.seat).sorted()
        let gaps = zip(seats, seats.dropFirst()).map { $1 - $0 }
        let nominal = 1.0 / Double(FerrofluidSim.siteCount)
        require(gaps.min()! > nominal * 0.25,
                "two seats collided (smallest gap \(gaps.min()!) vs nominal \(nominal))")
    }

    /// Every seat stays on the visible body. A lobe thrown past the top of the
    /// run tilts the surface instead of crowning it, and the loudest band
    /// suffers first since band 0 sits closest to the lip.
    static func noSeatIsThrownOffTheBody() {
        for openness in stride(from: 0.0, through: 1.0, by: 0.25) {
            let g = Geometry(notch: notch, panel: expanded, openness: CGFloat(openness))
            for seat in g.lobes(of: sites(flat(0.5))).map(\.seat) {
                require(seat >= g.visibleTopU - 1e-9 && seat <= 1 - g.visibleTopU + 1e-9,
                        "a seat sits off the visible body at openness \(openness): \(seat)")
            }
        }
    }

    /// Driven flat out at every openness, the outline must stay inside the panel
    /// it is drawn in. Retracted is the state that must not paint over window
    /// chrome.
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

    /// The progress trace is the silhouette offset inward by its own half-width
    /// everywhere, including the curves. Insetting the frame and clamping the
    /// shell's corner radius against it translates the corner by (inset, -inset)
    /// instead of offsetting it: exact at the tangent points but
    /// `inset * sqrt(2)` along the normal at 45 degrees, so the stroke would
    /// leave the silhouette at both bottom corners while a check on the straight
    /// run still passed.
    static func theTraceOffsetsTheSilhouetteRatherThanTranslatingIt() {
        // 1.25 is the resting stroke's half-width, 1.7 the hover swell's and 2
        // the grab's; the inset animates, so the property must hold at all three.
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
                    // Two-sided: too far in breaks the outline into two lines
                    // round the corner, too far out hangs the stroke past the
                    // shell. A proper offset measures 1.000 to 1.061 of the inset
                    // (a quadratic quarter-turn is not quite a circular arc) and
                    // a translated corner reaches 1.190, so 1.12 sits between.
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

    /// The pill silhouette and the trace must draw the same bottom corner.
    /// `NotchShape`'s pill branch floors its radius at 10 so a menu-bar-height
    /// capsule reads as a capsule, while `NotchBottomEdge` and other consumers of
    /// `bottomCornerRadius` do not know the floor. With the default cutout radius
    /// of 9 the silhouette would round at 10 and the trace at 9 minus the inset,
    /// leaving tinted ink on the menu bar beside the pill.
    static func thePillTraceDrawsTheSilhouettesOwnCorner() {
        // The rule itself: floor 10, passthrough above it, half-height clamp on
        // shells too short to carry it.
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
                // The edge path opens with its move to (minX, maxY - br), so the
                // drawn radius falls out of the first element.
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

        // The walk above shows the shapes agree when handed one value; this
        // shows the shipped wiring hands them one value. NotchController needs a
        // live screen and cannot be compiled here, so it is read as source.
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

    /// The bottom corner radius a shape actually draws, recovered from its path:
    /// the bottom run's leftmost endpoint is (minX + radius, maxY). Uses element
    /// endpoints, not sampled trim points, so it is exact even at the capsule
    /// limit where the straight side vanishes.
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

    /// The file with line comments removed, so a lint can be neither tripped nor
    /// satisfied by prose.
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

    /// Distance to the polyline's segments, not its vertices; measured to the
    /// vertices the answer carries the sample spacing as a bias.
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
