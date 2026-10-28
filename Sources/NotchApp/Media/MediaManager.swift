import AppKit
import CryptoKit
import SwiftUI
import Observation

/// Main-actor view model over `MediaBridge`.
///
///   * Polling is refcounted: the timer only runs while something on screen
///     needs it, so a collapsed idle notch costs nothing.
///   * Artwork and palette work is skipped unless the track identity changed.
///   * Very short "tracks" are notification chirps, not music, and are ignored.
@MainActor
@Observable
final class MediaManager {

    /// Keyed per display. With two notches a single shared `.notchExpanded` token
    /// would let one notch collapsing remove the token the other, still expanded,
    /// notch had just inserted.
    enum PollingSource: Hashable {
        case notchExpanded(String)
        case miniPlayer
    }

    // Presented state
    private(set) var title = ""
    private(set) var artist = ""
    private(set) var artists: [ArtistCredit] = []
    var artistLine: String { ArtistCredit.line(artists) }
    private(set) var isPlaying = false
    private(set) var duration: Double = 0
    private(set) var position: Double = 0
    private(set) var source: MusicSource?
    private(set) var artwork: NSImage?
    private(set) var palette: ArtworkPalette = .fallback
    private(set) var hasTrack = false
    /// `nil` when the source cannot report it, which is always the case for
    /// Spotify. The heart is shown only when this is non-nil.
    private(set) var liked: Bool?
    /// Player modes. `nil` means the player did not answer, and the control is
    /// not shown.
    private(set) var shuffling: Bool?
    private(set) var repeating: Bool?
    /// Offered but refused: Spotify restricts both modes in some playback
    /// contexts and says so in advance. The buttons stay visible and read as
    /// unavailable, so the panel does not look like it has lost them.
    private(set) var shuffleBlocked = false
    private(set) var repeatBlocked = false
    /// Bumped on every track change so views can retrigger entrance animations.
    private(set) var trackToken = 0
    /// The playing track's time-synced lyrics; nil when it has none, while they are
    /// looked up, and with the setting off.
    private(set) var lyrics: SyncedLyrics?
    /// False while a new track's lyrics are being looked up, for at most
    /// `lyricsPatience`. The panel holds its height meanwhile rather than shrinking
    /// on every skip and growing back a moment later.
    private(set) var lyricsSettled = true
    static let lyricsPatience: Duration = .seconds(1.5)
    @ObservationIgnored private var lyricsTask: Task<Void, Never>?
    @ObservationIgnored private var lyricsHold: Task<Void, Never>?
    /// The identity the lyrics on screen, or in flight, belong to.
    @ObservationIgnored private var lyricsIdentity = ""
    @ObservationIgnored private var lastSnapshot: TrackSnapshot?
    /// Set when a player is running but every snapshot comes back empty.
    private(set) var automationNote: String?
    private var emptyReads = 0
    /// Set when a player is running and taking events without answering them.
    /// No grant is missing in that case, so no settings pane can help.
    private(set) var stalledNote: String?
    private var stalledReads = 0

    /// How many consecutive unanswered polls before a stalled player is called
    /// one. The note and the clearing of the panel share this number so they
    /// happen on the same poll.
    static let stallPatience = 3

    /// Whether a poll that found no track should clear the panel or hold the
    /// last frame.
    ///
    /// A player that has stopped answering is not one with nothing to play, so
    /// the panel holds its track until the stall is named. `foundTrack` is not
    /// redundant with `stalled`: with two players polled, one can stall while
    /// the other plays, and holding the last frame would drop that snapshot.
    ///
    /// A pure function because `refresh()` needs a running player to reach it,
    /// so an assertion there would pass whatever the rule said.
    static func holdsLastFrame(stalled: Bool, foundTrack: Bool,
                               hasTrack: Bool, stalledReads: Int) -> Bool {
        stalled && !foundTrack && hasTrack && stalledReads < stallPatience
    }

    /// Among players that answered and none of which is playing, the one already
    /// on screen keeps the panel. Spotify is asked first, so without this,
    /// pausing Music while a paused Spotify sat behind it would hand the panel
    /// to Spotify. Pure for the same reason as `holdsLastFrame`.
    static func keepsPanel(_ snap: TrackSnapshot, over best: TrackSnapshot?,
                           showing: MusicSource?) -> Bool {
        guard let best else { return true }
        return snap.source == showing && best.source != showing
    }


