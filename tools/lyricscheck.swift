import Foundation

/// Headless checks for synced lyrics: LRC parsing, the line at a position, the choice
/// between LRCLIB's records and the NetEase fallback. Pure data, so no network or
/// player is involved.
@main
enum LyricsCheck {
    static var failures = 0

    static func require(_ ok: Bool, _ message: String) {
        if !ok { failures += 1; print("lyricscheck: FAILED | \(message)") }
    }

    static func main() {
        parsesStampsTagsAndOffsets()
        breaksAreKeptOnlyWhenLong()
        theLineFollowsThePositionBothWays()
        theCountInRunsAcrossItsBreak()
        picksTheRecordOfTheRightLength()
        searchTermsLoseThePlayersDecoration()
        aDecoratedVersionIsAskedForByItsWholeName()
        onlyRealAnswersAreKept()
        creditsAndLabelsAreNotSung()
        aDownLRCLIBFallsBackToNetEase()
        netEaseIsHeldToTheArtistAndLength()
        anotherSongOfTheSameLengthIsNotTheSong()
        if failures > 0 { exit(1) }
        print("lyricscheck: all checks passed")
    }

    static func parsesStampsTagsAndOffsets() {
        let lrc = """
            [ar:Someone]
            [offset:+500]
            [00:12.50]Second
            [00:01.00][00:20.00]First and again
            not a lyric line
            """
        guard let l = SyncedLyrics(lrc: lrc) else { return require(false, "valid LRC did not parse") }
        require(l.lines.map(\.text) == ["First and again", "Second", "First and again"],
                "lines are out of order or a repeated stamp was dropped: \(l.lines.map(\.text))")
        require(abs(l.lines[0].time - 0.5) < 0.001, "a positive offset must bring lines forward")
        require(SyncedLyrics(lrc: "plain words\nno stamps") == nil, "unsynced text must not parse")
        require(SyncedLyrics(lrc: "[00:01.00]\n[00:05.00]") == nil, "only breaks is no lyrics")
    }

    static func breaksAreKeptOnlyWhenLong() {
        let l = SyncedLyrics(lrc: """
            [00:09.00]One
            [00:11.00]
            [00:12.00]Two
            [00:20.00]
            [00:21.00]
            [00:30.00]Three
            [00:40.00]
            """)!
        require(l.lines.first?.isBreak == true && l.lines.first?.time == 0,
                "a 9 s intro needs a count-in")
        require(l.lines.map(\.text) == ["", "One", "Two", "", "Three"],
                "short breaks stay, runs merge, trailing breaks go: \(l.lines.map(\.text))")
        let quick = SyncedLyrics(lrc: "[00:02.00]Straight in")!
        require(quick.lines.count == 1, "a 2 s intro is not a break")
    }

    static func theLineFollowsThePositionBothWays() {
        let l = SyncedLyrics(lrc: "[00:01.00]A\n[00:03.00]B\n[00:06.00]C")!
        let lead = SyncedLyrics.lead
        require(l.index(at: 0) == 0, "before the first stamp the first line shows")
        require(l.index(at: 3 - lead - 0.01) == 0, "a line must not show before its lead")
        require(l.index(at: 3 - lead) == 1, "a line shows from its stamp less the lead")
        require(l.index(at: 100) == 2, "the last line holds to the end")
        // A seek backwards is just an earlier position: no state to unwind.
        require(l.index(at: 1.5) == 0, "seeking back must return to the earlier line")
    }

    static func theCountInRunsAcrossItsBreak() {
        let l = SyncedLyrics(lrc: "[00:10.00]Words")!
        let lead = SyncedLyrics.lead
        require(l.breakProgress(at: -lead, index: 0) == 0, "the count-in starts empty")
        let half = l.breakProgress(at: 5 - lead, index: 0) ?? -1
        require(abs(half - 0.5) < 0.001, "halfway through the intro is half lit, got \(half)")
        require(l.breakProgress(at: 11, index: 1) == nil, "a sung line has no count-in")
    }

