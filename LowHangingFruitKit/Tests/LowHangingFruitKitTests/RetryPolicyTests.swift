import Foundation
import Testing
@testable import LowHangingFruitKit

@Suite("Sync retry policy")
struct RetryPolicyTests {
    /// Records attempts and requested sleep delays without real waiting.
    private actor Recorder {
        var attempts = 0
        var sleeps: [TimeInterval] = []

        func nextAttempt() -> Int {
            attempts += 1
            return attempts
        }

        func recordSleep(_ delay: TimeInterval) {
            sleeps.append(delay)
        }
    }

    private struct TestError: Error {}

    @Test("backoff doubles per retry and caps at maxDelay")
    func delays() {
        let policy = RetryPolicy(maxAttempts: 5, baseDelay: 2, multiplier: 2, maxDelay: 6)
        #expect(policy.delay(beforeRetry: 1) == 2)
        #expect(policy.delay(beforeRetry: 2) == 4)
        #expect(policy.delay(beforeRetry: 3) == 6)
        #expect(policy.delay(beforeRetry: 4) == 6)
    }

    @Test("retries transient failures until an attempt succeeds")
    func retriesUntilSuccess() async throws {
        let recorder = Recorder()
        let result = try await RetryPolicy(maxAttempts: 3, baseDelay: 2).run(
            isRetryable: { _ in true },
            sleep: { await recorder.recordSleep($0) }
        ) { () async throws -> String in
            if await recorder.nextAttempt() < 3 { throw TestError() }
            return "ok"
        }
        #expect(result == "ok")
        #expect(await recorder.attempts == 3)
        #expect(await recorder.sleeps == [2, 4])
    }

    @Test("rethrows once attempts are exhausted")
    func exhaustsAttempts() async {
        let recorder = Recorder()
        await #expect(throws: TestError.self) {
            try await RetryPolicy(maxAttempts: 3, baseDelay: 1).run(
                isRetryable: { _ in true },
                sleep: { await recorder.recordSleep($0) }
            ) { () async throws -> Void in
                _ = await recorder.nextAttempt()
                throw TestError()
            }
        }
        #expect(await recorder.attempts == 3)
        #expect(await recorder.sleeps == [1, 2])
    }

    @Test("non-retryable errors surface immediately")
    func nonRetryableFailsFast() async {
        let recorder = Recorder()
        await #expect(throws: TestError.self) {
            try await RetryPolicy.background.run(
                isRetryable: { _ in false },
                sleep: { await recorder.recordSleep($0) }
            ) { () async throws -> Void in
                _ = await recorder.nextAttempt()
                throw TestError()
            }
        }
        #expect(await recorder.attempts == 1)
        #expect(await recorder.sleeps.isEmpty)
    }

    @Test(".none never retries, even for retryable errors")
    func nonePolicyIsSingleAttempt() async {
        let recorder = Recorder()
        await #expect(throws: TestError.self) {
            try await RetryPolicy.none.run(
                isRetryable: { _ in true },
                sleep: { await recorder.recordSleep($0) }
            ) { () async throws -> Void in
                _ = await recorder.nextAttempt()
                throw TestError()
            }
        }
        #expect(await recorder.attempts == 1)
        #expect(await recorder.sleeps.isEmpty)
    }

    @Test("Canvas transience: 5xx/429 and network drops retry, 4xx and auth don't")
    func canvasTransience() {
        #expect(CanvasICSClient.isTransient(CanvasICSClient.Error.http(status: 500)))
        #expect(CanvasICSClient.isTransient(CanvasICSClient.Error.http(status: 503)))
        #expect(CanvasICSClient.isTransient(CanvasICSClient.Error.http(status: 429)))
        #expect(!CanvasICSClient.isTransient(CanvasICSClient.Error.http(status: 401)))
        #expect(!CanvasICSClient.isTransient(CanvasICSClient.Error.http(status: 404)))
        #expect(!CanvasICSClient.isTransient(CanvasICSClient.Error.notHTTP))

        #expect(CanvasICSClient.isTransient(URLError(.timedOut)))
        #expect(CanvasICSClient.isTransient(URLError(.networkConnectionLost)))
        #expect(CanvasICSClient.isTransient(URLError(.notConnectedToInternet)))
        #expect(!CanvasICSClient.isTransient(URLError(.badURL)))
        #expect(!CanvasICSClient.isTransient(TestError()))
    }
}