    // Internals
    private let bridge: MediaBridge
    /// Spotify's like state lives behind the Web API; the local player can
    /// neither read nor write it.
    let spotify = SpotifyWeb()
    /// Guards against a stale library answer landing on a newer track.
    private var likeQuery = 0
    /// Same guard for Spotify's shuffle and repeat answers.
    private var playbackQuery = 0
    /// The newest heart write to Spotify's library; the next waits for it.
    @ObservationIgnored private var likeWrite: Task<Void, Never>?
    @ObservationIgnored private(set) var libraryTask: Task<Void, Never>?
    @ObservationIgnored private(set) var artistTask: Task<Void, Never>?
    private var artistGeneration = 0
    private var askedArtists = false
    private var artistLookupTask: Task<Void, Never>?
    private var musicArtistURLs: [String: URL] = [:]
    private var pollingSources: Set<PollingSource> = []
    private var timer: Task<Void, Never>?
    private var burst: Task<Void, Never>?
    private var identity = ""
    private var positionAnchor = Date()
    private var artworkTask: Task<Void, Never>?
    private var artworkGeneration = 0
    /// The generation whose answer (cover or none) is on screen, and the album it
    /// belongs to. A new album's slow cover must not leave the previous record
    /// under the new title; see `loadArtwork`.
    @ObservationIgnored private var artworkShown = 0
    @ObservationIgnored private var artworkAlbum = ""
    @ObservationIgnored private var artworkGraceTask: Task<Void, Never>?
    /// SHA-256 of the last artwork's bytes, so the same cover is not
    /// re-processed. Not `Data.hashValue`, which covers only the length and the
    /// first 80 bytes, so same-sized covers with a matching top edge would
    /// compare equal.
    private var artworkDigest: SHA256.Digest?
    // Touched in init and deinit only; deinit runs outside the actor.
    @ObservationIgnored private nonisolated(unsafe) var observers: [NSObjectProtocol] = []

    /// Anything shorter than this is a sound effect, not a song.
    private let transientDurationThreshold: Double = 6.0

    private var settings: Settings { .shared }

