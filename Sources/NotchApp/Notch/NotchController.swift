import AppKit
import SwiftUI
import Observation

/// Per-display notch state machine.
///
/// Content lives in two independent channels — a transient `notification` and a
/// `liveActivity` that persists while a track is loaded — so a HUD and the
/// now-playing peek cannot overwrite each other.
///
/// Only the notification carries the value/intent split it was built for: events
/// write the intent and a generation-guarded transition settles it into the
/// value, which is what lets a closing animation finish instead of being stomped
/// by the next event. `liveActivity` is written directly; its swap transition was
/// only ever cancelled, never scheduled, and went with this comment's third
/// channel.
@MainActor
@Observable
final class NotchController {

    // MARK: Content channels

    enum Notification: Equatable {
        case none
        case didChangeVolume
        case didChangeBrightness

        var isSome: Bool { self != .none }
    }

    enum LiveActivity: Equatable {
        case none
        case isPlaying

        var isSome: Bool { self != .none }
    }

    // MARK: Presentation state

    private(set) var isVisible = true
    private(set) var isMouseInside = false
    private(set) var isExpanded = false
    /// Held open on purpose, rather than because the pointer happens to be here.
    ///
    /// Without this a menu toggle could never stick: the pointer is at the menu,
    /// i.e. outside the notch, so `mouseExited` scheduled a collapse 850ms later
    /// and the 5s auto-retract armed on top of it. The panel opened and shut on
    /// its own, which is not what a toggle means.
    private(set) var isPinned = false
    /// Distinguishes a hover-opened panel (auto-closes) from a deliberately
    /// opened one (stays until dismissed).
    private var expandedByHover = false

    private(set) var notification: Notification = .none
    private var notificationIntent: Notification = .none

    private(set) var liveActivity: LiveActivity = .none


    /// Progress of the most recent HUD event, 0...1.
    private(set) var hudProgress: Double = 0
    private(set) var hudIsMuted = false

    // MARK: Geometry

    private(set) var collapsedSize: CGSize = .init(width: 190, height: 32)
    /// Height of the menu-bar band (`safeAreaInsets.top`). The retracted shell is
    /// never allowed past this line.
    private(set) var menuBarHeight: CGFloat = 32
    private(set) var style: NotchShape.Style = .notch

    /// Set by the coordinator from playback state. The idle panel is deliberately
    /// small — the full player with every field blank just looks broken.
    var hasMedia = false

    /// The two-finger swipe in flight over the notch, written by the
    /// coordinator on every finger delta and nil the moment it ends. Only
    /// `SwipeLeanFrame` reads it — a leaf, for the same reason `MeshField` is
    /// one: a value mutated at trackpad rate must not sit in a body the whole
    /// panel re-evaluates from. `Lean` is Equatable, so the repeated nil
    /// writes between swipes notify nobody (see `showNowPlaying`).
    var swipeLean: SwipeRecogniser.Lean?

    /// Widest the panel ever gets. The window is sized from this once and then
    /// never resized, so the morph stays pure SwiftUI interpolation.
    /// Body height *below* the cutout. Total panel height adds the notch band on
    /// top, because the shape grows out of the notch rather than over it.
    /// Sized to what the body actually lays out, not to a round number.
    ///
    /// At 90 the panel was 4pt SHORTER than its own contents: the band, the
    /// 24pt gap under it, the 56pt artwork row and the 14pt bottom margin sum to
    /// 126 against 122. The gap carries `minLength`, so it cannot absorb the
    /// difference and SwiftUI squeezes the content instead — which is why the
    /// body read as crowded into the bottom of the panel. See
    /// `ChromeRules.expandedBodyFits`, which now asserts this.
    static let expandedBodyHeight = ChromeRules.expandedBody
    /// The window is sized from this ONCE and never resized, so it has to cover
    /// the largest panel plus the shadow's margin. The `40` is the widest
    /// menu-bar band this has to work under, not the 32pt cutout — the panel is
    /// `band + expandedBodyHeight` and the band is hardware.
    static let maxExpandedSize = CGSize(width: ChromeRules.panelWidth,
                                        height: 40 + expandedBodyHeight)

    var expandedSize: CGSize {
        let band = collapsedSize.height
        return hasMedia
            ? CGSize(width: ChromeRules.panelWidth, height: band + Self.expandedBodyHeight)
            : CGSize(width: 232, height: band + 40)
    }

    /// The physical cutout, which the shape must match exactly through the
    /// menu-bar band.
    var notchSize: CGSize { collapsedSize }

    var currentSize: CGSize { isExpanded ? expandedSize : collapsedSizeForContent }

