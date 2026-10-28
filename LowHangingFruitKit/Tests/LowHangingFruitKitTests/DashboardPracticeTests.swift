import Testing
@testable import LowHangingFruitUI

@Suite("Dashboard practice")
struct DashboardPracticeTests {
    @Test("Complete moves to prev, undo returns to todo, and sync gates exit")
    func practiceFlow() {
        var practice = DashboardPracticeProgress()
        #expect(practice.step == .todo)
        #expect(!practice.canContinue(syncReady: true))
        practice.complete()
        #expect(practice.step == .previous)
        #expect(!practice.canContinue(syncReady: true))
        practice.undo()
        #expect(practice.step == .finished)
        #expect(!practice.canContinue(syncReady: false))
        #expect(practice.canContinue(syncReady: true))
    }

    @Test("Out-of-order and repeated gesture callbacks cannot skip or replay a step")
    func repeatedGestures() {
        var practice = DashboardPracticeProgress()
        practice.undo()
        #expect(practice.step == .todo)
        practice.complete()
        practice.complete()
        #expect(practice.step == .previous)
        practice.undo()
        practice.complete()
        practice.undo()
        #expect(practice.step == .finished)
        #expect(DashboardPracticeProgress().step == .todo)
    }
}
