import Foundation
import Observation

/// Ferrofluid physics, modelled on the Rosensweig (normal-field) instability.
///
/// The surface is flat until the local field crosses a critical value, then throws
/// a lattice of conical peaks. Hysteresis lets a peak hold briefly after a hit and
/// drain back into the shared pool without ringing.
///
/// Everything is driven by captured audio: no clock oscillators or springs, and
/// nothing detaches or expires. Each band's site rises and falls and the renderer
/// turns those into mounds of one continuous surface.
@MainActor
@Observable
final class FerrofluidSim {

    struct Site {
        /// 0…1 along the visible rim: left side, bottom, right side.
        let rim: Double
        /// Frequency band that drives this site.
        let band: Int
        /// Small fixed jitter keeps the lobes from reading as a comb.
        let fan: Double
        var height: Double
        /// How fast `height` is moving; the spike is a spring, so it can overshoot.
        var velocity: Double = 0
        var field: Double
        var isUp: Bool
    }

    @ObservationIgnored private(set) var sites: [Site] = []
    /// Bass energy displaces the whole continuous reservoir.
    @ObservationIgnored private(set) var swell: Double = 0
    private var swellVelocity = 0.0
    private var lastBassHit = 0.0
    /// How hard a full kick throws the body, in swell per second.
    static let swellBlow = 22.0
    /// Ink standing in peaks; the shared pool sinks by this amount.
    @ObservationIgnored private(set) var raised: Double = 0



    /// How hard the music just hit, 0...1; drives the rim glow. Taken from the largest
    /// per-band transient, so it is an event measure that spikes and decays, never a
    /// level.
    @ObservationIgnored private(set) var impact: Double = 0

    /// How open the ink is, which is not how open the shell is. Driving the ink
    /// straight from the shell's spring would make opening in silence move nothing,
    /// since with no lobes and no swell `displacement` is exactly 0. This follows the
    /// shell asymmetrically: slow to fill, quick to drain.
    @ObservationIgnored private(set) var inkOpen: Double = 0
    private var openTarget: Double = 0

    /// Reduce Motion takes the travel out of the open: the ink closes the gap to the
    /// shell sooner.
    var reduceMotion = false

    /// True while something is driving `advance`. `isSettled` is what pauses the
    /// renderer, so clearing it without a clock leaves `TimelineView` redrawing a
    /// picture that cannot change. Every writer that clears the gate must guarantee
    /// this.
    var isDriven: Bool { running != nil }

    /// Clears the settled gate and guarantees something will recompute it.
    private func wake() {
        if isSettled { isSettled = false }
        runClock()
    }

    /// The shell moved. Called with the aggregate across displays, never one
    /// controller's state, since the sim is shared and the controllers are not.
    func setOpen(_ open: Bool) {
        // Idempotent: the same aggregate value arrives once per display.
        let t = open ? 1.0 : 0.0
        guard t != openTarget else { return }
        openTarget = t
        wake()
    }

    /// Below this the halo is not drawn at all. A lower gate keeps it lit almost
    /// continuously, costing a silhouette paint and a blur every frame.
    nonisolated static let glowGate = 0.14
    /// The last stretch of the decay, over which the halo eases out instead of being
    /// cut off at the gate.
    nonisolated static let glowFade = 0.10

    /// The halo's alpha, eased to nothing at the gate. A hard threshold made the bloom
    /// vanish from alpha 0.19 in one frame, the largest per-frame change in the
    /// effect; a smoothstep over the last 0.10 of the decay cuts the worst step to
    /// 0.03 and leaves values at or above 0.24 unchanged.
    ///
    /// `nonisolated` because it is a pure function and the renderer needs it off the
    /// observation path.
    nonisolated static func glowAlpha(impact: Double, openness: Double) -> Double {
        let t = min(1, max(0, (impact - glowGate) / glowFade))
        let ease = t * t * (3 - 2 * t)
        return (0.10 + 0.62 * impact) * ease * min(1, max(0, openness))
    }
    /// Phase for the colour field behind the ink, advanced only by audio. Integrating
    /// loudness means the field moves as far as the music moves it and stalls when it
    /// stops; a wall-clock phase would sweep on a visible cycle with nothing playing.
    /// There is no constant term.
    @ObservationIgnored private(set) var flowPhase: Double = 0
    /// Smoothed loudness, 0...1, for intensity.
    @ObservationIgnored private(set) var brightness: Double = 0

