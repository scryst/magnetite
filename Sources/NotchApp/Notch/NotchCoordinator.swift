import AppKit
import SwiftUI

/// Owns one notch per display and routes system events to them.
///
/// Hover is detected with a global mouse monitor rather than a tracking area, which
/// keeps the collapsed window fully click-through (`ignoresMouseEvents = true`).
@MainActor
final class NotchCoordinator {

    private struct Host {
        let controller: NotchController
        let panel: NotchPanel
        let hosting: NotchHostingView<NotchRootView>
    }

    private var hosts: [String: Host] = [:]

    /// Internal so the status menu can reach the Spotify library connection.
    let media = MediaManager()
    private let audio = AudioLevels()
    private let fluid = FerrofluidSim()
    private let volume = VolumeManager()
    private let brightness = BrightnessManager()
    private var settings: Settings { .shared }

    private nonisolated(unsafe) var globalMouse: Any?
    private nonisolated(unsafe) var localMouse: Any?

    private var audioAttached = false
    /// Capture outlives a pause by this much so the ink settles instead of freezing
    /// mid-peak, then stops: a running tap is an aggregate device, and coreaudiod holds
    /// an idle-sleep assertion while one runs.
    private static let settleAfterPause: Duration = .seconds(3)
    private var settleDeadline: ContinuousClock.Instant?
    /// With the mini player off, capture outlives a close by this long, so the ink
    /// drains with sound under it and a quick re-hover finds it live. Tearing the tap
    /// down on every close also flickers the system's capture indicator.
    private static let holdAfterClose: Duration = .seconds(3)
    private var closeHoldDeadline: ContinuousClock.Instant?
    private var wasPlaying = false
    private var lastSurgedToken = -1
    private var systemHidden: Bool { lockedOrSaver || displaysAsleep }
    private var lockedOrSaver = false
    /// Separate from the lock flag: displays wake before the user unlocks, and a shared
    /// flag would show the panel over the lock screen.
    private var displaysAsleep = false
    private var clickAway: Any?
    private let gestures = NotchGestures()

    /// Room around the expanded panel for its shadow to fall into. It must exceed where
    /// the shadow's ink ends or the window edge cuts the bloom into a hard line: the
    /// shadow (radius 28, y 14, black 0.5) holds at least 1/255 out to 57.5 pt beside
    /// and 70 pt below the panel. Width covers both sides; height is all below, since
    /// the panel hangs from the screen's top edge.
    private static let margin = CGSize(width: 128, height: 78)

    init() {
        observeReduceMotion()
        rebuild()
        installMouseMonitors()
        installScreenObserver()
        installEnvironmentObservers()
        installGestures()
        wireSystemSources()
    }

