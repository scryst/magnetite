import Foundation

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
}
