import Foundation
import Observation

/// Frequency-band levels from the system-audio mixdown.
///
/// If capture is unavailable the levels decay to silence. A clock-driven
/// substitute would look periodic and keep moving after the music stops.
@MainActor
@Observable
final class AudioLevels {
    /// Read once rather than 30 times a second on the main actor.
    nonisolated static let debugLogging =
        ProcessInfo.processInfo.environment["NOTCH_AUDIO_DEBUG"] != nil


    static let bandCount = AudioTap.bandCount

    /// Below this in every band there is no sound (about -69 dBFS).
    ///
    /// `FerrofluidSim` uses the same value to tell a pause from a rest; two
    /// thresholds that disagreed would leave a window where this class publishes
    /// silence and the fluid still treats it as music.
    nonisolated static let silenceLevel: Float = 0.02

    private(set) var bands = [Float](repeating: 0, count: AudioTap.bandCount)
    private(set) var isLive = false
    private(set) var permissionNote: String?


    private let tap = AudioTap()
    private var pump: Task<Void, Never>?
    private var consumers = 0
    /// Reused across ticks so that `levels(into:)`, which keeps the tap's buffer away
    /// from the real-time thread, does not allocate 30 times a second.
    private var liveScratch = [Float](repeating: 0, count: AudioTap.bandCount)
    /// One rebuild per stall episode. Reset when delivery resumes, so a later stall
    /// gets another attempt but a tap that stays wedged is reported, not retried.
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

    /// Tries the tap again after the user has been to Privacy settings. `start()` is a
    /// no-op while the tap is running.
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
            // A tap can stop delivering while every status it exposes still reads live. A
            // stale delivery stamp on a "running" tap means the honest report is silence:
            // ask for one rebuild, and if that does not restore delivery, say so in the
            // permission note.
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
            // A running tap that reads silence means there is no sound; no synthesised
            // motion in its place.
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
            // Observation fires on assignment, so only write these on a transition.
            if !isLive { isLive = true }
            if permissionNote != nil { permissionNote = nil }
            return
        } else {
            // One `lastError` read per tick: it takes the tap's state lock, and two reads
            // could straddle a transition.
            if isLive { isLive = false }
            let failure = tap.lastError
            if permissionNote != failure { permissionNote = failure }
        }
        decayToSilence()
    }

    private func decayToSilence() {
        // Already silent: do not rewrite an observed array of zeroes at 30 Hz.
        guard bands.contains(where: { $0 > 0 }) else { return }
        for i in bands.indices {
            bands[i] *= 0.82
            if bands[i] < 0.002 { bands[i] = 0 }
        }
    }
}
