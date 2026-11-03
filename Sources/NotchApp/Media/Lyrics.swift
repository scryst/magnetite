import Foundation

/// Time-synced lyrics as pure data: parsing, the line at a playback position and the
/// choice between LRCLIB's candidates. No networking, so `lyricscheck` and the
/// off-screen view hosts compile against this file alone.
struct SyncedLyrics: Equatable, Sendable {
    struct Line: Equatable, Sendable {
        var time: Double
        /// Empty for an instrumental break, drawn as a short count-in rather than words.
        var text: String
        var isBreak: Bool { text.isEmpty }
    }

    var lines: [Line]

    /// Lines are shown this far ahead of their stamp. A line that arrives exactly on
    /// the sung syllable reads late, because the eye needs the roll to finish first.
    static let lead: Double = 0.25

    /// A silence this long before the first line, or marked by an empty stamp, gets a
    /// break of its own. Shorter ones keep the previous line up, as a singer's breath
    /// does not end the line.
    static let minimumBreak: Double = 4

    /// Parses LRC: `[mm:ss.xx] text`, several stamps per line, `[offset:±ms]`, and
    /// metadata tags, which are skipped. Nil when nothing is timed.
    init?(lrc: String) {
        var offset = 0.0
        var stamped: [Line] = []
        for raw in lrc.split(whereSeparator: \.isNewline) {
            var rest = Substring(raw)
            var times: [Double] = []
            var labelled = false
            while rest.first == "[", let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                rest = rest[rest.index(after: close)...]
                if let t = Self.stamp(tag) {
                    times.append(t)
                } else if tag.lowercased().hasPrefix("offset:"),
                          let ms = Double(tag.dropFirst(7).trimmingCharacters(in: .whitespaces)) {
                    // A positive offset makes lyrics appear sooner.
                    offset = ms / 1000
                } else if !times.isEmpty {
                    labelled = true
                }
            }
            let text = rest.trimmingCharacters(in: .whitespaces)
            // A stamped "[Chorus]" is a label, not a silence to count in.
            if Self.isCredit(text) || (text.isEmpty && labelled) { continue }
            for t in times { stamped.append(Line(time: t, text: text)) }
        }
        guard !stamped.isEmpty else { return nil }
        stamped = stamped.map { Line(time: max(0, $0.time - offset), text: $0.text) }
            .sorted { $0.time < $1.time }

