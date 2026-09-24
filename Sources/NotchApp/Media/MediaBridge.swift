import AppKit
import ScriptingBridge

/// Immutable snapshot of a player's state, safe to hand to the main actor.
struct TrackSnapshot: Equatable, Sendable {
    var source: MusicSource
    var title: String = ""
    var artist: String = ""
    var album: String = ""
    var isPlaying: Bool = false
    var duration: Double = 0
    var position: Double = 0
    /// Stable per-track key. Artwork work is skipped when this doesn't change,
    /// which is what keeps a poll from re-decoding the same cover forever.
    var identity: String = ""
    var artworkURL: String?
    /// Whether the track is favourited, or `nil` when the source cannot say.
    ///
    /// Spotify's dictionary declares `starred` as `access="r"` and asking for it
    /// fails outright at runtime (-10000), so for Spotify this is genuinely
    /// unknowable over ScriptingBridge — not merely unwritable. `nil` is what the
    /// interface keys off: no answer, no heart, rather than a heart that does
    /// nothing.
    var liked: Bool?
    /// Both are per-player state, not per-track, so they live on the app object.
    /// `nil` only if the player did not answer.
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
/// **Never touched from the main actor.** ScriptingBridge is synchronous IPC and
/// will block the caller if the target app is busy or beachballing — a hung
/// Spotify would otherwise beachball this app with it. The objects are confined
/// to a private serial queue and the connections carry an explicit send timeout.
final class MediaBridge: @unchecked Sendable {

    /// Each player's poll, each player's commands, and Music's artwork get
    /// **their own queue and their own ScriptingBridge connections** — see
    /// `LaneKey`.
    ///
    /// Sharing one serial queue meant every button press queued behind whatever
    /// poll was in flight, and a ScriptingBridge round-trip can take most of its
    /// timeout when the player is busy. That is the entire reason transport felt
    /// unresponsive: the command itself is fast, it just wasn't getting to run.
    /// The same sharing is what turned one stuck read into a dead app.
    /// An inert bridge answers nothing and commands nothing.
    ///
    /// `tools/mediacheck.swift` drives a real `MediaManager`, and its toggles
    /// dispatch through here. With Music running and a track loaded, running
    /// ./check.sh would have sent a live Apple Event and favourited whatever the
    /// user was playing — a test suite that edits your library is not a test
    /// suite. Nothing in the app constructs one of these.
    private let inert: Bool

    /// Stands in for the ScriptingBridge read. Only `tools/mediacheck.swift`
    /// passes one.
    ///
    /// The watchdog's entire job is to survive a read that never returns, and
    /// the only honest way to check that is with a read that never returns.
    /// There is no way to ask a real player to hang, and a check that waits for
    /// one to misbehave on its own is not a check.
    private let stubbedRead: (@Sendable (MusicSource) -> Read)?

    init(inert: Bool = false, stubbedRead: (@Sendable (MusicSource) -> Read)? = nil) {
        self.inert = inert
        self.stubbedRead = stubbedRead
    }

    /// What a lane serves. Each key owns its own lane, its own budget, and its
    /// own connections.
    ///
    /// One shared lane was the root of the outage this file exists to fix, and
    /// retiring it only narrowed the window. Three things survived: a wedged
    /// Spotify still owned Music's next read, a slow Apple Music cover still
    /// owned the poll queued behind it, and a player that quit returned a budget
    /// the *other* player's parked threads had spent. Keyed by purpose, none of
    /// them can happen — a wedge costs exactly the one thing that wedged.
    private enum LaneKey: Hashable {
        case poll(MusicSource)
        case artwork
        case command(MusicSource)

        /// Ends up in the dispatch queue label, so a `sample` of a wedged
        /// instance names the player and the purpose that wedged rather than
        /// just "read".
        var label: String {
            switch self {
            case .poll(let s):    return "read.\(s.rawValue)"
            case .artwork:        return "artwork"
            case .command(let s): return "cmd.\(s.rawValue)"
            }
        }

