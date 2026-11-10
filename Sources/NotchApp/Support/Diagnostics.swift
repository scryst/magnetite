import Foundation
import OSLog
import SystemConfiguration

/// "Copy Diagnostics" in the M menu: what a bug report needs, and nothing that
/// says who the user is, where they are or what they listen to.
///
/// The report holds the version, macOS, the Mac's model, the music source, the
/// problems the menu would show and the last `lineLimit` log entries of this
/// process. Every line is scrubbed of the home folder, the account and full name,
/// the computer's name, email addresses and the playing track's title and
/// artist. Times are UTC, so no time zone hints at a place.
enum Diagnostics {
    /// The app's own log: states and error texts only, marked public so the
    /// report can read them back. Never a track, an account or a token.
    static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "app.magnetite.Magnetite",
                            category: "app")

    static let lineLimit = 200

    struct Facts: Sendable {
        var version: String
        var macOS: String
        var model: String
        /// The M menu's Source choice and the player actually being read.
        var source: String
        var spotifyLibrary: String
        var problems: [String]
        var settings: [(String, Bool)]
    }

    static func report(_ facts: Facts, log lines: [String], redacting extra: [String] = [],
                       now: Date = Date()) -> String {
        var out = [
            "Magnetite \(facts.version)",
            "macOS \(facts.macOS), \(facts.model)",
            "Music source: \(facts.source)",
            "Spotify library: \(facts.spotifyLibrary)",
            "Problems: \(facts.problems.isEmpty ? "none" : facts.problems.joined(separator: "; "))",
            "Settings: " + facts.settings.map { "\($0.0) \($0.1 ? "on" : "off")" }.joined(separator: ", "),
            "Copied \(now.formatted(stamp))",
            "",
            "Last \(lines.count) log lines:",
        ]
        out += lines
        return scrub(out.joined(separator: "\n"), redacting: extra) + "\n"
    }

    /// What identifies this Mac or its owner, longest first so a full name goes
    /// before the parts of it.
    static func identifying(extra: [String]) -> [String] {
        let computer = SCDynamicStoreCopyComputerName(nil, nil) as String? ?? ""
        var words = [NSHomeDirectory(), NSUserName(), NSFullUserName(),
                     ProcessInfo.processInfo.hostName, computer]
        words += NSFullUserName().split(separator: " ").map(String.init)
        words += extra
        let kept = Set(words.map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count >= 3 })
        return kept.sorted { $0.count > $1.count }
    }

    static func scrub(_ text: String, redacting extra: [String] = []) -> String {
        var s = text
        let home = NSHomeDirectory()
        if home.count >= 3 { s = s.replacingOccurrences(of: home, with: "~") }
        for word in identifying(extra: extra) where word != home {
            s = s.replacingOccurrences(of: word, with: "<redacted>", options: [.caseInsensitive])
        }
        return s.replacingOccurrences(of: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#,
                                      with: "<email>", options: .regularExpression)
    }

    /// The newest `limit` entries this process has logged, its own and the system
    /// frameworks', oldest first.
    static func recentLog(limit: Int = lineLimit) -> [String] {
        do {
            let store = try OSLogStore(scope: .currentProcessIdentifier)
            var ring: [String] = []
            ring.reserveCapacity(limit)
            for case let entry as OSLogEntryLog in try store.getEntries() {
                let line = "\(entry.date.formatted(stamp)) \(name(entry.level)) "
                    + "\(entry.subsystem)[\(entry.category)] \(entry.composedMessage)"
                if ring.count == limit { ring.removeFirst() }
                ring.append(line)
            }
            return ring
        } catch {
            return ["(the log could not be read: \(error.localizedDescription))"]
        }
    }

    static func machineModel() -> String {
        var size = 0
        guard sysctlbyname("hw.model", nil, &size, nil, 0) == 0, size > 0 else { return "unknown Mac" }
        var bytes = [CChar](repeating: 0, count: size)
        guard sysctlbyname("hw.model", &bytes, &size, nil, 0) == 0 else { return "unknown Mac" }
        return String(cString: bytes)
    }

    private static func name(_ level: OSLogEntryLog.Level) -> String {
        switch level {
        case .debug: return "debug"
        case .info: return "info"
        case .notice: return "notice"
        case .error: return "error"
        case .fault: return "fault"
        default: return "log"
        }
    }

    /// UTC with milliseconds, e.g. 2026-11-10T02:15:31.123Z.
    private static let stamp = Date.ISO8601FormatStyle(includingFractionalSeconds: true)
}
