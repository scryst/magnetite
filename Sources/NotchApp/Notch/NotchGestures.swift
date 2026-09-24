import AppKit

/// Trackpad swipes over the notch.
///
/// Two gestures, mapped to the two things a music player is actually for:
/// horizontal skips a track, vertical toggles playback. Two is the ceiling, not
/// a starting point: a third and fourth would have to share an axis with these,
/// and an axis that means two things needs a switch to say which — a preference
/// paid for by every user to serve the one who wanted the other meaning.
///
/// **On consuming events.** Retracted, the panel is `ignoresMouseEvents = true`
/// so an idle notch is completely invisible to the system — which is the whole
/// point of it. A *local* monitor therefore never sees a scroll over it; only a
/// *global* one does, and a global monitor cannot swallow the event. So a swipe
/// over the notch also reaches whatever is beneath. Over the menu bar that is
/// almost always nothing, and the alternative — making the retracted notch
/// opaque to the mouse — costs far more than it buys.
@MainActor
final class NotchGestures {

    var onSkipForward: (() -> Void)?
    var onSkipBackward: (() -> Void)?
    var onTogglePlayback: (() -> Void)?
    /// Is the pointer over a notch right now? Supplied by the coordinator so the
    /// gesture region is exactly the hover region, with no second definition of
    /// "over the notch" to drift out of sync.
    var isOverNotch: ((NSPoint) -> Bool)?
    /// Can a gesture do anything right now? Injected like `isOverNotch`, for the
    /// same reason: this file cannot know whether a player is loaded, and the
    /// haptic ratchet exists to distinguish a swipe that worked from one that
    /// missed. With no track, every callback no-ops — so building three clicks
    /// and a firm commit under the fingers confirms a swipe that did nothing,
    /// which inverts the one promise the ratchet makes.
    var canAct: (() -> Bool)?
    /// The swipe in flight, whenever it changes — including the nil that says
    /// it is over, whichever way it ended. The recogniser decides what a live
    /// swipe is; this only reports it, the way the haptics only play it.
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
        // Also local, so the gesture keeps working over the expanded panel, which
        // *is* interactive and would otherwise swallow the event before the
        // global monitor ever saw it.
        local = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel]) {
            [weak self] event in
            MainActor.assumeIsolated { self?.handle(event) }
            return event
        }
    }


    private func reset() { recogniser.reset() }

    /// Report the in-flight swipe if it changed. Edge-triggered, so the ink is
    /// not re-targeted sixty times a second with the number it already has.
    private func publishLean() {
        let lean = recogniser.lean
        guard lean != lastLean else { return }
        lastLean = lean
        onSwipeChange?(lean)
    }

    private func handle(_ event: NSEvent) {
        // On EVERY path out of this function, however early. Each guard below
        // ends a swipe by resetting the recogniser, and an indicator raised on
        // the way in must hear about it or the magnet stays up for the session
        // — the same stuck-pointer class the scrub strip's onDisappear closes.
        defer { publishLean() }
        // Disabling gestures mid-swipe is the one exit no guard below reaches:
        // events stop being read entirely, so a raised lean would never see
        // the nil. Clearing the recogniser here costs nothing when gestures
        // were already off.
        guard Settings.shared.enableGestures else {
            reset()
            return
        }
        guard isOverNotch?(NSEvent.mouseLocation) == true else {
            reset()
            return
        }
        // Recognition is skipped entirely, not just the haptics: a silent
        // detent counter would still fire the callbacks at the commit point.
        guard canAct?() != false else {
            reset()
            return
        }

        // Momentum is not a gesture. After the fingers lift, macOS keeps sending
        // deltas — large ones — and `.ended` re-arms the recogniser immediately
        // before they arrive, so a single swipe skipped several tracks in a row.
        // Only what the fingers are actually doing counts.
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

        // A mouse wheel reports coarse line deltas rather than points; treating
        // those as a swipe would fire on a single notch of a wheel.
        guard event.hasPreciseScrollingDeltas else { return }

        guard Date().timeIntervalSince(lastFired) > cooldown else { return }

        // Normalise to FINGER direction, so the mapping does not silently invert
        // with the user's "natural scrolling" setting. The rule itself lives in
        // `SwipeRecogniser`, where a check can reach it — this file needs real
        // NSEvents and nothing headless can drive it.
        let sign = SwipeRecogniser.fingerSign(
            invertedFromDevice: event.isDirectionInvertedFromDevice)
        // The recogniser is handed the time rather than reading a clock itself,
        // so its rate limit stays a decision a check can drive.
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

    /// One click of the ratchet, and every click is this one.
    ///
    /// A swipe that did work and a swipe that missed are otherwise identical
    /// under the fingers — that is why the gesture ticks at all, and why the
    /// buttons no longer do; they have a panel to show for themselves and this
    /// has nothing. What it has instead is the whole length of the swipe, so the
    /// confirmation does not have to wait until the end to start.
    ///
    /// The first version stepped `.alignment` up to `.generic` partway, reading
    /// the patterns as a volume ladder. They are not one: macOS offers no
    /// intensity at all, and these are different *sensations*. Changing which
    /// one plays mid-swipe does not feel like the same ratchet getting firmer,
    /// it feels like the mechanism swapping for another one halfway down — so
    /// the ratchet now speaks with a single voice, and the build-up is carried
    /// entirely by the clicks accumulating.
    private func tick() {
        Self.perform(.alignment)
    }

    /// The commit, deliberately not another tick.
    ///
    /// Three even clicks have already landed, so the end of the gesture has to
    /// be a different *kind* of thing or it arrives as the quietest moment of
    /// its own build-up. `.levelChange` is the firmest pattern on offer, and one
    /// of it is the whole event: the release tap that used to follow 40ms later
    /// was meant to read as a catch letting go, and instead read as the gesture
    /// firing twice — the difference between a mechanism and a glitch is whether
    /// the second thing was asked for.
    private func commit() {
        Self.perform(.levelChange)
    }

    private static func perform(_ pattern: NSHapticFeedbackManager.FeedbackPattern) {
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }
}