    init(bridge: MediaBridge = MediaBridge(), observePlayers: Bool = true) {
        self.bridge = bridge
        // The stored Spotify token is restored off the main thread, so the track
        // already on screen may have been applied while still "not connected".
        // Ask the library again once the connection lands.
        spotify.onConnect = { [weak self] in
            self?.askedIdentity = nil
            self?.askLibrary()
            self?.askedArtists = false
            self?.askArtists()
        }
        guard observePlayers else { return }
        // Apple Music broadcasts track changes, which beats polling.
        let center = DistributedNotificationCenter.default()
        observers.append(center.addObserver(
            forName: .init("com.apple.Music.playerInfo"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSoon(announced: true) }
        })
        observers.append(center.addObserver(
            forName: .init("com.spotify.client.PlaybackStateChanged"), object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshSoon(announced: true) }
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
        // Only a new token restarts the burst; re-inserting one on every
        // mouse-moved event would restart the refresh task continuously.
        guard pollingSources.insert(src).inserted else { return }
        if wasEmpty { startTimer() }
        // A library ask that failed (no network, expired token) still marked the
        // track as asked about, and `apply` will not ask twice. Opening the panel
        // is the retry, rather than the poll loop, so a persistent failure
        // cannot hammer a rate-limited endpoint once a second.
        if source == .spotify, webLiked == nil { askedIdentity = nil }
        // The same retry for the account lookup the mode controls depend on; see
        // `SpotifyWeb.refreshAccountIfUnknown`.
        Task { [spotify] in await spotify.refreshAccountIfUnknown() }
        refreshSoon()
        // Shuffle and repeat can change in Spotify itself, and are restricted
        // while playback is paused, so refresh them when the panel opens.
        askPlayback()
        if artists.allSatisfy({ $0.spotifyID == nil }) { askedArtists = false }
        askArtists()
    }

    func endPolling(_ src: PollingSource) {
        // The coordinator calls this for every collapsed host on every
        // system-wide mouse move, so check presence first: stopTimer() would
        // cancel the notification burst, the only detection path while the
        // notch is idle.
        guard pollingSources.remove(src) != nil else { return }
        if pollingSources.isEmpty { stopTimer() }
    }

    private func startTimer() {
        stopTimer()
        timer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                // 1 s suffices because position is interpolated between polls.
                // Paused behind the closed mini player nothing moves, and both
                // players announce play, pause and track changes themselves, so
                // the poll is only a backstop there.
                let idle = self.map { !$0.isPlaying && $0.pollingSources == [.miniPlayer] } ?? false
                try? await Task.sleep(for: .seconds(idle ? 5 : 1))
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

    /// Polls hard for a moment after a command.
    ///
    /// Players update their state a beat after applying a command, so at the
    /// idle 1 Hz poll the controls would feel dead. A short burst catches the new
    /// state almost immediately.
    ///
    /// `announced` is the player saying the change has already happened (both
    /// post a notification as they apply it), so the first read goes out at once
    /// and the later ones only catch what settles afterwards, such as the
    /// position. A press is different: the player has not moved yet, so the
    /// reads start early and keep coming. Measured with a skip in Spotify, the
    /// old fixed schedule left a 320 ms gap straddling the change and the panel
    /// showed the new track about 300 ms after Spotify had it.
    private func refreshSoon(announced: Bool = false) {
        burst?.cancel()
        let delays = announced ? [0, 150, 350, 700] : [40, 90, 180, 320, 600]
        burst = Task { @MainActor [weak self] in
            for delay in delays {
                if delay > 0 { try? await Task.sleep(for: .milliseconds(delay)) }
                guard let self, !Task.isCancelled else { return }
                await self.refresh()
            }
        }
    }

    // MARK: Refresh

    /// Which players to read, in order. In automatic mode a playing player wins
    /// over one that is merely running.
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
        // Which player would not answer, as opposed to having nothing to say.
        var mute: MusicSource?
        // Which player took the event and never answered it.
        var stalled: MusicSource?
        // Labelled because the early exit sits inside a `switch`, where a bare
        // `break` would leave the switch rather than the loop.
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

        // Only the freshest refresh may write. Nothing serialises them (the
        // timer, the burst and init all call refresh() independently) and a
        // playing snapshot applies sooner than a paused one, which waits on the
        // second source. Without this guard an older snapshot could undo a press
        // that had already landed. It covers the counters and notes too, so
        // stale refreshes cannot advance the patience counters out of order.
        guard generation == refreshGeneration else { return }

        // A player is open but every read came back empty: the signature of a
        // refused Automation grant, which otherwise leaves the panel saying
        // nothing is playing while music plays. Three consecutive polls rather
        // than three seconds, since a launch notification triggers a burst; this
        // rides out a player that answers late.
        // Keyed on the player that would not answer, not on finding no track:
        // a player that answers "stopped" has a working grant.
        if let src = mute, best == nil {
            emptyReads &+= 1
            if emptyReads >= 3, automationNote == nil {
                automationNote = "Can't read \(src.displayName)"
            }
        } else {
            emptyReads = 0
            if automationNote != nil { automationNote = nil }
        }

        // Same patience, separate counter: a player that says no and one that
        // says nothing are different faults with different remedies, and a
        // shared counter would let two faults, neither three polls old, add up
        // to an accusation.
        if let src = stalled, best == nil {
            stalledReads &+= 1
            if stalledReads >= Self.stallPatience, stalledNote == nil {
                stalledNote = "\(src.displayName) isn't answering"
            }
        } else {
            stalledReads = 0
            if stalledNote != nil { stalledNote = nil }
        }

        // The panel keeps what it has while the stall is inside its patience.
        // `.unreadable` is not treated the same way: the player answered, and
        // what it said is that there is nothing to show.
        if Self.holdsLastFrame(stalled: stalled != nil, foundTrack: best != nil,
                               hasTrack: hasTrack, stalledReads: stalledReads) { return }

        apply(best)
    }

    /// Internal so `tools/mediacheck.swift` can drive the real reconciliation
    /// path with synthetic snapshots instead of a live player.
    func apply(_ snap: TrackSnapshot?) {
        guard let snap else {
            guard hasTrack else { return }
            hasTrack = false
            isPlaying = false
            lastSnapshot = nil
            loadLyrics()
            source = nil
            title = ""; artist = ""
            resetArtists()
            duration = 0; position = 0
            identity = ""
            artwork = nil
            palette = .fallback
            liked = nil
            shuffling = nil
            repeating = nil
            // Losing the player is not pausing it: a kept answer would come
            // back on whatever plays next.
            webModes = nil
            webLiked = nil
            // The record of having asked goes with the answer. Otherwise the
            // same track returning after a blank is not a change, `apply` would
            // not ask again, and the heart and mode glyphs would stay absent.
            askedIdentity = nil
            askedPlaying = nil
            // The artwork pipeline dies with the track, as on a track change;
            // otherwise a slow download or sleeping retry could land the dead
            // track's cover on an empty panel.
            artworkTask?.cancel()
            artworkTask = nil
            artworkGeneration &+= 1
            artworkDigest = nil
            return
        }

        // Short items are not tracks: players surface notification chirps and
        // stingers through the same interface, and a panel that flips to them
        // is worse than one that misses them. A genuine sub-6 s track is skipped
        // too, which is the accepted trade.
        //
        // The track on screen is kept but marked not playing, since whatever is
        // playing now is not it; held as playing, its line would run to the end
        // and stay there.
        if snap.duration > 0, snap.duration < transientDurationThreshold {
            if isPlaying {
                position = smoothPosition
                positionAnchor = Date()
                pendingIsPlaying = nil
                withAnimation(Motion.swap) { isPlaying = false }
            }
            return
        }

        // Observation fires on assignment, not on change, so each write below is
        // compared first; this runs at poll rate. Values are still computed on
        // every poll because the mode flags' inputs move between identical
        // snapshots; only the no-op assignments are skipped.
        let changed = snap.identity != identity
        let creditsChanged = source != snap.source || changed || artist != snap.artist
        if !hasTrack { hasTrack = true }
        if source != snap.source {
            bridge.prewarm(snap.source)
            source = snap.source
        }
        if title != snap.title { title = snap.title }
        if artist != snap.artist { artist = snap.artist }
        if duration != snap.duration { duration = snap.duration }

        // A new track makes any pending seek moot, and discards the previous
        // track's library answer, which is about to be asked for again.
        if changed { pendingPosition = nil; pendingLiked = nil; webLiked = nil }

        // Optimistic hold, as in the transport: the heart fills on the press and
        // the poll may not argue with it until the player has had time to agree.
        // Spotify's answer comes from the Web API and is always nil in the
        // snapshot, so the snapshot must not overwrite it.
        let snapLiked = snap.source == .spotify ? webLiked : snap.liked
        if let pending = pendingLiked,
           Date().timeIntervalSince(pending.at) < Self.commandGrace,
           snapLiked != pending.value {
            // In flight: keep what was pressed.
        } else {
            pendingLiked = nil
            if liked != snapLiked { liked = snapLiked }
        }

        // Spotify: ask the Web API, and only about a track not yet asked about.
        // `apply` runs every poll and this is a network round trip against a
        // rate-limited endpoint. Keyed on the asked identity rather than
        // `changed` because the connection is restored after the first snapshot,
        // so on launch the track never "changes".
        if snap.source == .spotify, spotify.isConnected, snap.identity != askedIdentity {
            askLibrary(about: snap.identity)
        } else if snap.source == .spotify, !spotify.isConnected {
            liked = nil
            // Modes must go the same way. The bridge keeps delivering snapshots
            // after a disconnect, so a stale `webModes` would keep both glyphs
            // lit while `askPlayback` (which bails when disconnected) could not
            // correct them.
            webModes = nil
            askedPlaying = nil
        }

        // A pause also moves the capabilities. Shuffle and repeat are restricted
        // while playback is paused, and Spotify drops the desktop app off Connect
        // when the music stops (the 204 that `SpotifyWeb.modes(from:keeping:)`
        // handles). A pause is not a track change and `beginPolling` returns
        // early while the panel is open, so without this the flags would keep
        // recomputing from a stale `webModes`.
        //
        // Keyed on the snapshot's playing state rather than ours: `isPlaying`
        // holds optimistically through a press, and what matters is when the
        // player actually moved.
        if Self.shouldAskPlayback(source: snap.source, connected: spotify.isConnected,
                                  playing: snap.isPlaying, askedPlaying: askedPlaying) {
            askedPlaying = snap.isPlaying
            askPlayback()
        }

        // Modes hold optimistically too: they are a round trip away and the
        // glyph must light under the finger. Spotify's answer is the Web API's;
        // the bridge reports nil for it.
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
            // The player has not caught up yet: keep what the user asked for.
        } else {
            pendingPosition = nil
            // Skipped only when paused and unchanged. While playing, the anchor
            // must reset on every accepted snapshot or interpolation runs from
            // stale time; while paused it is never read. The snapshot's state
            // counts too, since a resume made in the player itself arrives with
            // `isPlaying` still false.
            if position != snap.position || isPlaying || snap.isPlaying {
                // A jump the player made (a seek in Spotify, a scrub on a phone) glides
                // there, like a seek made here; drift between polls is far under this.
                if !changed, duration > 0, skipTrace == nil,
                   abs(snap.position - smoothPosition) > 2.5 {
                    glide(to: snap.position / duration)
                }
                position = snap.position
                positionAnchor = Date()
            }
        }

        if let pending = pendingIsPlaying,
           Date().timeIntervalSince(pending.at) < Self.commandGrace,
           snap.isPlaying != pending.value {
            // Command in flight: do not undo it on screen.
        } else {
            pendingIsPlaying = nil
            if isPlaying != snap.isPlaying {
                withAnimation(Motion.swap) { isPlaying = snap.isPlaying }
            }
        }

        lastSnapshot = snap
        if changed {
            identity = snap.identity
            trackToken &+= 1
            loadArtwork(for: snap)
        }
        loadLyrics()
        if creditsChanged || (snap.source == .spotify && !spotify.isConnected && askedArtists) {
            resetArtists()
            artists = ArtistCredit.fallback(snap.artist, source: snap.source)
        }
        askArtists()
    }

