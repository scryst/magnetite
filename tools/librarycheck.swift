import Foundation

/// Exercises real MediaManager reconciliation and MediaBridge snapshot types.
/// Only the Spotify account/library boundary and settings are test doubles.
@main @MainActor enum LibraryCheck {
    static var failures = 0
    static func snapshot(_ source: MusicSource, id: String = "fixture-a", liked: Bool? = nil) -> TrackSnapshot {
        var s = TrackSnapshot(source: source)
        s.title = "Fixture"; s.artist = "Synthetic"; s.album = "Fixture"
        s.duration = 120; s.position = 20; s.isPlaying = true
        s.identity = id; s.liked = liked
        return s
    }
    static func expect(_ ok: Bool, _ name: String) {
        print("\(ok ? "PASS" : "FAIL") \(name)")
        if !ok { failures += 1 }
    }
    static func ready() async -> MediaManager {
        let m = MediaManager(bridge: MediaBridge(inert: true), observePlayers: false)
        m.spotify.isConnected = true
        m.apply(snapshot(.spotify))
        await waitForRequest(m, 0)
        return m
    }
    static func waitForRequest(_ m: MediaManager, _ index: Int) async {
        let deadline = ContinuousClock.now + .seconds(2)
        while m.spotify.pending.count <= index, ContinuousClock.now < deadline {
            await Task.yield()
        }
        precondition(m.spotify.pending.count > index, "fixture library request not admitted")
    }
    static func answer(_ m: MediaManager, _ index: Int, saved: Bool?, task: Task<Void, Never>) async {
        await waitForRequest(m, index)
        m.spotify.resolve(index, saved: saved)
        await task.value // Includes the real caller's guard and its accepted or rejected write.
    }
    static func main() async {
        let inert = MediaBridge(inert: true)
        for source in MusicSource.allCases {
            let read = await inert.read(for: source)
            if case .unreadable = read { expect(true, "inert \(source) read answers nothing") }
            else { expect(false, "inert \(source) read answers nothing") }
        }
        if case .noCover = await inert.musicArtwork() { expect(true, "inert artwork answers nothing") }
        else { expect(false, "inert artwork answers nothing") }
        let stubbed = MediaBridge(inert: true, stubbedRead: { _ in .idle })
        if case .idle = await stubbed.read(for: .spotify) { expect(true, "explicit stubbed read retains precedence") }
        else { expect(false, "explicit stubbed read retains precedence") }

        let current = await ready()
        await answer(current, 0, saved: true, task: current.libraryTask!)
        expect(current.liked == true, "current Spotify read updates its heart")

        let switched = await ready()
        let switchedTask = switched.libraryTask!
        switched.apply(snapshot(.music, id: "fixture-music", liked: false))
        await answer(switched, 0, saved: true, task: switchedTask)
        expect(switched.source == .music && switched.liked == false,
               "late Spotify read cannot replace Music heart")

        let blank = await ready()
        let blankTask = blank.libraryTask!
        blank.apply(nil)
        await answer(blank, 0, saved: true, task: blankTask)
        expect(!blank.hasTrack && blank.liked == nil,
               "late Spotify read cannot resurrect heart after blank")

        let newer = await ready()
        let olderTask = newer.libraryTask!
        newer.apply(snapshot(.spotify, id: "fixture-b"))
        let newerTask = newer.libraryTask!
        await answer(newer, 0, saved: true, task: olderTask)
        expect(newer.liked == nil, "older Spotify track answer remains rejected")
        await answer(newer, 1, saved: false, task: newerTask)
        expect(newer.liked == false, "newer Spotify track answer remains accepted")

        let disconnected = await ready()
        let disconnectedTask = disconnected.libraryTask!
        disconnected.spotify.isConnected = false
        disconnected.apply(snapshot(.spotify, id: "fixture-disconnected"))
        await answer(disconnected, 0, saved: true, task: disconnectedTask)
        expect(disconnected.liked == nil && disconnected.spotify.pending.count == 1,
               "changed Spotify identity rejects late answer without a newer query")

        let sameKey = await ready()
        let sameKeyTask = sameKey.libraryTask!
        sameKey.apply(snapshot(.music, liked: false))
        await answer(sameKey, 0, saved: true, task: sameKeyTask)
        expect(sameKey.source == .music && sameKey.liked == false,
               "equal fallback identities still belong to different players")

        let recovered = await ready()
        let beforeBlankTask = recovered.libraryTask!
        recovered.apply(nil)
        recovered.apply(snapshot(.spotify))
        let recoveredTask = recovered.libraryTask!
        await answer(recovered, 0, saved: true, task: beforeBlankTask)
        expect(recovered.liked == nil, "pre-blank answer cannot own recovered same track")
        await answer(recovered, 1, saved: false, task: recoveredTask)
        expect(recovered.liked == false, "recovered same-track fresh answer is accepted")

        print("librarycheck: 13 cases, \(failures) failures")
        exit(failures == 0 ? 0 : 1)
    }
}
