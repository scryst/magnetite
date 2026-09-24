import Foundation
import Observation

/// UserDefaults-backed preferences.
///
/// The real app uses the `Defaults` package for this; a small property wrapper
/// keeps the dependency count at zero without changing the shape of the code.
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

    /// Every key this app stores. Listed so the migration below can move them
    /// without dragging along the keys the frameworks write into the domain.
    private static let keys = [
        "forceSimulatedNotch", "notchAdjustedWidth", "notchAdjustedHeight",
        "notchAdjustedRadius", "hideFromScreenCapture", "expandNotchOnHover",
        "hoverDuration", "peekDuration", "enableNowPlaying", "enableGestures",
        "enableVolume", "enableBrightness", "musicApp", "spotifyClientID",
    ]

    /// Every bundle identifier this app has shipped under, newest first.
    ///
    /// Spelled the old way on purpose: a migration has to name the old thing.
    /// There are two now — `com.laks.NotchApp`, then `com.laks.ferro` — and a
    /// user can be arriving from either, so neither may be dropped. Newest
    /// first because the order decides the winner: someone who ran both has
    /// their later values in the ferro domain, and the older domain is only a
    /// fallback for keys that never moved.
    private static let legacyDomains = ["com.laks.ferro", "com.laks.NotchApp"]

    /// Carries the preferences over from the bundle identifiers this app used
    /// before it was called Magnetite.
    ///
    /// `UserDefaults.standard` is keyed by `CFBundleIdentifier`, so renaming
    /// the bundle abandons the whole domain. Most of what is lost is a toggle
    /// worth one click — but `spotifyClientID` is not. The refresh token moves
    /// itself (see `TokenStore`), and a token without the client ID that issued
    /// it cannot be refreshed: the app reports itself connected and every
    /// request fails with `invalid_client`. Moving one and not the other is
    /// worse than moving neither, because it fails silently instead of visibly.
    ///
    /// Runs once, keyed on its own marker rather than on emptiness — a user who
    /// deliberately turned everything off must not have the old values pushed
    /// back at them on the next launch.
    private static func adoptPreferencesFromPreviousBundleID() {
        let now = UserDefaults.standard
        guard !now.bool(forKey: "didAdoptLegacyPreferences") else { return }

        // `where now.object(forKey:) == nil` is re-evaluated per domain, so the
        // first domain that answers for a key wins and the older one cannot
        // overwrite it — which is what makes the newest-first order above mean
        // what it says.
        for domain in legacyDomains {
            guard let old = UserDefaults(suiteName: domain) else { continue }
            for key in keys where now.object(forKey: key) == nil {
                guard let value = old.object(forKey: key) else { continue }
                now.set(value, forKey: key)
            }
        }
        // Marked last. A crash mid-copy should cost a repeat, not the settings,
        // and repeating is free: the loop only fills keys that are still unset.
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
    @ObservationIgnored @Stored("peekDuration", 2.2) private var _peekDuration: Double

    // Features
    @ObservationIgnored @Stored("enableNowPlaying", true) private var _enableNowPlaying: Bool
    @ObservationIgnored @Stored("enableGestures", true) private var _enableGestures: Bool
    @ObservationIgnored @Stored("enableVolume", true) private var _enableVolume: Bool
    @ObservationIgnored @Stored("enableBrightness", true) private var _enableBrightness: Bool
    @ObservationIgnored @Stored("musicApp", "automatic") private var _musicApp: String
    /// Spotify Web API client ID, from a personal app in development mode. Not a
    /// secret — PKCE exists so there is no secret to keep — and the refresh token
    /// it earns lives in TokenStore's 0600 file under Application
    /// Support/Magnetite, not here. TokenStore documents why it is not the
    /// Keychain.
    @ObservationIgnored @Stored("spotifyClientID", "") private var _spotifyClientID: String

    // Observable façades — writing bumps the registrar so views refresh.
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
    /// Nudge for the retracted shell's bottom corners.
    ///
    /// `safeAreaInsets` and the auxiliary areas describe a rectangle; the real
    /// cutout's corners are rounded and the radius is not reported anywhere, so
    /// it is a guess that has to be adjustable like the other two.
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
    /// Both feed `Duration.seconds`, which traps on a value it cannot hold — so
    /// a stray `defaults write` of 1e300 or nan crashed the app on first hover.
    /// Read back clamped to something a person could mean.
    var hoverDuration: Double {
        get { access(keyPath: \.hoverDuration); return Self.sane(_hoverDuration, or: 0.18) }
        set { withMutation(keyPath: \.hoverDuration) { _hoverDuration = newValue } }
    }
    var peekDuration: Double {
        get { access(keyPath: \.peekDuration); return Self.sane(_peekDuration, or: 2.2) }
        set { withMutation(keyPath: \.peekDuration) { _peekDuration = newValue } }
    }
    private static func sane(_ seconds: Double, or fallback: Double) -> Double {
        seconds.isFinite ? min(max(seconds, 0), 10) : fallback
    }
    /// Two-finger swipes over the notch: horizontal skips, vertical play/pause.
    ///
    /// This property wore `enableNowPlaying`'s entire doc comment — about the
    /// retracted strip and about being independent of `expandNotchOnHover` —
    /// which described neither this setting nor anything it does.
    var enableGestures: Bool {
        get { access(keyPath: \.enableGestures); return _enableGestures }
        set { withMutation(keyPath: \.enableGestures) { _enableGestures = newValue } }
    }

    var enableNowPlaying: Bool {
        get { access(keyPath: \.enableNowPlaying); return _enableNowPlaying }
        set { withMutation(keyPath: \.enableNowPlaying) { _enableNowPlaying = newValue } }
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