        /// Commands are what the finger is waiting on; reads are not.
        var qos: DispatchQoS {
            if case .command = self { return .userInteractive }
            return .utility
        }

        /// Reads get a short leash so a slow player cannot back up the poll;
        /// commands get more room, since they must not be dropped.
        var timeoutTicks: Int {
            switch self {
            case .command: return MediaBridge.cmdTimeoutTicks
            // The cover's own leash, not the poll's. At 0.75s a large cover ran
            // out of connection long before its 5s deadline, came back empty,
            // and was filed as having none — placeholder and neutral palette
            // for the whole track, with nothing that ever asked again.
            case .artwork: return MediaBridge.artworkTimeoutTicks
            case .poll:    return MediaBridge.readTimeoutTicks
            }
        }

        /// How long before the caller is answered without the call, or the
        /// command given up on. Twice the leash the connection carries, in each
        /// case, so merely-slow is never mistaken for silent.
        var deadline: TimeInterval {
            switch self {
            case .poll:    return MediaBridge.readDeadline
            // Artwork gets longer. Music hands the image back through the bridge
            // rather than a URL, and a large cover legitimately takes a moment;
            // timing that out at the poll's deadline would abandon lanes over
            // slowness rather than over silence.
            case .artwork: return 5
            case .command: return 4
            }
        }
    }

    /// One generation of one lane: a queue, and the connections that belong only
    /// to that queue.
    ///
    /// A lane exists so a call that will not come back can be *abandoned* rather
    /// than waited on. The parked thread keeps its own lane and the connections
    /// it was using, so nothing it touches afterwards is state the next lane
    /// reads — which is the whole reason the connections live here and not on
    /// the bridge.
    ///
    /// `@unchecked` because the confinement is the design, not an oversight:
    /// `apps` is only ever touched on `queue`, and everything below it only
    /// under the bridge's `lock`.
    private final class Lane: @unchecked Sendable {
        let queue: DispatchQueue
        let timeoutTicks: Int
        /// Only ever touched on `queue`.
        var apps: [MusicSource: MediaPlayerApp] = [:]

        /// `retiredIn` is the accounting epoch the lane was abandoned in, not a
        /// plain flag: `invalidate` can return the whole budget while a thread is
        /// still parked, and that thread must not later hand a seat back to a
        /// budget that has already been restored — which would leave more threads
        /// parked than `maxAbandoned` allows.
        var retiredIn: Int?
        /// The head of this queue is not coming back and there is no budget left
        /// to open a fresh lane. Set so later calls do not each pile another
        /// block behind a thread that will never run it.
        var blocked = false
        /// One block is already waiting behind that head, to run if the wedge
        /// ever clears. Exactly one: it is a recovery probe, not a queue.
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
        /// Bumped whenever this key's budget is returned wholesale, so seats can
        /// only be given back to the budget they were taken from.
        var epoch = 0
        var generation = 0
    }

    /// Answers its caller exactly once, for whichever of the call and the
    /// deadline gets there first, and tells the loser that it lost.
    ///
    /// `@unchecked` over a plain conditional conformance because the value being
    /// raced can be an `NSImage`, which is not `Sendable` — it is handed to
    /// exactly one of two callers under the lock and never shared.
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
        /// The deadline needs this. Answering first and retiring after left a
        /// window — short, but exactly one poll wide — in which the caller had
        /// already been told the read failed while the lane it failed on was
        /// still the current one, so the next read was dispatched onto the
        /// wedge and lost too.
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
    /// deadline has no caller to hand a value to and only needs to know whether
    /// it got there first.
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

    /// Timers only — never a ScriptingBridge call, or the watchdog could wedge
    /// behind the very thing it is watching.
    private static let watchdog = DispatchQueue(label: "magnetite.media.watchdog",
                                                qos: .utility)

