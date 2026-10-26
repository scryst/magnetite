import AppKit

/// Display brightness, read through private `DisplayServices`.
///
/// The symbol is resolved with `dlopen`/`dlsym` rather than linked, so if Apple
/// removes or renames it the app loses a feature instead of failing to launch.
///
/// Read-only: writing needs coalescing and callback suppression to avoid fighting
/// the system's own animation, and nothing here has a reason to write.
@MainActor
final class BrightnessManager {

    private(set) var brightness: Float = 0
    private(set) var isAvailable = false

    /// One key press moves brightness by a full notch (1/16 = 0.0625); much smaller
    /// steps on their own are the ambient light sensor, not a person.
    private static let manualStep: Float = 0.04
    /// How many consecutive polls have seen the level moving.
    private var rampTicks = 0
    /// Whether the current ramp has qualified as a person at the keys.
    private var manualRamp = false

    var onChange: ((Float) -> Void)?

    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32

    private var handle: UnsafeMutableRawPointer?
    private var getBrightness: GetBrightness?
    // `deinit` runs outside the actor; this is only touched there and during init.
    private nonisolated(unsafe) var poll: Task<Void, Never>?

    private static let path =
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"

    init() {
        resolve()
        reprobe()
        // Displays come and go and the built-in panel's ID can change across sleep/wake
        // with a dock, so a single probe at init would leave a lid-closed start with a
        // dead or wrong-display HUD.
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reprobe() }
        }
    }

    deinit {
        poll?.cancel()
    }

    private func resolve() {
        guard let h = dlopen(Self.path, RTLD_LAZY) else { return }
        handle = h
        guard let sym = dlsym(h, "DisplayServicesGetBrightness") else { return }
        getBrightness = unsafeBitCast(sym, to: GetBrightness.self)
    }

    /// The display whose brightness the keys drive: the built-in one.
    ///
    /// `NSScreen.main` follows the key window, which this app never has, so it falls
    /// back to the primary display and can name an external monitor the keys do not
    /// touch.
    private static func targetDisplay() -> CGDirectDisplayID {
        for screen in NSScreen.screens {
            if let id = ScreenMetrics.displayID(for: screen), CGDisplayIsBuiltin(id) != 0 {
                return id
            }
        }
        return CGMainDisplayID()
    }

    /// Resolved at probe time, not per poll tick.
    private var displayID = CGMainDisplayID()

    /// Confirms the symbol answers for the target display before claiming the feature
    /// works, and keeps that claim current as displays change.
    private func reprobe() {
        let was = isAvailable
        displayID = Self.targetDisplay()
        var value: Float = 0
        isAvailable = getBrightness?(displayID, &value) == 0
        guard isAvailable else {
            if was { poll?.cancel(); poll = nil }
            return
        }
        // Re-baseline from the probe so the next poll does not compare a new display's
        // level against the old one's and read it as a key press.
        readCurrent()
        rampTicks = 0
        manualRamp = false
        if !was { startPolling() }
    }

    private func readCurrent() {
        guard let getBrightness else { return }
        var value: Float = 0
        guard getBrightness(displayID, &value) == 0 else { return }
        brightness = value
    }

    /// Where the polled read runs. `DisplayServicesGetBrightness` is a
    /// synchronous round trip to another process, so on the main thread a slow
    /// answer (waking display, dock handshake) freezes the whole panel five
    /// times a second. Serial, so a slow read cannot pile up behind itself.
    private static let readQueue = DispatchQueue(label: "magnetite.brightness.read", qos: .utility)

    /// One poll's read, off the main thread. Nil when the call failed or the
    /// target display changed while it was out, so a stale level from the old
    /// display is never taken for a key press on the new one.
    private func readOffMain() async -> Float? {
        guard let getBrightness else { return nil }
        let id = displayID
        let value: Float? = await withCheckedContinuation { cont in
            Self.readQueue.async {
                var v: Float = 0
                cont.resume(returning: getBrightness(id, &v) == 0 ? v : nil)
            }
        }
        return id == displayID ? value : nil
    }

    /// `DisplayServices` has a change-notification registration, but its callback
    /// signature is undocumented and a wrong one crashes the process. Reading one
    /// float five times a second is cheap and cannot crash.
    private func startPolling() {
        poll?.cancel()
        poll = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, !Task.isCancelled else { return }
                let previous = self.brightness
                guard let level = await self.readOffMain(), !Task.isCancelled else { continue }
                self.brightness = level
                let delta = abs(self.brightness - previous)

                // Still: close out a manual ramp with its settled level, since the HUD dwells
                // after the fingers lift and must end on where the display actually is.
                if delta < 0.0005 {
                    if self.manualRamp {
                        self.manualRamp = false
                        if Settings.shared.enableBrightness { self.onChange?(self.brightness) }
                    }
                    self.rampTicks = 0
                    continue
                }
                self.rampTicks += 1

                // Only manual changes get a HUD. A key press moves brightness a full notch in one
                // tick and stops; adaptive brightness is a long train of much smaller steps. So a
                // step must be big and brief to qualify a ramp as manual. Once qualified, every
                // tick is reported, so a held key's HUD does not freeze while the screen keeps
                // changing (a held volume key has no such gate either).
                if delta >= Self.manualStep, self.rampTicks <= 3 { self.manualRamp = true }
                guard self.manualRamp else { continue }

                // The setting silences the HUD but not the tracking. Checking it above
                // the read would freeze `brightness`, and the first tick after re-enabling
                // would compare the live level with a stale baseline and look like a key press.
                // `VolumeManager` tracks unconditionally and applies its setting downstream.
                guard Settings.shared.enableBrightness else { continue }
                self.onChange?(self.brightness)
            }
        }
    }
}
