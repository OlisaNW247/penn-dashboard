import Foundation
import os

/// Waits for an async operation, but only so long.
///
/// **Why a continuation and not a task group.** The usual race is a task group
/// with the operation in one child and a sleep in the other, taking whichever
/// finishes first. That does not work for an operation that never finishes:
/// `withThrowingTaskGroup` does not return until every child has, cancelled or
/// not, and a child suspended in a system call that never calls back (a
/// notification-center read that hangs) does not respond to cancellation. The
/// group would wait out the very hang the deadline is there to survive. Here the
/// caller is resumed by whichever of the operation and the timer gets there
/// first, exactly once, and the loser is left to finish or not on its own: a
/// hung operation costs one parked task, never the caller.
enum Deadline {

    /// The operation's result, or nil if it had not finished after `seconds`.
    ///
    /// The operation runs on the main actor, which is where the callers' state
    /// lives (`PendingNotificationSink` is a main-actor protocol); the timer
    /// does not, so it fires even if the operation is what is stuck.
    static func run<T: Sendable>(
        after seconds: TimeInterval,
        _ operation: @escaping @MainActor @Sendable () async -> T
    ) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            @Sendable func resumeOnce(_ value: T?) {
                let first = resumed.withLock { done -> Bool in
                    if done { return false }
                    done = true
                    return true
                }
                if first { continuation.resume(returning: value) }
            }
            let timer = Task {
                try? await Task.sleep(for: .seconds(seconds))
                resumeOnce(nil)
            }
            Task {
                resumeOnce(await operation())
                // The operation won (or lost and finished late): no reason to
                // leave the timer sleeping. Cancelling makes its sleep return
                // early, and its `resumeOnce(nil)` is then a no-op.
                timer.cancel()
            }
        }
    }
}
