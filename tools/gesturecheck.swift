import Foundation
import CoreGraphics

/// Headless checks on swipe recognition.
///
/// NSEvents cannot reasonably be synthesised, so these drive the recogniser
/// directly with the deltas a trackpad would produce instead of swiping and
/// looking.
///
/// The haptic ratchet cannot be verified by eye either. What a check can hold is
/// every decision behind the sensation: where the clicks land, that they are
/// evenly spaced and the commit lands on the same beat, that a flick produces
/// clicks rather than a buzz, and that a gesture about to be refused stays
/// silent. Whether it feels good is out of reach; the recogniser says when and
/// `NotchGestures` says what.
///
/// The clock is an argument to the recogniser, so the rate limit, which exists
/// only because of hardware timing, is as drivable as the geometry.
@main
enum GestureCheck {
    static func main() {
        aDeliberateHorizontalSwipeSkips()
        aDeliberateVerticalSwipeTogglesPlayback()
        aDiagonalDragDoesNothing()
        aDriftDoesNotFire()
        oneSwipeIsOneGesture()
        liftingTheFingersRearms()
        naturalScrollingDoesNotFlipTheGesture()
        theRatchetIsEvenlySpaced()
        aSlowSwipeFeelsEveryDetent()
        aBriskSwipeStillFeelsEveryClick()
        aFlickClicksRatherThanBuzzes()
        aFlickDoesNotOutrunTheFloor()
        theCommitOutrunsTheFloor()
        theCommitIsNotMergedIntoAClick()
        aSwallowedClickDoesNotComeBackLater()
        aDiagonalDragTicksNothing()
        pullingBackDoesNotReRatchet()
        theRatchetStopsOnceTheGestureHasFired()
        liftingTheFingersRearmsTheRatchet()
        theLeanFollowsTheFingers()
        aRefusedAxisNeverLeans()
        theLeanBanksEachDetent()
        theMagnetClimbsTheRatchet()
        aFiredGestureStopsLeaning()
        liftingTheFingersClearsTheLean()
        theMagnetStaysOnTheRim()
        theOnsetGateSwallowsAStray()
        theSheetLeansTheWayTheFingersGo()
        theHudDoesNotLean()
        print("gesturecheck: all checks passed")
    }

    /// Deltas reach the recogniser in finger direction: right goes forward.
    private static func aDeliberateHorizontalSwipeSkips() {
        var forward = Hand()
        require(forward.move(dx: 14, dy: 0.4, steps: 6).action == .skipForward,
                "fingers moving right did not go forward")
        var back = Hand()
        require(back.move(dx: -14, dy: -0.4, steps: 6).action == .skipBackward,
                "fingers moving left did not go back")
    }

    private static func aDeliberateVerticalSwipeTogglesPlayback() {
        var hand = Hand()
        require(hand.move(dx: 0.6, dy: -13, steps: 6).action == .togglePlayback,
                "a vertical swipe did not toggle playback")
    }

    /// A 45-degree drag is ambiguous and must do nothing rather than guess.
    private static func aDiagonalDragDoesNothing() {
        var hand = Hand()
        require(hand.move(dx: 12, dy: 12, steps: 10).action == SwipeRecogniser.Action.none,
                "a diagonal drag fired a gesture")
    }

    /// Slow two-finger drift while reading should never skip a track.
    private static func aDriftDoesNotFire() {
        var hand = Hand()
        require(hand.move(dx: -3, dy: 0, steps: 10).action == SwipeRecogniser.Action.none,
                "30pt of drift fired a gesture (threshold is 52)")
    }

    /// One long swipe is one gesture, however far the fingers travel.
    private static func oneSwipeIsOneGesture() {
        var hand = Hand()
        require(hand.move(dx: -14, dy: 0, steps: 6).action == .skipBackward, "setup did not skip")
        require(hand.move(dx: -14, dy: 0, steps: 40).action == SwipeRecogniser.Action.none,
                "one continuous swipe fired more than once")
    }

    private static func liftingTheFingersRearms() {
        var hand = Hand()
        _ = hand.move(dx: -14, dy: 0, steps: 6)
        hand.lift()
        require(hand.move(dx: -14, dy: 0, steps: 6).action == .skipBackward,
                "a second swipe after lifting the fingers did not fire")
    }