    /// How long a read may take before its caller is answered without it.
    ///
    /// Twice the leash the connection itself carries, so a player that is merely
    /// slow is not called unanswered. It is longer than the 1s poll rather than
    /// inside it, and that is fine: each player's poll now has its own lane, so
    /// a stalled one holds up only its own next read, and the panel holds its
    /// last frame instead of blanking while it waits.
    ///
    /// Not private, because `tools/mediacheck.swift` measures against it rather
    /// than against a number copied out of here.
    static let readDeadline: TimeInterval = 1.5

    /// How many threads may be left parked inside a send that never answered,
    /// **per key**.
    ///
    /// Each abandoned lane costs one thread that will not come back. Opening a
    /// fresh one per poll against a player that never answers again would be an
    /// unbounded leak, so past this the bridge stops opening lanes for that key.
    ///
    /// The real worst case is `maxAbandoned + 1` threads per key: the current
    /// lane's thread is parked too, and is not counted here because it is the
    /// one lane still being handed out. Calls after that do not add to the
    /// count — they queue onto the blocked lane, one at a time and no more
    /// (`probePending`), so it settles rather than climbing. See `invalidate`:
    /// a player that quits or relaunches is a new world, and returns its budget.
    ///
    /// Not private, for the reason `readDeadline` is not: the check counts to
    /// the cap rather than to a number copied out of here.
    static let maxAbandoned = 2

    /// ScriptingBridge timeout is in ticks (1/60s).
    ///
    /// Neither is load-bearing, and the read one is why every call here carries a
    /// deadline of its own. An instance was found with the read queue pinned
    /// inside `AESendMessage` under `playerState`, identically across two
    /// independent `sample` runs, more than an hour after launch and with this
    /// leash set: the player had accepted the event and simply never answered,
    /// and the timeout the connection carries never fired.
    fileprivate static let readTimeoutTicks = 45     // 0.75s
    fileprivate static let cmdTimeoutTicks = 120     // 2s
    fileprivate static let artworkTimeoutTicks = 150 // 2.5s
    /// errAETimeout: the leash above ran out before the player answered.
    fileprivate static let eventTimedOut = -1712

    static func isRunning(_ source: MusicSource) -> Bool {
        runningInstance(source) != nil
    }

