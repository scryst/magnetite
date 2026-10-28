import AppKit
import Foundation
import SwiftUI

/// Headless checks on the per-display notch state machine.
///
/// `NotchController` is pure state (no drawing, events or network). It needs an
/// `NSScreen` only to measure once at init, and every rule below concerns what
/// the state machine does afterwards. A display must exist; this is asserted
/// rather than skipped, because a suite that passes when it could not run proves
/// nothing.
@main
enum ControllerCheck {
    @MainActor
    static func main() {
        hidingForgetsWhereThePointerWas()
        aHiddenNotchCannotBeOpened()
        hidingClosesWhatIsOpen()
        theExpansionCallbackFiresOnlyOnRealTransitions()
        theMenuToggleStaysOpenUntilItIsToggledBack()
        aHudDoesNotLandBehindTheOpenPanel()
        theHudNeverReportsMoreThanFull()
        theMiniPlayerTurnsOnAndOff()
        everyStoredSettingIsCarriedAcrossTheRename()
        theURLSchemeTheAppAnswersIsTheOneItRegistered()
        everyNameTheAppHasShippedUnderIsStillMigrated()
        theOpenPanelTakesClicksFromItsTopEdge()
        print("controllercheck: all checks passed")
    }

    /// A notch that hides under the pointer must not still think it is hovered.
    /// Hiding does not move the mouse, so no exit is reported; a controller left
    /// believing the pointer is inside never sees the false-to-true edge that
    /// `handleMouseMoved` turns into `mouseEntered`, and hover never re-arms.
    ///
    /// Asserted on the controller rather than by re-running the coordinator's
    /// edge rule, which would only show a copy of the rule agreeing with itself.
    @MainActor
    static func hidingForgetsWhereThePointerWas() {
        let notch = controller()
        notch.mouseEntered()
        require(notch.isMouseInside, "mouseEntered did not register at all")

        notch.setVisible(false)
        require(!notch.isMouseInside,
                "the notch hid under the pointer and went on believing it was "
                + "hovered, so the next sighting is not an entry and hover never "
                + "re-arms")

        notch.setVisible(true)
        require(!notch.isMouseInside,
                "the notch came back still claiming the pointer was inside it")
    }

    /// The URL scheme and the menu command do not go through the window, so
    /// nothing else stops them pinning an invisible panel open over someone's
    /// fullscreen video.
    @MainActor
    static func aHiddenNotchCannotBeOpened() {
        let notch = controller()
        notch.setVisible(false)

        notch.expand(byHover: false, pinned: true)
        require(!notch.isExpanded, "a hidden notch was expanded by a direct call")

        notch.toggle()
        require(!notch.isExpanded, "a hidden notch was expanded by the menu toggle")
    }

    /// Whatever is on screen goes away with the notch, including a pinned panel,
    /// which has no other way out since a pin survives the pointer leaving.
    @MainActor
    static func hidingClosesWhatIsOpen() {
        let notch = controller()
        notch.toggle()
        require(notch.isExpanded, "the menu toggle did not open the panel")

        notch.setVisible(false)
        require(!notch.isExpanded, "a pinned panel outlived the notch it lives in")
    }

    /// The fluid re-reads the panel's geometry on this callback, so it must fire
    /// only for real transitions.
    @MainActor
    static func theExpansionCallbackFiresOnlyOnRealTransitions() {
        let notch = controller()
        var opens = 0, closes = 0
        notch.onExpansionChange = { $0 ? (opens += 1) : (closes += 1) }

        notch.expand()
        notch.expand()
        require(opens == 1, "expanding an open panel reported \(opens) moves")

        notch.collapse()
        notch.collapse()
        require(closes == 1, "collapsing a shut panel reported \(closes) moves")
    }

    /// The menu toggle stays open until toggled back. The pointer is at the menu
    /// when the command fires, outside the notch, so without the pin
    /// `mouseExited` would collapse the panel behind it. The pin must also be
    /// released on the way closed, or the next hover-opened panel inherits it.
    @MainActor
    static func theMenuToggleStaysOpenUntilItIsToggledBack() {
        let notch = controller()
        notch.toggle()
        require(notch.isExpanded && notch.isPinned,
                "the menu toggle opened the panel without pinning it, so the "
                + "pointer being elsewhere closes it again")

        notch.toggle()
        require(!notch.isExpanded, "a second toggle did not close the panel")
        require(!notch.isPinned,
                "the pin outlived the panel, so the next hover-opened panel "
                + "inherits it and never retracts")
    }

    /// A volume or brightness HUD belongs to the retracted state. Presented
    /// behind the open panel it would dwell unseen and overwrite the HUD state
    /// the next real peek reads.
    @MainActor
    static func aHudDoesNotLandBehindTheOpenPanel() {
        let notch = controller()
        notch.toggle()
        require(notch.isExpanded, "the panel did not open")

        notch.present(.didChangeVolume, progress: 0.7, isMuted: true)
        require(notch.hudProgress == 0,
                "a HUD wrote its progress behind the open panel, so the value "
                + "the next peek shows came from an event nobody saw")
        require(!notch.hudIsMuted, "a HUD wrote its mute state behind the open panel")
    }

