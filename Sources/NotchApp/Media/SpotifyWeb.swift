import AppKit
import CryptoKit

/// Liking a Spotify track, which is the one thing the local player cannot do.
///
/// Spotify's scripting dictionary declares `starred` as `access="r"` and asking a
/// live player for it fails outright, so the state is not merely unwritable, it
/// is unreadable. There is no scripting route to it at all, on any version this
/// has been tried against. The Web API is the only one.
///
/// Authorization Code with PKCE, so there is no client secret to keep anywhere.
/// Only the refresh token is persisted — see `TokenStore` for where it goes and
/// why that is not the Keychain.
///
/// A personal app in Spotify's **development mode** is exactly the supported case
/// here — the April 2025 restriction applies to *extended* quota access, and that
/// announcement says development mode "will remain accessible for experimentation
/// and personal use".
@MainActor
@Observable
final class SpotifyWeb {

    /// Each one buys a control the panel actually shows, and nothing buys more
    /// than that: the library pair for the heart, playback state for shuffle and
    /// repeat, and `user-read-private` only because `product` is how we learn
    /// whether those two can work before offering them.
    private static let scopes = [
        "user-library-read", "user-library-modify",
        "user-read-private",
        "user-read-playback-state", "user-modify-playback-state",
    ].joined(separator: " ")
    private static let tokenAccount = "spotify-refresh-token"

    /// A FIXED port, because the dashboard rejects the portless form.
    ///
    /// Spotify's own documentation says a loopback literal may be registered
    /// without a port and take a dynamic one at request time. The create-app form
    /// disagrees: `http://127.0.0.1/callback` is refused as "not secure", and only
    /// an explicit port is accepted. So the listener binds this exact port rather
    /// than asking the OS for a free one.
    ///
    /// `localhost` is rejected outright either way.
    static let callbackPort: UInt16 = 8888
    static let registeredRedirect = "http://127.0.0.1:8888/callback"

    private(set) var isConnected = false
    private(set) var lastError: String?

    private var accessToken: String?
    private var expiry = Date.distantPast

    var clientID: String { Settings.shared.spotifyClientID }

    /// Called once the stored token has been looked for. The answer arrives
    /// after launch, so whoever depends on `isConnected` has to be told rather
    /// than having asked at the wrong moment.
    var onConnect: (() -> Void)?

