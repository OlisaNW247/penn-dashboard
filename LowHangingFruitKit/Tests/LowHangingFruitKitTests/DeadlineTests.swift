import Foundation
import Testing
@testable import LowHangingFruitUI

/// `Deadline.run` is what keeps a hung system call from stopping the reminder
/// re-plan (hardening plan C5 follow-up). Its reason for existing is the case a
/// task-group race cannot handle: an operation that never returns and does not
/// respond to cancellation.
@Suite("Deadline")
struct DeadlineTests {

    @Test("an operation that finishes in time gives its value")
    func finishesInTime() async {
        let value = await Deadline.run(after: 5) { 42 }
        #expect(value == 42)
    }

    @Test("an operation that never returns gives nil after the deadline, and the caller is not held by it")
    func neverReturns() async {
        let parked = Parked()
        let started = Date()
        let value: Int? = await Deadline.run(after: 0.05) {
            // Not cancellable: it is resumed by hand, as a hung callback would
            // never be.
            await parked.park()
            return 1
        }
        #expect(value == nil)
        #expect(Date().timeIntervalSince(started) < 2, "returned on the timer, not when the operation did")
        await parked.releaseAll()
    }

    @Test("a late result after the deadline is dropped and the caller is resumed exactly once")
    func lateResultIsDropped() async {
        let parked = Parked()
        let value: Int? = await Deadline.run(after: 0.05) {
            await parked.park()
            return 7
        }
        #expect(value == nil)
        await parked.releaseAll()          // the operation now finishes; nothing must resume twice
        try? await Task.sleep(for: .milliseconds(50))
    }

    /// Holds callers until released, with a continuation that ignores
    /// cancellation.
    @MainActor
    private final class Parked {
        private var waiting: [CheckedContinuation<Void, Never>] = []
        func park() async { await withCheckedContinuation { waiting.append($0) } }
        func releaseAll() {
            let all = waiting
            waiting = []
            for continuation in all { continuation.resume() }
        }
    }
}
