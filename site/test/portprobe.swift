import Foundation
import SwiftUI

/// Dumps the real Swift sim and geometry so the JavaScript port on the website
/// can be checked against them rather than against a design document.
///
/// This exists because the site's build spec carried constants that had drifted
/// from the source — a lobe-spread law that predated the current one, and two
/// figures the code had already moved past. A port verified against prose
/// inherits the prose's mistakes; a port verified against a dump from the
/// shipping physics does not.
///
/// The sim's state evolution is deterministic even though `seed` randomises
/// `rim` and `fan`: `updateSites` reads only `band`, which is a pure function
/// of the site index. `rim` and `fan` are read by the RENDERER, so the geometry
/// mode below supplies them explicitly instead of seeding them.
@main
enum PortProbe {

    @MainActor
    static func main() {
        let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "sim"
        switch mode {
        case "sim": replay()
        case "sim-held": replayHeld()
        case "surge-forward": surge(direction: 1)
        case "surge-back": surge(direction: -1)
        case "open": openClose()
        case "pointer": pointer()
        case "geom": geometry()
        default:
            FileHandle.standardError.write("unknown mode \(mode)\n".data(using: .utf8)!)
            exit(2)
        }
    }

    // MARK: - Output

    private static func f(_ value: Double) -> String { String(format: "%.12f", value) }
    private static func f(_ value: CGFloat) -> String { String(format: "%.12f", Double(value)) }

    @MainActor
    private static func frame(_ sim: FerrofluidSim, _ index: Int) {
        var parts = [String(index), f(sim.swell), f(sim.raised), f(sim.impact),
                     f(sim.brightness), f(sim.flowPhase), f(sim.inkOpen),
                     f(sim.pointerPull), f(sim.pointerRim),
                     sim.isSettled ? "1" : "0", sim.hasSound ? "1" : "0"]
        for site in sim.sites { parts.append(f(site.field)) }
        for site in sim.sites { parts.append(f(site.height)) }
        for site in sim.sites { parts.append(site.isUp ? "1" : "0") }
        print(parts.joined(separator: " "))
    }

    // MARK: - Levels

