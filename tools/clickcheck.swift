// Appended to NotchView.swift by tools/clickcheck so the real open panel takes the clicks.
// The panel is hosted the way the app hosts it, in a transparent window far off every
// display, and every click goes through `NSWindow.sendEvent`: the same hit test and the
// same SwiftUI buttons a real press reaches, without the pointer, a player or a display.
@main @MainActor enum ClickCheck {
    static var failures = 0

    static func require(_ ok: Bool, _ message: String) {
        if !ok { failures += 1; print("clickcheck: FAILED | \(message)") }
    }

    static func click(_ window: NSWindow, at point: NSPoint) {
        for type in [NSEvent.EventType.leftMouseDown, .leftMouseUp] {
            let event = NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: window.windowNumber, context: nil,
                                           eventNumber: 0, clickCount: 1, pressure: 1)!
            window.sendEvent(event)
            RunLoop.main.run(until: Date().addingTimeInterval(0.002))
        }
    }

    /// The open panel hosted the way the app hosts it: the app's window size (the largest
    /// panel plus `NotchCoordinator.margin`), transparent and far off every display.
    /// SwiftUI ignores events in a window that was never ordered in, so this one is, but
    /// nobody can see it or click it.
    static func host(_ controller: NotchController, _ media: MediaManager,
                     region: (() -> CGSize)?) -> (NSWindow, CGSize) {
        let size = CGSize(width: ChromeRules.panelWidth + 128,
                          height: 40 + ChromeRules.expandedBody + ChromeRules.lyricsBody + 78)
        let view = NotchHostingView(rootView: NotchRootView(controller: controller, media: media,
                                                            fluid: FerrofluidSim()))
        // With no region the whole window takes clicks: the baseline of what each point
        // of the panel would do if the hit test hid nothing.
        view.shellSize = region ?? { size }
        let window = NotchPanel(contentRect: NSRect(origin: .zero, size: size))
        window.setInteractive(true)
        window.contentView = view
        view.frame = NSRect(origin: .zero, size: size)
        window.alphaValue = 0
        window.setFrameOrigin(NSPoint(x: -20_000, y: -20_000))
        window.orderFrontRegardless()
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        return (window, size)
    }

    /// Every 4 pt across the window, top row first: the action a click there reaches, or
    /// nil.
    static func scan(_ window: NSWindow, _ size: CGSize, _ media: MediaManager) -> [[String?]] {
        let step: CGFloat = 4
        return stride(from: size.height - step / 2, to: 0, by: -step).map { y in
            stride(from: step / 2, to: size.width, by: step).map { x in
                media.calls = []
                click(window, at: NSPoint(x: x, y: y))
                return media.calls.first
            }
        }
    }

    static func main() {
        Motion.reduceMotion = true
        // SwiftUI handles a button's events only inside an app.
        NSApplication.shared.setActivationPolicy(.prohibited)
        // Twice: the panel without lyrics, and taller with the lyrics stage, whose lines
        // must neither take a click nor push the controls out of the region.
        check(lyrics: false)
        check(lyrics: true)
        if failures > 0 { exit(1) }
        print("clickcheck: with and without lyrics, all 7 controls answer a click, the hit region hides none of them, and nothing under the panel does")
    }

    static func check(lyrics: Bool) {
        let media = MediaManager()
        let controller = NotchController()
        controller.isExpanded = true
        media.source = .spotify
        if lyrics {
            controller.hasLyrics = true
            media.isPlaying = true
            media.lyrics = SyncedLyrics(lrc: "[00:01.00]A line long enough to wrap across the whole stage and then some more\n[02:00.00]Next")
        }
        let shell = controller.currentSize

        let (window, size) = host(controller, media, region: { controller.currentSize })
        let real = scan(window, size, media)
        window.orderOut(nil)
        let (open, _) = host(controller, media, region: nil)
        let bare = scan(open, size, media)

        let glyph = ["toggleLike": "h", "previous": "<", "playPause": "P", "next": ">",
                     "toggleShuffle": "s", "toggleRepeat": "r", "openInPlayer": "A", "seek": "~", "openArtist": "a"]
        let reached = Set(real.joined().compactMap { $0 })
        let expected = ["toggleLike", "previous", "playPause", "next", "toggleShuffle",
                        "toggleRepeat", "openInPlayer"]
        for call in expected {
            require(reached.contains(call), "no click anywhere on the open panel reaches \(call)")
        }
        // The hit region may only ever turn away clicks that reach nothing anyway.
        var hidden: [String: Int] = [:]
        for (r, b) in zip(real.joined(), bare.joined()) where r == nil && b != nil {
            hidden[b!, default: 0] += 1
        }
        for (call, count) in hidden.sorted(by: { $0.key < $1.key }) {
            require(false, "\(lyrics ? "with lyrics: " : "")the hit region turns away \(count) clicks that reach \(call)")
        }
        // Under the shell is the window beneath's: nothing there may answer.
        let shellRows = Int((shell.height / 4).rounded(.up)) + 1
        let below = real.dropFirst(shellRows).joined().compactMap { $0 }
        require(below.isEmpty, "\(below.count) clicks under the open panel reached a control")

        if failures > 0 || CommandLine.arguments.contains("--map") {
            print(lyrics ? "with lyrics:" : "without lyrics:")
            print(real.map { $0.map { $0.map { glyph[$0] ?? "?" } ?? "." }.joined() }.joined(separator: "\n"))
        }
        window.orderOut(nil)
        open.orderOut(nil)
    }
}
