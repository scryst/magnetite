import Foundation

/// A cancellable, generation-guarded delayed transition.
///
/// Overlapping events (a repeating volume key, a track change, a device connecting)
/// must not leave the notch in a half-state. Each scheduled body captures the
/// generation it was created under; rescheduling bumps the counter, so a body that
/// wakes up superseded returns without touching state.
@MainActor
final class Transition {
    private var generation: UInt64 = 0
    private var task: Task<Void, Never>?

    /// Cancel anything pending without scheduling a replacement.
    func cancel() {
        generation &+= 1
        task?.cancel()
        task = nil
    }

    /// Run `body` after `delay`, unless superseded first.
    func schedule(after delay: Duration, _ body: @escaping @MainActor () -> Void) {
        generation &+= 1
        let mine = generation
        task?.cancel()
        task = Task { @MainActor in
            try? await Task.sleep(for: delay)
            guard !Task.isCancelled, mine == self.generation else { return }
            body()
        }
    }

    /// Run `body` immediately and invalidate anything pending, so this event wins.
    func now(_ body: @escaping @MainActor () -> Void) {
        cancel()
        body()
    }

}
