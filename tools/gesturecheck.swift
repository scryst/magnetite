import Foundation
import CoreGraphics

/// Headless checks on swipe recognition.
///
/// NSEvents cannot reasonably be synthesised, so the alternative to this file is
/// swiping and looking — and "verified by eye" has been wrong more than once in
/// this project. These drive the recogniser directly with the deltas a trackpad
/// would produce.
///
/// The ratchet is checked here for a sharper version of the same reason: a
/// haptic cannot be verified by eye at all, and nothing else in this project can
/// be verified only by hand. What a check can still hold is every decision
/// behind the sensation — where the clicks land, that they are evenly spaced and
/// the commit lands on the same beat, that a flick produces clicks rather than a
/// buzz, and that a gesture on its way to being refused stays silent. What it
/// cannot reach is whether the result feels good, which is why the recogniser
/// says *when* and `NotchGestures` says *what*.
///
/// The clock is an argument rather than something the recogniser reads, so the
/// rate limit — the one part of this that only exists because of hardware
/// timing — is as drivable as the geometry.
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

    /// Deltas reach the recogniser in FINGER direction: right goes forward.
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

    /// One physical movement, both ways macOS reports it, one gesture.
    ///
    /// The user's "natural scrolling" setting flips the sign of the delta
    /// without changing what the hand did, so the app normalises to finger
    /// direction — and got the normalisation backwards, inverting the one case
    /// that was already correct. Swiping right went back a track, for everyone
    /// with the default setting.
    ///
    /// The scenario, not the ternary: the same movement is pushed in under both
    /// settings and has to come out as the same gesture. What it necessarily
    /// takes on trust is which sign macOS reports for which setting, since no
    /// headless check can ask the trackpad — so it pins the app's own model of
    /// the platform, stated in `fingerSign`, and would catch that model being
    /// flipped rather than being wrong in the first place.
    private static func naturalScrollingDoesNotFlipTheGesture() {
        // Fingers moving RIGHT. With natural scrolling on the delta already
        // follows the fingers and is positive; with it off the device reports
        // the content's direction instead, which is the negative of it.
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

    /// The spacing is the whole design, so the spacing is the claim.
    ///
    /// Evenness is not a tidiness preference here. These gaps are in *distance*,
    /// and a finger arrives at the end of a swipe slower than it left — so gaps
    /// that shrink toward the commit, which is what this used to assert, produce
    /// a rhythm under a real hand that is neither steady nor accelerating. Even
    /// gaps let the rhythm report finger speed honestly, the way a physical
    /// detent does.
    ///
    /// The commit counts as the last gap. Landing it on the same beat is what
    /// makes the payoff arrive *on* the ratchet rather than just after it.
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

    /// Taken slowly, every click is there — once, and in order.
    private static func aSlowSwipeFeelsEveryDetent() {
        var hand = Hand()
        let run = hand.move(dx: 0.75, dy: 0.03, steps: 70)
        require(run.action == .skipForward, "the slow swipe never committed")
        require(run.detents == Array(0..<SwipeRecogniser.detents.count),
                "a slow swipe did not feel each detent once in order: \(run.detents)")
    }

    /// The floor must not eat clicks out of an ordinary swipe.
    ///
    /// A rate limit that a normal hand can trip is not a rate limit, it is a
    /// dropped click. This is 52pt in about 200ms — brisk, and the fastest a
    /// swipe gets while still being aimed rather than flicked.
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

    /// A flick that clears three detents at once ticks once, not three times.
    ///
    /// Three taps inside one 8ms frame is a buzz, and a buzz is what this would
    /// be if every crossed detent reported. The click you feel is the highest
    /// one crossed, so the ladder that plays follows how deliberately you swiped
    /// rather than how many boundaries the delta happened to jump.
    private static func aFlickClicksRatherThanBuzzes() {
        var hand = Hand()
        let step = hand.tap(dx: 40, dy: 0)
        require(step.action == .none, "40pt of a 52pt threshold committed early")
        require(step.detent == 2,
                "one delta across three detents did not report the highest one "
                + "alone: \(String(describing: step.detent))")
    }

    /// Crossing detents on consecutive frames is still one click, not a burst.
    ///
    /// One delta per detent slips past the highest-crossed rule — each frame
    /// honestly reports one new detent — and lands three taps inside 24ms, which
    /// the trackpad's engine merges into mush at exactly the moment the gesture
    /// is trying to feel decisive. The floor is what turns that back into a
    /// click.
    private static func aFlickDoesNotOutrunTheFloor() {
        var hand = Hand()
        let run = hand.move(dx: 14, dy: 0.3, steps: 4)
        require(run.detents == [0],
                "a flick crossing a detent per frame buzzed instead of clicking: "
                + "\(run.detents)")
        require(run.action == .skipForward, "the flick did not skip")
    }

    /// However fast the swipe, the click that confirms it always plays.
    ///
    /// The commit rides the gesture, not the ratchet, so no rate limit can reach
    /// it. This is the load-bearing half of the floor: suppressing a detent
    /// costs a little texture, and suppressing the commit would mean a swipe
    /// that worked and said nothing.
    private static func theCommitOutrunsTheFloor() {
        var hand = Hand()
        // Every frame crosses a detent *and* the last one commits, all inside a
        // single floor interval.
        let run = hand.move(dx: 18, dy: 0.3, steps: 3, dt: 0.004)
        require(run.action == .skipForward,
                "the floor suppressed the commit of a fast swipe")
    }

    /// A click the floor swallowed is spent, not owed.
    ///
    /// The mark advances on every crossing, played or not. If it only advanced
    /// on the ones that played, a suppressed detent would sit there waiting and
    /// fire on some later frame — landing a click on a stretch of swipe where
    /// nothing was crossed, which is precisely the arrhythmia the floor exists
    /// to prevent.
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

    /// A gesture already refused must not promise anything on the way down.
    ///
    /// The diagonal is going to be rejected at the threshold, so ticking it
    /// would have the ratchet building toward a commit the recogniser has
    /// already decided against — worse than silence, because it is a lie you can
    /// feel.
    private static func aDiagonalDragTicksNothing() {
        var hand = Hand()
        let run = hand.move(dx: 12, dy: 12, steps: 10)
        require(run.action == .none, "a diagonal drag fired a gesture")
        require(run.detents.isEmpty,
                "a diagonal drag ticked its way toward a commit it cannot make: "
                + "\(run.detents)")
    }

    /// Drifting back across a detent must not re-arm it.
    ///
    /// Hesitate mid-swipe — pull back, push again — and a position-based ratchet
    /// would click every time you re-crossed the same boundary. The mark is a
    /// high-water mark, so the swipe only ever climbs.
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

    /// Once the gesture has gone, the rest of the swipe is silent.
    ///
    /// Two mechanisms hold this and either would do: the recogniser stops
    /// reading deltas once it has fired, and the mark is exhausted anyway,
    /// because committing means having crossed every detent below the commit.
    /// Breaking one alone leaves the ratchet quiet, so this is the one check
    /// here that no single-point defect can fail — it is a net under a future
    /// change that removes both, not proof that today's code is right.
    private static func theRatchetStopsOnceTheGestureHasFired() {
        var hand = Hand()
        require(hand.move(dx: 14, dy: 0, steps: 6).action == .skipForward, "setup did not skip")
        let after = hand.move(dx: 14, dy: 0, steps: 20)
        require(after.detents.isEmpty,
                "the ratchet kept clicking after the gesture fired: \(after.detents)")
        require(after.action == .none, "one continuous swipe fired more than once")
    }

    /// Lifting the fingers clears the mark *and* the floor.
    ///
    /// Both halves matter on the very next frame: a mark that survives leaves
    /// the new swipe starting halfway up its own ratchet, and a floor that
    /// survives silences the first click of a swipe that has earned it — the
    /// second one is invisible to any check that gives the new swipe room to
    /// breathe, so this one deliberately does not.
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

    /// The lean is the swipe made visible: direction, growing travel, no banks
    /// before the first detent.
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

    /// A gesture the threshold is going to refuse never leans — the visual
    /// twin of `aDiagonalDragTicksNothing`: an indicator for a refused gesture
    /// is a promise the recogniser has already declined to make.
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

    /// Every click the hand has felt is banked in the lean the eye gets — the
    /// two run on the same mark, so the stairs the sheet climbs are the stairs
    /// the ratchet plays.
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

    /// A banked detent is a visible step in the pull, not just more travel —
    /// the magnet's version of the click being a sensation rather than a slope.
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

    /// Once the gesture has fired, the indicator is done: the surge is the
    /// commit's voice, and a lean that survived it would promise a second
    /// gesture the recogniser has already refused for this touch.
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
    /// reachable state — the scrub is the one gesture allowed to out-pull it,
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

    /// A stray two-finger drift is sub-visible on both surfaces. Every scroll
    /// that merely passes over the notch produces a few points of horizontal
    /// travel, and an indicator that answers it makes the notch flinch at
    /// traffic.
    ///
    /// Two claims, because the first cannot hold the gate alone: the slopes
    /// are small enough that 3pt stays sub-half-point even ungated. The gate's
    /// own signature is the CONTRAST — the ramp opens over the first tenth of
    /// the threshold, so the indicator more than quadruples between 2pt and
    /// 6pt of travel, where a bare linear slope only triples. Dropping the
    /// gate from either surface flattens that ratio to 3 and fails here.
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

    /// End to end: real deltas, through the recogniser, out the chrome rule.
    /// The sheet goes the way the fingers go, further the further they travel,
    /// and visibly by the time the swipe is near its commit.
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
    /// flank to the padding, so any shift slides ink under the camera housing.
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
    /// The clock is real time, not a step count, because the floor is the one
    /// decision here that depends on it. Deltas advance it at the interval a
    /// trackpad actually reports at, so "steps" and "milliseconds" stay in the
    /// same relationship they have under a real finger.
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