    /// One physical movement, reported both ways macOS can report it, is one
    /// gesture. The "natural scrolling" setting flips the sign of the delta
    /// without changing what the hand did, and the app normalises to finger
    /// direction.
    ///
    /// The same movement is pushed in under both settings and must come out as
    /// the same gesture. The check necessarily trusts which sign macOS reports
    /// for which setting, so it pins the app's own model of the platform
    /// (`fingerSign`) and catches it being flipped, not being wrong.
    private static func naturalScrollingDoesNotFlipTheGesture() {
        // Fingers moving right. With natural scrolling on, the delta already
        // follows the fingers and is positive; with it off the device reports
        // the content's direction, the negative of it.
        for (inverted, rightwards) in [(true, CGFloat(14)), (false, CGFloat(-14))] {
            var hand = Hand()
            let sign = SwipeRecogniser.fingerSign(invertedFromDevice: inverted)
            let run = hand.move(dx: rightwards * sign, dy: 0.4, steps: 6)
            require(run.action == .skipForward,
                    "with natural scrolling \(inverted ? "on" : "off"), fingers moving "
                    + "right gave \(run.action) instead of skipping forward")
        }
        // And the mirror, so the check cannot pass by making everything forward.
        for (inverted, leftwards) in [(true, CGFloat(-14)), (false, CGFloat(14))] {
            var hand = Hand()
            let sign = SwipeRecogniser.fingerSign(invertedFromDevice: inverted)
            let run = hand.move(dx: leftwards * sign, dy: -0.4, steps: 6)
            require(run.action == .skipBackward,
                    "with natural scrolling \(inverted ? "on" : "off"), fingers moving "
                    + "left gave \(run.action) instead of skipping back")
        }
    }

    // MARK: The ratchet

    /// The detents are evenly spaced, and the commit counts as the last gap.
    /// The gaps are in distance and a finger slows toward the end of a swipe, so
    /// shrinking gaps would give a rhythm that is neither steady nor
    /// accelerating. Even gaps let the rhythm report finger speed honestly, like
    /// a physical detent, and landing the commit on the same beat puts the
    /// payoff on the ratchet rather than just after it.
    private static func theRatchetIsEvenlySpaced() {
        let at = SwipeRecogniser.detents
        require(at.count >= 3, "a ratchet needs enough clicks to build")
        require(at.last! < 1, "a detent sits at the commit, so the two collide")

        // Boundaries from the start of the swipe to the commit, inclusive: the
        // commit is the final click, not something after the last one.
        var gaps: [CGFloat] = []
        var previous = CGFloat(0)
        for position in at + [1] {
            require(position > previous, "the detents do not climb: \(at)")
            gaps.append(position - previous)
            previous = position
        }
        for gap in gaps.dropFirst() {
            require(abs(gap - gaps[0]) < 1e-9,
                    "the clicks are not evenly spaced, so the rhythm wanders "
                    + "instead of reporting how fast the finger is moving: \(gaps)")
        }
    }

    /// Taken slowly, every click is there, once and in order.
    private static func aSlowSwipeFeelsEveryDetent() {
        var hand = Hand()
        let run = hand.move(dx: 0.75, dy: 0.03, steps: 70)
        require(run.action == .skipForward, "the slow swipe never committed")
        require(run.detents == Array(0..<SwipeRecogniser.detents.count),
                "a slow swipe did not feel each detent once in order: \(run.detents)")
    }

    /// The rate floor must not eat clicks from an ordinary swipe. This is 52 pt
    /// in about 200 ms, the fastest a swipe gets while still being aimed rather
    /// than flicked.
    private static func aBriskSwipeStillFeelsEveryClick() {
        var hand = Hand()
        let run = hand.move(dx: 2.08, dy: 0.08, steps: 26)
        require(run.action == .skipForward, "the brisk swipe never committed")
        require(run.detents == Array(0..<SwipeRecogniser.detents.count),
                "the floor swallowed a click from an ordinary swipe: \(run.detents)")
        for (earlier, later) in zip(run.ticks, run.ticks.dropFirst()) {
            require(later - earlier >= SwipeRecogniser.tickFloor,
                    "two clicks landed \(later - earlier)s apart, inside the "
                    + "\(SwipeRecogniser.tickFloor)s floor")
        }
    }

