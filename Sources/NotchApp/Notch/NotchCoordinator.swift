import AppKit
import SwiftUI

/// Owns one notch per display and routes system events to them.
///
/// Hover is detected with a **global mouse monitor** rather than a tracking area.
/// That's what lets the collapsed window stay fully click-through
/// (`ignoresMouseEvents = true`), so an idle notch is completely invisible to the
/// desktop underneath it — no swallowed clicks, no stolen scroll.
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
    /// Capture outlives a pause by this much, so the ink settles instead of
    /// freezing mid-peak — and then stops, because a running tap is an
    /// aggregate device, and coreaudiod holds an idle-sleep assertion for as
    /// long as one runs. Gated on a loaded track alone, a paused Spotify kept a
    /// MacBook awake for hours.
    private static let settleAfterPause: Duration = .seconds(3)
    private var settleDeadline: ContinuousClock.Instant?
    private var wasPlaying = false
    private var lastSurgedToken = -1
    private var systemHidden = false
    private var clickAway: Any?
    private let gestures = NotchGestures()

    /// Extra room around the expanded panel for the shadow to fall into.
    ///
    /// Must exceed where the shadow's ink actually ends, or the window edge
    /// chops the bloom into a visible hard line on a bright desktop. Rendered
    /// offscreen and measured, the panel's shadow (radius 28, y 14, black 0.5)
    /// holds ≥1/255 of ink to 57.5pt beside the panel and 70pt below it — not
    /// the 28pt the radius suggests. 64pt per side and 78pt below let it reach
    /// zero with room to spare. Width is both sides, height is all below,
    /// because the panel hangs from the screen's top edge.
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

    /// Track Reduce Motion, now and whenever the user changes it.
    ///
    /// PRODUCT.md requires it, and nothing in the app read it: every spring,
    /// bounce and the marquee's `repeatForever` ran unconditionally.
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
            // The AGGREGATE, never one controller's state. `fluid` is shared and
            // the controllers are per display: hover A, cross to B, and A's
            // hover-close would fire setOpen(false) while B is still open,
            // leaving dead ink inside an open panel. The `open ||` covers the
            // first-rebuild race where the controller exists but is not in
            // `hosts` yet. Same lesson `broadcast` already records: decide once,
            // from the aggregate.
            controller.onExpansionChange = { [weak self] open in
                guard let self else { return }
                self.fluid.setOpen(open || self.anyExpanded)
                // Capture is gated on `anyExpanded` when the retracted strip is
                // off, and this is the only place expansion changes — without
                // it the panel opens onto a visualiser nothing ever restarted.
                self.syncLiveActivity()
            }
            let hosting = NotchHostingView(rootView: root)
            hosting.frame = NSRect(origin: .zero, size: panelSize)
            hosting.autoresizingMask = [.width, .height]
            // AppKit coordinates: the notch hangs from the *top* of the panel.
            hosting.hitRegion = { [weak controller] in
                guard let controller else { return .zero }
                let s = controller.currentSize
                // Pad below the silhouette: the seek strip hangs past the shell's
                // bottom edge, and without this the hit test rejected the very
                // pixels you have to aim at to grab the progress line.
                let below: CGFloat = controller.isExpanded ? 22 : 0
                let side: CGFloat = controller.isExpanded ? 20 : 2
                return CGRect(x: (panelSize.width - s.width) / 2 - side,
                              y: panelSize.height - s.height - below,
                              width: s.width + side * 2,
                              height: s.height + below)
            }

            panel.contentView = hosting
            panel.orderFrontRegardless()

            hosts[uuid] = Host(controller: controller, panel: panel, hosting: hosting)
        }

        // Tear down notches for displays that went away.
        for (uuid, host) in hosts where !seen.contains(uuid) {
            host.panel.orderOut(nil)
            host.panel.contentView = nil
            // Release this display's polling token before the host goes. It is
            // keyed by displayUUID, so an unplugged display left its token in the
            // set forever and pinned the media poller at its fast rate.
            media.endPolling(.notchExpanded(uuid))
            hosts.removeValue(forKey: uuid)
        }

        // Recompute after the teardown. A display unplugged while its panel was
        // expanded takes the only `onExpansionChange` that could ever clear the
        // fluid's target with it, stranding it open — and `setOpen` is
        // idempotent, so the next hover on a surviving display returns early and
        // that open gets no pour at all. Safe to call unconditionally for the
        // same reason.
        fluid.setOpen(anyExpanded)

        // A host created mid-song starts with hasMedia false and no live
        // activity, so it shows the bare cutout and hovers open the 232pt idle
        // panel instead of the player — until the track happens to change.
        // Unconditional, not just for created hosts: a display unplugged while
        // its panel was expanded can also flip `anyExpanded`, which the capture
        // gate reads, and its own onExpansionChange left with it.
        syncLiveActivity()

        // Correct any host that did not exist when the environment last changed.
        // A display hot-plugged during a hidden period used to come up visible
        // with nothing to fix it — a notch drawn over someone's fullscreen video
        // the moment they attached a monitor.
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
                self.isOverNotch(point, controller: $0.controller)
            }
        }
        // `hasTrack`, because it is what every gesture callback ultimately
        // guards on: with no track, next/previous/playPause all no-op.
        gestures.canAct = { [weak self] in self?.media.hasTrack ?? false }
        // A swipe skip had no strike at all, so its only reaction was the
        // undirected beat that arrives whenever the token changes — the one
        // gesture in the app the ink did not answer at the moment you made it.
        gestures.onSkipForward = { [weak self] in
            self?.media.next()
            self?.fluid.surge(0.8, direction: 1)
        }
        gestures.onSkipBackward = { [weak self] in
            self?.media.previous()
            self?.fluid.surge(0.8, direction: -1)
        }
        gestures.onTogglePlayback = { [weak self] in self?.media.playPause() }
        // The swipe is visible while it is still being made. The ink's magnet
        // rides the same `setPointer` channel the scrub drag uses — one
        // vocabulary for "the hand is pulling me" — and the content sheet
        // shears through the controllers. The two can only fight over the
        // pointer if a scrub drag and a swipe are live at once, which needs a
        // second hand on the trackpad mid-drag; the loser is a swell in the
        // wrong place for a beat, and the nil on either release clears it.
        gestures.onSwipeChange = { [weak self] lean in
            guard let self else { return }
            if let lean {
                let magnet = SwipeRecogniser.magnet(for: lean)
                self.fluid.setPointer(rim: magnet.rim, strength: magnet.strength)
            } else {
                // The commit's surge has already fired by the time this nil
                // arrives — callbacks run before the publish — so the slam
                // lands on a surface the magnet is just letting go of.
                self.fluid.setPointer(rim: nil)
            }
            self.broadcast { $0.swipeLean = lean }
        }
        gestures.start()
    }

    /// Get out of the way automatically, with no preference to find.
    ///
    /// Hiding while fullscreen, while gaming and while in Mission Control could
    /// each be a switch. They are not: a setting for something the app can
    /// simply know is a setting the user should never have had to find. Mission
    /// Control is the one case with no public signal at all — it can be inferred
    /// by tailing the unified log, and a log format is not something to build
    /// on across macOS releases, so it is left unhandled rather than guessed.
    ///
    /// These three are event-driven and public. The menu-bar check is the one
    /// that matters most: a notch overlay drawn over fullscreen video is the
    /// worst thing this app can do, and in fullscreen the menu-bar band is gone,
    /// which is a fact rather than an inference.
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
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshEnvironment() }
        }
        refreshEnvironment()
    }

    /// Does THIS screen currently have no menu-bar band — i.e. is a fullscreen
    /// app covering it? Fullscreen is per-display: putting a video fullscreen on
    /// one monitor is not a reason to uncover the camera cutout on another.
    private func menuBarIsHidden(on screen: NSScreen?) -> Bool {
        guard let screen else { return false }
        // With "Automatically hide and show the menu bar" on, visibleFrame.maxY
        // equals frame.maxY on the plain desktop — so the geometric test is true
        // with no fullscreen app anywhere, and the app would hide itself forever.
        // In that configuration the signal simply does not distinguish the two
        // states, so it is not used rather than guessed at.
        //
        // On a display with a cutout it does not need to be: the notch is
        // hardware and stays a legal home for the shell whether the menu bar is
        // up or not. Without one there is no band and no cutout, so every
        // pixel the retracted shell could occupy belongs to a window — and
        // PRODUCT.md's "never cover window chrome while retracted" leaves one
        // answer. Turning the menu bar's auto-hide off gives the notch back.
        if UserDefaults.standard.bool(forKey: "_HIHideMenuBar") {
            return ScreenMetrics.notchRect(for: screen) == nil
        }
        return screen.frame.maxY - screen.visibleFrame.maxY < 1
    }

    /// Lock and screensaver are global; fullscreen is not.
    private func setSystemHidden(_ hidden: Bool) {
        systemHidden = hidden
        refreshEnvironment()
    }

    /// Re-evaluate every host against its OWN screen.
    ///
    /// Also the correction point for hosts that did not exist when the state
    /// changed: a display hot-plugged during a hidden period used to come up
    /// visible with nothing to fix it, so `rebuild()` ends here too.
    private func refreshEnvironment() {
        for host in hosts.values {
            let hide = systemHidden || menuBarIsHidden(on: host.controller.screen)
            host.controller.setVisible(!hide)
            // Genuinely absent, not transparent. An ordered-out window cannot be
            // hovered, cannot be made interactive, and cannot be hit-tested at
            // all, which closes the whole class of "invisible thing ate my click".
            if hide {
                host.panel.orderOut(nil)
            } else {
                host.panel.orderFrontRegardless()
            }
        }
        // Immediately, not on the next mouse-moved event: a hidden panel that is
        // still ignoresMouseEvents = false is exactly the invisible click-eater
        // this is here to prevent.
        syncInteractivity()
        // Visibility is one of capture's gates: lock and fullscreen must release
        // the tap, and unlocking must bring it back.
        syncLiveActivity()
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
        // Mouse-moved monitoring needs no Accessibility grant (unlike key events).
        globalMouse = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            MainActor.assumeIsolated { self?.handleMouseMoved() }
        }
        localMouse = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            MainActor.assumeIsolated { self?.handleMouseMoved() }
            return event
        }
        // Click-away dismisses a pinned panel. Pinning is what makes a deliberate
        // toggle stick, but it also removed the only way the panel ever went away
        // on its own — leaving the status menu as the sole dismissal, which is
        // not somewhere anyone thinks to look for "close this".
        clickAway = NSEvent.addGlobalMonitorForEvents(
            matching: [.leftMouseDown, .rightMouseDown]
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.dismissPinnedIfOutside() }
        }
    }

    private func dismissPinnedIfOutside() {
        let mouse = NSEvent.mouseLocation
        for (_, host) in hosts where host.controller.isPinned {
            guard let screen = host.controller.screen else { continue }
            // The panel's own hit region, in screen coordinates.
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

    /// Is `point` over this notch? One definition, shared by hover and gestures,
    /// so the two can never disagree about where the notch is.
    private func isOverNotch(_ point: NSPoint, controller: NotchController) -> Bool {
        // A hidden notch is not anywhere. Without this the hot zone stayed live
        // through the entire hidden period, so two-finger scrolling at the top of
        // a fullscreen video skipped tracks with no visible UI to explain it —
        // and the page scrolled too, because a global monitor cannot consume.
        guard controller.isVisible else { return false }
        guard let screen = controller.screen else { return false }

        // The drawn shape, plus a shallow band along the very top edge so the
        // notch is reachable by throwing the pointer upward.
        let size = controller.currentSize
        let shapeRect = NSRect(x: screen.frame.midX - size.width / 2,
                               y: screen.frame.maxY - size.height,
                               width: size.width,
                               height: size.height)
        let edgeRect = NSRect(x: shapeRect.minX - 8,
                              y: screen.frame.maxY - 4,
                              width: shapeRect.width + 16,
                              height: 4)

        // Generous once open, and generous *below* in particular: the progress
        // line lives on the bottom edge and it moves, so a tight region meant the
        // panel snapped shut just as you got the cursor onto it.
        let sidePad: CGFloat = controller.isExpanded ? 30 : 6
        let belowPad: CGFloat = controller.isExpanded ? 40 : 6
        let hoverRect = NSRect(x: shapeRect.minX - sidePad,
                               y: shapeRect.minY - belowPad,
                               width: shapeRect.width + sidePad * 2,
                               height: shapeRect.height + belowPad)

        // NSMouseInRect, not CGRect.contains: a pointer thrown to the top of the
        // display reports y == frame.maxY, which `contains` excludes — so the
        // one row the edge band exists for never counted, the hover-open was
        // cancelled on arrival, and swipes there were ignored.
        return NSMouseInRect(point, hoverRect, false) || NSMouseInRect(point, edgeRect, false)
    }

    private func handleMouseMoved() {
        let mouse = NSEvent.mouseLocation

        for (_, host) in hosts {
            let controller = host.controller
            let inside = isOverNotch(mouse, controller: controller)

            if inside, !controller.isMouseInside {
                controller.mouseEntered()
            } else if !inside, controller.isMouseInside {
                controller.mouseExited()
            }

            // Interaction is only enabled while expanded, so a collapsed notch
            // never intercepts anything.
            // Visibility gates interaction, not just paint. The panel was only
            // ever faded to opacity 0, never ordered out, so hovering the top of a
            // fullscreen video expanded an invisible 344x122 window above it and
            // setInteractive(true) let it swallow the click — right where a
            // player's own title bar and close button live.
            host.panel.setInteractive(controller.isExpanded && controller.isVisible)

            // Refcount the seeker timer against what's actually on screen.
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
        syncLiveActivity()
    }

    /// Observation tracking is one-shot, so every handler re-arms itself.
    private func observeMedia() {
        withObservationTracking {
            _ = media.hasTrack
            _ = media.trackToken
            _ = media.isPlaying
            // Tracked too, so flipping the menu item takes effect at once rather
            // than waiting for the next track or play/pause.
            _ = settings.enableNowPlaying
        } onChange: { [weak self] in
            Task { @MainActor in
                guard let self else { return }
                // The ink reacts to a new song the way it reacts to a hit.
                //
                // Nested, not a multi-clause `if`. `consumeSkipDirection` returns
                // an Optional, so `let dir = ...` in a condition list is an
                // optional binding that would short-circuit the organic advance
                // entirely; and hoisting it above the `if` fires it on every
                // observation callback, so a play/pause inside the window would
                // eat the direction.
                if self.media.trackToken != self.lastSurgedToken {
                    let dir = self.media.consumeSkipDirection()
                    // Softer when it was asked for: the press or swipe already
                    // struck. `?? 0` keeps an organic advance on the exact shape
                    // it has today.
                    self.fluid.surge(dir == nil ? 0.95 : 0.45, direction: dir ?? 0)
                    self.lastSurgedToken = self.media.trackToken
                }
                self.syncLiveActivity()
                self.observeMedia()
            }
        }
    }

    private func syncLiveActivity() {
        // On transition. `hasMedia` is observed and this runs on every poll.
        broadcast { c in if c.hasMedia != media.hasTrack { c.hasMedia = media.hasTrack } }

        // Two gates, not one. The retracted strip and the visualiser used to
        // share `enableNowPlaying && hasTrack`, so unticking "Show When
        // Retracted" also detached the audio tap and stopped the sim — the full
        // player still opened on hover (hasMedia is synced above regardless)
        // with music audibly playing and the ink sitting motionless in it. The
        // two menu toggles are documented as independent states; capture has to
        // follow every surface that can show ink, not just the strip.
        let stripActive = settings.enableNowPlaying && media.hasTrack
        if stripActive {
            // Peek on a track change; otherwise stay exactly notch-sized so the
            // menu bar underneath is never covered.
            broadcast { $0.showNowPlaying() }
            media.beginPolling(.liveActivity)
        } else {
            broadcast { $0.clearLiveActivity() }
            media.endPolling(.liveActivity)
        }

        // Capture only while something can show the ink AND there is music to
        // show. Locked, screensaver, or every display fullscreen: nothing is on
        // screen, so nothing needs the tap.
        if wasPlaying, !media.isPlaying {
            settleDeadline = .now + Self.settleAfterPause
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: Self.settleAfterPause)
                self?.syncLiveActivity()
            }
        }
        wasPlaying = media.isPlaying
        let settling = settleDeadline.map { ContinuousClock.now < $0 } ?? false
        let onScreen = !systemHidden && hosts.values.contains { $0.controller.isVisible }
        let captureActive = media.hasTrack && onScreen
            && (media.isPlaying || settling)
            && (settings.enableNowPlaying || anyExpanded)
        if captureActive, !audioAttached {
            audioAttached = true
            audio.addConsumer()
            fluid.start(audio: audio)
        } else if !captureActive, audioAttached {
            audioAttached = false
            audio.removeConsumer()
            // Seen, the ink is let go of and comes to rest; unseen, it is reset.
            if onScreen { fluid.release() } else { fluid.stop() }
        }
    }

    private func broadcast(_ body: (NotchController) -> Void) {
        for (_, host) in hosts { body(host.controller) }
    }

    // MARK: Commands

    func toggleAll() {
        // Decide once, from the aggregate. Toggling each controller
        // independently inverted them relative to each other: with the pointer
        // resting over the built-in notch, hover had already expanded it, so one
        // menu command collapsed that one and expanded AND PINNED the other —
        // leaving a panel open on the display the user is not looking at, with no
        // hover-exit and no auto-retract to close it.
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

    /// Match the poller's refcount to which panels are actually open.
    ///
    /// It lived inline in `setExpandedAll` and `toggleAll` did not do it — so the
    /// menu's Toggle Notch expanded panels without ever asking for the fast poll,
    /// and collapsed them without releasing a token that `setExpandedAll` may
    /// have taken, leaving the poller fast for the rest of the session. Keyed by
    /// display, so it stays correct with a panel open on one screen and not
    /// another.
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

    /// Why audio capture isn't running, if it isn't.
    ///
    /// The tap records this and nothing ever read it, so a refused capture grant
    /// left the visualiser permanently flat with no explanation anywhere in the
    /// app — the signature feature failing silently is the worst way for it to
    /// fail.
    /// Called as the status menu opens, so a permission granted a moment ago is
    /// picked up before the menu decides what to say about it.
    func retryAudioCapture() { audio.retryCapture() }

    /// Why the player cannot be read, if it cannot be.
    var automationNote: String? { media.automationNote }
    var stalledNote: String? { media.stalledNote }

    var audioPermissionNote: String? { audio.isLive ? nil : audio.permissionNote }

    /// The cutout the app is currently drawing, for the menu to report back.
    var notchSize: CGSize {
        hosts.values.first?.controller.notchSize ?? .zero
    }

    /// The corner the shape is actually drawing, so the menu cannot report one
    /// the shape is not using.
    var cutoutCornerRadius: CGFloat {
        hosts.values.first?.controller.cutoutCornerRadius ?? 0
    }

    /// Is ANY panel open?
    ///
    /// The fluid is shared and the controllers are per display, so this is the
    /// only correct input to `setOpen` — one display's collapse must not blank
    /// the ink inside another's open panel. It was spelled out at three call
    /// sites, which is three chances to write one of them without the `||`.
    /// The menu reads it too, to say whether its command opens or closes.
    var anyExpanded: Bool {
        hosts.values.contains { $0.controller.isExpanded }
    }

    func applySettingsChange() {
        for (_, host) in hosts {
            if let screen = host.controller.screen {
                host.controller.refreshMetrics(for: screen)
            }
            host.panel.applyScreenCapturePolicy(hidden: settings.hideFromScreenCapture)
        }
        // And make the player look again.
        //
        // `musicApp` is read by `MediaManager.resolveSources`, which only runs
        // inside `refresh()` — and there may not BE a next refresh. With no
        // track detected and no panel open, `pollingSources` is empty and the
        // timer is stopped, so choosing a different player wrote the preference
        // and nothing ever read it. Worse, switching AWAY from a running player
        // is itself what empties the set, so switching back was the case that
        // could not recover. One refresh costs a poll and closes it.
        Task { [media] in await media.refresh() }
    }
}
