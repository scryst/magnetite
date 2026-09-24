import Foundation

/// A cancellable, generation-guarded delayed transition.
///
/// This is the single most load-bearing pattern in the app. Without it,
/// overlapping events — a volume key repeating while a track changes while a
/// device connects — leave the notch flickering or stuck in a half-state.
///
/// Every scheduled body carries the generation it was created with. Rescheduling
/// bumps the counter, so a body that wakes up superseded returns without touching
/// any state rather than clobbering whatever replaced it.
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

    /// Run `body` immediately, claiming the generation so any pending schedule is
    /// invalidated. Use when an event should win outright.
    func now(_ body: @escaping @MainActor () -> Void) {
        cancel()
        body()
    }

}