    /// Un-hovered, the player **never leaves the menu bar**.
    ///
    /// Anything hanging below the band sits on top of browser tabs, toolbars and
    /// window chrome, which is exactly where people's hands are. So peeks and HUDs
    /// only ever widen, never grow down.
    ///
    /// The rule itself lives in `ChromeRules.retractedSize` so it can be asserted
    /// — a peek fills the band exactly, an idle shell is clamped to it — and this
    /// is the call site.
    private var collapsedSizeForContent: CGSize {
        ChromeRules.retractedSize(collapsed: collapsedSize,
                                  band: menuBarHeight,
                                  hasContent: liveActivity.isSome || notification.isSome)
    }

    /// Goes to zero expanded, so the shoulders unroll into the bezel rather than
    /// switching shape.
    var topCornerRadius: CGFloat { isExpanded ? 0 : 9 }
    /// Retracted the shell is only the menu-bar band tall, so a 13pt underside
    /// curve ate most of its height and bowed the bar. Scaled to what's there.
    ///
    /// The pill case routes through the silhouette's own radius rule, because
    /// this property is what the trace, the trim mapping and the rim all read:
    /// hand them the raw cutout radius and they draw a corner the pill
    /// silhouette (which floors its radius) will not. The shape re-applies the
    /// rule internally and it is idempotent, so silhouette and consumers
    /// cannot disagree about which corner was meant.
    var bottomCornerRadius: CGFloat {
        let base: CGFloat = isExpanded ? (hasMedia ? 24 : 18) : cutoutCornerRadius
        guard style == .pill else { return base }
        return NotchShape.pillCornerRadius(height: currentSize.height,
                                           bottomCornerRadius: base)
    }

    /// The hardware cutout's own bottom corners.
    ///
    /// Not reported by any API — `safeAreaInsets` and the auxiliary areas
    /// describe a rectangle — so it is a guess, and adjustable like the width and
    /// the height. The shell and the ink pool BOTH read it: they had independent
    /// guesses of 9 and 6, so the ink's corners were squarer than the shell they
    /// sit inside and the two came apart exactly at the cutout's edge.
    var cutoutCornerRadius: CGFloat { max(0, 9 + CGFloat(settings.notchAdjustedRadius)) }

    // MARK: Wiring

    let displayUUID: String
    private(set) weak var screen: NSScreen?

    private let hoverOpen = Transition()
    private let hoverClose = Transition()
    private let notificationSwap = Transition()
    private let notificationClose = Transition()
    private let autoRetract = Transition()

    private var settings: Settings { .shared }

    init(screen: NSScreen) {
        self.screen = screen
        self.displayUUID = ScreenMetrics.displayUUID(for: screen)
        refreshMetrics(for: screen)
    }

    func refreshMetrics(for screen: NSScreen) {
        self.screen = screen
        collapsedSize = ScreenMetrics.collapsedSize(for: screen, settings: settings)
        // The true menu-bar height, which is NOT safeAreaInsets.top: that is the
        // cutout's height (32), while the band itself is a point taller (33). Using
        // the inset left the retracted shell — and the progress trace riding its
        // bottom edge — sitting a pixel above the menu bar's own bottom line.
        // Clamp to the band, do not widen past it. On a display with no notch
        // the pill's own height can exceed the menu bar, and taking the max let
        // the retracted shell hang below it — onto exactly the window chrome the
        // retracted state exists to stay off.
        //
        // The fallback is the cutout rather than the shell's own height, which
        // defeated that clamp whenever the band could not be measured. See
        // `ChromeRules.retractedBand`.
        menuBarHeight = ChromeRules.retractedBand(
            measured: screen.frame.maxY - screen.visibleFrame.maxY,
            cutout: ScreenMetrics.notchRect(for: screen)?.height)
        style = ScreenMetrics.style(for: screen, settings: settings)
    }

    // MARK: Hover

    func mouseEntered() {
        isMouseInside = true
        hoverClose.cancel()
        guard settings.expandNotchOnHover else { return }
        hoverOpen.schedule(after: .seconds(settings.hoverDuration)) { [weak self] in
            self?.expand(byHover: true)
        }
    }

    func mouseExited() {
        isMouseInside = false
        hoverOpen.cancel()
        // A pinned panel stays until it is unpinned. Everything else retracts.
        guard !isPinned else { return }
        // *Always* retract. Leaving a deliberately-opened panel up until it's
        // dismissed sounds reasonable but in practice means a full-size player
        // sitting over the menu bar long after the pointer has gone. A
        // deliberate open just gets a longer grace period than a hover one.
        hoverClose.schedule(after: .milliseconds(expandedByHover ? 320 : 850)) { [weak self] in
            self?.collapse()
        }
    }

