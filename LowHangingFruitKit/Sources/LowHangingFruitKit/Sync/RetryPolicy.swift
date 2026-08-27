import Foundation

/// Exponential backoff for transient sync failures.
///
/// `.none` preserves single-attempt behavior (manual sync: the user is watching
/// a spinner and can tap again). `.background` is tuned for the silent
/// auto-refresh loop: a few quick attempts whose total added delay stays far
/// below the 5-minute refresh cadence, so retries can never pile up.
public struct RetryPolicy: Sendable, Equatable {
    /// Total attempts, including the first one. 1 means "never retry".
    public var maxAttempts: Int
    /// Delay before the first retry, in seconds.
    public var baseDelay: TimeInterval
    /// Each subsequent retry waits this factor longer than the previous one.
    public var multiplier: Double
    /// Ceiling on any single delay, in seconds.
    public var maxDelay: TimeInterval

    public init(
        maxAttempts: Int,
        baseDelay: TimeInterval,
        multiplier: Double = 2,
        maxDelay: TimeInterval = 30
    ) {
        self.maxAttempts = max(1, maxAttempts)
        self.baseDelay = max(0, baseDelay)
        self.multiplier = max(1, multiplier)
        self.maxDelay = max(0, maxDelay)
    }

    /// Single attempt, no retries.
    public static let none = RetryPolicy(maxAttempts: 1, baseDelay: 0)

    /// Background auto-sync: 3 attempts with 2s → 4s backoff (≤6s added total).
    public static let background = RetryPolicy(maxAttempts: 3, baseDelay: 2)

    /// Delay before the given retry (1 = the first retry, after the first failure).
    public func delay(beforeRetry retry: Int) -> TimeInterval {
        guard retry >= 1 else { return 0 }
        return min(baseDelay * pow(multiplier, Double(retry - 1)), maxDelay)
    }

    /// Runs `operation`, retrying failures that `isRetryable` accepts until an
    /// attempt succeeds or `maxAttempts` is exhausted; the last error is
    /// rethrown. `sleep` is injectable so tests don't wait out real backoff.
    public func run<T: Sendable>(
        isRetryable: @escaping @Sendable (any Error) -> Bool,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = { seconds in
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        },
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        var attempt = 1
        while true {
            do {
                return try await operation()
            } catch {
                guard attempt < maxAttempts, !Task.isCancelled, isRetryable(error) else {
                    throw error
                }
                try await sleep(delay(beforeRetry: attempt))
                attempt += 1
            }
        }
    }
}
