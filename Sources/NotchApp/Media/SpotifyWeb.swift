import AppKit
import CryptoKit

/// Liking a Spotify track, which the local player cannot do.
///
/// Spotify's scripting dictionary declares `starred` as `access="r"` and asking a
/// live player for it fails, so the state is unreadable as well as unwritable
/// over scripting. The Web API is the only route.
///
/// Uses the Authorization Code flow with PKCE, so there is no client secret to
/// store. Only the refresh token is persisted; see `TokenStore`.
///
/// A personal app in Spotify's development mode is the supported case: the April
/// 2025 restriction applies to extended quota access, and Spotify states that
/// development mode remains available for experimentation and personal use.
@MainActor
@Observable
final class SpotifyWeb {

    /// Each scope buys a control the panel shows: the library pair for the heart,
    /// playback state for shuffle and repeat, and `user-read-private` because
    /// `product` tells us whether those two can work before they are offered.
    private static let scopes = [
        "user-library-read", "user-library-modify",
        "user-read-private",
        "user-read-playback-state", "user-modify-playback-state",
    ].joined(separator: " ")
    private static let tokenAccount = "spotify-refresh-token"
    private static let requestTimeout: TimeInterval = 10

    /// Spotify's OAuth error code, said plainly for the menu.
    static func tokenFailureMessage(_ code: String?) -> String {
        switch code {
        case "invalid_client":
            return "Spotify didn't recognise that Client ID. Use Change Spotify Client ID…"
        case "invalid_grant":
            return "Spotify sign-in expired. Click to connect again."
        default:
            return "Spotify sign-in failed. Click to try again."
        }
    }

    /// `lastError` as a menu title: most messages already name Spotify.
    var lastErrorTitle: String? {
        lastError.map { $0.hasPrefix("Spotify") ? $0 : "Spotify: \($0)" }
    }

    /// The redirect port is fixed because the dashboard rejects the portless
    /// form.
    ///
    /// Spotify's documentation says a loopback literal may be registered without
    /// a port, but the create-app form refuses `http://127.0.0.1/callback` as
    /// "not secure" and accepts only an explicit port. `localhost` is rejected
    /// either way.
    static let callbackPort: UInt16 = 8888
    static let registeredRedirect = "http://127.0.0.1:8888/callback"

    private(set) var isConnected = false
    private(set) var lastError: String?

    private var accessToken: String?
    private var expiry = Date.distantPast

    var clientID: String { Settings.shared.spotifyClientID }

    /// Called once the stored token has been looked for. The answer arrives after
    /// launch, so dependents of `isConnected` must be told rather than have asked
    /// too early.
    var onConnect: (() -> Void)?

    init() {
        // Not awaited. Reading the stored token happens off the main thread; an
        // inline keychain read once parked the main thread in securityd behind
        // an access dialog and the app never finished launching.
        Task { await self.restore() }
    }

    private func restore() async {
        await TokenStore.discardLegacyKeychainItem()
        isConnected = await TokenStore.read(Self.tokenAccount) != nil
        log("connected: \(isConnected), client set: \(!clientID.isEmpty)")
        guard isConnected else { return }
        await loadAccount()
        onConnect?()
    }

    // MARK: Connecting

    /// Opens the consent page in the user's browser and waits for the redirect.
    ///
    /// The loopback listener is bound before the browser opens, so the port in
    /// the authorize URL is one we are already listening on.
    func connect() async {
        connectFlow &+= 1
        let flow = connectFlow
        lastError = nil
        guard !clientID.isEmpty else {
            lastError = "No client ID — set one from the menu first."
            FileHandle.standardError.write(Data("[spotify] \(lastError!)\n".utf8))
            return
        }
        FileHandle.standardError.write(Data("[spotify] connecting, client \(clientID.prefix(6))…\n".utf8))
        let verifier = Self.randomVerifier()
        let challenge = Self.challenge(for: verifier)

        do {
            // One consent flow at a time: a listener left by an abandoned
            // consent tab would otherwise hold the port and fail every retry
            // with EADDRINUSE.
            callback?.cancel()
            callback = nil
            let listener = try await Self.bindListener()
            callback = listener
            // Ties the redirect to this flow, so an unrelated local connection
            // is not mistaken for the browser's answer.
            let state = Self.randomVerifier()
            let redirect = Self.registeredRedirect
            var url = URLComponents(string: "https://accounts.spotify.com/authorize")!
            url.queryItems = [
                .init(name: "client_id", value: clientID),
                .init(name: "response_type", value: "code"),
                .init(name: "redirect_uri", value: redirect),
                .init(name: "code_challenge_method", value: "S256"),
                .init(name: "code_challenge", value: challenge),
                .init(name: "state", value: state),
                .init(name: "scope", value: Self.scopes),
            ]
            // Logged as well as opened: the default browser and profile may not
            // be one the user can see.
            FileHandle.standardError.write(Data("[spotify] authorize \(url.url!)\n".utf8))
            NSWorkspace.shared.open(url.url!)

            FileHandle.standardError.write(Data("[spotify] listening on \(listener.port)\n".utf8))
            // Clear only our own listener; a newer Connect may have replaced it.
            defer { if callback === listener { callback = nil } }
            let epoch = authEpoch
            let code = try await listener.waitForCode(state: state)
            try await exchange(code: code, verifier: verifier, redirect: redirect)
            // A Disconnect or newer Connect during consent owns the outcome.
            // `post` discards a reply for a dropped account without throwing, so
            // without this a disconnect mid-exchange would still end as
            // "connected" with no token stored.
            guard flow == connectFlow, epoch == authEpoch else { return }
            isConnected = true
            await loadAccount()
            // The track on screen was drawn while unconnected; its controls
            // appear only when asked again.
            onConnect?()
        } catch {
            // A superseded flow's "cancelled" is not news: the flow that
            // replaced it, or the Disconnect that ended it, speaks for the menu.
            guard flow == connectFlow else { return }
            lastError = error.localizedDescription
            isConnected = false
            FileHandle.standardError.write(Data("[spotify] failed: \(lastError!)\n".utf8))
        }
    }

