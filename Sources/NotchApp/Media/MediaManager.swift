import AppKit
import SwiftUI
import Observation

/// Main-actor view model over `MediaBridge`.
///
/// Three habits that keep an always-running menu-bar app honest:
///
///   * **Refcounted polling** — the seeker timer only runs while something on
///     screen actually needs it, so a collapsed idle notch costs nothing.
///   * **Track identity** — artwork and palette work is skipped unless the
///     identity changed, instead of re-decoding on every poll.
///   * **Transient filtering** — very short "tracks" are notification chirps, not
///     music, and must not hijack the display.
@MainActor
@Observable
final class MediaManager {

    /// Keyed per display: with two notches, a collapsed one used to remove the
    /// single shared `.notchExpanded` token that the *other*, still-expanded
    /// notch had just inserted, silently dropping the poll rate on the panel the
    /// user was actually looking at.
    enum PollingSource: Hashable {
        case notchExpanded(String)
        case liveActivity
    }

    // Presented state
    private(set) var title = ""
    private(set) var artist = ""
    private(set) var isPlaying = false
    private(set) var duration: Double = 0
    private(set) var position: Double = 0
    private(set) var source: MusicSource?
    private(set) var artwork: NSImage?
    private(set) var palette: ArtworkPalette = .fallback
    private(set) var hasTrack = false
    /// `nil` when the source cannot report it — which is Spotify, always. The
    /// heart is shown only when this is non-nil, so there is never a control that
    /// looks live and does nothing.
    private(set) var liked: Bool?
    /// Player modes. `nil` means the player did not answer, and the control is
    /// not shown — the same rule the heart follows.
    private(set) var shuffling: Bool?
    private(set) var repeating: Bool?
    /// Offered but refused: Spotify restricts both modes in some playback
    /// contexts and says so in advance. Hiding them on that basis is what made
    /// the panel look like it had lost its buttons, so they stay on screen and
    /// read as unavailable instead.
    private(set) var shuffleBlocked = false
    private(set) var repeatBlocked = false
    /// Bumped on every track change so views can retrigger entrance animations.
    private(set) var trackToken = 0
    /// Set when a player is running but every snapshot comes back empty.
    private(set) var automationNote: String?
    private var emptyReads = 0
    /// Set when a player is running and taking the events without answering
    /// them. A different fault from `automationNote` with a different remedy —
    /// no grant is missing, so no settings pane can help.
    private(set) var stalledNote: String?
    private var stalledReads = 0

    /// How many consecutive unanswered polls before a stalled player is called
    /// one. One number, deliberately: the note that explains the stall and the
    /// clearing of the panel it explains must happen on the same beat, or the
    /// panel goes blank for two polls with nothing on screen saying why.
    static let stallPatience = 3

    /// Whether a poll that found no track should clear the panel or hold the
    /// last frame it had.
    ///
    /// A player that has stopped answering is not a player with nothing to play.
    /// Blanking on the very first unanswered read tore the track off the panel
    /// within 1.5s of a stall, then replayed the entrance animation when it came
    /// back — a flicker per stall, on the same fault the note treats as worth
    /// three polls of patience before it will even name it.
    ///
    /// `foundTrack` is not redundant with `stalled`: with two players polled,
    /// one can stall while the other is playing perfectly well. Holding the last
    /// frame in that case would drop a snapshot the panel was handed — the
    /// wedged-Spotify-hides-a-healthy-Music failure, one layer up.
    ///
    /// A pure rule rather than a branch inside `refresh()`, for the reason
    /// `SpotifyWeb.modes(from:keeping:)` is one: `refresh()` needs a running
    /// player to reach this at all, so an assertion there would pass no matter
    /// what the rule said.
    static func holdsLastFrame(stalled: Bool, foundTrack: Bool,
                               hasTrack: Bool, stalledReads: Int) -> Bool {
        stalled && !foundTrack && hasTrack && stalledReads < stallPatience
    }

    /// Among players that answered and none of which is playing, the one
    /// already on screen keeps the panel. Spotify is asked first, so pausing
    /// Music while a paused Spotify sat behind it handed the panel to Spotify.
    /// Pure for the reason `holdsLastFrame` is.
    static func keepsPanel(_ snap: TrackSnapshot, over best: TrackSnapshot?,
                           showing: MusicSource?) -> Bool {
        guard let best else { return true }
        return snap.source == showing && best.source != showing
    }


    // Internals
    private let bridge: MediaBridge
    /// Spotify's like state lives behind the Web API — the local player can
    /// neither read nor write it.
    let spotify = SpotifyWeb()
    /// Guards against a stale library answer landing on a newer track.
    private var likeQuery = 0
    @ObservationIgnored private(set) var libraryTask: Task<Void, Never>?
    private var pollingSources: Set<PollingSource> = []
    private var timer: Task<Void, Never>?
    private var burst: Task<Void, Never>?
    private var identity = ""
    private var positionAnchor = Date()
    private var artworkTask: Task<Void, Never>?
    private var artworkGeneration = 0
    /// Hash of the last artwork's bytes, so the same cover is not re-processed.
    private var artworkDigest: Int?
    // Touched in init and deinit only; deinit runs outside the actor.
    @ObservationIgnored private nonisolated(unsafe) var observers: [NSObjectProtocol] = []

