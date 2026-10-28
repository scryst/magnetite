import AppKit
import SwiftUI

/// SwiftUI insets content away from the notch; here the content is the notch, so the
/// insets are flattened. Hit-testing uses the notch region rather than the view's
/// bounds: the panel stays much larger than the collapsed notch so the shape can
/// morph without resizing the window, and its empty area must not swallow clicks.
final class NotchHostingView<Content: View>: NSHostingView<Content> {

    /// Size of the drawn shell, which hangs centred from the view's top edge.
    var shellSize: () -> CGSize = { .zero }

    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsets() }

    /// The shell measured from the top edge. A hosting view is flipped, so a region
    /// written in bottom-up AppKit terms hangs from the bottom instead: the title row
    /// and the heart stopped taking clicks, and a strip under the open panel swallowed
    /// clicks meant for the window beneath.
    var hitRegion: CGRect {
        let s = shellSize()
        let y = isFlipped ? 0 : bounds.height - s.height
        return CGRect(x: (bounds.width - s.width) / 2, y: y, width: s.width, height: s.height)
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard hitRegion.insetBy(dx: -2, dy: -2).contains(local) else { return nil }
        return super.hitTest(point)
    }
}

/// The notch window.
///
/// Borderless, non-activating, above the menu bar, on every Space, and excluded from
/// screen capture (see `applyScreenCapturePolicy`).
///
/// The frame stays at the expanded size for the window's lifetime; all motion
/// happens inside SwiftUI, because resizing an `NSWindow` every frame janks.
final class NotchPanel: NSPanel {

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)

        level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.statusWindow)) + 1)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        isMovableByWindowBackground = false
        hidesOnDeactivate = false
        isReleasedWhenClosed = false
        animationBehavior = .none
        // Click-through while collapsed (hover comes from a global monitor); expanding
        // turns interaction back on.
        ignoresMouseEvents = true
    }

    /// Never take focus — the notch must never steal the user's keyboard.
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
    override var acceptsFirstResponder: Bool { false }

    func setInteractive(_ interactive: Bool) {
        guard ignoresMouseEvents == interactive else { return }
        ignoresMouseEvents = !interactive
    }

    func applyScreenCapturePolicy(hidden: Bool) {
        sharingType = hidden ? .none : .readOnly
    }
}
