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
            while rest.first == "[", let close = rest.firstIndex(of: "]") {
                let tag = rest[rest.index(after: rest.startIndex)..<close]
                rest = rest[rest.index(after: close)...]
                if let t = Self.stamp(tag) {
                    times.append(t)
                } else if tag.lowercased().hasPrefix("offset:"),
                          let ms = Double(tag.dropFirst(7).trimmingCharacters(in: .whitespaces)) {
                    // A positive offset makes lyrics appear sooner.
                    offset = ms / 1000
                }
            }
            let text = rest.trimmingCharacters(in: .whitespaces)
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
            guard let d = r.duration, abs(d - duration) <= tolerance || duration <= 0 else { return false }
            return r.instrumental == true || !(r.syncedLyrics ?? "").isEmpty
        }
        let album = Self.fold(album)
        return usable.min { a, b in
            let da = abs((a.duration ?? 0) - duration), db = abs((b.duration ?? 0) - duration)
            if abs(da - db) > 0.5 { return da < db }
            let aa = Self.fold(a.albumName ?? "") == album, ab = Self.fold(b.albumName ?? "") == album
            if aa != ab { return aa }
            let ta = titleScore(a.trackName ?? "", title), tb = titleScore(b.trackName ?? "", title)
            if ta != tb { return ta > tb }
            // Synced words beat an instrumental flag when both claim the track.
            return !(a.syncedLyrics ?? "").isEmpty && (b.syncedLyrics ?? "").isEmpty
        }
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
    /// "Song (feat. X)", "Song [Live]". Used only for the fallback search.
    static func searchTitle(_ title: String) -> String {
        var t = title
        for marker in [" - ", " (feat", " (with ", " [", " (Remaster", " (Live"] {
            if let r = t.range(of: marker, options: .caseInsensitive), r.lowerBound > t.startIndex {
                t = String(t[..<r.lowerBound])
            }
        }
        return t.trimmingCharacters(in: .whitespaces)
    }

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
