import AppKit

/// Trackpad swipes over the notch.
///
/// Horizontal swipes skip a track, vertical swipes toggle playback. Two is the ceiling:
/// a third would have to share an axis, and an axis with two meanings needs a
/// preference to choose between them.
///
/// Events are not consumed. A retracted panel has `ignoresMouseEvents = true`, so a
/// local monitor never sees a scroll over it and only a global one does, and a
/// global monitor cannot swallow the event. A swipe over the notch therefore also
/// reaches whatever is beneath, which over the menu bar is almost always nothing.
@MainActor
final class NotchGestures {

    var onSkipForward: (() -> Void)?
    var onSkipBackward: (() -> Void)?
    var onTogglePlayback: (() -> Void)?
    /// Whether the pointer is over a notch. Supplied by the coordinator so the gesture
    /// region is exactly the hover region.
    var isOverNotch: ((NSPoint) -> Bool)?
    /// Whether a gesture can do anything now (a player is loaded). Without a track
    /// every callback no-ops, and the haptic ratchet must not confirm a swipe that
    /// did nothing.
    var canAct: (() -> Bool)?
    /// The swipe in flight whenever it changes, including the nil when it ends. The
    /// recogniser decides what a swipe is; this only reports it.
    var onSwipeChange: ((SwipeRecogniser.Lean?) -> Void)?

    /// One gesture per swipe, and a beat before the next can start.
    private let cooldown: TimeInterval = 0.55
    private var recogniser = SwipeRecogniser()
    private var lastFired = Date.distantPast
    private var lastLean: SwipeRecogniser.Lean?
    private var global: Any?
    private var local: Any?

    func start() {
        guard global == nil else { return }
        global = NSEvent.addGlobalMonitorForEvents(matching: [.scrollWheel]) {
            [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
        }
        // Also local, so the gesture works over the expanded panel, which is interactive
        // and would swallow the event before the global monitor saw it.
        local = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) {
            [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
    }


    private func reset() { recogniser.reset() }

    /// Reports the in-flight swipe if it changed, so the indicator is not re-targeted
    /// every event with a value it already has.
    private func publishLean() {
        let lean = recogniser.lean
        guard lean != lastLean else { return }
        lastLean = lean
        onSwipeChange?(lean)
    }

    private func handle(_ event: NSEvent) {
        // On every path out, however early: each guard below ends a swipe by resetting
        // the recogniser, and a raised indicator must hear about it or it stays up.
        defer { publishLean() }
        // Disabling gestures mid-swipe is the one exit no guard below reaches, because
        // events stop being read. Clearing here is free when gestures were already off.
        guard Settings.shared.enableGestures else {
            reset()
            return
        }
        guard isOverNotch?(NSEvent.mouseLocation) == true else {
            reset()
            return
        }
        // Skip recognition entirely, not just the haptics: a silent detent counter would
        // still fire the callbacks at the commit point.
        guard canAct?() != false else {
            reset()
            return
        }

        // Momentum is not a gesture. After the fingers lift macOS keeps sending large
        // deltas and `.ended` re-arms the recogniser before they arrive, so one swipe
        // would skip several tracks.
        guard event.momentumPhase == [] else {
            reset()
            return
        }

        switch event.phase {
        case .began:
            reset()
        case .ended, .cancelled:
            reset()
            return
        default:
            break
        }

        // A mouse wheel reports coarse line deltas; treating them as a swipe would fire
        // on a single wheel notch.
        guard event.hasPreciseScrollingDeltas else { return }

        guard Date().timeIntervalSince(lastFired) > cooldown else { return }

        // Normalise to finger direction so the mapping does not invert with natural
        // scrolling. The rule lives in `SwipeRecogniser`, where a check can reach it.
        let sign = SwipeRecogniser.fingerSign(
            invertedFromDevice: event.isDirectionInvertedFromDevice)
        // The recogniser is given the time rather than reading a clock, so its rate
        // limit stays testable.
        let step = recogniser.add(dx: event.scrollingDeltaX * sign,
                                  dy: event.scrollingDeltaY * sign,
                                  now: event.timestamp)

        if step.detent != nil { tick() }
        guard step.action != .none else { return }

        lastFired = Date()
        commit()

        switch step.action {
        case .skipForward:    onSkipForward?()
        case .skipBackward:   onSkipBackward?()
        case .togglePlayback: onTogglePlayback?()
        case .none:           break
        }
    }

    // MARK: Haptics

    /// One click of the ratchet; every click is this pattern.
    ///
    /// A swipe that worked and one that missed feel the same under the fingers, so the
    /// gesture ticks as it builds. macOS offers no haptic intensity, and the patterns
    /// are different sensations rather than a ladder: switching pattern mid-swipe feels
    /// like the mechanism being swapped, so the build-up is carried by the clicks
    /// accumulating.
    private func tick() {
        Self.perform(.alignment)
    }

    /// The commit, deliberately a different kind of haptic from the ticks so it does not
    /// arrive as the quietest moment of its own build-up. `.levelChange` is the firmest
    /// pattern available; a follow-up release tap reads as the gesture firing twice.
    private func commit() {
        Self.perform(.levelChange)
    }

    private static func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}
