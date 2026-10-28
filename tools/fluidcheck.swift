import Foundation

/// Headless checks on the ferrofluid's physics. Each encodes a behaviour that
/// can only be diagnosed by measuring, so it cannot regress quietly.
@main
enum FluidCheck {
    @MainActor
    static func main() {
        heldLoudnessDoesNotPinTheCrown()
        theCrownIsNotAComb()
        silenceIsGenuinelyStill()
        bassOutlastsTreble()
        aTrackChangeMovesTheInk()
        aSurgeIntoStillnessStillMoves()
        aSurgeBeforeTheFirstTickIsNotLost()
        stoppingLeavesItSettled()
        releasingKeepsThePicture()
        theInkAnswersThePointer()
        aScrubPullsHarderThanAHover()
        theSwellTrailsTheCursor()
        aFinishedScrubReleasesTheInk()
        theGlowNeverSwitchesOnOrOff()
        realMusicDoesNotSaturateIt()
        resumingIsNotAnEvent()
        noTwoBandsCarryTheSameBin()
        aSkipHasADirection()
        theInkWashesInBehindTheShell()
        theGateNeverOutlivesTheClock()
        theIOProcNeverSharesTheLifecycleQueue()
        print("fluidcheck: all checks passed")
    }

    /// Drive must measure change, not volume. Music sits at 0.5-0.8 for long
    /// stretches, and keying off absolute level would pin 16 of 17 peaks up as a
    /// static jagged wall.
    ///
    /// Held at 0.8 so the first assertion can fail. A site's drive is
    /// `dev * 0.5 + kick * 0.8` and a held level decays `kick` to nothing, so a
    /// level-reading drive is half the level: 0.35 at 0.7, just under the 0.36
    /// critical field, which leaves no site rising and the count vacuous. At 0.8
    /// the drive is 0.40. The margin is only 0.04, so a `criticalField` raised
    /// past 0.40 would make the count vacuous again; the margin is therefore
    /// asserted first and that change fails by name.
    @MainActor
    private static func heldLoudnessDoesNotPinTheCrown() {
        let sim = FerrofluidSim()
        let level: Float = 0.8
        // The check's premise, held rather than hoped. `0.5` restates the dev
        // weight in `updateSites` (`dev * 0.5 + kick * 0.8`); if that weight
        // moves, this fails red, the safe direction for a guard.
        let levelReadingDrive = Double(level) * 0.5
        let margin = levelReadingDrive - sim.criticalField
        require(margin >= 0.01,
                "held level \(level) gives a level-reading drive of "
                + "\(String(format: "%.3f", levelReadingDrive)), only "
                + "\(String(format: "%.3f", margin)) above the critical field "
                + "\(sim.criticalField) — below 0.01 the count below cannot fail")
        let loud = [Float](repeating: level, count: 12)
        for _ in 0..<(60 * 8) { sim.advance(levels: loud, dt: 1.0 / 60) }

        let standing = sim.sites.filter { $0.height > 0.05 }.count
        require(standing <= 4,
                "held loudness left \(standing) of \(sim.sites.count) peaks standing")
        require(sim.swell < 0.15, "held loudness kept the pool swollen (\(sim.swell))")
    }

    /// A crown whose peaks are all nearly the same height is the same-height
    /// spike comb the product contract rules out.
    @MainActor
    private static func theCrownIsNotAComb() {
        let sim = FerrofluidSim()
        // Quiet floor first, so the adaptive baseline settles.
        let floor: [Float] = (0..<12).map { 0.25 - Float($0) * 0.015 }
        for _ in 0..<(60 * 3) { sim.advance(levels: floor, dt: 1.0 / 60) }
        // Then a spectrum with a real shape to it.
        var shaped = floor
        shaped[0] = 0.95; shaped[1] = 0.80; shaped[5] = 0.42; shaped[9] = 0.30
        for _ in 0..<24 { sim.advance(levels: shaped, dt: 1.0 / 60) }

        let up = sim.sites.map(\.height).filter { $0 > 0.02 }
        require(up.count >= 2, "no crown formed to measure (\(up.count) peaks)")
        let ratio = (up.max() ?? 0) / max(0.0001, up.min() ?? 0)
        require(ratio > 3,
                "peak heights span only \(String(format: "%.1f", ratio)):1 — that is a comb")
    }

