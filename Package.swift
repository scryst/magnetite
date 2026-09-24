// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "NotchApp",
    // macOS 26 is the floor for Liquid Glass (`glassEffect`, `GlassEffectContainer`,
    // `glassEffectID`). Those are the whole point of the visual design here, so we
    // take the newer floor rather than hand-rolling a lesser material.
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "NotchApp",
            path: "Sources/NotchApp",
            swiftSettings: [
                // AppKit/SwiftUI interop is pervasively main-actor bound; v5 mode keeps
                // the isolation annotations readable instead of ceremonial.
                .swiftLanguageMode(.v5),
            ],
            linkerSettings: [
                .linkedFramework("AppKit"),
                .linkedFramework("SwiftUI"),
                .linkedFramework("ScriptingBridge"),
                .linkedFramework("CoreAudio"),
                .linkedFramework("QuartzCore"),
                .linkedFramework("AudioToolbox"),
                .linkedFramework("Accelerate"),
            ]
        )
    ]
)
