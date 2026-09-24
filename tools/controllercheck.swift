import AppKit
import Foundation

/// Headless checks on the per-display notch state machine.
///
/// `NotchController` is the one piece of the app that is pure state — no
/// drawing, no events, no network — and it went uncovered anyway, on the
/// assumption that anything importing AppKit needs a running app to drive. It
/// does not: the class only wants an `NSScreen` to measure once at init, and
/// every rule below is about what the state machine does afterwards, which no
/// display can change. The defect that started this suite is the first check
/// here, and it reproduced in eight lines.
///
/// The one environmental need is that a screen exists at all. That is asserted
/// rather than guarded around, because a suite that quietly passes when it could
/// not run is worse than one that fails: this repo has already shipped a
/// vacuous assertion once.
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
        thePeekTurnsOnAndOff()
        everyStoredSettingIsCarriedAcrossTheRename()
        theURLSchemeTheAppAnswersIsTheOneItRegistered()
        everyNameTheAppHasShippedUnderIsStillMigrated()
        print("controllercheck: all checks passed")
    }

    /// A notch that hides under the pointer does not still think it is hovered.
    ///
    /// Hiding does not move the mouse, so nothing reports an exit — the notch
    /// simply stops being anywhere. Left believing the pointer is inside, the
    /// controller never sees the false-to-true edge that `handleMouseMoved`
    /// turns into `mouseEntered`, so hover never re-arms: a pointer parked over
    /// the notch through a fullscreen video found it deaf afterwards, and only
    /// leaving the region entirely and coming back woke it up.
    ///
    /// Asserted on the controller rather than by re-running the coordinator's
    /// edge rule here, which would only prove that a copy of that rule agrees
    /// with itself. What the coordinator needs from this class is exactly the
    /// line below: after the notch has been away, it must not claim the pointer
    /// is already inside.
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
    /// nothing else stops them pinning an invisible panel open on top of
    /// someone's fullscreen video.
    @MainActor
    static func aHiddenNotchCannotBeOpened() {
        let notch = controller()
        notch.setVisible(false)

        notch.expand(byHover: false, pinned: true)
        require(!notch.isExpanded, "a hidden notch was expanded by a direct call")

        notch.toggle()
        require(!notch.isExpanded, "a hidden notch was expanded by the menu toggle")
    }

    /// Whatever is on screen goes away with the notch — including a panel that
    /// was pinned open, which is the case that has no other way out: a pin
    /// deliberately survives the pointer leaving.
    @MainActor
    static func hidingClosesWhatIsOpen() {
        let notch = controller()
        notch.toggle()
        require(notch.isExpanded, "the menu toggle did not open the panel")

        notch.setVisible(false)
        require(!notch.isExpanded, "a pinned panel outlived the notch it lives in")
    }

    /// The fluid re-reads the panel's geometry on this callback, so a call that
    /// reports a move nothing made is work with nothing behind it.
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

    /// A toggle that does not stick is not a toggle.
    ///
    /// The pointer is at the menu when the command fires — i.e. outside the
    /// notch — so without the pin `mouseExited` scheduled a collapse behind it
    /// and the panel shut on its own. The pin is also what has to be given up
    /// on the way closed, or the next hover-opened panel inherits it and stays
    /// up after the pointer leaves.
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

    /// A volume or brightness HUD is a retracted-state thing. Presented while
    /// the player is open it would be drawn behind the panel, where it dwells
    /// unseen and then expires — and on the way it overwrites the HUD state the
    /// next real peek reads.
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

    /// The HUD's progress drives a bar that is drawn to its own width. A value
    /// past the ends does not clip, it overhangs.
    @MainActor
    static func theHudNeverReportsMoreThanFull() {
        let notch = controller()
        notch.present(.didChangeVolume, progress: 1.8)
        require(notch.hudProgress == 1, "a HUD reported \(notch.hudProgress) of a full bar")

        notch.present(.didChangeBrightness, progress: -0.5)
        require(notch.hudProgress == 0, "a HUD reported \(notch.hudProgress) of a full bar")
    }

    /// The peek is the retracted player's entire content, so both edges of it
    /// have to actually land.
    ///
    /// This began as a check that the guard in `showNowPlaying` suppresses the
    /// redundant write `syncLiveActivity` makes on every poll. There is no such
    /// thing to observe: on Swift 6.4 `@Observable` compares before it notifies
    /// when the property's type is `Equatable`, so a guarded write and an
    /// unguarded one are indistinguishable to anything downstream — a mutant
    /// removing the guard survived, which is how that surfaced. See
    /// `showNowPlaying`, whose comment recorded the old behaviour as current.
    @MainActor
    static func thePeekTurnsOnAndOff() {
        let notch = controller()

        notch.showNowPlaying()
        require(notch.liveActivity == .isPlaying, "the peek never turned on")

        notch.clearLiveActivity()
        require(notch.liveActivity == .none, "the peek never turned off")
    }

    /// The preference migration's key list matches the preferences that exist.
    ///
    /// `Settings.adoptPreferencesFromPreviousBundleID` names its keys in a
    /// literal, because copying the whole old domain would drag in everything
    /// AppKit writes there too. A literal list beside the declarations it is
    /// supposed to mirror is a list that drifts: add a `@Stored` next year,
    /// forget the array, and that one setting is silently dropped by a
    /// migration that appears to have run fine.
    ///
    /// The list is sliced out before matching, on purpose. Asking whether the
    /// file "contains" a key is answered by the `@Stored` declaration itself,
    /// so a check written that way passes with the array empty — this repo has
    /// already shipped one lint that satisfied itself.
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
        // a reformat moves the list without silently turning this check into
        // "cannot find" — which reads like a failure but tests nothing.
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

    /// The scheme the app answers to is the scheme it registered.
    ///
    /// These are two independent strings — `CFBundleURLSchemes` in Info.plist,
    /// and the literal `application(_:open:)` compares `url.scheme` against —
    /// and nothing but this makes them agree. Rename the product, update one,
    /// and the URL scheme goes quietly dead: LaunchServices still routes the
    /// URL to the app, the app looks at it, does not recognise the scheme, and
    /// drops it. No error anywhere, and every scripted verb stops working.
    ///
    /// Worth having beyond a rename: the scheme is how the panel is driven from
    /// a shell, which is the only sane way to reach a window that otherwise
    /// only appears on hover.
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
        // The literal in the comparison, not the file's vocabulary: the doc
        // comment above it spells the scheme too, so asking whether the file
        // "contains" it is answered by prose and would pass with the actual
        // test still naming the old one.
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

    /// Every bundle identifier and support directory the app has shipped under
    /// is still named by a migration.
    ///
    /// Preferences are keyed by `CFBundleIdentifier` and the Spotify refresh
    /// token lives in a directory named for the app, so each rename abandons
    /// both unless the old name is carried forward. The app has shipped under
    /// two already; a third rename that forgets to append signs everyone out of
    /// their library and resets their settings, and the only symptom is a heart
    /// that stopped working.
    ///
    /// The current name must NOT appear in either list. A migration that reads
    /// its own domain is a no-op that still looks like a migration, which is
    /// exactly how a missing entry hides.
    static func everyNameTheAppHasShippedUnderIsStillMigrated() {
        guard let data = FileManager.default.contents(atPath: "Resources/Info.plist"),
              let plist = (try? PropertyListSerialization.propertyList(
                            from: data, format: nil)) as? [String: Any],
              let bundleID = plist["CFBundleIdentifier"] as? String,
              let bundleName = plist["CFBundleName"] as? String else {
            require(false, "cannot read the identity out of Resources/Info.plist")
            return
        }

        // Written down here on purpose. The lists in the source say what is
        // migrated; only a second, independent record says what SHOULD be, and
        // a rename that edits the source list is not evidence about itself.
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
        // without silently turning this into "cannot find".
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

    /// A controller on whatever display this Mac has.
    ///
    /// Which display it is does not matter to anything below — the metrics it
    /// measures at init feed geometry, and geometry is `chromecheck`'s subject.
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
