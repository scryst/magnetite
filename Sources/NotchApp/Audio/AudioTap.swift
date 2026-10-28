import AudioToolbox
import Accelerate
import AVFoundation
import CoreAudio
import Foundation

/// System-audio capture reduced to frequency-band levels.
///
/// Uses the macOS 14.4+ process tap: `CATapDescription` with a global stereo
/// mixdown, wrapped in a private aggregate device so an IOProc can be attached (a
/// tap alone is not a device frames can be pulled from).
///
/// The IOProc runs on a real-time audio thread. Nothing on that path allocates,
/// takes a long lock or touches the main actor: samples are windowed, FFT'd into
/// preallocated scratch, reduced to bands and published under a short unfair lock.
///
/// Needs the audio-capture TCC grant (`NSAudioCaptureUsageDescription`). If it is
/// refused, or any Core Audio step fails, `isRunning` stays false and callers decay
/// to silence rather than inventing motion.
final class AudioTap: @unchecked Sendable {

    static let bandCount = 12

    /// Which FFT bins each band sums: a monotone partition with no bin twice.
    ///
    /// Plain log spacing puts the first two bands in the same bin (1.000-1.682 and
    /// 1.682-2.828 both truncate to (1, 2)), so they publish identical values and the
    /// sim sites seated on them rise and fall in lockstep. Carrying the previous upper
    /// edge forward makes each band begin where the last ended: non-overlapping and
    /// gapless by construction.
    static func bandPartition(fftSize: Int, bandCount: Int) -> [(Int, Int)] {
        let half = fftSize / 2
        let minBin = 1.0, maxBin = Double(half - 1)
        var edges: [(Int, Int)] = []
        var lower = 1
        for b in 0..<bandCount {
            let hi = minBin * pow(maxBin / minBin, Double(b + 1) / Double(bandCount))
            // `lower + 1` keeps a band non-empty where the log step is narrower than a bin;
            // `half` is the exclusive end of `magnitudes`.
            let upper = min(half, max(lower + 1, min(half - 1, Int(hi))))
            edges.append((lower, upper))
            lower = upper
        }
        return edges
    }


    /// Published under `stateLock`: teardown runs on `queue` while callers read these
    /// from the main actor.
    private var stateLock = os_unfair_lock_s()
    private var _isRunning = false
    private var _lastError: String?

    var isRunning: Bool {
        os_unfair_lock_lock(&stateLock); defer { os_unfair_lock_unlock(&stateLock) }
        return _isRunning
    }
    var lastError: String? {
        os_unfair_lock_lock(&stateLock); defer { os_unfair_lock_unlock(&stateLock) }
        return _lastError
    }
    private func setState(running: Bool? = nil, error: String?? = nil) {
        os_unfair_lock_lock(&stateLock)
        if let running { _isRunning = running }
        if let error { _lastError = error }
        os_unfair_lock_unlock(&stateLock)
    }

    /// Whether a consumer still wants capture; stops a device change after `stop()`
    /// from resurrecting the tap.
    private var wantsRunning = false
    private var listenerInstalled = false
    /// Rebuild attempts left for the current device change. Queue-confined.
    private var rebuildRetries = 0

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    /// Lifecycle only: start, stop, teardown and the default-output listener.
    private let queue = DispatchQueue(label: "magnetite.audiotap", qos: .userInitiated)
    /// The IOProc's queue, and nothing else's.
    ///
    /// Core Audio delivers the IOProc by `dispatch_sync` onto the queue it was given,
    /// while holding its own IO mutex. Giving it `queue`, which teardown also runs on,
    /// is an ABBA deadlock: `AudioDeviceStop` blocks on that mutex on `queue` while the
    /// IO thread holds the mutex and waits for `queue`.
    ///
    ///     teardown -> AudioDeviceStop -> StopIOProc -> HALB_Mutex::Lock
    ///     audio.IOThread -> IOWorkLoop -> dispatch_sync -> wait for the lifecycle queue
    ///
    /// Nothing recovers from it. The wedge is upstream of `setState(running: false)`,
    /// so `isRunning` stays true, `levels()` keeps handing out stale bands and
    /// `retryCapture()` declines to act: every diagnostic reports healthy capture.
    private let ioQueue = DispatchQueue(label: "magnetite.audiotap.io",
                                        qos: .userInitiated)