        // Breaks are kept only where they are long enough to read as one; a run of empty
        // stamps is one break.
        var lines: [Line] = []
        for (i, line) in stamped.enumerated() {
            if line.isBreak {
                let next = stamped[(i + 1)...].first { !$0.isBreak }
                guard let next, next.time - line.time >= Self.minimumBreak,
                      lines.last?.isBreak != true else { continue }
            }
            lines.append(line)
        }
        guard let first = lines.firstIndex(where: { !$0.isBreak }) else { return nil }
        lines.removeFirst(first)
        if lines[0].time >= Self.minimumBreak {
            lines.insert(Line(time: 0, text: ""), at: 0)
        }
        // Trailing breaks have nothing to count in to.
        while lines.last?.isBreak == true { lines.removeLast() }
        self.lines = lines
    }

    init(lines: [Line]) { self.lines = lines }

    /// Lines the uploading site added and nobody sings: "{more ILLIT lyrics at
    /// lyricsify.com/u/KPopLRCFiles}", a web address, or a credit such as "Lyrics by X",
    /// "작사 : X" or NetEase's "制作人 : X" (producer). A sung aside in parentheses is kept.
    static func isCredit(_ text: String) -> Bool {
        if text.hasPrefix("{") && text.hasSuffix("}") { return true }
        let t = text.lowercased()
        if t.range(of: #"[a-z0-9-]\.(com|net|org|io|kr|jp)\b"#, options: .regularExpression) != nil {
            return true
        }
        if t.range(of: #"^(lyrics?|lrc)( made)? by\b"#, options: .regularExpression) != nil
            || t.range(of: #"^more .*lyrics (at|on)\b"#, options: .regularExpression) != nil {
            return true
        }
        let label = #"^(作词|作詞|作曲|编曲|編曲|制作人|监制|和声|录音|混音|母带|작사|작곡|편곡|lyrics|lyricist|composer|music|producers?|(written|composed|arranged|produced) by)\s*[:：]"#
        return t.range(of: label, options: .regularExpression) != nil
    }

    /// The latest stamp in raw LRC, credit lines included, as the uploader left it.
    static func lastStamp(_ lrc: String) -> Double? {
        var last: Double?
        for raw in lrc.split(whereSeparator: \.isNewline) {
            var rest = Substring(raw)
            while rest.first == "[", let close = rest.firstIndex(of: "]") {
                if let t = stamp(rest[rest.index(after: rest.startIndex)..<close]) { last = max(last ?? t, t) }
                rest = rest[rest.index(after: close)...]
            }
        }
        return last
    }

    private static func stamp(_ tag: Substring) -> Double? {
        let parts = tag.split(separator: ":")
        guard parts.count == 2, let m = Double(parts[0]),
              let s = Double(parts[1].replacingOccurrences(of: ",", with: ".")),
              m >= 0, s >= 0, s < 60 else { return nil }
        return m * 60 + s
    }

    /// The line showing at `position`: the last whose stamp, less the lead, has passed.
    /// Before the first stamp it is the first line, so the intro shows what comes.
    func index(at position: Double) -> Int {
        let t = position + Self.lead
        var lo = 0, hi = lines.count - 1, found = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if lines[mid].time <= t { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return found
    }

    /// How far through a break `position` is, 0...1, for its count-in. Nil when the line
    /// at `index` is words.
    func breakProgress(at position: Double, index: Int) -> Double? {
        guard lines.indices.contains(index), lines[index].isBreak else { return nil }
        let start = lines[index].time
        let end = index + 1 < lines.count ? lines[index + 1].time : start + Self.minimumBreak
        let t = position + Self.lead
        return min(max((t - start) / max(end - start, 0.1), 0), 1)
    }
}

/// What LRCLIB returns for one recording, and how to pick between several.
struct LyricsRecord: Codable, Equatable, Sendable {
    var trackName: String?
    var artistName: String?
    var albumName: String?
    var duration: Double?
    var instrumental: Bool?
    var syncedLyrics: String?

    /// The best synced (or instrumental) record within `tolerance` seconds of the track:
    /// nearest length first, then a matching album, then the closest title. A record of
    /// the wrong length is a different edit or a live take, and its stamps would drift
    /// through the song. The title decides between versions of one length, such as an
    /// "English ver." and the original it was sung over.
    static func best(of records: [LyricsRecord], duration: Double, album: String,
                     title: String = "", tolerance: Double = 3) -> LyricsRecord? {
        let usable = records.filter { r in
            guard let d = r.duration else { return false }
            guard abs(d - duration) <= tolerance || duration <= 0 || r.lengthIsGuessed(within: duration)
            else { return false }
            guard isSameSong(r.trackName ?? "", title) else { return false }
            return r.instrumental == true || !(r.syncedLyrics ?? "").isEmpty
        }
        return usable.min { ranks($0, before: $1, duration: duration, album: album, title: title) }
    }

    /// Nearest length first, then a matching album, then the closest title.
    static func ranks(_ a: LyricsRecord, before b: LyricsRecord, duration: Double,
                      album: String, title: String) -> Bool {
        let da = abs((a.duration ?? 0) - duration), db = abs((b.duration ?? 0) - duration)
        if abs(da - db) > 0.5 { return da < db }
        let album = fold(album)
        let aa = fold(a.albumName ?? "") == album, ab = fold(b.albumName ?? "") == album
        if aa != ab { return aa }
        let ta = titleScore(a.trackName ?? "", title), tb = titleScore(b.trackName ?? "", title)
        if ta != tb { return ta > tb }
        // Synced words beat an instrumental flag when both claim the track.
        return !(a.syncedLyrics ?? "").isEmpty && (b.syncedLyrics ?? "").isEmpty
    }

    /// One answer from two sources, the first preferred: either's record wins, both
    /// misses are a miss, and a miss beside a failed question is still a failed
    /// question, so it is asked again rather than kept for three days. Each argument
    /// is `.some(nil)` for a definite miss and `nil` for a failed question.
    static func either(_ first: LyricsRecord??, _ second: LyricsRecord??) -> LyricsRecord?? {
        if case .some(.some) = first { return first }
        if case .some(.some) = second { return second }
        if case .some(.none) = first, case .some(.none) = second { return .some(nil) }
        return nil
    }

    /// Some uploaders give no real length, only their last stamp: Crush's "Seesaw (ft. IU)"
    /// says 171 s, exactly where its closing credit sits, and Spotify's recording runs
    /// 181 s. Such a length says nothing about the edit, so the record is used when its
    /// lines fit inside the track and it is at most `slack` seconds short. A record whose
    /// length runs on past its last line was timed to a different recording.
    func lengthIsGuessed(within track: Double, slack: Double = 15) -> Bool {
        guard let d = duration, d < track, track - d <= slack,
              let last = SyncedLyrics.lastStamp(syncedLyrics ?? "") else { return false }
        return d <= last + 1 && last <= track
    }

    /// Whether a record's title names the player's song: it holds every word of the
    /// plain title and adds none the player's whole title lacks, so "Too late" and
    /// "Hotel California (Live)" are the song and "Cecilia" or "Before It's Too Late" are
    /// not. A search answers with the artist's other songs, and length alone let Shye's
    /// "Cecilia" (238 s) stand in for her "Too Late" (240 s). An empty title asks nothing.
    static func isSameSong(_ record: String, _ title: String) -> Bool {
        let plain = words(searchTitle(title))
        guard !plain.isEmpty else { return true }
        let named = words(searchTitle(record))
        return plain.isSubset(of: named) && named.isSubset(of: words(title))
    }

    /// Words the record's title shares with the player's, less the words it adds: a
    /// remix credit counts against it.
    static func titleScore(_ record: String, _ title: String) -> Int {
        let r = words(record), t = words(title)
        return r.intersection(t).count - r.subtracting(t).count
    }

    private static func words(_ s: String) -> Set<String> {
        Set(fold(s).split { !$0.isLetter && !$0.isNumber }.map(String.init))
    }

    /// Players decorate titles that lyric sites do not: "Song - Remastered 2011",
    /// "Song (feat. X)", "Song [Live]", a member's name as in "Misty (MINA)". Used only
    /// for the fallback search, whose candidates `titleScore` then tells apart, so a
    /// version that keeps its decoration on the site still wins.
    static func searchTitle(_ title: String) -> String {
        var t = title
        for marker in [" - ", " (", " ["] {
            if let r = t.range(of: marker, options: .caseInsensitive), r.lowerBound > t.startIndex {
                t = String(t[..<r.lowerBound])
            }
        }
        return t.trimmingCharacters(in: .whitespaces)
    }

    /// Titles to ask the fallback search for, in order. It answers with at most 20 records,
    /// and a popular song's plain title fills them with studio takes, so a decorated
    /// version such as Eagles' "Hotel California - Live" (421 s) is found only by asking
    /// for it by its whole name.
    static func searchTitles(_ title: String) -> [String] {
        let full = title.trimmingCharacters(in: .whitespaces)
        let plain = searchTitle(title)
        return plain == full || plain.isEmpty ? [full] : [plain, full]
    }

    /// Whether LRCLIB really answered: a record or "not found". Anything else (a busy
    /// reply, an error page, no reply) says nothing about the song and is not kept.
    static func answered(status: Int?) -> Bool { status == 200 || status == 404 }

    /// LRCLIB's "try again in a moment": 429 with a Retry-After of a second, and a 503
    /// "ServerOverloaded" that clears on the next request.
    static func isBusy(status: Int) -> Bool { [429, 502, 503, 504].contains(status) }

    /// The first credited artist, for the fallback search.
    static func searchArtist(_ artist: String) -> String {
        var a = artist
        for marker in [", ", " & ", " feat. ", " ft. ", " x "] {
            if let r = a.range(of: marker, options: .caseInsensitive), r.lowerBound > a.startIndex {
                a = String(a[..<r.lowerBound])
            }
        }
        return a.trimmingCharacters(in: .whitespaces)
    }

    /// Case, width and curly-quote insensitive: "I’LL LIKE YOU" is "I'LL LIKE YOU".
    static func fold(_ s: String) -> String {
        s.replacingOccurrences(of: "\u{2019}", with: "'")
            .folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: nil)
            .trimmingCharacters(in: .whitespaces)
    }
}

