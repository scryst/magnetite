import Foundation
import CryptoKit

/// Synced lyrics from LRCLIB (lrclib.net): free, keyless and answering for Spotify and
/// Music alike by title, artist, album and length, so nobody signs in to anything.
/// Spotify's own lyrics endpoint is private.
///
/// Every answer is kept on disk under Application Support, so a song is asked about
/// once. A definite "none" is kept for a few days, since LRCLIB grows; a failed request
/// is not kept at all.
enum LyricsSource {

    enum Answer: Equatable, Sendable {
        case synced(SyncedLyrics)
        /// Instrumental, unsynced only, or unknown to LRCLIB: no stage either way.
        case none
    }

    private struct Entry: Codable {
        var synced: String?
        var at: Date
    }

    private static let base = URL(string: "https://lrclib.net/api/")!
    /// LRCLIB asks clients to name themselves.
    private static let agent: String = {
        let v = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        return "Magnetite \(v) (https://magnetite.app)"
    }()
    private static let missKeptFor: TimeInterval = 3 * 86_400

    static var folder: URL {
        URL.applicationSupportDirectory
            .appending(path: "Magnetite", directoryHint: .isDirectory)
            .appending(path: "Lyrics", directoryHint: .isDirectory)
    }

    /// Nil when the question could not be answered (offline, a timeout); the caller
    /// asks again on the next play of the track.
    static func lyrics(title: String, artist: String, album: String,
                       duration: Double) async -> Answer? {
        guard !title.isEmpty, !artist.isEmpty else { return Answer.none }
        let file = cacheFile(title: title, artist: artist, album: album, duration: duration)
        if let data = try? Data(contentsOf: file),
           let entry = try? JSONDecoder().decode(Entry.self, from: data),
           entry.synced != nil || Date().timeIntervalSince(entry.at) < missKeptFor {
            return answer(entry.synced)
        }
        guard let record = await fetch(title: title, artist: artist, album: album,
                                       duration: duration) else { return nil }
        let synced = record.flatMap { $0.instrumental == true ? nil : $0.syncedLyrics }
            .flatMap { $0.isEmpty ? nil : $0 }
        store(Entry(synced: synced, at: Date()), at: file)
        return answer(synced)
    }

    private static func answer(_ synced: String?) -> Answer {
        synced.flatMap(SyncedLyrics.init(lrc:)).map(Answer.synced) ?? Answer.none
    }

    /// `.some(nil)` is a definite miss; `nil` is a failed question.
    private static func fetch(title: String, artist: String, album: String,
                              duration: Double) async -> LyricsRecord?? {
        // The exact lookup first. It answers 404, or 503 when its upstream sources miss,
        // so any failure here falls through to the search, which is the definite answer.
        var items = [URLQueryItem(name: "track_name", value: title),
                     URLQueryItem(name: "artist_name", value: artist)]
        if !album.isEmpty { items.append(URLQueryItem(name: "album_name", value: album)) }
        if duration > 0 { items.append(URLQueryItem(name: "duration", value: String(Int(duration.rounded())))) }
        if let (data, status) = await get("get", items), status == 200,
           let record = try? JSONDecoder().decode(LyricsRecord.self, from: data),
           LyricsRecord.best(of: [record], duration: duration, album: album, title: title) != nil {
            return .some(record)
        }
        let search = [URLQueryItem(name: "track_name", value: LyricsRecord.searchTitle(title)),
                      URLQueryItem(name: "artist_name", value: LyricsRecord.searchArtist(artist))]
        guard let (data, status) = await get("search", search), status == 200,
              let records = try? JSONDecoder().decode([LyricsRecord].self, from: data)
        else { return nil }
        return .some(LyricsRecord.best(of: records, duration: duration, album: album, title: title))
    }

    private static func get(_ path: String, _ items: [URLQueryItem]) async -> (Data, Int)? {
        var components = URLComponents(url: base.appending(path: path), resolvingAgainstBaseURL: false)!
        components.queryItems = items
        guard let url = components.url else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 8)
        request.setValue(agent, forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse else { return nil }
        return (data, http.statusCode)
    }

    private static func cacheFile(title: String, artist: String, album: String,
                                  duration: Double) -> URL {
        // The leading tag changes whenever lookup improves, so misses cached by an
        // older build are asked again instead of waiting out their three days.
        let key = ["v2", title, artist, album, String(Int(duration.rounded()))]
            .map(LyricsRecord.fold).joined(separator: "\u{1}")
        let digest = SHA256.hash(data: Data(key.utf8)).prefix(16)
            .map { String(format: "%02x", $0) }.joined()
        return folder.appending(path: digest + ".json")
    }

    private static func store(_ entry: Entry, at file: URL) {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(entry) { try? data.write(to: file, options: .atomic) }
    }
}