    private func resetArtists() {
        artistGeneration &+= 1
        artistTask?.cancel()
        artistTask = nil
        artistLookupTask?.cancel()
        askedArtists = false
        if !artists.isEmpty { artists = [] }
    }

    private func askArtists() {
        guard source == .spotify, spotify.isConnected, !identity.isEmpty, !askedArtists else { return }
        askedArtists = true
        artistTask?.cancel()
        artistGeneration &+= 1
        let generation = artistGeneration
        let id = identity
        artistTask = Task { @MainActor [weak self, spotify] in
            let credits = await spotify.trackArtists(trackID: id)
            guard let self, !Task.isCancelled, self.artistGeneration == generation,
                  self.source == .spotify, self.identity == id, spotify.isConnected,
                  let credits, !credits.isEmpty else { return }
            self.artists = credits
        }
    }

    func openArtist(_ credit: ArtistCredit) {
        guard let source, artists.contains(credit) else { return }
        artistLookupTask?.cancel()
        if source == .spotify {
            let destination = spotify.isConnected ? credit : ArtistCredit(name: credit.name)
            NSWorkspace.shared.open(destination.url(in: source))
            return
        }
        let generation = artistGeneration
        artistLookupTask = Task { @MainActor [weak self] in
            guard let self else { return }
            // A split field may be one band ("Earth, Wind & Fire"). If the whole
            // field is a unique catalog artist, every fragment opens that band
            // rather than an unrelated artist sharing a fragment.
            let whole = ArtistCredit(name: self.artist)
            var resolved: URL?
            if self.artists.count > 1 {
                if let cached = self.musicArtistURLs[whole.name] { resolved = cached }
                else if let band = await whole.resolveMusicURL() {
                    self.musicArtistURLs[whole.name] = band
                    resolved = band
                }
            }
            if resolved == nil {
                if let cached = self.musicArtistURLs[credit.name] { resolved = cached }
                else { resolved = await credit.resolveMusicURL() }
            }
            guard !Task.isCancelled, generation == self.artistGeneration,
                  self.source == source, self.artists.contains(credit) else { return }
            if let resolved { self.musicArtistURLs[credit.name] = resolved }
            NSWorkspace.shared.open(resolved ?? credit.url(in: source))
        }
    }