    /// A flick that clears three detents at once ticks once, not three times:
    /// three taps in one 8 ms frame would be a buzz. The click felt is the
    /// highest one crossed.
    private static func aFlickClicksRatherThanBuzzes() {
        var hand = Hand()
        let step = hand.tap(dx: 40, dy: 0)
        require(step.action == .none, "40pt of a 52pt threshold committed early")
        require(step.detent == 2,
                "one delta across three detents did not report the highest one "
                + "alone: \(String(describing: step.detent))")
    }

    /// Crossing one detent per frame on consecutive frames is still one click.
    /// Each frame honestly reports one new detent, so the highest-crossed rule
    /// alone lets through three taps in 24 ms, which the trackpad's engine
    /// merges into mush; the floor turns that back into a click.
    private static func aFlickDoesNotOutrunTheFloor() {
        var hand = Hand()
        let run = hand.move(dx: 14, dy: 0.3, steps: 4)
        require(run.detents == [0],
                "a flick crossing a detent per frame buzzed instead of clicking: "
                + "\(run.detents)")
        require(run.action == .skipForward, "the flick did not skip")
    }

    /// However fast the swipe, the click that confirms it always plays. The
    /// commit rides the gesture, not the ratchet, so the rate limit cannot reach
    /// it; suppressing a detent costs a little texture, but suppressing the
    /// commit would leave a swipe that worked and said nothing.
    private static func theCommitOutrunsTheFloor() {
        var hand = Hand()
        // Every frame crosses a detent and the last one commits, all inside a
        // single floor interval.
        let run = hand.move(dx: 18, dy: 0.3, steps: 3, dt: 0.004)
        require(run.action == .skipForward,
                "the floor suppressed the commit of a fast swipe")
    }

    /// A flick to pause: a click a frame before the commit. The engine merges taps inside
    /// the floor, so a commit played at once folded into that click and the swipe felt
    /// like nothing. Its haptic waits out the floor; with no click near, it plays at once.
    private static func theCommitIsNotMergedIntoAClick() {
        var flick = SwipeRecogniser()
        let click = flick.add(dx: 0, dy: 40, now: 1)
        require(click.detent != nil, "setup: the flick did not click")
        let commit = flick.add(dx: 0, dy: 20, now: 1.008)
        require(commit.action == .togglePlayback, "setup: the flick did not toggle")
        require(abs(1.008 + commit.commitDelay - (1 + SwipeRecogniser.tickFloor)) < 1e-9,
                "the commit haptic landed \(commit.commitDelay * 1000)ms after the commit, "
                + "inside the floor of the click before it, so the engine merges the two")

        var slow = SwipeRecogniser()
        _ = slow.add(dx: 0, dy: 40, now: 1)
        let late = slow.add(dx: 0, dy: 20, now: 1.2)
        require(late.commitDelay == 0, "a commit well clear of any click was held back")
        var jump = SwipeRecogniser()
        require(jump.add(dx: 60, dy: 0, now: 1).commitDelay == 0,
                "a commit with no click before it was held back")
    }

    /// A click the floor swallowed is spent, not owed. The mark advances on every
    /// crossing, played or not; otherwise the suppressed detent would fire on a
    /// later frame where nothing was crossed, the arrhythmia the floor prevents.
    private static func aSwallowedClickDoesNotComeBackLater() {
        var hand = Hand()
        let burst = hand.move(dx: 14, dy: 0.3, steps: 2)
        require(burst.detents == [0], "setup did not swallow the second click: \(burst.detents)")

        // Long enough that the floor is no longer any excuse for silence.
        hand.pause(0.1)
        let after = hand.move(dx: 1, dy: 0.02, steps: 1)
        require(after.detents.isEmpty,
                "a click the floor swallowed came back once the floor lifted: "
                + "\(after.detents)")
    }

    /// A gesture already refused must not promise anything on the way down. The
    /// diagonal will be rejected at the threshold, so ticking it would build
    /// toward a commit the recogniser has already decided against.
    private static func aDiagonalDragTicksNothing() {
        var hand = Hand()
        let run = hand.move(dx: 12, dy: 12, steps: 10)
        require(run.action == .none, "a diagonal drag fired a gesture")
        require(run.detents.isEmpty,
                "a diagonal drag ticked its way toward a commit it cannot make: "
                + "\(run.detents)")
    }

