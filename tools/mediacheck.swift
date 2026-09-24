import Foundation

/// Headless checks on the media surface — the reconciliation between what the
/// user just pressed and what the player says a moment later.
///
/// Every manager here takes an INERT bridge. The toggles dispatch real commands,
/// so with Music running and a track loaded this suite would otherwise have sent
/// a live Apple Event and favourited whatever was playing.
///
/// None of this had coverage. It is the same shape of state logic that produced
/// the settled-gate bug: cheap to get subtly wrong, invisible until it is wrong
/// in front of someone.
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
        aRecoveredPlayerGetsItsBudgetBack()
        aParkedThreadReturnsExactlyOneSeat()
        aStalledPanelHoldsItsLastFrame()
        aPromisedCoverIsAskedForAgain()
        aResumeStartsFromWhereItPaused()
        aPauseKeepsThePlayerOnScreen()
        aShortItemDoesNotFreezeThePanel()
        print("mediacheck: all checks passed")
    }

    /// Pausing the player on screen does not hand the panel to another one.
    ///
    /// Spotify is asked first, so with both paused the first answer used to
    /// win: pause Music while a paused Spotify sat behind it and the panel
    /// jumped to Spotify's track.
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

    /// A short item keeps the track on screen, but not as playing.
    ///
    /// Held as playing, the track's line ran to its end and stayed there for as
    /// long as the short item stayed current in the player.
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

    /// A resume starts from where it paused, not from when.
    ///
    /// The interpolation clock was anchored at the last position CHANGE, and a
    /// pause changes nothing — so pressing play after a pause elapsed the whole
    /// pause at once. Clamped to the track's end, the progress line ran all the
    /// way round the panel's edge and snapped back on the next poll. Both doors
    /// in: the press here, and a resume made in the player itself.
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

    /// The arrival beat is observed from the track token, which carries no
    /// direction — so the direction is recorded at the press and consumed when
    /// the new track lands. It must expire, and it must be taken exactly once, or
    /// a later organic advance inherits a lean it did not earn.
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

    /// Optimistic holds. The glyph must light under the finger and the poll must
    /// not argue with it — but the hold has to end, or one press would pin the
    /// interface out of step with the player for the rest of the session.
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

        // A track change ends every hold: the values belong to the old track.
        //
        // On its own manager, and with nothing applied in between. Folded into
        // the sequence above, an intervening poll that happens to AGREE with the
        // press releases the hold naturally, and the check passes whether or not
        // a track change would have released it — which is exactly how this
        // assertion was vacuous when first written.
        let fresh = MediaManager(bridge: MediaBridge(inert: true))
        fresh.apply(snapshot(.music, liked: false))
        fresh.toggleLike()
        require(fresh.liked == true, "the press did not take")
        fresh.apply(snapshot(.music, identity: "spotify:track:other", liked: false))
        require(fresh.liked == false,
                "the hold survived a track change and lied about the new one")
    }

    /// `nil` means the player did not answer, and the control is not drawn. It
    /// must never collapse into `false`, which would render a live-looking
    /// control that does nothing — Spotify cannot report or set `starred` at all.
    ///
    /// For Spotify a mode the BRIDGE answers is still not a mode the bridge can
    /// set: `shuffling` and `repeating` are declared settable in its dictionary
    /// and the write is silently dropped. So its modes come from the Web API and
    /// a bridge answer is deliberately ignored — showing it would be exactly the
    /// live-looking control that does nothing. Apple Music takes the write, so
    /// there its answer is the one that counts.
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

        // Losing the track clears everything, rather than stranding the last
        // track's modes on an empty panel.
        //
        // Asserted on the Apple Music manager, because it is the only one here
        // with anything to lose. This ran on `m` — Spotify, whose modes come
        // from `webModes` and are already nil with no connection — so all three
        // comparisons were nil against nil and the assertion could not fail
        // however the clears were broken.
        music.apply(nil)
        require(music.liked == nil && music.shuffling == nil && music.repeating == nil,
                "modes outlived the track")
    }

    /// Pausing Spotify makes `/me/player` answer 204, which arrives here as "no
    /// modes" rather than "shuffle is off". Wiping them on that took both toggles
    /// off the panel every time the music stopped.
    ///
    /// Tested through the pure decision rather than through `askPlayback`, which
    /// bails on `isConnected` and can never reach this headlessly — an assertion
    /// there would pass no matter what the rule said.
    static func aPauseDoesNotTakeTheTogglesAway() {
        let playing = SpotifyWeb.Playback(shuffling: true, repeating: true,
                                          canShuffle: true, canRepeat: true)
        // The 204. The values survive so the glyphs stay put...
        let paused = SpotifyWeb.modes(from: nil, keeping: playing)
        require(paused?.shuffling == true && paused?.repeating == true,
                "a pause reset the toggles instead of holding the last answer")
        // ...and both writes are marked refused. `apply` recomputes the blocked
        // flags from these on every poll, so carrying `canShuffle: true` through
        // would leave a bright button whose write is about to fail — which is the
        // live-looking-control rule this file already enforces next door.
        require(paused?.canShuffle == false && paused?.canRepeat == false,
                "a kept answer still claimed the toggles were writable")

        // A fresh answer always wins, including one that disagrees.
        let stopped = SpotifyWeb.Playback(shuffling: false, repeating: false,
                                          canShuffle: true, canRepeat: true)
        let fresh = SpotifyWeb.modes(from: stopped, keeping: playing)
        require(fresh?.shuffling == false && fresh?.canShuffle == true,
                "a live answer was overruled by the one before it")

        // Nothing to keep is still nothing — launching while paused shows no
        // toggles rather than inventing a state for them.
        require(SpotifyWeb.modes(from: nil, keeping: nil) == nil,
                "modes were conjured from no answer at all")
    }

    /// A pause is a reason to ask again what the toggles can still do.
    ///
    /// `aPauseDoesNotTakeTheTogglesAway` proves the app handles the 204
    /// correctly once it has one. This is the half before that: whether anything
    /// goes and gets it. Spotify restricts shuffle and repeat while playback is
    /// stopped and drops the desktop app off Connect entirely, so a pause moves
    /// what the buttons can do without moving the track — and nothing re-asked
    /// on that transition. The identity gate sees no track change, and
    /// `beginPolling`'s ask sits below a guard that returns early while the
    /// panel's token is already in the set, which it always is while the panel
    /// is open. So `apply` went on recomputing `shuffleBlocked` from the cached
    /// answer once a second for the rest of the track, in both directions: a
    /// bright button whose write Spotify refuses, and a dimmed one on a player
    /// that would now take it.
    ///
    /// Through the pure decision for the same reason as the check above:
    /// `askPlayback` bails on `isConnected` and cannot run headlessly, so an
    /// assertion there would pass whatever the rule said.
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

        // The half that pulls the other way. `apply` runs once a second against
        // a rate-limited endpoint, so "ask more often" is not a free fix.
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

    /// `identity` falls back to a synthesised title/artist key when a player
    /// gives no id. Handing that to a URL would produce a nonsense link.
    static func onlyARealTrackURLIsShareable() {
        let m = MediaManager(bridge: MediaBridge(inert: true))
        m.apply(snapshot(identity: "spotify:track:2lLzW4bflris4pkw67edvg"))
        require(m.shareURL?.absoluteString
                == "https://open.spotify.com/track/2lLzW4bflris4pkw67edvg",
                "the share link is not the track's page (\(m.shareURL?.absoluteString ?? "nil"))")

        m.apply(snapshot(.music, identity: "Swim\u{1}Artist\u{1}Album"))
        require(m.shareURL == nil, "a synthesised identity was offered as a link")
    }

    /// A player that takes the event and never answers costs one read, not the
    /// app.
    ///
    /// This is the failure as it was found, not one imagined for a test: an
    /// instance with `magnetite.media.read` pinned inside `AESendMessage` under
    /// `playerState`, identically across two `sample` runs, more than an hour
    /// after launch and with the connection's own timeout set. Nothing rendered
    /// for that whole hour.
    ///
    /// Two independent things have to hold, and only the first is about the
    /// deadline. The read has to come back at all — it is answered off the
    /// blocked thread, so it can. And the *next* read has to be free of it: the
    /// queue is serial, so unless the wedged lane is retired, every later read
    /// simply waits behind the first one for as long as it lasts.
    ///
    /// What the stub does NOT reach, in this check or the three below: it
    /// short-circuits `readSync`, so `readApp`/`snapshot` and the per-lane
    /// ScriptingBridge connections never run. These prove the lane accounting.
    /// They would stay green if the connections were moved back off the lane
    /// onto the bridge — which is a crash, not merely staleness, since the
    /// parked thread and the fresh lane's thread would then be mutating one
    /// dictionary from two queues. Covering that needs a seam below the
    /// connection, stubbing `connect` rather than the whole read.
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
        // Measured against the bridge's own constant, so this cannot quietly
        // start passing because the deadline was changed underneath it.
        //
        // Bounded from ABOVE as well, which it was not: with only a floor, a
        // watchdog that had stopped firing at all still passed this line, since
        // the harness's own 10s give-up answers late rather than never. The
        // upper slack is generous because a loaded machine can delay a timer
        // queue, not because 1.5s is approximate.
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

    /// A wedged Spotify must not hide a perfectly healthy Music.
    ///
    /// This is the half of the original outage that the first fix did not
    /// address: retiring the lane freed the *next* read, but one lane still
    /// served both players, so the next read was only free once the retirement
    /// had cost a deadline. Each player polls its own lane now, so the healthy
    /// one is never behind the stalled one at all.
    static func aWedgedPlayerDoesNotHideTheOtherOne() {
        let wedge = DispatchSemaphore(value: 0)
        let bridge = MediaBridge(inert: true, stubbedRead: { source in
            if source == .spotify { wedge.wait() }
            return .idle
        })

        // Spotify's read is left IN FLIGHT — not waited out first. Waiting for
        // it proves nothing: its deadline retires the lane on the way out, so
        // even a single shared lane is clear again by the time the next read is
        // asked for, and this check passed against exactly the design it was
        // written to reject. Music has to ask while Spotify is still stuck.
        Task.detached { _ = await bridge.read(for: .spotify) }
        usleep(200_000)

        let (healthy, took) = read(bridge, .music, giveUpAfter: 10)
        wedge.signal()
        guard let healthy, case .idle = healthy else {
            require(false, "a wedged Spotify swallowed Music's read entirely")
            return
        }
        // Not "eventually": immediately. A Music read that waited out Spotify's
        // deadline would still arrive, and the panel would still be a second and
        // a half behind the music on every poll.
        require(took < 0.5,
                "a wedged Spotify held Music's read up for \(fmt(took))s")
    }

    /// A player that comes back is owed its seats back.
    ///
    /// Two failures live here, both of which shipped. Once every seat is taken
    /// the lane is kept and marked, and reads after that must be REFUSED rather
    /// than queued onto it — a block per poll behind a thread that will never
    /// run any of them is a slow leak dressed as patience. And when the player
    /// finally answers, the parked threads have to hand their seats back, or the
    /// bridge stays permanently out of budget and the next stall is unsurvivable.
    static func aRecoveredPlayerGetsItsBudgetBack() {
        // A gate rather than a semaphore, because this one has to close again:
        // a semaphore signalled once per parked thread keeps the surplus, and
        // phase 4's read walked straight through it.
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

        // Phase 3: the player answers. Every parked thread returns its seat.
        //
        // Bounded waits rather than one immediate read: the parked threads wake
        // on their own schedule, so recovery is observable from the poll after
        // they do, not from the same instant the player starts answering. The
        // app polls at 1Hz and would see it on the next tick.
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

        // Phase 4: and the returned budget is real, not just a zeroed counter —
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

    /// A parked thread hands back exactly one seat, and only into the budget it
    /// took one from.
    ///
    /// Both halves are guards that survive every check above, because both only
    /// bite when more than one thing is outstanding at once. A lane can hold
    /// several blocks — reads issued before it was retired — and they all come
    /// back when the player does; if each refunds, the budget inflates and the
    /// cap stops bounding anything. And `invalidate` returns the whole budget
    /// while threads are still parked in it, so a thread that wakes afterwards
    /// is refunding a seat that has already been given back.
    ///
    /// Gated on the queue label so one generation can be released while another
    /// stays wedged, which is the only way to observe either.
    static func aParkedThreadReturnsExactlyOneSeat() {
        let wedge = LaneWedge()
        let bridge = MediaBridge(inert: true, stubbedRead: { _ in
            wedge.hold(); return .idle
        })

        // Two reads on one lane. Concurrent, so both are admitted before either
        // deadline retires it — a lane with two blocks on it is the whole point.
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

        // Now wake the thread that was parked before the relaunch. Its seat was
        // handed back by `invalidate` already; handing it back again would leave
        // the budget claiming a free seat that is still occupied.
        // Waited out rather than polled for: the assertion is that the count
        // does NOT move, and a `waitUntil` on a condition that already holds
        // returns before the thread it is about has even woken.
        wedge.free(generation: 1)
        settle(1.0)
        require(bridge.parkedPollLanes(for: .spotify) == 1,
                "a thread parked before the relaunch refunded into the budget "
                + "that had already replaced its own, leaving "
                + "\(bridge.parkedPollLanes(for: .spotify)) seats claimed free")
        wedge.freeAll()
    }

    /// A player that has stopped answering is not a player with nothing to play.
    ///
    /// The panel used to blank 1.5s into any stall, then replay its entrance
    /// animation when the player came back — while the note explaining the stall
    /// waited three polls before it would even name it. One patience, one
    /// counter, so the frame clears on the same beat the note that explains it
    /// appears.
    ///
    /// Tested through the pure rule rather than through `refresh()`, which needs
    /// a running player to reach this at all — an assertion there would pass no
    /// matter what the rule said.
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
        // The other player is playing. Holding here would be the wedged-Spotify-
        // hides-a-healthy-Music failure again, one layer up from the lanes.
        require(!holds(foundTrack: true, reads: 1),
                "a stall on one player swallowed the other player's track")
        // A player that answers "no" has answered, and what it said is that
        // there is nothing to show.
        require(!holds(stalled: false, reads: 1),
                "a refused read was given the patience owed to a silent one")
    }

    /// Gives background work time to happen when the assertion is that nothing
    /// changes.
    static func settle(_ seconds: Double) { usleep(useconds_t(seconds * 1_000_000)) }

    /// Spins until the condition holds or the budget runs out.
    ///
    /// The refund happens on each parked thread's own queue, so it is ordered
    /// after the read that proved recovery, not before it.
    static func waitUntil(_ seconds: Double, _ ok: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if ok() { return true }
            usleep(20_000)
        }
        return ok()
    }

    /// Drives one async read from a synchronous check.
    ///
    /// `giveUpAfter` is not belt-and-braces: without it, a build whose watchdog
    /// had been removed would hang this suite instead of failing it, and a suite
    /// that hangs reports nothing at all.
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

    /// A cover that was promised and did not download is asked for again, a
    /// bounded number of times.
    ///
    /// The fetch is a network round trip and nothing here can drive it. The
    /// bound is the checkable half, and it is the half with two wrong answers
    /// available: never ask again and one dropped packet leaves a placeholder
    /// and a neutral colour field on a track that has a cover, for as long as it
    /// plays; ask forever and a 404 becomes a request loop that outlives the
    /// album.
    ///
    /// The delays themselves are a judgement and are not asserted here — that
    /// would only be the constants restated. What is asserted is every way the
    /// sequence could be shaped wrong.
    static func aPromisedCoverIsAskedForAgain() {
        require(MediaManager.artworkRetryDelay(attempt: 1) != nil,
                "a cover that failed to download was never asked for again, so a "
                + "single dropped request costs the track its artwork and its "
                + "whole colour field")

        // Bounded. Walk far past any plausible count rather than probing the
        // one attempt the rule happens to stop at, which would pass against a
        // rule that stops somewhere else and never.
        let attempts = 1...64
        guard let last = attempts.last(where: { MediaManager.artworkRetryDelay(attempt: $0) != nil })
        else {
            require(false, "no attempt was allowed at all")
            return
        }
        require(last < 64, "the retry never gives up, so a cover that does not "
                + "exist is requested for as long as the track plays")

        // The attempts it answers to are a run from the first, with no hole in
        // it — which is also what makes giving up final, since a rule that
        // resumed would have to leave one. Asserted as a prefix rather than as
        // "nil after the last one" because that second form cannot fail: `last`
        // is by construction the last attempt with an answer.
        //
        // Every wait in the run is real and never shortens. A zero spins the
        // task against the network as fast as it will answer; a shrinking one is
        // a retry getting more insistent as it runs out of reasons to hope.
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

/// Both exist because the check reaches across threads: the stub runs on the
/// bridge's lane, the answer arrives on whichever queue resumed it, and the
/// check itself is waiting on the main thread.
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
/// Which lane a block is on is not something the stub is told — it is handed
/// only the source. The dispatch queue label carries it, because the bridge puts
/// the generation there for exactly this kind of after-the-fact identification:
/// `magnetite.media.read.spotify.2`. Releasing by generation is the only way to
/// wake one parked thread while its neighbours stay wedged, and without that,
/// every refund is indistinguishable from every other.
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
