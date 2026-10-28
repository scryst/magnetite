import Foundation
import Observation

/// `UserDefaults`-backed preference, stored under a fixed key with a fallback.
@propertyWrapper
struct Stored<Value> {
    let key: String
    let fallback: Value
    private let get: (String) -> Value?
    private let set: (String, Value) -> Void

    var wrappedValue: Value {
        get { get(key) ?? fallback }
        nonmutating set { set(key, newValue) }
    }

    init(_ key: String, _ fallback: Value,
         get: @escaping (String) -> Value?,
         set: @escaping (String, Value) -> Void) {
        self.key = key
        self.fallback = fallback
        self.get = get
        self.set = set
    }
}

extension Stored where Value == Bool {
    init(_ key: String, _ fallback: Value) {
        self.init(key, fallback,
                  get: { UserDefaults.standard.object(forKey: $0) as? Bool },
                  set: { UserDefaults.standard.set($1, forKey: $0) })
    }
}

extension Stored where Value == Double {
    init(_ key: String, _ fallback: Value) {
        self.init(key, fallback,
                  get: { UserDefaults.standard.object(forKey: $0) as? Double },
                  set: { UserDefaults.standard.set($1, forKey: $0) })
    }
}

extension Stored where Value == String {
    init(_ key: String, _ fallback: Value) {
        self.init(key, fallback,
                  get: { UserDefaults.standard.string(forKey: $0) },
                  set: { UserDefaults.standard.set($1, forKey: $0) })
    }
}

@MainActor
@Observable
final class Settings {
    static let shared = Settings()

    private init() { Self.adoptPreferencesFromPreviousBundleID() }

    /// Every key this app stores, so the migration moves only these and not the keys
    /// frameworks write into the same domain.
    private static let keys = [
        "forceSimulatedNotch", "notchAdjustedWidth", "notchAdjustedHeight",
        "notchAdjustedRadius", "hideFromScreenCapture", "expandNotchOnHover",
        "hoverDuration", "peekDuration", "enableNowPlaying", "enableGestures",
        "enableVolume", "enableBrightness", "musicApp", "spotifyClientID", "showLyrics",
    ]

    /// Every bundle identifier this app has shipped under, newest first.
    ///
    /// A user may be arriving from either old identifier, so neither can be dropped.
    /// Order matters: someone who ran both has their later values in the newer domain,
    /// and the older one is only a fallback for keys that never moved.
    private static let legacyDomains = ["com.laks.ferro", "com.laks.NotchApp"]

    /// Copies preferences over from the bundle identifiers used before the rename.
    ///
    /// `UserDefaults.standard` is keyed by `CFBundleIdentifier`, so renaming the bundle
    /// abandons the whole domain. `spotifyClientID` must move with the refresh token
    /// (see `TokenStore`): a token without the client ID that issued it cannot be
    /// refreshed, and the app would report itself connected while every request fails
    /// with `invalid_client`.
    ///
    /// Runs once, guarded by its own marker rather than by emptiness, so a user who
    /// turned everything off is not given the old values back.
    private static func adoptPreferencesFromPreviousBundleID() {
        let now = UserDefaults.standard
        guard !now.bool(forKey: "didAdoptLegacyPreferences") else { return }

        // The `where` clause is re-evaluated per domain, so the first domain that answers
        // for a key wins and an older one cannot overwrite it.
        for domain in legacyDomains {
            guard let old = UserDefaults(suiteName: domain) else { continue }
            for key in keys where now.object(forKey: key) == nil {
                guard let value = old.object(forKey: key) else { continue }
                now.set(value, forKey: key)
            }
        }
        // Marked last: a crash mid-copy repeats the copy, which only fills unset keys.
        now.set(true, forKey: "didAdoptLegacyPreferences")
    }

    // Appearance
    @ObservationIgnored @Stored("forceSimulatedNotch", false) private var _forceSimulatedNotch: Bool
    @ObservationIgnored @Stored("notchAdjustedWidth", 0) private var _notchAdjustedWidth: Double
    @ObservationIgnored @Stored("notchAdjustedHeight", 0) private var _notchAdjustedHeight: Double
    @ObservationIgnored @Stored("notchAdjustedRadius", 0) private var _notchAdjustedRadius: Double
    @ObservationIgnored @Stored("hideFromScreenCapture", true) private var _hideFromScreenCapture: Bool

    // Behaviour
    @ObservationIgnored @Stored("expandNotchOnHover", true) private var _expandNotchOnHover: Bool
    @ObservationIgnored @Stored("hoverDuration", 0.18) private var _hoverDuration: Double
    // Key names are kept from earlier releases so existing preferences carry over.
    @ObservationIgnored @Stored("peekDuration", 2.2) private var _hudDuration: Double

