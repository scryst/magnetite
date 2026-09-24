import AppKit
import SwiftUI

/// SwiftUI insets content away from the notch automatically. When your content
/// *is* the notch that is exactly backwards, so we flatten the insets.
///
/// It also hit-tests against the notch region rather than its own bounds. The
/// panel is deliberately much larger than the collapsed notch — that's what lets
/// the shape morph without ever resizing the window — so without this the empty
/// area would swallow clicks meant for the desktop.
final class NotchHostingView<Content: View>: NSHostingView<Content> {

    /// Notch region in this view's (unflipped, AppKit) coordinates.
    var hitRegion: () -> CGRect = { .zero }

    override var safeAreaInsets: NSEdgeInsets { NSEdgeInsets() }

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard hitRegion().insetBy(dx: -2, dy: -2).contains(local) else { return nil }
        return super.hitTest(point)
    }
}

/// The notch window.
///
/// Borderless, non-activating, above the menu bar, present on every Space, and
/// excluded from screen capture — a fake notch showing up in a recording looks
/// broken, which is why the real app makes that a setting.
///
/// The frame is fixed at the expanded size for the lifetime of the window. All
/// motion happens inside, in SwiftUI. Resizing an `NSWindow` every frame is the
/// single biggest source of jank in notch apps; not doing it is why this morph
/// stays smooth.
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
        // Collapsed, the window is entirely click-through; hover is detected with
        // a global monitor instead. Expanding turns interaction back on.
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
