import Foundation

/// Headless checks on the media surface: the reconciliation between what the
/// user just pressed and what the player reports a moment later.
///
/// Every manager here takes an inert bridge. The toggles dispatch real commands,
/// so a live Music session would otherwise receive Apple Events and have its
/// current track favourited.
@main
@MainActor
enum MediaCheck {
    static func main() {
        aSkipRemembersItsDirectionBriefly()
        aPressHoldsUntilThePlayerAgrees()
        anUnansweredControlIsNotShown()
        aPauseDoesNotTakeTheTogglesAway()
        aPauseAsksWhatTheTogglesCanStillDo()
        onlyARealTrackURLIsShareable()
        aWedgedReadDoesNotOwnTheNextOne()
        aWedgedPlayerDoesNotHideTheOtherOne()
        aWedgedCommandNeitherBlocksThePressNorTheNextOne()
        aRecoveredPlayerGetsItsBudgetBack()
        aParkedThreadReturnsExactlyOneSeat()
        aStalledPanelHoldsItsLastFrame()
        aPromisedCoverIsAskedForAgain()
        aResumeStartsFromWhereItPaused()
        aPauseKeepsThePlayerOnScreen()
        aShortItemDoesNotFreezeThePanel()
        artistCreditsKeepNamesAndSafeDestinations()
        print("mediacheck: all checks passed")
    }

