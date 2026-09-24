import AppKit

/// Display brightness, read through private `DisplayServices`.
///
/// Resolved with `dlopen`/`dlsym` rather than linked, so if Apple removes or
/// renames these the app loses a feature instead of failing to launch. A private
/// symbol resolved at link time is a launch failure waiting for an OS update.
///
/// **Read-only.** Writing brightness needs coalescing and callback suppression
/// to avoid fighting the system's own animation; until the media-key tap exists
/// there is nothing to write *from*, so we don't take the risk.
@MainActor
final class BrightnessManager {

    private(set) var brightness: Float = 0
    private(set) var isAvailable = false

    /// A brightness key moves one notch, 1/16 = 0.0625. Anything much smaller
    /// arriving under its own steam is the ambient sensor, not a person.
    private static let manualStep: Float = 0.04
    /// How many consecutive polls have seen the level moving.
    private var rampTicks = 0
    /// Whether the current ramp has qualified as a person at the keys.
    private var manualRamp = false

    var onChange: ((Float) -> Void)?

    private typealias GetBrightness = @convention(c) (CGDirectDisplayID, UnsafeMutablePointer<Float>) -> Int32

    private var handle: UnsafeMutableRawPointer?
    private var getBrightness: GetBrightness?
    // deinit runs outside the actor; this storage is only touched there and in
    // init-time setup, so unchecked access is genuinely safe.
    private nonisolated(unsafe) var poll: Task<Void, Never>?

    private static let path =
        "/System/Library/PrivateFrameworks/DisplayServices.framework/DisplayServices"

    init() {
        resolve()
        reprobe()
        // Displays come and go; the built-in panel's ID can even change across
        // a sleep/wake with a dock. One probe at init meant a session that
        // started docked-lid-closed kept a dead (or wrong-display) HUD after
        // the lid opened.
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

    /// The display whose brightness the keys actually drive.
    ///
    /// Not `NSScreen.main`: that is the key window's screen, and this app never
    /// has a key window, so it degrades to the primary display in Arrangement —
    /// on a docked MacBook with the external monitor set primary, that probed
    /// (and tracked) a display the brightness keys do not touch, leaving the
    /// HUD silently dead or following the wrong panel for the whole session.
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

    /// Confirm the symbol actually answers for the target display before
    /// claiming the feature works — and keep the claim current as displays
    /// come and go.
    private func reprobe() {
        let was = isAvailable
        displayID = Self.targetDisplay()
        var value: Float = 0
        isAvailable = getBrightness?(displayID, &value) == 0
        guard isAvailable else {
            if was { poll?.cancel(); poll = nil }
            return
        }
        // Baseline straight from the probe: the next poll tick must not read
        // a new display's level against the old display's and call it a key.
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

    /// DisplayServices does expose a change-notification registration, but its
    /// callback signature is undocumented and getting it wrong crashes the
    /// process. Reading one float a few times a second costs microseconds and
    /// cannot crash, so we poll — the conservative trade for a private API.
    private func startPolling() {
        poll?.cancel()
        poll = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(200))
                guard let self, !Task.isCancelled else { return }
                let previous = self.brightness
                self.readCurrent()
                let delta = abs(self.brightness - previous)

                // Still: re-arm — and close out a manual ramp with its settled
                // level. The HUD dwells for seconds after the fingers lift, so
                // whatever it shows last must be where the display actually
                // ended up, not wherever the ramp was when qualification ran
                // out.
                if delta < 0.0005 {
                    if self.manualRamp {
                        self.manualRamp = false
                        if Settings.shared.enableBrightness { self.onChange?(self.brightness) }
                    }
                    self.rampTicks = 0
                    continue
                }
                self.rampTicks += 1

                // Only manual changes get a HUD.
                //
                // The old test was `> 0.001`, which any ambient drift clears, so
                // adaptive brightness put the indicator on screen continuously
                // while nobody had touched anything. A key press moves brightness
                // a full notch (1/16) in one 200ms tick and then stops; adaptive
                // brightness is a long train of much smaller steps. So: the step
                // has to be big AND it has to be brief — but only to QUALIFY the
                // ramp. Suppressing its updates too meant a held key animated
                // three steps and froze while the screen visibly kept going,
                // then dwelt for two seconds displaying a level the display
                // contradicted; a held volume key has no such gate, and two
                // HUDs must not disagree about the same interaction. Once a
                // ramp has proven manual, every tick of it is reported.
                if delta >= Self.manualStep, self.rampTicks <= 3 { self.manualRamp = true }
                guard self.manualRamp else { continue }

                // The setting silences the HUD; it does not stop the tracking.
                //
                // This guard used to sit at the top of the loop, above
                // `readCurrent()`, so switching the HUD off froze `brightness`
                // at whatever it held at that moment. The first tick after
                // switching it back on then measured the live level against a
                // baseline minutes old, which is arithmetically indistinguishable
                // from a key press — and dropped a HUD nobody had asked for,
                // immediately after the user ticked the box. It needs no key
                // press at all on a laptop with adaptive brightness: the level
                // drifts past `manualStep` on its own while nothing is watching.
                //
                // `VolumeManager` never had this: it tracks unconditionally and
                // its setting is applied downstream, in the coordinator.
                guard Settings.shared.enableBrightness else { continue }
                self.onChange?(self.brightness)
            }
        }
    }
}
