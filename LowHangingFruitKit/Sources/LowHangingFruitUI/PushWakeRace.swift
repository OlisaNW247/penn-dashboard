import Foundation
import os

/// The shape of a silent-push wake's budget: do the work, but answer iOS
/// within `timeout` whatever the work is doing, and answer exactly once.
///
/// iOS gives a `didReceiveRemoteNotification` handler about 30 seconds and
/// then suspends the process; the completion handler must be called once, on
/// the main thread (CLAUDE.md → Traps, the notification-tap crash: UIKit
/// asserts the main thread when the completion is called from the cooperative
/// pool). So both finishers here are `@MainActor` tasks, and a lock-guarded
/// flag lets whichever arrives first win. On the timeout the work is
/// cancelled and the answer is "no new data": the alarm was armed days ago
/// and a missed read costs nothing but the read.
///
/// Platform-neutral on purpose, so the once-only rule is run by a test on the
/// Mac (`BackgroundRefresh.swift` is iOS-only and compiles only in
/// `xcodebuild`).
@MainActor
enum PushWakeRace {
    nonisolated static let defaultTimeout: TimeInterval = 25

    private final class TaskBox: @unchecked Sendable {
        var task: Task<Void, Never>?
    }

    /// `work` answers whether it changed anything; `completion` receives that
    /// answer, or `false` on timeout, exactly once.
    static func run(
        timeout: TimeInterval = defaultTimeout,
        work: @escaping @MainActor () async -> Bool,
        completion: @escaping @MainActor (Bool) -> Void
    ) {
        let answered = OSAllocatedUnfairLock(initialState: false)
        let box = TaskBox()

        @MainActor func finish(_ newData: Bool) {
            let first = answered.withLock { done -> Bool in
                if done { return false }
                done = true
                return true
            }
            if first { completion(newData) }
        }

        box.task = Task { @MainActor in
            let result = await work()
            finish(result)
        }
        Task { @MainActor in
            let nanoseconds = UInt64(max(0, timeout) * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            box.task?.cancel()
            finish(false)
        }
    }
}