    /// Observed, and written only when it flips. Observation fires on assignment, not
    /// change, and the underlying fields are rewritten every frame, so a view reading
    /// them would be invalidated at 60 Hz and `paused:` could never stop anything.
    /// Every hot field is untracked (the display link drives redraws) and these two
    /// Bools are the observable surface.
    private(set) var isSettled = true
    /// True while there is sound. Gates the colour field's timeline.
    private(set) var hasSound = false

    private func publishGates() {
        let e = Self.settledEpsilon
        let settled = swell < e && abs(swellVelocity) < 0.02 && impact < e && pointerPull < e
            && inkOpen == openTarget
            && !sites.contains { $0.height > 0.003 || abs($0.velocity) > 0.05 }
        if settled != isSettled { isSettled = settled }
        let sound = brightness >= 0.002
        if sound != hasSound { hasSound = sound }
    }

    /// Read once rather than building an environment dictionary 60 times a second.
    nonisolated static let debugLogging =
        ProcessInfo.processInfo.environment["NOTCH_FLUID_DEBUG"] != nil

    /// Below this a field is treated as zero. It must be the same threshold
    /// `updateImpact` snaps at and `publishGates` settles at; with two values impact
    /// can sit in the gap between them, too small for the gate and too large to snap.
    static let settledEpsilon = 0.004

    nonisolated static let siteCount = 17
    /// Raised so fewer sites break at once: eight middling lobes read as a ripple,
    /// three decisive ones as ferrofluid answering the music. Internal so fluidcheck
    /// can hold its margins against the real value.
    let criticalField = 0.36
    private let collapseField = 0.16


    private var running: Task<Void, Never>?
    private weak var audio: AudioLevels?
    private var previousLevels: [Float] = []
    /// The frame before `previousLevels`. A hit's rise straddles two 16 ms frames, so
    /// measured against one frame back each half can fall under the onset bar.
    private var olderLevels: [Float] = []
    private var kick: [Double] = []
    /// A surge that arrived before there was anything to apply it to.
    private var pendingSurge: (strength: Double, direction: Double)?

    /// Where the pointer is along the rim, 0...1. The ink is magnetic, so a cursor
    /// moving along the notch drags a swell with it, which makes the surface feel
    /// alive with no music playing.
    @ObservationIgnored private(set) var pointerRim: Double = 0.5
    /// Where the cursor actually is; `pointerRim` chases this.
    private var pointerRimTarget: Double = 0.5
    /// How much of that pull is applied, eased so the ink does not snap to attention
    /// when the pointer crosses the boundary.
    @ObservationIgnored private(set) var pointerPull: Double = 0

    private var pointerTarget: Double = 0

    /// Called on every mouse move (the coordinator) and every scrub step (the panel).
    func setPointer(rim: Double?, strength: Double = 1) {
        if let rim {
            // Only the target moves with the cursor; the swell chases it viscously, so the
            // bulge is dragged rather than teleported.
            pointerRimTarget = min(1, max(0, rim))
            pointerTarget = min(1.6, max(0, strength))
            // Wake the renderer: it is gated on `isSettled`, and a pointer arriving is the
            // case where nothing else will clear it, including when no clock is running.
            wake()
        } else {
            pointerTarget = 0
        }
    }
    private var baseline: [Double] = []
    private var spread: [Double] = []
    /// The spread `deviation` starts every band at, and returns to on re-entry.
    private static let initialSpread = 0.06
    /// How many swings a rise must clear to count as an onset.
    static let onsetFloor = 0.9
    /// `deviation` slowed to a drift: between hits the body follows how loud the music
    /// is, not every wobble in it.
    private var drift: [Double] = []
    private var pool = 0.0

    /// How long every band must sit under `AudioLevels.silenceLevel` before the next
    /// audio counts as re-entry rather than a transient. The levels take about 0.6 s
    /// to decay under that threshold, so this is roughly a second of real silence:
    /// longer than any rest inside a track, shorter than a pause.
    private static let reentryAfter = 0.35
    private var quietFor = 0.0