    /// The consent flow currently listening, kept so a new connect or a
    /// disconnect can end it instead of leaking the port.
    private var callback: LoopbackCallback?
    /// Which Connect is current. Bumped by every Connect and by Disconnect, so
    /// an older flow finishing late knows it no longer speaks for the menu.
    private var connectFlow = 0

    /// Binds the callback port, riding out the short window in which a
    /// superseded listener has been told to stop but has not yet closed its
    /// socket. The worker owns the close (closing an fd under a thread still
    /// polling it invites fd reuse) and notices the cancel within one poll tick.
    private static func bindListener() async throws -> LoopbackCallback {
        var lastError: Error?
        for _ in 0..<12 {
            do { return try LoopbackCallback(port: callbackPort) }
            catch { lastError = error }
            try? await Task.sleep(for: .milliseconds(150))
        }
        throw lastError ?? NSError(domain: "SpotifyWeb", code: 2, userInfo: [
            NSLocalizedDescriptionKey: "port \(callbackPort): could not bind",
        ])
    }

    func disconnect() {
        // Everything in flight belongs to the account being dropped. A refresh
        // parked in `URLSession.data` would otherwise finish later and have
        // `post` write the rotated refresh token to disk after the delete below,
        // recreating the credential and silently signing back in on next launch.
        // URLSession's default timeout is 60 s, and a stalled network is exactly
        // when someone clicks Disconnect.
        //
        // Cancelling covers the parked call; the epoch covers a reply that has
        // already landed. The connect flow needs the epoch too, since its
        // `exchange` is the same `post`.
        authEpoch &+= 1
        connectFlow &+= 1
        refreshTask?.cancel()
        refreshTask = nil
        // A consent flow mid-flight belongs to the dropped account too.
        callback?.cancel()
        callback = nil
        Task { await TokenStore.delete(Self.tokenAccount) }
        accessToken = nil
        expiry = .distantPast
        isConnected = false
        // The user asked for this, so a stale complaint from the dropped account
        // should not outlive it in the menu.
        lastError = nil
    }

    /// Bumped whenever the stored account stops being the one in play. Anything
    /// that crossed an `await` before the bump must check it before writing.
    private var authEpoch = 0

    // MARK: Library

    /// The library is addressed by URI rather than by id and entity type.
    ///
    /// Spotify's February 2026 migration folded `/me/tracks`, `/me/albums` and
    /// the rest into `/me/library` and retired the per-type endpoints for apps in
    /// development mode. They answer 403 Forbidden with no message rather than
    /// 404, which looks like a missing scope.
    private static let libraryContains = "https://api.spotify.com/v1/me/library/contains"
    private static let library = "https://api.spotify.com/v1/me/library"

    /// Track credits, not the album's artists. Uses the existing account grant.
    func trackArtists(trackID: String) async -> [ArtistCredit]? {
        guard let id = Self.bareID(trackID), ArtistCredit.validSpotifyID(id),
              let (data, status) = await send("GET", "https://api.spotify.com/v1/tracks/\(id)"),
              status == 200 else { return nil }
        return Self.artists(from: data)
    }

