import Foundation

// Linked only into librarycheck, so no settings migration, token restoration,
// provider request or library write can run while delayed answers are tested.
@MainActor final class Settings {
    static let shared = Settings()
    var musicApp = "auto"
}

@MainActor final class SpotifyWeb {
    var isConnected = false
    let canControlPlayback = false
    var onConnect: (() -> Void)?
    struct Playback {
        var shuffling = false
        var repeating = false
        var canShuffle = false
        var canRepeat = false
    }
    var pending: [CheckedContinuation<Bool?, Never>] = []
    func isSaved(trackID: String) async -> Bool? {
        await withCheckedContinuation { pending.append($0) }
    }
    func resolve(_ index: Int, saved: Bool?) { pending[index].resume(returning: saved) }
    func refreshAccountIfUnknown() async {}
    func setSaved(_ saved: Bool, trackID: String) async -> Bool { false }
    func playbackModes() async -> Playback? { nil }
    func setMode(shuffling: Bool?, repeating: Bool?) async -> Bool { false }
    static func modes(from fresh: Playback?, keeping previous: Playback?) -> Playback? { fresh ?? previous }
}
