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
/// `seed` randomises `rim` and `fan`. `rim` is read only by the RENDERER, but a
/// lobe's charge scales with its `fan`, so the sim modes below lead with the
/// fans the run drew and the port is handed the same ones. The geometry mode
/// supplies `rim` and `fan` explicitly instead of seeding them.
@main
enum PortProbe {

    @MainActor
    static func main() {
        let mode = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "sim"
        switch mode {
        case "sim": replay()
        case "sim-held": replayHeld()
        case "sim-drop": drop()
        case "sim-resume": resume()
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
        // A lobe's charge scales with its `fan`, which `seed` draws from the system RNG, so
        // the dump leads with the fans this run drew and the port is handed the same ones.
        // They are drawn once, on the first step, and never change, so printing them with
        // frame 0 prints the ones every frame used.
        if index == 0 {
            print((["fan"] + sim.sites.map { f($0.fan) }).joined(separator: " "))
        }
        var parts = [String(index), f(sim.swell), f(sim.raised), f(sim.impact),
                     f(sim.brightness), f(sim.flowPhase), f(sim.inkOpen),
                     f(sim.pointerPull), f(sim.pointerRim),
                     sim.isSettled ? "1" : "0", sim.hasSound ? "1" : "0"]
        for site in sim.sites { parts.append(f(site.field)) }
        for site in sim.sites { parts.append(f(site.height)) }
        for site in sim.sites { parts.append(site.isUp ? "1" : "0") }
        parts.append(f(sim.light))
        print(parts.joined(separator: " "))
    }

    // MARK: - Levels

    /// The capture as Resources/real-levels.txt holds it, at the 30Hz it was taken at.
    private static func capture() -> [[Double]] {
        let path = "Resources/real-levels.txt"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            FileHandle.standardError.write("missing \(path)\n".data(using: .utf8)!)
            exit(2)
        }
        return text.split(separator: "\n").compactMap { line in
            let values = line.split(separator: " ").compactMap { Double($0) }
            return values.count == AudioTap.bandCount ? values : nil
        }
    }

    private static func realLevels() -> [[Float]] {
        capture().map { $0.map { Float($0) } }
    }

    /// The capture at the app's 60Hz: the midpoint of each consecutive pair put
    /// between the two, as `tools/fluidcheck.swift` replays it and as
    /// site/test/gen-levels.mjs writes it for the page. The midpoint is taken in
    /// Double from the decimals as written and narrowed once, because the page's
    /// data carries it as a decimal and widens it from there; a midpoint of two
    /// narrowed Floats can sit one ulp from that.
    private static func resampled() -> [[Float]] {
        var out: [[Float]] = []
        let frames = capture()
        for (index, frame) in frames.enumerated() {
            if index > 0 {
                out.append(zip(frames[index - 1], frame).map { Float(($0 + $1) / 2) })
            }
            out.append(frame.map { Float($0) })
        }
        return out
    }

    // MARK: - Modes

    /// 240 frames of real captured audio, one step each at a fixed 1/60: the
    /// port's arithmetic on a sequence nothing ships.
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
    /// `replay()` above advances once per 30Hz captured frame, which is a
    /// cadence nothing ships: it proves the port's arithmetic and says nothing
    /// about the sequence the fluid actually integrates. On the machine the
    /// render clock is 60Hz and `AudioLevels` republishes every 16ms, so every
    /// step has news: the capture is played at 60Hz with a midpoint between each
    /// pair of its frames, one step apiece. It was stepped twice per frame, with
    /// the second step seeing a delta of exactly zero, while the pump slept 33ms.
    ///
    /// That zero-delta step is still a step the app can take, when a read lands
    /// on the bands it already had, so the dump ends with the last frame held
    /// for a second. Both of the sim's inputs are measured against a remembered
    /// past, `deviation` divides by an adapting `spread`, and `isSettled` can
    /// early-return, so "the port agrees on frames that all change" does not
    /// imply it agrees on a held one. This mode is what makes that a checked
    /// claim rather than an assumed one.
    ///
    /// One dump line per step.
    @MainActor
    private static func replayHeld() {
        let sim = FerrofluidSim()
        var frames = resampled()
        frames += [[Float]](repeating: frames[frames.count - 1], count: 60)
        for (index, levels) in frames.enumerated() {
            sim.advance(levels: levels, dt: 1.0 / 60)
            frame(sim, index)
        }
    }

    /// A beat that drops out and slams back, as in fluidcheck's
    /// `kicksStillLandAfterADrop`: a bass wall pumping on each beat, two seconds
    /// gone, then back. The captured audio has no such drop, so on it the two
    /// onset yardsticks never disagree and a port missing one still matches.
    @MainActor
    private static func drop() {
        let sim = FerrofluidSim()
        var index = 0
        for (seconds, bass) in [(6.0, Float(0.9)), (2.0, 0.02), (4.0, 0.9)] {
            for _ in 0..<Int(seconds * 60) {
                var levels = [Float](repeating: 0.35, count: 12)
                let pumped: Float = index % 22 < 3 ? bass - 0.15 : bass
                for band in 0..<3 { levels[band] = max(0, pumped) }
                sim.advance(levels: levels, dt: 1.0 / 60)
                frame(sim, index)
                index += 1
            }
        }
    }

    /// The music, four seconds of silence, then the same music again waking over four steps, as in fluidcheck's
    /// `resumingIsNotAnEvent`. Coming back from a pause is the one path through `reenter`
    /// and the ramp that lets onsets in over 150 ms, and the capture never goes quiet
    /// long enough to take it, so no other golden reaches either.
    @MainActor
    private static func resume() {
        let sim = FerrofluidSim()
        let music = Array(resampled().prefix(120))
        let silence = [Float](repeating: 0, count: AudioTap.bandCount)
        var index = 0
        // The analyser wakes over the first callbacks back rather than arriving at full
        // level, which is the rise the ramp exists to keep from reading as a drum.
        let back = music.enumerated().map { pair in
            pair.element.map { $0 * Float(min(4, pair.offset + 1)) / 4 }
        }
        for levels in music + [[Float]](repeating: silence, count: 240) + back {
            sim.advance(levels: levels, dt: 1.0 / 60)
            frame(sim, index)
            index += 1
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
