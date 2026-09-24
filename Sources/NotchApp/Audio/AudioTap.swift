import AudioToolbox
import Accelerate
import AVFoundation
import CoreAudio
import Foundation

/// Real system-audio capture, reduced to frequency-band levels.
///
/// Uses the macOS 14.4+ **process tap**: `CATapDescription` with a global stereo
/// mixdown, wrapped in a private aggregate device so we can attach an IOProc.
/// A tap on its own is not a device you can pull frames from — the aggregate is
/// what makes it readable, which is the step that trips most implementations up.
///
/// The IOProc runs on a real-time audio thread. Nothing in that path allocates,
/// locks for long, or touches the main actor: samples are windowed, FFT'd into a
/// preallocated scratch buffer, reduced to bands, and published under a very
/// short unfair lock.
///
/// Requires the audio-capture TCC grant (`NSAudioCaptureUsageDescription`). If it
/// is refused, or any Core Audio step fails, `isRunning` stays false and callers
/// decay to silence rather than fabricating motion.
final class AudioTap: @unchecked Sendable {

    static let bandCount = 12

    /// Which FFT bins each band sums: a monotone partition, no bin twice.
    ///
    /// Log spacing put the first two bands inside the same bin. Band 0 ran
    /// 1.000–1.682 and band 1 ran 1.682–2.828; `Int()` truncation plus the
    /// non-empty floor sent BOTH to (1, 2), so both summed bin 1 alone and
    /// shipped bit-identical values — not occasionally, but in 240 of the 240
    /// frames of `Resources/real-levels.txt`, this repo's own capture of real
    /// music.
    ///
    /// That is not a rounding curiosity. `FerrofluidSim.seed` maps sites 0, 1
    /// and 2 to bands 0, 1 and 1, and `FerrofluidView.seatU` seats exactly those
    /// three on the left vertical run — the run whose own comment says the warp
    /// is there "so there are three peaks to tell apart". They were driven by one
    /// bin, so they rose and fell in lockstep: a same-height spike comb, the
    /// first anti-reference in PRODUCT.md, manufactured by the analyser rather
    /// than by the music. Twelve advertised bands were eleven.
    ///
    /// Carrying the previous upper edge forward makes each band begin where the
    /// last one ended, which is both non-overlapping and gapless by construction.
    static func bandPartition(fftSize: Int, bandCount: Int) -> [(Int, Int)] {
        let half = fftSize / 2
        let minBin = 1.0, maxBin = Double(half - 1)
        var edges: [(Int, Int)] = []
        var lower = 1
        for b in 0..<bandCount {
            let hi = minBin * pow(maxBin / minBin, Double(b + 1) / Double(bandCount))
            // `lower + 1` keeps a band from being empty where the log step is
            // narrower than a bin; `half` is the exclusive end of `magnitudes`.
            let upper = min(half, max(lower + 1, min(half - 1, Int(hi))))
            edges.append((lower, upper))
            lower = upper
        }
        return edges
    }


    /// Published under `stateLock`: `start`/`stop` teardown runs on `queue` while
    /// callers read these from the main actor.
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

