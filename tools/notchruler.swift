import AppKit

// notchruler — measure the physical notch, and draw guides over it.
//
// The notch metrics macOS reports disagree across hardware and OS versions, and
// every alignment bug in a notch app traces back to trusting the wrong number.
// This prints exactly what the system says, and `--overlay` draws those numbers
// on the screen so you can see whether they match the actual cutout.

struct Metrics {
    let screen: NSScreen
    let name: String
    let frame: CGRect
    let scale: CGFloat
    let safeTop: CGFloat
    let left: CGRect?
    let right: CGRect?

    init(_ s: NSScreen) {
        screen = s
        name = s.localizedName
        frame = s.frame
        scale = s.backingScaleFactor
        safeTop = s.safeAreaInsets.top
        left = s.auxiliaryTopLeftArea
        right = s.auxiliaryTopRightArea
    }

    /// The cutout in screen coordinates, or nil if this display has none.
    var notch: CGRect? {
        guard let l = left, let r = right, safeTop > 0 else { return nil }
        let w = r.minX - l.maxX
        guard w > 1 else { return nil }
        return CGRect(x: l.maxX, y: frame.maxY - safeTop, width: w, height: safeTop)
    }

    func report() {
        print("── \(name)")
        print("   frame            \(fmt(frame))")
        print("   backing scale    \(scale)x")
        print("   safeAreaInsets   top=\(safeTop)  bottom=\(screen.safeAreaInsets.bottom)")
        print("   auxTopLeftArea   \(left.map(fmt) ?? "nil")")
        print("   auxTopRightArea  \(right.map(fmt) ?? "nil")")
        if let n = notch {
            print("   NOTCH            \(fmt(n))")
            print("                    width  \(n.width) pt   (\(n.width * scale) px)")
            print("                    height \(n.height) pt   (\(n.height * scale) px)")
            print("                    left   x=\(n.minX)   right x=\(n.maxX)")
            print("                    screen midX=\(frame.midX)  notch midX=\(n.midX)"
                  + (abs(frame.midX - n.midX) > 0.5 ? "   ⚠️ NOT CENTRED" : "   (centred)"))
        } else {
            print("   NOTCH            none on this display")
        }
        print("")
    }

    private func fmt(_ r: CGRect) -> String {
        String(format: "x=%.1f y=%.1f w=%.1f h=%.1f", r.minX, r.minY, r.width, r.height)
    }
}

// MARK: - Overlay

final class GuideView: NSView {
    var metrics: Metrics!
    override var isFlipped: Bool { true }

    override func draw(_ dirty: NSRect) {
        guard let notch = metrics.notch else { return }
        NSColor.black.withAlphaComponent(0.18).setFill()
        bounds.fill()

        // Convert screen coords -> view coords (view sits at the top of the screen).
        let sf = metrics.frame
        let x0 = notch.minX - sf.minX
        let x1 = notch.maxX - sf.minX
        let h = notch.height

        let magenta = NSColor.systemPink
        let cyan = NSColor.cyan

        // Vertical guides at the cutout edges, full height of the overlay.
        magenta.setStroke()
        for x in [x0, x1] {
            let p = NSBezierPath()
            p.move(to: CGPoint(x: x, y: 0))
            p.line(to: CGPoint(x: x, y: bounds.height))
            p.lineWidth = 1
            p.stroke()
        }

        // Horizontal guide at the bottom of the cutout / menu-bar band.
        cyan.setStroke()
        let hb = NSBezierPath()
        hb.move(to: CGPoint(x: 0, y: h))
        hb.line(to: CGPoint(x: bounds.width, y: h))
        hb.lineWidth = 1
        hb.stroke()

        // Outline the cutout itself.
        magenta.withAlphaComponent(0.9).setStroke()
        let box = NSBezierPath(rect: CGRect(x: x0, y: 0, width: notch.width, height: h))
        box.lineWidth = 1.5
        box.stroke()

        // 10pt ticks along the top, every 50pt labelled.
        NSColor.white.withAlphaComponent(0.5).setStroke()
        var x = CGFloat(0)
        while x < bounds.width {
            let long = x.truncatingRemainder(dividingBy: 50) == 0
            let t = NSBezierPath()
            t.move(to: CGPoint(x: x, y: bounds.height))
            t.line(to: CGPoint(x: x, y: bounds.height - (long ? 10 : 5)))
            t.lineWidth = 1
            t.stroke()
            if long {
                label("\(Int(x))", at: CGPoint(x: x + 2, y: bounds.height - 22),
                      color: .white.withAlphaComponent(0.55), size: 9)
            }
            x += 10
        }

        label(String(format: "notch  %.1f × %.1f pt", notch.width, notch.height),
              at: CGPoint(x: x0 + notch.width / 2 - 52, y: h + 96), color: magenta, size: 12)
        label(String(format: "x %.1f", notch.minX),
              at: CGPoint(x: max(2, x0 - 54), y: h + 96), color: magenta, size: 11)
        label(String(format: "x %.1f", notch.maxX),
              at: CGPoint(x: x1 + 6, y: h + 96), color: magenta, size: 11)
        label(String(format: "menu-bar band  %.1f pt", h),
              at: CGPoint(x: 10, y: h + 8), color: cyan, size: 11)
    }

    private func label(_ s: String, at p: CGPoint, color: NSColor, size: CGFloat) {
        let a: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: size, weight: .semibold),
            .foregroundColor: color,
        ]
        NSAttributedString(string: s, attributes: a).draw(at: p)
    }
}

// MARK: - Main

let args = CommandLine.arguments
let overlay = args.contains("--overlay")
let seconds = args.firstIndex(of: "--seconds").flatMap { i -> Double? in
    i + 1 < args.count ? Double(args[i + 1]) : nil
} ?? 20

let app = NSApplication.shared
app.setActivationPolicy(.accessory)

let all = NSScreen.screens.map(Metrics.init)
print("")
for m in all { m.report() }

guard overlay else {
    print("tip: notchruler --overlay [--seconds N]   draws these guides on screen")
    exit(0)
}

var windows: [NSWindow] = []
for m in all where m.notch != nil {
    let height: CGFloat = 170
    let rect = NSRect(x: m.frame.minX, y: m.frame.maxY - height,
                      width: m.frame.width, height: height)
    let w = NSPanel(contentRect: rect,
                    styleMask: [.borderless, .nonactivatingPanel],
                    backing: .buffered, defer: false)
    w.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 2)
    w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
    w.isOpaque = false
    w.backgroundColor = .clear
    w.hasShadow = false
    w.ignoresMouseEvents = true          // never blocks what's underneath
    let v = GuideView(frame: NSRect(origin: .zero, size: rect.size))
    v.metrics = m
    w.contentView = v
    w.orderFrontRegardless()
    windows.append(w)
}

print("overlay up for \(Int(seconds))s — pink = cutout edges, cyan = menu-bar band")
DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { app.terminate(nil) }
app.run()
