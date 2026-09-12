import Dispatch
import Foundation
import Testing
@testable import LowHangingFruitKit

/// A stand-in for `NLEmbedding` with no state of its own, so it can conform
/// to `Sendable` outright (not `@unchecked`) rather than raising a strict-
/// concurrency capture warning the way returning a bare `NSObject` from a
/// `@Sendable` loader closure would.
private final class FakeEmbedding: Sendable {}

/// Thread-safe invocation counter, since `SentenceEmbeddingProvider`'s
/// `loader` runs on a detached background task and these tests need to
/// observe how many times it fired from the test's own thread.
private final class CallCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    var value: Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

/// Wraps a `DispatchSemaphore` so it can be captured in the `@Sendable`
/// loader closure regardless of whether a given toolchain's Dispatch overlay
/// has declared `DispatchSemaphore` itself `Sendable` — it's a well-known
/// thread-safe primitive either way, which is exactly what `@unchecked`
/// is for.
private final class SemaphoreBox: @unchecked Sendable {
    let semaphore = DispatchSemaphore(value: 0)
}

/// Polls `condition` until it's true or `timeout` elapses, for asserting on
/// a background task's eventual effect without a fixed, flake-prone sleep.
/// Every provider state transition here happens off a detached task the
/// test does not control the scheduling of, so "sleep a bit and hope" would
/// be exactly the kind of timing assumption this Kit's tests avoid elsewhere.
private func waitUntil(timeout: TimeInterval = 2, _ condition: @Sendable () -> Bool) async {
    let deadline = Date().addingTimeInterval(timeout)
    while !condition(), Date() < deadline {
        try? await Task.sleep(nanoseconds: 5_000_000)
    }
}

@Suite("SentenceEmbeddingProvider never blocks the caller to load")
struct SentenceEmbeddingProviderTests {
    @Test("first current() returns nil, moves to .loading, and the loader fires exactly once even under repeated calls")
    func loadsOnceUnderRepeatedCalls() async {
        let counter = CallCounter()
        let sentinel = FakeEmbedding()
        // Blocks on this until the test signals it, so every `current()`
        // call made before the signal is guaranteed to observe the loader
        // still in flight rather than racing its completion.
        let semaphoreBox = SemaphoreBox()
        let provider = SentenceEmbeddingProvider {
            counter.increment()
            semaphoreBox.semaphore.wait()
            return sentinel
        }

        for _ in 0..<10 {
            #expect(provider.current() == nil)
        }
        #expect(provider.state == .loading)

        semaphoreBox.semaphore.signal()
        await waitUntil { provider.state != .loading }

        #expect(provider.state == .ready)
        #expect(counter.value == 1)
    }

    @Test("once the loader returns an object, current() returns it and state is .ready")
    func becomesReady() async {
        let sentinel = FakeEmbedding()
        let provider = SentenceEmbeddingProvider { sentinel }

        #expect(provider.current() == nil)
        await waitUntil { provider.state == .ready }

        #expect(provider.state == .ready)
        #expect((provider.current() as? FakeEmbedding) === sentinel)
    }

    @Test("a loader returning nil makes state .unavailable, current() stays nil, and the loader never fires again")
    func unavailableIsTerminal() async {
        let counter = CallCounter()
        let provider = SentenceEmbeddingProvider {
            counter.increment()
            return nil
        }

        #expect(provider.current() == nil)
        await waitUntil { provider.state == .unavailable }

        #expect(provider.state == .unavailable)
        for _ in 0..<5 {
            #expect(provider.current() == nil)
        }
        #expect(counter.value == 1)
    }

    @Test("warmUp() starts the load from .cold and is a no-op once ready")
    func warmUpIsIdempotent() async {
        let counter = CallCounter()
        let sentinel = FakeEmbedding()
        let provider = SentenceEmbeddingProvider {
            counter.increment()
            return sentinel
        }

        provider.warmUp()
        #expect(provider.state == .loading)
        await waitUntil { provider.state == .ready }
        #expect(counter.value == 1)

        // Already `.ready` — a second call must not restart the load.
        provider.warmUp()
        #expect(provider.state == .ready)
        #expect(counter.value == 1)
    }

    @Test("current() never blocks, even when the loader takes seconds")
    func neverBlocks() {
        let provider = SentenceEmbeddingProvider {
            Thread.sleep(forTimeInterval: 2)
            return FakeEmbedding()
        }

        let start = Date()
        let result = provider.current()
        let elapsed = Date().timeIntervalSince(start)

        #expect(result == nil)
        #expect(elapsed < 0.1)
    }
}
