import AppKit
import SwiftUI

// Rendering fixtures, deliberately excluding the app, settings, players, audio
// and provider implementations. No observers, timers, commands or persistence.
enum MusicSource {
    case spotify, music
    var displayName: String { self == .spotify ? "Spotify" : "Music" }
}

final class MediaManager {
    var title = "Northern Lights"
    var artist = "Aria, Beck & Cleo"
    var artists = ArtistCredit.fallback("Aria, Beck & Cleo", source: .music)
    var artistLine: String { ArtistCredit.line(artists) }
    var trackToken = 1
    var hasTrack = true
    var isPlaying = false
    var duration: Double = 240
    var position: Double = 115
    var skipTrace: Double?
    var artwork: NSImage?
    var palette = ArtworkPalette.fallback
    var source: MusicSource? = .music
    var shareURL: URL? = nil
    var liked: Bool? = false
    var shuffling: Bool? = false
    var repeating: Bool? = false
    var shuffleBlocked = false
    var repeatBlocked = false
    var smoothPosition: Double { position }
    var smoothProgress: Double { duration > 0 ? min(1, max(0, position / duration)) : 0 }
    func seek(toFraction: Double) {}
    func previous() {}
    func next() {}
    func playPause() {}
    func toggleLike() {}
    func toggleShuffle() {}
    func toggleRepeat() {}
    func openInPlayer() {}
    func openArtist(_ credit: ArtistCredit) {}
}

final class NotchController {
    enum Notification: Equatable {
        case none, didChangeVolume, didChangeBrightness
        var isSome: Bool { self != .none }
    }
    enum LiveActivity: Equatable {
        case none, isPlaying
        var isSome: Bool { self != .none }
    }
    var isVisible = true
    var isMouseInside = false
    var isExpanded = false
    var hasMedia = true
    var notification: Notification = .none
    var liveActivity: LiveActivity = .isPlaying
    var hudProgress: Double = 0
    var hudIsMuted = false
    var swipeLean: SwipeRecogniser.Lean?
    var notchSize = CGSize(width: 185, height: 32)
    var menuBarHeight: CGFloat = 33
    var style: NotchShape.Style = .notch
    var cutoutCornerRadius: CGFloat = 9
    var currentSize: CGSize {
        isExpanded ? CGSize(width: ChromeRules.panelWidth,
                            height: notchSize.height + ChromeRules.expandedBody)
        : ChromeRules.retractedSize(collapsed: notchSize, band: menuBarHeight,
                                    hasContent: liveActivity.isSome || notification.isSome)
    }
    var topCornerRadius: CGFloat { isExpanded ? 0 : 9 }
    var bottomCornerRadius: CGFloat { isExpanded ? 24 : cutoutCornerRadius }
}

final class FerrofluidSim {
    struct Site {
        let rim: Double
        let band: Int
        let fan: Double
        var height: Double
        var field: Double
        var isUp: Bool
    }
    static let siteCount = 17
    var sites: [Site] = (0..<siteCount).map { i in
        Site(rim: Double(i) / Double(siteCount - 1), band: i % 12,
             fan: Double((i * 7) % 13) / 13 * 2 - 1,
             height: Double(i % 5) / 4, field: 0.7, isUp: true)
    }
    var isSettled = true
    var hasSound = false
    var swell: Double = 0.7
    var raised: Double = 0.2
    var impact: Double = 0
    var inkOpen: Double = 1
    var pointerRim: Double = 0.5
    var pointerPull: Double = 0
    var flowPhase: Double = 0
    var brightness: Double = 0.7
    static func glowAlpha(impact: Double, openness: Double) -> Double { 0 }
    func setPointer(rim: Double?, strength: Double = 1) {}
    func surge(_ strength: Double, direction: Double = 0) {}
}