    /// Credits are split only on unambiguous separators, and every artist link
    /// resolves to a safe destination: an exact catalog ID, an encoded search, or
    /// an https music.apple.com page.
    static func artistCreditsKeepNamesAndSafeDestinations() {
        let names = ArtistCredit.fallback("A, B & C", source: .music)
        require(names.map(\.name) == ["A", "B", "C"] && ArtistCredit.line(names) == "A, B & C",
                "Music collaboration credits or their separators changed")
        for field in ["A feat. B", "A featuring B", "A (feat. B)", "A [feat. B]"] {
            require(ArtistCredit.fallback(field, source: .music).map(\.name) == ["A", "B"],
                    "Music featured credit was lost: \(field)")
        }
        // A lone comma is part of one name; it splits only beside an "&".
        for (field, expected) in [
            ("Tyler, The Creator", ["Tyler, The Creator"]),
            ("Tyler, The Creator feat. Kali Uchis", ["Tyler, The Creator", "Kali Uchis"]),
            ("A & B feat. C", ["A", "B", "C"]),
            ("A, B & C (feat. D)", ["A", "B", "C", "D"]),
        ] {
            let got = ArtistCredit.fallback(field, source: .music)
            require(got.map(\.name) == expected, "Music credit split wrong: \(field) -> \(got.map(\.name))")
        }
        require(ArtistCredit.line(ArtistCredit.fallback("Tyler, The Creator", source: .music))
                == "Tyler, The Creator", "a comma in one name was redisplayed as an &")
        for source in MusicSource.allCases {
            require(ArtistCredit.fallback("Artist (US)", source: source).map(\.name) == ["Artist (US)"],
                    "artist punctuation was stripped without a featuring wrapper")
        }
        require(ArtistCredit.fallback("A & B", source: .spotify).map(\.name) == ["A & B"],
                "Spotify's primary bridge name was guessed apart")
        let data = Data(#"{"artists":[{"name":"A","id":"0123456789012345678901"},{"name":"B","id":"abcdefghijklmnopqrstuv"},{"name":"C","id":"../bad"}],"album":{"artists":[{"name":"Wrong"}]}}"#.utf8)
        let credits = SpotifyWeb.artists(from: data) ?? []
        require(credits.map(\.name) == ["A", "B", "C"], "track artists[] was not preserved")
        require(credits.first?.url(in: .spotify).absoluteString == "spotify:artist:0123456789012345678901",
                "Spotify artist did not use its catalog ID")
        require(credits.last?.url(in: .spotify).absoluteString == "spotify:search:C",
                "malformed artist ID did not fall back to search")
        let punctuation = ArtistCredit(name: "AC/DC & Björk #1")
        require(punctuation.url(in: .spotify).absoluteString == "spotify:search:AC%2FDC%20%26%20Bj%C3%B6rk%20%231",
                "artist search name changes URI structure")
        require(punctuation.url(in: .music).query?.contains("%26") == true,
                "Music search query is not encoded")
        let match = #"{"wrapperType":"artist","artistName":"Björk","artistId":123,"artistLinkUrl":"https://music.apple.com/us/artist/bjork/123?uo=4"}"#
        require(ArtistCredit.musicURL(from: Data("{\"results\":[\(match)]}".utf8), named: "Björk")?.scheme == "music",
                "a unique exact Apple artist match was not resolved")
        require(ArtistCredit.musicURL(from: Data("{\"results\":[\(match),\(match)]}".utf8), named: "Björk") == nil,
                "ambiguous Apple artists opened an arbitrary page")
        let foreign = match.replacingOccurrences(of: "music.apple.com", with: "example.com")
        require(ArtistCredit.musicURL(from: Data("{\"results\":[\(foreign)]}".utf8), named: "Björk") == nil,
                "catalog result opened an untrusted host")
    }

    /// Pausing the player on screen must not hand the panel to another player.
    /// Spotify is asked first, so with both paused the first answer would
    /// otherwise win.
    static func aPauseKeepsThePlayerOnScreen() {
        var spotify = snapshot(.spotify); spotify.isPlaying = false
        var music = snapshot(.music, identity: "music:1"); music.isPlaying = false
        require(MediaManager.keepsPanel(music, over: spotify, showing: .music),
                "pausing Music handed the panel to a paused Spotify")
        require(!MediaManager.keepsPanel(music, over: spotify, showing: .spotify),
                "a paused Music took the panel from the Spotify on screen")
        require(!MediaManager.keepsPanel(music, over: spotify, showing: nil),
                "with nothing on screen, the first player to answer no longer wins")
        require(MediaManager.keepsPanel(music, over: nil, showing: .spotify),
                "the only player that answered was not shown")
    }

    /// A short item keeps the track on screen but not as playing; held as
    /// playing, its progress line would run to the end and stay there.
    static func aShortItemDoesNotFreezeThePanel() {
        let m = MediaManager(bridge: MediaBridge(inert: true))
        m.apply(snapshot())
        var chirp = snapshot(identity: "spotify:track:chirp")
        chirp.title = "Chirp"; chirp.duration = 3; chirp.position = 0
        m.apply(chirp)
        require(m.title == "Swim", "a short item replaced the track on screen")
        require(!m.isPlaying, "the track on screen went on playing under a short item")
        let held = m.smoothPosition
        Thread.sleep(forTimeInterval: 0.3)
        require(m.smoothPosition == held,
                "the held track's line kept running: \(held)s became \(m.smoothPosition)s")
    }

    /// A resume starts from the paused position, not from the time of the pause.
    /// The interpolation clock is anchored at the last position change, which a
    /// pause does not update, so the pause would otherwise be elapsed at once.
    /// Covers both entry points: the press and a resume made in the player.
    static func aResumeStartsFromWhereItPaused() {
        for door in ["a press", "the player"] {
            let m = MediaManager(bridge: MediaBridge(inert: true))
            var paused = snapshot()
            paused.isPlaying = false
            paused.duration = 10
            paused.position = 9
            m.apply(paused)
            // Longer than what was left of the track.
            Thread.sleep(forTimeInterval: 1.2)
            if door == "a press" {
                m.playPause()
            } else {
                var playing = paused
                playing.isPlaying = true
                m.apply(playing)
            }
            require(m.isPlaying, "resuming from \(door) did not take")
            require(m.smoothPosition < 9.5,
                    "resuming from \(door) jumped to \(m.smoothPosition)s of 10 — "
                    + "the pause was elapsed as if it had been playing")
        }
    }

    static func snapshot(_ source: MusicSource = .spotify,
                         identity: String = "spotify:track:abc",
                         liked: Bool? = nil,
                         shuffling: Bool? = false,
                         repeating: Bool? = false) -> TrackSnapshot {
        var s = TrackSnapshot(source: source)
        s.title = "Swim"; s.artist = "Artist"; s.album = "Album"
        s.isPlaying = true; s.duration = 200; s.position = 10
        s.identity = identity
        s.liked = liked; s.shuffling = shuffling; s.repeating = repeating
        return s
    }

    /// The skip direction is recorded at the press and consumed when the new
    /// track lands. It must expire and be taken exactly once, or a later organic
    /// advance would inherit a lean it did not earn.
    static func aSkipRemembersItsDirectionBriefly() {
        let m = MediaManager(bridge: MediaBridge(inert: true))
        m.apply(snapshot())
        require(m.consumeSkipDirection() == nil, "a direction appeared with no skip")

        m.next()
        require(m.consumeSkipDirection() == 1, "a skip forward lost its direction")
        require(m.consumeSkipDirection() == nil, "the direction was consumed twice")

        m.previous()
        require(m.consumeSkipDirection() == -1, "a skip back lost its direction")

        m.next()
        require(m.consumeSkipDirection(within: 0) == nil,
                "a stale direction outlived its window")
        require(m.consumeSkipDirection() == nil,
                "an expired direction was left behind to be picked up later")
    }

    /// Optimistic holds: a glyph lights under the finger and a stale poll must
    /// not undo it, but the hold must end, or one press would leave the interface
    /// out of step with the player for the session.
    static func aPressHoldsUntilThePlayerAgrees() {
        let m = MediaManager(bridge: MediaBridge(inert: true))
        m.apply(snapshot(.music, liked: false, shuffling: false, repeating: false))
        require(m.liked == false && m.shuffling == false && m.repeating == false,
                "the snapshot did not land")

        m.toggleLike()
        require(m.liked == true, "the heart did not fill under the press")
        m.apply(snapshot(.music, liked: false))          // player has not caught up
        require(m.liked == true, "a stale poll undid the press")

        m.toggleShuffle()
        require(m.shuffling == true, "shuffle did not light under the press")
        m.apply(snapshot(.music, liked: true, shuffling: false))
        require(m.shuffling == true, "a stale poll undid the shuffle press")

        // Toggling the other mode must not drop the first one's hold.
        m.toggleRepeat()
        m.apply(snapshot(.music, liked: true, shuffling: false, repeating: false))
        require(m.shuffling == true && m.repeating == true,
                "one mode's hold cancelled the other's (\(m.shuffling!), \(m.repeating!))")

        // A track change ends every hold, since the values belong to the old
        // track. This uses a fresh manager with nothing applied in between: an
        // intervening poll that agreed with the press would release the hold and
        // let the assertion pass either way.
        let fresh = MediaManager(bridge: MediaBridge(inert: true))
        fresh.apply(snapshot(.music, liked: false))
        fresh.toggleLike()
        require(fresh.liked == true, "the press did not take")
        fresh.apply(snapshot(.music, identity: "spotify:track:other", liked: false))
        require(fresh.liked == false,
                "the hold survived a track change and lied about the new one")
    }

    /// `nil` means the player did not answer and the control is not drawn; it
    /// must never collapse into `false`, which would draw a live-looking control
    /// that does nothing. Spotify cannot report or set `starred` at all.
    ///
    /// Spotify's modes come from the Web API and a bridge answer is ignored,
    /// because the bridge accepts those writes and silently drops them. Music
    /// takes the write, so there its answer counts.
    static func anUnansweredControlIsNotShown() {
        let m = MediaManager(bridge: MediaBridge(inert: true))
        m.apply(snapshot(.spotify, liked: nil, shuffling: true, repeating: false))
        require(m.liked == nil, "an unanswerable heart was shown as empty")
        require(m.shuffling == nil && m.repeating == nil,
                "a Spotify mode was shown on the bridge's word, which the player drops")

        let music = MediaManager(bridge: MediaBridge(inert: true))
        music.apply(snapshot(.music, identity: "music:1", liked: true,
                             shuffling: true, repeating: false))
        require(music.shuffling == true && music.repeating == false && music.liked == true,
                "an answered mode was lost")

        m.toggleLike()
        require(m.liked == nil, "toggling an unanswerable control invented a state")

        // Losing the track clears everything. Asserted on the Music manager,
        // the only one here with state to lose; Spotify's modes are already nil
        // without a connection, so the comparison could not fail.
        music.apply(nil)
        require(music.liked == nil && music.shuffling == nil && music.repeating == nil,
                "modes outlived the track")
    }

    /// Pausing Spotify makes `/me/player` answer 204, which arrives as "no
    /// modes", not "shuffle is off"; the toggles must keep their last state
    /// rather than vanish whenever the music stops.
    ///
    /// Tested through the pure rule: `askPlayback` bails on `isConnected` and
    /// cannot be reached headlessly.
    static func aPauseDoesNotTakeTheTogglesAway() {
        let playing = SpotifyWeb.Playback(shuffling: true, repeating: true,
                                          canShuffle: true, canRepeat: true)
        // The 204: the values survive so the glyphs stay put...
        let paused = SpotifyWeb.modes(from: nil, keeping: playing)
        require(paused?.shuffling == true && paused?.repeating == true,
                "a pause reset the toggles instead of holding the last answer")
        // ...and both writes are marked refused, since `apply` recomputes the
        // blocked flags from these on every poll.
        require(paused?.canShuffle == false && paused?.canRepeat == false,
                "a kept answer still claimed the toggles were writable")

        // A fresh answer always wins, including one that disagrees.
        let stopped = SpotifyWeb.Playback(shuffling: false, repeating: false,
                                          canShuffle: true, canRepeat: true)
        let fresh = SpotifyWeb.modes(from: stopped, keeping: playing)
        require(fresh?.shuffling == false && fresh?.canShuffle == true,
                "a live answer was overruled by the one before it")

        // Nothing to keep stays nothing: launching while paused shows no toggles.
        require(SpotifyWeb.modes(from: nil, keeping: nil) == nil,
                "modes were conjured from no answer at all")
    }

    /// A pause or resume is a reason to ask again what the toggles can do.
    /// Spotify restricts shuffle and repeat while playback is stopped, so the
    /// capabilities move without a track change; without a re-ask the cached
    /// answer would leave a bright button whose write is refused, or a dimmed
    /// one on a player that would now accept it. The rule must also not ask on
    /// every poll, since the endpoint is rate limited.
    ///
    /// Tested through the pure rule for the same reason as the check above.
    static func aPauseAsksWhatTheTogglesCanStillDo() {
        // The transition that was missed, in both directions.
        require(MediaManager.shouldAskPlayback(source: .spotify, connected: true,
                                               playing: false, askedPlaying: true),
                "pausing did not re-ask, so a refused write stays behind a bright button")
        require(MediaManager.shouldAskPlayback(source: .spotify, connected: true,
                                               playing: true, askedPlaying: false),
                "resuming did not re-ask, so a usable toggle stays dimmed and disabled")
        // Launching mid-track has never asked, and has to.
        require(MediaManager.shouldAskPlayback(source: .spotify, connected: true,
                                               playing: true, askedPlaying: nil),
                "the first poll of a track never asked at all")

        // The opposing half: `apply` runs once a second against a rate-limited
        // endpoint, so asking more often is not free.
        require(!MediaManager.shouldAskPlayback(source: .spotify, connected: true,
                                                playing: true, askedPlaying: true),
                "a poll where nothing moved asked again anyway, once a second")
        require(!MediaManager.shouldAskPlayback(source: .spotify, connected: false,
                                                playing: false, askedPlaying: true),
                "a disconnected Spotify was asked over a connection it does not have")
        require(!MediaManager.shouldAskPlayback(source: .music, connected: true,
                                                playing: false, askedPlaying: true),
                "Apple Music was asked the Spotify Web API about its own toggles")
    }

    /// Only a real `spotify:track:` identity is shareable. `identity` falls back
    /// to a synthesised title/artist key when a player gives no id, which would
    /// produce a nonsense link.
    static func onlyARealTrackURLIsShareable() {
        let m = MediaManager(bridge: MediaBridge(inert: true))
        m.apply(snapshot(identity: "spotify:track:2lLzW4bflris4pkw67edvg"))
        require(m.shareURL?.absoluteString
                == "https://open.spotify.com/track/2lLzW4bflris4pkw67edvg",
                "the share link is not the track's page (\(m.shareURL?.absoluteString ?? "nil"))")

        m.apply(snapshot(.music, identity: "Swim\u{1}Artist\u{1}Album"))
        require(m.shareURL == nil, "a synthesised identity was offered as a link")
    }

    /// A player that takes an event and never answers costs one read, not the
    /// app. Two things must hold: the read is answered off the blocked thread
    /// within the deadline, and the next read is free of it, which requires the
    /// wedged lane to be retired because the queue is serial.
    ///
    /// The stub short-circuits `readSync`, so this exercises lane accounting
    /// only. It would stay green if the per-lane ScriptingBridge connections
    /// moved back onto the bridge, which would crash by mutating one dictionary
    /// from two queues; covering that needs a seam below the connection.
    static func aWedgedReadDoesNotOwnTheNextOne() {
        let wedge = DispatchSemaphore(value: 0)
        let calls = Calls()
        // The first read never comes back; every later one is instant. So a
        // second read that is slow can only be one that queued behind the first.
        let bridge = MediaBridge(inert: true, stubbedRead: { _ in
            if calls.take() == 0 { wedge.wait() }
            return .idle
        })

        let (first, firstTook) = read(bridge, giveUpAfter: 10)
        guard let first else {
            wedge.signal()
            require(false, "a read that never returned took its caller with it")
            return
        }
        guard case .unanswered = first else {
            wedge.signal()
            require(false, "a player that never answered was reported as something else")
            return
        }
        // Measured against the bridge's own constant, and bounded above as well
        // as below: a watchdog that never fires would otherwise pass via the
        // harness's own 10 s give-up. The upper slack allows for a loaded
        // machine delaying a timer queue.
        require(firstTook >= MediaBridge.readDeadline - 0.1
                && firstTook <= MediaBridge.readDeadline + 1.0,
                "the read gave up after \(fmt(firstTook))s, not near the "
                + "\(fmt(MediaBridge.readDeadline))s deadline it advertises")

        let (second, secondTook) = read(bridge, giveUpAfter: 10)
        wedge.signal()
        guard let second, case .idle = second else {
            require(false, "the read after a wedged one never got through")
            return
        }
        require(secondTook < 0.5,
                "the next read spent \(fmt(secondTook))s waiting behind the wedged one")
    }

    /// A command that never returns (Spotify's main thread busy, an Apple Event
    /// waiting out its own timeout) must not hold the press, and the press after
    /// it must not queue behind the stuck one. The stub's first command blocks
    /// forever; every later one is instant, so a second command that arrives
    /// late can only have waited behind the first.
    static func aWedgedCommandNeitherBlocksThePressNorTheNextOne() {
        let wedge = DispatchSemaphore(value: 0)
        let calls = Calls()
        let delivered = Flag()
        let bridge = MediaBridge(inert: true, stubbedCommand: { _ in
            if calls.take() == 0 { wedge.wait() } else { delivered.set() }
        })
        // A build whose press waits on the command would hang this thread on
        // the very stub that never returns. The harness gives up on its own.
        let giveUp = DispatchWorkItem {
            print("mediacheck: a press waited on a command that never returned, and the suite hung")
            exit(1)
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + 20, execute: giveUp)
        defer { giveUp.cancel() }
        let m = MediaManager(bridge: bridge)
        m.apply(snapshot())
        let before = m.isPlaying

        // The handler returns at once and the button has already flipped: the
        // call is dispatched, not awaited.
        let started = Date()
        m.playPause()
        let took = Date().timeIntervalSince(started)
        require(took < 0.05, "the press blocked its caller for \(fmt(took))s behind a command that never returned")
        require(m.isPlaying != before, "the button did not flip while the player was still deciding")

        // A press made while the first is still stuck is dropped or queued
        // behind it; once the lane is abandoned at the command deadline the
        // next one must get through on a fresh lane.
        settle(0.2)
        require(!delivered.isSet, "a second command ran while the first was still on the same lane")
        let gaveUp = Date()
        var arrived = false
        while Date().timeIntervalSince(gaveUp) < 8 {
            m.playPause()
            if waitUntil(0.25, { delivered.isSet }) { arrived = true; break }
        }
        wedge.signal()
        require(arrived, "no later press got through a command that never returned")
        let waited = Date().timeIntervalSince(gaveUp)
        require(waited < 6, "the press after a wedged command waited \(fmt(waited))s, past its deadline plus slack")
    }

    /// A wedged Spotify must not delay a healthy Music. Each player polls its
    /// own lane, so the healthy one is never behind the stalled one.
    static func aWedgedPlayerDoesNotHideTheOtherOne() {
        let wedge = DispatchSemaphore(value: 0)
        let bridge = MediaBridge(inert: true, stubbedRead: { source in
            if source == .spotify { wedge.wait() }
            return .idle
        })

        // Spotify's read is left in flight rather than waited out. Waiting would
        // let its deadline retire the lane, so even a single shared lane would
        // be clear by the time Music asks, and the check would pass against the
        // design it rejects.
        Task.detached { _ = await bridge.read(for: .spotify) }
        usleep(200_000)

        let (healthy, took) = read(bridge, .music, giveUpAfter: 10)
        wedge.signal()
        guard let healthy, case .idle = healthy else {
            require(false, "a wedged Spotify swallowed Music's read entirely")
            return
        }
        // Immediately, not eventually: a Music read that waited out Spotify's
        // deadline would still arrive but leave the panel behind on every poll.
        require(took < 0.5,
                "a wedged Spotify held Music's read up for \(fmt(took))s")
    }

    /// A player that comes back is owed its seats back. Once the budget is
    /// spent the lane is marked blocked and further reads must be refused rather
    /// than queued (a block per poll behind a thread that never runs is a slow
    /// leak); and when the player answers again, parked threads must refund
    /// their seats or the next stall is unsurvivable.
    static func aRecoveredPlayerGetsItsBudgetBack() {
        // A resettable flag rather than a semaphore: a semaphore signalled once
        // per parked thread keeps the surplus, and phase 4's read would walk
        // straight through it.
        let answering = Flag()
        let bridge = MediaBridge(inert: true, stubbedRead: { _ in
            while !answering.isSet { usleep(20_000) }
            return .idle
        })

        // Phase 1: fill the budget. One more read than the cap, because the last
        // one is the lane that gets kept rather than retired.
        for i in 0...MediaBridge.maxAbandoned {
            let (r, _) = read(bridge, giveUpAfter: 10)
            guard let r, case .unanswered = r else {
                answering.set(); require(false, "wedged read \(i) was not unanswered"); return
            }
        }
        require(bridge.parkedPollLanes(for: .spotify) == MediaBridge.maxAbandoned,
                "after \(MediaBridge.maxAbandoned + 1) wedged reads the bridge counts "
                + "\(bridge.parkedPollLanes(for: .spotify)) parked lanes, not "
                + "\(MediaBridge.maxAbandoned)")

        // Phase 2: one probe is allowed to wait behind the wedge, and exactly
        // one. The read after it is answered without being queued at all.
        let (probe, probeTook) = read(bridge, giveUpAfter: 10)
        guard let probe, case .unanswered = probe else {
            answering.set(); require(false, "the recovery probe was not unanswered"); return
        }
        require(probeTook >= MediaBridge.readDeadline - 0.1,
                "the probe answered in \(fmt(probeTook))s without waiting on the lane")

        let (refused, refusedTook) = read(bridge, giveUpAfter: 10)
        guard let refused, case .unanswered = refused else {
            answering.set(); require(false, "the refused read was not unanswered"); return
        }
        require(refusedTook < 0.5,
                "a read past a blocked lane was queued onto it anyway, taking "
                + "\(fmt(refusedTook))s — one more block behind a thread that "
                + "is never coming back, once per poll")

        // Phase 3: the player answers and every parked thread returns its seat.
        // Bounded waits, since the threads wake on their own schedule; the app
        // would see recovery on its next 1 Hz poll.
        answering.set()
        require(waitUntil(3.0) { bridge.parkedPollLanes(for: .spotify) == 0 },
                "the recovered player's seats never came back: "
                + "\(bridge.parkedPollLanes(for: .spotify)) still parked")
        require(waitUntil(3.0) {
                    let (r, _) = read(bridge, giveUpAfter: 10)
                    if let r, case .idle = r { return true }
                    return false
                },
                "reads never got through again after the player recovered")

        // Phase 4: the returned budget is spendable, not just a zeroed counter;
        // the next stall is retired out of it rather than refused.
        answering.clear()
        let (again, _) = read(bridge, giveUpAfter: 10)
        answering.set()
        guard let again, case .unanswered = again else {
            require(false, "the read after recovery was not wedged as arranged"); return
        }
        require(bridge.parkedPollLanes(for: .spotify) == 1,
                "a fresh stall after recovery parked "
                + "\(bridge.parkedPollLanes(for: .spotify)) lanes, not 1 — the "
                + "budget was not actually spendable again")
    }

    /// A parked thread refunds exactly one seat, and only into the budget it took
    /// one from. A lane can hold several blocks that all return together, so
    /// refunding per block would inflate the budget; and `invalidate` restores
    /// the whole budget while threads are still parked, so a later wake must not
    /// refund again.
    ///
    /// Gated on the queue label so one generation can be released while another
    /// stays wedged, the only way to observe either.
    static func aParkedThreadReturnsExactlyOneSeat() {
        let wedge = LaneWedge()
        let bridge = MediaBridge(inert: true, stubbedRead: { _ in
            wedge.hold(); return .idle
        })

        // Two concurrent reads on one lane, so both are admitted before either
        // deadline retires it.
        let both = DispatchGroup()
        for _ in 0..<2 {
            both.enter()
            Task.detached { _ = await bridge.read(for: .spotify); both.leave() }
        }
        guard both.wait(timeout: .now() + 10) == .success else {
            wedge.freeAll(); require(false, "the two concurrent reads never came back"); return
        }
        require(bridge.parkedPollLanes(for: .spotify) == 1,
                "two reads wedged on one lane retired it "
                + "\(bridge.parkedPollLanes(for: .spotify)) times, not once")

        // A second lane, so the count below has something to be wrong about.
        let (second, _) = read(bridge, giveUpAfter: 10)
        guard let second, case .unanswered = second else {
            wedge.freeAll(); require(false, "the second lane's read was not unanswered"); return
        }
        require(bridge.parkedPollLanes(for: .spotify) == 2,
                "a second wedged lane was not counted")

        // Release only the first lane. Both of its blocks come back; one seat
        // does.
        wedge.free(generation: 0)
        require(waitUntil(3.0) { bridge.parkedPollLanes(for: .spotify) == 1 },
                "releasing one lane's two blocks returned "
                + "\(2 - bridge.parkedPollLanes(for: .spotify)) seats, not one")

        // The player relaunches while a thread is still parked in the old world.
        bridge.invalidate(.spotify)
        require(bridge.parkedPollLanes(for: .spotify) == 0,
                "a relaunched player did not get its budget back")

        let (afterward, _) = read(bridge, giveUpAfter: 10)
        guard let afterward, case .unanswered = afterward else {
            wedge.freeAll(); require(false, "the post-relaunch read was not unanswered"); return
        }
        require(bridge.parkedPollLanes(for: .spotify) == 1,
                "the post-relaunch stall was not counted")

        // Wake the thread parked before the relaunch. `invalidate` already
        // returned its seat, so refunding again would leave the budget claiming
        // a free seat that is still occupied. Waited out rather than polled for:
        // the assertion is that the count does not move, and `waitUntil` on a
        // condition that already holds would return before the thread wakes.
        wedge.free(generation: 1)
        settle(1.0)
        require(bridge.parkedPollLanes(for: .spotify) == 1,
                "a thread parked before the relaunch refunded into the budget "
                + "that had already replaced its own, leaving "
                + "\(bridge.parkedPollLanes(for: .spotify)) seats claimed free")
        wedge.freeAll()
    }

    /// A player that has stopped answering is not a player with nothing to play.
    /// The panel holds its last frame until the stall note appears, using one
    /// patience and one counter so the frame clears on the same poll the note
    /// explaining it shows up.
    ///
    /// Tested through the pure rule: `refresh()` needs a running player.
    static func aStalledPanelHoldsItsLastFrame() {
        let patience = MediaManager.stallPatience
        func holds(stalled: Bool = true, foundTrack: Bool = false,
                   hasTrack: Bool = true, reads: Int) -> Bool {
            MediaManager.holdsLastFrame(stalled: stalled, foundTrack: foundTrack,
                                        hasTrack: hasTrack, stalledReads: reads)
        }

        require(holds(reads: 1), "the first unanswered poll tore the track off the panel")
        require(holds(reads: patience - 1),
                "the panel cleared before the note that explains it")
        require(!holds(reads: patience),
                "the panel held past its patience, so a player that stopped "
                + "answering leaves a frozen track on screen indefinitely")

        // Nothing to hold: this is the launch case, not a stall over a track.
        require(!holds(hasTrack: false, reads: 1),
                "an empty panel held a frame it never had")
        // The other player is playing; holding would let a stalled player hide
        // a healthy one.
        require(!holds(foundTrack: true, reads: 1),
                "a stall on one player swallowed the other player's track")
        // A player that answers "no" has answered; there is nothing to show.
        require(!holds(stalled: false, reads: 1),
                "a refused read was given the patience owed to a silent one")
    }

    /// Gives background work time to happen when the assertion is that nothing
    /// changes.
    static func settle(_ seconds: Double) { usleep(useconds_t(seconds * 1_000_000)) }

    /// Spins until the condition holds or the budget runs out. Refunds happen on
    /// each parked thread's own queue, after the read that proved recovery.
    static func waitUntil(_ seconds: Double, _ ok: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if ok() { return true }
            usleep(20_000)
        }
        return ok()
    }

