import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {

    private var coordinator: NotchCoordinator?
    private var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Menu-bar only. LSUIElement covers the bundled case; this makes `swift run`
        // behave the same.
        NSApp.setActivationPolicy(.accessory)

        // One Magnetite per session: a second copy would draw a second panel, answer
        // every swipe twice, run a second audio tap and lose the Spotify callback port.
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

    /// Handles `magnetite://` URLs: `toggle`, `expand`, `collapse`, `spotify-connect`,
    /// `spotify-disconnect`, `like`, `shuffle`, `repeat` and `state`.
    ///
    /// Scripted control makes UI states reachable from a shell, which is the practical
    /// way to verify a window that only appears on hover. The scheme is not kept
    /// alongside an older one: it is a global claim on the machine, and two
    /// registrations for one app can launch the wrong copy.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls where url.scheme == "magnetite" {
            switch url.host ?? url.path.replacingOccurrences(of: "/", with: "") {
            case "toggle":   coordinator?.toggleAll()
            case "expand":   coordinator?.setExpandedAll(true)
            case "collapse": coordinator?.setExpandedAll(false)
            // Scriptable so the consent flow can be started without a menu item and re-run
            // after a token expires.
            case "spotify-connect":
                if let web = coordinator?.media.spotify { Task { await web.connect() } }
            case "spotify-disconnect":
                coordinator?.media.spotify.disconnect()
            // Scriptable for the same reason: these controls only exist inside a panel that
            // appears on hover.
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
        // The app's own mark rather than a system symbol. `MagnetiteMark` is generated
        // from the icon master, so it is the same contour as the Dock tile and favicon,
        // and a template image, so the menu bar owns the colour.
        item.button?.image = MagnetiteMark.menuBarImage(height: 16)
        item.button?.image?.accessibilityDescription = "Magnetite"

        let menu = NSMenu()
        menu.delegate = self
        item.menu = menu
        statusItem = item
    }

    /// Rebuilt every time it opens, so checkmarks and toggles read the current setting
    /// rather than a copy captured at build time.
    func menuNeedsUpdate(_ menu: NSMenu) {
        // Pick up an audio-capture grant made since the last look.
        coordinator?.retryAudioCapture()
        menu.removeAllItems()
        let settings = Settings.shared

        // Problems first, and only when there is one: a visualiser that never moves
        // because a grant was refused looks the same as a broken one. Each note is
        // followed by the action that fixes it.
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
            // `musicApp` is read only by the next media refresh, and switching away from the
            // running player stops the timer that would have produced one, so the change
            // has to be announced.
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
        // A mistyped or deleted Spotify app leaves the saved ID with no way out, since
        // Connect only asks while the ID is empty.
        if let web = coordinator?.media.spotify, !web.isConnected, !web.clientID.isEmpty {
            menu.addItem(CallbackMenuItem(title: "Change Spotify Client ID…", keyEquivalent: "") { [weak self] in
                self?.connectSpotify(web, askForID: true)
            })
        }

        // Named for what the user sees. Hover-to-open and the cover-and-clock strip are
        // independent states (progress in the menu bar always, the player on request).
        menu.addItem(.separator())
        menu.addItem(.sectionHeader(title: "Notch"))
        menu.addItem(toggle("Open on Hover", value: settings.expandNotchOnHover) { on in
            Settings.shared.expandNotchOnHover = on
        })
        menu.addItem(toggle("Mini Player When Closed", value: settings.showsMiniPlayer) { on in
            Settings.shared.showsMiniPlayer = on
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
        // Registered but blocked in Login Items reads as "off" and a second click does
        // nothing, so say so and send the user there.
        if SMAppService.mainApp.status == .requiresApproval {
            menu.addItem(CallbackMenuItem(title: "Launch at Login: Allow in System Settings…", keyEquivalent: "") {
                SMAppService.openSystemSettingsLoginItems()
            })
        } else {
            menu.addItem(toggle("Launch at Login", value: launchAtLoginEnabled) { [weak self] on in
                self?.setLaunchAtLogin(on)
            })
        }
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

    /// Every state that stops the app working, each with its remedy. Usually empty.
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

        // No settings pane here: the grant is fine and the player never answered, so
        // the only help is restarting it.
        if let text = coordinator?.stalledNote {
            note(text, "Magnetite is asking, and your music app isn't replying. "
                + "Quitting and reopening it usually clears this.")
        }

        // Only the tap's own creation can be a refused grant. A failed aggregate device,
        // IOProc or start belongs to the audio system.
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

        // A connected library that is failing has nowhere else to say so: `spotifyItem`
        // returns the Disconnect item as soon as `isConnected` is true and reads
        // `lastError` only on the branch below it.
        if let web = coordinator?.media.spotify, web.isConnected, let text = web.lastErrorTitle {
            note(text,"The library connection is set up but the last request failed.")
        }
        return items
    }

    // MARK: About

    static let sourceURL = URL(string: "https://github.com/scryst/magnetite")!
    static let releasesURL = URL(string: "https://github.com/scryst/magnetite-releases/releases/latest")!

    /// The standard About panel plus where the source lives. An accessory app has to
    /// come forward first or the panel opens behind the frontmost app.
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
                if SMAppService.mainApp.status == .requiresApproval {
                    SMAppService.openSystemSettingsLoginItems()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            // Unregistered bundles (a bare `swift run`) cannot do this.
            FileHandle.standardError.write(
                "[login] \(on ? "register" : "unregister") failed: \(error)\n"
                    .data(using: .utf8)!)
        }
    }

    // MARK: Closure-backed menu items

    /// Connects Spotify's library, the only route to liking a track: `starred` is
    /// read-only in the local player's dictionary. Authorization Code with PKCE, so
    /// there is no client secret; the refresh token lives in `TokenStore`'s 0600 file.
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
        let title = web.lastErrorTitle ?? "Connect Spotify Library…"
        return CallbackMenuItem(title: title, keyEquivalent: "") { [weak self] in
            self?.connectSpotify(web)
        }
    }

    /// Asks for the client ID once, then opens Spotify's consent page. The ID is not a
    /// secret (PKCE has none) but is per user, since it names an app registered on
    /// their own developer account.
    private func connectSpotify(_ web: SpotifyWeb, askForID: Bool = false) {
        if askForID || web.clientID.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Spotify client ID"
            alert.informativeText = """
                Create an app at developer.spotify.com/dashboard, add \
                \(SpotifyWeb.registeredRedirect) as a Redirect URI, tick Web API, \
                then paste the Client ID here.
                """
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
            field.placeholderString = "32 hex characters"
            field.stringValue = web.clientID
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

    /// Live nudges for the cutout the app draws. The public notch APIs disagree across
    /// hardware and OS versions (see `ScreenMetrics`), so the user can correct them.
    /// The submenu opens on the resulting size so it can be read back and baked in
    /// as a default.
    private func notchSizeItem(_ settings: Settings) -> NSMenuItem {
        let size = coordinator?.notchSize ?? .zero
        let item = NSMenuItem(title: "Calibrate Notch", action: nil, keyEquivalent: "")
        let sub = NSMenu()
        // From the controller, not recomputed, so the menu cannot report a radius the
        // shape is not drawing.
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

    /// `value` is read fresh each time the menu opens, so the handler writes its
    /// negation with no captured copy to drift.
    private func toggle(_ title: String, value: Bool, _ handler: @escaping (Bool) -> Void) -> NSMenuItem {
        let item = CallbackMenuItem(title: title, keyEquivalent: "") { }
        item.state = value ? .on : .off
        item.handler = { handler(!value) }
        return item
    }
}

/// An `NSMenuItem` that owns its action closure and is its own target.
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
