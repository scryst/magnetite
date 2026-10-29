import AppKit
import ScriptingBridge

/// One credited artist. A name remains useful when the catalog cannot answer.
struct ArtistCredit: Equatable, Sendable {
    var name: String
    var spotifyID: String? = nil

    static func validSpotifyID(_ id: String) -> Bool {
        id.utf8.count == 22 && id.utf8.allSatisfy {
            (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0)
        }
    }

    static func fallback(_ raw: String, source: MusicSource) -> [Self] {
        // Spotify's local name is authoritative until artists[] arrives. Music
        // has no credit list, so only separators in its artist field are read.
        let names: [String]
        if source == .music {
            // "feat." always separates credits. Each side is split on commas
            // only when it also contains " & ": Music writes a pair as "A & B"
            // and a list as "A, B & C", so a lone comma belongs to a name
            // ("Tyler, The Creator").
            let feat = "\u{1F}"
            let marked = raw
                .replacingOccurrences(
                    of: #"(?i)\s+[\(\[](?:feat\.?|ft\.?|featuring)\s+([^\)\]]+)[\)\]]"#,
                    with: "\(feat)$1", options: .regularExpression)
                .replacingOccurrences(
                    of: #"(?i)\s+(?:feat\.?|ft\.?|featuring)\s+"#,
                    with: feat, options: .regularExpression)
            names = marked.components(separatedBy: feat).flatMap { part in
                part.contains(" & ")
                    ? part.components(separatedBy: ",").flatMap { $0.components(separatedBy: " & ") }
                    : [part]
            }
        } else { names = [raw] }
        var seen = Set<String>()
        return names.compactMap { part in
            let name = part.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(name).inserted else { return nil }
            return Self(name: name)
        }
    }

    static func separator(before index: Int, count: Int) -> String {
        index == 0 ? "" : (index == count - 1 ? " & " : ", ")
    }

    static func line(_ artists: [Self]) -> String {
        artists.enumerated().map { separator(before: $0.offset, count: artists.count) + $0.element.name }.joined()
    }