    // FFT
    private let log2n: vDSP_Length = 10
    private var fftSize: Int { 1 << Int(log2n) }
    private var fftSetup: FFTSetup?
    private var window: [Float] = []
    /// First and last magnitude bin for each band; see `init`.
    private var bandEdges: [(Int, Int)] = []
    private var realBuf: [Float] = []
    private var imagBuf: [Float] = []
    private var magnitudes: [Float] = []
    private var mono: [Float] = []
    /// Rolling history, so the FFT always sees a full block. The output IOProc hands 512
    /// frames against a 1024-point FFT; windowing 512 samples plus 512 zeros applies
    /// only the Hann's rising half and leaves a step in the middle. Sidelobes then fall
    /// off at about 6 dB/octave instead of 18, and one bass note leaks across all the
    /// bands.
    private var ring: [Float] = []
    private var writeIndex = 0
    private var framesWritten = 0
    private var block: [Float] = []

    // Published levels
    private var lock = os_unfair_lock_s()
    private var bands = [Float](repeating: 0, count: AudioTap.bandCount)
    /// Band scratch for `computeBands`; a member because a fresh array per callback is
    /// a malloc on the real-time thread.
    private var outScratch = [Float](repeating: 0, count: AudioTap.bandCount)
    /// Continuous-clock tick of the last band publish, under `lock`. Armed at
    /// `startSync` success, so a device still warming up is measured from the start
    /// call.
    private var lastDeliveryTicks: UInt64 = 0

    init() {
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        // Built once beside the window: constant for the tap's life, and it saves 24
        // `pow` calls on the audio thread per callback.
        bandEdges = Self.bandPartition(fftSize: fftSize, bandCount: Self.bandCount)
        realBuf = [Float](repeating: 0, count: fftSize / 2)
        imagBuf = [Float](repeating: 0, count: fftSize / 2)
        magnitudes = [Float](repeating: 0, count: fftSize / 2)
        mono = [Float](repeating: 0, count: fftSize)
        ring = [Float](repeating: 0, count: fftSize)
        block = [Float](repeating: 0, count: fftSize)
    }

    deinit {
        // Synchronous: the object is going away, so teardown cannot be left queued.
        queue.sync { self.teardown() }
        if let fftSetup { vDSP_destroy_fftsetup(fftSetup) }
    }

    /// Copies the current band levels, 0...1, into caller-owned storage. `inout`
    /// rather than a returned array, which would share the buffer the IOProc mutates
    /// and make its next write pay a copy-on-write malloc under `lock` on the
    /// real-time thread. Any reallocation happens before the lock is taken.
    func levels(into out: inout [Float]) {
        out.withUnsafeMutableBufferPointer { dst in
            guard dst.count >= Self.bandCount else { return }
            os_unfair_lock_lock(&lock)
            for i in 0..<Self.bandCount { dst[i] = bands[i] }
            os_unfair_lock_unlock(&lock)
        }
    }