    /// Drifting back across a detent must not re-arm it. The mark is a
    /// high-water mark, so a hesitant swipe that pulls back and pushes again
    /// does not click on every re-crossing.
    private static func pullingBackDoesNotReRatchet() {
        var hand = Hand()
        let up = hand.move(dx: 0.75, dy: 0.03, steps: 40)
        require(up.detents == [0, 1], "setup did not reach the second detent: \(up.detents)")

        let back = hand.move(dx: -0.75, dy: -0.03, steps: 20)
        require(back.detents.isEmpty, "retreating ticked: \(back.detents)")

        let again = hand.move(dx: 0.75, dy: 0.03, steps: 20)
        require(again.detents.isEmpty,
                "re-crossing detents already felt ticked them again: \(again.detents)")
    }

    /// Once the gesture has fired, the rest of the swipe is silent. Two
    /// mechanisms each ensure this (the recogniser stops reading deltas after
    /// firing, and the mark is already exhausted because committing means
    /// crossing every detent), so no single-point defect fails this check; it is
    /// a net for a change that removes both.
    private static func theRatchetStopsOnceTheGestureHasFired() {
        var hand = Hand()
        require(hand.move(dx: 14, dy: 0, steps: 6).action == .skipForward, "setup did not skip")
        let after = hand.move(dx: 14, dy: 0, steps: 20)
        require(after.detents.isEmpty,
                "the ratchet kept clicking after the gesture fired: \(after.detents)")
        require(after.action == .none, "one continuous swipe fired more than once")
    }

    /// Lifting the fingers clears the mark and the floor, both visible on the
    /// very next frame: a surviving mark starts the new swipe halfway up its own
    /// ratchet, and a surviving floor silences its first click. The new swipe
    /// is therefore given no room to breathe.
    private static func liftingTheFingersRearmsTheRatchet() {
        var hand = Hand()
        let first = hand.move(dx: 14, dy: 0.3, steps: 1)
        require(first.detents == [0], "setup did not click: \(first.detents)")

        hand.lift()
        let second = hand.move(dx: 14, dy: 0.3, steps: 1)
        require(second.detents == [0],
                "the ratchet did not start again from the bottom on the frame "
                + "after the fingers lifted: \(second.detents)")
    }

    // MARK: The indicator

    /// The lean is the swipe made visible: direction, growing travel, and no
    /// banked detents before the first one.
    private static func theLeanFollowsTheFingers() {
        var hand = Hand()
        var previous: CGFloat = 0
        for _ in 0..<8 {
            _ = hand.move(dx: 1.2, dy: 0.05, steps: 1)
            guard let lean = hand.lean else {
                require(false, "a horizontal drift produced no lean"); return
            }
            require(lean.direction == 1,
                    "fingers moving right lean \(lean.direction)")
            require(lean.progress > previous,
                    "the lean did not grow with the fingers: \(lean.progress) "
                    + "after \(previous)")
            require(lean.reached == 0,
                    "a sub-detent drift banked \(lean.reached) clicks")
            previous = lean.progress
        }
        var left = Hand()
        _ = left.move(dx: -1.2, dy: -0.05, steps: 4)
        require(left.lean?.direction == -1, "fingers moving left did not lean left")
    }

    /// A gesture the threshold will refuse never leans: the visual twin of
    /// `aDiagonalDragTicksNothing`.
    private static func aRefusedAxisNeverLeans() {
        var vertical = Hand()
        for _ in 0..<10 {
            _ = vertical.move(dx: 0.3, dy: -4, steps: 1)
            require(vertical.lean == nil, "a vertical swipe leaned")
        }
        var diagonal = Hand()
        for _ in 0..<10 {
            _ = diagonal.move(dx: 4, dy: 4, steps: 1)
            require(diagonal.lean == nil, "a diagonal drag leaned")
        }
    }

    /// Every click the hand has felt is banked in the lean the eye gets. Both
    /// run on the same mark, so the stairs the sheet climbs are the stairs the
    /// ratchet plays.
    private static func theLeanBanksEachDetent() {
        var hand = Hand()
        var felt = 0
        for _ in 0..<50 {
            let run = hand.move(dx: 1, dy: 0.04, steps: 1)
            if let detent = run.detents.first { felt = detent + 1 }
            guard let lean = hand.lean else {
                require(false, "the swipe stopped leaning mid-flight"); return
            }
            require(lean.reached == felt,
                    "the hand has felt \(felt) clicks and the lean banked "
                    + "\(lean.reached)")
        }
        require(felt == SwipeRecogniser.detents.count,
                "the drive never climbed the whole ratchet: \(felt) clicks")
    }

