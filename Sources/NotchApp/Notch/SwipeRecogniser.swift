import CoreGraphics
import Foundation

/// Swipe recognition, separated from the event plumbing so it can be tested (`NSEvent`s
/// cannot reasonably be synthesised). When a ratchet click lands is decided here;
/// which haptic pattern plays is plumbing in `NotchGestures`.
struct SwipeRecogniser {
    enum Action: Equatable { case none, skipForward, skipBackward, togglePlayback }

    struct Step: Equatable {
        var action: Action = .none
        /// Index into `detents` when this delta crossed into a new one and the floor let it play.
        var detent: Int?
        /// How long the commit's haptic waits. A flick commits a frame or two after its last
        /// click, and the trackpad's engine merges taps inside `tickFloor`, so the commit
        /// folded into that click and the swipe seemed to say nothing. The action itself
        /// never waits; only its haptic is moved clear of the click.
        var commitDelay: TimeInterval = 0
    }

    /// Where the ratchet clicks on the way to the threshold, evenly spaced with the
    /// commit at 1.0 completing the grid. The gaps are in distance and a finger
    /// decelerates as it arrives, so shrinking gaps give an uneven rhythm; even gaps
    /// report the hand's speed honestly, as a physical detent does.
    static let detents: [CGFloat] = [0.25, 0.5, 0.75]

    /// The shortest gap between two clicks that still reads as two; the trackpad's engine
    /// merges closer taps. A crossing inside it is skipped, not delayed, since a
    /// deferred click would land away from the movement that earned it.
    static let tickFloor: TimeInterval = 0.04

    /// Turns a scroll delta into a finger delta. `isDirectionInvertedFromDevice` is true
    /// when natural scrolling is on, and the delta then already follows the fingers.
    /// A named rule so `gesturecheck` can drive it; the call site in `NotchGestures`
    /// needs real `NSEvent`s.
    static func fingerSign(invertedFromDevice: Bool) -> CGFloat {
        invertedFromDevice ? 1 : -1
    }

    /// Points of travel that count as a deliberate swipe, reachable in one comfortable
    /// two-finger movement without firing on a stray flick.
    var threshold: CGFloat = 52
    /// How much one axis must dominate before it counts; a diagonal drag does nothing.
    var dominance: CGFloat = 1.6

    private(set) var x: CGFloat = 0
    private(set) var y: CGFloat = 0
    /// False once a gesture has fired, until the fingers lift: one swipe, one gesture.
    private(set) var armed = true
    /// How far up the ratchet this swipe has been, a high-water mark so drifting across a
    /// detent cannot tick twice. It advances even when the floor swallowed the click.
    private(set) var reached = 0
    /// When the last click played; nil means the first click is never held back.
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
            // Deltas arrive in finger direction, so this does not flip with natural scrolling.
            let action: Action = x > 0 ? .skipForward : .skipBackward
            x = 0; y = 0
            return Step(action: action, commitDelay: commitDelay(now: now))
        }
        if ay >= threshold, ay > ax * dominance {
            armed = false
            x = 0; y = 0
            return Step(action: .togglePlayback, commitDelay: commitDelay(now: now))
        }
        return Step(detent: climb(ax: ax, ay: ay, now: now))
    }

    private func commitDelay(now: TimeInterval) -> TimeInterval {
        guard let last = lastTick else { return 0 }
        return max(0, Self.tickFloor - (now - last))
    }

    /// The highest detent this delta crossed into, if the floor allows it. The commit
    /// rides `action`, which nothing here can suppress.
    private mutating func climb(ax: CGFloat, ay: CGFloat, now: TimeInterval) -> Int? {
        // Only a winning axis may tick; a diagonal drag will be refused at the threshold.
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

    /// A horizontal swipe still in flight: direction, progress and banked detents. The
    /// ink's magnet and the content sheet follow it. It exists only for a swipe that
    /// could still commit.
    struct Lean: Equatable {
        /// Finger direction: +1 rightward (forward), -1 leftward.
        var direction: CGFloat
        /// Travel toward the threshold, 0…1.
        var progress: CGFloat
        /// Detents banked so far, so drifting back cannot un-bank a click already felt.
        var reached: Int

        /// How much the indicator believes this is a swipe. Every two-finger touch drifts a
        /// few points horizontally, so the gate ramps over the first tenth of the
        /// threshold.
        var gate: CGFloat { min(1, progress / SwipeRecogniser.onsetTravel) }
    }

    /// The fraction of `threshold` over which `Lean.gate` ramps from 0 to 1.
    static let onsetTravel: CGFloat = 0.10

    /// The swipe in flight, or nil. After the commit `x` keeps accumulating while the
    /// fingers stay down, so `armed` is checked first.
    var lean: Lean? {
        guard armed else { return nil }
        let ax = abs(x), ay = abs(y)
        guard ax > ay * dominance, ax > 0 else { return nil }
        return Lean(direction: x > 0 ? 1 : -1,
                    progress: min(ax / threshold, 1),
                    reached: reached)
    }

    /// The ink's answer to a live swipe: a magnet on the rim, on the same channel as
    /// the scrub drag (`setPointer`). The mound moves from the rim's centre toward the
    /// destination edge (0.5 +/- 0.42) and pulls harder with distance and with each
    /// banked detent, up to 1.59 against the scrub's 1.6 ceiling. The commit adds
    /// nothing: the skip callback's surge is the slam.
    static func magnet(for lean: Lean) -> (rim: Double, strength: Double) {
        let rim = 0.5 + Double(lean.direction) * 0.42 * Double(lean.progress)
        let strength = min(1.6, Double(lean.gate)
            * (0.45 * Double(lean.progress) + 0.38 * Double(lean.reached)))
        return (rim, strength)
    }

    /// The content sheet's answer: how far it shears with the fingers. Composed here so
    /// `gesturecheck` can drive the whole rule; caps and slopes live in
    /// `ChromeRules.swipeShift`. A HUD does not lean, since its meter fills its flank
    /// and a shift would slide ink under the camera housing.
    static func sheetShift(for lean: Lean?, expanded: Bool,
                           hudShowing: Bool) -> CGFloat {
        guard let lean, !hudShowing else { return 0 }
        return lean.gate * ChromeRules.swipeShift(direction: lean.direction,
                                                  progress: lean.progress,
                                                  reached: lean.reached,
                                                  expanded: expanded)
    }
}