    /// Looks up the current track's lyrics once per identity. Also called when the
    /// setting changes, so turning it on finds the song already playing.
    func loadLyrics() {
        guard settings.showsLyrics, let snap = lastSnapshot, !snap.identity.isEmpty else {
            lyricsTask?.cancel(); lyricsHold?.cancel()
            lyricsIdentity = ""
            if lyrics != nil { lyrics = nil }
            if !lyricsSettled { lyricsSettled = true }
            return
        }
        // Keyed on identity and length, so a failed lookup is not retried at poll rate
        // (the next play of the track asks again), and a track first read without its
        // length is asked about once the length arrives: unfiltered by length, a
        // lookup can pick a different edit whose stamps drift.
        let key = "\(snap.identity)|\(Int(snap.duration.rounded()))"
        guard key != lyricsIdentity else { return }
        lyricsIdentity = key
        lyricsTask?.cancel(); lyricsHold?.cancel()
        if lyrics != nil { lyrics = nil }
        guard snap.duration > 0 else {
            if !lyricsSettled { lyricsSettled = true }
            return
        }
        lyricsSettled = false
        let id = key
        lyricsTask = Task { @MainActor [weak self] in
            let answer = await LyricsSource.lyrics(title: snap.title, artist: snap.artist,
                                                   album: snap.album, duration: snap.duration)
            guard let self, !Task.isCancelled, self.lyricsIdentity == id else { return }
            if case .synced(let found) = answer { self.lyrics = found }
            self.lyricsHold?.cancel()
            if !self.lyricsSettled { self.lyricsSettled = true }
        }
        lyricsHold = Task { @MainActor [weak self] in
            try? await Task.sleep(for: Self.lyricsPatience)
            guard let self, !Task.isCancelled, self.lyricsIdentity == id else { return }
            if !self.lyricsSettled { self.lyricsSettled = true }
        }
    }