    init() {
        // Deliberately not awaited. Reading the stored token is off the main
        // thread and stays there: when this was a keychain read done inline, a
        // single access dialog parked the main thread in securityd and the app
        // never finished launching.
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
    /// The loopback listener is bound before the browser is opened, so the port
    /// in the authorize URL is one we are already listening on.
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
            // One consent flow at a time. A listener parked by an abandoned
            // consent tab used to hold the port for the rest of the session,
            // so every retry died on EADDRINUSE before the browser opened.
            callback?.cancel()
            callback = nil
            let listener = try await Self.bindListener()
            callback = listener
            // Ties the redirect to THIS flow. Without it, the first local
            // connection of any origin was treated as the browser's answer.
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
            // Logged as well as opened. `NSWorkspace.open` lands in whichever
            // browser and profile happens to be default, which is not always one
            // you can see — and a consent flow you cannot find is a dead end.
            FileHandle.standardError.write(Data("[spotify] authorize \(url.url!)\n".utf8))
            NSWorkspace.shared.open(url.url!)

            FileHandle.standardError.write(Data("[spotify] listening on \(listener.port)\n".utf8))
            // Only our own listener: a newer Connect may already have replaced
            // it, and clearing theirs left nothing able to cancel it.
            defer { if callback === listener { callback = nil } }
            let epoch = authEpoch
            let code = try await listener.waitForCode(state: state)
            try await exchange(code: code, verifier: verifier, redirect: redirect)
            // A Disconnect or a newer Connect during consent owns the outcome
            // now. `post` discards a reply for a dropped account without
            // throwing, so without this a disconnect mid-exchange still ended
            // here as "connected" with no token stored.
            guard flow == connectFlow, epoch == authEpoch else { return }
            isConnected = true
            await loadAccount()
            // The track on screen was drawn while this was still unconnected, so
            // its controls are missing until someone asks again.
            onConnect?()
        } catch {
            // A superseded flow's "cancelled" is not news: the flow that
            // replaced it, or the Disconnect that ended it, speaks for the menu.
            guard flow == connectFlow else { return }
            lastError = error.localizedDescription
            isConnected = false
            // A silent failure here is the worst outcome: the menu item just does
            // nothing and there is nowhere to look.
            FileHandle.standardError.write(Data("[spotify] failed: \(lastError!)\n".utf8))
        }
    }

    /// The consent flow currently listening, if any — kept so a new connect or
    /// a disconnect can end it instead of leaking the port.
    private var callback: LoopbackCallback?
    /// Which Connect is current. Bumped by every Connect and by Disconnect, so
    /// an older flow finishing late can tell it no longer speaks for the menu.
    private var connectFlow = 0

    /// Binds the callback port, riding out the window where a superseded
    /// listener has been told to stop but has not yet closed its socket: the
    /// worker owns the close — closing an fd under a thread still polling it
    /// invites fd reuse — and it notices the cancel within one poll tick.
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
        // Everything already in the air belongs to the account being dropped.
        //
        // A refresh parked in `URLSession.data` when this runs comes back a
        // round trip later and finishes its job: `post` writes the ROTATED
        // refresh token to disk. The delete below is a detached `removeItem`
        // that completes in this runloop tick, so the write lands after it and
        // recreates the credential the user just asked to be rid of — and the
        // next launch finds the file, reports connected, and silently signs
        // back in to the account they disconnected. The window is up to
        // URLSession's 60s default, and a stalled network is exactly when
        // somebody opens the menu and clicks Disconnect.
        //
        // Cancelling covers the parked call; the epoch covers the sliver where
        // the reply has already landed and cancellation has nothing left to
        // interrupt. The connect flow needs the epoch too — its `exchange` is
        // the same `post`, and a disconnect mid-consent must not be undone by
        // the consent completing.
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
        // Nothing is wrong: the user asked for this. A stale complaint from the
        // account being dropped would outlive it in the menu.
        lastError = nil
    }

    /// Bumped whenever the stored account stops being the one in play. Anything
    /// that crossed an `await` before the bump has to check it before writing.
    private var authEpoch = 0

    // MARK: Library

    /// The library is addressed by URI now, not by id and entity type.
    ///
    /// Spotify's February 2026 migration folded `/me/tracks`, `/me/albums`,
    /// `/me/episodes` and the rest into one `/me/library`, and retired the old
    /// per-type endpoints for apps in development mode. They do not 404 — they
    /// answer 403 Forbidden with no message, which reads exactly like a missing
    /// scope and is why this looked for a while like a permissions problem.
    private static let libraryContains = "https://api.spotify.com/v1/me/library/contains"
    private static let library = "https://api.spotify.com/v1/me/library"

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
        // `uris` is a query parameter on these, not a body — a JSON body comes
        // back as "Missing required field: uris".
        guard let (data, status) = await send(saved ? "PUT" : "DELETE", Self.library,
                                              ["uris": uri]) else { return false }
        if !(200...299).contains(status) {
            log("setSaved(\(saved)): HTTP \(status) \(String(data: data, encoding: .utf8) ?? "")")
        }
        return (200...299).contains(status)
    }

    // MARK: Playback modes

    /// Shuffle and repeat, which the local player will not take.
    ///
    /// Spotify's scripting dictionary declares `shuffling` and `repeating`
    /// settable, and then quietly drops the write — `shuffling enabled` and
    /// `repeating enabled` sit next to them, read-only and false. So these go
    /// over the Web API, where they are real. It costs a Premium account, which
    /// is what `canControlPlayback` records.
    private(set) var canControlPlayback = false

    /// Whether the account has ever actually answered.
    ///
    /// `canControlPlayback` alone cannot tell "this account is not Premium" from
    /// "we never found out", and the two want opposite treatment: the first is
    /// settled, the second is worth asking again.
    private(set) var accountLoaded = false

    /// Reads the account once, to know whether the mode controls can work at all
    /// before any of them is offered.
    func loadAccount() async {
        guard let (data, status) = await send("GET", "https://api.spotify.com/v1/me"),
              status == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        accountLoaded = true
        canControlPlayback = (json["product"] as? String) == "premium"
        log("account \(json["id"] as? String ?? "?"), product \(json["product"] as? String ?? "?")")
    }

    /// Ask again when the account never answered the first time.
    ///
    /// `loadAccount` runs exactly twice in a session — once from `restore` and
    /// once from `connect` — and returns silently on a nil reply, any non-200
    /// status, or an unparseable body. So one failure at launch, which is the
    /// likeliest moment for one (waking the Mac, a captive portal, a VPN not up
    /// yet, a 429, a 502), latched `canControlPlayback` false for the whole
    /// session. `askPlayback` bails on that flag, so shuffle and repeat stayed
    /// nil, `ChromeRules.modeSlots` reserved neither slot, and both controls were
    /// simply absent until the app was relaunched — with nothing on screen or in
    /// the menu saying why. The heart recovered from the same outage, which is
    /// what made the modes' silence look deliberate.
    ///
    /// Opening the panel is the retry rather than the poll loop, the same trade
    /// `MediaManager.beginPolling` already makes for the heart: a persistent
    /// failure costs one request per panel open instead of one a second at a
    /// rate-limited endpoint. Guarded on `accountLoaded`, so an account that
    /// answered and simply is not Premium is never asked twice.
    func refreshAccountIfUnknown() async {
        guard isConnected, !accountLoaded else { return }
        await loadAccount()
    }

    /// What the player is doing and what it will let us change.
    ///
    /// The second half matters as much as the first: Spotify refuses a mode it
    /// does not allow in the current context with "Restriction violated", and it
    /// says so in advance under `actions.disallows`. A control offered against
    /// that answer is a control that does nothing.
    struct Playback {
        var shuffling = false
        var repeating = false
        var canShuffle = false
        var canRepeat = false
    }

    /// Nil when there is no active device to ask about — 204 rather than 200,
    /// which is not an error.
    /// What the panel shows when the player did not answer.
    ///
    /// Pausing makes `/me/player` answer 204, so the modes arrive as nothing at
    /// all — and wiping them on that took both toggles off the panel every time
    /// the music stopped. Controls that come and go with the transport are worse
    /// than controls that sit still: the reason the user reported them "missing"
    /// was that Spotify happened to be paused.
    ///
    /// So the last answer is kept, with both writes marked refused. That is not a
    /// convenient fiction — while paused they genuinely are refused, and Spotify
    /// says so itself: `toggling_shuffle` sits in `disallows` even in the replies
    /// it does send. The glyph stays where it was, dimmed and disabled, which is
    /// the same thing the panel shows a second earlier while playing.
    ///
    /// Zeroing the two `can` flags is the whole point of keeping a COPY rather
    /// than just declining to overwrite. `apply` recomputes `shuffleBlocked` from
    /// `canShuffle` on every poll, so a kept answer from a context that allowed
    /// shuffle would leave a bright, live-looking button whose write is about to
    /// fail — exactly the thing mediacheck exists to prevent.
    static func modes(from fresh: Playback?, keeping previous: Playback?) -> Playback? {
        if let fresh { return fresh }
        guard var kept = previous else { return nil }
        kept.canShuffle = false
        kept.canRepeat = false
        return kept
    }

    func playbackModes() async -> Playback? {
        guard canControlPlayback else { return nil }
        // Each of these returned nil silently, and a silent nil here reads on the
        // panel as "no shuffle button" — indistinguishable from a button that was
        // never built. 204 is the one that actually happens, and it means PAUSED:
        // Spotify drops the desktop app off Connect the moment the music stops,
        // so there is no player to report even though the app is still open with
        // the track loaded. See `modes(from:keeping:)` for what the panel shows
        // in that window.
        guard let (data, status) = await send("GET", "https://api.spotify.com/v1/me/player")
        else { log("playback: no reply"); return nil }
        guard status == 200 else {
            log("playback: HTTP \(status)" + (status == 204 ? " — no active Connect device" : ""))
            return nil
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { log("playback: unreadable body"); return nil }
        let disallows = (json["actions"] as? [String: Any])?["disallows"] as? [String: Any] ?? [:]
        // One key, and specifically the key the write actually uses.
        //
        // This took a list and returned true if ANY of them was permitted, and
        // repeat was asked about both `toggling_repeat_context` and
        // `toggling_repeat_track`. But `setMode` only ever sends
        // `state=context` or `state=off`, so context is the sole capability that
        // governs this button — and Spotify's usual shape when a context cannot
        // repeat is to name `toggling_repeat_context` and omit the track key
        // entirely. An absent key is not a refusal, so the OR read the missing
        // one as permission and lit a button whose every press was refused with
        // "Restriction violated". It never settled either: the revert path does
        // not re-ask, so the next poll recomputed the same wrong permission.
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
    /// `context` — repeat the album or playlist, the state a single toggle means.
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
    /// Retry-After. Hammering through a rate limit only lengthens it.
    private var notBefore = Date.distantPast

    /// One authorized request. Returns nil only when there is no token, the
    /// connection itself failed, or a rate limit is still running — an HTTP
    /// error still comes back, because the status is the most useful thing
    /// this API says.
    ///
    /// A 401 gets one retry through `token()`. The local expiry is only a
    /// guess at the server's opinion: a password change or sign-out-everywhere
    /// invalidates the token server-side with up to an hour left on the local
    /// clock, and every feature went dark for that hour with nothing rendered
    /// anywhere. The retry refreshes; a refresh refused with invalid_grant
    /// already surfaces "revoked" properly via `refreshFailed`.
    private func send(_ method: String, _ url: String,
                      _ query: [String: String] = [:],
                      retried: Bool = false) async -> (Data, Int)? {
        guard Date() >= notBefore else { return nil }
        guard let token = await token() else { return nil }
        var c = URLComponents(string: url)!
        if !query.isEmpty { c.queryItems = query.map { .init(name: $0.key, value: $0.value) } }
        var request = URLRequest(url: c.url!)
        request.httpMethod = method
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, response) = try? await URLSession.shared.data(for: request) else {
            log("\(method) \(url): request failed")
            return nil
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        if status == 401 {
            guard !retried else {
                // Refreshed and still refused — surface it where the
                // connected-but-failing menu line can render it.
                lastError = "Spotify refused the last request."
                return (data, status)
            }
            // Drop the cached token only if it is still the one that was
            // refused: a slow reply's 401 must not wipe a fresh refresh.
            if accessToken == token {
                accessToken = nil
                expiry = .distantPast
            }
            return await send(method, url, query, retried: true)
        }
        if status == 429 {
            let after = (response as? HTTPURLResponse)?
                .value(forHTTPHeaderField: "Retry-After").flatMap(Double.init) ?? 5
            notBefore = Date().addingTimeInterval(after)
            log("\(method) \(url): 429, backing off \(Int(after))s")
        }
        // A request that worked is proof the complaint in the menu is over. It
        // was only ever cleared by Connect and Disconnect, so a refresh that
        // failed once while Wi-Fi came back after wake stayed on screen as
        // "could not be reached" for the rest of the session.
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
    /// Opening the panel asks the library about the track and the player about
    /// its modes at nearly the same moment, and on a cold launch every one of
    /// them finds the same expired token — three `token ok` lines in the log
    /// from one launch. Spotify ROTATES the refresh token, so the second and
    /// third present one the first has already spent, and whichever finishes
    /// last writes its answer over the good one. Nothing looks wrong today; it
    /// fails at some later launch as a refresh that is simply refused, with no
    /// trace of what invalidated it.
    private var refreshTask: Task<String?, Never>?

    private func token() async -> String? {
        if let accessToken, expiry > Date().addingTimeInterval(30) { return accessToken }
        // Only the caller that started the refresh clears it, and no new one can
        // start while it is set, so this cannot drop somebody else's task.
        if let refreshTask {
            // Silent in the ordinary case, and the only way to see the race
            // being absorbed rather than merely absent — one `token ok` in a
            // log proves nothing if only one caller ever asked.
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
                // this on purpose, and `refreshFailed` would answer that with
                // "Spotify could not be reached." — which the menu then shows,
                // because disconnect has just set `isConnected` false and that
                // is the branch `lastError` renders in. A deliberate, wholly
                // successful disconnect would report a network failure.
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

    /// A refresh that came back refused, which used to be discarded by a `try?`.
    ///
    /// Nothing reacted: `isConnected` stayed true because it is set from the
    /// stored file merely EXISTING, `lastError` was only ever written by
    /// `connect()`, and not one line reached the log. Revoke the app at
    /// spotify.com and every launch afterwards looks connected, shows no error,
    /// offers "Disconnect Spotify Library" — and the whole Spotify half of the
    /// panel is simply dark, for good, with nowhere to look. The file's own note
    /// on `connect()` names this as the worst outcome, and then this path did it.
    ///
    /// `invalid_grant` is the terminal one: the grant is gone and no retry will
    /// bring it back, so the token is dropped and the connection reported as
    /// what it now is. Everything else — offline, a 500, a timeout — is left
    /// alone, because a transient failure must not throw away a good token.
    private func refreshFailed(_ error: Error) {
        // The token endpoint's ERROR bodies carry no credential; the access and
        // refresh tokens only ever appear in a 200, which does not reach here.
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
        // isConnected false is what makes the menu's error line reachable at
        // all: it renders "Disconnect Spotify Library" whenever this is true,
        // and puts `lastError` in the branch that only runs when it is false.
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
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = fields
            .map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "")" }
            .joined(separator: "&")
            .data(using: .utf8)

        let epoch = authEpoch
        let (data, response) = try await URLSession.shared.data(for: request)
        // Disconnected while this was in the air. Returning rather than throwing:
        // there is no failure to report, the answer is simply about an account
        // that is no longer ours to write for.
        guard epoch == authEpoch else {
            log("token reply discarded — disconnected while it was in flight")
            return
        }
        guard (response as? HTTPURLResponse)?.statusCode == 200,
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let access = json["access_token"] as? String
        else {
            throw NSError(domain: "SpotifyWeb", code: 1, userInfo: [
                NSLocalizedDescriptionKey:
                    String(data: data, encoding: .utf8) ?? "token request failed",
            ])
        }
        accessToken = access
        expiry = Date().addingTimeInterval((json["expires_in"] as? Double) ?? 3600)
        // What was actually granted, which is not always what was asked for —
        // and a 403 from the library reads identically either way.
        FileHandle.standardError.write(Data(
            "[spotify] token ok, scope: \(json["scope"] as? String ?? "none")\n".utf8))
        // Spotify only returns a new refresh token sometimes; keep the old one
        // when it does not.
        if let newRefresh = json["refresh_token"] as? String {
            await TokenStore.write(newRefresh, account: Self.tokenAccount)
            // The epoch check above covers replies that landed after a
            // disconnect; this covers the write itself. The suspension into
            // the store releases the actor, so a disconnect can run between
            // that check and this write's enqueue — its detached delete then
            // loses the race and the rotated token quietly recreates the
            // credential. Re-check and compensate, rather than trying to
            // order two detached tasks.
            if epoch != authEpoch {
                log("token write voided — disconnected while it was landing")
                await TokenStore.delete(Self.tokenAccount)
            }
        }
    }

    // MARK: Helpers

    /// `spotify:track:ID` and bare IDs both arrive here; the API wants the bare
    /// one. Anything else — a synthesised title/artist key from a player with no
    /// id — is refused rather than sent.
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
    /// base64url, unpadded — what RFC 7636 asks for.
    var base64URL: String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

// MARK: - The loopback listener

/// Waits for the browser to hit the redirect, pulls `code` out of the query,
/// and answers with a page that tells the truth about what happened.
///
/// A plain BSD socket rather than `NWListener`. Network.framework refused this
/// port with `POSIXErrorCode 22: Invalid argument` and, without a state handler,
/// did so silently — the flow simply hung with nothing in the log. For a
/// loopback accept there is nothing the framework buys that is worth that.
///
/// Three rules earned the hard way:
/// - A DEADLINE, because the wait used to be a bare `accept()` with none: an
///   abandoned consent tab parked the thread forever, held the port in LISTEN
///   for the rest of the session, and every retry died on EADDRINUSE before
///   the browser even opened.
/// - A LOOP with a `state` check, because the first connection on a loopback
///   port is not necessarily the browser — a stray localhost fetch from any
///   web page, a port scanner, a speculative browser socket. Anything that is
///   not this flow's redirect gets a 404 and the wait continues.
/// - The reply is chosen AFTER parsing, because the page used to say
///   "Connected." to a declined consent.
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
        // A local until both members are set — Swift will not let a closure see
        // a partially initialised self.
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
        // Non-blocking, so the wait below can poll against a deadline instead
        // of parking a thread in accept() with no way home.
        let flags = fcntl(sock, F_GETFL, 0)
        _ = fcntl(sock, F_SETFL, flags | O_NONBLOCK)
        fd = sock
        port = wanted
    }

    /// Ends the wait from outside — a new connect superseding this one, or a
    /// disconnect mid-consent. The worker notices within one poll tick and
    /// closes the socket ITSELF: closing an fd out from under a thread still
    /// polling it invites the number being reused for something else.
    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    /// How long the user gets to finish the consent page. Spotify's own
    /// authorization codes die well within this; past it the flow is dead
    /// anyway and holding the port only wedges the retry.
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
                        // Not the browser. Keep waiting for it.
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
        /// Anything else — not this flow's redirect.
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

    /// One read() can return before the request line has arrived; loop until
    /// the header terminator or a small cap. Bounded blocking — the accepted
    /// fd inherits non-blocking from the listener on BSD, and a slow browser
    /// still deserves to be parsed.
    ///
    /// Any local process can connect while the consent window is open, so this
    /// is a trust boundary. Two guards: a peer that resets the connection makes
    /// the reply's write() raise SIGPIPE, whose default action kills the whole
    /// app — SO_NOSIGPIPE turns that into an EPIPE the reply ignores; and a
    /// peer that trickles a byte every second or two would reset a per-read
    /// timeout forever, holding the only worker past the consent deadline, so
    /// the whole read gets one absolute deadline too.
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
/// It was, and the Keychain is the right home for a credential — but a keychain
/// item is bound to the exact executable that wrote it, and this app is ad-hoc
/// signed, so every rebuild is a different executable. macOS then asks for
/// permission on the next launch, in a dialog that opens behind whatever window
/// is in front, and until someone finds and answers it the Spotify half of the
/// panel is simply dark. Signing with a stable identity would fix that; this Mac
/// has no code-signing identity to sign with. An access policy naming no
/// application was tried too, and denies rather than opens.
///
/// So: a file, owner-read-only, in this app's own Application Support directory.
/// What it protects is a refresh token scoped to one person's own saved songs
/// and playback. On a FileVault volume it is encrypted at rest like everything
/// else; the difference from a keychain item is that another process running as
/// the same user could read it — and such a process could equally read this
/// app's binary, its defaults, and the rest of the home directory.
///
/// If this app is ever signed with a stable identity, the Keychain becomes the
/// better home again and this should go back.
enum TokenStore {

    private static var directory: URL {
        URL.applicationSupportDirectory.appending(path: "Magnetite", directoryHint: .isDirectory)
    }

    /// Where the token lived under earlier names, newest first.
    ///
    /// Deliberately still spelled the old way: a migration path has to name the
    /// old thing to find it. Nothing else in the app may use these strings.
    ///
    /// Two of them now. The directory was `NotchApp`, then `Ferro`, and the
    /// token only ever exists in one place — whichever build last wrote it — so
    /// both have to be tried or a user who skipped a release is silently signed
    /// out of their library, with a heart that stopped working as the only
    /// symptom.
    private static let legacyNames = ["Ferro", "NotchApp"]

    private static func legacyDirectory(_ name: String) -> URL {
        URL.applicationSupportDirectory.appending(path: name, directoryHint: .isDirectory)
    }

    private static func file(_ account: String) -> URL {
        directory.appending(path: account, directoryHint: .notDirectory)
    }

    // Off the main thread. File reads are quick, but this is a credential store
    // on a shared main actor and the launch path has been frozen by one once.
    static func read(_ account: String) async -> String? {
        await off { readNow(account) }
    }

    static func write(_ value: String, account: String) async {
        await off { writeNow(value, account: account) }
    }

    /// Deletion covers everything `read` consults, or Disconnect can be
    /// silently undone: `readNow` falls back to the legacy directories, and a
    /// legacy file that survived its migration — a full disk mid-copy, a
    /// swallowed removeItem — would be re-adopted on the next launch, written
    /// forward, and reported as connected: the app re-signing in to the
    /// account the user asked to be rid of.
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

    /// A token written under the old directory name is still the user's token.
    ///
    /// Without this, renaming the app silently signs everyone out of their
    /// library and the only symptom is a heart that stopped working. Reads it
    /// once, writes it forward, and removes the original so this never runs
    /// twice — and takes the old directory with it when nothing is left in it.
    ///
    /// The original is removed only once the forward copy has been read back
    /// and found to match. `writeNow` reports failure to stderr and returns
    /// normally, so trusting it would turn a full disk or a bad permission into
    /// a deleted credential; on any doubt the old file stays and the token
    /// still works from where it is. Returning the token either way means the
    /// session continues even when the migration could not.
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
            let url = file(account)
            try Data(value.utf8).write(to: url, options: [.atomic])
            // Set after the write: an atomic write replaces the file, and with it
            // any permissions the previous one carried.
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            FileHandle.standardError.write(Data(
                "[spotify] could not store the token: \(error.localizedDescription)\n".utf8))
        }
    }

    /// Removes the credential the earlier builds left in the login keychain.
    ///
    /// Deleting does not need the item's contents, so it does not raise the
    /// access dialog that reading it would.
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