    /// How long a running tap may go without publishing bands before it is called
    /// stalled: longer than any device warm-up (Bluetooth takes over a second to its
    /// first callback), short enough to catch a frozen visualiser within a few frames.
    private static let stallThreshold: TimeInterval = 2

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// True when the tap claims to run but has not published bands for over
    /// `stallThreshold`. Every status this class exposes can read healthy while frames
    /// stop arriving; the delivery stamp cannot. The continuous clock counts sleep on
    /// purpose: after a wake the stamp reads stale and buys the rebuild a
    /// re-enumerated device usually needs.
    func deliveryIsStale() -> Bool {
        os_unfair_lock_lock(&lock)
        let last = lastDeliveryTicks
        os_unfair_lock_unlock(&lock)
        guard last != 0 else { return false }
        let now = mach_continuous_time()
        guard now > last else { return false }
        let elapsed = Double(now - last)
            * Double(Self.timebase.numer) / Double(Self.timebase.denom) / 1e9
        return elapsed > Self.stallThreshold
    }

    // MARK: Lifecycle

    func start() {
        queue.async { [weak self] in
            guard let self else { return }
            self.wantsRunning = true
            self.installDefaultOutputListener()
            self.startSync()
        }
    }

    /// Teardown is queued, never run on the caller's thread. Run inline, a stop could
    /// finish while a start is mid-flight and leave a live process tap and aggregate
    /// device that nothing can reach.
    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.wantsRunning = false
            self.teardown()
        }
    }

    /// One recovery attempt for a tap that claims to run but has stopped delivering.
    /// The caller bounds how often it asks; there is no retry here, since a tap that
    /// stalls straight after a rebuild needs reporting, not hammering.
    func rebuildStalled() {
        queue.async { [weak self] in
            guard let self, self.wantsRunning, self.isRunning else { return }
            self.log("delivery stalled — rebuilding tap")
            self.teardown()
            self.startSync()
        }
    }

    /// Core Audio teardown. Only ever called on `queue`, and asserted rather than
    /// assumed: the failure is a silent permanent hang, not a crash.
    private func teardown() {
        dispatchPrecondition(condition: .notOnQueue(ioQueue))
        if let procID, aggregateID != kAudioObjectUnknown {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = kAudioObjectUnknown
        }
        if tapID != kAudioObjectUnknown {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = kAudioObjectUnknown
        }
        setState(running: false)
    }

    /// Follows the default output device. The aggregate is built around the device that
    /// was default at start, so switching outputs would leave the tap bound to a device
    /// carrying no audio.
    private func installDefaultOutputListener() {
        guard !listenerInstalled else { return }
        listenerInstalled = true
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject), &addr, queue
        ) { [weak self] _, _ in
            guard let self, self.wantsRunning else { return }
            self.log("default output changed — rebuilding tap")
            self.rebuildRetries = 2
            self.teardown()
            self.startSync()
            self.scheduleRebuildRetryIfNeeded()
        }
    }

    /// Only the device-change path retries a failed start. A start refused for
    /// permission must not become an endless tap-create loop, but a rebuild against a
    /// device mid-handoff (AirPods switching hosts) can fail once while it settles.
    /// Each notification re-arms the budget, so a refused permission costs at most two
    /// extra attempts per device change.
    private func scheduleRebuildRetryIfNeeded() {
        guard wantsRunning, !isRunning, rebuildRetries > 0 else { return }
        rebuildRetries -= 1
        queue.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self, self.wantsRunning, !self.isRunning else { return }
            self.startSync()
            self.scheduleRebuildRetryIfNeeded()
        }
    }

    private func startSync() {
        guard !_isRunning else { return }

        // 1. Global stereo mixdown of everything currently playing.
        let desc = CATapDescription(stereoGlobalTapButExcludeProcesses: [])
        desc.uuid = UUID()
        desc.name = "Magnetite Visualiser Tap"
        desc.isPrivate = true
        // Never alter what the user hears.
        desc.muteBehavior = .unmuted

        var status = AudioHardwareCreateProcessTap(desc, &tapID)
        guard status == noErr, tapID != kAudioObjectUnknown else {
            let message = "process tap failed (\(status)) — audio-capture permission?"
            setState(error: message)
            log(message)
            return
        }

        guard let outputUID = defaultOutputDeviceUID() else {
            let message = "no default output device"
            setState(error: message)
            log(message)
            teardown()
            return
        }

        // 2. Private aggregate device carrying the tap, so it can be read.
        let aggUID = UUID().uuidString
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Magnetite Visualiser",
            kAudioAggregateDeviceUIDKey: aggUID,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapDriftCompensationKey: true,
                kAudioSubTapUIDKey: desc.uuid.uuidString,
            ]],
        ]

        status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID)
        guard status == noErr, aggregateID != kAudioObjectUnknown else {
            let message = "aggregate device failed (\(status))"
            setState(error: message)
            log(message)
            teardown()
            return
        }

        // 3. Pull frames, on `ioQueue` and never `queue` (see `ioQueue`).
        status = AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, ioQueue) {
            [weak self] _, inInputData, _, _, _ in
            self?.consume(inInputData)
        }
        guard status == noErr, procID != nil else {
            let message = "IOProc failed (\(status))"
            setState(error: message)
            log(message)
            teardown()
            return
        }

        status = AudioDeviceStart(aggregateID, procID)
        guard status == noErr else {
            let message = "device start failed (\(status))"
            setState(error: message)
            log(message)
            teardown()
            return
        }

        setState(running: true, error: .some(nil))
        // Arm the staleness clock from the start call, so a tap that never delivers a
        // frame still goes stale.
        os_unfair_lock_lock(&lock)
        lastDeliveryTicks = mach_continuous_time()
        os_unfair_lock_unlock(&lock)
        log("live — capturing system audio")
    }

    /// One line on stderr either way: whether the tap got its permission is the most
    /// useful fact when the visualiser looks wrong.
    private func log(_ message: String) {
        FileHandle.standardError.write("[audio] \(message)\n".data(using: .utf8)!)
    }

    private func defaultOutputDeviceUID() -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &deviceID) == noErr,
              deviceID != kAudioObjectUnknown else { return nil }

        addr.mSelector = kAudioDevicePropertyDeviceUID
        // `Unmanaged`, not a bare `CFString`: Core Audio writes a +1 reference into
        // the buffer, and a strongly held Swift variable would be clobbered and the
        // returned retain leaked.
        var uid: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &uidSize, &uid) == noErr,
              let value = uid
        else { return nil }
        return value.takeRetainedValue() as String
    }

    // MARK: Real-time path

    /// Internal rather than private so `site/test/bandsprobe.swift` can feed synthesised
    /// PCM through the real pipeline (ring, window, FFT, partition, meter) to dump the
    /// goldens the site's port is checked against.
    func consume(_ bufferList: UnsafePointer<AudioBufferList>) {
        let abl = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: bufferList))
        guard let first = abl.first,
              let raw = first.mData,
              first.mDataByteSize > 0 else { return }

        let available = Int(first.mDataByteSize) / MemoryLayout<Float>.size
        let channels = max(1, Int(first.mNumberChannels))
        let frames = min(fftSize, available / channels)
        // No minimum block size: a device running 32-frame buffers would trip a minimum
        // on every callback, the bands would freeze while `isLive` stayed true.
        guard frames > 0 else { return }

        let samples = raw.assumingMemoryBound(to: Float.self)

        // Interleaved to mono for just this block.
        block.withUnsafeMutableBufferPointer { dst in
            if channels == 1 {
                dst.baseAddress!.update(from: samples, count: frames)
            } else {
                var scale = 1.0 / Float(channels)
                vDSP_vclr(dst.baseAddress!, 1, vDSP_Length(frames))
                for c in 0..<channels {
                    vDSP_vadd(dst.baseAddress!, 1,
                              samples + c, vDSP_Stride(channels),
                              dst.baseAddress!, 1, vDSP_Length(frames))
                }
                vDSP_vsmul(dst.baseAddress!, 1, &scale,
                           dst.baseAddress!, 1, vDSP_Length(frames))
            }
        }

        // Append into the ring in at most two contiguous runs. The wrap happens at most
        // once, so finding it is cheaper than testing for it on every frame.
        var idx = writeIndex
        block.withUnsafeBufferPointer { src in
            ring.withUnsafeMutableBufferPointer { dst in
                var offset = 0
                while offset < frames {
                    let run = min(fftSize - idx, frames - offset)
                    dst.baseAddress!.advanced(by: idx)
                        .update(from: src.baseAddress!.advanced(by: offset), count: run)
                    idx = (idx + run) % fftSize
                    offset += run
                }
            }
        }
        writeIndex = idx
        framesWritten &+= frames
        guard framesWritten >= fftSize else { return }

        // Copy the latest fftSize samples out in chronological order so the window is
        // applied to a continuous block.
        let head = fftSize - writeIndex
        mono.withUnsafeMutableBufferPointer { dst in
            ring.withUnsafeBufferPointer { src in
                dst.baseAddress!.update(from: src.baseAddress! + writeIndex, count: head)
                if writeIndex > 0 {
                    (dst.baseAddress! + head).update(from: src.baseAddress!, count: writeIndex)
                }
            }
        }

        // In place through one pointer: passing `mono` as both input and `&mono` output
        // makes Swift copy the array, a 4 KB malloc on the IO thread about 86 times a
        // second.
        mono.withUnsafeMutableBufferPointer { m in
            vDSP_vmul(m.baseAddress!, 1, window, 1, m.baseAddress!, 1, vDSP_Length(fftSize))
        }
        computeBands()
    }

    private func computeBands() {
        guard let fftSetup else { return }
        let half = fftSize / 2

        realBuf.withUnsafeMutableBufferPointer { realPtr in
            imagBuf.withUnsafeMutableBufferPointer { imagPtr in
                var split = DSPSplitComplex(realp: realPtr.baseAddress!,
                                            imagp: imagPtr.baseAddress!)
                mono.withUnsafeBufferPointer { src in
                    src.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: half) {
                        vDSP_ctoz($0, 2, &split, 1, vDSP_Length(half))
                    }
                }
                vDSP_fft_zrip(fftSetup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                magnitudes.withUnsafeMutableBufferPointer { mag in
                    vDSP_zvabs(&split, 1, mag.baseAddress!, 1, vDSP_Length(half))
                    // vDSP's real FFT returns magnitudes scaled by 2N; undo that or every band
                    // saturates.
                    var scale = Float(1) / Float(2 * self.fftSize)
                    vDSP_vsmul(mag.baseAddress!, 1, &scale,
                               mag.baseAddress!, 1, vDSP_Length(half))
                }
            }
        }

        // Log-spaced bins, since pitch perception is logarithmic and linear bands put
        // almost everything in the first bar. The edges depend only on `fftSize`, so they
        // are computed once; this runs about 86 times a second on the audio thread.
        for b in 0..<Self.bandCount {
            let (i0, i1) = bandEdges[b]
            var sum: Float = 0
            for i in i0..<i1 { sum += magnitudes[i] }
            let mean = sum / Float(i1 - i0)
            // dB, then normalised into a range that uses the full height.
            let db = 20 * log10(max(mean, 1e-7))
            // Music sits roughly in -70...-15 dBFS per band.
            outScratch[b] = min(1, max(0, (db + 70) / 55))
        }

        os_unfair_lock_lock(&lock)
        // Attack fast, release slow, as a level meter does. The attack is nearly a step:
        // at 0.55 a kick took three callbacks to land and the ink trailed the bass by a
        // frame it did not need to.
        for i in 0..<Self.bandCount {
            bands[i] = outScratch[i] > bands[i]
                ? bands[i] + (outScratch[i] - bands[i]) * 0.85
                : bands[i] + (outScratch[i] - bands[i]) * 0.16
        }
        lastDeliveryTicks = mach_continuous_time()
        os_unfair_lock_unlock(&lock)
    }
}
