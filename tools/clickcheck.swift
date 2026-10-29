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
    static let step: CGFloat = 4

    static func point(row: Int, col: Int, _ size: CGSize) -> NSPoint {
        NSPoint(x: step / 2 + CGFloat(col) * step, y: size.height - step / 2 - CGFloat(row) * step)
    }

    static func scan(_ window: NSWindow, _ size: CGSize, _ media: MediaManager) -> [[String?]] {
        let rows = Int(((size.height - step / 2) / step).rounded(.up))
        let cols = Int(((size.width - step / 2) / step).rounded(.up))
        return (0..<rows).map { row in
            (0..<cols).map { col in
                media.calls = []
                click(window, at: point(row: row, col: col, size))
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
        aWideCoverStaysInItsSquare()
        if failures > 0 { exit(1) }
        print("clickcheck: with and without lyrics, all 7 controls answer a click, the hit region hides none of them, and nothing under the panel does; a 16:9 cover is cropped to its square")
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
        var real = scan(window, size, media)
        window.orderOut(nil)
        let (open, _) = host(controller, media, region: nil)
        let bare = scan(open, size, media)
        open.orderOut(nil)
        // A busy Mac can deliver a button's action after the 2 ms pump, so a cell the
        // region let through may read as nil. The region is geometry and does not change
        // with time: click each disagreeing cell again and wait properly.
        window.orderFrontRegardless()
        for (row, cells) in real.enumerated() {
            for (col, call) in cells.enumerated() where call == nil && bare[row][col] != nil {
                media.calls = []
                click(window, at: point(row: row, col: col, size))
                RunLoop.main.run(until: Date().addingTimeInterval(0.1))
                real[row][col] = media.calls.first
            }
        }

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

    /// A music video's cover is a 16:9 still (Spotify sends 640x360). The tile is square
    /// at both sizes, so the still is cropped to it: drawn wider, it ran over the title
    /// in the open card and past the camera in the closed strip.
    static func aWideCoverStaysInItsSquare() {
        let wide = NSImage(size: NSSize(width: 160, height: 90), flipped: false) { rect in
            NSColor.white.setFill()
            rect.fill()
            return true
        }
        for (side, radius) in [(CGFloat(88), CGFloat(14)), (19, 5.5)] {
            let pad: CGFloat = side / 2
            let renderer = ImageRenderer(content: Artwork(image: wide, palette: .fallback,
                                                          size: side, radius: radius)
                .frame(width: side, height: side)
                .padding(pad)
                .frame(width: side + 2 * pad, height: side + 2 * pad))
            renderer.scale = 2
            guard let image = renderer.cgImage else {
                require(false, "the \(Int(side)) pt cover did not render")
                continue
            }
            let bitmap = NSBitmapImageRep(cgImage: image)
            let scale = CGFloat(image.width) / (side + 2 * pad)
            func light(_ x: CGFloat, _ y: CGFloat) -> CGFloat {
                let c = bitmap.colorAt(x: Int(x * scale), y: Int(y * scale))!.usingColorSpace(.deviceRGB)!
                return c.redComponent * c.alphaComponent
            }
            let mid = pad + side / 2
            // Just inside the slot's left and right edges: the still fills the square.
            require(light(pad + side * 0.1, mid) > 0.9 && light(pad + side * 0.9, mid) > 0.9,
                    "a 16:9 cover leaves the \(Int(side)) pt square unfilled")
            // A quarter of the slot outside either edge: nothing of the still.
            for x in [pad - side / 4, pad + side * 1.25] {
                require(light(x, mid) < 0.5,
                        "a 16:9 cover draws \(Int(side / 4)) pt outside its \(Int(side)) pt square")
            }
        }
    }
}