    /// Whether a consumer still wants capture. Guards the rebuild path so a
    /// device change after `stop()` does not resurrect the tap.
    private var wantsRunning = false
    private var listenerInstalled = false
    /// Rebuild attempts left for the current device change. Queue-confined.
    private var rebuildRetries = 0

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    /// Lifecycle only: start, stop, teardown, and the default-output listener.
    private let queue = DispatchQueue(label: "magnetite.audiotap", qos: .userInitiated)
    /// The IOProc's queue, and nothing else's.
    ///
    /// Core Audio delivers the IOProc by `dispatch_sync`ing onto whichever queue
    /// it was handed, *while holding its own IO mutex*. Handing it `queue` — the
    /// queue teardown also runs on — is therefore an ABBA deadlock, and it is
    /// not a race: `AudioDeviceStop` runs on `queue` and blocks acquiring that
    /// mutex, while the IO thread holds the mutex and blocks waiting for `queue`.
    /// Sampling the shipped app caught both halves pinned for all 1653 samples
    /// of a two-second window (quoted as recorded, under the queue label this
    /// app carried before it was renamed):
    ///
    ///     notchapp.audiotap  teardown -> AudioDeviceStop -> StopIOProc -> HALB_Mutex::Lock
    ///     audio.IOThread     IOWorkLoop -> dispatch_sync -> wait for notchapp.audiotap
    ///
    /// Nothing recovers from it. The wedge is upstream of `setState(running:
    /// false)`, so `isRunning` stays true, `levels()` keeps handing out the last
    /// bands it computed, and `AudioLevels` goes on reporting a healthy tap;
    /// every later `start()` queues behind the stuck teardown and never runs,
    /// and `retryCapture()` — guarded on `!isRunning` — declines to act. The
    /// visualiser stops responding to audio for the rest of the session while
    /// every diagnostic the app has says capture is fine.
    ///
    /// Serialising teardown onto `queue` was itself the fix for a start/stop
    /// race (see `stop()`); it just put lifecycle work on the queue Core Audio
    /// was already using to deliver frames. The two jobs need two queues.
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
    /// Rolling history, so the FFT always sees a full block.
    ///
    /// The default output IOProc hands 512 frames while the FFT is 1024, and the
    /// old code windowed 512 real samples followed by 512 zeros — which applies
    /// only the Hann's rising half and leaves a step discontinuity in the middle
    /// of the block. Its sidelobes then fall off at roughly 6 dB/octave instead
    /// of Hann's 18, so one loud bass note leaks across all twelve log-spaced
    /// bands. That is the flat, undifferentiated spectrum the per-band mounds
    /// exist to avoid, coming from the analysis rather than from the music.
    private var ring: [Float] = []
    private var writeIndex = 0
    private var framesWritten = 0
    private var block: [Float] = []

    // Published levels
    private var lock = os_unfair_lock_s()
    private var bands = [Float](repeating: 0, count: AudioTap.bandCount)
    /// Band scratch for `computeBands` — a member, not a local, because a fresh
    /// `[Float]` per callback is a malloc on the real-time thread.
    private var outScratch = [Float](repeating: 0, count: AudioTap.bandCount)
    /// Continuous-clock tick of the last band publish, under `lock`. Armed at
    /// `startSync` success so a device still warming up is measured from the
    /// start call, not from a delivery that has not happened yet.
    private var lastDeliveryTicks: UInt64 = 0

