import AppKit

// Manual startup rather than @main: an LSUIElement app that owns its own windows
// has no use for SwiftUI's App scene machinery, and this keeps the launch path
// obvious.
// Top-level code already runs on the main thread; assumeIsolated states that to
// the compiler without a needless hop.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    // Keep the delegate alive for the process lifetime.
    withExtendedLifetime(delegate) {
        app.run()
    }
}