    /// The per-display arm of a toggle. The menu command and `magnetite://toggle`
    /// do NOT come here — they go through `NotchCoordinator.toggleAll()`, which
    /// decides open/closed once from the aggregate; calling this per-controller
    /// from a command path reproduces the cross-display inversion documented
    /// there. Exercised headlessly by tools/controllercheck.swift. Pins on the
    /// way open.
    func toggle() {
        if isExpanded {
            collapse()
        } else {
            expand(byHover: false, pinned: true)
        }
    }

    // MARK: Expansion

    func expand(byHover: Bool = false, pinned: Bool = false) {
        // A hidden notch cannot be opened. Ordering the window out already stops
        // hover reaching it, but the URL scheme and the menu command do not go
        // through the window at all — without this they could pin an invisible
        // panel open over someone's fullscreen video.
        guard isVisible else { return }
        guard !isExpanded else { return }
        isPinned = pinned
        expandedByHover = byHover
        isExpanded = true
        onExpansionChange?(true)
        // A HUD notification shouldn't linger behind the expanded panel.
        notificationClose.now { [weak self] in self?.clearNotification() }
        // Safety net for opens that didn't come from hover: mouse-exit only fires
        // if the pointer actually moves, so a scripted or menu-driven expand with
        // a stationary pointer elsewhere would otherwise stay up forever.
        if !byHover, !pinned {
            autoRetract.schedule(after: .seconds(5)) { [weak self] in
                guard let self, !self.isMouseInside else { return }
                self.collapse()
            }
        }
    }

    /// Fired after `isExpanded` settles, so the fluid learns the panel moved.
    /// Both call sites are already guarded, so this cannot fire on a no-op.
    var onExpansionChange: ((Bool) -> Void)?

    func collapse() {
        guard isExpanded else { return }
        autoRetract.cancel()
        isPinned = false
        expandedByHover = false
        isExpanded = false
        onExpansionChange?(false)
    }

    // MARK: Notifications (transient HUDs)

    /// Show a HUD. Repeated calls (key repeat) refresh the value and push the
    /// dismissal out rather than restarting the animation.
    func present(_ kind: Notification, progress: Double, isMuted: Bool = false) {
        guard !isExpanded else { return }
        hudProgress = min(max(progress, 0), 1)
        hudIsMuted = isMuted
        notificationIntent = kind

        if notification != kind {
            notificationSwap.schedule(after: .milliseconds(notification.isSome ? 90 : 0)) { [weak self] in
                guard let self else { return }
                self.notification = self.notificationIntent
            }
        }

        notificationClose.schedule(after: .seconds(settings.peekDuration)) { [weak self] in
            self?.clearNotification()
        }
    }

    /// Also called when Focus Mode is switched on, to pull down whatever HUD is
    /// already up rather than letting it finish its dwell.
    func clearNotification() {
        notificationSwap.cancel()
        notificationIntent = .none
        notification = .none
    }

    // MARK: Live activity

    /// Show now-playing in the flanks and *keep* it there while a track is
    /// loaded. It lives entirely inside the cutout's height, so it never covers
    /// anything below the menu bar — and it's what makes the retracted player
    /// readable at all instead of a bare outline.
    func showNowPlaying() {
        // On transition, because `syncLiveActivity` calls this on every poll.
        //
        // This comment used to read "Observation fires on ASSIGNMENT", and on
        // Swift 6.4 that is only true of a property whose type is NOT
        // `Equatable`: the generated setter compares first, and a same-value
        // write to an Equatable one notifies nobody. `LiveActivity` is
        // Equatable, so the guard below is belt-and-braces today — measured, by
        // a mutant that removed it and could not be told apart from the
        // original.
        //
        // It stays, and the rule is worth keeping straight rather than
        // deleting, because the half of it that still bites is the half that is
        // easy to walk into: drop the `Equatable` conformance, or add an
        // observable property of a type that never had one, and an
        // every-poll write goes back to invalidating the whole panel once a
        // second to say that nothing has changed.
        if liveActivity != .isPlaying { liveActivity = .isPlaying }
    }


    func clearLiveActivity() {
        if liveActivity != .none { liveActivity = .none }
    }

    // MARK: Visibility

    func setVisible(_ visible: Bool) {
        guard isVisible != visible else { return }
        isVisible = visible
        if !visible {
            hoverOpen.cancel()
            collapse()
            // Forget where the pointer was.
            //
            // Hiding does not move the mouse, so nothing ever reports an exit —
            // the notch simply stops being anywhere, which is what
            // `isOverNotch` already says. Left believing the pointer is inside,
            // the controller never sees an ENTRY when the notch comes back:
            // `handleMouseMoved` only calls `mouseEntered` on the false-to-true
            // edge, and the flag never went false. So a pointer parked over the
            // notch through a fullscreen video found the notch deaf to it
            // afterwards — hover did nothing until the pointer left the region
            // entirely and came back.
            isMouseInside = false
        }
    }
}