    /// Drives one async read from a synchronous check. `giveUpAfter` keeps a
    /// build with no watchdog from hanging the suite instead of failing it.
    static func read(_ bridge: MediaBridge, _ source: MusicSource = .spotify,
                     giveUpAfter seconds: Double) -> (MediaBridge.Read?, Double) {
        let done = DispatchSemaphore(value: 0)
        let box = Answer()
        let started = Date()
        Task.detached {
            box.set(await bridge.read(for: source))
            done.signal()
        }
        let hung = done.wait(timeout: .now() + seconds) == .timedOut
        return (hung ? nil : box.get(), Date().timeIntervalSince(started))
    }

    static func fmt(_ v: Double) -> String { String(format: "%.2f", v) }

    /// A cover that was promised and failed to download is asked for again a
    /// bounded number of times. The fetch cannot be driven here, but its bound
    /// can: never retrying leaves a placeholder on a track that has a cover, and
    /// retrying forever turns a 404 into a request loop.
    ///
    /// The delay values are a judgement and are not asserted; the check covers
    /// every way the sequence could be shaped wrong.
    static func aPromisedCoverIsAskedForAgain() {
        require(MediaManager.artworkRetryDelay(attempt: 1) != nil,
                "a cover that failed to download was never asked for again, so a "
                + "single dropped request costs the track its artwork and its "
                + "whole colour field")

        // Bounded. Walk far past any plausible count rather than probing the one
        // attempt the rule happens to stop at.
        let attempts = 1...64
        guard let last = attempts.last(where: { MediaManager.artworkRetryDelay(attempt: $0) != nil })
        else {
            require(false, "no attempt was allowed at all")
            return
        }
        require(last < 64, "the retry never gives up, so a cover that does not "
                + "exist is requested for as long as the track plays")

        // The answered attempts form an unbroken run from the first, which also
        // makes giving up final. Checked as a prefix because "nil after the last
        // one" cannot fail: `last` is by construction the last answered attempt.
        //
        // Every wait is real and never shortens: zero would spin against the
        // network, and a shrinking delay would grow more insistent as hope
        // runs out.
        var previous: TimeInterval = 0
        for attempt in 1...last {
            guard let delay = MediaManager.artworkRetryDelay(attempt: attempt) else {
                require(false, "the rule had nothing to say about attempt "
                        + "\(attempt) and then answered again at \(last), so a "
                        + "retry resumes after it has given up — a task kept "
                        + "alive that looks bounded wherever it is probed")
                return
            }
            require(delay > 0, "attempt \(attempt) waits \(delay)s, so it retries in a spin")
            require(delay >= previous,
                    "attempt \(attempt) comes sooner than the one before it")
            previous = delay
        }
    }