/// NetEase Cloud Music's public web API, asked when LRCLIB has no synced record or
/// cannot answer (its API returned 502 for every request through 2026-10-31). Keyless
/// like LRCLIB, and its lengths are the recordings' own, in milliseconds.
enum NetEaseLyrics {
    struct Song: Equatable, Sendable {
        var id: Int
        var record: LyricsRecord
    }

    private struct Search: Decodable {
        struct Result: Decodable { var songs: [Item]? }
        struct Item: Decodable {
            struct Named: Decodable { var name: String? }
            var id: Int
            var name: String?
            var artists: [Named]?
            var album: Named?
            var duration: Double?
        }
        var code: Int?
        var result: Result?
    }

    private struct Lyric: Decodable {
        struct Text: Decodable { var lyric: String? }
        var code: Int?
        var lrc: Text?
        var nolyric: Bool?
        var pureMusic: Bool?
    }

    /// The search's songs, or nil when the reply is not a search answer.
    static func songs(fromSearch data: Data) -> [Song]? {
        guard let reply = try? JSONDecoder().decode(Search.self, from: data), reply.code == 200
        else { return nil }
        return (reply.result?.songs ?? []).map { item in
            Song(id: item.id, record: LyricsRecord(
                trackName: item.name,
                artistName: (item.artists ?? []).compactMap(\.name).joined(separator: ", "),
                albumName: item.album?.name,
                duration: item.duration.map { $0 / 1000 },
                instrumental: nil, syncedLyrics: nil))
        }
    }

