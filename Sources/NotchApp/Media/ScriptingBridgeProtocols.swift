import AppKit
import ScriptingBridge

/// Four-char player states. Spotify and Music happen to use the same codes.
enum PlayerState {
    static let stopped: Int = 0x6b50_5353   // 'kPSS'
    static let playing: Int = 0x6b50_5350   // 'kPSP'
    static let paused:  Int = 0x6b50_5370   // 'kPSp'
}

/// One protocol for both players rather than one per app.
///
/// ScriptingBridge dispatches on ObjC selectors, so two protocols declaring
/// `currentTrack` with different return types cannot both be conformed to by
/// `SBApplication`. Every member is `@objc optional`, so each app simply answers
/// the subset it implements and returns `nil` for the rest.
@objc protocol MediaTrack {
    @objc optional var name: String { get }
    @objc optional var artist: String { get }
    @objc optional var album: String { get }
    @objc optional var artworkUrl: String { get }     // Spotify
    @objc optional func artworks() -> SBElementArray  // Music
    /// Music only: select this track in the app's own window. Spotify has no
    /// equivalent — it is addressed by URL instead.
    @objc optional func reveal()
    // `duration` is deliberately absent: Spotify returns Int milliseconds and
    // Music returns Double seconds under the same selector, which no single
    // declaration can express. It's read through KVC and normalised per source.
    // `id` is absent for the same reason: Spotify's is its `spotify:track:` URI
    // and Music's an integer, which a `String` declaration retained as an object
    // pointer — 0.1.1 crashed on the first Music track it read. See
    // `MediaBridge.trackKey`; tools/bridgecheck.py holds every member here to
    // both dictionaries.
}

@objc protocol MediaArtwork {
    @objc optional var data: NSImage { get }
    @objc optional var rawData: Data { get }
}

@objc protocol MediaPlayerApp {
    @objc optional var currentTrack: MediaTrack { get }
    @objc optional var playerState: Int { get }
    @objc optional var playerPosition: Double { get }
    @objc optional func setPlayerPosition(_ position: Double)
    @objc optional func playpause()
    @objc optional func nextTrack()
    @objc optional func previousTrack()   // Spotify
    @objc optional func backTrack()       // Music
}

// Declaring these conformances is what makes `as?` succeed. Without them the
// cast silently returns nil and the whole media pipeline goes dark.
extension SBApplication: MediaPlayerApp {}
extension SBObject: MediaTrack, MediaArtwork {}
