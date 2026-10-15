import AppKit

// Manual startup instead of @main: the app owns its own windows and has no use for
// SwiftUI's App scene machinery. Top-level code already runs on the main thread;
// assumeIsolated says so to the compiler.
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
