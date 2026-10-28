import Foundation

/// Headless checks for synced lyrics: LRC parsing, the line at a position and the
/// choice between LRCLIB's records. Pure data, so no network or player is involved.
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
    }

    static func searchTermsLoseThePlayersDecoration() {
        require(LyricsRecord.searchTitle("Song - Remastered 2011") == "Song", "remaster suffix")
        require(LyricsRecord.searchTitle("Song (feat. X)") == "Song", "feature credit")
        require(LyricsRecord.searchTitle("- Intro") == "- Intro", "a leading dash is the title")
        require(LyricsRecord.searchArtist("Aria, Beck & Cleo") == "Aria", "first credit only")
    }
}
