import Foundation
import Observation

/// Frequency-band levels from the real system-audio mixdown.
///
/// If capture is unavailable, the levels decay to silence. Inventing a clock-
/// driven substitute makes the fluid look periodic and can keep it moving after
/// the music stops, which is worse than an honestly quiet visualiser.
@MainActor
@Observable
final class AudioLevels {
    /// Read once, not 30 times a second on the main actor.
    nonisolated static let debugLogging =
        ProcessInfo.processInfo.environment["NOTCH_AUDIO_DEBUG"] != nil


    static let bandCount = AudioTap.bandCount

    /// Below this in every band there is no sound — roughly -69 dBFS.
    ///
    /// Shared with `FerrofluidSim`, which needs the same definition of silence to
    /// tell a pause from a rest. Two thresholds that disagree would leave a
    /// window where this class publishes silence and the fluid still calls it
    /// music.
    nonisolated static let silenceLevel: Float = 0.02

    private(set) var bands = [Float](repeating: 0, count: AudioTap.bandCount)
    private(set) var isLive = false
    private(set) var permissionNote: String?


    private let tap = AudioTap()
    private var pump: Task<Void, Never>?
    private var consumers = 0
    /// Reused across ticks: `levels(into:)` exists so the tap never has to
    /// share its buffer with the real-time thread, and reusing the destination
    /// keeps this side from allocating 30 times a second in exchange.
    private var liveScratch = [Float](repeating: 0, count: AudioTap.bandCount)
    /// One rebuild per stall episode. Reset when delivery resumes, so a tap
    /// that stalls again later gets one more attempt — but a tap that stays
    /// wedged is reported, not hammered.
    private var stallRebuildAttempted = false

    /// Refcounted like the media poller: nothing runs when nothing is on screen.
    func addConsumer() {
        consumers += 1
        if consumers == 1 { begin() }
    }

    func removeConsumer() {
        consumers = max(0, consumers - 1)
        if consumers == 0 { end() }
    }

    /// Try the tap again after the user has been to Privacy settings.
    ///
    /// Without this the one remediation the app advertises went nowhere: you
    /// granted the permission and the visualiser stayed flat until playback
    /// stopped entirely or the app was relaunched. `startSync` already guards on
    /// `_isRunning`, so calling it while healthy is a no-op.
    func retryCapture() {
        guard consumers > 0, !tap.isRunning else { return }
        tap.start()
    }

    private func begin() {
        stallRebuildAttempted = false
        tap.start()
        pump?.cancel()
        pump = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(33))
                guard let self, !Task.isCancelled else { return }
                self.tick()
            }
        }
    }

    private func end() {
        pump?.cancel()
        pump = nil
        tap.stop()
        isLive = false
        bands = [Float](repeating: 0, count: Self.bandCount)
    }

    private func tick() {
        if tap.isRunning {
            // A tap can stop delivering while every status it exposes still
            // reads live — the tap's own teardown comment records exactly that
            // wedge. A stalled delivery stamp on a "running" tap means the
            // honest report is silence, not a freeze-frame of the last bands:
            // ask for one rebuild, and only if that fails to restore delivery
            // say so where the permission note is shown.
            if tap.deliveryIsStale() {
                if !stallRebuildAttempted {
                    stallRebuildAttempted = true
                    tap.rebuildStalled()
                } else {
                    let note = "capture stalled — rebuilding did not recover it"
                    if permissionNote != note { permissionNote = note }
                }
                if isLive { isLive = false }
                decayToSilence()
                return
            }
            stallRebuildAttempted = false
            tap.levels(into: &liveScratch)
            // A running tap that reads silence means there *is* no sound. Report
            // that honestly — falling back to synthesised motion here is what made
            // the visualiser churn away with the music switched off.
            if !liveScratch.contains(where: { $0 > Self.silenceLevel }) {
                if !isLive { isLive = true }
                decayToSilence()
                return
            }
            bands = liveScratch
            if Self.debugLogging {
                FileHandle.standardError.write(
                    ("[levels] " + liveScratch.map { String(format: "%.2f", $0) }.joined(separator: " ") + "\n")
                        .data(using: .utf8)!)
            }
            // Only on transition. These are observed, and Observation fires on
            // ASSIGNMENT — writing them every tick invalidated every view that
            // reads them 30 times a second to say nothing had changed.
            if !isLive { isLive = true }
            if permissionNote != nil { permissionNote = nil }
            return
        } else {
            // One `lastError` read per tick: the property takes the tap's state
            // lock each time, and two reads could straddle a mid-tick
            // transition and disagree.
            if isLive { isLive = false }
            let failure = tap.lastError
            if permissionNote != failure { permissionNote = failure }
        }
        decayToSilence()
    }

    private func decayToSilence() {
        // Already silent — don't rewrite an observed array of zeroes at 30Hz.
        guard bands.contains(where: { $0 > 0 }) else { return }
        for i in bands.indices {
            bands[i] *= 0.82
            if bands[i] < 0.002 { bands[i] = 0 }
        }
    }
}