    /// Tracks Reduce Motion, now and whenever the user changes it.
    private func observeReduceMotion() {
        Motion.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        fluid.reduceMotion = Motion.reduceMotion
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                self.fluid.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
                Motion.reduceMotion =
                    NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            }
        }
    }

    deinit {
        if let globalMouse { NSEvent.removeMonitor(globalMouse) }
        if let localMouse { NSEvent.removeMonitor(localMouse) }
        if let clickAway { NSEvent.removeMonitor(clickAway) }
    }

    // MARK: Build

    func rebuild() {
        var seen = Set<String>()

        for screen in NSScreen.screens {
            let uuid = ScreenMetrics.displayUUID(for: screen)
            seen.insert(uuid)

            if let existing = hosts[uuid] {
                existing.controller.refreshMetrics(for: screen)
                position(existing, on: screen)
                continue
            }

            let controller = NotchController(screen: screen)
            let panelSize = CGSize(
                width: NotchController.maxExpandedSize.width + Self.margin.width,
                height: NotchController.maxExpandedSize.height + Self.margin.height)
            let frame = NSRect(x: screen.frame.midX - panelSize.width / 2,
                               y: screen.frame.maxY - panelSize.height,
                               width: panelSize.width,
                               height: panelSize.height)

            let panel = NotchPanel(contentRect: frame)
            panel.applyScreenCapturePolicy(hidden: settings.hideFromScreenCapture)

            let root = NotchRootView(controller: controller, media: media, fluid: fluid)
            // The aggregate, never one controller's state: `fluid` is shared while controllers
            // are per display, so one display's hover-close must not close the fluid while
            // another is open. The `open ||` covers the first rebuild, when the controller
            // exists but is not in `hosts` yet.
            controller.onExpansionChange = { [weak self] open in
                guard let self else { return }
                self.fluid.setOpen(open || self.anyExpanded)
                if !open, !self.anyExpanded {
                    self.closeHoldDeadline = .now + Self.holdAfterClose
                    Task { @MainActor [weak self] in
                        try? await Task.sleep(for: Self.holdAfterClose)
                        self?.syncMiniPlayerAndCapture()
                    }
                }
                // Capture is gated on `anyExpanded` when the closed strip is off, and this is the
                // only place expansion changes.
                self.syncMiniPlayerAndCapture()
            }
            let hosting = NotchHostingView(rootView: root)
            hosting.frame = NSRect(origin: .zero, size: panelSize)
            hosting.autoresizingMask = [.width, .height]
            // Exactly the drawn shell; keeping the panel open is the hover zone's job.
            hosting.shellSize = { [weak controller] in controller?.currentSize ?? .zero }

            panel.contentView = hosting
            panel.orderFrontRegardless()

            hosts[uuid] = Host(controller: controller, panel: panel, hosting: hosting)
        }

        // Tear down notches for displays that went away.
        for (uuid, host) in hosts where !seen.contains(uuid) {
            host.panel.orderOut(nil)
            host.panel.contentView = nil
            // Release this display's polling token; it is keyed by displayUUID and would
            // otherwise pin the media poller at its fast rate.
            media.endPolling(.notchExpanded(uuid))
            hosts.removeValue(forKey: uuid)
        }

        // Recompute after teardown: a display unplugged while expanded takes its
        // `onExpansionChange` with it, and `setOpen` is idempotent, so the fluid would stay
        // open and the next hover on another display would pour nothing.
        fluid.setOpen(anyExpanded)

        // A host created mid-song starts with `hasMedia` false and would show the bare
        // cutout until the track changed. Unconditional, since a teardown can also flip
        // `anyExpanded`, which the capture gate reads.
        syncMiniPlayerAndCapture()

        // Corrects hosts that did not exist when the environment last changed, such as a
        // display hot-plugged while hidden.
        refreshEnvironment()
    }

    private func position(_ host: Host, on screen: NSScreen) {
        let size = host.panel.frame.size
        host.panel.setFrame(
            NSRect(x: screen.frame.midX - size.width / 2,
                   y: screen.frame.maxY - size.height,
                   width: size.width, height: size.height),
            display: false)
        host.panel.applyScreenCapturePolicy(hidden: settings.hideFromScreenCapture)
    }

    /// Two-finger swipes over the notch: horizontal skips, vertical play/pause.
    private func installGestures() {
        gestures.isOverNotch = { [weak self] point in
            guard let self else { return false }
            return self.hosts.values.contains {
                self.isOverNotch(point, controller: $0.controller, forGesture: true)
            }
        }
        // `hasTrack` is what every gesture callback guards on: with no track,
        // next, previous and playPause all no-op.
        gestures.canAct = { [weak self] in self?.media.hasTrack ?? false }
        // A swipe skip needs its own strike; the undirected beat on a token change is
        // the only other reaction.
        gestures.onSkipForward = { [weak self] in
            self?.media.next()
            self?.fluid.surge(0.8, direction: 1)
        }
        gestures.onSkipBackward = { [weak self] in
            self?.media.previous()
            self?.fluid.surge(0.8, direction: -1)
        }
        gestures.onTogglePlayback = { [weak self] in self?.media.playPause() }
        // The swipe is visible while it is made. The ink's magnet uses the same
        // `setPointer` channel as the scrub drag, and the content sheet shears through the
        // controllers. They only compete if a scrub and a swipe are live together; the nil
        // on either release clears it.
        gestures.onSwipeChange = { [weak self] lean in
            guard let self else { return }
            if let lean {
                let magnet = SwipeRecogniser.magnet(for: lean)
                self.fluid.setPointer(rim: magnet.rim, strength: magnet.strength)
            } else {
                // Callbacks run before the publish, so the commit's surge has already fired and
                // lands on a surface the magnet is letting go of.
                self.fluid.setPointer(rim: nil)
            }
            self.broadcast { $0.swipeLean = lean }
        }
        gestures.start()
    }

    /// Hides automatically in a locked, screensaver, display-sleep or fullscreen state,
    /// with no setting. Mission Control has no public signal (inferring it means
    /// parsing the unified log), so it is not handled. A notch drawn over fullscreen
    /// video is the worst thing this app can do, and in fullscreen the menu-bar band is
    /// gone, which is a fact rather than an inference.
    private func installEnvironmentObservers() {
        let distributed = DistributedNotificationCenter.default()
        for name in ["com.apple.screenIsLocked", "com.apple.screensaver.didstart"] {
            distributed.addObserver(forName: .init(name), object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.setSystemHidden(true) }
            }
        }
        for name in ["com.apple.screenIsUnlocked", "com.apple.screensaver.didstop"] {
            distributed.addObserver(forName: .init(name), object: nil, queue: .main) {
                [weak self] _ in
                MainActor.assumeIsolated { self?.setSystemHidden(false) }
            }
        }
        // Display sleep without a lock: stop the audio tap, ink clock and polls.
        for (name, asleep) in [(NSWorkspace.screensDidSleepNotification, true),
                               (NSWorkspace.screensDidWakeNotification, false)] {
            NSWorkspace.shared.notificationCenter.addObserver(
                forName: name, object: nil, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.displaysAsleep = asleep
                    self?.refreshEnvironment()
                }
            }
        }
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshEnvironment() }
        }
        refreshEnvironment()
    }

    /// Whether this screen has no menu-bar band, i.e. a fullscreen app covers it.
    /// Fullscreen is per display.
    /// one monitor is not a reason to uncover the camera cutout on another.
    private func menuBarIsHidden(on screen: NSScreen?) -> Bool {
        guard let screen else { return false }
        // With "Automatically hide and show the menu bar" on, `visibleFrame.maxY` equals
        // `frame.maxY` on the plain desktop, so the geometric test cannot distinguish
        // fullscreen. With a cutout the notch is hardware and stays a legal home either
        // way. Without one, every pixel the retracted shell could occupy belongs to a
        // window, so it hides (PRODUCT.md: never cover window chrome while retracted).
        if UserDefaults.standard.bool(forKey: "_HIHideMenuBar") {
            return ScreenMetrics.notchRect(for: screen) == nil
        }
        return screen.frame.maxY - screen.visibleFrame.maxY < 1
    }

    /// Lock and screensaver are global; fullscreen is not.
    private func setSystemHidden(_ hidden: Bool) {
        lockedOrSaver = hidden
        refreshEnvironment()
    }

    /// Re-evaluates every host against its own screen. Also the correction point for
    /// hosts created while the state changed, so `rebuild()` ends here too.
    /// visible with nothing to fix it, so `rebuild()` ends here too.
    private func refreshEnvironment() {
        for host in hosts.values {
            let hide = systemHidden || menuBarIsHidden(on: host.controller.screen)
            let reappearing = !hide && !host.controller.isVisible
            host.controller.setVisible(!hide)
            // Ordered out rather than made transparent: an ordered-out window cannot be
            // hovered or hit-tested, so it cannot eat a click.
            if hide {
                host.panel.orderOut(nil)
            } else {
                // Re-measured on the way back: the band reads 0 during fullscreen, and a display
                // change or wake then would leave the mini player and HUD 0 pt tall. Only on
                // the hidden-to-shown edge, since observation invalidates on assignment and this
                // runs on every space change.
                if reappearing, let screen = host.controller.screen {
                    host.controller.refreshMetrics(for: screen)
                }
                host.panel.orderFrontRegardless()
            }
        }
        // Immediately: a hidden panel that still has `ignoresMouseEvents = false` would
        // eat clicks.
        syncInteractivity()
        // Visibility gates capture: lock and fullscreen release the tap, unlocking
        // restores it.
        syncMiniPlayerAndCapture()
    }

    private func installScreenObserver() {
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
    }

    // MARK: Hover

    private func installMouseMonitors() {
        // Mouse-moved monitoring needs no Accessibility grant, unlike key events.
        globalMouse = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleMouseMoved() }
        }
        localMouse = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            MainActor.assumeIsolated { self?.handleMouseMoved() }
            return event
        }
        // Click-away dismisses a pinned panel; pinning makes a toggle stick but would
        // otherwise leave the status menu as the only way to close it.
        clickAway = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] event in
            MainActor.assumeIsolated {
                self?.dismissPinnedIfOutside()
                if event.type == .leftMouseDown { self?.openOnClickIfHoverOff() }
            }
        }
    }

    /// With Open on Hover off, a click on the notch opens and pins it. The notch is
    /// dead menu-bar space, so the click a global monitor cannot consume lands on
    /// nothing.
    private func openOnClickIfHoverOff() {
        guard !settings.expandNotchOnHover else { return }
        let mouse = NSEvent.mouseLocation
        var opened = false
        for (_, host) in hosts where !host.controller.isExpanded
            && isOverNotch(mouse, controller: host.controller, forGesture: true) {
            host.controller.expand(byHover: false, pinned: true)
            opened = true
        }
        guard opened else { return }
        syncInteractivity()
        syncExpandedPolling()
    }

    private func dismissPinnedIfOutside() {
        let mouse = NSEvent.mouseLocation
        for (_, host) in hosts where host.controller.isPinned {
            guard let screen = host.controller.screen else { continue }
            // The panel's hit region in screen coordinates.
            let size = host.controller.currentSize
            let centerX = screen.frame.midX
            let top = screen.frame.maxY
            let frame = CGRect(x: centerX - size.width / 2,
                               y: top - size.height,
                               width: size.width,
                               height: size.height)
            if !frame.contains(mouse) { host.controller.collapse() }
        }
    }

    /// Whether `point` is over this notch. Shared by hover and gestures so they agree;
    /// only the open panel's keep-open pad is hover's alone.
    private func isOverNotch(_ point: NSPoint, controller: NotchController,
                             forGesture: Bool = false) -> Bool {
        // A hidden notch is not anywhere. A live hot zone during fullscreen video would
        // skip tracks on a two-finger scroll, and the page would scroll too because a
        // global monitor cannot consume.
        guard controller.isVisible else { return false }
        guard let screen = controller.screen else { return false }

        // The drawn shape, plus a shallow band along the top edge so the notch is
        // reachable by throwing the pointer upward.
        let size = controller.currentSize
        let shapeRect = NSRect(x: screen.frame.midX - size.width / 2,
                               y: screen.frame.maxY - size.height,
                               width: size.width,
                               height: size.height)
        // Closed, exactly the drawn shell: with the mini player off that is the cutout,
        // and padding it would open the panel from invisible menu-bar area.
        let edgeRect = NSRect(x: shapeRect.minX,
                              y: screen.frame.maxY - 4,
                              width: shapeRect.width,
                              height: 4)

        // Generous once open, and below in particular: the progress line sits on the
        // bottom edge and moves, so a tight region would snap the panel shut under the
        // cursor. Hover only: a swipe is read by a global monitor that cannot consume
        // it, so over the pad a scroll in a browser tab strip would skip the track and
        // scroll the page. Gestures take the drawn shell.
        let generous = controller.isExpanded && !forGesture
        let sidePad: CGFloat = generous ? 30 : 0
        let belowPad: CGFloat = generous ? 40 : 0
        let hoverRect = NSRect(x: shapeRect.minX - sidePad,
                               y: shapeRect.minY - belowPad,
                               width: shapeRect.width + sidePad * 2,
                               height: shapeRect.height + belowPad)

        // `NSMouseInRect`, not `CGRect.contains`: a pointer thrown to the top of the
        // display reports y == frame.maxY, which `contains` excludes, and that is the one
        // row the edge band exists for.
        return NSMouseInRect(point, hoverRect, false) || NSMouseInRect(point, edgeRect, false)
    }

    private func handleMouseMoved() {
        let mouse = NSEvent.mouseLocation

        for (_, host) in hosts {
            let controller = host.controller
            let inside = isOverNotch(mouse, controller: controller)

            if inside, !controller.isMouseInside {
                controller.mouseEntered()
                // Warm the audio tap during the hover delay so the ink does not open as a dead
                // box when the closed strip is off.
                syncMiniPlayerAndCapture()
            } else if !inside, controller.isMouseInside {
                controller.mouseExited()
                syncMiniPlayerAndCapture()
            }

            // Interaction is only enabled while expanded and visible, so a collapsed or
            // hidden notch never intercepts anything. Hiding faded the panel without ordering
            // it out, so an invisible expanded window could swallow clicks over fullscreen
            // video title bars.
            host.panel.setInteractive(controller.isExpanded && controller.isVisible)

            // Refcount the seeker timer against what is on screen.
            if controller.isExpanded {
                media.beginPolling(.notchExpanded(controller.displayUUID))
            } else {
                media.endPolling(.notchExpanded(controller.displayUUID))
            }
        }
    }

    // MARK: System sources

    private func wireSystemSources() {
        volume.onChange = { [weak self] value, muted in
            guard let self, self.settings.enableVolume else { return }
            self.broadcast { $0.present(.didChangeVolume, progress: Double(value), isMuted: muted) }
        }

        brightness.onChange = { [weak self] value in
            guard let self, self.settings.enableBrightness else { return }
            self.broadcast { $0.present(.didChangeBrightness, progress: Double(value)) }
        }

        observeMedia()
        syncMiniPlayerAndCapture()
    }

    /// Observation tracking is one-shot, so every handler re-arms itself.
    private func observeMedia() {
        withObservationTracking {
            _ = media.hasTrack
            _ = media.trackToken
            _ = media.isPlaying
            // Tracked so toggling the menu item takes effect at once.
            _ = settings.showsMiniPlayer
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // The ink reacts to a new song as it does to a hit. Nested rather than a
                // multi-clause `if`: `consumeSkipDirection` returns an Optional, so binding it in
                // the condition list would skip the organic advance, and hoisting it above the
                // `if` would consume the direction on every observation callback.
                if self.media.trackToken != self.lastSurgedToken {
                    let dir = self.media.consumeSkipDirection()
                    // Softer when asked for, since the press or swipe already struck. `?? 0` keeps an
                    // organic advance undirected.
                    self.fluid.surge(dir == nil ? 0.95 : 0.45, direction: dir ?? 0)
                    self.lastSurgedToken = self.media.trackToken
                }
                self.syncMiniPlayerAndCapture()
                self.observeMedia()
            }
        }
    }

    private func syncMiniPlayerAndCapture() {
        // On transition, since `hasMedia` is observed and this runs on every poll.
        // Animated while open: the idle card and the player differ in size, and this
        // lands after the content switched.
        broadcast { c in
            guard c.hasMedia != media.hasTrack else { return }
            withAnimation(c.isExpanded ? Motion.expand : nil) { c.hasMedia = media.hasTrack }
        }

        // Two gates, not one: the mini player and the visualiser are independent menu
        // toggles, and capture has to follow every surface that can show ink.
        let miniPlayerShown = settings.showsMiniPlayer && media.hasTrack
        if miniPlayerShown {
            broadcast { $0.showMiniPlayer() }
            media.beginPolling(.miniPlayer)
        } else {
            broadcast { $0.hideMiniPlayer() }
            media.endPolling(.miniPlayer)
        }

        // Capture only while something can show the ink and there is music to show. When
        // locked, in a screensaver or fullscreen everywhere, nothing needs the tap.
        if wasPlaying, !media.isPlaying {
            settleDeadline = .now + Self.settleAfterPause
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.settleAfterPause)
                self?.syncMiniPlayerAndCapture()
            }
        }
        wasPlaying = media.isPlaying
        let settling = settleDeadline.map { ContinuousClock.now < $0 } ?? false
        let onScreen = !systemHidden && hosts.values.contains { $0.controller.isVisible }
        let holding = closeHoldDeadline.map { ContinuousClock.now < $0 } ?? false
        let captureActive = media.hasTrack && onScreen
            && (media.isPlaying || settling)
            && (settings.showsMiniPlayer || anyExpanded || anyHovered || holding)
        if captureActive, !audioAttached {
            audioAttached = true
            audio.addConsumer()
            fluid.start(audio: audio)
        } else if !captureActive, audioAttached {
            audioAttached = false
            audio.removeConsumer()
            // Seen, the ink is let go and comes to rest; unseen, it is reset.
            if onScreen { fluid.release() } else { fluid.stop() }
        }
    }

    private func broadcast(_ body: (NotchController) -> Void) {
        for (_, host) in hosts { body(host.controller) }
    }

    // MARK: Commands

    func toggleAll() {
        // Decide once, from the aggregate. Toggling each controller independently would
        // collapse a hover-opened display while expanding and pinning the other, leaving
        // a panel open elsewhere with no hover-exit or auto-retract to close it.
        let open = anyExpanded
        broadcast { open ? $0.collapse() : $0.expand(byHover: false, pinned: true) }
        syncInteractivity()
        syncExpandedPolling()
    }

    func setExpandedAll(_ expanded: Bool) {
        broadcast { expanded ? $0.expand(byHover: false) : $0.collapse() }
        syncInteractivity()
        syncExpandedPolling()
    }

    /// Matches the poller's refcount to which panels are open, keyed by display so it
    /// stays correct with one screen open and another not. Both toggle paths call it.
    private func syncExpandedPolling() {
        for host in hosts.values {
            let token = MediaManager.PollingSource.notchExpanded(host.controller.displayUUID)
            if host.controller.isExpanded {
                media.beginPolling(token)
            } else {
                media.endPolling(token)
            }
        }
    }

    private func syncInteractivity() {
        for (_, host) in hosts {
            host.panel.setInteractive(host.controller.isExpanded && host.controller.isVisible)
        }
    }

    /// Asks the audio tap to try again; called as the status menu opens so a permission
    /// granted a moment ago is picked up before the menu decides what to say.
    func retryAudioCapture() { audio.retryCapture() }

    /// Why the player cannot be read, if it cannot be.
    var automationNote: String? { media.automationNote }
    var stalledNote: String? { media.stalledNote }

    var audioPermissionNote: String? { audio.isLive ? nil : audio.permissionNote }

    /// The cutout the app is drawing, for the menu to report.
    var notchSize: CGSize {
        hosts.values.first?.controller.notchSize ?? .zero
    }

    /// The corner the shape is drawing, so the menu cannot report one it is not using.
    var cutoutCornerRadius: CGFloat {
        hosts.values.first?.controller.cutoutCornerRadius ?? 0
    }

    /// Whether any panel is open. The fluid is shared and controllers are per display,
    /// so this is the correct input to `setOpen`; one display's collapse must not blank
    /// the ink inside another's open panel. The menu reads it to choose open or close.
    var anyExpanded: Bool {
        hosts.values.contains { $0.controller.isExpanded }
    }

    /// A pointer on a notch is about to open it; capture starts then.
    private var anyHovered: Bool {
        hosts.values.contains { $0.controller.isMouseInside }
    }

    func applySettingsChange() {
        for (_, host) in hosts {
            if let screen = host.controller.screen {
                host.controller.refreshMetrics(for: screen)
            }
            host.panel.applyScreenCapturePolicy(hidden: settings.hideFromScreenCapture)
        }
        // Make the player look again. `musicApp` is read by `resolveSources`, which only
        // runs inside `refresh()`, and with no track and no open panel the poll timer is
        // stopped, so a new choice would never be read. One refresh closes that.
        Task { [media] in await media.refresh() }
    }
}