    /// Resuming is not an onset.
    ///
    /// Both inputs measure change against a remembered past, and a pause poisons that
    /// memory: `previousLevels` tracks the decay to zero and `baseline`/`spread` freeze
    /// near zero once the settled early-return stops calling `deviation`. The first
    /// frame after a pause then reads as a full-scale event twice over (`rise` is the
    /// whole level, and `delta / max(0.035, spread * 1.6)` divides a half-scale jump by
    /// the floor). Re-seeding the memory to the incoming levels makes that frame a
    /// non-event without a fade or injected energy.
    ///
    /// `spread` is deliberately not reset: it is the only memory of how wide this
    /// track's swings are, a cold value moves the slam one frame later rather than
    /// removing it, and a stale spread only under-reacts briefly.
    private func reenter(_ levels: [Float]) {
        previousLevels = levels
        olderLevels = levels
        baseline = levels.map(Double.init)
    }

    func start(audio: AudioLevels) {
        self.audio = audio
        runClock()
    }

    /// Lets go of the audio without dropping the picture. `stop()` zeroes every field
    /// at once, a visible jump when something is on screen. Here the clock runs on
    /// silence until the ink comes to rest and then retires itself.
    func release() {
        audio = nil
        runClock()
    }

    /// The 16 ms tick. It runs without an audio consumer, so opening the idle panel
    /// still moves the ink; the tap is the expensive part, not this. The loop ends
    /// itself once nothing feeds it and the fluid is at rest.
    private func runClock() {
        guard running == nil else { return }

        running = Task { @MainActor [weak self] in
            var last = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                guard let self, !Task.isCancelled else { return }

                let now = ContinuousClock.now
                let span = last.duration(to: now)
                let dt = min(0.05, Double(span.components.seconds)
                             + Double(span.components.attoseconds) / 1e18)
                last = now
                self.step(dt: dt)

                if self.audio == nil, self.isSettled {
                    self.running = nil
                    return
                }
            }
        }
    }

    func stop() {
        running?.cancel()
        running = nil
        brightness = 0
        flowPhase = 0
        impact = 0
        pointerPull = 0
        pointerTarget = 0
        audio = nil
        sites = []
        swell = 0
        swellVelocity = 0
        lastBassHit = 0
        raised = 0
        impact = 0
        previousLevels = []
        olderLevels = []
        kick = []
        quietFor = 0
        pendingSurge = nil
        inkOpen = openTarget
        baseline = []
        drift = []
        pool = 0
        spread = []
        // Last, after every field it reads: publishing earlier computes `isSettled` from
        // stale state and can pin the renderer running.
        publishGates()
    }

    private func step(dt: Double) {
        // Silence rather than a bail-out: with no track there is still a panel to open,
        // and the open is not made of audio.
        advance(levels: audio?.bands ?? Self.silence, dt: dt)
    }

    private static let silence = [Float](repeating: 0, count: AudioTap.bandCount)

    /// The physics with the audio plumbing removed so it can be driven directly.
    /// Reacting to change rather than loudness, a surface that is not a comb, and
    /// genuinely still silence are all properties of this function, which
    /// `tools/fluidcheck.swift` asserts against synthetic spectra.
    func advance(levels: [Float], dt: Double) {
        guard !levels.isEmpty else { return }

        // The pointer pull and the ink's follow of the shell are independent of audio, so
        // they are integrated before the settled early-return. Both are viscous. The open
        // has two state-dependent rates: filling starts slow and accelerates, so the ink
        // is visibly behind the chrome early and still catches it; draining starts fast
        // and eases, so it beats the closing shell home rather than being caught by the
        // clip.
        let scale = reduceMotion ? 2.6 : 1.0
        let openRate = (openTarget > inkOpen ? (1.4 + 10.0 * inkOpen)
                                             : (8.0 + 16.0 * (1 - inkOpen))) * scale
        inkOpen += (openTarget - inkOpen) * min(1, openRate * dt)
        if openTarget == 1, inkOpen > 0.98 { inkOpen = 1 }
        if openTarget == 0, inkOpen < 0.02 { inkOpen = 0 }

        // Opening injects no energy. Feeding the kick, swell or glow would make the
        // panel opening a drum hit with no drum (PRODUCT.md: audio causes events, a clock
        // only advances the simulation). The open moves the ink's shape through
        // `inkOpen` (`room`, `seatU` and the lateral terms key off it), never its energy.

        let pullRate = pointerTarget > pointerPull ? 7.0 : 3.4
        pointerPull += (pointerTarget - pointerPull) * min(1, pullRate * dt)
        if pointerPull < 0.002 { pointerPull = 0 }
        // The swell lags the cursor: slow enough to read as mass being dragged, fast
        // enough to arrive while you are still there.
        pointerRim += (pointerRimTarget - pointerRim) * min(1, 5.0 * dt)

        // Ahead of the early-return, because the silence being timed is the state that
        // early-returns.
        if levels.contains(where: { $0 > AudioLevels.silenceLevel }) {
            if quietFor >= Self.reentryAfter { reenter(levels) }
            quietFor = 0
        } else {
            quietFor += dt
        }

        // Nothing to advance: silent, and every part of the fluid already home. Writing
        // observed state at 60 Hz for a static picture keeps SwiftUI re-evaluating the
        // panel.
        if sites.count == Self.siteCount, isSettled, brightness < 0.002,
           pointerTarget == 0, pointerPull == 0,
           inkOpen == openTarget,
           !levels.contains(where: { $0 > 0.004 }) {
            return
        }

        if sites.count != Self.siteCount { seed(levels: levels) }
        updateKick(levels: levels, dt: dt)
        let dev = deviation(levels, dt: dt)
        if drift.count != dev.count { drift = dev }
        for index in dev.indices { drift[index] += (dev[index] - drift[index]) * min(1, 2.0 * dt) }
        updateSwell(levels: levels, dev: dev, dt: dt)
        updateFlow(levels: levels, dt: dt)
        updateImpact(dt: dt)
        publishGates()
        updateSites(levels: levels, dev: drift, dt: dt)
    }

    private func seed(levels: [Float]) {
        sites = (0..<Self.siteCount).map { index in
            let position = (Double(index) + 0.5) / Double(Self.siteCount)
            let band = min(levels.count - 1, Int(position * Double(levels.count)))
            return Site(rim: min(1, max(0, position + Double.random(in: -0.012...0.012))),
                        band: band,
                        fan: Double.random(in: -0.38...0.38),
                        height: 0,
                        field: 0,
                        isUp: false)
        }
        raised = 0
        swell = 0
        swellVelocity = 0
        lastBassHit = 0
    }

    /// Positive band rise gives the surface its immediate attack.
    private func updateKick(levels: [Float], dt: Double) {
        if kick.count != levels.count {
            kick = [Double](repeating: 0, count: levels.count)
            previousLevels = levels
            olderLevels = levels
        }
        if let held = pendingSurge {
            pendingSurge = nil
            surge(held.strength, direction: held.direction)
        }

        // An onset is a rise wider than this band's own recent swing. Every rise used to
        // count, so ordinary level noise kicked the surface every frame and a drum hit
        // looked like the bar around it. Measured against `spread`, a quiet passage and a
        // loud one both stay still between hits.
        // The kick is the strike itself and lasts a fraction of a beat; how long the ink
        // takes to recover is the surface's business, set by its own drain rates.
        let decay = pow(0.002, dt)
        for index in levels.indices {
            let rise = Double(max(0, levels[index] - min(previousLevels[index],
                                                         olderLevels[index])))
            let swing = index < spread.count ? spread[index] : Self.initialSpread
            let onset = rise / max(0.03, swing * 1.6) - Self.onsetFloor
            kick[index] = max(kick[index] * decay, min(1, max(0, onset)))
        }
        olderLevels = previousLevels
        previousLevels = levels
    }

    /// Each band is measured against its own recent norm, so quiet and loud tracks get
    /// comparable dynamic range without a scripted gain envelope.
    private func deviation(_ levels: [Float], dt: Double) -> [Double] {
        if baseline.count != levels.count {
            baseline = levels.map(Double.init)
            spread = [Double](repeating: Self.initialSpread, count: levels.count)
        }

        let rate = min(1, dt / 2.5)
        var result = [Double](repeating: 0, count: levels.count)
        for index in levels.indices {
            let value = Double(levels[index])
            let delta = value - baseline[index]
            baseline[index] += delta * rate
            spread[index] += (abs(delta) - spread[index]) * rate
            result[index] = max(0, delta) / max(0.035, spread[index] * 1.6)
        }
        return result
    }

    /// Slam the reservoir. A track change is as much an event as a drum hit, so it goes
    /// in through the same door, weighted toward the low end like a downbeat; the
    /// ordinary physics takes over from there. Only the trigger is scripted.
    ///
    /// `direction` is +1 for a skip forward, -1 for back, 0 for anything with no
    /// direction (a press, a track ending). The profile is mirrored rather than
    /// travelling: a moving front reads as a pile at the wrong end for the first
    /// ~0.27 s, because on a flat spectrum `allowed` is 2 and `isUp` hysteresis pins
    /// whichever two sites rose first. 0 keeps the undirected shape.
    func surge(_ strength: Double = 1, direction: Double = 0) {
        // Both exits, including the held one: a surge with no clock either never decays
        // or never arrives. An idle pour can size `kick` and then retire the clock, so a
        // later swipe takes the main path (sets impact and swell, clears `isSettled`)
        // with nothing left to decay them. Re-entrancy safe: `updateKick` calls back in
        // for a held surge while the clock runs, and `runClock` no-ops.
        defer { runClock() }
        guard !kick.isEmpty else {
            // `kick` is sized on the first step tick, not in `start()`, so a track change in
            // that window has nothing to inject into. Hold it rather than drop it (the first
            // song of a session matters most); the stronger wins, and a real direction beats
            // none.
            pendingSurge = (max(pendingSurge?.strength ?? 0, strength),
                            direction != 0 ? direction : (pendingSurge?.direction ?? 0))
            return
        }
        for index in kick.indices {
            let t = Double(index) / Double(max(1, kick.count - 1))
            let w = direction > 0 ? (0.45 + 0.55 * t) : (1 - 0.55 * t)
            kick[index] = max(kick[index], strength * w)
        }
        impact = max(impact, strength)
        swell = max(swell, strength * 0.7)
        // Republish immediately: `advance` early-returns while `isSettled` is true, and
        // it is a stored value, so a surge into a settled fluid would be skipped by the
        // next step.
        publishGates()
    }

    private func updateImpact(dt: Double) {
        let hit = kick.max() ?? 0
        // Fast up, slow down: a hit reads instantly and leaves an afterglow.
        impact = max(hit, impact * pow(0.06, dt))
        if impact < Self.settledEpsilon { impact = 0 }
    }


    private func updateFlow(levels: [Float], dt: Double) {
        let loud = levels.isEmpty ? 0
            : Double(levels.reduce(0, +)) / Double(levels.count)
        let rate = loud > brightness ? 6.0 : 2.2
        brightness += (loud - brightness) * min(1, rate * dt)
        if brightness < 0.002 { brightness = 0 }
        flowPhase += brightness * 2.6 * dt
    }

    private func updateSwell(levels: [Float], dev: [Double], dt: Double) {
        let count = max(1, min(3, levels.count))
        // Two parts: a pool that follows how loud the bass is over about a second, so the
        // ink rests rounded and full rather than as the bare cutout, and the hit on top.
        let bass = drift.prefix(count).reduce(0, +) / Double(count)
        // In silence it drains quickly, so the ink comes home and the renderer can stop.
        let poolRate = quietFor > 0 ? 4.0 : 0.8
        pool += (min(1, bass * 0.3) - pool) * min(1, poolRate * dt)
        let hit = kick.prefix(count).max() ?? 0
        // A spring rather than a chase: the body rests on the pool, and a kick is a blow
        // that throws it, so it moves in the frame the hit arrives, overshoots, and
        // bounces home like a liquid instead of easing in and out like a meter. Only the
        // rise of the kick strikes; its decay is the spring's business.
        let blow = max(0, hit - lastBassHit)
        lastBassHit = hit
        swellVelocity += blow * Self.swellBlow
        let omega = quietFor > 0 ? 20.0 : 15.0
        swellVelocity += (omega * omega * (pool - swell) - 2 * 0.4 * omega * swellVelocity) * dt
        swell = min(1.15, swell + swellVelocity * dt)
        if swell <= 0 { swell = 0; swellVelocity = max(0, swellVelocity) }
        if swell < 0.004, abs(swellVelocity) < 0.02 { swell = 0; swellVelocity = 0 }
    }

    private func updateSites(levels: [Float], dev: [Double], dt: Double) {
        var standing = 0.0
        let energy = dev.reduce(0, +) / Double(max(1, dev.count))
        let allowed = 2 + Int((min(1, energy) * 7).rounded())
        let rank = sites.indices.sorted { sites[$0].field > sites[$1].field }
        var mayStand = [Bool](repeating: false, count: sites.count)
        for index in rank.prefix(allowed) { mayStand[index] = true }

        for index in sites.indices {
            let band = min(levels.count - 1, sites[index].band)
            let raw = min(1, dev[band] * 0.22 + kick[band] * 1.4)

            // Heaves on the hit, drains like something thick.
            let fieldRate = raw > sites[index].field ? 60.0 : 6.0
            sites[index].field += (raw - sites[index].field) * min(1, fieldRate * dt)
            let field = sites[index].field

            if sites[index].isUp {
                if field < collapseField || !mayStand[index] {
                    sites[index].isUp = false
                }
            } else if field > criticalField, mayStand[index] {
                sites[index].isUp = true
            }

            let target: Double
            if sites[index].isUp {
                let excess = (field - collapseField) / (1 - collapseField)
                // Power law rather than a floor plus a curve: a floor makes every standing peak
                // start high and the crown a row of near-equal spikes (about 1.8:1). This spans
                // roughly 0.14 to 1.0 (about 7:1) at the shipping `criticalField`, so a quiet
                // band is a ripple and a hit is a spire. Onset is still a finite pop, so the
                // hysteresis above holds. Both ratios depend on `criticalField`, and the same
                // figures are restated in `FerrofluidView` and the site's JS port.
                target = min(1, pow(max(0, excess), 1.35))
            } else {
                target = 0
            }

            // Bass is heavy and drains slowly, treble is light and snaps back; one rate
            // would make the whole crown breathe as a single object.
            let bandT = Double(band) / Double(max(1, levels.count - 1))
            // Twice as fast once the music has stopped, so the ink is home inside the
            // settle budget rather than draining for four seconds of silence.
            // A spring: the spike shoots up within a frame or two, overshoots, and rings
            // down. A plain chase reached its mark and stopped dead, which read as stiff.
            // The stiff spring holds until the spike turns over, so the momentum it gave
            // is braked by the spring that made it; braked by the soft one, a spike told
            // to fall kept climbing for 150 ms.
            var v = sites[index].velocity
            let rising = v > 0 || target > sites[index].height + 0.05
            let omega = rising ? 52.0 : (7.0 + 13.0 * bandT) * (quietFor > 0 ? 1.6 : 1)
            let zeta = rising ? 0.5 : 0.7
            v += (omega * omega * (target - sites[index].height) - 2 * zeta * omega * v) * dt
            var h = sites[index].height + v * dt
            if h <= 0 { h = 0; v = max(0, v) }
            if h > 1.25 { h = 1.25; v = min(0, v) }
            if h < 0.003, abs(v) < 0.05 { h = 0; v = 0 }
            sites[index].height = h
            sites[index].velocity = v
            standing += sites[index].height
        }

        // Surface tension shares ink between neighbouring peaks: first-order diffusion,
        // no springs and no overshoot.
        if sites.count > 2 {
            let heights = sites.map(\.height)
            let rate = min(0.5, 3.2 * dt)
            for index in 1..<(sites.count - 1) {
                let mean = (heights[index - 1] + heights[index + 1]) / 2
                sites[index].height += (mean - heights[index]) * rate
            }
        }

        let targetRaised = min(1, standing / Double(max(1, sites.count)) * 1.4)
        raised += (targetRaised - raised) * min(1, 9 * dt)

        if Self.debugLogging {
            let up = sites.filter(\.isUp).count
            let meanField = sites.map(\.field).reduce(0, +) / Double(sites.count)
            FileHandle.standardError.write(
                String(format: "[fluid] up=%2d/%d meanField=%.2f swell=%.2f\n",
                       up, sites.count, meanField, swell).data(using: .utf8)!)
        }
    }
}