    static func artists(from data: Data) -> [ArtistCredit]? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let rows = json["artists"] as? [[String: Any]], !rows.isEmpty else { return nil }
        let credits = rows.compactMap { row -> ArtistCredit? in
            guard let name = row["name"] as? String,
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            let id = row["id"] as? String
            return ArtistCredit(name: name, spotifyID: id.flatMap { ArtistCredit.validSpotifyID($0) ? $0 : nil })
        }
        return credits.isEmpty ? nil : credits
    }

    /// Whether the track is in Saved Songs, or nil if we cannot say.
    func isSaved(trackID: String) async -> Bool? {
        guard let uri = Self.trackURI(trackID) else { return nil }
        guard let (data, status) = await send("GET", Self.libraryContains, ["uris": uri]) else {
            return nil
        }
        guard status == 200, let flags = try? JSONDecoder().decode([Bool].self, from: data) else {
            log("isSaved: HTTP \(status) \(String(data: data, encoding: .utf8) ?? "")")
            return nil
        }
        return flags.first
    }

    @discardableResult
    func setSaved(_ saved: Bool, trackID: String) async -> Bool {
        guard let uri = Self.trackURI(trackID) else { return false }
        // `uris` is a query parameter here, not a body; a JSON body is rejected
        // with "Missing required field: uris".
        guard let (data, status) = await send(saved ? "PUT" : "DELETE", Self.library,
                                              ["uris": uri]) else { return false }
        if !(200...299).contains(status) {
            log("setSaved(\(saved)): HTTP \(status) \(String(data: data, encoding: .utf8) ?? "")")
        }
        return (200...299).contains(status)
    }

    // MARK: Playback modes

    /// Shuffle and repeat go over the Web API because the local player drops the
    /// writes: its dictionary declares `shuffling` and `repeating` settable, but
    /// the read-only `shuffling enabled` / `repeating enabled` beside them are
    /// false. The Web API needs a Premium account, which this records.
    private(set) var canControlPlayback = false

    /// Whether the account has ever answered. `canControlPlayback` alone cannot
    /// tell "not Premium" (settled) from "never found out" (worth asking again).
    private(set) var accountLoaded = false

    /// Reads the account once, to learn whether the mode controls can work before
    /// any is offered.
    func loadAccount() async {
        guard let (data, status) = await send("GET", "https://api.spotify.com/v1/me"),
              status == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        accountLoaded = true
        canControlPlayback = (json["product"] as? String) == "premium"
        log("account \(json["id"] as? String ?? "?"), product \(json["product"] as? String ?? "?")")
    }

    /// Asks again when the account never answered the first time.
    ///
    /// `loadAccount` runs only from `restore` and `connect` and returns silently
    /// on any failure. A single failure at launch (waking the Mac, a captive
    /// portal, a 429) would otherwise latch `canControlPlayback` false for the
    /// session and leave both mode controls absent with no explanation.
    ///
    /// Opening the panel is the retry rather than the poll loop, the same trade
    /// `MediaManager.beginPolling` makes for the heart. Guarded on
    /// `accountLoaded`, so a non-Premium account that answered is never asked
    /// twice.
    func refreshAccountIfUnknown() async {
        guard isConnected, !accountLoaded else { return }
        await loadAccount()
    }

    /// What the player is doing and what it will let us change.
    ///
    /// Spotify refuses a mode the current context disallows with "Restriction
    /// violated", and announces it in advance under `actions.disallows`. A
    /// control offered against that answer would do nothing.
    struct Playback {
        var shuffling = false
        var repeating = false
        var canShuffle = false
        var canRepeat = false
    }

    /// What the panel shows when the player did not answer.
    ///
    /// Pausing makes `/me/player` answer 204, so the modes arrive as nothing, and
    /// wiping them would remove both toggles every time the music stopped. The
    /// last answer is kept instead, with both writes marked refused. That is
    /// accurate: while paused they are refused, and Spotify lists
    /// `toggling_shuffle` in `disallows` even in the replies it does send.
    ///
    /// Zeroing the `can` flags is why this keeps a copy. `apply` recomputes
    /// `shuffleBlocked` from `canShuffle` on every poll, so a kept answer from a
    /// context that allowed shuffle would leave a bright button whose write is
    /// about to fail.
    static func modes(from fresh: Playback?, keeping previous: Playback?) -> Playback? {
        if let fresh { return fresh }
        guard var kept = previous else { return nil }
        kept.canShuffle = false
        kept.canRepeat = false
        return kept
    }

    /// Nil when there is no active device to ask about (204 rather than 200),
    /// which is not an error.
    func playbackModes() async -> Playback? {
        guard canControlPlayback else { return nil }
        // 204 is the case that actually occurs and means paused: Spotify drops
        // the desktop app off Connect when the music stops. See
        // `modes(from:keeping:)` for what the panel shows then. Each failure is
        // logged because a silent nil reads on the panel as a button that was
        // never built.
        guard let (data, status) = await send("GET", "https://api.spotify.com/v1/me/player")
        else { log("playback: no reply"); return nil }
        guard status == 200 else {
            log("playback: HTTP \(status)" + (status == 204 ? " — no active Connect device" : ""))
            return nil
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { log("playback: unreadable body"); return nil }
        let disallows = (json["actions"] as? [String: Any])?["disallows"] as? [String: Any] ?? [:]
        // Repeat is judged by `toggling_repeat_context` alone, the capability
        // `setMode` actually uses (it only sends `state=context` or `off`). When
        // a context cannot repeat, Spotify usually names the context key and
        // omits the track key; an absent key is not a refusal, so also testing
        // `toggling_repeat_track` would light a button whose every press fails.
        func allowed(_ key: String) -> Bool {
            (disallows[key] as? Bool) != true
        }
        let playback = Playback(
            shuffling: json["shuffle_state"] as? Bool ?? false,
            repeating: (json["repeat_state"] as? String ?? "off") != "off",
            canShuffle: allowed("toggling_shuffle"),
            canRepeat: allowed("toggling_repeat_context"))
        log("playback: shuffle \(playback.shuffling)"
            + (playback.canShuffle ? "" : " (blocked)")
            + ", repeat \(playback.repeating)"
            + (playback.canRepeat ? "" : " (blocked)")
            + ", context \((json["context"] as? [String: Any])?["type"] as? String ?? "none")"
            + ", disallows \(disallows.keys.sorted())"
            + ", device \(deviceDescription(json))")
        return playback
    }

    /// Repeat is three-state on Spotify and one glyph here, so it is set to
    /// `context` (repeat the album or playlist), which is what a single toggle
    /// means.
    @discardableResult
    func setMode(shuffling: Bool? = nil, repeating: Bool? = nil) async -> Bool {
        guard canControlPlayback else { return false }
        let call: (path: String, state: String)? =
            if let shuffling { ("shuffle", shuffling ? "true" : "false") }
            else if let repeating { ("repeat", repeating ? "context" : "off") }
            else { nil }
        guard let call,
              let (data, status) = await send(
                "PUT", "https://api.spotify.com/v1/me/player/\(call.path)", ["state": call.state])
        else { return false }
        if !(200...299).contains(status) {
            log("setMode \(call.path)=\(call.state): HTTP \(status) "
                + (String(data: data, encoding: .utf8) ?? ""))
        }
        return (200...299).contains(status)
    }

    // MARK: Requests

    /// Earliest moment the API may be asked anything again, set from a 429's
    /// Retry-After. Pushing through a rate limit only lengthens it.
    private var notBefore = Date.distantPast

    /// One authorized request. Returns nil only when there is no token, the
    /// connection failed, or a rate limit is still running; an HTTP error is
    /// returned, because the status is the most useful thing this API says.
    ///
    /// A 401 gets one retry through `token()`. The local expiry only guesses the
    /// server's view: a password change or sign-out-everywhere invalidates the
    /// token with up to an hour left locally. A refresh refused with
    /// invalid_grant already surfaces as revoked via `refreshFailed`.
    private func send(_ method: String, _ url: String,
                      _ query: [String: String] = [:],
                      retried: Bool = false) async -> (Data, Int)? {
        guard Date() >= notBefore else { return nil }
        guard let token = await token() else { return nil }
        var c = URLComponents(string: url)!
        if !query.isEmpty { c.queryItems = query.map { .init(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: c.url!)
        request.httpMethod = method
        // URLSession's 60 s default would leave a press hanging on a stalled
        // network.
        request.timeoutInterval = Self.requestTimeout
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            log("\(method) \(url): request failed")
            // Surfaced in the menu so a heart that fills then empties has a
            // visible reason.
            lastError = "Couldn't reach Spotify."
            return nil
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 {
            guard !retried else {
                // Refreshed and still refused; surface it where the
                // connected-but-failing menu line can render it.
                lastError = "Spotify refused the last request."
                return (data, status)
            }
            // Drop the cached token only if it is still the one that was
            // refused; a slow reply's 401 must not wipe a fresh refresh.
            if accessToken == token {
                accessToken = nil
                expiry = .distantPast
            }
            return await send(method, url, query, retried: true)
        }
        if status == 429 {
            let after = (response as? HTTPURLResponse)?
                .value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 5
            // Capped: one huge value would switch Spotify features off until the
            // next launch.
            notBefore = Date().addingTimeInterval(min(max(after, 1), 120))
            log("\(method) \(url): 429, backing off \(Int(after))s")
            lastError = "Spotify asked us to slow down. Try again shortly."
        } else if status == 403 {
            lastError = "Spotify didn't allow that for this account."
        }
        // A successful request ends any earlier complaint in the menu; otherwise
        // only Connect and Disconnect would clear it.
        if (200..<300).contains(status) { lastError = nil }
        return (data, status)
    }

    private func deviceDescription(_ json: [String: Any]) -> String {
        guard let device = json["device"] as? [String: Any] else { return "none" }
        let type = device["type"] as? String ?? "?"
        let restricted = device["is_restricted"] as? Bool ?? false
        return "\(type) restricted=\(restricted)"
    }

    private func log(_ message: String) {
        FileHandle.standardError.write(Data("[spotify] \(message)\n".utf8))
    }

    // MARK: Tokens

    /// One refresh at a time, however many callers want a token.
    ///
    /// Opening the panel asks about the track and the modes at nearly the same
    /// moment, and on a cold launch each finds the same expired token. Spotify
    /// rotates the refresh token, so concurrent refreshes would present one the
    /// first has already spent, and the last to finish would overwrite the good
    /// token, failing at some later launch with no trace of the cause.
    private var refreshTask: Task<String?, Never>?

    private func token() async -> String? {
        if let accessToken, expiry > Date().addingTimeInterval(30) { return accessToken }
        // Only the caller that started the refresh clears it, and no new one
        // starts while it is set, so this cannot drop somebody else's task.
        if let refreshTask {
            // Logged so the race being absorbed is visible.
            log("refresh already in flight — joined")
            return await refreshTask.value
        }
        let task = Task { [weak self] () -> String? in
            guard let self else { return nil }
            guard let refresh = await TokenStore.read(Self.tokenAccount) else { return nil }
            do {
                return try await self.refreshing(with: refresh)
            } catch is CancellationError {
                return nil
            } catch let cancelled as URLError where cancelled.code == .cancelled {
                // A cancelled refresh is not a refused one. `disconnect` cancels
                // on purpose, and `refreshFailed` would make the menu report a
                // network failure for a successful disconnect.
                return nil
            } catch {
                self.refreshFailed(error)
                return nil
            }
        }
        refreshTask = task
        let result = await task.value
        refreshTask = nil
        return result
    }

    /// Reacts to a refresh that came back refused.
    ///
    /// `isConnected` is set from the stored file merely existing, so without
    /// this a revoked app would look connected on every launch with no error and
    /// the Spotify half of the panel permanently dark.
    ///
    /// `invalid_grant` is terminal: the grant is gone, so the token is dropped
    /// and the connection reported as what it now is. Anything else (offline, a
    /// 500, a timeout) is left alone, because a transient failure must not
    /// discard a good token.
    private func refreshFailed(_ error: Error) {
        // The token endpoint's error bodies carry no credential; tokens appear
        // only in a 200, which does not reach here.
        let described = error.localizedDescription
        let revoked = described.contains("invalid_grant")
        log("refresh refused\(revoked ? " (invalid_grant)" : ""): \(described)")
        guard revoked else {
            lastError = "Spotify could not be reached."
            return
        }
        lastError = "Spotify access was revoked — connect again."
        accessToken = nil
        expiry = .distantPast
        // The menu renders `lastError` only when this is false.
        isConnected = false
        authEpoch &+= 1
        Task { await TokenStore.delete(Self.tokenAccount) }
    }

    private func exchange(code: String, verifier: String, redirect: String) async throws {
        try await post([
            "grant_type": "authorization_code",
            "code": code,
            "redirect_uri": redirect,
            "client_id": clientID,
            "code_verifier": verifier,
        ])
    }

    @discardableResult
    private func refreshing(with refresh: String) async throws -> String? {
        try await post([
            "grant_type": "refresh_token",
            "refresh_token": refresh,
            "client_id": clientID,
        ])
        return accessToken
    }

    private func post(_ fields: [String: String]) async throws {
        var request = URLRequest(url: URL(string: "https://accounts.spotify.com/api/token")!)
        request.httpMethod = "POST"
        request.timeoutInterval = Self.requestTimeout
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = fields
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)

        let epoch = authEpoch
        let (data, response) = try await URLSession.shared.data(for: request)
        // Disconnected while this was in flight. Return rather than throw: there
        // is no failure to report, the answer is about an account that is no
        // longer ours to write for.
        guard epoch == authEpoch else {
            log("token reply discarded — disconnected while it was in flight")
            return
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String
        else {
            // The menu shows the mapped message, not the raw reply body.
            let code = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            log("token request failed: \(String(data: data, encoding: .utf8) ?? "?")")
            throw NSError(domain: "SpotifyWeb", code: 1, userInfo: [
                NSLocalizedDescriptionKey: Self.tokenFailureMessage(code),
            ])
        }
        accessToken = access
        expiry = Date().addingTimeInterval((json["expires_in"] as? Double) ?? 3600)
        // Log what was granted, which is not always what was asked for; a 403
        // from the library looks the same either way.
        FileHandle.standardError.write(Data(
            "[spotify] token ok, scope: \(json["scope"] as? String ?? "none")\n".utf8))
        // Spotify only sometimes returns a new refresh token; keep the old one
        // when it does not.
        if let newRefresh = json["refresh_token"] as? String {
            await TokenStore.write(newRefresh, account: Self.tokenAccount)
            // The check above covers replies that landed after a disconnect; this
            // covers the write itself. The suspension into the store releases the
            // actor, so a disconnect can run in between and its delete lose the
            // race. Re-check and compensate rather than order two detached tasks.
            if epoch != authEpoch {
                log("token write voided — disconnected while it was landing")
                await TokenStore.delete(Self.tokenAccount)
            }
        }
    }

    // MARK: Helpers

    /// `spotify:track:ID` and bare IDs both arrive here; the API wants the bare
    /// one. Anything else, such as a synthesised title/artist key from a player
    /// with no id, is refused rather than sent.
    static func bareID(_ identity: String) -> String? {
        let prefix = "spotify:track:"
        if identity.hasPrefix(prefix) { return String(identity.dropFirst(prefix.count)) }
        let bare = identity.allSatisfy { $0.isLetter || $0.isNumber }
        return bare && identity.count == 22 ? identity : nil
    }

    /// The same identity as a URI, which is what the library endpoints take.
    static func trackURI(_ identity: String) -> String? {
        bareID(identity).map { "spotify:track:\($0)" }
    }

    private static func randomVerifier() -> String {
        var bytes = [UInt8](repeating: 0, count: 64)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64URL
    }

    private static func challenge(for verifier: String) -> String {
        Data(SHA256.hash(data: Data(verifier.utf8))).base64URL
    }
}

private extension Data {
    /// base64url, unpadded, as RFC 7636 requires.
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - The loopback listener

/// Waits for the browser to hit the redirect, pulls `code` out of the query,
/// and answers with a page that reports what happened.
///
/// A plain BSD socket rather than `NWListener`: Network.framework refused this
/// port with `POSIXErrorCode 22` and, without a state handler, did so silently.
///
/// - The wait has a deadline. A bare `accept()` would let an abandoned consent
///   tab park the thread and hold the port for the session.
/// - The wait loops with a `state` check, since the first connection on a
///   loopback port may not be the browser (a stray localhost fetch from a web
///   page, a scanner). Anything that is not this flow's redirect gets a 404 and
///   the wait continues.
/// - The reply is chosen after parsing, so a declined consent is not reported as
///   "Connected."
private final class LoopbackCallback: @unchecked Sendable {
    let port: UInt16
    private let fd: Int32
    private let lock = NSLock()
    private var cancelled = false

    init(port wanted: UInt16) throws {
        func fail(_ why: String) -> NSError {
            NSError(domain: "SpotifyWeb", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "port \(wanted): \(why)",
            ])
        }
        // A local until both members are set; Swift will not let a closure see a
        // partially initialised self.
        let sock = socket(AF_INET, SOCK_STREAM, 0)
        guard sock >= 0 else { throw fail("socket() failed") }
        var yes: Int32 = 1
        setsockopt(sock, SOL_SOCKET, SO_REUSEADDR, &yes, socklen_t(MemoryLayout<Int32>.size))

        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = wanted.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")

        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(sock, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0 else { close(sock); throw fail("bind: \(String(cString: strerror(errno)))") }
        guard listen(sock, 4) == 0 else { close(sock); throw fail("listen failed") }
        // Non-blocking, so the wait can poll against a deadline instead of
        // parking a thread in accept().
        let flags = fcntl(sock, F_GETFL, 0)
        _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)
        fd = sock
        port = wanted
    }

    /// Ends the wait from outside (a newer connect, or a disconnect). The worker
    /// notices within one poll tick and closes the socket itself, since closing
    /// an fd under a thread still polling it invites the number being reused.
    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    /// How long the user gets to finish the consent page. Spotify's authorization
    /// codes expire well within this; past it the flow is dead and holding the
    /// port only wedges the retry.
    private static let consentWindow: TimeInterval = 300

    func waitForCode(state: String) async throws -> String {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async { [self] in
                defer { close(fd) }
                let deadline = Date().addingTimeInterval(Self.consentWindow)
                while true {
                    if isCancelled {
                        continuation.resume(throwing: Self.error(
                            "The connect was cancelled."))
                        return
                    }
                    guard Date() < deadline else {
                        continuation.resume(throwing: Self.error(
                            "Authorization timed out — try Connect again."))
                        return
                    }
                    var waiting = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
                    guard poll(&waiting, 1, 500) > 0,
                          waiting.revents & Int16(POLLIN) != 0 else { continue }
                    let client = accept(fd, nil, nil)
                    guard client >= 0 else { continue }

                    let request = Self.readRequest(client)
                    switch Self.parse(request, expecting: state) {
                    case .code(let code):
                        Self.reply(client, status: "200 OK",
                                   body: "<b>Connected.</b> You can close this tab.")
                        close(client)
                        continuation.resume(returning: code)
                        return
                    case .declined:
                        Self.reply(client, status: "200 OK",
                                   body: "<b>Not connected.</b> Spotify says the request was "
                                       + "declined — you can close this tab and try again "
                                       + "from the menu.")
                        close(client)
                        continuation.resume(throwing: Self.error("Authorization was declined."))
                        return
                    case .failed:
                        Self.reply(client, status: "200 OK",
                                   body: "<b>Not connected.</b> No authorization code came "
                                       + "back — you can close this tab and try again from "
                                       + "the menu.")
                        close(client)
                        continuation.resume(throwing: Self.error("No authorization code came back."))
                        return
                    case .stray:
                        Self.reply(client, status: "404 Not Found", body: "Nothing here.")
                        close(client)
                        // Not the browser; keep waiting for it.
                    }
                }
            }
        }
    }

    private enum Callback {
        /// The redirect, state verified, code present.
        case code(String)
        /// The redirect, state verified, consent refused.
        case declined
        /// The redirect, state verified, but nothing usable in it.
        case failed
        /// Anything else: not this flow's redirect.
        case stray
    }

    private static func parse(_ request: String, expecting state: String) -> Callback {
        // "GET /callback?code=...&state=... HTTP/1.1"
        guard let line = request.split(separator: "\r\n").first,
              line.hasPrefix("GET "),
              let path = line.split(separator: " ").dropFirst().first,
              path.hasPrefix("/callback"),
              let parts = URLComponents(string: "http://127.0.0.1\(path)"),
              parts.queryItems?.first(where: { $0.name == "state" })?.value == state
        else { return .stray }
        if let code = parts.queryItems?.first(where: { $0.name == "code" })?.value {
            return .code(code)
        }
        let denied = parts.queryItems?.contains {
            $0.name == "error" && $0.value == "access_denied"
        } ?? false
        return denied ? .declined : .failed
    }

    /// Reads the request, looping until the header terminator or a small cap,
    /// since one read() can return before the request line has arrived. The
    /// accepted fd inherits non-blocking from the listener on BSD, so it is
    /// switched back to blocking with timeouts.
    ///
    /// Any local process can connect while the consent window is open, so this is
    /// a trust boundary. A peer that resets the connection would make the reply's
    /// write() raise SIGPIPE, whose default action kills the app, so SO_NOSIGPIPE
    /// turns it into an ignored EPIPE. A peer trickling a byte every second or
    /// two would reset a per-read timeout indefinitely, so the whole read also
    /// gets one absolute deadline.
    private static func readRequest(_ client: Int32) -> String {
        let flags = fcntl(client, F_GETFL, 0)
        _ = fcntl(client, F_SETFL, flags & ~O_NONBLOCK)
        var on: Int32 = 1
        _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &on,
                       socklen_t(MemoryLayout<Int32>.size))
        var patience = timeval(tv_sec: 2, tv_usec: 0)
        _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &patience,
                       socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &patience,
                       socklen_t(MemoryLayout<timeval>.size))
        let deadline = Date().addingTimeInterval(5)
        var collected = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while collected.count < 16384, Date() < deadline {
            let n = read(client, &buffer, buffer.count)
            guard n > 0 else { break }
            collected.append(contentsOf: buffer[0..<n])
            if String(decoding: collected, as: UTF8.self).contains("\r\n\r\n") { break }
        }
        return String(decoding: collected, as: UTF8.self)
    }

    private static func reply(_ client: Int32, status: String, body: String) {
        let page = "<html><body style=\"font:15px -apple-system;padding:3rem\">\(body)</body></html>"
        let out = "HTTP/1.1 \(status)\r\nContent-Type: text/html\r\n"
            + "Content-Length: \(page.utf8.count)\r\nConnection: close\r\n\r\n\(page)"
        _ = out.withCString { write(client, $0, strlen($0)) }
    }

    private static func error(_ message: String) -> NSError {
        NSError(domain: "SpotifyWeb", code: 3,
                userInfo: [NSLocalizedDescriptionKey: message])
    }
}