    /// A banked detent is a visible step in the magnet's pull, not just more
    /// travel, matching the click being a sensation rather than a slope.
    private static func theMagnetClimbsTheRatchet() {
        for progress in stride(from: CGFloat(0.3), through: 1.0, by: 0.1) {
            let unbanked = SwipeRecogniser.magnet(
                for: .init(direction: 1, progress: progress, reached: 0))
            let banked = SwipeRecogniser.magnet(
                for: .init(direction: 1, progress: progress, reached: 1))
            require(banked.strength - unbanked.strength >= 0.3,
                    "a banked detent stepped the pull by only "
                    + "\(banked.strength - unbanked.strength) at \(progress)")
        }
    }

    /// Once the gesture has fired the indicator is done. The surge is the
    /// commit's voice, and a surviving lean would promise a second gesture the
    /// recogniser has already refused for this touch.
    private static func aFiredGestureStopsLeaning() {
        var hand = Hand()
        require(hand.move(dx: 14, dy: 0, steps: 6).action == .skipForward,
                "setup did not skip")
        for _ in 0..<20 {
            _ = hand.move(dx: 14, dy: 0, steps: 1)
            require(hand.lean == nil,
                    "the sheet kept leaning after the gesture fired")
        }
    }

    private static func liftingTheFingersClearsTheLean() {
        var hand = Hand()
        _ = hand.move(dx: 2, dy: 0.05, steps: 10)
        require(hand.lean != nil, "setup never leaned")
        hand.lift()
        require(hand.lean == nil, "the lean survived the fingers lifting")
    }

    /// The magnet stays on the visible rim and under the scrub's pull at every
    /// reachable state. The scrub is the one gesture allowed to out-pull it,
    /// because there the hand is on the surface itself.
    private static func theMagnetStaysOnTheRim() {
        for direction in [CGFloat(-1), 1] {
            for progress in stride(from: CGFloat(0), through: 1, by: 0.01) {
                for reached in 0...SwipeRecogniser.detents.count {
                    let m = SwipeRecogniser.magnet(
                        for: .init(direction: direction,
                                   progress: progress, reached: reached))
                    require(m.rim >= 0.05 && m.rim <= 0.95,
                            "the magnet left the rim: \(m.rim)")
                    require(m.strength >= 0 && m.strength <= 1.6,
                            "the magnet out-pulled the scrub: \(m.strength)")
                }
            }
        }
    }

    /// A stray two-finger drift must be near-invisible on both surfaces: a
    /// scroll that merely passes over the notch produces a few points of
    /// horizontal travel, and an indicator that answers it would make the notch
    /// flinch at traffic.
    ///
    /// Two claims, since the small slopes alone keep 3 pt sub-half-point even
    /// without a gate. The gate's signature is the contrast: the ramp opens over
    /// the first tenth of the threshold, so the indicator more than quadruples
    /// between 2 pt and 6 pt, where a bare linear slope only triples. Dropping
    /// the gate from either surface flattens the ratio to 3 and fails here.
    private static func theOnsetGateSwallowsAStray() {
        var stray = Hand()
        _ = stray.move(dx: 1.5, dy: 0.05, steps: 2)
        guard let lean = stray.lean else {
            require(false, "3pt of drift produced no lean to judge"); return
        }
        let m = SwipeRecogniser.magnet(for: lean)
        require(m.strength < 0.05, "3pt of drift pulled the ink at \(m.strength)")
        for expanded in [false, true] {
            let shift = SwipeRecogniser.sheetShift(for: lean, expanded: expanded,
                                                   hudShowing: false)
            require(abs(shift) < 0.5, "3pt of drift moved the sheet \(shift)pt")
        }

        var early = Hand(), open = Hand()
        _ = early.move(dx: 1, dy: 0.03, steps: 2)
        _ = open.move(dx: 1, dy: 0.03, steps: 6)
        guard let at2 = early.lean, let at6 = open.lean else {
            require(false, "the onset drives produced no lean to compare"); return
        }
        let pull2 = SwipeRecogniser.magnet(for: at2).strength
        let pull6 = SwipeRecogniser.magnet(for: at6).strength
        require(pull2 > 0 && pull6 > pull2 * 4,
                "the ink's pull grew only \(pull6 / max(pull2, 1e-12))x from 2pt "
                + "to 6pt — the onset ramp is not suppressing the first touch")
        for expanded in [false, true] {
            let shift2 = SwipeRecogniser.sheetShift(for: at2, expanded: expanded,
                                                    hudShowing: false)
            let shift6 = SwipeRecogniser.sheetShift(for: at6, expanded: expanded,
                                                    hudShowing: false)
            require(shift2 > 0 && shift6 > shift2 * 4,
                    "the sheet's lean grew only \(shift6 / max(shift2, 1e-12))x "
                    + "from 2pt to 6pt (expanded: \(expanded)) — the onset ramp "
                    + "is not suppressing the first touch")
        }
    }

