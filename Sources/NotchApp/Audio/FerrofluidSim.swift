import AppKit
import Observation
import QuartzCore

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
        /// How fast `height` is moving. The follower is critically damped, so a lobe flows
        /// out and drains home without overshoot.
        var velocity: Double = 0
        var field: Double
        var isUp: Bool
    }

    @ObservationIgnored private(set) var sites: [Site] = []
    /// Bass energy displaces the whole continuous reservoir.
    @ObservationIgnored private(set) var swell: Double = 0
    private var swellVelocity = 0.0
    /// The body's charge from the last hit, held at the larger of its decay and the newest
    /// hit, so the swell has a target to flow toward rather than a blow to absorb.
    private var swellCharge = 0.0
    // The loudest the music has been lately, and how near it is to that now.
    private var loudMemory = 0.0
    private var loudGain = 1.0
    // A track change opens the lobe budget for a moment, so the whole side it leans to
    // stands rather than whichever two lobes happen to rise first.
    private var surgeOpen = 0.0
    /// How far a full hit throws the body, and a band's lobe, as a share of full travel.
    static let swellBlow = 0.5
    static let siteBlow = 12.0
    /// Ink standing in peaks; the shared pool sinks by this amount.
    @ObservationIgnored private(set) var raised: Double = 0



    /// How hard the music just hit, 0...1; drives the rim glow. Taken from the largest
    /// per-band transient, so it is an event measure that spikes and decays, never a
    /// level.
    @ObservationIgnored private(set) var impact: Double = 0

    /// The hit as light: what the rim halo and the card's bloom show. `impact` may climb
    /// on every drum; this starts a new flash only `flashGap` after the last one began,
    /// so nothing it lights flashes more than three times a second (the WCAG 2.3.1
    /// ceiling). Under Dim Flashing Lights it is once a second at a third of the strength.
    /// A hit inside the gap still moves the ink; only the light skips it.
    @ObservationIgnored private(set) var light: Double = 0
    private var sinceFlash = Double.infinity
    /// Mirrors the system's Dim Flashing Lights setting, kept current by the coordinator.
    var dimFlashingLights = false
    nonisolated static let flashGap = 1.0 / 3

    /// How open the ink is, which is not how open the shell is. Driving the ink
    /// straight from the shell's spring would make opening in silence move nothing,
    /// since with no lobes and no swell `displacement` is exactly 0. This follows the
    /// shell asymmetrically: slow to fill, quick to drain.
    @ObservationIgnored private(set) var inkOpen: Double = 0
    private var openTarget: Double = 0

    /// Reduce Motion takes the travel out of the open: the ink closes the gap to the
    /// shell sooner.
    var reduceMotion = false

    /// True while something is driving `advance`. The ink redraws only when a step
    /// publishes, so clearing `isSettled` without a clock leaves it frozen mid-motion.
    /// Every writer that clears the gate must guarantee this.
    var isDriven: Bool { link != nil || fallback != nil }

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
    nonisolated static func glowAlpha(light: Double, openness: Double) -> Double {
        let t = min(1, max(0, (light - glowGate) / glowFade))
        let ease = t * t * (3 - 2 * t)
        return (0.10 + 0.62 * light) * ease * min(1, max(0, openness))
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
    /// Bumped once per published step. The ink view reads it and so redraws exactly when
    /// the picture changed; a timeline of its own at 1/60 s on a 120 Hz screen drew at
    /// uneven 17 and 25 ms gaps and could show one step twice.
    private(set) var frame = 0

    private func publishGates() {
        frame &+= 1
        let e = Self.settledEpsilon
        let settled = swell < e && abs(swellVelocity) < 0.02 && impact < e && light < e && pointerPull < e
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
    /// A lobe at this height counts as standing, for the debug log and the checks.
    static let standingHeight = 0.08
    static let siteGate = 0.35
    static let fewestStanding = 2
    static let extraStanding = 7.0
    static let loudMemorySeconds = 12.0
    static let loudCurve = 6.0


    private var link: CADisplayLink?
    /// Steps the ink where there is no screen to sync to, as in the headless checks.
    private var fallback: Task<Void, Never>?
    private var lastFrame: CFTimeInterval = 0
    private weak var audio: AudioLevels?
    private var previousLevels: [Float] = []
    /// The frame before `previousLevels`. A hit's rise straddles two 16 ms frames, so
    /// measured against one frame back each half can fall under the onset bar.
    private var olderLevels: [Float] = []
    private var kick: [Double] = []
    /// Each band's typical one-frame rise over about a second: the second yardstick for
    /// an onset, beside `spread`. `spread` is distance from a slow average, so a section
    /// where the bass drops out and slams back in reads as one wide swing and lifts the
    /// bar over every kick for seconds; the ink went flat on a drop. Rises alone only
    /// count rises, so a level change between sections does not move this bar.
    private var flux: [Double] = []
    /// How many typical rises a rise must be to count, against `flux`.
    static let fluxOnsetScale = 8.0
    /// Seconds since the music came back from silence, capped at the ramp. The levels
    /// climb from nothing over the first frames back, a rise in every band that is the
    /// analyser waking rather than a drum, so onsets are let in over about 150 ms.
    private var reentry = Double.infinity
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
    /// How many swings a rise must clear to count as an onset, and how far past that a
    /// hit is half strength. The soft knee keeps a hit's size proportional to its rise,
    /// where a hard clamp made every drum a full blow.
    static let onsetFloor = 1.1
    static let onsetKnee = 1.0
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
        reentry = 0
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

    /// The 60 Hz tick. It runs without an audio consumer, so opening the idle panel
    /// still moves the ink; the tap is the expensive part, not this. The clock ends
    /// itself once nothing feeds it and the fluid is at rest.
    ///
    /// Stepped on the display's refresh. A 16 ms sleep on the main actor ran at about
    /// 56 Hz with gaps up to 24 ms, so against a 60 Hz screen some four frames a second
    /// showed the ink unchanged and the next one jumped: a judder that read as a stiff,
    /// late liquid. The levels are read in the same tick, so every step has the newest.
    private func runClock() {
        guard !isDriven else { return }
        lastFrame = 0
        if let screen = NSScreen.screens.first {
            let tick = DisplayTick { [weak self] link in self?.frame(link) }
            let link = screen.displayLink(target: tick, selector: #selector(DisplayTick.fire(_:)))
            link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
            link.add(to: .main, forMode: .common)
            self.link = link
            return
        }
        fallback = Task { @MainActor [weak self] in
            var last = ContinuousClock.now
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(16))
                guard let self, !Task.isCancelled else { return }
                let now = ContinuousClock.now
                let span = last.duration(to: now)
                last = now
                self.tick(dt: min(0.05, Double(span.components.seconds)
                                  + Double(span.components.attoseconds) / 1e18))
            }
        }
    }

    private func frame(_ link: CADisplayLink) {
        let dt = lastFrame == 0 ? 1.0 / 60 : min(0.05, link.timestamp - lastFrame)
        lastFrame = link.timestamp
        tick(dt: dt)
    }

    private func tick(dt: Double) {
        audio?.pull()
        step(dt: dt)
        if audio == nil, isSettled { endClock() }
    }

    private func endClock() {
        link?.invalidate()
        link = nil
        fallback?.cancel()
        fallback = nil
    }

    func stop() {
        endClock()
        brightness = 0
        flowPhase = 0
        impact = 0
        pointerPull = 0
        pointerTarget = 0
        audio = nil
        sites = []
        swell = 0
        swellVelocity = 0
        swellCharge = 0
        raised = 0
        impact = 0
        light = 0
        sinceFlash = .infinity
        previousLevels = []
        olderLevels = []
        kick = []
        flux = []
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
        updateSites(levels: levels, dev: dev, dt: dt)
    }

    /// Where the lobes' small random offsets come from; a check replaces it to replay a
    /// capture exactly.
    var random: (ClosedRange<Double>) -> Double = { Double.random(in: $0) }

    private func seed(levels: [Float]) {
        sites = (0..<Self.siteCount).map { index in
            let position = (Double(index) + 0.5) / Double(Self.siteCount)
            let band = min(levels.count - 1, Int(position * Double(levels.count)))
            return Site(rim: min(1, max(0, position + random(-0.012...0.012))),
                        band: band,
                        fan: random(-0.38...0.38),
                        height: 0,
                        field: 0,
                        isUp: false)
        }
        raised = 0
        swell = 0
        swellVelocity = 0
        swellCharge = 0
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
        let decay = pow(0.00002, dt)
        reentry += dt
        let wake = min(1, reentry / 0.15)
        if flux.count != levels.count { flux = [Double](repeating: 0.02, count: levels.count) }
        let fluxRate = min(1, dt / 1.2)
        for index in levels.indices {
            let rise = Double(max(0, levels[index] - min(previousLevels[index],
                                                         olderLevels[index])))
            let swing = index < spread.count ? spread[index] : Self.initialSpread
            // Either yardstick may call it: `spread` keeps the hits it always caught, `flux`
            // adds the ones a section change hid from it.
            let ratio = max(rise / max(0.03, swing * 1.6),
                            rise / max(0.02, flux[index] * Self.fluxOnsetScale))
            let over = max(0, ratio - Self.onsetFloor)
            // Silence has no rises, so learning through it would shrink the bar to nothing
            // and the first frame back would read as a hit in every band.
            if quietFor == 0 {
                flux[index] += (Double(max(0, levels[index] - previousLevels[index])) - flux[index]) * fluxRate
            }
            kick[index] = max(kick[index] * decay, wake * pow(over / (over + Self.onsetKnee), 1.5))
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
        func weight(_ band: Int) -> Double {
            let t = Double(band) / Double(max(1, kick.count - 1))
            return direction > 0 ? (0.3 + 0.7 * t) : (1 - 0.7 * t)
        }
        // The kick is raised flat, for the body and the light: leaning it as well would
        // let the end bands through the common-hit subtraction, and their random spread
        // would decide the crown instead of the surge.
        for index in kick.indices {
            kick[index] = max(kick[index], strength)
        }
        // The peaks are charged directly: a surge lands in every band at once, which
        // the common-hit subtraction in `updateSites` would read as a whole-mix hit and
        // cancel, leaving a track change with no crown. A full surge stands a full lobe
        // at the end it leans to, so the crown is the surge's and not the random spread's.
        for index in sites.indices {
            sites[index].field = max(sites[index].field, 1.7 * strength * weight(sites[index].band))
        }
        impact = max(impact, strength)
        surgeOpen = max(surgeOpen, strength)
        flash(strength)
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
        sinceFlash += dt
        light *= pow(0.06, dt)
        flash(hit)
        if light < Self.settledEpsilon { light = 0 }
    }

    /// Lights a hit if the flash ceiling allows it. A hit's rise straddles two or three
    /// frames, so the first 50 ms of a flash may still climb; after that the light only
    /// decays until the gap has passed.
    private func flash(_ hit: Double) {
        let strength = hit * (dimFlashingLights ? 0.35 : 1)
        if sinceFlash < 0.05 {
            light = max(light, strength)
        } else if sinceFlash >= (dimFlashingLights ? 1 : Self.flashGap), strength > light + 0.1 {
            light = strength
            sinceFlash = 0
        }
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
        pool += (min(1, bass * 0.03) - pool) * min(1, poolRate * dt)
        // Any drum heaves the body, the low end hardest: a snare is a hit as much as a kick,
        // and on many mixes the sub-bass is a flat floor with the beat living in the mids.
        var hit = 0.0
        for index in kick.indices {
            let t = Double(index) / Double(max(1, kick.count - 1))
            hit = max(hit, kick[index] * (1 - 0.9 * t))
        }
        // Critically damped toward the pool plus the held charge: the body flows out over
        // about 90 ms and drains over about 400 ms, with no overshoot to ring.
        let chargeTau = 0.08 / (quietFor > 0 ? 1.6 : 1)
        swellCharge = max(swellCharge * exp(-dt / chargeTau), min(1.0, hit * Self.swellBlow * loudGain))
        let target = pool + swellCharge
        let omega = target > swell ? 30.0 : 18.0
        swellVelocity += (omega * omega * (target - swell) - 2 * omega * swellVelocity) * dt
        swell = min(1.15, swell + swellVelocity * dt)
        if swell <= 0 { swell = 0; swellVelocity = max(0, swellVelocity) }
        if swell < 0.004, abs(swellVelocity) < 0.02 { swell = 0; swellVelocity = 0 }
    }

    private func updateSites(levels: [Float], dev: [Double], dt: Double) {
        var standing = 0.0
        // What every band hit together, taken off each one, so a full-mix crash raises the
        // bands that stood out of it rather than all seventeen as one wall.
        let common = kick.reduce(0, +) / Double(max(1, kick.count))
        // Quiet passages move less: hits are scaled by how near the music is to the loudest
        // it has been over the last several seconds, so a verse stays calm under a chorus.
        loudMemory = max(brightness, loudMemory * exp(-dt / Self.loudMemorySeconds))
        loudGain = pow(min(1, brightness / max(0.02, loudMemory)), Self.loudCurve)
        for index in sites.indices {
            let band = min(levels.count - 1, sites[index].band)
            let bandT = Double(band) / Double(max(1, levels.count - 1))
            // The charge holds the larger of its own decay and the newest hit: bass holds a
            // little longer than treble, and twice as briefly once the music has stopped.
            // A hit under the gate charges nothing, so small hits leave the ink still; the
            // gate is taken off the hit, not the charge, so a held lobe drains on its own
            // curve.
            let tau = (0.11 - 0.044 * bandT) / (quietFor > 0 ? 1.6 : 1)
            let hit = max(0, kick[band] - 1.3 * common) * Self.siteBlow * (1 + sites[index].fan)
            let gated = max(0, (min(1.2, hit * loudGain) - Self.siteGate) / (1.2 - Self.siteGate))
            sites[index].field = max(sites[index].field * exp(-dt / tau), 1.2 * gated)
        }
        // Only a few lobes may stand at once, more as the music gets busier, so each hit is
        // its own move rather than the whole rim breathing.
        surgeOpen *= exp(-dt / 0.3)
        let energy = max(surgeOpen, dev.reduce(0, +) / Double(max(1, dev.count)))
        let allowed = Self.fewestStanding + Int((min(1, energy) * Self.extraStanding).rounded())
        let rank = sites.indices.sorted { sites[$0].field > sites[$1].field }
        var mayStand = [Bool](repeating: false, count: sites.count)
        for index in rank.prefix(allowed) { mayStand[index] = true }
        for index in sites.indices {
            let band = min(levels.count - 1, sites[index].band)
            let bandT = Double(band) / Double(max(1, levels.count - 1))
            let target = mayStand[index] ? sites[index].field : 0
            // The lobe follows its charge critically damped, out at about 80 rad/s and home
            // at about 20: it is out in about 60 ms and drains over about 300 ms, never
            // overshooting. The step is the exact solution for the frame, so it starts from
            // rest without a jump and stays stable at any rate. Bass is heavy and treble
            // light, so treble both answers and drains a little quicker; one rate would
            // smooth every band into one breath, and a quick drain alone would leave the
            // treble lower than the bass for the same hit.
            var v = sites[index].velocity
            let weight = 0.8 + 0.4 * bandT
            let omega = target > sites[index].height ? 80.0 * weight : 20.0 * weight
            let c1 = sites[index].height - target, c2 = v + omega * c1, decay = exp(-omega * dt)
            var h = target + (c1 + c2 * dt) * decay
            v = (c2 - omega * (c1 + c2 * dt)) * decay
            if h <= 0 { h = 0; v = max(0, v) }
            if h > 1.25 { h = 1.25; v = min(0, v) }
            if h < 0.003, abs(v) < 0.05 { h = 0; v = 0 }
            sites[index].height = h
            sites[index].velocity = v
            sites[index].isUp = h > Self.standingHeight
            standing += h
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

/// The display link's target. The link retains its target, so this holds the simulation
/// weakly and the simulation ends the link with `invalidate`.
@MainActor
private final class DisplayTick: NSObject {
    let body: (CADisplayLink) -> Void
    init(_ body: @escaping (CADisplayLink) -> Void) { self.body = body }
    @objc func fire(_ link: CADisplayLink) { body(link) }
}