    /// When the music stops the ink must come home and stay there; no clock term
    /// may keep it moving. Measures how long it takes to settle, not only that
    /// it does.
    @MainActor
    private static func silenceIsGenuinelyStill() {
        let sim = FerrofluidSim()
        // Settle the adaptive baseline on a quiet floor first: the drive measures
        // departure from the recent norm, so a hit with no history is not an
        // event at all.
        let floor = [Float](repeating: 0.2, count: 12)
        for _ in 0..<(60 * 3) { sim.advance(levels: floor, dt: 1.0 / 60) }
        var hit = floor
        hit[0] = 1; hit[1] = 0.9
        for _ in 0..<30 { sim.advance(levels: hit, dt: 1.0 / 60) }
        require(sim.sites.contains { $0.height > 0.05 }, "test never raised a crown")

        // Settling time is the property with something to say. Asserting that
        // heights do not drift after settling cannot fail, because `advance`
        // returns early once the fluid is settled and silent; a drain that stops
        // draining, or a gate that never publishes, shows up here instead.
        let silence = [Float](repeating: 0, count: 12)
        var frames = 0
        while !sim.isSettled, frames < 60 * 10 {
            sim.advance(levels: silence, dt: 1.0 / 60)
            frames += 1
        }
        require(sim.isSettled, "the fluid did not settle in silence")
        require(frames < 60 * 4,
                "the fluid took \(Double(frames) / 60)s to settle — the renderer runs "
                + "for all of it")
        require(frames > 30,
                "the fluid settled in \(frames) frames, which is a cut rather than a decay")
    }

    /// Bass is heavy and treble is light: one drain rate for every band would
    /// make the whole crown breathe as a single object.
    @MainActor
    private static func bassOutlastsTreble() {
        let sim = FerrofluidSim()
        let floor = [Float](repeating: 0.2, count: 12)
        for _ in 0..<(60 * 3) { sim.advance(levels: floor, dt: 1.0 / 60) }
        var hit = floor
        hit[0] = 1; hit[11] = 1
        for _ in 0..<20 { sim.advance(levels: hit, dt: 1.0 / 60) }

        func height(band: Int) -> Double {
            sim.sites.filter { $0.band == band }.map(\.height).max() ?? 0
        }
        let bass0 = height(band: 0), treble0 = height(band: 11)
        require(bass0 > 0.05 && treble0 > 0.05,
                "both bands must rise first (bass \(bass0), treble \(treble0))")

        for _ in 0..<12 { sim.advance(levels: floor, dt: 1.0 / 60) }
        let bassKept = height(band: 0) / bass0
        let trebleKept = height(band: 11) / treble0
        require(bassKept > trebleKept + 0.05,
                "bass kept \(bassKept) and treble \(trebleKept) — bands drain alike")
    }

    /// A track change is an event, so it enters through the same door a drum hit
    /// does, and then ordinary physics takes over, including settling.
    @MainActor
    private static func aTrackChangeMovesTheInk() {
        let sim = FerrofluidSim()
        let floor = [Float](repeating: 0.2, count: 12)
        for _ in 0..<(60 * 3) { sim.advance(levels: floor, dt: 1.0 / 60) }
        require((sim.sites.map(\.height).max() ?? 1) < 0.05, "crown was not flat before the surge")

        sim.surge(0.95)
        for _ in 0..<14 { sim.advance(levels: floor, dt: 1.0 / 60) }
        require((sim.sites.map(\.height).max() ?? 0) > 0.2,
                "a track change did not move the ink")

        let silence = [Float](repeating: 0, count: 12)
        for _ in 0..<(60 * 5) { sim.advance(levels: silence, dt: 1.0 / 60) }
        require(sim.isSettled, "the surge left the fluid unsettled")
    }

    /// A track change during a quiet passage arrives when the fluid is fully
    /// settled. `advance` returns early while `isSettled` is true, so the surge
    /// must republish the gate itself or the next step skips it.
    @MainActor
    private static func aSurgeIntoStillnessStillMoves() {
        let sim = FerrofluidSim()
        let silence = [Float](repeating: 0, count: 12)
        for _ in 0..<(60 * 4) { sim.advance(levels: silence, dt: 1.0 / 60) }
        require(sim.isSettled, "fluid did not settle before the surge")

        sim.surge(0.95)
        require(!sim.isSettled, "surge left isSettled true, so advance will skip it")
        for _ in 0..<12 { sim.advance(levels: silence, dt: 1.0 / 60) }
        require(sim.impact > 0.1, "a surge into stillness produced no impact")
    }

    /// The first song of a session is when the reaction matters most, and it
    /// arrives before `kick` has been sized.
    @MainActor
    private static func aSurgeBeforeTheFirstTickIsNotLost() {
        let sim = FerrofluidSim()
        // Nothing has stepped yet, so there is no per-band array to inject into.
        sim.surge(0.95)

        let floor = [Float](repeating: 0.2, count: 12)
        for _ in 0..<20 { sim.advance(levels: floor, dt: 1.0 / 60) }
        require(sim.impact > 0.1, "a surge before the first tick was lost")
    }