    /// End to end: real deltas through the recogniser and out the chrome rule.
    /// The sheet goes the way the fingers go, further as they travel, and
    /// visibly by the time the swipe is near its commit.
    private static func theSheetLeansTheWayTheFingersGo() {
        for (dx, sign) in [(CGFloat(2), CGFloat(1)), (-2, -1)] {
            var hand = Hand()
            var previous: CGFloat = 0
            for _ in 0..<24 {
                _ = hand.move(dx: dx, dy: 0.05 * sign, steps: 1)
                guard let lean = hand.lean else {
                    require(false, "the swipe stopped leaning mid-flight"); return
                }
                let shift = SwipeRecogniser.sheetShift(for: lean, expanded: true,
                                                       hudShowing: false)
                require(shift == 0 || (shift > 0) == (sign > 0),
                        "the sheet leaned against the fingers: \(shift)")
                require(shift * sign >= previous * sign,
                        "the sheet retreated mid-swipe: \(shift) after \(previous)")
                previous = shift
            }
            require(abs(previous) > 4,
                    "a near-commit swipe moved the sheet only \(previous)pt")
        }
    }

    /// The HUD never leans, whatever the swipe is doing: its meter fills its
    /// flank to the padding, so any shift would slide ink under the camera
    /// housing.
    private static func theHudDoesNotLean() {
        for progress in stride(from: CGFloat(0.2), through: 1, by: 0.2) {
            for expanded in [false, true] {
                let shift = SwipeRecogniser.sheetShift(
                    for: .init(direction: 1, progress: progress, reached: 2),
                    expanded: expanded, hudShowing: true)
                require(shift == 0, "the HUD leaned \(shift)pt")
            }
        }
    }

    // MARK: Driving

    /// A hand on the trackpad: the recogniser plus the clock its deltas arrive on.
    ///
    /// The clock is real time rather than a step count because the rate floor
    /// depends on it. Deltas advance it at the interval a trackpad reports at, so
    /// steps and milliseconds keep the relationship they have under a finger.
    private struct Hand {
        /// A trackpad reports at about 120Hz.
        static let frame: TimeInterval = 0.008

        private var recogniser = SwipeRecogniser()
        private var now: TimeInterval = 0

        /// Every consequence of a run of deltas: the clicks, in the order they
        /// were felt, when each landed, and the gesture if one fired.
        mutating func move(dx: CGFloat, dy: CGFloat, steps: Int, dt: TimeInterval = Hand.frame)
            -> (detents: [Int], action: SwipeRecogniser.Action, ticks: [TimeInterval]) {
            var detents: [Int] = []
            var ticks: [TimeInterval] = []
            var action = SwipeRecogniser.Action.none
            for _ in 0..<steps {
                now += dt
                let step = recogniser.add(dx: dx, dy: dy, now: now)
                if let detent = step.detent {
                    detents.append(detent)
                    ticks.append(now)
                }
                if step.action != .none, action == .none { action = step.action }
            }
            return (detents, action, ticks)
        }

        /// One delta, when the claim is about that delta alone.
        mutating func tap(dx: CGFloat, dy: CGFloat) -> SwipeRecogniser.Step {
            now += Hand.frame
            return recogniser.add(dx: dx, dy: dy, now: now)
        }

        /// Time passing without the fingers moving.
        mutating func pause(_ seconds: TimeInterval) { now += seconds }

        /// The in-flight lean, read the way the coordinator reads it.
        var lean: SwipeRecogniser.Lean? { recogniser.lean }

        /// The fingers leaving the trackpad. Time keeps running.
        mutating func lift() { recogniser.reset() }
    }

    private static func require(_ ok: @autoclosure () -> Bool, _ message: String) {
        guard ok() else {
            FileHandle.standardError.write("gesturecheck: \(message)\n".data(using: .utf8)!)
            exit(1)
        }
    }
}
