import AppKit
import SwiftUI
import Observation

/// Per-display notch state machine.
///
/// Content lives in two independent channels, a transient `notification` (the volume
/// or brightness HUD) and the mini player, so neither can overwrite the other.
///
/// Only the notification has the value/intent split: events write the intent and a
/// generation-guarded transition settles it into the value, so a closing animation
/// finishes instead of being stomped by the next event. `isMiniPlayerShown` is
/// written directly.
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

    // MARK: Presentation state

    private(set) var isVisible = true
    private(set) var isMouseInside = false
    /// The rim's hover light; lit only when the hover will actually open the panel.
    var hoverWillOpen: Bool { isMouseInside && settings.expandNotchOnHover }
    private(set) var isExpanded = false
    /// Held open on purpose rather than because the pointer is here. Without it a menu
    /// toggle could not stick: the pointer is at the menu, outside the notch, so
    /// `mouseExited` would schedule a collapse.
    private(set) var isPinned = false
    /// Distinguishes a hover-opened panel (auto-closes) from a deliberate one.
    private var expandedByHover = false

    private(set) var notification: Notification = .none
    private var notificationIntent: Notification = .none

    /// The closed notch widened to show the cover, time and progress line ("Mini Player
    /// When Closed").
    private(set) var isMiniPlayerShown = false


    /// Progress of the most recent HUD event, 0...1.
    private(set) var hudProgress: Double = 0
    private(set) var hudIsMuted = false

    // MARK: Geometry

    private(set) var collapsedSize: CGSize = .init(width: 190, height: 32)
    /// Height of the menu-bar band. The retracted shell never goes past it.
    private(set) var menuBarHeight: CGFloat = 32
    private(set) var style: NotchShape.Style = .notch

    /// Set by the coordinator from playback state. The idle panel is small; a full
    /// player with every field blank looks broken.
    var hasMedia = false
    /// Set by the coordinator: the track has synced lyrics and the setting is on, so the
    /// open panel carries the lyrics stage.
    var hasLyrics = false

    /// The two-finger swipe in flight, written by the coordinator on every finger delta
    /// and nil when it ends. Only `SwipeLeanFrame` reads it, as a leaf, so a value
    /// mutated at trackpad rate does not invalidate the whole panel body.
    var swipeLean: SwipeRecogniser.Lean?

    /// Body height below the cutout. The panel's total height adds the notch band on
    /// top, because the shape grows out of the notch. It is the sum of what the body
    /// lays out; `ChromeRules.expandedBodyFits` asserts it, since a shorter value makes
    /// SwiftUI squeeze the content.
    static let expandedBodyHeight = ChromeRules.expandedBody
    /// The window is sized from this once and never resized, so it covers the largest
    /// panel plus the shadow's margin. The 40 is the tallest menu-bar band it has to
    /// work under; the band is hardware.
    static let maxExpandedSize = CGSize(width: ChromeRules.panelWidth,
                                        height: 40 + expandedBodyHeight + ChromeRules.lyricsBody)

    var expandedSize: CGSize {
        let band = collapsedSize.height
        return hasMedia
            ? CGSize(width: ChromeRules.panelWidth,
                     height: band + Self.expandedBodyHeight + (hasLyrics ? ChromeRules.lyricsBody : 0))
            : CGSize(width: 232, height: band + 40)
    }

    /// The physical cutout, which the shape must match through the menu-bar band.
    var notchSize: CGSize { collapsedSize }

    var currentSize: CGSize { isExpanded ? expandedSize : collapsedSizeForContent }

    /// Un-hovered, the player never leaves the menu bar: anything below it sits over
    /// tabs and toolbars, where people's hands are. Peeks and HUDs only widen. The rule
    /// is `ChromeRules.retractedSize`, so it can be asserted.
    private var collapsedSizeForContent: CGSize {
        ChromeRules.retractedSize(collapsed: collapsedSize,
                                  band: menuBarHeight,
                                  hasContent: isMiniPlayerShown || notification.isSome)
    }

    /// Goes to zero when expanded, so the shoulders unroll into the bezel.
    var topCornerRadius: CGFloat { isExpanded ? 0 : 9 }
    /// Collapsed, the shell is only the band tall and a 13 pt curve would bow the bar.
    /// The pill case goes through the silhouette's own radius rule, since the trace,
    /// the trim mapping and the rim all read this property; the shape re-applies the
    /// rule idempotently.
    var bottomCornerRadius: CGFloat {
        let base: CGFloat = isExpanded ? (hasMedia ? 24 : 18) : cutoutCornerRadius
        guard style == .pill else { return base }
        return NotchShape.pillCornerRadius(height: currentSize.height,
                                           bottomCornerRadius: base)
    }

    /// The hardware cutout's bottom corner radius. No API reports it, so it is an
    /// estimate, adjustable like width and height. The shell and the ink pool both
    /// read it so their corners agree at the cutout's edge.
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
        // The true menu-bar height, not `safeAreaInsets.top`: that is the cutout's
        // height (32) while the band is a point taller (33). Clamped to the band rather
        // than widened past it, since a notchless display's pill can exceed the menu bar
        // and the retracted shell must stay off window chrome. The fallback is the cutout
        // (see `ChromeRules.retractedBand`).
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
        // A pinned panel stays until it is unpinned.
        guard !isPinned else { return }
        // Otherwise always retract; a deliberate open just gets a longer grace period
        // than a hover one.
        hoverClose.schedule(after: .milliseconds(expandedByHover ? 320 : 850)) { [weak self] in
            self?.collapse()
        }
    }

    /// The per-display arm of a toggle; pins on the way open. The menu command and
    /// `magnetite://toggle` go through `NotchCoordinator.toggleAll()` instead, which
    /// decides open or closed once from the aggregate; calling this per controller from
    /// a command path inverts the state across displays.
    func toggle() {
        if isExpanded {
            collapse()
        } else {
            expand(byHover: false, pinned: true)
        }
    }

    // MARK: Expansion

    func expand(byHover: Bool = false, pinned: Bool = false) {
        // A hidden notch cannot be opened. The URL scheme and menu command do not go
        // through the window, so without this they could pin an invisible panel open
        // over a fullscreen video.
        guard isVisible else { return }
        guard !isExpanded else { return }
        isPinned = pinned
        expandedByHover = byHover
        isExpanded = true
        onExpansionChange?(true)
        // A HUD should not linger behind the expanded panel.
        notificationClose.now { [weak self] in self?.clearNotification() }
        // Safety net for non-hover opens: mouse-exit only fires if the pointer moves, so
        // a scripted or menu-driven open with a stationary pointer would stay up.
        if !byHover, !pinned {
            autoRetract.schedule(after: .seconds(5)) { [weak self] in
                guard let self, !self.isMouseInside else { return }
                self.collapse()
            }
        }
    }

    /// Fired after `isExpanded` settles so the fluid learns the panel moved. Both call
    /// sites are guarded, so it cannot fire on a no-op.
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

    /// Shows a HUD. Repeated calls (key repeat) refresh the value and push the
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

        notificationClose.schedule(after: .seconds(settings.hudDuration)) { [weak self] in
            self?.clearNotification()
        }
    }

    /// Also called when Focus Mode switches on, to pull down a HUD that is already up.
    func clearNotification() {
        notificationSwap.cancel()
        notificationIntent = .none
        notification = .none
    }

    // MARK: Live activity

    /// Shows the mini player in the flanks and keeps it there while a track is loaded.
    /// It stays inside the cutout's height, so it never covers anything below the menu
    /// bar.
    func showMiniPlayer() {
        // Written only on transition, since `syncMiniPlayerAndCapture` calls this every
        // poll. A same-value write to an `Equatable` property notifies nobody, so the
        // guard is redundant for `Bool`; it keeps an every-poll write from invalidating
        // the whole panel if the type ever stops being `Equatable`.
        if !isMiniPlayerShown { isMiniPlayerShown = true }
    }

    func hideMiniPlayer() {
        if isMiniPlayerShown { isMiniPlayerShown = false }
    }

    // MARK: Visibility

    func setVisible(_ visible: Bool) {
        guard isVisible != visible else { return }
        isVisible = visible
        if !visible {
            hoverOpen.cancel()
            collapse()
            // Forget where the pointer was. Hiding does not move the mouse, so nothing
            // reports an exit; left true, `handleMouseMoved` never sees the false-to-true
            // edge when the notch returns and hover stays dead until the pointer leaves the
            // region and comes back.
            isMouseInside = false
        }
    }
}