    func url(in source: MusicSource) -> URL {
        if source == .spotify, let spotifyID, Self.validSpotifyID(spotifyID) {
            return URL(string: "spotify:artist:\(spotifyID)")!
        }
        let encoded = name.addingPercentEncoding(withAllowedCharacters:
            CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-._~"))!
        return URL(string: source == .spotify ? "spotify:search:\(encoded)"
                   : "music://music.apple.com/search?term=\(encoded)")!
    }

    /// A unique exact catalog match, never the first fuzzy search result.
    static func musicURL(from data: Data, named name: String) -> URL? {
        func normalized(_ s: String) -> String {
            s.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = json["results"] as? [[String: Any]] else { return nil }
        let matches = results.filter {
            ($0["wrapperType"] as? String) == "artist"
                && normalized($0["artistName"] as? String ?? "") == normalized(name)
        }
        guard matches.count == 1, let match = matches.first,
              let id = match["artistId"] as? Int, id > 0,
              let address = match["artistLinkUrl"] as? String, let url = URL(string: address),
              url.scheme == "https", url.host == "music.apple.com",
              url.user == nil, url.password == nil, url.port == nil,
              url.pathComponents.contains("artist"), url.lastPathComponent == String(id)
        else { return nil }
        var components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        components?.scheme = "music"
        return components?.url
    }

    func resolveMusicURL() async -> URL? {
        var query = URLComponents(string: "https://itunes.apple.com/search")!
        query.queryItems = [URLQueryItem(name: "term", value: name),
                           URLQueryItem(name: "media", value: "music"),
                           URLQueryItem(name: "entity", value: "musicArtist"),
                           URLQueryItem(name: "attribute", value: "artistTerm"),
                           URLQueryItem(name: "limit", value: "10")]
        guard let url = query.url,
              let (data, response) = try? await URLSession.shared.data(for: URLRequest(url: url, timeoutInterval: 4)),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return Self.musicURL(from: data, named: name)
    }
}

/// Immutable snapshot of a player's state, safe to hand to the main actor.
struct TrackSnapshot: Equatable, Sendable {
    var source: MusicSource
    var title: String = ""
    var artist: String = ""
    var album: String = ""
    var isPlaying: Bool = false
    var duration: Double = 0
    var position: Double = 0
    /// Stable per-track key. Artwork work is skipped while it is unchanged, so a
    /// poll does not re-decode the same cover.
    var identity: String = ""
    var artworkURL: String?
    /// Whether the track is favourited, or `nil` when the source cannot say.
    ///
    /// Spotify's dictionary declares `starred` as `access="r"` and reading it
    /// fails at runtime (-10000), so over ScriptingBridge the answer is
    /// unavailable, not merely unwritable. The interface shows no heart for `nil`.
    var liked: Bool?
    /// Per-player state rather than per-track, so read from the app object.
    /// `nil` if the player did not answer.
    var shuffling: Bool?
    var repeating: Bool?
}

enum MusicSource: String, Sendable, CaseIterable {
    case spotify
    case music

    var bundleID: String {
        switch self {
        case .spotify: return "com.spotify.client"
        case .music:   return "com.apple.Music"
        }
    }

    var displayName: String {
        switch self {
        case .spotify: return "Spotify"
        case .music:   return "Music"
        }
    }
}

/// Talks to the players over ScriptingBridge.
///
/// Never call this from the main actor. ScriptingBridge is synchronous IPC and
/// blocks the caller while the target app is busy or hung. Objects are confined
/// to private serial queues and connections carry an explicit send timeout.
final class MediaBridge: @unchecked Sendable {

    /// An inert bridge answers nothing and commands nothing.
    ///
    /// `tools/mediacheck.swift` drives a real `MediaManager` whose toggles
    /// dispatch through here; with a live player the check would otherwise send
    /// real Apple Events and favourite the user's current track. Nothing in the
    /// app constructs one.
    private let inert: Bool

    /// Replaces the ScriptingBridge read. Only `tools/mediacheck.swift` passes
    /// one, to exercise the watchdog with a read that never returns.
    private let stubbedRead: (@Sendable (MusicSource) -> Read)?

    /// Replaces the ScriptingBridge command. Only `tools/mediacheck.swift` passes
    /// one, to press a control whose player never answers.
    private let stubbedCommand: (@Sendable (MusicSource) -> Void)?

    init(inert: Bool = false,
         stubbedRead: (@Sendable (MusicSource) -> Read)? = nil,
         stubbedCommand: (@Sendable (MusicSource) -> Void)? = nil) {
        self.inert = inert
        self.stubbedRead = stubbedRead
        self.stubbedCommand = stubbedCommand
    }

    /// What a lane serves. Each key has its own queue, abandonment budget and
    /// connections, so a wedge costs only the thing that wedged: a hung Spotify
    /// cannot block Music's reads, a slow Music cover cannot block the poll, and
    /// one player quitting cannot refund the other's parked threads.
    private enum LaneKey: Hashable {
        case poll(MusicSource)
        case artwork
        case command(MusicSource)

        /// Used in the dispatch queue label so a `sample` of a wedged process
        /// names the player and purpose.
        var label: String {
            switch self {
            case .poll(let s):    return "read.\(s.rawValue)"
            case .artwork:        return "artwork"
            case .command(let s): return "cmd.\(s.rawValue)"
            }
        }

        /// Commands are what the user is waiting on; reads are not.
        var qos: DispatchQoS {
            if case .command = self { return .userInteractive }
            return .utility
        }

        /// Reads get a short leash so a slow player cannot back up the poll;
        /// commands get more room, since they must not be dropped.
        var timeoutTicks: Int {
            switch self {
            case .command: return MediaBridge.cmdTimeoutTicks
            // A large cover can outlast the poll's leash and would otherwise be
            // filed as having no artwork.
            case .artwork: return MediaBridge.artworkTimeoutTicks
            case .poll:    return MediaBridge.readTimeoutTicks
            }
        }

        /// How long before the caller is answered without the call, or the
        /// command given up on. Twice the connection's leash, so a merely slow
        /// player is not mistaken for a silent one.
        var deadline: TimeInterval {
            switch self {
            case .poll:    return MediaBridge.readDeadline
            // Music returns the image through the bridge rather than a URL, and
            // a large cover legitimately takes a moment.
            case .artwork: return 5
            case .command: return 4
            }
        }
    }

    /// One generation of one lane: a queue and the connections that belong only
    /// to it.
    ///
    /// A lane exists so a call that never returns can be abandoned rather than
    /// waited on. The parked thread keeps its own lane and connections, so
    /// nothing it touches later is state the next lane reads.
    ///
    /// `@unchecked` because confinement is the design: `apps` is only touched on
    /// `queue`, and the remaining fields only under the bridge's `lock`.
    private final class Lane: @unchecked Sendable {
        let queue: DispatchQueue
        let timeoutTicks: Int
        /// Only ever touched on `queue`.
        var apps: [MusicSource: MediaPlayerApp] = [:]

        /// The accounting epoch in which the lane was abandoned. An epoch rather
        /// than a flag: `invalidate` can restore the whole budget while a thread
        /// is still parked, and that thread must not hand a seat back to a budget
        /// that has already been restored.
        var retiredIn: Int?
        /// The head of this queue is not coming back and no budget is left to
        /// open a fresh lane. Later calls are refused instead of piling blocks
        /// behind a thread that will never run them.
        var blocked = false
        /// One block is waiting behind that head, to run if the wedge clears. At
        /// most one: it is a recovery probe, not a queue.
        var probePending = false

        init(_ key: LaneKey, _ generation: Int) {
            queue = DispatchQueue(label: "magnetite.media.\(key.label).\(generation)",
                                  qos: key.qos)
            timeoutTicks = key.timeoutTicks
        }
    }

    /// One key's lane and the accounting that belongs to it alone.
    private struct LaneGroup {
        var lane: Lane
        /// Lanes of this key whose thread is still inside a send that never
        /// answered.
        var abandoned = 0
        /// Bumped whenever this key's budget is returned wholesale, so seats are
        /// only given back to the budget they were taken from.
        var epoch = 0
        var generation = 0
    }

    /// Answers its caller exactly once, for whichever of the call and the
    /// deadline gets there first, and tells the loser that it lost.
    ///
    /// `@unchecked` because the raced value can be an `NSImage`, which is not
    /// `Sendable`; it is handed to exactly one of two callers under the lock.
    private final class Race<T>: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<T, Never>?
        init(_ continuation: CheckedContinuation<T, Never>) {
            self.continuation = continuation
        }
        /// Wins the race without answering yet, so the winner can put the bridge
        /// in order before its caller is free to make the next call. `nil` when
        /// someone else got there first.
        ///
        /// The deadline relies on this: retiring the lane before answering
        /// ensures the caller's next read is not dispatched onto the wedged lane.
        func claim() -> CheckedContinuation<T, Never>? {
            lock.lock(); defer { lock.unlock() }
            guard let c = continuation else { return nil }
            continuation = nil
            return c
        }

        /// `true` when this call is the one that answered.
        @discardableResult
        func resume(_ value: T) -> Bool {
            guard let c = claim() else { return false }
            c.resume(returning: value)
            return true
        }
    }

    /// `Race` with nothing to answer. A command is fire-and-forget, so its
    /// deadline only needs to know whether it got there first.
    private final class Gate: @unchecked Sendable {
        private let lock = NSLock()
        private var open = true
        /// `true` when this call is the one that got there first.
        func close() -> Bool {
            lock.lock(); defer { lock.unlock() }
            guard open else { return false }
            open = false
            return true
        }
    }

    private let lock = NSLock()
    private var groups: [LaneKey: LaneGroup] = [:]

    /// Timers only. A ScriptingBridge call here could wedge the watchdog behind
    /// the thing it is watching.
    private static let watchdog = DispatchQueue(label: "magnetite.media.watchdog",
                                                qos: .utility)

    /// How long a read may take before its caller is answered without it.
    ///
    /// Twice the connection's own leash. It is longer than the 1 s poll, which
    /// is fine: each player's poll has its own lane, so a stalled read delays
    /// only that player's next read, and the panel keeps its last frame.
    ///
    /// Not private: `tools/mediacheck.swift` measures against it.
    static let readDeadline: TimeInterval = 1.5

    /// How many threads may be left parked inside a send that never answered,
    /// per key.
    ///
    /// Each abandoned lane costs one thread that never returns, so past this
    /// the bridge stops opening lanes for that key. The worst case is
    /// `maxAbandoned + 1` threads per key, since the current lane's thread may
    /// be parked too; later calls queue onto the blocked lane at most one at a
    /// time (`probePending`). See `invalidate`: a player that quits or
    /// relaunches returns its budget.
    ///
    /// Not private: the check counts to the cap.
    static let maxAbandoned = 2

    /// ScriptingBridge timeouts are in ticks (1/60 s).
    ///
    /// The read timeout cannot be relied on: a read has been seen pinned inside
    /// `AESendMessage` for over an hour, the player having accepted the event and
    /// never answered, without the connection's timeout firing. That is why
    /// every call also carries its own deadline.
    fileprivate static let readTimeoutTicks = 45     // 0.75s
    fileprivate static let cmdTimeoutTicks = 120     // 2s
    fileprivate static let artworkTimeoutTicks = 150 // 2.5s
    /// errAETimeout: the leash above ran out before the player answered.
    fileprivate static let eventTimedOut = -1712

    static func isRunning(_ source: MusicSource) -> Bool {
        runningInstance(source) != nil
    }

    /// The live process, if there is one. A player mid-quit stays listed until
    /// it has fully gone, so a terminated entry does not count.
    static func runningInstance(_ source: MusicSource) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: source.bundleID)
            .first { !$0.isTerminated }
    }

    /// How many of this player's poll lanes have a thread still parked inside a
    /// send that never answered. For `tools/mediacheck.swift`, which asserts on
    /// the count directly rather than inferring it from later refusals.
    func parkedPollLanes(for source: MusicSource) -> Int {
        lock.lock(); defer { lock.unlock() }
        return groups[.poll(source)]?.abandoned ?? 0
    }

    /// The lane a call should run on, or `nil` when it must be refused.
    ///
    /// The head block of a blocked lane is known not to be coming back and a
    /// probe is already waiting behind it, so queueing more would only add
    /// blocks (each holding a continuation and its captures) that never run.
    private func admit(_ key: LaneKey) -> Lane? {
        lock.lock(); defer { lock.unlock() }
        // `let` suffices for the lane flags (a class), but the group must be
        // written back for a key seen for the first time.
        let g = groups[key] ?? LaneGroup(lane: Lane(key, 0))
        defer { groups[key] = g }
        guard g.lane.blocked else { return g.lane }
        guard !g.lane.probePending else { return nil }
        g.lane.probePending = true
        return g.lane
    }

    /// Gives up on the lane a call was abandoned in, so the next call does not
    /// queue behind a thread that is never coming back.
    ///
    /// Only called for a call whose own block had not finished at its deadline
    /// (see the `Gate` each call carries). The identity check rejects all but
    /// the first of several calls timing out on one lane.
    private func retire(_ dead: Lane, key: LaneKey) {
        lock.lock(); defer { lock.unlock() }
        guard var g = groups[key], dead === g.lane else { return }
        guard g.abandoned < Self.maxAbandoned else {
            dead.blocked = true
            return
        }
        dead.retiredIn = g.epoch
        g.abandoned += 1
        g.generation += 1
        g.lane = Lane(key, g.generation)
        groups[key] = g
    }

    /// A block came back. That alone frees the lane for normal use; whether it
    /// beat its deadline decides whether a seat is refunded.
    ///
    /// The seat stamp is cleared as the seat is returned, so calls queued behind
    /// it on the same serial queue cannot each claim it again, and a stamp from
    /// a spent epoch is dropped without a refund.
    private func finished(_ old: Lane, key: LaneKey, late: Bool) {
        lock.lock(); defer { lock.unlock() }
        // Whatever was in front of this block has cleared.
        old.blocked = false
        old.probePending = false
        guard late else { return }
        guard let takenIn = old.retiredIn else { return }
        old.retiredIn = nil
        guard var g = groups[key], takenIn == g.epoch, g.abandoned > 0 else { return }
        g.abandoned -= 1
        groups[key] = g
    }

    /// Must be called on `lane.queue`.
    private func app(_ source: MusicSource, on lane: Lane) -> MediaPlayerApp? {
        if let a = lane.apps[source] { return a }
        let a = connect(source, timeout: lane.timeoutTicks)
        lane.apps[source] = a
        return a
    }

    /// Aimed at the running process, never at the bundle ID.
    ///
    /// An app object made from a bundle ID launches its target whenever an event
    /// is sent and the target is not running, which would reopen a player the
    /// user is quitting (it posts events as it exits). An event sent to a PID
    /// that has exited simply fails. Lanes are replaced on every launch and quit
    /// (`invalidate`), so a relaunched player gets a fresh object.
    private func connect(_ source: MusicSource, timeout: Int) -> MediaPlayerApp? {
        guard let running = Self.runningInstance(source),
              let raw = SBApplication(processIdentifier: running.processIdentifier)
        else { return nil }
        raw.timeout = timeout
        return raw as MediaPlayerApp
    }

    /// The player's own key for a track, read through KVC. Under `id` Spotify
    /// answers a `spotify:track:` URI and Music an integer database id, and a
    /// typed `String` read of Music's integer crashes. Music's text key is
    /// `persistentID`, which also survives a library rebuild. Spotify's stays
    /// `id` because `openInPlayer` builds its URL from it.
    private static func trackKey(of track: MediaTrack, source: MusicSource) -> String? {
        let key = source == .spotify ? "id" : "persistentID"
        guard let value = (track as? NSObject)?.value(forKey: key) as? String,
              !value.isEmpty else { return nil }
        return value
    }

    /// Spotify reports milliseconds and Music seconds under one selector, so the
    /// value is read untyped and normalised to seconds here.
    private func duration(of track: MediaTrack, source: MusicSource) -> Double {
        guard let value = (track as? NSObject)?.value(forKey: "duration") as? NSNumber
        else { return 0 }
        return source == .spotify ? value.doubleValue / 1000.0 : value.doubleValue
    }

    /// Opens the command connection before it is needed. The first call on a
    /// fresh connection pays for the Apple Event handshake, which would make the
    /// first button press noticeably slower.
    func prewarm(_ source: MusicSource) {
        // Opening the connection is what the lane does on the way to running a
        // command, so an empty body is the whole warm-up.
        command(source) { _ in }
    }

    /// A player that launched or quit invalidates more than its connection.
    ///
    /// A parked thread is waiting on a process that is no longer the one being
    /// asked, so that player's budget is returned in full and its lanes start
    /// clean. This is the only recovery once every seat is taken. It applies to
    /// that player alone; otherwise a quitting Music would refund Spotify's
    /// parked threads and the budget would bound nothing.
    func invalidate(_ source: MusicSource) {
        var keys: [LaneKey] = [.poll(source), .command(source)]
        // Artwork only ever asks Music, so only Music invalidates it.
        if source == .music { keys.append(.artwork) }

        lock.lock(); defer { lock.unlock() }
        for key in keys {
            guard var g = groups[key] else { continue }
            g.abandoned = 0
            g.epoch += 1
            g.generation += 1
            // Replace the lane rather than clearing its proxies in place: a
            // clean-up dispatched onto a lane with a parked thread would never
            // run.
            g.lane = Lane(key, g.generation)
            groups[key] = g
        }
    }

    /// What a read found, which is not the same question as what is playing.
    ///
    /// The caller must tell an idle player (nothing queued) from one that will
    /// not answer; treating both as failure would accuse the user of denying an
    /// Automation grant they had given.
    enum Read {
        case track(TrackSnapshot)
        /// Running, answering, and playing nothing.
        case idle
        /// Refused: the Automation grant is denied, or the player quit mid-read.
        case unreadable
        /// Accepted the event and never answered. Distinct from a refusal because
        /// the Automation settings pane offered for `unreadable` cannot unstick a
        /// player that is not replying.
        case unanswered
    }

    /// Reads the player, or gives up on it.
    ///
    /// The deadline is enforced here rather than on the connection because the
    /// connection's own timeout can fail to fire (see `readTimeoutTicks`). The
    /// caller is answered without the blocked call and the thread is left where
    /// it stands. `MediaManager.refresh()` awaits this call, so an unbounded read
    /// would stop the poll loop.
    func read(for source: MusicSource) async -> Read {
        let key = LaneKey.poll(source)
        return await withCheckedContinuation { continuation in
            let race = Race(continuation)
            guard let lane = admit(key) else { race.resume(.unanswered); return }
            // Not redundant with the race: the race says who answered the
            // caller, this says whether this call's block ever came back, which
            // is what justifies retiring the lane under it.
            let done = Gate()

            lane.queue.async { [weak self] in
                guard let self else { race.resume(.unanswered); return }
                let result = self.readSync(for: source, on: lane)
                race.resume(result)
                self.finished(lane, key: key, late: !done.close())
            }

            // Armed here rather than at the top of the block above: a block
            // queued behind a wedge never starts, so would never arm a deadline
            // and its caller would wait forever.
            Self.watchdog.asyncAfter(deadline: .now() + key.deadline) { [weak self] in
                // Lost the race: the read answered in time.
                guard let answer = race.claim() else { return }
                // Retire before answering, so the caller's next poll is not
                // dispatched onto the lane that just failed it, and only if this
                // call's block is still in there.
                if done.close() { self?.retire(lane, key: key) }
                answer.resume(returning: .unanswered)
            }
        }
    }

    private func readSync(for source: MusicSource, on lane: Lane) -> Read {
        if let stubbedRead { return stubbedRead(source) }
        guard !inert else { return .unreadable }
        guard Self.isRunning(source) else {
            lane.apps[source] = nil
            return .unreadable
        }
        return snapshot(source, on: lane)
    }

    private func snapshot(_ source: MusicSource, on lane: Lane) -> Read {
        guard let app = app(source, on: lane) else { return .unreadable }
        // Read before the track guards: it is the only property that separates
        // "answering, nothing queued" from "will not answer".
        guard let state = app.playerState else { return .unreadable }
        // ScriptingBridge answers a scalar it could not fetch with 0 rather than
        // nil, and the track proxy then reads empty, which would look like
        // `.idle`. No player state is 0, so 0 means failure; the error says
        // which kind.
        if state == 0 {
            let error = (app as? SBObject)?.lastError() as NSError?
            return error?.code == Self.eventTimedOut ? .unanswered : .unreadable
        }
        guard let track = app.currentTrack else { return .idle }
        let title = track.name ?? ""
        let artist = track.artist ?? ""
        guard !title.isEmpty || !artist.isEmpty else { return .idle }

        var s = TrackSnapshot(source: source)
        s.title = title
        s.artist = artist
        s.album = track.album ?? ""
        s.isPlaying = state == PlayerState.playing
        s.duration = duration(of: track, source: source)
        s.position = app.playerPosition ?? 0
        s.artworkURL = track.artworkUrl
        s.identity = Self.trackKey(of: track, source: source)
            ?? "\(title)\u{1}\(artist)\u{1}\(s.album)"
        // Spotify's modes are not read here at all: its writes are silently
        // dropped by the local player, so shuffle and repeat go over the Web API
        // and `MediaManager.apply` takes Spotify's answer from there. Each mode
        // read is an Apple Event Spotify serves on its main thread (about 8 ms
        // apiece), so four reads nobody used made every poll a third longer and
        // delayed the press that arrived behind it.
        if source == .music {
            s.shuffling = Self.shuffleState(app, source: source)
            s.repeating = Self.repeatState(app, source: source)
        }
        s.liked = source == .music
            ? (track as? NSObject)?.value(forKey: "favorited") as? Bool
            : nil
        return .track(s)
    }

    /// What a Music artwork read said. A library with no cover has answered and
    /// asking again cannot change it; a read the watchdog abandoned, or a lane
    /// too wedged to admit, never answered and should be retried.
    enum ArtworkAnswer {
        case image(NSImage)
        /// The player answered: this track has no cover.
        case noCover
        /// The deadline fired or the lane was refused.
        case unanswered
    }

    /// Apple Music artwork comes back as an `NSImage` through the bridge, which
    /// is expensive; call this only when the track identity has changed.
    ///
    /// Runs on its own lane, so a slow cover cannot block the poll queue.
    func musicArtwork() async -> ArtworkAnswer {
        let key = LaneKey.artwork
        return await withCheckedContinuation { continuation in
            let race = Race(continuation)
            guard let lane = admit(key) else { race.resume(.unanswered); return }
            let done = Gate()

            lane.queue.async { [weak self] in
                guard let self else { race.resume(.unanswered); return }
                let image = self.artworkSync(on: lane)
                race.resume(image.map(ArtworkAnswer.image) ?? .noCover)
                self.finished(lane, key: key, late: !done.close())
            }

            Self.watchdog.asyncAfter(deadline: .now() + key.deadline) { [weak self] in
                guard let answer = race.claim() else { return }
                if done.close() { self?.retire(lane, key: key) }
                answer.resume(returning: .unanswered)
            }
        }
    }

    private func artworkSync(on lane: Lane) -> NSImage? {
        guard !inert, Self.isRunning(.music),
              let app = app(.music, on: lane),
              let track = app.currentTrack,
              let artworks = track.artworks?(),
              artworks.count > 0,
              let art = artworks.object(at: 0) as? MediaArtwork
        else { return nil }

        return Self.image(from: art.data) ?? Self.image(from: art.rawData)
    }

    /// A cover from whatever ScriptingBridge handed back (see `MediaArtwork`).
    static func image(from value: AnyObject?) -> NSImage? {
        switch value {
        case let image as NSImage: image.isValid ? image : nil
        case let data as Data: NSImage(data: data)
        case let event as NSAppleEventDescriptor: NSImage(data: event.data)
        default: nil
        }
    }

    // MARK: Modes

    /// Spotify uses plain booleans; Music uses `shuffle enabled` and a
    /// three-state `song repeat` enum. Read through KVC because one selector
    /// cannot cover both shapes.
    private static func key(_ mode: Mode, _ source: MusicSource) -> String {
        switch (mode, source) {
        case (.shuffle, .spotify): return "shuffling"
        case (.shuffle, .music):   return "shuffleEnabled"
        case (.repeat, .spotify):  return "repeating"
        case (.repeat, .music):    return "songRepeat"
        }
    }

    enum Mode { case shuffle, `repeat` }

    /// Music's repeat is off / one / all. It is collapsed to a boolean and
    /// written back as `all`, since the panel has a single glyph.
    private static let repeatOff: UInt32 = 0x6b52_704f   // 'kRpO'
    private static let repeatAll: UInt32 = 0x6b41_6c6c   // 'kAll'

    private static func shuffleState(_ app: MediaPlayerApp, source: MusicSource) -> Bool? {
        (app as? NSObject)?.value(forKey: key(.shuffle, source)) as? Bool
    }

    private static func repeatState(_ app: MediaPlayerApp, source: MusicSource) -> Bool? {
        guard let raw = (app as? NSObject)?.value(forKey: key(.repeat, source)) else { return nil }
        if source == .spotify { return raw as? Bool }
        guard let code = (raw as? NSNumber)?.uint32Value else { return nil }
        return code != repeatOff
    }

    /// Runs every command: one lane per player, a deadline, and a lane that can
    /// be abandoned. A command is the same synchronous IPC as a read and can
    /// wedge the same way, so a stuck `playpause` must not own later presses.
    private func command(_ source: MusicSource,
                         _ body: @escaping @Sendable (MediaPlayerApp) -> Void) {
        guard !inert || stubbedCommand != nil else { return }
        let key = LaneKey.command(source)
        guard let lane = admit(key) else { return }
        let gate = Gate()
        let expiry = DispatchTime.now() + key.deadline

        lane.queue.async { [weak self] in
            guard let self else { return }
            // A press that outlived its deadline behind a wedged player is
            // dropped; delivered minutes later it would be an unwanted skip.
            if DispatchTime.now() < expiry {
                if let stubbedCommand = self.stubbedCommand {
                    stubbedCommand(source)
                } else if Self.isRunning(source), let app = self.app(source, on: lane) {
                    body(app)
                }
            }
            self.finished(lane, key: key, late: !gate.close())
        }

        // No continuation is waiting on a press; the deadline exists only to
        // abandon the lane so the next press does not queue behind this one.
        Self.watchdog.asyncAfter(deadline: .now() + key.deadline) { [weak self] in
            guard gate.close() else { return }
            self?.retire(lane, key: key)
        }
    }

    func setMode(_ mode: Mode, _ on: Bool, source: MusicSource) {
        command(source) { app in
            guard let app = app as? NSObject else { return }
            let value: Any = (mode == .repeat && source == .music)
                ? NSNumber(value: on ? Self.repeatAll : Self.repeatOff)
                : on
            app.setValue(value, forKey: Self.key(mode, source))
        }
    }

    // MARK: Library

    /// Writes the favourite through KVC rather than `MediaPlayerApp`: Music
    /// renamed `loved` to `favorited`, and Spotify's nearest equivalent is
    /// read-only, so no single declaration satisfies both apps.
    ///
    /// `identity` is the pressed track's key. The body re-derives the live
    /// track's key exactly as `snapshot` does before writing, because the
    /// command runs later than the press (Music may have auto-advanced, or an
    /// abandoned lane may replay the body late) and `currentTrack` resolves at
    /// event receipt. The check narrows that race to milliseconds rather than
    /// closing it.
    func setLiked(_ liked: Bool, source: MusicSource, identity: String) {
        guard source == .music else { return }
        command(source) { app in
            guard let track = app.currentTrack else { return }
            let name = track.name ?? ""
            let artist = track.artist ?? ""
            let album = track.album ?? ""
            let live = Self.trackKey(of: track, source: source)
                ?? "\(name)\u{1}\(artist)\u{1}\(album)"
            guard live == identity, let obj = track as? NSObject else { return }
            obj.setValue(liked, forKey: "favorited")
        }
    }

    /// Brings the track up in the app that is playing it.
    ///
    /// Music uses `reveal`, which selects the track in its own window. Spotify
    /// is normally sent its `spotify:track:` URL by `MediaManager.openInPlayer`
    /// and arrives here only when the track has no id (identity is then a
    /// synthesised title/artist key), where bringing the app forward is the
    /// whole action. Neither app activates itself.
    func revealInPlayer(_ source: MusicSource) {
        if source == .music {
            command(source) { $0.currentTrack?.reveal?() }
        }
        // Activation is an `NSRunningApplication` call, not an Apple Event, so
        // it stays off the lane and still works when the player has stopped
        // answering.
        guard !inert, Self.isRunning(source) else { return }
        DispatchQueue.main.async {
            NSRunningApplication
                .runningApplications(withBundleIdentifier: source.bundleID)
                .first?.activate()
        }
    }

    // MARK: Transport

    func playPause(_ source: MusicSource) {
        command(source) { $0.playpause?() }
    }

    func next(_ source: MusicSource) {
        command(source) { $0.nextTrack?() }
    }

    func previous(_ source: MusicSource) {
        command(source) { app in
            switch source {
            case .spotify: app.previousTrack?()
            case .music:   app.backTrack?()
            }
        }
    }

    func seek(_ source: MusicSource, to position: Double) {
        command(source) { $0.setPlayerPosition?(position) }
    }
}