    // Features
    @ObservationIgnored @Stored("enableNowPlaying", true) private var _showsMiniPlayer: Bool
    @ObservationIgnored @Stored("enableGestures", true) private var _enableGestures: Bool
    @ObservationIgnored @Stored("enableVolume", true) private var _enableVolume: Bool
    @ObservationIgnored @Stored("enableBrightness", true) private var _enableBrightness: Bool
    @ObservationIgnored @Stored("musicApp", "automatic") private var _musicApp: String
    @ObservationIgnored @Stored("showLyrics", true) private var _showsLyrics: Bool
    /// Spotify Web API client ID from a personal development-mode app. Not a secret
    /// (PKCE has none). The refresh token it earns lives in `TokenStore`'s 0600 file,
    /// which documents why it is not in the Keychain.
    @ObservationIgnored @Stored("spotifyClientID", "") private var _spotifyClientID: String

    // Observable facades: a write goes through `withMutation` so views refresh.
    var forceSimulatedNotch: Bool {
        get { access(keyPath: \.forceSimulatedNotch); return _forceSimulatedNotch }
        set { withMutation(keyPath: \.forceSimulatedNotch) { _forceSimulatedNotch = newValue } }
    }
    var notchAdjustedWidth: Double {
        get { access(keyPath: \.notchAdjustedWidth); return _notchAdjustedWidth }
        set { withMutation(keyPath: \.notchAdjustedWidth) { _notchAdjustedWidth = newValue } }
    }
    var notchAdjustedHeight: Double {
        get { access(keyPath: \.notchAdjustedHeight); return _notchAdjustedHeight }
        set { withMutation(keyPath: \.notchAdjustedHeight) { _notchAdjustedHeight = newValue } }
    }
    /// Nudge for the collapsed shell's bottom corners. The cutout's corner radius is not
    /// reported anywhere, so it is an estimate that has to be adjustable.
    var notchAdjustedRadius: Double {
        get { access(keyPath: \.notchAdjustedRadius); return _notchAdjustedRadius }
        set { withMutation(keyPath: \.notchAdjustedRadius) { _notchAdjustedRadius = newValue } }
    }
    var hideFromScreenCapture: Bool {
        get { access(keyPath: \.hideFromScreenCapture); return _hideFromScreenCapture }
        set { withMutation(keyPath: \.hideFromScreenCapture) { _hideFromScreenCapture = newValue } }
    }
    var expandNotchOnHover: Bool {
        get { access(keyPath: \.expandNotchOnHover); return _expandNotchOnHover }
        set { withMutation(keyPath: \.expandNotchOnHover) { _expandNotchOnHover = newValue } }
    }
    /// Both feed `Duration.seconds`, which traps on values it cannot hold (a stray
    /// `defaults write` of 1e300 or nan), so reads are clamped by `sane`.
    var hoverDuration: Double {
        get { access(keyPath: \.hoverDuration); return Self.sane(_hoverDuration, or: 0.18) }
        set { withMutation(keyPath: \.hoverDuration) { _hoverDuration = newValue } }
    }
    /// How long a volume or brightness HUD stays up.
    var hudDuration: Double {
        get { access(keyPath: \.hudDuration); return Self.sane(_hudDuration, or: 2.2) }
        set { withMutation(keyPath: \.hudDuration) { _hudDuration = newValue } }
    }
    private static func sane(_ seconds: Double, or fallback: Double) -> Double {
        seconds.isFinite ? min(max(seconds, 0), 10) : fallback
    }
    /// Two-finger swipes over the notch: horizontal skips, vertical play/pause.
    var enableGestures: Bool {
        get { access(keyPath: \.enableGestures); return _enableGestures }
        set { withMutation(keyPath: \.enableGestures) { _enableGestures = newValue } }
    }

    /// Mini player: while closed, the notch widens to show the cover, elapsed time and
    /// progress line. Independent of Open on Hover.
    var showsMiniPlayer: Bool {
        get { access(keyPath: \.showsMiniPlayer); return _showsMiniPlayer }
        set { withMutation(keyPath: \.showsMiniPlayer) { _showsMiniPlayer = newValue } }
    }
    /// Time-synced lyrics under the open player, for songs LRCLIB has them for.
    var showsLyrics: Bool {
        get { access(keyPath: \.showsLyrics); return _showsLyrics }
        set { withMutation(keyPath: \.showsLyrics) { _showsLyrics = newValue } }
    }
    var enableVolume: Bool {
        get { access(keyPath: \.enableVolume); return _enableVolume }
        set { withMutation(keyPath: \.enableVolume) { _enableVolume = newValue } }
    }
    var enableBrightness: Bool {
        get { access(keyPath: \.enableBrightness); return _enableBrightness }
        set { withMutation(keyPath: \.enableBrightness) { _enableBrightness = newValue } }
    }
    var spotifyClientID: String {
        get { access(keyPath: \.spotifyClientID); return _spotifyClientID }
        set { withMutation(keyPath: \.spotifyClientID) { _spotifyClientID = newValue } }
    }
    /// `automatic` | `spotify` | `music`
    var musicApp: String {
        get { access(keyPath: \.musicApp); return _musicApp }
        set { withMutation(keyPath: \.musicApp) { _musicApp = newValue } }
    }
}