    init() {
        fftSetup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))
        window = [Float](repeating: 0, count: fftSize)
        vDSP_hann_window(&window, vDSP_Length(fftSize), Int32(vDSP_HANN_NORM))
        // Built once beside the window, for the same reason: constant for the
        // life of the tap, and the alternative was 24 `pow` calls on the audio
        // thread every callback.
        bandEdges = Self.bandPartition(fftSize: fftSize, bandCount: Self.bandCount)
        realBuf = [Float](repeating: 0, count: fftSize / 2)
        imagBuf = [Float](repeating: 0, count: fftSize / 2)
        magnitudes = [Float](repeating: 0, count: fftSize / 2)
        mono = [Float](repeating: 0, count: fftSize)
        ring = [Float](repeating: 0, count: fftSize)
        block = [Float](repeating: 0, count: fftSize)
    }

    deinit {
        // Synchronous: the object is going away, so teardown cannot be left in
        // flight on the queue.
        queue.sync { self.teardown() }
        if let fftSetup { vDSP_destroy_fftsetup(fftSetup) }
    }

    /// Copy the current band levels, 0...1, into caller-owned storage.
    ///
    /// `inout` rather than a returned array: returning `bands` handed the
    /// caller a share of the very buffer the IOProc mutates, so the next
    /// callback's write paid a copy-on-write malloc under `lock` on the
    /// real-time thread — roughly 30 times a second. The copy still happens,
    /// but here, on the caller's thread, and `withUnsafeMutableBufferPointer`
    /// does any reallocation before the lock is taken.
    func levels(into out: inout [Float]) {
        out.withUnsafeMutableBufferPointer { dst in
            guard dst.count >= Self.bandCount else { return }
            os_unfair_lock_lock(&lock)
            for i in 0..<Self.bandCount { dst[i] = bands[i] }
            os_unfair_lock_unlock(&lock)
        }
    }

    /// How long a running tap may go without publishing bands before it is
    /// declared stalled. Longer than any observed device warm-up — Bluetooth
    /// takes over a second to its first callback — and short enough that a
    /// frozen visualiser is caught within a couple of frames of decay.
    private static let stallThreshold: TimeInterval = 2

    private static let timebase: mach_timebase_info_data_t = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return info
    }()

    /// True when the tap claims to run but has not published bands for over
    /// `stallThreshold`. The delivery stamp is the one signal a silent stall
    /// cannot fake: every status this class exposes can go on reading healthy
    /// while frames simply stop arriving. The continuous clock counts sleep on
    /// purpose — after a wake the stamp reads stale and buys the one rebuild a
    /// re-enumerated device usually needs anyway.
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

    /// Teardown is queued, never run on the caller's thread.
    ///
    /// It used to execute inline while `startSync` was mid-flight on `queue`.
    /// A start racing a stop would finish *after* the teardown, leaving a live
    /// process tap and aggregate device with no consumers and no handle able to
    /// reach them — the tap simply ran until the app quit.
    func stop() {
        queue.async { [weak self] in
            guard let self else { return }
            self.wantsRunning = false
            self.teardown()
        }
    }

    /// One recovery attempt for a tap that claims to run but has stopped
    /// delivering. Lifecycle work, so it goes on `queue` like every other
    /// lifecycle move; the caller bounds how often it asks — this method
    /// deliberately has no retry of its own, because a tap that stalls right
    /// back after a rebuild needs reporting, not hammering.
    func rebuildStalled() {
        queue.async { [weak self] in
            guard let self, self.wantsRunning, self.isRunning else { return }
            self.log("delivery stalled — rebuilding tap")
            self.teardown()
            self.startSync()
        }
    }

    /// Core Audio teardown. Only ever called on `queue`.
    ///
    /// Asserted rather than assumed. The failure this guards is a silent
    /// permanent hang, not a crash — the tap simply stops delivering and every
    /// status the app can read still says it is live — so the one thing worse
    /// than tripping here is not tripping here.
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

    /// Follow the default output device.
    ///
    /// The aggregate is built around whichever device was default at start, so
    /// plugging in headphones or switching to a display's speakers previously
    /// left the tap bound to a device carrying no audio — the visualiser went
    /// flat and never recovered until the app restarted.
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

    /// Only the device-change path retries a failed start. An initial start
    /// refused for permission must not become an endless tap-create loop, but
    /// a rebuild against a device mid-handoff — AirPods switching hosts, a
    /// display renegotiating — can fail once while the device settles, and
    /// without a retry the visualiser stayed flat until something else poked
    /// the tap. Each notification re-arms the budget, so a genuinely refused
    /// permission costs at most two extra attempts per device change.
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

        // 3. Pull frames.
        // `ioQueue`, never `queue`. See `ioQueue`: the IOProc is dispatch_sync'd
        // here from the IO thread under Core Audio's own mutex, so any queue that
        // also runs `AudioDeviceStop` deadlocks against its own frame delivery.
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
        // Arm the staleness clock from the start call itself, so a tap that
        // never delivers a single frame still goes stale instead of sitting in
        // an unarmed state forever.
        os_unfair_lock_lock(&lock)
        lastDeliveryTicks = mach_continuous_time()
        os_unfair_lock_unlock(&lock)
        log("live — capturing system audio")
    }

    /// One line on stderr either way. Whether the tap got its permission is the
    /// single most useful thing to know when the visualiser looks wrong.
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
        // Unmanaged, not a bare CFString: Core Audio writes a +1 CFStringRef into
        // this buffer, and pointing it at a strongly-held Swift variable both
        // clobbers an existing reference and drops the returned one's retain on
        // the floor.
        var uid: Unmanaged<CFString>?
        var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &uidSize, &uid) == noErr,
              let value = uid
        else { return nil }
        return value.takeRetainedValue() as String
    }

    // MARK: Real-time path

    /// Internal, not private: `site/test/bandsprobe.swift` compiles this file
    /// and feeds synthesized PCM through the real pipeline — ring, window, FFT,
    /// partition, meter — to dump the goldens the site's port is checked
    /// against. A harness that reimplemented the chain would only ever agree
    /// with itself. Nothing else calls this from outside the IOProc.
    func consume(_ bufferList: UnsafePointer<AudioBufferList>) {
        let abl = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: bufferList))
        guard let first = abl.first,
              let raw = first.mData,
              first.mDataByteSize > 0 else { return }

        let available = Int(first.mDataByteSize) / MemoryLayout<Float>.size
        let channels = max(1, Int(first.mNumberChannels))
        let frames = min(fftSize, available / channels)
        // No minimum block size. A device running a 32-frame buffer used to trip
        // a `frames >= 64` guard on every single callback, so computeBands never
        // ran, the published bands held their last values forever, and `isLive`
        // still read true — a frozen non-zero visualiser with the menu reporting
        // everything healthy.
        guard frames > 0 else { return }

        let samples = raw.assumingMemoryBound(to: Float.self)

        // Interleaved -> mono for just this block.
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

        // Append into the ring, in at most two contiguous runs.
        //
        // The per-sample version did a bounds-checked store and an integer
        // modulo for every frame — 512 of each per callback, on the audio thread.
        // The wrap can happen at most once, so it is cheaper to find it than to
        // test for it 512 times.
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

        // Copy the most recent fftSize samples out in chronological order, so the
        // window is applied to a genuinely continuous block.
        let head = fftSize - writeIndex
        mono.withUnsafeMutableBufferPointer { dst in
            ring.withUnsafeBufferPointer { src in
                dst.baseAddress!.update(from: src.baseAddress! + writeIndex, count: head)
                if writeIndex > 0 {
                    (dst.baseAddress! + head).update(from: src.baseAddress!, count: writeIndex)
                }
            }
        }

        // In place through one pointer. Passing `mono` as both the input and
        // the `&mono` output made Swift copy the array for the call — a 4KB
        // malloc, copy and free on the IO thread about 86 times a second.
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
                    // vDSP's real FFT returns magnitudes scaled by 2N. Without
                    // undoing that every band saturates at full scale and the
                    // visualiser is a flat wall — which is exactly what happened.
                    var scale = Float(1) / Float(2 * self.fftSize)
                    vDSP_vsmul(mag.baseAddress!, 1, &scale,
                               mag.baseAddress!, 1, vDSP_Length(half))
                }
            }
        }

        // Log-spaced bins: pitch perception is logarithmic, and linear bands put
        // almost everything in the first bar.
        //
        // The edges depend only on `fftSize`, so they are computed once rather
        // than 24 `pow` calls on every IOProc callback — this runs on the audio
        // thread roughly 86 times a second, where the budget is a few
        // microseconds and allocation is not allowed at all.
        for b in 0..<Self.bandCount {
            let (i0, i1) = bandEdges[b]
            var sum: Float = 0
            for i in i0..<i1 { sum += magnitudes[i] }
            let mean = sum / Float(i1 - i0)
            // dB, then normalise into a range that actually uses the full height.
            let db = 20 * log10(max(mean, 1e-7))
            // Normalised magnitudes put music roughly in -70…-15 dBFS per band.
            outScratch[b] = min(1, max(0, (db + 70) / 55))
        }

        os_unfair_lock_lock(&lock)
        // Attack fast, release slow — the shape of every good level meter.
        for i in 0..<Self.bandCount {
            bands[i] = outScratch[i] > bands[i]
                ? bands[i] + (outScratch[i] - bands[i]) * 0.55
                : bands[i] + (outScratch[i] - bands[i]) * 0.16
        }
        lastDeliveryTicks = mach_continuous_time()
        os_unfair_lock_unlock(&lock)
    }
}