    static func require(_ ok: Bool, _ message: @autoclosure () -> String) {
        if !ok { print("mediacheck: \(message())"); exit(1) }
    }
}

/// Counts calls across threads: the stub runs on the bridge's lane while the
/// check waits on the main thread.
final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func take() -> Int {
        lock.lock(); defer { count += 1; lock.unlock() }
        return count
    }
}

/// A stubbed player that can be unstuck one lane at a time.
///
/// The stub is told only the source, so the lane is identified from the dispatch
/// queue label, which carries the generation (`magnetite.media.read.spotify.2`).
/// Releasing by generation wakes one parked thread while its neighbours stay
/// wedged.
final class LaneWedge: @unchecked Sendable {
    private let lock = NSLock()
    private var freed = Set<Int>()
    private var all = false

    /// Called on a lane's queue. Returns when that lane has been released.
    func hold() {
        let label = String(cString: __dispatch_queue_get_label(nil))
        let generation = Int(label.split(separator: ".").last ?? "") ?? -1
        while !passes(generation) { usleep(20_000) }
    }

    private func passes(_ generation: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return all || freed.contains(generation)
    }

    func free(generation: Int) { lock.lock(); freed.insert(generation); lock.unlock() }
    func freeAll() { lock.lock(); all = true; lock.unlock() }
}

/// Whether the stubbed player is answering yet. Flipped from the check's thread
/// and read on the bridge's lanes.
final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
    func set() { lock.lock(); value = true; lock.unlock() }
    func clear() { lock.lock(); value = false; lock.unlock() }
}

final class Answer: @unchecked Sendable {
    private let lock = NSLock()
    private var value: MediaBridge.Read?
    func set(_ v: MediaBridge.Read) { lock.lock(); value = v; lock.unlock() }
    func get() -> MediaBridge.Read? { lock.lock(); defer { lock.unlock() }; return value }
}