    /// Anything shorter than this is a sound effect, not a song.
    private let transientDurationThreshold: Double = 6.0

    private var settings: Settings { .shared }

    init(bridge: MediaBridge = MediaBridge(), observePlayers: Bool = true) {
        self.bridge = bridge
        // The stored Spotify token is looked for off the main thread, so the
        // track already on screen was applied while the answer was still "not
        // connected". Ask the library again the moment it lands, or the heart
        // stays missing until the next track change.
        spotify.onConnect = { [weak self] in
            // Forget what was asked before the connection existed, so the track
            // already on screen is asked about again.
            self?.askedIdentity = nil
            self?.askLibrary()
        }
        guard observePlayers else { return }
        // Apple Music broadcasts track changes for free — far better than polling.
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(
            forName: .init("com.apple.Music.playerInfo"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSoon() }
        })
        observers.append(center.addObserver(
            forName: .init("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSoon() }
        })

        let ws = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.didLaunchApplicationNotification,
                     NSWorkspace.didTerminateApplicationNotification] {
            observers.append(ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    if let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                       let id = app.bundleIdentifier,
                       let src = MusicSource.allCases.first(where: { $0.bundleID == id }) {
                        self.bridge.invalidate(src)
                    }
                    self.refreshSoon()
                }
            })
        }

        Task { await refresh() }
    }

    deinit {
        let center = DistributedNotificationCenter.default()
        let ws = NSWorkspace.shared.notificationCenter
        for o in observers { center.removeObserver(o); ws.removeObserver(o) }
    }

    // MARK: Polling lifecycle

    func beginPolling(_ src: PollingSource) {
        let wasEmpty = pollingSources.isEmpty
        // Only a genuinely new token restarts the burst. Re-inserting one on
        // every mouse-moved event restarted the refresh task continuously.
        guard pollingSources.insert(src).inserted else { return }
        if wasEmpty { startTimer() }
        // An ask that never came back — no network, a token that had expired, a
        // connection not yet restored — still marked this track as asked about,
        // and `apply` will not ask twice. The heart would then stay absent for
        // as long as the track plays. Opening the panel is the retry, rather
        // than the poll loop, so a persistent failure cannot hammer a
        // rate-limited endpoint once a second.
        if source == .spotify, webLiked == nil { askedIdentity = nil }
        // The same retry, for the answer the modes depend on. A launch-time
        // failure left `canControlPlayback` false for the session and took both
        // mode controls off the panel with it, while the heart above recovered
        // from the identical outage. See `SpotifyWeb.refreshAccountIfUnknown`.
        Task { [spotify] in await spotify.refreshAccountIfUnknown() }
        refreshSoon()
        // Shuffle and repeat can be changed in Spotify itself, and can stop
        // being offered at all — they are restricted while playback is paused.
        // Opening the panel is the moment that has to be true.
        askPlayback()
    }

    func endPolling(_ src: PollingSource) {
        // Presence-checked, the guard beginPolling already has: the coordinator
        // calls this for every collapsed host on every system-wide mouse move,
        // and removing nothing still reached stopTimer() — cancelling the
        // notification burst that is the only detection path while the notch
        // is idle. Music started just before a mouse twitch went undetected
        // until the next player event.
        guard pollingSources.remove(src) != nil else { return }
        if pollingSources.isEmpty { stopTimer() }
    }

    private func startTimer() {
        stopTimer()
        timer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                // 1s is plenty: position is interpolated locally between polls.
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                await self.refresh()
            }
        }
    }

    private func stopTimer() {
        timer?.cancel()
        timer = nil
        burst?.cancel()
        burst = nil
    }

    /// Poll hard for a moment after a command.
    ///
    /// Players apply a transport command and update their own state a beat later,
    /// and at the idle 1Hz poll that lag is what makes the controls feel dead even
    /// though the command already landed. A short burst catches the new state
    /// almost immediately and then gets out of the way.
    private func refreshSoon() {
        burst?.cancel()
        burst = Task { @MainActor [weak self] in
            for delay in [40, 90, 180, 320, 600] {
                try? await Task.sleep(for: .milliseconds(delay))
                guard let self, !Task.isCancelled else { return }
                await self.refresh()
            }
        }
    }

    // MARK: Refresh

    /// Which player to read. `automatic` prefers whichever is actually playing,
    /// falling back to whichever is merely running.
    private func resolveSources() -> [MusicSource] {
        switch settings.musicApp {
        case "spotify": return [.spotify]
        case "music":   return [.music]
        default:        return [.spotify, .music]
        }
    }

    /// Bumped at every refresh() entry; only the most recently started refresh
    /// may write state when its reads come back.
    private var refreshGeneration = 0

    func refresh() async {
        refreshGeneration &+= 1
        let generation = refreshGeneration
        var best: TrackSnapshot?
        // Which player would not answer, as opposed to which had nothing to say.
        var mute: MusicSource?
        /// Which player took the event and never answered it.
        var stalled: MusicSource?
        // Labelled, because the early exit below sits inside a `switch` now and
        // a bare `break` there leaves the switch, not the loop — it would go on
        // polling the other player after already finding the one that is playing.
        search: for src in resolveSources() {
            guard MediaBridge.isRunning(src) else { continue }
            switch await bridge.read(for: src) {
            case .unreadable:
                if mute == nil { mute = src }
            case .unanswered:
                if stalled == nil { stalled = src }
            case .idle:
                continue
            case .track(let snap):
                // A playing source always wins over a merely-open one.
                if snap.isPlaying { best = snap; break search }
                if Self.keepsPanel(snap, over: best, showing: source) { best = snap }
            }
        }

        // Only the freshest refresh may write. Nothing serialises these: the
        // 1Hz timer, the burst and init all call refresh() independently, and
        // the await above parks each one inside the bridge. The inversion is
        // real and asymmetric — a playing snapshot breaks the search early and
        // applies at burst latency, while a paused one falls through to the
        // second source and straddles up to the read deadline — so a press
        // that already landed was being un-pressed on screen ~1.5s later by a
        // snapshot read before it. The guard covers the whole tail, counters
        // and notes included, not just apply(): stale refreshes must not walk
        // the patience counters out of order either.
        guard generation == refreshGeneration else { return }

        // A player is open but every read came back empty — the signature of a
        // refused Automation grant. It is the more commonly denied of the two
        // permissions and the only one with no diagnosis anywhere: the panel just
        // says nothing is playing, forever, while music is audibly playing.
        // Three consecutive polls, not three seconds. A launch notification
        // triggers a burst refresh, so three can pass in well under a second —
        // this rides out a player that answers late, not one that is slow.
        // Keyed on the player that would not ANSWER, not on merely having found
        // no track. Open Music to browse and queue nothing — an ordinary all-day
        // state — and this used to accuse the user of refusing a permission they
        // had granted, then offer a settings pane that could not change it. A
        // player that answers "stopped" is a player whose grant is working.
        if let src = mute, best == nil {
            emptyReads &+= 1
            if emptyReads >= 3, automationNote == nil {
                automationNote = "Can't read \(src.displayName)"
            }
        } else {
            emptyReads = 0
            if automationNote != nil { automationNote = nil }
        }

        // Same three-poll patience, and deliberately a separate counter: a
        // player that answers "no" and a player that answers nothing are not
        // the same fault, and the menu offers a different remedy for each.
        // Sharing one counter would also let two different faults, neither of
        // them three polls old, add up to an accusation.
        if let src = stalled, best == nil {
            stalledReads &+= 1
            if stalledReads >= Self.stallPatience, stalledNote == nil {
                stalledNote = "\(src.displayName) isn't answering"
            }
        } else {
            stalledReads = 0
            if stalledNote != nil { stalledNote = nil }
        }

        // The panel keeps what it has while the stall is still inside its
        // patience. `.unreadable` is not given the same treatment: a player that
        // answers "no" has answered, and what it said is that there is nothing
        // to show.
        if Self.holdsLastFrame(stalled: stalled != nil, foundTrack: best != nil,
                               hasTrack: hasTrack, stalledReads: stalledReads) { return }

        apply(best)
    }

    /// Internal rather than private so `tools/mediacheck.swift` can drive the real
    /// reconciliation path with synthetic snapshots instead of a live player.
    func apply(_ snap: TrackSnapshot?) {
        guard let snap else {
            guard hasTrack else { return }
            hasTrack = false
            isPlaying = false
            source = nil
            title = ""; artist = ""
            duration = 0; position = 0
            identity = ""
            artwork = nil
            palette = .fallback
            liked = nil
            shuffling = nil
            repeating = nil
            // Losing the player is not the same as pausing it: there is nothing
            // left for `modes(from:keeping:)` to keep, and a kept answer would
            // come back on whatever plays next.
            webModes = nil
            webLiked = nil
            // And the record of having ASKED goes with the answer it produced.
            //
            // Left standing, the same track returning after a blank is not a
            // track change, so `apply` will not ask about it again — the heart
            // and both mode glyphs stay absent for the rest of that track, and
            // only opening the panel or playing something else brings them back.
            // Every blank is a candidate: a stall, a quit, a track that ended.
            askedIdentity = nil
            askedPlaying = nil
            // The artwork pipeline dies with the track — the same teardown a
            // track change performs. Left running, the generation still
            // matched, so a slow CDN answer or a sleeping retry re-landed the
            // dead track's cover and palette on an empty panel; and with
            // `hasTrack` false, the guard above meant nothing ever cleaned
            // that up until something else played.
            artworkTask?.cancel()
            artworkTask = nil
            artworkGeneration &+= 1
            artworkDigest = nil
            return
        }

        // Short items are not tracks. Players surface notification chirps and
        // stingers through the same interface, and a panel that flips to them and
        // back is worse than one that misses them. A genuinely sub-6s track is
        // skipped too, which is the accepted side of that trade.
        //
        // The track on screen is kept, but not as playing: whatever is playing
        // now is not it. Held as playing, its line ran to the end and stayed
        // there for as long as the short item stayed current, which for a clip
        // left stopped in the player is indefinitely.
        if snap.duration > 0, snap.duration < transientDurationThreshold {
            if isPlaying {
                position = smoothPosition
                positionAnchor = Date()
                pendingIsPlaying = nil
                withAnimation(Motion.swap) { isPlaying = false }
            }
            return
        }

        // Observation fires on assignment, not on change, so every write below
        // is compared first: this runs at poll rate, and rewriting a static
        // title on a paused track invalidated every body reading it, once a
        // second, forever. Values are still COMPUTED unconditionally each poll
        // — the recompute is load-bearing for the mode flags, whose inputs move
        // between identical snapshots — only the no-op assignments are skipped.
        let changed = snap.identity != identity
        if !hasTrack { hasTrack = true }
        if source != snap.source {
            bridge.prewarm(snap.source)
            source = snap.source
        }
        if title != snap.title { title = snap.title }
        if artist != snap.artist { artist = snap.artist }
        if duration != snap.duration { duration = snap.duration }

        // A new track makes any pending seek moot — and the previous track's
        // library answer, which is about to be asked for again.
        if changed { pendingPosition = nil; pendingLiked = nil; webLiked = nil }

        // Same optimistic hold the transport uses: the heart fills on the press
        // and the poll is not allowed to argue with it until the player has had
        // time to agree.
        // Spotify's answer arrives over the network, not in the snapshot, where
        // it is permanently nil — so taking the snapshot's word for it wiped the
        // library's answer on the very next poll, a few hundred milliseconds
        // after it landed. The heart was being erased, not never set.
        let snapLiked = snap.source == .spotify ? webLiked : snap.liked
        if let pending = pendingLiked,
           Date().timeIntervalSince(pending.at) < Self.commandGrace,
           snapLiked != pending.value {
            // In flight — keep what was pressed.
        } else {
            pendingLiked = nil
            if liked != snapLiked { liked = snapLiked }
        }

        // Spotify: ask the Web API, and only when the track actually changed.
        // `apply` runs on every poll and this is a network round trip against a
        // rate-limited endpoint.
        // Keyed on which track was asked about, not on `changed`: the connection
        // is restored off the main thread and lands after the first snapshot, so
        // on launch the track never "changes" and nothing would ever ask.
        if snap.source == .spotify, spotify.isConnected, snap.identity != askedIdentity {
            askLibrary(about: snap.identity)
        } else if snap.source == .spotify, !spotify.isConnected {
            liked = nil
            // The modes have to go the same way the heart does.
            //
            // Snapshots keep arriving after a disconnect — the bridge reads the
            // local Spotify app over AppleScript and knows nothing about the Web
            // API — so `snapModes` below went on reading a `webModes` that no
            // longer had anything behind it. Both glyphs stayed lit and enabled,
            // `askPlayback` could never correct them because it bails on
            // `isConnected`, and pressing one reverted it to the same stale
            // value. A control that renders and does nothing, for as long as the
            // track lasts.
            webModes = nil
            askedPlaying = nil
        }

        // A pause is the other moment the capabilities move without us.
        //
        // `beginPolling` already says it: shuffle and repeat "are restricted
        // while playback is paused", and Spotify drops the desktop app off
        // Connect the moment the music stops, which is what turns the answer
        // into the 204 that `SpotifyWeb.modes(from:keeping:)` exists to handle.
        // But a pause is not a track change, so the gate above never fires for
        // it — and `beginPolling` cannot re-ask either, because while the panel
        // is open its token is already in `pollingSources` and the insert
        // returns early. So the flags went on recomputing from the same stale
        // `webModes` on every poll for the rest of the track, in both
        // directions: a bright shuffle button whose write Spotify refuses, or a
        // dimmed one on a player that would now accept it.
        //
        // Keyed on the SNAPSHOT's playing state, not ours: `isPlaying` above
        // holds optimistically through a press, and what matters here is when
        // the player actually moved.
        if Self.shouldAskPlayback(source: snap.source, connected: spotify.isConnected,
                                  playing: snap.isPlaying, askedPlaying: askedPlaying) {
            askedPlaying = snap.isPlaying
            askPlayback()
        }

        // Modes hold optimistically too: they are a round-trip away and the
        // glyph must light under the finger.
        // Spotify's own answer is the Web API's; the bridge reports nil for it.
        let snapModes: (shuffling: Bool?, repeating: Bool?) =
            snap.source == .spotify ? (webModes?.shuffling, webModes?.repeating)
                                    : (snap.shuffling, snap.repeating)
        let blockShuffle = snap.source == .spotify && !(webModes?.canShuffle ?? true)
        let blockRepeat = snap.source == .spotify && !(webModes?.canRepeat ?? true)
        if shuffleBlocked != blockShuffle { shuffleBlocked = blockShuffle }
        if repeatBlocked != blockRepeat { repeatBlocked = blockRepeat }
        if let p = pendingModes, Date().timeIntervalSince(p.at) < Self.commandGrace {
            if p.shuffling == nil, shuffling != snapModes.shuffling {
                shuffling = snapModes.shuffling
            }
            if p.repeating == nil, repeating != snapModes.repeating {
                repeating = snapModes.repeating
            }
        } else {
            pendingModes = nil
            if shuffling != snapModes.shuffling { shuffling = snapModes.shuffling }
            if repeating != snapModes.repeating { repeating = snapModes.repeating }
        }

        if let pending = pendingPosition,
           Date().timeIntervalSince(pending.at) < Self.commandGrace,
           abs(snap.position - pending.value) > 1.5 {
            // The player has not caught up yet — keep what the user asked for.
        } else {
            pendingPosition = nil
            // Skipped only when paused AND unchanged: while playing the anchor
            // must reset on every accepted snapshot or the interpolation runs
            // from stale time, and while paused the anchor is never read. The
            // SNAPSHOT's state counts too: a resume made in the player itself
            // arrives here with `isPlaying` still false, and skipping the reset
            // then left the anchor at the moment of the pause — the same
            // run-to-the-end the press path had.
            if position != snap.position || isPlaying || snap.isPlaying {
                position = snap.position
                positionAnchor = Date()
            }
        }

        if let pending = pendingIsPlaying,
           Date().timeIntervalSince(pending.at) < Self.commandGrace,
           snap.isPlaying != pending.value {
            // Same: the command is in flight, don't undo it on screen.
        } else {
            pendingIsPlaying = nil
            if isPlaying != snap.isPlaying {
                withAnimation(Motion.swap) { isPlaying = snap.isPlaying }
            }
        }

        if changed {
            identity = snap.identity
            trackToken &+= 1
            loadArtwork(for: snap)
        }
    }

    /// Position interpolated from the last poll, evaluated at read time.
    ///
    /// Ticking a stored value on a timer makes the scrubber advance in visible
    /// steps at whatever the tick rate is. Anchoring to the last known position
    /// and elapsing real time instead lets a display-rate view read a genuinely
    /// continuous value.
    var smoothPosition: Double {
        guard isPlaying else { return position }
        let elapsed = position + Date().timeIntervalSince(positionAnchor)
        // Duration 0 is a live stream, not a reason to stop interpolating: the
        // clamp needs a duration, the elapsing of real time does not, and the
        // raw fallback stepped at poll cadence on exactly the clocks this
        // property exists to keep smooth.
        return duration > 0 ? min(duration, elapsed) : elapsed
    }

    var smoothProgress: Double {
        guard duration > 0.01 else { return 0 }
        return min(max(smoothPosition / duration, 0), 1)
    }

    /// Asks Spotify's library about a track. The generation counter is what
    /// keeps a slow answer for an older track from landing on a newer one.
    private func askLibrary(about id: String? = nil) {
        guard let id = id ?? (source == .spotify ? identity : nil), !id.isEmpty,
              spotify.isConnected else { return }
        askedIdentity = id
        likeQuery &+= 1
        let query = likeQuery
        libraryTask = Task { @MainActor in
            let saved = await spotify.isSaved(trackID: id)
            // Leaving Spotify does not start another library query. A late
            // answer still belongs only to the Spotify track that asked for it.
            guard query == self.likeQuery, self.source == .spotify,
                  id == self.identity else { return }
            self.webLiked = saved
            if self.pendingLiked == nil { self.liked = saved }
        }
        askPlayback()
    }

    /// Everything the panel is currently claiming, in one line. The controls
    /// live in a window that only exists while hovered, so this is how their
    /// state gets checked without a person watching.
    func logState() {
        FileHandle.standardError.write(Data("""
            [state] source \(source.map(String.init(describing:)) ?? "none") \
            liked \(liked.map(String.init) ?? "nil") \
            shuffling \(shuffling.map(String.init) ?? "nil") \
            repeating \(repeating.map(String.init) ?? "nil") \
            track \(title) — \(artist)\n
            """.utf8))
    }

    /// Whether Spotify's playback capabilities have to be asked about again.
    ///
    /// A rule rather than a condition inline, because the ask itself cannot be
    /// checked — it is a network round trip against a rate-limited endpoint —
    /// while WHEN to make it is exactly the part that was wrong. Both halves
    /// matter and pull opposite ways: miss a transition and a control lies about
    /// what it can do, ask on every poll and the endpoint throttles us.
    static func shouldAskPlayback(source: MusicSource, connected: Bool,
                                  playing: Bool, askedPlaying: Bool?) -> Bool {
        source == .spotify && connected && playing != askedPlaying
    }

    /// Spotify's shuffle and repeat, which arrive over the network rather than
    /// from the snapshot.
    ///
    /// Refreshed when the track changes, when playback starts or stops, and
    /// after a press. The middle one was missing and the omission was invisible:
    /// this comment used to end "which is every moment they can have moved
    /// without us", while `beginPolling` fifteen lines away already said the
    /// capabilities are restricted while playback is paused.
    private func askPlayback() {
        guard spotify.isConnected, spotify.canControlPlayback else { return }
        Task { @MainActor in
            let fresh = await spotify.playbackModes()
            guard self.source == .spotify else { return }
            // A pause answers 204, not "shuffle is off" — keep the last answer
            // rather than letting the toggles vanish with the music.
            let modes = SpotifyWeb.modes(from: fresh, keeping: self.webModes)
            self.webModes = modes
            self.shuffleBlocked = !(modes?.canShuffle ?? true)
            self.repeatBlocked = !(modes?.canRepeat ?? true)
            if self.pendingModes == nil {
                self.shuffling = modes?.shuffling
                self.repeating = modes?.repeating
            }
        }
    }

    // MARK: Artwork

    private func loadArtwork(for snap: TrackSnapshot) {
        artworkGeneration &+= 1
        let generation = artworkGeneration
        artworkTask?.cancel()

        artworkTask = Task { @MainActor [weak self] in
            guard let self else { return }

            // The cover Spotify said this track has.
            //
            // Its presence is the whole difference between "no artwork" and
            // "artwork we failed to fetch". Music hands back an image or
            // nothing, and nothing means the library has no cover for this
            // track — asking again cannot change that. A URL that WAS handed to
            // us and then would not download is a transport failure, and those
            // pass.
            let promised: URL? = snap.source == .spotify
                ? snap.artworkURL.flatMap(URL.init(string:))
                : nil

            var image: NSImage?
            // A Music read the deadline abandoned is a transport failure, not
            // "this track has no cover" — the two used to share one nil, so
            // the retry below could never fire for Music and one 5s stall left
            // the placeholder up for the whole track.
            var unanswered = false
            switch snap.source {
            case .music:
                switch await self.bridge.musicArtwork() {
                case .image(let i): image = i
                case .noCover:      break
                case .unanswered:   unanswered = true
                }
            case .spotify:
                if let promised { image = await Self.download(promised) }
            }

            guard await self.show(image, from: generation) else { return }

            // A cover that was promised and did not arrive — or asked of a
            // player that never answered.
            //
            // The panel is NOT held on the previous track's artwork while this
            // runs — `show` has already put the placeholder and the neutral
            // palette up, because a stale cover is the worse of the two wrongs
            // and this file names it below. What follows is a late arrival
            // swapping in over an honest placeholder, which is the one order
            // that is never a lie.
            //
            // The whole retry rides this same task, so it needs no state of its
            // own: the next track's `artworkTask?.cancel()` kills a sleeping
            // retry for free, and the generation guard inside `show` catches
            // anything already in flight.
            guard image == nil, promised != nil || unanswered else { return }
            var attempt = 1
            while let delay = Self.artworkRetryDelay(attempt: attempt) {
                try? await Task.sleep(for: .seconds(delay))
                guard !Task.isCancelled, generation == self.artworkGeneration else { return }
                var late: NSImage?
                if let promised {
                    late = await Self.download(promised)
                } else if case .image(let i) = await self.bridge.musicArtwork() {
                    late = i
                }
                if let late {
                    _ = await self.show(late, from: generation)
                    return
                }
                attempt += 1
            }
        }
    }

    /// Puts a fetched cover on screen. False means a newer track has already
    /// claimed the panel, which is the caller's signal to stop rather than go on
    /// fetching for a song that is no longer playing.
    private func show(_ image: NSImage?, from generation: Int) async -> Bool {
        // Superseded by a newer track while we were fetching.
        guard !Task.isCancelled, generation == artworkGeneration else { return false }

        // Skip identical artwork.
        //
        // Consecutive tracks from one album carry the same cover, and both
        // players hand it back as a fresh image object each time — so the
        // palette was re-extracted (a 24x24 downsample, bucket pass and
        // spread on every track change) and the whole colour field
        // re-animated to the values it already had. Hashing the TIFF is cheap
        // beside the extraction it avoids.
        //
        // Both off the main actor: the TIFF encode is O(source pixels) — tens
        // of megabytes for a full-resolution Music cover — and it was running
        // on the main thread inside the 0.52s track-entrance window, against a
        // 60fps mesh. Nothing touches the NSImage until the main-actor commit.
        let priorDigest = artworkDigest
        let hasArtwork = artwork != nil
        let work = Task.detached(priority: .userInitiated) {
            () -> (digest: Int?, palette: ArtworkPalette?, identical: Bool) in
            let digest = image?.tiffRepresentation?.hashValue
            if let digest, digest == priorDigest, hasArtwork {
                return (digest, nil, true)
            }
            return (digest, image.flatMap { ArtworkPalette.extract(from: $0) }, false)
        }
        let result = await work.value
        // Re-checked after the hop: a newer track may have claimed the panel
        // while the encode ran.
        guard !Task.isCancelled, generation == artworkGeneration else { return false }
        if result.identical { return true }
        artworkDigest = result.digest

        let newPalette = result.palette
        withAnimation(Motion.track) {
            artwork = image
            if let newPalette {
                palette = newPalette
            } else if image == nil {
                // No artwork at all: fall back to neutral rather than keeping
                // the last record's colour. A Spotify local file, or a cover
                // whose download failed, otherwise left the mesh field, the
                // rim glow and the progress trace all still
                // painting the PREVIOUS track — the shell confidently
                // claiming this song is a record it isn't. Art that exists but
                // cannot be rasterised still keeps the old palette, which is
                // the documented behaviour.
                palette = .fallback
            }
        }
        return true
    }

    /// How long to wait before asking again for a cover that was promised and
    /// did not arrive. Nil once there is no point asking again.
    ///
    /// A rule rather than a bound written into the loop, for the same reason
    /// `shouldAskPlayback` is one: the fetch itself is a network round trip and
    /// nothing headless can check it, while how many times and how long apart is
    /// exactly the part with a wrong answer available. Two wrong answers, in
    /// fact, pulling opposite ways — never asking again leaves a placeholder on
    /// a track that has a cover for as long as it plays, and asking forever
    /// hammers a CDN over a 404 that is never going to become an image.
    ///
    /// So: twice, widening. The first wait outlasts the blip that a six-second
    /// timeout usually is; the second outlasts a slower one, such as a network
    /// that is still coming back after a wake. Both land well inside the track
    /// that asked for the cover, which is the only window where an answer is
    /// still worth having.
    static func artworkRetryDelay(attempt: Int) -> TimeInterval? {
        switch attempt {
        case 1: 3
        case 2: 9
        default: nil
        }
    }

    private static func download(_ url: URL) async -> NSImage? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 6
        guard let (data, _) = try? await URLSession.shared.data(for: request) else { return nil }
        return NSImage(data: data)
    }

    // MARK: Transport

    /// Briefly drives the trace, so a skip reads as the bar finishing rather than
    /// as the position teleporting.
    ///
    /// Held only for the length of the run: the moment it clears, the trace falls
    /// back to the new track's real position with no animation, so the reset
    /// itself is never seen travelling backwards.
    private(set) var skipTrace: Double?

    /// Which way the last skip went, for the beat that fires when the new track
    /// actually arrives.
    ///
    /// The arrival is observed from the track token, which carries no direction —
    /// and an undirected surge would `max()` a flat-ish profile over a leaning
    /// one and erase the lean within one poll. So the direction is recorded at
    /// the press and consumed on arrival.
    @ObservationIgnored private var skipCommand: (direction: Double, at: Date)?

    /// Takes the direction if a skip is still recent, and forgets it either way.
    func consumeSkipDirection(within window: TimeInterval = 2) -> Double? {
        guard let c = skipCommand else { return nil }
        skipCommand = nil
        return Date().timeIntervalSince(c.at) < window ? c.direction : nil
    }
    private var flourishTask: Task<Void, Never>?

    private func flourish(to target: Double) {
        flourishTask?.cancel()
        // Start from where the bar actually is, or the run has nothing to travel.
        skipTrace = smoothProgress
        withAnimation(.easeIn(duration: 0.26)) { skipTrace = target }
        flourishTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(290))
            guard let self, !Task.isCancelled else { return }
            self.skipTrace = nil
        }
    }

    /// What we optimistically committed, and when.
    ///
    /// The burst poll fires immediately after a command and routinely reads the
    /// player *before* it has processed it. Applying that snapshot verbatim
    /// overwrote our optimistic value and snapped the UI back to the pre-command
    /// state — the pause button flicking back to play, the scrubber jumping to
    /// where the drag started — which is what made the transport feel unreliable.
    /// We hold our value until the player agrees or the grace window expires.
    private var pendingIsPlaying: (value: Bool, at: Date)?
    private var pendingPosition: (value: Double, at: Date)?
    private var pendingLiked: (value: Bool?, at: Date)?
    private var pendingModes: (shuffling: Bool?, repeating: Bool?, at: Date)?
    /// What the Web API last said about the Spotify track and player. The bridge
    /// cannot answer for either, so the snapshot's nil must not overwrite these.
    private var webModes: SpotifyWeb.Playback?
    private var webLiked: Bool?
    /// Which track the library has already been asked about.
    private var askedIdentity: String?
    /// The playing state `askPlayback` last asked about.
    ///
    /// Separate from `askedIdentity` because it moves independently: the
    /// capabilities are restricted while playback is stopped, and a pause
    /// changes no identity at all.
    private var askedPlaying: Bool?
    private static let commandGrace: TimeInterval = 1.0

    func playPause() {
        guard let source else { return }
        // The interpolation clock turns over with the state. Pausing keeps the
        // position the edge is actually showing, not the last poll's; resuming
        // elapses from NOW. Anchored at the last position change instead — and
        // a pause changes nothing — a resume elapsed the whole pause at once:
        // clamped to the track's end, the progress line ran all the way round
        // the panel's edge and snapped back on the next poll.
        position = smoothPosition
        positionAnchor = Date()
        // Optimistic: flip immediately, let the next poll reconcile. Waiting for
        // the player to answer makes the button feel broken.
        withAnimation(Motion.swap) { isPlaying.toggle() }
        pendingIsPlaying = (isPlaying, Date())
        bridge.playPause(source)
        refreshSoon()
    }

    func next() {
        guard let source else { return }
        bridge.next(source)
        skipCommand = (1, Date())
        // The trace runs OUT to the right, not back to the left. Skipping forward
        // finishes a track — that is what the gesture means — so the bar
        // completing says "done with that one" while snapping to zero said
        // "un-played it", which is not a thing that happened.
        flourish(to: 1)
        position = 0
        positionAnchor = Date()
        pendingPosition = (0, Date())
        refreshSoon()
    }

    func previous() {
        guard let source else { return }
        bridge.previous(source)
        skipCommand = (-1, Date())
        // Backwards runs back to the start, which is the same direction the
        // gesture goes.
        flourish(to: 0)
        position = 0
        positionAnchor = Date()
        pendingPosition = (0, Date())
        refreshSoon()
    }

    /// Only ever called when `liked` is non-nil, so there is no silent no-op.
    func toggleLike() {
        guard let source, let current = liked else { return }
        let next = !current
        liked = next
        pendingLiked = (next, Date())
        if source == .spotify {
            let id = identity
            // The same generation counter `askLibrary` uses, for the same
            // reason. Without it this continuation wrote `webLiked` and `liked`
            // with no idea which track it was about: press the heart, skip
            // before the PUT lands, and track A's library state is written onto
            // track B's heart — and it sticks, because `askedIdentity` is
            // already B so nothing re-asks, and the panel-open retry only fires
            // when `webLiked` is nil, which this write has just made it not.
            likeQuery &+= 1
            let query = likeQuery
            Task { @MainActor in
                let ok = await self.spotify.setSaved(next, trackID: id)
                guard query == self.likeQuery, id == self.identity else { return }
                guard ok else {
                    // Put it back if the API refused, rather than leaving the
                    // heart filled over a track that was never saved.
                    self.webLiked = current
                    self.liked = current
                    self.pendingLiked = nil
                    return
                }
                self.webLiked = next
                // `liked` too, and the hold released deliberately. Setting only
                // the cached answer left the press to be carried by the
                // optimistic hold alone, and that hold expires after
                // `commandGrace`. A PUT slower than one second therefore filled
                // the heart on the press, EMPTIED it at the next poll — which
                // read the pre-toggle `webLiked` — then refilled it when this
                // finally landed. A visible flicker on a press that succeeded.
                self.liked = next
                self.pendingLiked = nil
            }
            return
        }
        bridge.setLiked(next, source: source, identity: identity)
        refreshSoon()
    }

    func toggleShuffle() {
        guard let source, let current = shuffling, !shuffleBlocked else { return }
        shuffling = !current
        pendingModes = (!current, pendingModes?.repeating, Date())
        command(source, shuffling: !current)
    }

    func toggleRepeat() {
        guard let source, let current = repeating, !repeatBlocked else { return }
        repeating = !current
        pendingModes = (pendingModes?.shuffling, !current, Date())
        command(source, repeating: !current)
    }

    /// Spotify takes modes over the Web API and drops them over the bridge;
    /// Music is the other way round. Both put the glyph back if the player
    /// refuses, so the panel never keeps a state the player does not have.
    private func command(_ source: MusicSource, shuffling: Bool? = nil, repeating: Bool? = nil) {
        guard source == .spotify else {
            if let shuffling { bridge.setMode(.shuffle, shuffling, source: source) }
            if let repeating { bridge.setMode(.repeat, repeating, source: source) }
            return refreshSoon()
        }
        Task { @MainActor in
            let ok = await spotify.setMode(shuffling: shuffling, repeating: repeating)
            if !ok {
                self.pendingModes = nil
                if shuffling != nil { self.shuffling = self.webModes?.shuffling }
                if repeating != nil { self.repeating = self.webModes?.repeating }
                return
            }
            if let shuffling { self.webModes?.shuffling = shuffling }
            if let repeating { self.webModes?.repeating = repeating }
            self.askPlayback()
        }
    }

    /// A link to the track that means something outside this Mac.
    ///
    /// `identity` holds Spotify's own `spotify:track:` URI, which opens the app
    /// but is useless in a message. The https form is the same id addressed as a
    /// page, so it opens in a browser for someone without Spotify and deep-links
    /// for someone with it. Music has no public address for a track, so there is
    /// nothing honest to offer and the item is not shown.
    var shareURL: URL? {
        let prefix = "spotify:track:"
        guard identity.hasPrefix(prefix) else { return nil }
        return URL(string: "https://open.spotify.com/track/"
                   + identity.dropFirst(prefix.count))
    }

    /// Open the current track where it lives.
    ///
    /// Spotify's `identity` is already its `spotify:track:` URI, so this needs no
    /// ScriptingBridge round-trip at all; anything else goes through the bridge's
    /// reveal. The prefix is checked rather than assumed — `identity` falls back
    /// to a synthesised title/artist key when the player gives no id, and handing
    /// that to `NSWorkspace` would ask the system to open a nonsense scheme.
    func openInPlayer() {
        guard let source else { return }
        if identity.hasPrefix("spotify:"), let url = URL(string: identity) {
            NSWorkspace.shared.open(url)
            return
        }
        bridge.revealInPlayer(source)
    }

    func seek(toFraction fraction: Double) {
        guard let source, duration > 0 else { return }
        let target = min(max(fraction, 0), 1) * duration
        position = target
        positionAnchor = Date()
        pendingPosition = (target, Date())
        bridge.seek(source, to: target)
    }
}
