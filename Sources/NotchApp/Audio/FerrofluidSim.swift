import Foundation
import Observation

/// Ferrofluid physics, modelled on the Rosensweig (normal-field) instability.
///
/// A ferrofluid surface is flat until the local field crosses a critical value,
/// then throws a lattice of conical peaks. Hysteresis lets a peak hold briefly
/// after the hit and viscously drain back into the shared pool without ringing.
///
/// Every quantity is driven by captured audio. There are no clock oscillators,
/// no springs, and nothing that detaches or expires: each band's site rises and
/// falls, and the renderer turns those into mounds in one continuous surface.
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
        var field: Double
        var isUp: Bool
    }

    @ObservationIgnored private(set) var sites: [Site] = []
    /// Bass energy displaces the whole continuous reservoir.
    @ObservationIgnored private(set) var swell: Double = 0
    /// Ink standing in peaks; the shared pool sinks by this amount.
    @ObservationIgnored private(set) var raised: Double = 0



    /// How hard the music just hit, 0…1. Drives the rim glow.
    ///
    /// Taken from the largest per-band transient, so it spikes on an onset and
    /// decays — it is an *event* measure, never a level.
    @ObservationIgnored private(set) var impact: Double = 0

    /// How open the INK is, which is not how open the shell is.
    ///
    /// `openness` is the shell's spring and the ink was driven straight off it,
    /// so the two arrived together — and opening in silence produced no ink
    /// motion at all, because with no lobes and no swell `displacement` returns
    /// exactly 0. A fluid should wash in behind the chrome. This follows the
    /// shell asymmetrically: slow to fill, quick to drain.
    @ObservationIgnored private(set) var inkOpen: Double = 0
    private var openTarget: Double = 0

    /// Reduce Motion takes the travel out of the open: the ink closes the gap to
    /// the shell sooner, so there is less of a journey to watch.
    var reduceMotion = false

    /// True while something is actually driving `advance`.
    ///
    /// `isSettled` is what pauses the renderer, so clearing it without a clock
    /// leaves TimelineView redrawing 144 samples at 60Hz over a picture that
    /// cannot change. Every writer that clears the gate must also guarantee this.
    var isDriven: Bool { running != nil }

    /// Clear the settled gate and guarantee something will recompute it.
    private func wake() {
        if isSettled { isSettled = false }
        runClock()
    }

    /// The shell moved. Called with the AGGREGATE across displays, never with one
    /// controller's state — the sim is shared and the controllers are not.
    func setOpen(_ open: Bool) {
        // Idempotent: the coordinator broadcasts the aggregate, so the same value
        // arrives once per display.
        let t = open ? 1.0 : 0.0
        guard t != openTarget else { return }
        openTarget = t
        wake()
    }

    /// Below this the halo is not drawn at all — at a 0.01 threshold it was lit
    /// almost continuously, which is a full extra silhouette paint and a blur on
    /// every frame.
    nonisolated static let glowGate = 0.14
    /// The last stretch of the decay, over which the halo eases out instead of
    /// being cut off at the gate.
    nonisolated static let glowFade = 0.10

    /// The halo's alpha, eased to nothing at the gate.
    ///
    /// The gate is a hard threshold, so the bloom used to appear and disappear at
    /// alpha 0.1868 in a single frame — the largest per-frame change anywhere in
    /// the effect was the moment it switched off, which reads as a bug rather
    /// than as light. A smoothstep across the last 0.10 of the decay takes the
    /// worst step from 0.1907 to 0.0337, and leaves every tuned value at or above
    /// 0.24 unchanged to the digit (1.0 -> 0.7200, 0.5 -> 0.4100).
    ///
    /// `nonisolated` because it is a pure function of its arguments; the class is
    /// `@MainActor` and the renderer needs this off the observation path.
    nonisolated static func glowAlpha(impact: Double, openness: Double) -> Double {
        let t = min(1, max(0, (impact - glowGate) / glowFade))
        let ease = t * t * (3 - 2 * t)
        return (0.10 + 0.62 * impact) * ease * min(1, max(0, openness))
    }
    /// Phase for the colour field behind the ink, advanced **only** by audio.
    ///
    /// The field used to run off `timeline.date`, which meant it swept and
    /// breathed on a wall clock whether or not anything was playing — a visible
    /// ~4.8s cycle sitting behind ink that was working hard not to be periodic.
    /// Integrating loudness instead means the field moves as far as the music
    /// moves it and stalls when the music stops. There is no constant term: a
    /// clock advances the integration, it never creates motion.
    @ObservationIgnored private(set) var flowPhase: Double = 0
    /// Smoothed loudness, 0…1, for intensity. Replaces a `sin(t)` breath.
    @ObservationIgnored private(set) var brightness: Double = 0

    /// Observed, and written ONLY when it flips.
    ///
    /// This used to be computed from swell, impact and every site — all of which
    /// are rewritten sixty times a second. Observation fires on *assignment*, not
    /// on change, so any view reading it was invalidated 60x/s and the `paused:`
    /// flag it feeds could never actually stop anything: the still picture was
    /// re-rendered throughout the settling tail after every quiet passage. The
    /// Every hot field is untracked now — the display link drives redraws, which
    /// is what it is for — and these two Bools are the only observable surface.
    /// The count is deliberately not written down; it has grown twice since.
    private(set) var isSettled = true
    /// True while there is sound. Gates the colour field's timeline.
    private(set) var hasSound = false

    private func publishGates() {
        let e = Self.settledEpsilon
        let settled = swell < e && impact < e && pointerPull < e
            && inkOpen == openTarget
            && !sites.contains { $0.height > 0.003 }
        if settled != isSettled { isSettled = settled }
        let sound = brightness >= 0.002
        if sound != hasSound { hasSound = sound }
    }

    /// Read once. It was `ProcessInfo.processInfo.environment[...]` inside
    /// `updateSites`, i.e. a dictionary build and lookup 60 times a second on the
    /// main actor, to decide not to print.
    nonisolated static let debugLogging =
        ProcessInfo.processInfo.environment["NOTCH_FLUID_DEBUG"] != nil

    /// Below this a field is treated as zero.
    ///
    /// `updateImpact` snapped at 0.002 while `publishGates` called settled at
    /// 0.004, so impact could sit in the gap: small enough for the gate to
    /// early-return, too large for the snap to ever run. It froze at 0.00395 and
    /// stayed there, which is why a check that stepped "until impact == 0" hung.
    static let settledEpsilon = 0.004

    nonisolated static let siteCount = 17
    /// Raised so fewer sites break at once. Eight middling lobes read as a
    /// ripple; three decisive ones read as ferrofluid answering the music.
    ///
    /// Internal rather than private so fluidcheck can hold its held-loudness
    /// margin against the real value instead of a copy of the number.
    let criticalField = 0.36
    private let collapseField = 0.16


    private var running: Task<Void, Never>?
    private weak var audio: AudioLevels?
    private var previousLevels: [Float] = []
    private var kick: [Double] = []
    /// A surge that arrived before there was anything to apply it to.
    private var pendingSurge: (strength: Double, direction: Double)?

    /// Where the pointer is along the rim, 0…1, or nil when it is away.
    ///
    /// The ink is magnetic, and the one magnet it has never responded to is the
    /// user's own hand. A cursor moving along the notch now drags a swell with
    /// it — the surface leans toward you. It is the cheapest possible way to make
    /// the thing feel alive when no music is playing at all.
    @ObservationIgnored private(set) var pointerRim: Double = 0.5
    /// Where the cursor actually is. `pointerRim` chases this.
    private var pointerRimTarget: Double = 0.5
    /// How much of that pull is currently applied, eased so the ink does not snap
    /// to attention the instant the pointer crosses the boundary.
    @ObservationIgnored private(set) var pointerPull: Double = 0

    private var pointerTarget: Double = 0

    /// Called from the coordinator on every mouse move.
    func setPointer(rim: Double?, strength: Double = 1) {
        if let rim {
            // Only the TARGET moves with the cursor. The swell itself chases it
            // viscously below — setting the position directly made the bulge
            // teleport along the rim, tracking the pointer rigidly instead of
            // being dragged by it, which is the opposite of what a heavy liquid
            // does.
            pointerRimTarget = min(1, max(0, rim))
            pointerTarget = min(1.6, max(0, strength))
            // Wake the renderer. It is gated on isSettled, and the pointer
            // arriving is precisely the case where nothing else will clear it —
            // including, since the clock learned to retire, the case where there
            // is no clock to recompute the gate either.
            wake()
        } else {
            pointerTarget = 0
        }
    }
    private var baseline: [Double] = []
    private var spread: [Double] = []
    /// The spread `deviation` starts every band at, and returns to on re-entry.
    private static let initialSpread = 0.06

    /// How long every band must sit under `AudioLevels.silenceLevel` before the
    /// next audio counts as re-entry rather than as a transient.
    ///
    /// The levels themselves take about 0.6s to decay under that threshold after
    /// sound stops, so this is roughly a second of real silence — far longer than
    /// any rest inside a track, and far shorter than a pause.
    private static let reentryAfter = 0.35
    private var quietFor = 0.0

    /// Resuming is not an onset.
    ///
    /// Both of the sim's inputs measure CHANGE against a remembered past, and a
    /// pause poisons that memory: `previousLevels` tracks the decay to zero, and
    /// `baseline`/`spread` freeze near zero once the settled early-return stops
    /// calling `deviation`. So the first frame of audio after a pause reads as a
    /// full-scale event twice over — `rise` is the whole level, so `kick` hits
    /// its ceiling, and `delta / max(0.035, spread * 1.6)` divides a half-scale
    /// jump by the floor, giving a deviation around 14 where music gives ~1.
    ///
    /// Replaying this repo's own `Resources/real-levels.txt` with four seconds of
    /// silence cut into the middle, and scoring the twelve frames after audio
    /// returns against the loudest frame of the steady replay: the resume heaved
    /// the body to swell 0.973 and peak height 0.997, where the music's own peak
    /// is 0.879. That is the saturation wall `realMusicDoesNotSaturateIt` exists
    /// to forbid, reached in the one window that check never enters, by the
    /// analyser rather than by the music. Afterwards the resume peaks at 0.468.
    ///
    /// Re-seeding the memory to the incoming levels makes that frame a non-event:
    /// no rise, no deviation, and the music's own dynamics take over on the very
    /// next frame. It is not a fade-in and it injects nothing — it just declines
    /// to report the analyser's own discontinuity as a drum hit.
    ///
    /// `spread` is deliberately NOT reset. It is the only memory of how wide this
    /// track's swings are, and a pause is no evidence that they changed. Resetting
    /// it to `initialSpread` was tried and measured: it merely moved the slam one
    /// frame later, because every following frame then divided its distance from
    /// the new baseline by a cold 0.06 and swell pinned at 0.97 within five
    /// frames. Keeping it is also the conservative direction — a stale spread
    /// under-reacts for the 2.5s it takes to re-adapt, and under-reacting is not
    /// what anyone notices.
    private func reenter(_ levels: [Float]) {
        previousLevels = levels
        baseline = levels.map(Double.init)
    }

    func start(audio: AudioLevels) {
        self.audio = audio
        runClock()
    }

    /// Lets go of the audio without dropping the picture.
    ///
    /// `stop()` zeroes every field at once, which is right when nothing is on
    /// screen and a visible jump when something is: three seconds after a
    /// pause, the ink snapped fully open or shut under a pointer that was still
    /// pulling it, and the glow switched off. Here the clock runs on silence
    /// until the ink comes to rest and then retires itself, as it does after an
    /// idle open.
    func release() {
        audio = nil
        runClock()
    }

    /// The 16ms tick.
    ///
    /// It used to begin and end with the audio consumer, which meant that with no
    /// track there was no clock — so opening the idle panel did not move the ink at
    /// all, the one state where the ink has nothing else to do. The tap is the
    /// expensive part, not this; the loop ends itself as soon as nothing is
    /// feeding it and the fluid has come to rest, so an idle open costs the
    /// ~0.5s the ink actually takes to arrive, not a timer held open for the session.
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
        raised = 0
        impact = 0
        previousLevels = []
        kick = []
        quietFor = 0
        pendingSurge = nil
        inkOpen = openTarget
        baseline = []
        spread = []
        // LAST, after every field it reads. Publishing before `sites` was cleared
        // computed isSettled from stale state, pinned it false, and left the
        // renderer running at 60fps for the rest of the session.
        publishGates()
    }

    private func step(dt: Double) {
        // Silence rather than a bail-out: with no track there is still a panel to
        // open, and the open is not made of audio.
        advance(levels: audio?.bands ?? Self.silence, dt: dt)
    }

    private static let silence = [Float](repeating: 0, count: AudioTap.bandCount)

    /// The physics, with the audio plumbing removed so it can be driven directly.
    ///
    /// Everything the fluid is judged on — that it reacts to change rather than
    /// loudness, that the surface is not a comb, that silence is genuinely still —
    /// is a property of this function, and `tools/fluidcheck.swift` asserts each
    /// one against synthetic spectra.
    func advance(levels: [Float], dt: Double) {
        guard !levels.isEmpty else { return }

        // The pointer pull is independent of audio, so it is integrated BEFORE
        // the settled early-return below. Viscous, like everything else here: it
        // arrives and leaves at a fluid's pace rather than tracking rigidly.
        // The ink follows the shell before the settled early-return, for the
        // same reason the pointer does: the panel moving is independent of audio.
        //
        // Two rate laws, both state-dependent. Filling starts slow and
        // accelerates, so the ink is visibly behind the chrome early and still
        // catches it; draining starts fast and eases, so it beats the closing
        // shell home rather than being caught by the clip.
        let scale = reduceMotion ? 2.6 : 1.0
        let openRate = (openTarget > inkOpen ? (1.4 + 10.0 * inkOpen)
                                             : (8.0 + 16.0 * (1 - inkOpen))) * scale
        inkOpen += (openTarget - inkOpen) * min(1, openRate * dt)
        if openTarget == 1, inkOpen > 0.98 { inkOpen = 1 }
        if openTarget == 0, inkOpen < 0.02 { inkOpen = 0 }

        // NOTE: opening deliberately injects NO energy.
        //
        // It used to feed the kick, the swell and the glow, so the panel opening
        // manufactured a beat — and with nothing playing that is a drum hit with
        // no drum, which is exactly what PRODUCT.md's second design principle
        // forbids: audio causes events, a clock only advances the simulation.
        // The open is not audio. It moves the ink's SHAPE, through `inkOpen`
        // below — `room`, `seatU` and the lateral terms all key off it, so the
        // body still washes in from the cutout — and never its energy.

        let pullRate = pointerTarget > pointerPull ? 7.0 : 3.4
        pointerPull += (pointerTarget - pointerPull) * min(1, pullRate * dt)
        if pointerPull < 0.002 { pointerPull = 0 }
        // The swell lags the cursor. Slow enough to read as mass being dragged,
        // fast enough that it arrives while you are still there.
        pointerRim += (pointerRimTarget - pointerRim) * min(1, 5.0 * dt)

        // Ahead of the early-return, because the silence being timed is exactly
        // the state that early-returns.
        if levels.contains(where: { $0 > AudioLevels.silenceLevel }) {
            if quietFor >= Self.reentryAfter { reenter(levels) }
            quietFor = 0
        } else {
            quietFor += dt
        }

        // Nothing to advance: silent, and every part of the fluid already home.
        // Writing observed state 60x a second for a completely static picture
        // kept SwiftUI re-evaluating the whole panel while the user was idle.
        if sites.count == Self.siteCount, isSettled, brightness < 0.002,
           pointerTarget == 0, pointerPull == 0,
           inkOpen == openTarget,
           !levels.contains(where: { $0 > 0.004 }) {
            return
        }

        if sites.count != Self.siteCount { seed(levels: levels) }
        updateKick(levels: levels, dt: dt)
        let dev = deviation(levels, dt: dt)
        updateSwell(levels: levels, dev: dev, dt: dt)
        updateFlow(levels: levels, dt: dt)
        updateImpact(dt: dt)
        publishGates()
        updateSites(levels: levels, dev: dev, dt: dt)
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
    }

    /// Positive band rise gives the surface its immediate attack.
    private func updateKick(levels: [Float], dt: Double) {
        if kick.count != levels.count {
            kick = [Double](repeating: 0, count: levels.count)
            previousLevels = levels
        }
        if let held = pendingSurge {
            pendingSurge = nil
            surge(held.strength, direction: held.direction)
        }

        let decay = pow(0.05, dt)
        for index in levels.indices {
            let rise = Double(max(0, levels[index] - previousLevels[index]))
            kick[index] = max(kick[index] * decay, min(1, rise * 8))
        }
        previousLevels = levels
    }

    /// Each band is measured against its own recent norm, so quiet and loud
    /// tracks get comparable dynamic range without a scripted gain envelope.
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

    /// Slam the reservoir.
    ///
    /// A real event, not a clock: a track change is exactly as much of an event
    /// as a drum hit, so it goes in through the same door. The impulse is
    /// weighted toward the low end like a downbeat, and from there the ordinary
    /// physics takes over — it surges, breaks, and settles on its own. Nothing
    /// about the motion is scripted; only the trigger is.
    /// `direction` is +1 for a skip forward, -1 for back, 0 for anything with no
    /// direction — a press, or a track simply ending.
    ///
    /// Forward and back used to produce the identical heave, so the ink said a
    /// track had changed but never which way you went. The profile is mirrored
    /// rather than travelling: a moving front was tried and measured, and it
    /// reads as a pile at the WRONG end for the first ~0.27s, because on a flat
    /// spectrum `allowed` is 2 and `isUp` hysteresis pins whichever two sites
    /// rose first — at the front's entry end. The crest never overtakes its own
    /// wake. The mirror is unambiguous at every frame, carries no persistent
    /// state, and 0 keeps the existing shape byte for byte.
    func surge(_ strength: Double = 1, direction: Double = 0) {
        // Both exits, including the held one — a surge with no clock is a surge
        // that either never decays or never arrives.
        //
        // This is the failure the self-cancelling clock introduced. Before it,
        // the clock ran exactly start() -> stop() and stop() empties `kick`, so
        // "no clock but kick still sized" could not happen and surge always took
        // the pendingSurge branch, which publishes nothing. Now an idle pour
        // sizes `kick` and then the clock retires, so the next swipe takes the
        // MAIN path: impact and swell are set, publishGates clears isSettled, and
        // nothing is left to decay them. Re-entrancy safe — updateKick calls back
        // in for a held surge while the clock runs, and runClock no-ops.
        defer { runClock() }
        guard !kick.isEmpty else {
            // `kick` is sized on the first step tick, not in `start()`, so a
            // track change arriving in that window has no per-band array to
            // inject into. Hold it rather than dropping it: the first song of a
            // session is exactly when the reaction matters most.
            // The stronger wins, and a real direction beats none.
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
        // Republish immediately. `advance` early-returns while `isSettled` is
        // true, and isSettled is a stored value — so a surge into a settled fluid
        // set the state and was then skipped by the very next step, which is
        // exactly the case a track change during a quiet passage produces.
        publishGates()
    }

    private func updateImpact(dt: Double) {
        let hit = kick.max() ?? 0
        // Fast up, slow down: a hit should read instantly and leave an afterglow.
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
        let bass = dev.prefix(count).reduce(0, +) / Double(count)
        let target = min(1, bass * 0.8)
        let rate = target > swell ? 22.0 : 5.5
        swell += (target - swell) * min(1, rate * dt)
        if swell < 0.004 { swell = 0 }
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
            let raw = min(1, dev[band] * 0.5 + kick[band] * 0.8)

            let fieldRate = raw > sites[index].field ? 40.0 : 9.0
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
                // Power law, not a floor plus a curve. The old form —
                // min(1, 0.32 + 0.68 * pow(excess, 0.6)) — floored every
                // standing peak at 0.32 and at onset actually produced 0.6074,
                // so the whole crown occupied a 1.65:1 range, which on screen is
                // a row of spikes of nearly equal height whatever the music
                // does. That is the "same-height spike comb" the contract rules
                // out. This spans 0.1441...1.0, a 6.94:1 range, so a quiet band
                // is a ripple and a hit is a spire. Onset is still a finite pop,
                // so the subcritical hysteresis above is intact.
                //
                // BOTH ratios are quoted at the shipping field, because both are
                // functions of criticalField rather than constants beside it:
                // onset is pow((criticalField - collapseField) / (1 -
                // collapseField), 1.35) here, and 0.32 + 0.68 * pow(that same
                // excess, 0.6) in the old form. They read 0.089/11:1 and 1.8:1
                // for as long as the field was 0.30, and were left untouched
                // when 858889f raised it to 0.36 — here, in FerrofluidView's
                // restatement, and in the JS port, so one constant moving
                // stranded the same two figures in three places, and the
                // sentence ended up comparing a 0.30-era ratio against a
                // 0.36-era one.
                //
                // No check could have caught it: theCrownIsNotAComb measures the
                // span of the peaks one shaped spectrum actually raises, which
                // is a different quantity from this ratio, and only requires
                // that it exceed 3:1.
                target = min(1, pow(max(0, excess), 1.35))
            } else {
                target = 0
            }

            // Bass is heavy and drains slowly; treble is light and snaps back.
            // One drain rate for every band made the whole crown breathe as a
            // single object regardless of what the music was doing.
            let bandT = Double(band) / Double(max(1, levels.count - 1))
            let fall = 4.6 * (0.55 + 1.5 * bandT)
            let heightRate = target > sites[index].height ? 24.0 : fall
            sites[index].height += (target - sites[index].height) * min(1, heightRate * dt)
            if sites[index].height < 0.003 { sites[index].height = 0 }
            standing += sites[index].height
        }

        // Surface tension shares ink between neighbouring peaks. This is a
        // first-order diffusion only: no springs and no overshoot.
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