    /// Songs worth asking for words, best first: the track's title, credited to its first
    /// artist and within `tolerance` seconds of its length. A search for a title by an
    /// artist also returns covers, remixes and live takes by others, and the artist's
    /// other songs.
    static func candidates(_ songs: [Song], artist: String, duration: Double, album: String,
                           title: String, tolerance: Double = 3) -> [Song] {
        let wanted = LyricsRecord.fold(LyricsRecord.searchArtist(artist))
        return songs.filter { song in
            guard let d = song.record.duration, abs(d - duration) <= tolerance || duration <= 0
            else { return false }
            let credited = (song.record.artistName ?? "").components(separatedBy: ", ")
                .map(LyricsRecord.fold)
            return !wanted.isEmpty && credited.contains(wanted)
                && LyricsRecord.isSameSong(song.record.trackName ?? "", title)
        }
        .sorted { LyricsRecord.ranks($0.record, before: $1.record, duration: duration,
                                     album: album, title: title) }
    }

    /// The song's words: its LRC when timed, `instrumental` when NetEase marks it pure
    /// music. Nil when the reply is not a lyric answer.
    static func lyric(from data: Data) -> (synced: String?, instrumental: Bool)? {
        guard let reply = try? JSONDecoder().decode(Lyric.self, from: data), reply.code == 200
        else { return nil }
        if reply.pureMusic == true || reply.nolyric == true { return (nil, true) }
        let lrc = reply.lrc?.lyric ?? ""
        return (SyncedLyrics(lrc: lrc) == nil ? nil : lrc, false)
    }
}
