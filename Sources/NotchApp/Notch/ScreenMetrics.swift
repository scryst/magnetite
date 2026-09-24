import AppKit

/// Physical notch measurement.
///
/// `safeAreaInsets.top` and the two `auxiliaryTop*Area` rects are the only public
/// description of the cutout, and they disagree across hardware and OS versions —
/// which is exactly why the real app ships user-adjustable offsets. We do too.
@MainActor
enum ScreenMetrics {

    /// The cutout rect in the screen's own coordinate space, or `nil` when the
    /// display has no notch.
    static func notchRect(for screen: NSScreen) -> CGRect? {
        guard let left = screen.auxiliaryTopLeftArea,
              let right = screen.auxiliaryTopRightArea,
              screen.safeAreaInsets.top > 0
        else { return nil }

        let width = right.minX - left.maxX
        guard width > 1 else { return nil }

        return CGRect(x: left.maxX,
                      y: screen.frame.maxY - screen.safeAreaInsets.top,
                      width: width,
                      height: screen.safeAreaInsets.top)
    }

    /// Collapsed size we should draw at, honouring the user's nudge.
    ///
    /// Displays with no physical notch get a pill sized to look deliberate rather
    /// than a fake cutout pretending to be hardware.
    static func collapsedSize(for screen: NSScreen, settings: Settings) -> CGSize {
        let base: CGSize
        if let notch = notchRect(for: screen) {
            base = notch.size
        } else {
            base = CGSize(width: 190, height: 32)
        }
        return CGSize(width: max(60, base.width + settings.notchAdjustedWidth),
                      height: max(20, base.height + settings.notchAdjustedHeight))
    }

    static func style(for screen: NSScreen, settings: Settings) -> NotchShape.Style {
        if settings.forceSimulatedNotch { return .pill }
        return notchRect(for: screen) == nil ? .pill : .notch
    }


    static func displayUUID(for screen: NSScreen) -> String {
        guard let number = screen.deviceDescription[.init("NSScreenNumber")] as? NSNumber
        else { return screen.localizedName }
        let id = CGDirectDisplayID(number.uint32Value)
        guard let uuid = CGDisplayCreateUUIDFromDisplayID(id)?.takeRetainedValue()
        else { return "display-\(id)" }
        return CFUUIDCreateString(nil, uuid) as String
    }

    static func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
        guard let number = screen.deviceDescription[.init("NSScreenNumber")] as? NSNumber
        else { return nil }
        return CGDirectDisplayID(number.uint32Value)
    }
}