// MARK: - Token store

/// Where the refresh token lives, and why it is not the Keychain.
///
/// A keychain item is bound to the exact executable that wrote it. This app is
/// ad-hoc signed, so every rebuild is a different executable and macOS prompts
/// on the next launch, in a dialog that can open behind other windows, leaving
/// the Spotify half of the panel dark until someone answers it. A stable signing
/// identity would fix that, but none is available; an access policy naming no
/// application was tried and denies rather than opens.
///
/// So the token is a file, owner-read-only, in the app's own Application Support
/// directory. It is a refresh token scoped to one person's saved songs and
/// playback. On FileVault it is encrypted at rest like everything else; unlike a
/// keychain item another process running as the same user could read it, but
/// such a process could equally read this app's binary, its defaults and the
/// rest of the home directory.
///
/// If the app is ever signed with a stable identity, the Keychain becomes the
/// better home again.
enum TokenStore {

    private static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "Magnetite", directoryHint: .isDirectory)
    }

    /// Where the token lived under earlier names, newest first. They are still
    /// spelled the old way because a migration has to name the old thing to find
    /// it; nothing else in the app may use these strings. The token exists in
    /// only one place (whichever build last wrote it), so both are tried, or a
    /// user who skipped a release would be signed out of their library.
    private static let legacyNames = ["Ferro", "NotchApp"]

    private static func legacyDirectory(_ name: String) -> URL {
        URL.applicationSupportDirectory.appending(path: name, directoryHint: .isDirectory)
    }

    private static func file(_ account: String) -> URL {
        directory.appending(path: account, directoryHint: .notDirectory)
    }

    // Off the main thread: this is a credential store on a shared main actor,
    // and a blocking read has frozen the launch path before.
    static func read(_ account: String) async -> String? {
        await off { readNow(account) }
    }

    static func write(_ value: String, account: String) async {
        await off { writeNow(value, account: account) }
    }

    /// Deletion covers everything `read` consults. `readNow` falls back to the
    /// legacy directories, so a legacy file that survived its migration (a full
    /// disk mid-copy, a swallowed removeItem) would be re-adopted on the next
    /// launch and silently undo a Disconnect.
    static func delete(_ account: String) async {
        await off {
            let fm = FileManager.default
            try? fm.removeItem(at: file(account))
            for name in legacyNames {
                let dir = legacyDirectory(name)
                try? fm.removeItem(at: dir.appending(path: account,
                                                     directoryHint: .notDirectory))
                if (try? fm.contentsOfDirectory(atPath: dir.path))?.isEmpty == true {
                    try? fm.removeItem(at: dir)
                }
            }
        }
    }

    private static func off<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await Task.detached(priority: .userInitiated, operation: body).value
    }

    private static func readNow(_ account: String) -> String? {
        guard let data = try? Data(contentsOf: file(account)) else {
            return adoptLegacyToken(account)
        }
        let token = String(decoding: data, as: UTF8.self)
        return token.isEmpty ? nil : token
    }

    /// A token written under an old directory name is still the user's token.
    /// Reads it once, writes it forward, removes the original, and removes the
    /// old directory when nothing is left in it.
    ///
    /// The original is removed only after the forward copy has been read back
    /// and matches. `writeNow` reports failure to stderr and returns normally, so
    /// trusting it would turn a full disk into a deleted credential. On any doubt
    /// the old file stays, and the token is returned either way so the session
    /// continues.
    private static func adoptLegacyToken(_ account: String) -> String? {
        for name in legacyNames {
            let directory = legacyDirectory(name)
            let old = directory.appending(path: account, directoryHint: .notDirectory)
            guard let data = try? Data(contentsOf: old) else { continue }
            let token = String(decoding: data, as: UTF8.self)
            guard !token.isEmpty else { continue }

            writeNow(token, account: account)
            guard let carried = try? Data(contentsOf: file(account)), carried == data else {
                return token
            }

            let fm = FileManager.default
            try? fm.removeItem(at: old)
            if (try? fm.contentsOfDirectory(atPath: directory.path))?.isEmpty == true {
                try? fm.removeItem(at: directory)
            }
            return token
        }
        return nil
    }

    private static func writeNow(_ value: String, account: String) {
        let fm = FileManager.default
        do {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            // An existing directory keeps whatever mode it was made with.
            try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: directory.path)
            let url = file(account)
            // Created 0600 and then swapped in; writing first and chmodding
            // after would leave the token world-readable in between.
            let staging = directory.appendingPathComponent(".\(account).\(UUID().uuidString)")
            guard fm.createFile(atPath: staging.path, contents: Data(value.utf8),
                                attributes: [.posixPermissions: 0o600]) else {
                throw CocoaError(.fileWriteUnknown)
            }
            if fm.fileExists(atPath: url.path) {
                _ = try fm.replaceItemAt(url, withItemAt: staging,
                                         options: .usingNewMetadataOnly)
            } else {
                try fm.moveItem(at: staging, to: url)
            }
        } catch {
            FileHandle.standardError.write(Data(
                "[spotify] could not store the token: \(error.localizedDescription)\n".utf8))
        }
    }

    /// Removes the credential earlier builds left in the login keychain.
    /// Deleting does not need the item's contents, so it does not raise the
    /// access dialog that reading would.
    static func discardLegacyKeychainItem() async {
        await off {
            _ = SecItemDelete([
                kSecClass as String: kSecClassGenericPassword,
                kSecAttrService as String: "com.laks.NotchApp",
                kSecAttrAccount as String: "spotify-refresh-token",
            ] as CFDictionary)
        }
    }
}