    /// The HUD's progress drives a bar drawn to its own width, so a value past
    /// either end would overhang rather than clip.
    @MainActor
    static func theHudNeverReportsMoreThanFull() {
        let notch = controller()
        notch.present(.didChangeVolume, progress: 1.8)
        require(notch.hudProgress == 1, "a HUD reported \(notch.hudProgress) of a full bar")

        notch.present(.didChangeBrightness, progress: -0.5)
        require(notch.hudProgress == 0, "a HUD reported \(notch.hudProgress) of a full bar")
    }

    /// The mini player is the closed notch's entire content, so both edges must
    /// land. (The guard in `showMiniPlayer` is not observable here: `@Observable`
    /// already compares Equatable values before notifying.)
    @MainActor
    static func theMiniPlayerTurnsOnAndOff() {
        let notch = controller()

        notch.showMiniPlayer()
        require(notch.isMiniPlayerShown, "the mini player never turned on")

        notch.hideMiniPlayer()
        require(!notch.isMiniPlayerShown, "the mini player never turned off")
    }

    /// The preference migration's key list must match the preferences that
    /// exist. `Settings.adoptPreferencesFromPreviousBundleID` names its keys in a
    /// literal (copying the whole old domain would bring in everything AppKit
    /// writes there), so a new `@Stored` setting missing from the list would be
    /// dropped silently on upgrade.
    ///
    /// The list is sliced out before matching: asking whether the file contains a
    /// key is answered by the `@Stored` declaration itself and would pass with
    /// the array empty.
    static func everyStoredSettingIsCarriedAcrossTheRename() {
        let path = "Sources/NotchApp/Support/Settings.swift"
        guard let code = try? String(contentsOfFile: path, encoding: .utf8) else {
            require(false, "cannot read \(path) — run this from the repo root")
            return
        }

        let declared = capturedGroups(#"@Stored\("([A-Za-z0-9_]+)""#, in: code)
        require(declared.count >= 14,
                "found only \(declared.count) @Stored keys in Settings.swift, so "
                + "the pattern stopped matching and this check is asserting nothing")

        // Located by declaration, then by its brackets, so a type annotation or
        // reformat moves the list without turning a failure into a no-op.
        guard let decl = code.range(of: "private static let keys"),
              let open = code.range(of: "[", range: decl.upperBound..<code.endIndex),
              let close = code.range(of: "]", range: open.upperBound..<code.endIndex) else {
            require(false, "cannot find the migration's key list in \(path)")
            return
        }
        let list = String(code[open.upperBound..<close.lowerBound])

        for key in declared {
            require(list.contains("\"\(key)\""),
                    "\(key) is a stored preference that the rename migration does "
                    + "not carry, so it is silently dropped for anyone upgrading")
        }

        let listed = capturedGroups(#""([A-Za-z0-9_]+)""#, in: list)
        for key in listed where !declared.contains(key) {
            require(false,
                    "the migration carries \(key), which is no longer a stored "
                    + "preference — either the key was renamed and the list was "
                    + "not, or this is a typo that moves nothing")
        }
    }

    /// The scheme the app answers to is the scheme it registered. They are two
    /// independent strings (`CFBundleURLSchemes` in Info.plist and the literal
    /// `application(_:open:)` compares `url.scheme` against); if they diverge,
    /// LaunchServices still routes the URL but the app drops it with no error,
    /// and every scripted verb stops working. The scheme is how the panel is
    /// driven from a shell.
    static func theURLSchemeTheAppAnswersIsTheOneItRegistered() {
        let plistPath = "Resources/Info.plist"
        guard let data = FileManager.default.contents(atPath: plistPath),
              let plist = (try? PropertyListSerialization.propertyList(
                            from: data, format: nil)) as? [String: Any] else {
            require(false, "cannot read \(plistPath) — run this from the repo root")
            return
        }
        guard let types = plist["CFBundleURLTypes"] as? [[String: Any]],
              let schemes = types.first?["CFBundleURLSchemes"] as? [String],
              let registered = schemes.first, !registered.isEmpty else {
            require(false, "Info.plist registers no URL scheme, so nothing can "
                    + "drive the panel from a shell")
            return
        }

        let path = "Sources/NotchApp/App/AppDelegate.swift"
        guard let code = try? String(contentsOfFile: path, encoding: .utf8) else {
            require(false, "cannot read \(path) — run this from the repo root")
            return
        }
        // Reads the literal in the comparison itself, not the file's vocabulary:
        // a doc comment may spell the scheme too, which would satisfy a
        // "contains" test while the real comparison named the old one.
        guard let at = code.range(of: "url.scheme == \"") else {
            require(false, "AppDelegate no longer compares url.scheme against a "
                    + "literal — this check just became a no-op")
            return
        }
        let answered = String(code[at.upperBound...].prefix { $0 != "\"" })
        require(answered == registered,
                "Info.plist registers \(registered):// but AppDelegate answers "
                + "only \(answered):// — LaunchServices will route the URL and "
                + "the app will drop it, with no error anywhere")
    }

    /// Every bundle identifier and support directory the app has shipped under is
    /// still named by a migration. Preferences are keyed by `CFBundleIdentifier`
    /// and the Spotify refresh token lives in a directory named for the app, so a
    /// rename that forgets to append would reset settings and sign users out of
    /// their library.
    ///
    /// The current name must not appear in either list: a migration reading its
    /// own domain is a no-op that looks like a migration and hides a missing
    /// entry.
    static func everyNameTheAppHasShippedUnderIsStillMigrated() {
        guard let data = FileManager.default.contents(atPath: "Resources/Info.plist"),
              let plist = (try? PropertyListSerialization.propertyList(
                            from: data, format: nil)) as? [String: Any],
              let bundleID = plist["CFBundleIdentifier"] as? String,
              let bundleName = plist["CFBundleName"] as? String else {
            require(false, "cannot read the identity out of Resources/Info.plist")
            return
        }

        // Written down here on purpose: the lists in the source say what is
        // migrated, and only an independent record says what should be.
        let shippedIDs = ["com.laks.NotchApp", "com.laks.ferro"]
        let shippedDirectories = ["NotchApp", "Ferro"]

        check(list: "legacyDomains",
              in: "Sources/NotchApp/Support/Settings.swift",
              carries: shippedIDs, current: bundleID,
              what: "bundle identifier", loses: "every stored preference")

        check(list: "legacyNames",
              in: "Sources/NotchApp/Media/SpotifyWeb.swift",
              carries: shippedDirectories, current: bundleName,
              what: "support directory", loses: "the Spotify refresh token")
    }

    /// One migration list, sliced out of its own declaration and checked.
    static func check(list name: String, in path: String,
                      carries expected: [String], current: String,
                      what: String, loses: String) {
        guard let code = try? String(contentsOfFile: path, encoding: .utf8) else {
            require(false, "cannot read \(path) — run this from the repo root")
            return
        }
        // Located by declaration then brackets, so a reformat moves the list
        // without turning a failure into a no-op.
        guard let decl = code.range(of: "let \(name)"),
              let open = code.range(of: "[", range: decl.upperBound..<code.endIndex),
              let close = code.range(of: "]", range: open.upperBound..<code.endIndex) else {
            require(false, "cannot find \(name) in \(path)")
            return
        }
        let listed = String(code[open.upperBound..<close.lowerBound])

        for old in expected {
            require(listed.contains("\"\(old)\""),
                    "\(old) is a \(what) this app shipped under and \(name) no "
                    + "longer names it, so anyone upgrading from it loses \(loses)")
        }
        require(!listed.contains("\"\(current)\""),
                "\(name) names the CURRENT \(what) \(current), which reads the "
                + "domain it is already writing to — a no-op that still looks "
                + "like a migration, and hides a name that is genuinely missing")
    }

    static func capturedGroups(_ pattern: String, in text: String) -> [String] {
        guard let re = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return re.matches(in: text, range: range).compactMap {
            Range($0.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    /// The heart and the title row sit just under the band. A hosting view is flipped,
    /// and a region written bottom-up hung the shell from the window's bottom edge: the
    /// heart took no clicks, and a strip under the panel swallowed clicks meant for the
    /// window beneath. Hit-tested on a real hosting view, since only AppKit knows which
    /// way the view is flipped.
    @MainActor
    static func theOpenPanelTakesClicksFromItsTopEdge() {
        let window = CGSize(width: 500, height: 244)
        let shell = CGSize(width: 372, height: 160)
        let view = NotchHostingView(rootView: Color.black.frame(width: window.width,
                                                                height: window.height))
        view.shellSize = { shell }
        // Installed as the app installs it, so `hitTest` receives points in the window's
        // bottom-up coordinates. Never ordered on screen.
        let host = NSWindow(contentRect: NSRect(origin: .zero, size: window),
                            styleMask: .borderless, backing: .buffered, defer: true)
        host.contentView = view
        view.layoutSubtreeIfNeeded()
        func hits(_ fromTop: CGFloat) -> Bool {
            view.hitTest(NSPoint(x: window.width / 2 + 54, y: window.height - fromTop)) != nil
        }
        require(hits(74), "the heart's row, 74 pt from the top, takes no clicks")
        require(hits(shell.height - 8), "the transport row near the shell's bottom takes no clicks")
        require(!hits(shell.height + 30), "the empty window under the open panel swallows clicks")
    }

    /// A controller on whatever display this Mac has. Which display does not
    /// matter: the metrics measured at init feed geometry, which is
    /// `chromecheck`'s subject.
    @MainActor
    static func controller() -> NotchController {
        guard let screen = NSScreen.main else {
            print("controllercheck: no display, so nothing here actually ran")
            exit(1)
        }
        return NotchController(screen: screen)
    }

    static func require(_ ok: Bool, _ message: @autoclosure () -> String) {
        if !ok { print("controllercheck: \(message())"); exit(1) }
    }
}