    /// Position interpolated from the last poll, evaluated at read time.
    ///
    /// Ticking a stored value on a timer advances the scrubber in visible steps.
    /// Anchoring to the last known position and elapsing real time lets a
    /// display-rate view read a continuous value.
    var smoothPosition: Double {
        guard isPlaying else { return position }
        let elapsed = position + Date().timeIntervalSince(positionAnchor)
        // Duration 0 is a live stream: it only removes the clamp, not the
        // interpolation.
        return duration > 0 ? min(duration, elapsed) : elapsed
    }

    var smoothProgress: Double {
        guard duration > 0.01 else { return 0 }
        return min(max(smoothPosition / duration, 0), 1)
    }

    /// Asks Spotify's library about a track. The query counter keeps a slow
    /// answer for an older track from landing on a newer one.
    private func askLibrary(about id: String? = nil) {
        guard let id = id ?? (source == .spotify ? identity : nil), !id.isEmpty,
              spotify.isConnected else { return }
        askedIdentity = id
        likeQuery &+= 1
        let query = likeQuery
        libraryTask = Task { @MainActor in
            let saved = await spotify.isSaved(trackID: id)
            // A late answer belongs only to the Spotify track that asked for it.
            guard query == self.likeQuery, self.source == .spotify,
                  id == self.identity else { return }
            self.webLiked = saved
            if self.pendingLiked == nil { self.liked = saved }
        }
        askPlayback()
    }

    /// The panel's claimed state on one stderr line. The controls live in a
    /// window that exists only while hovered, so this is how their state is
    /// checked without a person watching.
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
    /// A rule rather than an inline condition because the ask is a network
    /// round trip that cannot be checked headlessly, while when to make it can.
    /// Missing a transition makes a control misreport what it can do; asking on
    /// every poll gets the endpoint throttled.
    static func shouldAskPlayback(source: MusicSource, connected: Bool,
                                  playing: Bool, askedPlaying: Bool?) -> Bool {
        source == .spotify && connected && playing != askedPlaying
    }

    /// Spotify's shuffle and repeat, which arrive over the network rather than
    /// from the snapshot.
    ///
    /// Refreshed when the track changes, when playback starts or stops, when the
    /// panel opens, and after a press.
    private func askPlayback() {
        guard spotify.isConnected, spotify.canControlPlayback else { return }
        playbackQuery &+= 1
        let query = playbackQuery
        Task { @MainActor in
            let fresh = await spotify.playbackModes()
            // Only the newest ask may answer; an older reply landing after the
            // post-toggle one would flip the glyph back.
            guard query == self.playbackQuery, self.source == .spotify else { return }
            // A pause answers 204, not "shuffle is off". Keep the last answer
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

        // A different record: if its cover is not here within 0.3 s, show the
        // neutral placeholder rather than leave the last album's cover and
        // colours under the new title for the whole download (up to 6 s). The
        // grace stops a fast fetch flashing the placeholder; the same album
        // keeps its cover.
        artworkGraceTask?.cancel()
        let newRecord = snap.album.isEmpty || snap.album != artworkAlbum
        artworkAlbum = snap.album
        if newRecord, artwork != nil {
            artworkGraceTask = Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(300))
                guard let self, !Task.isCancelled,
                      generation == self.artworkGeneration,
                      self.artworkShown != generation else { return }
                self.artworkDigest = nil
                withAnimation(Motion.track) {
                    self.artwork = nil
                    self.palette = .fallback
                }
            }
        }