    /// The live process, if there is one. A player mid-quit is still listed
    /// until it has fully gone, so a terminated entry does not count.
    static func runningInstance(_ source: MusicSource) -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: source.bundleID)
            .first { !$0.isTerminated }
    }

    /// How many of this player's poll lanes have a thread still parked inside a
    /// send that never answered. For `tools/mediacheck.swift`.
    ///
    /// Exposed rather than inferred. A seat coming back is otherwise only
    /// visible three wedged reads later, in whether the fourth is refused — four
    /// and a half seconds of deadline to observe a number this already keeps,
    /// and an inference that cannot tell a refund from an off-by-one. The check
    /// asserts on the count *and* on what the count is supposed to buy, so
    /// neither one stands alone.
    func parkedPollLanes(for source: MusicSource) -> Int {
        lock.lock(); defer { lock.unlock() }
        return groups[.poll(source)]?.abandoned ?? 0
    }

    /// The lane a call should run on, or `nil` when it must be refused outright.
    ///
    /// Refusing is not a failure mode, it is the honest answer: the lane's head
    /// block is known not to be coming back, a probe is already waiting behind
    /// it, and sitting out the deadline would reach the same answer more slowly.
    /// Before this, every poll against a wedged player added one more block to a
    /// queue that would never run any of them — each holding a continuation and
    /// its captures, once a second, for as long as the app stayed up.
    private func admit(_ key: LaneKey) -> Lane? {
        lock.lock(); defer { lock.unlock() }
        // `let`, and the write-back is still needed: the flag below lives on the
        // lane object, but a key being asked for the first time has to keep the
        // group this just made for it.
        let g = groups[key] ?? LaneGroup(lane: Lane(key, 0))
        defer { groups[key] = g }
        guard g.lane.blocked else { return g.lane }
        guard !g.lane.probePending else { return nil }
        g.lane.probePending = true
        return g.lane
    }

    /// Give up on the lane a call was abandoned in, so the next one does not
    /// queue behind a thread that is never coming back.
    ///
    /// Only ever called for a call whose own block had not finished when its
    /// deadline came up — see the `Gate` each call carries. A lane-wide "it came
    /// back late" flag stood here first and was wrong twice over: set once it
    /// spared *every* later retirement of that lane, including the one that was
    /// a genuine wedge, and even paired correctly it spared a retirement earned
    /// minutes later by a different call. Several calls timing out on one lane
    /// need no flag at all — the identity guard below already rejects all but
    /// the first.
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

    /// A block came back. That it came back at all frees the lane to be used
    /// normally again; whether it beat its deadline decides what else it is
    /// worth.
    ///
    /// The seat stamp is cleared as the seat is returned, so the calls that
    /// piled up behind it on the same serial queue cannot each claim that one
    /// seat again; and a stamp from a spent epoch is dropped without a refund.
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
    /// An app object made from a bundle ID LAUNCHES its target whenever an
    /// event is sent and the target is not running. Quitting Spotify posts its
    /// own PlaybackStateChanged, which asks for a refresh at once; the poll's
    /// `isRunning` check passed while Spotify was still on its way out, the
    /// dozen events that follow arrived after it had gone, and LaunchServices
    /// dutifully reopened the player the user had just closed — every time.
    /// Aimed at a PID, an event to a process that has exited simply fails. The
    /// lanes are replaced on every launch and quit (`invalidate`), so a
    /// relaunched player gets a fresh object for its new PID.
    private func connect(_ source: MusicSource, timeout: Int) -> MediaPlayerApp? {
        guard let running = Self.runningInstance(source),
              let raw = SBApplication(processIdentifier: running.processIdentifier)
        else { return nil }
        raw.timeout = timeout
        // Unconditional: SBApplication is declared to conform, so `as?` was
        // always going to succeed and only read as if failure were possible.
        return raw as MediaPlayerApp
    }

    /// Spotify reports milliseconds, Music reports seconds, both under the same
    /// selector — so it's read untyped and normalised here.
    /// The player's own key for a track, through KVC for the reason `duration`
    /// is: under `id` Spotify answers its `spotify:track:` URI and Music an
    /// integer database id, and a typed `String` read of Music's integer
    /// crashed the app. Music's text key is `persistentID`, which also survives
    /// a library rebuild. Spotify's stays `id`: `openInPlayer` builds its URL
    /// from it.
    private static func trackKey(of track: MediaTrack, source: MusicSource) -> String? {
        let key = source == .spotify ? "id" : "persistentID"
        guard let value = (track as? NSObject)?.value(forKey: key) as? String,
              !value.isEmpty else { return nil }
        return value
    }

    private func duration(of track: MediaTrack, source: MusicSource) -> Double {
        guard let value = (track as? NSObject)?.value(forKey: "duration") as? NSNumber
        else { return 0 }
        return source == .spotify ? value.doubleValue / 1000.0 : value.doubleValue
    }

    /// Open the command connection before it's needed.
    ///
    /// The first ScriptingBridge call on a fresh connection pays for the Apple
    /// Event handshake, so without this the *first* button press is noticeably
    /// slower than every one after it.
    func prewarm(_ source: MusicSource) {
        // Opening the connection is what the lane does on the way to running a
        // command, so an empty one is the whole warm-up.
        command(source) { _ in }
    }

    /// A player that just launched or quit invalidates more than its connection.
    ///
    /// Whatever a parked thread is still waiting for, it is waiting on a process
    /// that is no longer the one being asked. So that player's budget is returned
    /// in full and its lanes start clean — which is the recovery a relaunch of
    /// the player is expected to buy, and the only one available once every seat
    /// is taken.
    ///
    /// *That player's*. When one lane served everything, a quitting Music handed
    /// Spotify's parked threads their seats back, and the budget stopped bounding
    /// anything.
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
            // The lane is replaced outright rather than having its cached
            // proxies cleared in place. A parked thread keeps the lane it is
            // parked on, so a clean-up dispatched onto that lane would sit behind
            // it forever — which is how the advertised remedy, quit and reopen
            // the player, could fail to change anything at all.
            g.lane = Lane(key, g.generation)
            groups[key] = g
        }
    }

    /// What a read found — which is not the same question as what is playing.
    ///
    /// `snapshot` answered a bare nil for two unrelated causes: a player with
    /// nothing queued, and a player that will not answer at all. The caller
    /// counted both as the second, so opening Music to browse without queueing
    /// anything accused the user, after three polls, of refusing an Automation
    /// grant they had in fact given — and offered to open a settings pane that
    /// could not change it. `playerState` is the one signal that tells them
    /// apart, and it was read AFTER the guards that discard the case.
    enum Read {
        case track(TrackSnapshot)
        /// Running, answering, and playing nothing.
        case idle
        /// Refused: the Automation grant is denied, or the player quit mid-read.
        /// The player said no.
        case unreadable
        /// Accepted the event and never answered.
        ///
        /// Distinct from a refusal for the same reason `idle` is, and by the
        /// same lesson: the menu answers `unreadable` with an Automation
        /// settings pane, which cannot unstick a player that is not replying and
        /// accuses the user of withholding a grant they have already given.
        case unanswered
    }

    /// Reads the player, or gives up on it.
    ///
    /// The deadline is enforced out here rather than on the connection, because
    /// the connection's own leash is the thing that failed: `readTimeoutTicks`
    /// was set and a read still sat inside `AESendMessage` for over an hour.
    /// Waiting for the blocked call to notice something is not on the table, so
    /// the caller is answered without it and the thread is left where it stands.
    ///
    /// A serial queue then made that one read own every later one — the other
    /// player's included, so a wedged Spotify also hid a perfectly healthy
    /// Music — and `MediaManager.refresh()` awaits this call, so the poll loop
    /// stopped with it. The panel showed nothing at all for as long as the app
    /// stayed up, which is how this was found.
    func read(for source: MusicSource) async -> Read {
        let key = LaneKey.poll(source)
        return await withCheckedContinuation { continuation in
            let race = Race(continuation)
            guard let lane = admit(key) else { race.resume(.unanswered); return }
            // Separate from the race, and not redundant with it. The race says
            // who answered the caller; this says whether this call's block ever
            // came back, which is the only thing that justifies retiring the
            // lane under it.
            let done = Gate()

            lane.queue.async { [weak self] in
                guard let self else { race.resume(.unanswered); return }
                let result = self.readSync(for: source, on: lane)
                race.resume(result)
                self.finished(lane, key: key, late: !done.close())
            }

            // Armed here rather than at the top of the block, deliberately. A
            // block that never *starts* — one queued behind a wedge — would
            // never arm one, and its caller would then wait with nothing left to
            // answer it: the exact outage this file exists to fix, reintroduced
            // by the tidier-looking placement.
            Self.watchdog.asyncAfter(deadline: .now() + key.deadline) { [weak self] in
                // Lost the race: the read answered in time and there is nothing
                // to abandon.
                guard let answer = race.claim() else { return }
                // Retired before the caller is told, so the poll it makes next
                // cannot be dispatched onto the lane that just failed it — and
                // only if this call's block is still in there.
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
        // Asked FIRST, and that is the whole point: it is the only property that
        // separates "answering, nothing queued" from "will not answer". Read
        // after the track guards, as it was, it could never be consulted in the
        // case that needed it.
        guard let state = app.playerState else { return .unreadable }
        // A failed event does not come back as nil. ScriptingBridge answers a
        // scalar it could not fetch with 0, and the track proxy after it reads
        // empty, so a refused Automation grant was reported as `.idle` and the
        // note that names the refusal could never appear. No player state is 0,
        // so 0 is the failure, and the error says which kind.
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
        // Gated on the player's own answer to "can this be set right now".
        //
        // Spotify's `shuffling` and `repeating` are declared settable and are
        // NOT: `setValue` is accepted and silently ignored, and so is
        // `set shuffling to true` over raw AppleScript. The reason is next to
        // them in the dictionary — `shuffling enabled` and `repeating enabled`,
        // read-only, "in the current playback context". Both are false for a
        // queue that does not support them, and Spotify simply drops the write.
        //
        // So the control is only offered when the player says it will answer,
        // which is the rule the heart already follows: no answer, no control,
        // rather than a control that does nothing.
        s.shuffling = Self.modeAvailable(app, source: source, .shuffle)
            ? Self.shuffleState(app, source: source) : nil
        s.repeating = Self.modeAvailable(app, source: source, .repeat)
            ? Self.repeatState(app, source: source) : nil
        s.liked = source == .music
            ? (track as? NSObject)?.value(forKey: "favorited") as? Bool
            : nil
        return .track(s)
    }

    /// What a Music artwork read actually said — because two different silences
    /// were being conflated into one `nil`. A library with no cover for the
    /// track has ANSWERED, and asking again cannot change it; a read the
    /// watchdog abandoned, or a lane too wedged to admit, never answered at
    /// all, and the file's own rule is that transport failures pass. Folding
    /// both into `nil` meant one 5s stall at a track change left the
    /// placeholder and the neutral palette up for the whole track, with no
    /// path that ever re-asked.
    enum ArtworkAnswer {
        case image(NSImage)
        /// The player answered: this track has no cover.
        case noCover
        /// The deadline fired or the lane was refused — nothing answered.
        case unanswered
    }

    /// Apple Music artwork comes back as an `NSImage` through the bridge, which is
    /// expensive — only ever call this when the track identity actually changed.
    /// On its own lane, not the poll's. Sharing one meant a cover that took its
    /// full five seconds owned every poll queued behind it, so the panel blanked
    /// mid-song — and, since blanking dropped the track, asked for the artwork
    /// again on the next arrival and blanked again.
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

        if let image = art.data { return image }
        if let raw = art.rawData { return NSImage(data: raw) }
        return nil
    }

    // MARK: Modes

    /// Spotify keys both on plain booleans; Music uses `shuffle enabled` and a
    /// three-state `song repeat` enum. Read through KVC for the same reason
    /// `duration` is — one selector cannot cover two shapes.
    private static func key(_ mode: Mode, _ source: MusicSource) -> String {
        switch (mode, source) {
        case (.shuffle, .spotify): return "shuffling"
        case (.shuffle, .music):   return "shuffleEnabled"
        case (.repeat, .spotify):  return "repeating"
        case (.repeat, .music):    return "songRepeat"
        }
    }

    enum Mode { case shuffle, `repeat` }

    /// Music's repeat is off / one / all. Collapsed to a boolean here and
    /// restored as `all`, because the panel has one glyph and three states would
    /// need three — worth doing only if the third one is asked for.
    private static let repeatOff: UInt32 = 0x6b52_704f   // 'kRpO'
    private static let repeatAll: UInt32 = 0x6b41_6c6c   // 'kAll'

    /// Whether the player will accept a write to this mode at all.
    ///
    /// Music exposes no such flag and takes the write, so it is always true
    /// there.
    private static func modeAvailable(_ app: MediaPlayerApp, source: MusicSource,
                                      _ mode: Mode) -> Bool {
        guard source == .spotify else { return true }
        let key = mode == .shuffle ? "shufflingEnabled" : "repeatingEnabled"
        return (app as? NSObject)?.value(forKey: key) as? Bool ?? false
    }

    private static func shuffleState(_ app: MediaPlayerApp, source: MusicSource) -> Bool? {
        (app as? NSObject)?.value(forKey: key(.shuffle, source)) as? Bool
    }

    private static func repeatState(_ app: MediaPlayerApp, source: MusicSource) -> Bool? {
        guard let raw = (app as? NSObject)?.value(forKey: key(.repeat, source)) else { return nil }
        if source == .spotify { return raw as? Bool }
        guard let code = (raw as? NSNumber)?.uint32Value else { return nil }
        return code != repeatOff
    }

    /// Every command runs through here: one lane per player, a deadline, and a
    /// lane that can be abandoned — the read path's machinery, for the same
    /// reason.
    ///
    /// A command wedges exactly as a read does; it is the same synchronous IPC
    /// to the same process, and it is the half the finger is waiting on. One
    /// shared serial queue for both players meant a single stuck `playpause`
    /// owned every later press, the other player's included, with no deadline
    /// anywhere to end it. That the panel used to blank on a stalled read is all
    /// that kept it rare: nothing was left on screen to press. Now that the
    /// panel holds its last frame, the transport stays live and inviting under
    /// exactly the conditions that wedge.
    private func command(_ source: MusicSource,
                         _ body: @escaping @Sendable (MediaPlayerApp) -> Void) {
        guard !inert else { return }
        let key = LaneKey.command(source)
        guard let lane = admit(key) else { return }
        let gate = Gate()

        lane.queue.async { [weak self] in
            guard let self else { return }
            if Self.isRunning(source), let app = self.app(source, on: lane) { body(app) }
            self.finished(lane, key: key, late: !gate.close())
        }

        // Nothing to answer — the press has no continuation waiting on it. The
        // deadline exists only to abandon the lane, so the *next* press is not
        // queued behind this one.
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

    /// Read and written through KVC rather than through `MediaPlayerApp`.
    ///
    /// Same reason `duration` is: the two players disagree under one selector.
    /// Music renamed `loved` to `favorited`, and Spotify's nearest equivalent is
    /// read-only and non-functional, so there is no single declaration both apps
    /// could satisfy.
    /// `identity` is the pressed track's key, and the body re-derives the live
    /// track's key the exact way `snapshot` builds it before writing. The
    /// command lane runs later than the press — Music may have auto-advanced, a
    /// queued skip may land first, or an abandoned lane may replay this body
    /// late — and `currentTrack` is a by-reference specifier resolved at event
    /// receipt, so the favourite went onto whatever was playing THEN, silently:
    /// the optimistic heart showed success and the next poll read the wrong
    /// track's ✓ back as confirmation. The Spotify branch has captured identity
    /// since the same race bit it; this is the Music half. The compare narrows
    /// the race to milliseconds rather than closing it — the write still goes
    /// through the current-track specifier.
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

    /// Bring the track up in the app that is playing it.
    ///
    /// Music only, in practice: it uses `reveal`, which selects the track in its
    /// own window. Spotify usually never reaches here — `MediaManager.openInPlayer`
    /// sends it to its own `spotify:track:` URL instead, which costs no round-trip.
    /// It arrives only when the track has no id to send to, which is the case
    /// `identity` covers with a synthesised title/artist key; then there is
    /// nothing to reveal and bringing the app forward is the whole action.
    /// Either way the app has to be brought forward, since neither activates
    /// itself.
    func revealInPlayer(_ source: MusicSource) {
        if source == .music {
            command(source) { $0.currentTrack?.reveal?() }
        }
        // Off the lane. Bringing the app forward is an `NSRunningApplication`
        // call rather than an Apple Event, so a player that has stopped
        // answering must not cost the one part of this that would still work.
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
