import CoreGraphics
import Foundation

/// The decision, separated from the event plumbing so it can be tested.
///
/// NSEvents cannot reasonably be synthesised, so without this split the only way
/// to know whether a swipe is recognised correctly is to swipe and look — which
/// is exactly the kind of "verified by eye" this project keeps getting caught by.
///
/// The ratchet lives here for the same reason, and one further one: a haptic is
/// the one thing in this app that cannot be verified by looking either. When the
/// clicks land is a decision and is checked; which pattern plays is plumbing and
/// lives in `NotchGestures`.
struct SwipeRecogniser {
    enum Action: Equatable { case none, skipForward, skipBackward, togglePlayback }

    /// One delta's worth of consequence.
    struct Step: Equatable {
        /// The gesture, once the swipe has travelled far enough to mean it.
        var action: Action = .none
        /// Index into `detents`, when this delta crossed into a new one *and*
        /// the floor let it play.
        var detent: Int?
    }

    /// Where the ratchet clicks on the way to the threshold.
    ///
    /// Evenly spaced, and the commit at 1.0 completes the grid: click, click,
    /// click, clunk, all on the same beat. The first version of this tightened
    /// the gaps toward the commit on the theory that accelerating clicks read as
    /// winding up. They do not, for a reason that only shows up under a real
    /// hand: these gaps are in *distance*, and a finger does not travel at a
    /// constant speed — it eases off as it arrives. Shrinking distance against a
    /// decelerating finger produces a rhythm that is neither even nor
    /// accelerating, and arrhythmia is what "weird" turned out to mean.
    ///
    /// Even spacing has the opposite property: the rhythm you feel is an honest
    /// report of how fast you are moving, which is exactly what a physical
    /// detent does. Every ratchet, dial and wheel worth the comparison is
    /// evenly spaced; none of them speed up as they approach anything.
    static let detents: [CGFloat] = [0.25, 0.5, 0.75]

    /// The shortest gap between two clicks that still reads as two clicks.
    ///
    /// The trackpad's engine merges taps that arrive too close together, so a
    /// flick that crosses three detents inside 25ms does not produce three
    /// sensations — it produces mush, in the part of the gesture that can least
    /// afford it. Below this, a crossing is skipped rather than delayed:
    /// deferring it would push the click away from the movement that earned it
    /// and reintroduce the arrhythmia this is here to prevent.
    static let tickFloor: TimeInterval = 0.04

    /// Turns a scroll delta into a FINGER delta.
    ///
    /// `NSEvent.isDirectionInvertedFromDevice` is true when natural scrolling is
    /// ON — and with it on the delta already follows the fingers, so it is the
    /// OTHER case that needs flipping. Reading it the other way round is what
    /// made swiping right go backwards: the normalisation inverted the very case
    /// it should have left alone.
    ///
    /// A named rule rather than a ternary at the call site because that ternary
    /// lives in `NotchGestures`, which needs real NSEvents and so cannot be
    /// driven by anything headless. Here, `gesturecheck` can push a delta
    /// through it and out the other side of the recogniser.
    static func fingerSign(invertedFromDevice: Bool) -> CGFloat {
        invertedFromDevice ? 1 : -1
    }

    /// Points of travel that count as a deliberate swipe. Trackpad deltas
    /// accumulate fast, so this is generous enough not to fire on a stray flick
    /// while still landing inside one comfortable two-finger movement.
    var threshold: CGFloat = 52
    /// How much an axis must dominate before it is treated as that gesture. A
    /// diagonal drag should do nothing rather than pick one at random.
    var dominance: CGFloat = 1.6

    private(set) var x: CGFloat = 0
    private(set) var y: CGFloat = 0
    /// False once a gesture has fired, until the fingers lift: one swipe is one
    /// gesture, however far it travels.
    private(set) var armed = true
    /// How far up the ratchet this swipe has already been.
    ///
    /// A high-water mark, not a position, so drifting back and forth across a
    /// detent cannot tick it twice. It advances when a detent is crossed whether
    /// or not the floor let that click play — a crossing that was swallowed is
    /// still a crossing, and letting it come back later would land a click on a
    /// stretch of swipe where nothing happened.
    private(set) var reached = 0
    /// When the last click played. Nil means the floor has nothing to measure
    /// against yet, so the first click of a swipe is never held back.
    private(set) var lastTick: TimeInterval?

    mutating func reset() {
        x = 0
        y = 0
        armed = true
        reached = 0
        lastTick = nil
    }

    mutating func add(dx: CGFloat, dy: CGFloat, now: TimeInterval) -> Step {
        x += dx
        y += dy
        guard armed else { return Step() }

        let ax = abs(x), ay = abs(y)
        if ax >= threshold, ax > ay * dominance {
            armed = false
            // Deltas arrive in FINGER direction, normalised by the caller, so
            // this mapping cannot flip with the user's natural-scrolling setting.
            // Fingers moving right go forward, which is the direction people
            // reached for without being told.
            let action: Action = x > 0 ? .skipForward : .skipBackward
            x = 0; y = 0
            return Step(action: action)
        }
        if ay >= threshold, ay > ax * dominance {
            armed = false
            x = 0; y = 0
            return Step(action: .togglePlayback)
        }
        return Step(detent: climb(ax: ax, ay: ay, now: now))
    }