    /// stop() must leave the gates consistent with the state it cleared, or the
    /// renderer runs at 60 fps for the rest of the session.
    @MainActor
    private static func stoppingLeavesItSettled() {
        let sim = FerrofluidSim()
        let floor = [Float](repeating: 0.2, count: 12)
        for _ in 0..<(60 * 2) { sim.advance(levels: floor, dt: 1.0 / 60) }
        sim.surge(0.95)
        for _ in 0..<10 { sim.advance(levels: floor, dt: 1.0 / 60) }
        sim.stop()
        require(sim.isSettled, "stop() left isSettled false — the renderer never pauses")
        require(sim.sites.isEmpty, "stop() left sites behind")
    }

    /// Letting go of the audio on screen must not move the ink. Capture shuts off
    /// shortly after a pause; the ink must come to rest from where it is, on its
    /// own clock, and then stop, rather than zeroing the swell, glow and pointer
    /// pull in one frame.
    @MainActor
    private static func releasingKeepsThePicture() {
        let sim = FerrofluidSim()
        let floor = [Float](repeating: 0.2, count: 12)
        for _ in 0..<(60 * 2) { sim.advance(levels: floor, dt: 1.0 / 60) }
        sim.surge(0.95)
        for _ in 0..<10 { sim.advance(levels: floor, dt: 1.0 / 60) }
        let swell = sim.swell, impact = sim.impact, glow = sim.brightness
        require(swell > 0.01 && glow > 0.01, "the harness left nothing that could jump")
        sim.release()
        require(sim.swell == swell && sim.impact == impact && sim.brightness == glow,
                "releasing the audio moved the ink in one frame")
        require(sim.isDriven, "release left no clock to bring the ink to rest")
        let deadline = Date().addingTimeInterval(10)
        while sim.isDriven, Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.05))
        }
        require(!sim.isDriven && sim.isSettled,
                "the released ink never came to rest — the renderer runs on")
    }

    /// Anything that clears the settled gate must leave something driving it.
    /// `isSettled` pauses the renderer; clearing it with no clock leaves
    /// TimelineView rebuilding a 144-sample outline at 60 Hz over a picture that
    /// cannot change, and nothing recomputes the gate.
    ///
    /// Reachable since the clock learned to retire on its own: an idle pour sizes
    /// `kick` and then the clock retires, so the next surge takes the main path
    /// and clears the gate with nothing behind it.
    @MainActor
    private static func theGateNeverOutlivesTheClock() {
        let sim = FerrofluidSim()
        let floor = [Float](repeating: 0.2, count: 12)
        // Driven by hand, as this file drives everything, so `kick` is sized and
        // there is deliberately no clock: the state after an idle pour finishes.
        for _ in 0..<30 { sim.advance(levels: floor, dt: 1.0 / 60) }
        require(!sim.isDriven, "the harness started a clock; this check proves nothing")

        sim.surge(0.9)
        require(!sim.isSettled, "a surge did not clear the gate")
        require(sim.isDriven,
                "a surge cleared the gate and left nothing to recompute it")

        // The held path too: a surge before `kick` exists must still arrive.
        let early = FerrofluidSim()
        early.surge(0.9)
        require(early.isDriven, "a held surge left nothing to ever consume it")

        // And the pointer, which clears the gate the same way.
        let scrub = FerrofluidSim()
        for _ in 0..<30 { scrub.advance(levels: floor, dt: 1.0 / 60) }
        scrub.setPointer(rim: 0.5)
        require(scrub.isDriven, "the pointer cleared the gate with no clock")
    }

    /// The ink arrives behind the shell and brings no beat with it. The follower
    /// is asymmetric: slow to fill, quick to drain. Opening must move the shape
    /// and nothing else; injecting into the kick, swell or glow would manufacture
    /// a drum hit with no drum, against PRODUCT.md's second design principle
    /// (audio causes events, a clock only advances the simulation).
    @MainActor
    private static func theInkWashesInBehindTheShell() {
        let sim = FerrofluidSim()
        let silence = [Float](repeating: 0, count: 12)
        for _ in 0..<(60 * 3) { sim.advance(levels: silence, dt: 1.0 / 60) }
        require(sim.isSettled, "did not settle before the panel moved")

        sim.setOpen(true)
        require(!sim.isSettled, "opening the panel did not wake the renderer")

        var peakSwell = 0.0, peakImpact = 0.0, peakHeight = 0.0
        for _ in 0..<11 {
            sim.advance(levels: silence, dt: 1.0 / 60)
            peakSwell = max(peakSwell, sim.swell)
            peakImpact = max(peakImpact, sim.impact)
            peakHeight = max(peakHeight, sim.sites.map(\.height).max() ?? 0)
        }
        // The shell is at 0.896 here; this fails if the ink is re-coupled to it.
        require(sim.inkOpen < 0.5,
                "the ink kept pace with the shell instead of trailing it (\(sim.inkOpen))")

        for _ in 0..<40 {
            sim.advance(levels: silence, dt: 1.0 / 60)
            peakSwell = max(peakSwell, sim.swell)
            peakImpact = max(peakImpact, sim.impact)
            peakHeight = max(peakHeight, sim.sites.map(\.height).max() ?? 0)
        }
        require(sim.inkOpen > 0.9, "the ink never finished arriving (\(sim.inkOpen))")
        require(peakSwell < 0.004 && peakImpact < 0.004 && peakHeight < 0.004,
                "opening in silence made the ink pulse — swell \(peakSwell), "
                + "impact \(peakImpact), crown \(peakHeight)")

        for _ in 0..<(60 * 3) { sim.advance(levels: silence, dt: 1.0 / 60) }
        require(sim.isSettled, "the fluid never settled after the open")

        // Closing is quick, so the ink beats the shell home rather than being
        // caught by the clip.
        sim.setOpen(false)
        for _ in 0..<13 { sim.advance(levels: silence, dt: 1.0 / 60) }
        require(sim.inkOpen == 0, "the ink did not drain with the shell (\(sim.inkOpen))")

        // An idle panel moves too. With no track the pump is down and `sites` is
        // empty; opening must not snap in that case.
        let idle = FerrofluidSim()
        idle.setOpen(true)
        require(!idle.isSettled, "opening an idle panel did not wake the fluid")
        for _ in 0..<30 { idle.advance(levels: silence, dt: 1.0 / 60) }
        require(idle.inkOpen > 0.5, "the idle panel's ink never moved (\(idle.inkOpen))")
        for _ in 0..<(60 * 3) { idle.advance(levels: silence, dt: 1.0 / 60) }
        require(idle.isSettled, "the idle open never settled — the clock would never stop")

        // Reduce Motion shortens the journey rather than lengthening it.
        func arrival(reduced: Bool) -> Int {
            let s = FerrofluidSim()
            s.reduceMotion = reduced
            for _ in 0..<60 { s.advance(levels: silence, dt: 1.0 / 60) }
            s.setOpen(true)
            for f in 1...120 {
                s.advance(levels: silence, dt: 1.0 / 60)
                if s.inkOpen == 1 { return f }
            }
            return 999
        }
        let plain = arrival(reduced: false), reduced = arrival(reduced: true)
        require(reduced < plain,
                "Reduce Motion did not shorten the open (\(reduced) vs \(plain) frames)")
    }

    /// Forward and back must not produce the same heave. A scalar `surge` would
    /// announce that a track changed but never which way. Forward leans the high
    /// bands, which under the band -> rim -> seatU chain is the right, the same
    /// direction `next()` runs the progress trace.
    @MainActor
    private static func aSkipHasADirection() {
        func lean(_ direction: Double, frames: Int = 10)
            -> (low: Double, high: Double, centroid: Double, crestLow: Double, crestHigh: Double) {
            let sim = FerrofluidSim()
            let floor = [Float](repeating: 0.2, count: 12)
            for _ in 0..<180 { sim.advance(levels: floor, dt: 1.0 / 60) }
            sim.surge(0.9, direction: direction)
            var crestLow = 0.0, crestHigh = 0.0
            for _ in 0..<frames {
                sim.advance(levels: floor, dt: 1.0 / 60)
                crestLow = max(crestLow, sim.sites.filter { $0.rim < 0.4 }.map(\.height).max() ?? 0)
                crestHigh = max(crestHigh, sim.sites.filter { $0.rim > 0.6 }.map(\.height).max() ?? 0)
            }
            let low = sim.sites.filter { $0.rim < 0.4 }.map(\.height).max() ?? 0
            let high = sim.sites.filter { $0.rim > 0.6 }.map(\.height).max() ?? 0
            let mass = sim.sites.reduce(0.0) { $0 + $1.height }
            let centroid = mass > 0
                ? sim.sites.reduce(0.0) { $0 + $1.rim * $1.height } / mass
                : 0.5
            return (low, high, centroid, crestLow, crestHigh)
        }

        let f = lean(1), b = lean(-1)
        require(f.high > f.low + 0.05,
                "a skip forward did not lean right (low \(f.low), high \(f.high))")
        require(b.low > b.high + 0.05,
                "a skip back did not lean left (low \(b.low), high \(b.high))")
        require(f.centroid > 0.55 && b.centroid < 0.45,
                "the two skips are not mirrored (forward \(f.centroid), back \(b.centroid))")
        // Crests, not sums or one frame: the spikes are springs that drain faster in
        // the treble, so totals and any single frame legitimately diverge while the
        // highest point each side reaches stays matched.
        let peaks = (f.crestHigh, b.crestLow)
        require(abs(peaks.0 - peaks.1) / max(peaks.0, peaks.1) < 0.15,
                "one direction hits harder than the other (\(peaks.0) vs \(peaks.1))")

        // Directed before the first tick, so it goes through pendingSurge.
        let early = FerrofluidSim()
        let floor = [Float](repeating: 0.2, count: 12)
        early.surge(0.9, direction: 1)
        for _ in 0..<10 { early.advance(levels: floor, dt: 1.0 / 60) }
        let lo = early.sites.filter { $0.rim < 0.4 }.map(\.height).max() ?? 0
        let hi = early.sites.filter { $0.rim > 0.6 }.map(\.height).max() ?? 0
        require(hi > lo + 0.05,
                "a held surge lost its direction through pendingSurge (\(lo) vs \(hi))")
    }

    /// Every band is its own slice of the spectrum. With log spacing, bands 0 and
    /// 1 shared a bin, so two sites on the left run rose in lockstep: a
    /// same-height spike comb produced by the analyser, which PRODUCT.md rules
    /// out. The other checks feed the sim constructed levels and never ask where
    /// a real level comes from.
    ///
    /// Asserted as a partition (strictly increasing, gapless, non-empty, in
    /// range) rather than against a table of edges, which would copy the
    /// implementation and pass for any spacing.
    static func noTwoBandsCarryTheSameBin() {
        let fftSize = 1024, half = fftSize / 2
        let edges = AudioTap.bandPartition(fftSize: fftSize, bandCount: AudioTap.bandCount)
        require(edges.count == AudioTap.bandCount,
                "\(edges.count) ranges for \(AudioTap.bandCount) bands")
        for (b, e) in edges.enumerated() {
            require(e.0 >= 1 && e.1 <= half,
                    "band \(b) is \(e), outside bins 1..<\(half)")
            require(e.1 > e.0, "band \(b) is empty (\(e)) — it would always read zero")
            if b > 0 {
                // Equality here is the bug: (1,2) twice summed bin 1 twice.
                require(e.0 == edges[b - 1].1,
                        "band \(b) starts at \(e.0) where band \(b - 1) ended at "
                        + "\(edges[b - 1].1) — bins are \(e.0 < edges[b - 1].1 ? "shared" : "skipped")")
                require(e != edges[b - 1],
                        "bands \(b - 1) and \(b) are the same range \(e) — they can only "
                        + "ever report the same level, and the sites they drive move as one")
            }
        }
        // The whole usable spectrum is covered, or bands are being thrown away.
        require(edges.first!.0 == 1 && (edges.last!.1 == half - 1 || edges.last!.1 == half),
                "the partition covers \(edges.first!.0)..<\(edges.last!.1) of 1..<\(half)")
    }

    /// The fluid stays in its working range on real music, not just on synthetic
    /// spectra. The other checks use constructed levels and miss sustained music,
    /// where bands neither hold still nor spike cleanly.
    /// `Resources/real-levels.txt` is 240 frames captured from the app's own tap.
    ///
    /// The failure guarded is saturation: if the whole-body swell pins near 1 the
    /// outline lifts uniformly, tanh compresses it to the ceiling and the
    /// silhouette becomes a smooth wall with no crowns, with no crash or hang to
    /// reveal it. On this capture the swell has mean 0.35, sd 0.23, never above
    /// 0.95, and the site budget is reached only 2% of the time.
    @MainActor
    private static func realMusicDoesNotSaturateIt() {
        let path = "Resources/real-levels.txt"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            require(false, "cannot read \(path) — run check.sh from the repo root")
            return
        }
        let frames: [[Float]] = text.split(separator: "\n").map {
            $0.split(separator: " ").compactMap { Float($0) }
        }.filter { $0.count == 12 }
        require(frames.count > 200, "the capture has only \(frames.count) frames")

        let sim = FerrofluidSim()
        var swells: [Double] = [], ups: [Int] = []
        var last = frames[0]
        for (i, f) in frames.enumerated() {
            // The capture is 30 Hz and the app reads and steps at 60, so the step
            // between two captured frames sees their midpoint, as the meter would.
            sim.advance(levels: zip(last, f).map { ($0 + $1) / 2 }, dt: 1.0 / 60)
            sim.advance(levels: f, dt: 1.0 / 60)
            last = f
            guard i > frames.count / 4 else { continue }      // let the baseline settle
            swells.append(sim.swell)
            ups.append(sim.sites.filter(\.isUp).count)
        }
        let mean = swells.reduce(0, +) / Double(swells.count)
        let pinned = swells.filter { $0 > 0.95 }.count * 100 / swells.count
        require(pinned < 10,
                "the swell is pinned for \(pinned)% of real music — a saturated body "
                + "lifts the whole outline and the crowns flatten into a wall")
        require(mean > 0.10 && mean < 0.60,
                "the swell averages \(mean) on real music, outside its working range")
        // The surface must also be doing something: a fluid that never raises a
        // site on real music is as wrong as one that raises all of them.
        let atCap = ups.filter { $0 >= 9 }.count * 100 / ups.count
        require(atCap < 25, "the site budget is exhausted \(atCap)% of the time")
        require(ups.contains { $0 >= 3 }, "real music never raised three crowns at once")
    }

    /// Coming back from a pause must not hit the fluid harder than the music
    /// does. Both inputs measure change against a remembered past, and silence
    /// poisons that memory: `rise` is measured from levels decayed to zero, and
    /// `delta` is divided by a `spread` that stopped adapting once the settled
    /// early return stopped calling `deviation`. A resume then read as a
    /// full-scale event (swell 0.973, peak 0.997 against a loudest music frame of
    /// 0.879), the saturation wall reached by the analyser rather than the music.
    ///
    /// Both assertions are relative to the same capture rather than to a tuned
    /// constant: a resume may move the fluid exactly as much as the music does.
    @MainActor
    private static func resumingIsNotAnEvent() {
        let path = "Resources/real-levels.txt"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            require(false, "cannot read \(path) — run check.sh from the repo root")
            return
        }
        let music: [[Float]] = text.split(separator: "\n").map {
            $0.split(separator: " ").compactMap { Float($0) }
        }.filter { $0.count == 12 }
        require(music.count > 200, "the capture has only \(music.count) frames")
        let silence = [Float](repeating: 0, count: 12)

        // Site height rises with a 1/24 s time constant, so twelve frames at 60 Hz
        // is several of them: past that the surface answers the music, not the
        // resume.
        let window = 12
        let sim = FerrofluidSim()
        var musicSwell = 0.0, musicMove = 0.0
        var resumeSwell = 0.0, resumeMove = 0.0
        var previousMean = 0.0
        var frame = 0
        var lastLevels: [Float] = []

        func step(_ levels: [Float], record: (Double, Double) -> Void) {
            // A 30 Hz capture read at 60 Hz: the midpoint, then the frame, as above.
            let between = lastLevels.isEmpty ? levels : zip(lastLevels, levels).map { ($0 + $1) / 2 }
            sim.advance(levels: between, dt: 1.0 / 60)
            sim.advance(levels: levels, dt: 1.0 / 60)
            lastLevels = levels
            let heights = sim.sites.map(\.height)
            let mean = heights.isEmpty ? 0
                : heights.reduce(0, +) / Double(heights.count)
            record(sim.swell, abs(mean - previousMean))
            previousMean = mean
            frame += 1
        }

        // Play, skipping the first 30 frames so the baseline has adapted and the
        // reference is steady music rather than a cold start.
        for f in music.prefix(120) {
            step(f) { swell, move in
                guard frame >= 30 else { return }
                musicSwell = max(musicSwell, swell)
                musicMove = max(musicMove, move)
            }
        }
        // Four seconds paused: long enough for the levels to decay to zero and
        // the fluid to settle, which is what poisons the memory.
        for _ in 0..<120 { step(silence) { _, _ in } }
        // Then the same music again, so the two windows differ only in what came
        // before them; a different passage could report an improvement as a
        // regression.
        var resumed = 0
        for f in music.prefix(120) {
            step(f) { swell, move in
                guard resumed < window else { return }
                resumeSwell = max(resumeSwell, swell)
                resumeMove = max(resumeMove, move)
            }
            resumed += 1
        }

        require(resumeSwell <= musicSwell,
                "resuming heaved the body to swell \(resumeSwell), harder than the "
                + "loudest frame of the same music (\(musicSwell)) — the analyser's "
                + "own discontinuity read as a drum hit")
        require(resumeMove <= musicMove,
                "resuming moved the surface \(resumeMove) in a frame, more than the "
                + "music's own peak of \(musicMove)")
    }

    /// The halo must never appear or vanish in one frame. `glowGate` is a hard
    /// threshold, so without the ease the bloom would switch on and off at alpha
    /// 0.1868, the largest per-frame change in the effect.
    ///
    /// A fixed frame count is the house style here. `updateImpact` and
    /// `publishGates` now share `settledEpsilon`, so impact no longer freezes
    /// between two different thresholds and a step-until-zero loop cannot hang.
    @MainActor
    private static func theGlowNeverSwitchesOnOrOff() {
        let sim = FerrofluidSim()
        let silence = [Float](repeating: 0, count: 12)
        // One tick first so `kick` is sized and the surge lands synchronously.
        sim.advance(levels: silence, dt: 1.0 / 60)
        sim.surge(1.0)

        var previous = FerrofluidSim.glowAlpha(impact: sim.impact, openness: 1)
        var worst = 0.0
        for _ in 0..<240 {
            sim.advance(levels: silence, dt: 1.0 / 60)
            let now = FerrofluidSim.glowAlpha(impact: sim.impact, openness: 1)
            worst = max(worst, abs(now - previous))
            previous = now
        }
        require(worst < 0.05,
                "the halo steps \(worst) in one frame — it is switching, not fading")

        require(FerrofluidSim.glowAlpha(impact: FerrofluidSim.glowGate, openness: 1) == 0,
                "the halo has brightness left at the gate, so it still cuts off")
        // The tuned peak is untouched: the ease only reshapes the bottom.
        require(abs(FerrofluidSim.glowAlpha(impact: 1, openness: 1) - 0.72) < 1e-9,
                "the ease moved the halo's peak")
        require(FerrofluidSim.glowAlpha(impact: 1, openness: 0) == 0,
                "the halo survives a retracted panel")
    }

    /// Letting go of the scrub must release the ink. The scrub is the only thing
    /// that sets the pointer, so anything other than a release on `onEnded` pins
    /// the swell up for the session and `isSettled` never returns, leaving the
    /// renderer running.
    @MainActor
    private static func aFinishedScrubReleasesTheInk() {
        let sim = FerrofluidSim()
        let silence = [Float](repeating: 0, count: 12)
        sim.setPointer(rim: 0.6, strength: 1.5)
        for _ in 0..<30 { sim.advance(levels: silence, dt: 1.0 / 60) }
        require(sim.pointerPull > 0.5, "the scrub never pulled")

        // Re-arming at normal strength and waiting for a mouse move to clear it
        // can never release on its own now.
        sim.setPointer(rim: 0.6)
        for _ in 0..<(60 * 3) { sim.advance(levels: silence, dt: 1.0 / 60) }
        require(sim.pointerPull > 0.5 && !sim.isSettled,
                "re-arming the magnet released on its own — this test proves nothing")

        sim.setPointer(rim: nil)                       // what onEnded must do
        for _ in 0..<(60 * 3) { sim.advance(levels: silence, dt: 1.0 / 60) }
        require(sim.pointerPull == 0,
                "a finished scrub left the ink pulled (\(sim.pointerPull))")
        require(sim.isSettled,
                "a finished scrub left the renderer running forever")
    }

    /// The swell is dragged by the cursor, not pinned to it. Assigning
    /// `pointerRim` directly would teleport the mound along the rim on every
    /// mouse move, so the ink tracks rigidly. It must lag: visibly behind after
    /// one frame, still short of the target a tenth of a second later, and
    /// arrived by half a second.
    @MainActor
    private static func theSwellTrailsTheCursor() {
        let sim = FerrofluidSim()
        let silence = [Float](repeating: 0, count: 12)
        sim.setPointer(rim: 0.1)
        for _ in 0..<60 { sim.advance(levels: silence, dt: 1.0 / 60) }
        require(abs(sim.pointerRim - 0.1) < 0.01,
                "the swell never reached the resting cursor (\(sim.pointerRim))")

        sim.setPointer(rim: 0.9)
        sim.advance(levels: silence, dt: 1.0 / 60)
        require(sim.pointerRim < 0.25,
                "the swell jumped with the cursor instead of trailing it (\(sim.pointerRim))")

        for _ in 0..<5 { sim.advance(levels: silence, dt: 1.0 / 60) }
        require(sim.pointerRim < 0.72,
                "the swell caught up too fast to read as mass (\(sim.pointerRim))")

        for _ in 0..<24 { sim.advance(levels: silence, dt: 1.0 / 60) }
        require(abs(sim.pointerRim - 0.9) < 0.06,
                "the swell never arrived where the cursor is (\(sim.pointerRim))")
    }

    /// The pointer is a magnet that must work in silence, so its pull is
    /// integrated before `advance()`'s settled early return, and its arrival
    /// wakes a renderer gated on `isSettled`.
    @MainActor
    private static func theInkAnswersThePointer() {
        let sim = FerrofluidSim()
        let silence = [Float](repeating: 0, count: 12)
        for _ in 0..<(60 * 3) { sim.advance(levels: silence, dt: 1.0 / 60) }
        require(sim.isSettled, "did not settle before the pointer arrived")

        sim.setPointer(rim: 0.25)
        require(!sim.isSettled, "the pointer did not wake the renderer")
        for _ in 0..<40 { sim.advance(levels: silence, dt: 1.0 / 60) }
        require(sim.pointerPull > 0.5,
                "the pull never built in silence (pull \(sim.pointerPull))")

        sim.setPointer(rim: nil)
        for _ in 0..<(60 * 3) { sim.advance(levels: silence, dt: 1.0 / 60) }
        require(sim.pointerPull == 0, "the pull never released")
        require(sim.isSettled, "the fluid never settled after the pointer left")
    }

    /// Dragging the playhead should feel like dragging the surface, so a scrub
    /// pulls harder than a plain pointer. Both calls are scrubs; what differs is
    /// the strength argument.
    @MainActor
    private static func aScrubPullsHarderThanAHover() {
        let sim = FerrofluidSim()
        let silence = [Float](repeating: 0, count: 12)
        for _ in 0..<(60 * 3) { sim.advance(levels: silence, dt: 1.0 / 60) }

        sim.setPointer(rim: 0.7)
        for _ in 0..<40 { sim.advance(levels: silence, dt: 1.0 / 60) }
        let hover = sim.pointerPull

        sim.setPointer(rim: 0.7, strength: 1.5)
        for _ in 0..<40 { sim.advance(levels: silence, dt: 1.0 / 60) }
        require(sim.pointerPull > hover * 1.2,
                "a scrub did not pull harder than a hover (\(hover) -> \(sim.pointerPull))")
    }

    // MARK: The audio lifecycle

    /// Core Audio's callback queue must never be the queue teardown runs on.
    ///
    /// Core Audio delivers the IOProc by `dispatch_sync`ing onto the queue it was
    /// handed while holding its own IO mutex. If that queue also runs
    /// `AudioDeviceStop` the result is an ABBA deadlock, not a race, and nothing
    /// recovers: the wedge sits upstream of `setState(running: false)`, so
    /// `isRunning` stays true, `levels()` keeps serving the last bands, and every
    /// status reports capture healthy while the visualiser is dead.
    ///
    /// Exercising it would need a live process tap capturing system audio and a
    /// deliberate deadlock, so this reads the source and asserts the
    /// relationship rather than the spelling: whatever the queues are called, the
    /// one handed to Core Audio must not be the one `start()` and `stop()`
    /// dispatch onto.
    private static func theIOProcNeverSharesTheLifecycleQueue() {
        let path = "Sources/NotchApp/Audio/AudioTap.swift"
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else {
            require(false, "cannot read \(path) — run check.sh from the repo root")
            return
        }

        guard let startBody = body(of: "func start() {", in: text),
              let stopBody = body(of: "func stop() {", in: text),
              let teardown = body(of: "private func teardown() {", in: text)
        else {
            require(false, "cannot find start/stop/teardown in \(path) — if they were "
                    + "renamed, re-read this check before re-pointing it")
            return
        }

        guard let startQueue = queueDispatchedOn(in: startBody),
              let stopQueue = queueDispatchedOn(in: stopBody)
        else {
            require(false, "start() or stop() no longer dispatches its work onto a queue "
                    + "at all, so lifecycle work now runs on the caller's thread")
            return
        }

        // Teardown is serialised behind start: run inline, a stop could complete
        // while a start was mid-flight and leave a live tap and aggregate device
        // with no handle able to reach them.
        require(startQueue == stopQueue,
                "start() dispatches onto \(startQueue) and stop() onto \(stopQueue); "
                + "a start racing a stop is only ordered while both use one queue")

        let marker = "AudioDeviceCreateIOProcIDWithBlock("
        let around = text.components(separatedBy: marker)
        require(around.count == 2,
                "expected exactly one IOProc registration in \(path), found \(around.count - 1)")
        guard around.count == 2, let brace = around[1].firstIndex(of: "{") else { return }

        // The queue is the last argument before the trailing closure.
        let arguments = String(around[1][..<brace])
        let ioQueue = arguments
            .split(separator: ",")
            .last
            .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " )\n\t")) }
        guard let ioQueue, !ioQueue.isEmpty else {
            require(false, "cannot read the IOProc's queue argument from \(path)")
            return
        }

        require(ioQueue != startQueue,
                "the IOProc is delivered on \(ioQueue), the same queue teardown runs on: "
                + "Core Audio dispatch_syncs the callback there while holding its IO mutex, "
                + "so AudioDeviceStop blocks on that mutex while the IO thread blocks on "
                + "the queue, and the tap wedges with every status still reporting healthy")

        // The runtime half: if the queues converge again by a route this source
        // read cannot see, teardown traps instead of hanging silently.
        require(teardown.contains("dispatchPrecondition") && teardown.contains("notOnQueue"),
                "teardown() no longer asserts it is off the IOProc's queue, so the deadlock "
                + "would come back as a silent permanent hang rather than a crash")
    }

    /// A function body: from its signature to the next brace at method indent.
    private static func body(of signature: String, in text: String) -> String? {
        let parts = text.components(separatedBy: signature)
        guard parts.count == 2, let end = parts[1].range(of: "\n    }") else { return nil }
        return String(parts[1][..<end.lowerBound])
    }

    /// The queue a body dispatches onto: the identifier before its first `.async`.
    private static func queueDispatchedOn(in body: String) -> String? {
        guard let call = body.range(of: ".async") else { return nil }
        var name = ""
        var i = call.lowerBound
        while i > body.startIndex {
            let previous = body.index(before: i)
            let character = body[previous]
            guard character.isLetter || character.isNumber || character == "_" else { break }
            name = String(character) + name
            i = previous
        }
        return name.isEmpty ? nil : name
    }

    private static func require(_ ok: @autoclosure () -> Bool, _ message: String) {
        guard ok() else {
            FileHandle.standardError.write("fluidcheck: \(message)\n".data(using: .utf8)!)
            exit(1)
        }
    }
}
