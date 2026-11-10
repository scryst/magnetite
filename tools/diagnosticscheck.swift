import Foundation
import SystemConfiguration

/// Headless checks for "Copy Diagnostics": the report says what a bug report
/// needs and nothing that identifies the user, and the log reader returns this
/// process's newest entries.
@main
enum DiagnosticsCheck {
    static func main() async {
        theScrubberRemovesEveryIdentifier()
        theReportCarriesTheFacts()
        theReportIsScrubbedWhole()
        timesCarryNoTimeZone()
        await theReaderFindsItsOwnLog()
        await theReaderKeepsOnlyTheNewest()
        print("diagnosticscheck: all checks passed")
    }

    static func expect(_ ok: Bool, _ what: String) {
        if !ok {
            FileHandle.standardError.write(Data("diagnosticscheck: FAILED \(what)\n".utf8))
            exit(1)
        }
    }

    static var identifiers: [String] {
        let computer = SCDynamicStoreCopyComputerName(nil, nil) as String? ?? ""
        return [NSUserName(), NSFullUserName(), ProcessInfo.processInfo.hostName, computer]
            .filter { $0.count >= 3 }
    }

    static func theScrubberRemovesEveryIdentifier() {
        let raw = """
        opened \(NSHomeDirectory())/Library/Application Support/Magnetite/Lyrics/x.json
        user \(NSUserName()) on \(ProcessInfo.processInfo.hostName)
        owner \(NSFullUserName().uppercased()) mail someone.else@example.co.uk
        computer \(SCDynamicStoreCopyComputerName(nil, nil) as String? ?? "")
        now playing Art Deco by Lana Del Rey
        """
        let s = Diagnostics.scrub(raw, redacting: ["Art Deco", "Lana Del Rey"])
        expect(!s.contains(NSHomeDirectory()), "the home folder is replaced")
        expect(s.contains("~/Library/Application Support/Magnetite"), "a path keeps its shape under ~")
        for word in identifiers {
            expect(!s.localizedCaseInsensitiveContains(word), "\"\(word)\" is redacted, in any case")
        }
        expect(!s.contains("example.co.uk") && s.contains("<email>"), "an email address is redacted")
        expect(!s.contains("Art Deco") && !s.contains("Lana Del Rey"), "the song is redacted")
    }

    static let facts = Diagnostics.Facts(
        version: "0.1.18 (build 23)", macOS: "Version 26.2 (Build 25C56)", model: "Mac16,1",
        source: "Automatic, reading Spotify", spotifyLibrary: "not set up", problems: [],
        settings: [("Lyrics in Player", true), ("Volume Indicator", false)])

    static func theReportCarriesTheFacts() {
        let r = Diagnostics.report(facts, log: ["line one", "line two"])
        for want in ["Magnetite 0.1.18 (build 23)", "macOS Version 26.2 (Build 25C56), Mac16,1",
                     "Music source: Automatic, reading Spotify", "Spotify library: not set up",
                     "Problems: none", "Settings: Lyrics in Player on, Volume Indicator off",
                     "Last 2 log lines:\nline one\nline two"] {
            expect(r.contains(want), "the report says \"\(want)\"")
        }
        var stuck = facts
        stuck.problems = ["Spotify isn't answering"]
        expect(Diagnostics.report(stuck, log: []).contains("Problems: Spotify isn't answering"),
               "a problem the menu shows is in the report")
    }

    static func theReportIsScrubbedWhole() {
        var mine = facts
        mine.source = "Spotify on \(ProcessInfo.processInfo.hostName)"
        let r = Diagnostics.report(mine, log: ["read \(NSHomeDirectory())/Music by \(NSUserName())"],
                                   redacting: ["Hush"])
        expect(!r.contains(NSHomeDirectory()), "no home folder in the report")
        for word in identifiers {
            expect(!r.localizedCaseInsensitiveContains(word), "no \"\(word)\" in the report")
        }
    }

    static func timesCarryNoTimeZone() {
        let r = Diagnostics.report(facts, log: [], now: Date(timeIntervalSince1970: 0))
        expect(r.contains("Copied 1970-01-01T00:00:00.000Z"), "the copy time is UTC")
    }

    /// The store is written asynchronously, so a fresh entry may take a moment.
    static func lines(containing marker: String, limit: Int = Diagnostics.lineLimit) async -> [String] {
        for _ in 0..<40 {
            let got = Diagnostics.recentLog(limit: limit)
            if got.contains(where: { $0.contains(marker) }) { return got }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return Diagnostics.recentLog(limit: limit)
    }

    static func theReaderFindsItsOwnLog() async {
        let marker = "diagnosticscheck-\(UUID().uuidString)"
        Diagnostics.log.error("\(marker, privacy: .public)")
        let got = await lines(containing: marker)
        expect(got.contains { $0.contains(marker) && $0.contains(" error ") && $0.hasSuffix(marker) },
               "the reader returns this process's own entry with its level (got \(got.suffix(3)))")
        expect(got.allSatisfy { $0.first?.isNumber == true || $0.hasPrefix("(") }, "every line starts with its time")
    }

    static func theReaderKeepsOnlyTheNewest() async {
        let run = UUID().uuidString.prefix(8)
        for i in 0..<250 { Diagnostics.log.notice("burst \(run, privacy: .public) \(i, privacy: .public)") }
        let got = await lines(containing: "burst \(run) 249", limit: 200)
        expect(got.count == 200, "the reader stops at its limit (\(got.count))")
        // Opening the store logs its own XPC connection after the burst, so the
        // newest of ours is the last of ours, not necessarily the last line.
        let ours = got.filter { $0.contains("burst \(run) ") }
        expect(ours.last?.hasSuffix("burst \(run) 249") == true, "the newest entry comes last (\(got.suffix(2)))")
        expect(!got.contains { $0.hasSuffix("burst \(run) 0") }, "the oldest entries are dropped")
    }
}