    static func picksTheRecordOfTheRightLength() {
        func r(_ d: Double, _ album: String, synced: Bool = true, instrumental: Bool = false) -> LyricsRecord {
            LyricsRecord(trackName: "T", artistName: "A", albumName: album, duration: d,
                         instrumental: instrumental, syncedLyrics: synced ? "[00:01.00]x" : nil)
        }
        let picked = LyricsRecord.best(of: [r(187, "I'LL LIKE YOU"), r(161, "Other"),
                                            r(160, "I’LL LIKE YOU"), r(160, "x", synced: false)],
                                       duration: 160, album: "I'LL LIKE YOU")
        require(picked?.albumName == "I’LL LIKE YOU",
                "nearest length, then the album with its quote folded, got \(String(describing: picked))")
        require(LyricsRecord.best(of: [r(200, "a")], duration: 160, album: "a") == nil,
                "a different edit must not be used: its stamps drift")
        require(LyricsRecord.best(of: [r(160, "a", synced: false)], duration: 160, album: "a") == nil,
                "plain lyrics cannot be synced")
        require(LyricsRecord.best(of: [r(160, "a", synced: false, instrumental: true)],
                                  duration: 160, album: "a")?.instrumental == true,
                "an instrumental answer is still an answer")
        func t(_ name: String) -> LyricsRecord {
            LyricsRecord(trackName: name, artistName: "A", albumName: "Single", duration: 147,
                         instrumental: false, syncedLyrics: "[00:01.00]x")
        }
        let version = LyricsRecord.best(of: [t("plot twist"), t("Plot Twist (English ver.) (Cat Dealers Remix)"),
                                             t("Plot Twist (English ver.)")],
                                        duration: 147, album: "Other", title: "Plot Twist - English ver.")
        require(version?.trackName == "Plot Twist (English ver.)",
                "one length, two languages: the title picks the version, got \(String(describing: version))")

        // LRCLIB's only synced Crush "Seesaw (ft. IU)": its 171 s is where its credit
        // sits, and Spotify's "seesaw (Feat. IU)" runs 181 s.
        let seesaw = LyricsRecord(trackName: "Seesaw (ft. IU)", artistName: "Crush", albumName: "Seesaw",
                                  duration: 171, instrumental: false, syncedLyrics: """
            [00:10.00]Dwijukbakjuk
            [02:41.00]Du ru du du
            [02:46.00]
            [02:51.00]{more Crush lyrics at lyricsify.com/u/KPopLRCFiles}
            """)
        require(LyricsRecord.best(of: [seesaw], duration: 181, album: "seesaw (Feat. IU)",
                                  title: "seesaw (Feat. IU)") != nil,
                "a length that is only the last stamp must not hide the lyrics")
        var edit = seesaw
        edit.syncedLyrics = "[00:10.00]Dwijukbakjuk\n[02:41.00]Du ru du du"
        require(LyricsRecord.best(of: [edit], duration: 181, album: "Seesaw") == nil,
                "a real 171 s recording 10 s short of the track is another edit")
        require(LyricsRecord.best(of: [seesaw], duration: 200, album: "Seesaw") == nil,
                "a guessed length still has to be near the track")
    }

    static func searchTermsLoseThePlayersDecoration() {
        require(LyricsRecord.searchTitle("Song - Remastered 2011") == "Song", "remaster suffix")
        require(LyricsRecord.searchTitle("Song (feat. X)") == "Song", "feature credit")
        require(LyricsRecord.searchTitle("Misty (MINA)") == "Misty",
                "any trailing bracket: LRCLIB files the synced Misty (MINA) as Misty")
        require(LyricsRecord.searchTitle("(I Can't Get No) Satisfaction") == "(I Can't Get No) Satisfaction",
                "a leading bracket is the title")
        require(LyricsRecord.searchTitle("- Intro") == "- Intro", "a leading dash is the title")
        require(LyricsRecord.searchArtist("Aria, Beck & Cleo") == "Aria", "first credit only")
    }