    private static func realLevels() -> [[Float]] {
        let path = "Resources/real-levels.txt"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            FileHandle.standardError.write("missing \(path)\n".data(using: .utf8)!)
            exit(2)
        }
        return text.split(separator: "\n").compactMap { line in
            let values = line.split(separator: " ").compactMap { Float($0) }
            return values.count == AudioTap.bandCount ? values : nil
        }
    }

    // MARK: - Modes

    /// 240 frames of real captured audio at a fixed 60fps step.
    @MainActor
    private static func replay() {
        let sim = FerrofluidSim()
        let frames = realLevels()
        for (index, levels) in frames.enumerated() {
            sim.advance(levels: levels, dt: 1.0 / 60)
            frame(sim, index)
        }
    }

    /// The same capture, stepped the way the APP steps it.
    ///
    /// `replay()` above advances once per captured frame, which is a cadence
    /// nothing ships: it proves the port's arithmetic and says nothing about the
    /// sequence the fluid actually integrates. On the machine the render clock
    /// is 60Hz and `AudioLevels` republishes at 30 — `Task.sleep(.milliseconds(33))`
    /// — so every captured frame is stepped TWICE and the second step sees a
    /// delta of exactly zero. `tools/fluidcheck.swift` has driven it that way
    /// since the capture was added; the website did not, and the difference is
    /// the whole reason this mode exists.
    ///
    /// A zero-delta step is not a step the varying sequence ever takes. Both of
    /// the sim's inputs are measured against a remembered past, `deviation`
    /// divides by an adapting `spread`, and `isSettled` can early-return — so
    /// "the port agrees on 240 changing frames" does not imply it agrees on a
    /// held one. This mode is what makes that a checked claim rather than an
    /// assumed one.
    ///
    /// One dump line per CAPTURED frame, after both steps: the site samples
    /// where the eye does, at the frame, not between its halves.
    @MainActor
    private static func replayHeld() {
        let sim = FerrofluidSim()
        let frames = realLevels()
        for (index, levels) in frames.enumerated() {
            sim.advance(levels: levels, dt: 1.0 / 60)
            sim.advance(levels: levels, dt: 1.0 / 60)
            frame(sim, index)
        }
    }

    /// A track change into stillness, then 90 frames of silence to watch it
    /// drain. Forward and back must not produce the same shape.
    @MainActor
    private static func surge(direction: Double) {
        let sim = FerrofluidSim()
        let silence = [Float](repeating: 0, count: AudioTap.bandCount)
        // One step so `kick` is sized — a surge before the first tick takes the
        // pendingSurge path, which is covered separately by fluidcheck.
        sim.advance(levels: silence, dt: 1.0 / 60)
        sim.surge(1, direction: direction)
        for index in 0..<90 {
            sim.advance(levels: silence, dt: 1.0 / 60)
            frame(sim, index)
        }
    }

    /// The ink following the shell: slow to fill, quick to drain, and no energy
    /// injected by the open itself.
    @MainActor
    private static func openClose() {
        let sim = FerrofluidSim()
        let silence = [Float](repeating: 0, count: AudioTap.bandCount)
        sim.setOpen(true)
        for index in 0..<60 {
            sim.advance(levels: silence, dt: 1.0 / 60)
            frame(sim, index)
        }
        sim.setOpen(false)
        for index in 60..<120 {
            sim.advance(levels: silence, dt: 1.0 / 60)
            frame(sim, index)
        }
    }

    /// The pointer easing in at 7.0 and out at 3.4, with the swell lagging the
    /// cursor at 5.0.
    @MainActor
    private static func pointer() {
        let sim = FerrofluidSim()
        let silence = [Float](repeating: 0, count: AudioTap.bandCount)
        sim.setPointer(rim: 0.15, strength: 1)
        for index in 0..<60 {
            sim.advance(levels: silence, dt: 1.0 / 60)
            frame(sim, index)
        }
        sim.setPointer(rim: 0.85, strength: 1.4)
        for index in 60..<120 {
            sim.advance(levels: silence, dt: 1.0 / 60)
            frame(sim, index)
        }
        sim.setPointer(rim: nil)
        for index in 120..<180 {
            sim.advance(levels: silence, dt: 1.0 / 60)
            frame(sim, index)
        }
    }

    /// The outline itself, from sites supplied explicitly so `rim` and `fan` are
    /// not random. Printed at four values of openness including retracted.
    @MainActor
    private static func geometry() {
        // Deliberately uneven: two tall neighbours to exercise the Mexican-hat
        // neck, one lobe on each vertical run, and a pair close enough that the
        // jitter's local scaling matters.
        let heights: [Double] = [0.94, 0.10, 0.00, 0.61, 0.00, 0.00, 0.33, 0.88,
                                 0.72, 0.00, 0.05, 0.00, 0.41, 0.00, 0.00, 0.19, 0.66]
        let fans: [Double] = [0.31, -0.22, 0.08, -0.35, 0.17, 0.02, -0.11, 0.28,
                              -0.30, 0.14, 0.36, -0.05, 0.21, -0.18, 0.09, 0.33, -0.27]
        var sites: [FerrofluidSim.Site] = []
        for index in 0..<FerrofluidSim.siteCount {
            let position = (Double(index) + 0.5) / Double(FerrofluidSim.siteCount)
            sites.append(FerrofluidSim.Site(
                rim: position,
                band: min(AudioTap.bandCount - 1,
                          Int(position * Double(AudioTap.bandCount))),
                fan: fans[index],
                height: heights[index],
                field: 0,
                isUp: heights[index] > 0))
        }

        let notch = CGSize(width: 185, height: 32)
        let panel = CGSize(width: 640, height: 190)
        let cases: [(CGFloat, CGFloat, CGFloat, CGFloat, Bool)] = [
            // openness, swell, raised, pointerPull, reduceMotion
            (0.0,  0.42, 0.30, 0.0, false),
            (0.35, 0.42, 0.30, 0.0, false),
            (1.0,  0.42, 0.30, 0.0, false),
            (1.0,  0.00, 0.00, 0.9, false),
            (1.0,  0.42, 0.30, 0.0, true),
        ]

        for (caseIndex, c) in cases.enumerated() {
            let (openness, swell, raised, pointerPull, reduce) = c
            // `displacement(reduce:)` picks `Motion.travel`, which is itself
            // gated on `Motion.reduceMotion` — so passing `reduce: true` while
            // that global is false selects a travel of 1 and reduces nothing.
            // The two always move together in the app, where NotchCoordinator
            // sets both; a probe that set only one would have dumped a
            // full-travel outline under the label "reduced".
            Motion.reduceMotion = reduce
            defer { Motion.reduceMotion = false }
            let geometry = Geometry(notch: notch, panel: panel, openness: openness)
            let lobes = geometry.lobes(of: sites)

            // The scalars the whole outline is built from, so a drifted
            // constant shows up here and not only in the finished shape.
            // `arcRun` and `bottomRun` are private, and a probe is not a reason
            // to widen an app type's access. They are re-derived here instead —
            // safely, because `total` is dumped straight off the geometry and
            // `total = sideRun * 2 + arcRun * 2 + bottomRun`, so a wrong
            // derivation cannot agree with it.
            let arcRun = CGFloat.pi * geometry.cornerRadius / 2
            let bottomRun = max(0, geometry.core.width - 2 * geometry.cornerRadius)
            print("case \(caseIndex) openness \(f(openness)) total \(f(geometry.total)) "
                  + "top \(f(geometry.top)) sideRun \(f(geometry.sideRun)) "
                  + "bottomRun \(f(bottomRun)) arcRun \(f(arcRun)) "
                  + "visibleTopU \(f(geometry.visibleTopU)) lobes \(lobes.count)")
            for lobe in lobes {
                print("lobe \(f(lobe.seat)) \(f(lobe.height)) \(f(lobe.spread)) \(f(lobe.reach))")
            }

            let surface = { (position: Double, lateral: CGFloat, headroom: CGFloat,
                             detail: CGFloat) -> CGFloat in
                geometry.displacement(reduce: reduce,
                                      at: position,
                                      lobes: lobes,
                                      swell: swell,
                                      raised: raised,
                                      lateral: lateral,
                                      detail: detail,
                                      headroom: headroom,
                                      pointerRim: 0.62,
                                      pointerPull: pointerPull)
            }

            // Every relaxed point, recovered from the finished path: `move`
            // gives the first, and each `curve` element's endpoint gives the
            // next. The two trailing lines close the body above the screen.
            var points: [CGPoint] = []
            geometry.poolPath(displacement: surface).forEach { element in
                switch element {
                case let .move(to): points.append(to)
                case let .curve(to, _, _): points.append(to)
                default: break
                }
            }
            for point in points { print("point \(f(point.x)) \(f(point.y))") }
        }
    }
}