    /// The highest detent this delta crossed into, if the floor allows it.
    ///
    /// The commit does not come through here. It rides `action`, which nothing
    /// in this function can suppress — so however fast the swipe, the one click
    /// that confirms it always plays.
    private mutating func climb(ax: CGFloat, ay: CGFloat, now: TimeInterval) -> Int? {
        // Only an axis that is actually winning may tick. A diagonal drag is
        // going to be refused at the threshold, so ticking it would be the
        // gesture promising a commit it has already decided not to make.
        let travel: CGFloat
        if ax > ay * dominance { travel = ax }
        else if ay > ax * dominance { travel = ay }
        else { return nil }

        let progress = travel / threshold
        var crossed: Int?
        while reached < Self.detents.count, progress >= Self.detents[reached] {
            crossed = reached
            reached += 1
        }
        guard crossed != nil else { return nil }
        if let last = lastTick, now - last < Self.tickFloor { return nil }
        lastTick = now
        return crossed
    }

    // MARK: The indicator

    /// A horizontal swipe still in flight, as the two surfaces that answer it
    /// need it: which way, how far, and how much of the ratchet it has banked.
    ///
    /// The haptic ratchet reports progress to the hand; nothing reported it to
    /// the eye, so a swipe was invisible until the moment it fired. `Lean` is
    /// what the ink's magnet and the content sheet lean on while the fingers
    /// are still moving — and it exists only for a swipe that could still
    /// commit: not before the fingers pick an axis, not after the gesture has
    /// fired, and never for a vertical or diagonal drag, which the threshold is
    /// going to refuse. An indicator for a refused gesture is the visual twin
    /// of the tick `climb` already declines to play for one.
    struct Lean: Equatable {
        /// Finger direction: +1 rightward (forward), -1 leftward.
        var direction: CGFloat
        /// Travel toward the threshold, 0…1.
        var progress: CGFloat
        /// Detents banked so far — `reached`, the high-water mark, so drifting
        /// back mid-swipe cannot un-bank a click the hand already felt.
        var reached: Int

        /// How much the indicator believes this is a swipe at all.
        ///
        /// Every two-finger touch produces a few points of horizontal drift,
        /// and an indicator that answers all of it makes the notch flinch at
        /// every scroll that merely passes over it. Ramping over the first
        /// tenth of the threshold keeps a stray under ~5pt sub-visible while a
        /// real swipe reaches full credence 5pt in — the same shape as
        /// `tickFloor`: the gesture earns its feedback.
        var gate: CGFloat { min(1, progress / SwipeRecogniser.onsetTravel) }
    }

    /// The fraction of `threshold` over which `Lean.gate` ramps 0 to 1.
    static let onsetTravel: CGFloat = 0.10

    /// The swipe in flight, or nil when there is nothing to indicate.
    ///
    /// Armed is the first gate: after the commit `x` keeps accumulating while
    /// the fingers stay down, and an indicator that kept leaning would promise
    /// a second gesture `add` has already refused. The axis test is `climb`'s
    /// own, for `climb`'s own reason.
    var lean: Lean? {
        guard armed else { return nil }
        let ax = abs(x), ay = abs(y)
        guard ax > ay * dominance, ax > 0 else { return nil }
        return Lean(direction: x > 0 ? 1 : -1,
                    progress: min(ax / threshold, 1),
                    reached: reached)
    }

    /// The ink's answer to a live swipe: a magnet on the rim.
    ///
    /// This drives the SAME channel the scrub drag drives (`setPointer`), on
    /// purpose: the reservoir already has a vocabulary for "the hand is pulling
    /// me" and a second vocabulary would read as a second substance. The mound
    /// migrates from the rim's centre toward the swipe's destination edge —
    /// 0.5 ± 0.42 keeps it on the visible rim, off the exact corners — and the
    /// pull is the swipe's own arithmetic: distance, plus a step for every
    /// banked detent, so the ink climbs the ratchet the hand is feeling. The
    /// ceiling is the scrub's own 1.6; at full stretch this reaches 1.59, just
    /// under the one gesture allowed to out-pull it.
    ///
    /// The commit adds nothing here: `onSkipForward`'s surge is already the
    /// slam, and the release to nil is what lets it land on a settling surface.
    static func magnet(for lean: Lean) -> (rim: Double, strength: Double) {
        let rim = 0.5 + Double(lean.direction) * 0.42 * Double(lean.progress)
        let strength = min(1.6, Double(lean.gate)
            * (0.45 * Double(lean.progress) + 0.38 * Double(lean.reached)))
        return (rim, strength)
    }

    /// The content sheet's answer: how far it shears with the fingers.
    ///
    /// Composed here rather than in the view so the whole rule — gate, HUD
    /// refusal, chrome arithmetic — is one function `gesturecheck` drives
    /// end-to-end from real deltas. The caps and slopes live in
    /// `ChromeRules.swipeShift`, where chromecheck holds them against the
    /// margins they must not leave.
    ///
    /// A HUD does not lean. Its meter fills its flank to the padding, so a
    /// shifted strip slides ink under the camera housing; the retracted cap
    /// was derived from `CollapsedActivity`'s leading-aligned flanks, whose
    /// empty trailing air absorbs the travel, and the HUD has no such air.
    static func sheetShift(for lean: Lean?, expanded: Bool,
                           hudShowing: Bool) -> CGFloat {
        guard let lean, !hudShowing else { return 0 }
        return lean.gate * ChromeRules.swipeShift(direction: lean.direction,
                                                  progress: lean.progress,
                                                  reached: lean.reached,
                                                  expanded: expanded)
    }
}