    /// LRCLIB's search answers with 20 records at most. Asked for "Hotel California" by
    /// Eagles it returned 20 studio takes and none of the 421 s live one, which it
    /// returned at once for "Hotel California - Live"; the player's title is asked
    /// second, so a miss on the plain title no longer ends the lookup.
    static func aDecoratedVersionIsAskedForByItsWholeName() {
        require(LyricsRecord.searchTitles("Hotel California - Live")
                    == ["Hotel California", "Hotel California - Live"],
                "a decorated title is asked plain, then whole: \(LyricsRecord.searchTitles("Hotel California - Live"))")
        require(LyricsRecord.searchTitles("Yellow") == ["Yellow"], "a plain title is asked once")
        require(LyricsRecord.searchTitles("(I Can't Get No) Satisfaction") == ["(I Can't Get No) Satisfaction"],
                "a title that is all bracket is asked once")
        func r(_ name: String, _ d: Double) -> LyricsRecord {
            LyricsRecord(trackName: name, artistName: "Eagles", albumName: "x", duration: d,
                         instrumental: false, syncedLyrics: "[00:01.00]x")
        }
        let studio = (0..<20).map { r("Hotel California", 390 + Double($0 % 3)) }
        require(LyricsRecord.best(of: studio, duration: 421, album: "Hell Freezes Over",
                                  title: "Hotel California - Live") == nil,
                "twenty studio takes hold no 421 s record")
        require(LyricsRecord.best(of: [r("Hotel California - Live", 421)], duration: 421,
                                  album: "Hell Freezes Over", title: "Hotel California - Live") != nil,
                "the whole-name search holds it")
    }

    /// LRCLIB answers a busy server with 429, or a 503 "ServerOverloaded" on about one
    /// request in ten. Only 200 and 404 are answers; a miss built on anything else was
    /// kept for three days and hid a song LRCLIB has.
    static func onlyRealAnswersAreKept() {
        require(LyricsRecord.answered(status: 200) && LyricsRecord.answered(status: 404),
                "a record and a not-found are answers")
        for status in [429, 500, 502, 503, 504] as [Int?] + [nil] {
            require(!LyricsRecord.answered(status: status),
                    "status \(String(describing: status)) is no answer about the song")
        }
        require(LyricsRecord.isBusy(status: 503) && LyricsRecord.isBusy(status: 429),
                "overloaded and rate-limited replies are asked again")
        require(!LyricsRecord.isBusy(status: 404) && !LyricsRecord.isBusy(status: 200),
                "a not-found is final")
    }

    static func creditsAndLabelsAreNotSung() {
        // The tail of LRCLIB's ILLIT "Pop Pop", as the owner saw it under the player.
        let tail = SyncedLyrics(lrc: """
            [02:16.00]Pop Pop
            [02:21.00]
            [02:26.00]{more ILLIT lyrics at lyricsify.com/u/KPopLRCFiles}
            """)!
        require(tail.lines.map(\.text) == ["", "Pop Pop"],
                "a source credit must not show as a line: \(tail.lines.map(\.text))")
        let l = SyncedLyrics(lrc: """
            [00:00.00]작사 : Someone
            [00:00.50]Lyrics by Someone
            [00:01.00]Words
            [00:03.00][Chorus]
            [00:09.00](Wait for you)
            [00:11.00]Lyrics from www.example.com
            """)!
        require(l.lines.map(\.text) == ["Words", "(Wait for you)"],
                "credits and labels go, a sung aside stays: \(l.lines.map(\.text))")
        require(SyncedLyrics.isCredit("{Synced by KPopLRCFiles}"), "a braced line is never sung, address or not")
        require(!SyncedLyrics.isCredit("Music by the sea"), "a sung line that starts like a credit stays")
    }

