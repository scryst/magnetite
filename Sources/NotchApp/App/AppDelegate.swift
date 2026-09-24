import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var coordinator: NotchCoordinator?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar only. LSUIElement in Info.plist covers the bundled case; this
        // makes `swift run` behave the same way.
        NSApp.setActivationPolicy(.accessory)

        // One Magnetite per session. A second copy — a fresh build opened beside
        // the installed one, or a login item racing a manual launch — drew a
        // second panel over the first, answered every swipe twice, ran a second
        // audio tap and lost the Spotify callback port to the first.
        if let id = Bundle.main.bundleIdentifier,
           NSRunningApplication.runningApplications(withBundleIdentifier: id)
               .contains(where: { $0 != .current && !$0.isTerminated }) {
            FileHandle.standardError.write(Data(
                "[launch] Magnetite is already running; quit it first to run this copy.\n".utf8))
            NSApp.terminate(nil)
            return
        }

        coordinator = NotchCoordinator()
        installStatusItem()
    }

    /// `magnetite://toggle`, `magnetite://expand`, `magnetite://collapse`,
    /// `magnetite://spotify-connect`, `magnetite://spotify-disconnect`.
    ///
    /// Scriptable control is a real feature — it also makes the UI states
    /// reachable from a shell, which is the only sane way to verify a window that
    /// only appears on hover.
    ///
    /// The scheme is renamed with the product, and deliberately not kept
    /// alongside the old one: a scheme is a global claim on the machine, and
    /// two live registrations for one app is how the wrong copy gets launched.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "magnetite" {
            switch url.host ?? url.path.replacingOccurrences(of: "/", with: "") {
            case "toggle":   coordinator?.toggleAll()
            case "expand":   coordinator?.setExpandedAll(true)
            case "collapse": coordinator?.setExpandedAll(false)
            // Scriptable so the consent flow can be started without hunting for
            // a menu item — and so it can be re-run after a token expires.
            case "spotify-connect":
                if let web = coordinator?.media.spotify { Task { await web.connect() } }
            case "spotify-disconnect":
                coordinator?.media.spotify.disconnect()
            // Same reason as the rest: a control that only exists inside a panel
            // you have to hover cannot otherwise be exercised.
            case "like":    coordinator?.media.toggleLike()
            case "shuffle": coordinator?.media.toggleShuffle()
            case "repeat":  coordinator?.media.toggleRepeat()
            case "state":   coordinator?.media.logState()
            default: break
            }
        }
    }

    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    // MARK: Menu bar

    private func installStatusItem() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // The app's own mark, not a system symbol standing in for it.
        //
        // `rectangle.topthird.inset.filled` sat here for the app's whole life: a
        // generic notch glyph, indistinguishable from anything else in the bar
        // that wanted to gesture at a screen. The one surface the app shows
        // while it is doing its job was the one place the logo was not.
        //
        // `MagnetiteMark` is generated from the icon master, so this is the same
        // contour as the Dock tile, the favicon and the mark in the site's foot
        // — and a template, so the bar owns the colour.
        item.button?.image = MagnetiteMark.menuBarImage(height: 16)
        item.button?.image?.accessibilityDescription = "Magnetite"

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    /// Rebuilt every time it opens.
    ///
    /// It used to be built once at launch, so every checkmark was a snapshot:
    /// picking a music source wrote the preference and left the tick on the old
    /// entry forever, and each toggle decided what to write from a copy of the
    /// value captured at build time rather than from the setting. Rebuilding on
    /// open makes staleness impossible instead of something to keep in sync.
    func menuNeedsUpdate(_ menu: NSMenu) {
        // If the user granted audio capture since we last looked, pick it up now
        // rather than reporting it as still unavailable.
        coordinator?.retryAudioCapture()
        menu.removeAllItems()
        let settings = Settings.shared

        // Problems first, and only when there is one. A visualiser that never
        // moves because a grant was refused is indistinguishable from one that
        // is broken, and nothing else in the app says which — so the answer
        // belongs where the eye lands when the menu opens, not under ten
        // toggles. Each note is followed by the one action that fixes it.
        let problems = problemItems()
        if !problems.isEmpty {
            problems.forEach(menu.addItem)
            menu.addItem(.separator())
        }

        let open = coordinator?.anyExpanded ?? false
        menu.addItem(action(open ? "Close Player" : "Open Player", key: "n") { [weak self] in
            self?.coordinator?.toggleAll()
        })

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Music"))
        let sourceItem = NSMenuItem(title: "Source", action: nil, keyEquivalent: "")
        let sourceMenu = NSMenu()
        for (label, value) in [("Automatic", "automatic"),
                               ("Spotify", "spotify"),
                               ("Apple Music", "music")] {
            // The notification matters here more than anywhere else in this
            // menu: every other item is read by something that is already
            // running, while `musicApp` is read only by the next media refresh —
            // and switching away from the player that was running is what stops
            // the timer that would have produced one.
            let entry = action(label, key: "") { [weak self] in
                Settings.shared.musicApp = value
                self?.coordinator?.applySettingsChange()
            }
            entry.state = settings.musicApp == value ? .on : .off
            sourceMenu.addItem(entry)
        }
        sourceItem.submenu = sourceMenu
        menu.addItem(sourceItem)
        menu.addItem(spotifyItem())

        // Named for what the user sees, not for the setting's key: hover-to-open
        // and the cover-and-clock strip are two independent states, because one
        // quiet mode could not express "progress in the menu bar all the time,
        // and the player only when I ask for it".
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Notch"))
        menu.addItem(toggle("Open on Hover", value: settings.expandNotchOnHover) { on in
            Settings.shared.expandNotchOnHover = on
        })
        menu.addItem(toggle("Show Track While Closed", value: settings.enableNowPlaying) { on in
            Settings.shared.enableNowPlaying = on
        })
        menu.addItem(toggle("Swipe to Skip and Pause", value: settings.enableGestures) { on in
            Settings.shared.enableGestures = on
        })
        menu.addItem(toggle("Volume Indicator", value: settings.enableVolume) { on in
            Settings.shared.enableVolume = on
        })
        menu.addItem(toggle("Brightness Indicator", value: settings.enableBrightness) { on in
            Settings.shared.enableBrightness = on
        })
        menu.addItem(notchSizeItem(settings))

        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "General"))
        menu.addItem(toggle("Launch at Login", value: launchAtLoginEnabled) { [weak self] on in
            self?.setLaunchAtLogin(on)
        })
        menu.addItem(toggle("Hide from Screen Recordings", value: settings.hideFromScreenCapture) { [weak self] on in
            Settings.shared.hideFromScreenCapture = on
            self?.coordinator?.applySettingsChange()
        })

        menu.addItem(.separator())
        menu.addItem(action("About Magnetite", key: "") { [weak self] in
            self?.showAbout()
        })
        menu.addItem(action("Check for Updates…", key: "") {
            NSWorkspace.shared.open(Self.releasesURL)
        })
        menu.addItem(action("Quit Magnetite", key: "q") { NSApp.terminate(nil) })
    }

    // MARK: Problems

    /// Every state that stops the app working, each with its remedy. Empty when
    /// nothing is wrong, which is almost always.
    private func problemItems() -> [NSMenuItem] {
        var items: [NSMenuItem] = []
        func note(_ title: String, _ tip: String) {
            let status = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            status.isEnabled = false
            status.toolTip = tip
            status.image = NSImage(systemSymbolName: "exclamationmark.triangle.fill",
                                   accessibilityDescription: "Problem")
            items.append(status)
        }

        if let text = coordinator?.automationNote {
            note(text, "Magnetite needs permission to control your music app.")
            items.append(action("Open Automation Settings…", key: "") {
                NSWorkspace.shared.open(URL(string:
                    "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation")!)
            })
        }

        // No settings pane here on purpose. The grant is fine — the player took
        // the event and never answered — so the only thing that helps is
        // restarting it, and offering Automation settings would send the user to
        // fix a permission that is not broken.
        if let text = coordinator?.stalledNote {
            note(text, "Magnetite is asking, and your music app isn't replying. "
                + "Quitting and reopening it usually clears this.")
        }

        // Only the tap's own creation can be a refused grant. A failed aggregate
        // device, IOProc or start is the audio system's, and sending someone to
        // a permission they already gave cannot fix it.
        if let text = coordinator?.audioPermissionNote {
            if text.contains("permission") {
                note("Visualiser can't hear system audio", text)
                items.append(action("Open Privacy Settings…", key: "") {
                    NSWorkspace.shared.open(URL(string:
                        "x-apple.systempreferences:com.apple.preference.security?Privacy_AudioCapture")!)
                })
            } else {
                note("Visualiser couldn't start audio capture",
                     "\(text). Switching the output device or reopening Magnetite usually clears this.")
            }
        }

        // A connected library that is failing has nowhere else to say so.
        //
        // `spotifyItem` returns the Disconnect item as soon as `isConnected` is
        // true, and only reads `lastError` on the branch below it — so an error
        // raised while connected was written and never rendered anywhere. That
        // is the state where the user most needs it: the heart and the mode
        // toggles go quiet together and nothing explains it.
        if let web = coordinator?.media.spotify, web.isConnected, let text = web.lastError {
            note("Spotify: \(text)", "The library connection is set up but the last request failed.")
        }
        return items
    }

    // MARK: About

    static let sourceURL = URL(string: "https://github.com/scryst/magnetite")!
    static let releasesURL = URL(string: "https://github.com/scryst/magnetite-releases/releases/latest")!

    /// The standard panel: icon, name, version and the copyright line from
    /// Info.plist, plus where the source lives. An accessory app has to come
    /// forward first or the panel opens behind whatever is in front.
    private func showAbout() {
        let credits = NSMutableAttributedString(
            string: "Free and open source under the MIT License.\n",
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                         .foregroundColor: NSColor.secondaryLabelColor])
        credits.append(NSAttributedString(
            string: "github.com/scryst/magnetite",
            attributes: [.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                         .link: Self.sourceURL]))
        let centred = NSMutableParagraphStyle()
        centred.alignment = .center
        credits.addAttribute(.paragraphStyle, value: centred,
                             range: NSRange(location: 0, length: credits.length))
        NSApp.activate(ignoringOtherApps: true)
        NSApp.orderFrontStandardAboutPanel(options: [.credits: credits])
    }

    // MARK: Launch at login

    private var launchAtLoginEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    private func setLaunchAtLogin(_ on: Bool) {
        do {
            if on {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Unregistered bundles (a bare `swift run`) simply cannot do this.
            FileHandle.standardError.write(
                "[login] \(on ? "register" : "unregister") failed: \(error)\n"
                    .data(using: .utf8)!)
        }
    }

    // MARK: Closure-backed menu items

    /// Connecting Spotify's library, which is the only route to liking a track.
    ///
    /// The local player cannot do it: `starred` is read-only in Spotify's
    /// dictionary and errors when asked. This is Authorization Code with PKCE, so
    /// there is no client secret anywhere; the refresh token lives in TokenStore's
    /// 0600 file under Application Support/Magnetite (TokenStore documents why it
    /// is not the Keychain).
    private func spotifyItem() -> NSMenuItem {
        guard let media = coordinator?.media else {
            return NSMenuItem(title: "Spotify", action: nil, keyEquivalent: "")
        }
        let web = media.spotify
        if web.isConnected {
            return CallbackMenuItem(title: "Disconnect Spotify Library", keyEquivalent: "") {
                web.disconnect()
            }
        }
        let title = web.lastError.map { "Spotify: \($0)" } ?? "Connect Spotify Library…"
        return CallbackMenuItem(title: title, keyEquivalent: "") { [weak self] in
            self?.connectSpotify(web)
        }
    }

    /// Asks for the client ID once, then opens Spotify's consent page.
    ///
    /// The ID is not a secret — PKCE exists precisely so a public client has none
    /// — but it is per-user, because it identifies an app registered on their own
    /// developer account.
    private func connectSpotify(_ web: SpotifyWeb) {
        if web.clientID.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Spotify client ID"
            alert.informativeText = """
                Create an app at developer.spotify.com/dashboard, add \
                \(SpotifyWeb.registeredRedirect) as a Redirect URI, tick Web API, \
                then paste the Client ID here.
                """
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
            field.placeholderString = "32 hex characters"
            alert.accessoryView = field
            alert.addButton(withTitle: "Connect")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            guard alert.runModal() == .alertFirstButtonReturn else { return }
            let id = field.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !id.isEmpty else { return }
            Settings.shared.spotifyClientID = id
        }
        Task { await web.connect() }
    }

    /// Live nudges for the cutout the app draws.
    ///
    /// `safeAreaInsets.top` and the two auxiliary areas are the only public
    /// description of the notch and ScreenMetrics' own doc says they disagree
    /// across hardware and OS versions — which is why the offsets have existed
    /// since the beginning. Nothing could ever set them, so whatever the API
    /// reported was final, and if it was wrong the shell painted black past the
    /// real cutout with no way to correct it.
    ///
    /// The submenu opens on the resulting size so it can be read back and baked
    /// in as a default. It was the item's own title once, which put a debug
    /// readout at the top level of a menu everyone opens.
    private func notchSizeItem(_ settings: Settings) -> NSMenuItem {
        let size = coordinator?.notchSize ?? .zero
        let item = NSMenuItem(title: "Calibrate Notch", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        // From the controller, not recomputed. Written out here it was a second
        // copy of `cutoutCornerRadius`'s formula, so the menu could report a
        // radius the shape was not drawing.
        let readout = NSMenuItem(title: String(format: "%.0f × %.0f pt, corner %.0f",
                                               size.width, size.height,
                                               coordinator?.cutoutCornerRadius ?? 0),
                                 action: nil, keyEquivalent: "")
        readout.isEnabled = false
        sub.addItem(readout)
        sub.addItem(.separator())
        func nudge(_ title: String, _ key: String, _ apply: @escaping () -> Void) {
            sub.addItem(CallbackMenuItem(title: title, keyEquivalent: key) { [weak self] in
                apply()
                self?.coordinator?.applySettingsChange()
            })
        }
        nudge("Narrower", "[") { settings.notchAdjustedWidth -= 2 }
        nudge("Wider", "]") { settings.notchAdjustedWidth += 2 }
        sub.addItem(.separator())
        nudge("Shorter", "-") { settings.notchAdjustedHeight -= 1 }
        nudge("Taller", "=") { settings.notchAdjustedHeight += 1 }
        sub.addItem(.separator())
        nudge("Squarer Corners", "") { settings.notchAdjustedRadius -= 1 }
        nudge("Rounder Corners", "") { settings.notchAdjustedRadius += 1 }
        sub.addItem(.separator())
        nudge("Reset to Hardware", "") {
            settings.notchAdjustedWidth = 0
            settings.notchAdjustedHeight = 0
            settings.notchAdjustedRadius = 0
        }
        item.submenu = sub
        return item
    }

    private func action(_ title: String, key: String, _ handler: @escaping () -> Void) -> NSMenuItem {
        let item = CallbackMenuItem(title: title, keyEquivalent: key, handler: handler)
        return item
    }

    /// `value` is read fresh every time the menu opens, so the handler can just
    /// write its negation — no captured copy to drift out of sync.
    private func toggle(_ title: String, value: Bool, _ handler: @escaping (Bool) -> Void) -> NSMenuItem {
        let item = CallbackMenuItem(title: title, keyEquivalent: "") { }
        item.state = value ? .on : .off
        item.handler = { handler(!value) }
        return item
    }
}

/// `NSMenuItem` that owns its action closure.
///
/// The original uses an `ActionTrampoline` plus objc associated objects for this;
/// a subclass that is its own target is simpler and retains the closure naturally.
final class CallbackMenuItem: NSMenuItem {
    var handler: () -> Void

    init(title: String, keyEquivalent: String, handler: @escaping () -> Void) {
        self.handler = handler
        super.init(title: title, action: #selector(fire), keyEquivalent: keyEquivalent)
        target = self
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("not used") }

    @objc private func fire() { handler() }
}