        artworkTask = Task { @MainActor [weak self] in
            guard let self else { return }

            // The cover URL Spotify promised for this track. Its presence
            // separates "no artwork" from "artwork we failed to fetch": Music
            // returns an image or nothing, and nothing means the library has no
            // cover, which asking again cannot change. A promised URL that will
            // not download is a transport failure and is retried.
            let promised: URL? = snap.source == .spotify
                ? snap.artworkURL.flatMap(URL.init(string:))
                : nil

            var image: NSImage?
            // A Music read the deadline abandoned is a transport failure, not
            // "no cover", and is retried below.
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

            // A cover that was promised and did not arrive, or was asked of a
            // player that never answered. `show` has already put the placeholder
            // and neutral palette up (a stale cover is the worse error), so a
            // late arrival swaps in over an honest placeholder.
            //
            // The retry rides this task and needs no state of its own: the next
            // track's `artworkTask?.cancel()` ends a sleeping retry, and the
            // generation guard inside `show` catches anything in flight.
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

    /// Puts a fetched cover on screen. False means a newer track has claimed
    /// the panel, which tells the caller to stop fetching.
    private func show(_ image: NSImage?, from generation: Int) async -> Bool {
        // Superseded by a newer track while fetching.
        guard !Task.isCancelled, generation == artworkGeneration else { return false }

        // Skip identical artwork. Consecutive tracks from one album carry the
        // same cover but both players return a fresh image object each time, so
        // without this the palette is re-extracted and the colour field
        // re-animated to the values it already had. Hashing the TIFF is cheap
        // beside that.
        //
        // Both run off the main actor: the TIFF encode is O(source pixels) and
        // would otherwise block the main thread during the track-entrance
        // animation. Nothing touches the NSImage until the main-actor commit.
        let priorDigest = artworkDigest
        let hasArtwork = artwork != nil
        let work = Task.detached(priority: .userInitiated) {
            () -> (digest: SHA256.Digest?, palette: ArtworkPalette?, identical: Bool) in
            let digest = image?.tiffRepresentation.map { SHA256.hash(data: $0) }
            if let digest, digest == priorDigest, hasArtwork {
                return (digest, nil, true)
            }
            return (digest, image.flatMap { ArtworkPalette.extract(from: $0) }, false)
        }
        let result = await work.value
        // Re-check after the hop: a newer track may have claimed the panel.
        guard !Task.isCancelled, generation == artworkGeneration else { return false }
        artworkShown = generation
        if result.identical { return true }
        artworkDigest = result.digest

        let newPalette = result.palette
        withAnimation(Motion.track) {
            artwork = image
            if let newPalette {
                palette = newPalette
            } else if image == nil {
                // No artwork at all (a Spotify local file, or a failed download):
                // fall back to neutral rather than keep painting the previous
                // record's colours. Art that exists but cannot be rasterised
                // keeps the old palette.
                palette = .fallback
            }
        }
        return true
    }

    /// How long to wait before asking again for a cover that was promised and
    /// did not arrive; nil once there is no point asking again.
    ///
    /// A rule for the same reason as `shouldAskPlayback`. Never retrying leaves
    /// a placeholder on a track that has a cover; retrying forever hammers a CDN
    /// over a 404. Two widening attempts: the first outlasts the usual blip
    /// behind a six-second timeout, the second a network still recovering from
    /// wake. Both land well inside the track that asked.
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

    /// Carries the trace to a new place in the same track with a settling spring.
    private func glide(to target: Double) {
        flourishTask?.cancel()
        skipTrace = smoothProgress
        withAnimation(Motion.glide) { skipTrace = min(max(target, 0), 1) }
        flourishTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(520))
            guard let self, !Task.isCancelled else { return }
            self.skipTrace = nil
        }
    }

    /// Briefly drives the trace so a skip reads as the bar finishing rather than
    /// the position teleporting. Held only for the length of the run; when it
    /// clears the trace falls back to the new track's position without
    /// animation, so the reset is never seen travelling backwards.
    private(set) var skipTrace: Double?

    /// Which way the last skip went, for the beat that fires when the new track
    /// arrives. Arrival is observed from the track token, which carries no
    /// direction, so the direction is recorded at the press and consumed then.
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

    /// Optimistically committed values and when they were set.
    ///
    /// The burst poll fires right after a command and often reads the player
    /// before it has processed it. Applying that snapshot would snap the UI back
    /// to the pre-command state, so each value is held until the player agrees or
    /// the grace window expires.
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
    /// The playing state `askPlayback` last asked about. Separate from
    /// `askedIdentity` because capabilities change with playback state while a
    /// pause changes no identity.
    private var askedPlaying: Bool?
    private static let commandGrace: TimeInterval = 1.0

    func playPause() {
        guard let source else { return }
        // The interpolation clock turns over with the state: pausing keeps the
        // position the edge is showing, and resuming elapses from now. Anchored
        // at the last position change instead, a resume would elapse the whole
        // pause at once.
        position = smoothPosition
        positionAnchor = Date()
        // Optimistic: flip now and let the next poll reconcile, since waiting
        // for the player makes the button feel broken.
        withAnimation(Motion.swap) { isPlaying.toggle() }
        pendingIsPlaying = (isPlaying, Date())
        bridge.playPause(source)
        refreshSoon()
    }

    func next() {
        guard let source else { return }
        bridge.next(source)
        skipCommand = (1, Date())
        // The trace runs out to the right: skipping forward finishes the track,
        // so the bar completing says "done with that one".
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
        // Backwards runs back to the start, the same direction as the gesture.
        flourish(to: 0)
        position = 0
        positionAnchor = Date()
        pendingPosition = (0, Date())
        refreshSoon()
    }

    /// Only called when `liked` is non-nil, so it is never a silent no-op.
    func toggleLike() {
        guard let source, let current = liked else { return }
        let next = !current
        liked = next
        pendingLiked = (next, Date())
        if source == .spotify {
            let id = identity
            // Same query counter as `askLibrary`: if the user skips before the
            // PUT lands, track A's library state must not be written onto track
            // B's heart, where nothing would re-ask.
            likeQuery &+= 1
            let query = likeQuery
            // One write at a time, in press order. Sent together, a press and
            // the press that undoes it are two requests racing to the server,
            // and the heart was seen filled over a track the library did not
            // hold (three presses back to back, no gap, left it saved-then-not
            // while the heart stayed on).
            let earlier = likeWrite
            likeWrite = Task { @MainActor in
                await earlier?.value
                let ok = await self.spotify.setSaved(next, trackID: id)
                guard query == self.likeQuery, id == self.identity else { return }
                guard ok else {
                    // Put it back if the API refused, rather than leave the
                    // heart filled over a track that was never saved, and read
                    // the library for the truth: with presses queued, the value
                    // before this one is not necessarily what the server holds.
                    self.webLiked = current
                    self.liked = current
                    self.pendingLiked = nil
                    self.askLibrary(about: id)
                    return
                }
                self.webLiked = next
                // Set `liked` and release the hold explicitly. The optimistic
                // hold expires after `commandGrace`, so a PUT slower than that
                // would let the next poll read the pre-toggle `webLiked` and
                // flicker the heart empty before this lands.
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
    /// Music is the other way round. Both restore the glyph if the player
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
    /// `identity` holds Spotify's `spotify:track:` URI, which opens the app but
    /// is useless in a message. The https form addresses the same id as a page,
    /// which opens in a browser or deep-links into the app. Music has no public
    /// address for a track, so nothing is offered for it.
    var shareURL: URL? {
        let prefix = "spotify:track:"
        guard identity.hasPrefix(prefix) else { return nil }
        return URL(string: "https://open.spotify.com/track/"
                   + identity.dropFirst(prefix.count))
    }

    /// Opens the current track where it lives.
    ///
    /// Spotify's `identity` is already its URI, so no ScriptingBridge round trip
    /// is needed; anything else goes through the bridge's reveal. The prefix is
    /// checked because `identity` falls back to a synthesised title/artist key
    /// when the player gives no id, which `NSWorkspace` cannot open.
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