    /// 2026-10-31 LRCLIB's API answered 502 to every request all day, and with it as
    /// the only source no song showed lyrics. A failed LRCLIB question now goes to
    /// NetEase, and only two misses are kept as a miss.
    static func aDownLRCLIBFallsBackToNetEase() {
        let found = LyricsRecord(trackName: "T", artistName: "A", albumName: "B", duration: 138,
                                 instrumental: false, syncedLyrics: "[00:09.08]Moon")
        let failed: LyricsRecord?? = nil, missed: LyricsRecord?? = .some(nil)
        require(LyricsRecord.either(failed, .some(found)) == .some(found),
                "LRCLIB down: NetEase's words must show")
        require(LyricsRecord.either(missed, .some(found)) == .some(found),
                "LRCLIB without the song: NetEase's words must show")
        require(LyricsRecord.either(.some(found), failed) == .some(found), "LRCLIB's record comes first")
        require(LyricsRecord.either(missed, missed) == .some(nil), "two misses are a miss to keep")
        require(LyricsRecord.either(failed, missed) == nil && LyricsRecord.either(missed, failed) == nil,
                "a miss beside a failure is asked again, not kept for three days")

        // The reply shapes music.163.com gave for Mitski's "My Love Mine All Mine".
        let search = Data(#"""
            {"result":{"songs":[
              {"id":2082156813,"name":"My Love Mine All Mine","artists":[{"id":1,"name":"Mitski"}],
               "album":{"id":2,"name":"The Land Is Inhospitable and So Are We"},"duration":137773},
              {"id":2614347892,"name":"My Love Mine All Mine","artists":[{"name":"Kastiar"},{"name":"Mitski"}],
               "album":{"name":"My Love Mine All Mine"},"duration":114335}],"songCount":2},"code":200}
            """#.utf8)
        guard let songs = NetEaseLyrics.songs(fromSearch: search) else {
            return require(false, "a NetEase search reply did not decode")
        }
        require(songs.first?.record.duration == 137.773, "NetEase lengths are milliseconds")
        let lyric = Data(#"""
            {"lrc":{"version":7,"lyric":"[00:00.000] 作词 : Mitski Miyawaki\n[00:01.000] 作曲 : Mitski Miyawaki\n[00:02.000] 制作人 : Patrick Hyland\n[00:09.082] Moon, a hole of light\n[00:12.716] Through the big top tent up high\n"},"code":200}
            """#.utf8)
        let words = NetEaseLyrics.lyric(from: lyric)
        require(words?.instrumental == false && words?.synced != nil, "NetEase's timed LRC is synced lyrics")
        let lines = words?.synced.flatMap(SyncedLyrics.init(lrc:))?.lines.filter { !$0.isBreak }.map(\.text)
        require(lines == ["Moon, a hole of light", "Through the big top tent up high"],
                "NetEase's credit lines are not sung: \(String(describing: lines))")
        require(NetEaseLyrics.lyric(from: Data(#"{"uncollected":true,"lrc":{"lyric":""},"code":200}"#.utf8))
                    .map { $0.synced == nil && !$0.instrumental } == true,
                "a song NetEase has no words for is a miss")
        require(NetEaseLyrics.lyric(from: Data(#"{"pureMusic":true,"code":200}"#.utf8))?.instrumental == true,
                "pure music is an instrumental answer")
        require(NetEaseLyrics.songs(fromSearch: Data("error code: 502".utf8)) == nil
                    && NetEaseLyrics.lyric(from: Data(#"{"code":-460}"#.utf8)) == nil,
                "an error page is a failed question, not a miss")
    }

    static func netEaseIsHeldToTheArtistAndLength() {
        func song(_ id: Int, _ name: String, _ artists: String, _ album: String, _ d: Double) -> NetEaseLyrics.Song {
            NetEaseLyrics.Song(id: id, record: LyricsRecord(trackName: name, artistName: artists, albumName: album,
                                                            duration: d, instrumental: nil, syncedLyrics: nil))
        }
        // ILLIT "Magnetic" (160 s) as NetEase's search returns it: a live take, a remix,
        // a cover sharing the title, then the single.
        let found = [song(1, "Magnetic (Live)", "ILLIT", "쿨룩 LIVE", 165),
                     song(2, "Magnetic", "AUrora", "Magnetic", 159),
                     song(3, "Magnetic (Ferry Remix)", "ILLIT", "", 173.6),
                     song(4, "Magnetic", "ILLIT", "SUPER REAL ME", 160.5),
                     song(5, "Magnetic", "ILLIT", "Magnetic (Sped Up)", 120)]
        let picks = NetEaseLyrics.candidates(found, artist: "ILLIT", duration: 160,
                                             album: "SUPER REAL ME", title: "Magnetic")
        require(picks.map(\.id) == [4], "only ILLIT's recording of this length: \(picks.map(\.id))")
        let duet = [song(7, "APT.", "Bruno Mars", "APT.", 170), song(8, "APT.", "ROSÉ, Bruno Mars", "APT.", 170)]
        require(NetEaseLyrics.candidates(duet, artist: "ROSÉ, Bruno Mars", duration: 170, album: "APT.",
                                         title: "APT.").map(\.id) == [8],
                "the first credited artist must be on the song, accent folded")
    }

    /// 2026-11-03 Shye's "Too Late" played with "Cecilia"'s words. Spotify's album edit
    /// runs 240 s and every timed "Too Late" is 249 s, so LRCLIB missed and NetEase's
    /// search for "Too Late Shye" offered her whole album; "Cecilia" (238 s) was the
    /// first by her within 3 s, and nothing asked for its title.
    static func anotherSongOfTheSameLengthIsNotTheSong() {
        func song(_ id: Int, _ name: String, _ d: Double) -> NetEaseLyrics.Song {
            NetEaseLyrics.Song(id: id, record: LyricsRecord(trackName: name, artistName: "Shye",
                                                            albumName: "The Doves Came Home", duration: d,
                                                            instrumental: nil, syncedLyrics: nil))
        }
        let found = [song(3375205164, "Too Late", 249.107), song(535570356, "Before It's Too Late", 211.066),
                     song(3375205165, "Eclipse", 236.4), song(3375206881, "If Today Was Yesterday", 248.47),
                     song(3375205162, "Cecilia", 238.285)]
        let picks = NetEaseLyrics.candidates(found, artist: "Shye", duration: 240.015,
                                             album: "The Doves Came Home", title: "Too Late")
        require(picks.isEmpty, "only a 'Too Late' near 240 s is the song: \(picks.map(\.record.trackName))")
        require(NetEaseLyrics.candidates(found, artist: "Shye", duration: 249,
                                         album: "The Doves Came Home", title: "Too Late").map(\.id) == [3375205164],
                "the 249 s single is found by its title")
        func r(_ name: String) -> LyricsRecord {
            LyricsRecord(trackName: name, artistName: "Shye", albumName: "x", duration: 240,
                         instrumental: false, syncedLyrics: "[00:01.00]x")
        }
        require(LyricsRecord.best(of: [r("Cecilia"), r("Before It's Too Late"), r("Late")],
                                  duration: 240, album: "x", title: "Too Late") == nil,
                "LRCLIB's search is held to the title too")
        for (name, title) in [("Too late", "Too Late"), ("Hotel California (Live)", "Hotel California - Live"),
                              ("Hotel California", "Hotel California - Live"), ("Seesaw (ft. IU)", "seesaw (Feat. IU)"),
                              ("Misty", "Misty (MINA)"), ("I’LL LIKE YOU", "I'LL LIKE YOU")] {
            require(LyricsRecord.isSameSong(name, title), "\(name) is \(title)")
        }
    }
}
