import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

@Suite("Completion gestures")
struct CompletionSwipeTests {
    @Test("Left drags and deliberate left flicks undo")
    func leftSwipe() {
        #expect(CompletionSwipe.accepts(horizontal: -68, vertical: 3, predicted: -68, undo: true))
        #expect(CompletionSwipe.accepts(horizontal: -42, vertical: 4, predicted: -100, undo: true))
    }

    @Test("Scrolling, short nudges and the opposite direction never undo")
    func rejectAccidents() {
        #expect(!CompletionSwipe.accepts(horizontal: -80, vertical: 100, predicted: -150, undo: true))
        #expect(!CompletionSwipe.accepts(horizontal: -41, vertical: 0, predicted: -200, undo: true))
        #expect(!CompletionSwipe.accepts(horizontal: -60, vertical: 0, predicted: -70, undo: true))
        #expect(!CompletionSwipe.accepts(horizontal: 100, vertical: 0, predicted: 200, undo: true))
    }

    @Test("The practice card teaches right-to-complete and left-to-undo")
    func practiceDirections() {
        #expect(CompletionSwipe.accepts(horizontal: 70, vertical: 5, predicted: 80, undo: false))
        #expect(!CompletionSwipe.accepts(horizontal: -70, vertical: 5, predicted: -80, undo: false))
        #expect(!CompletionSwipe.accepts(horizontal: 70, vertical: 90, predicted: 180, undo: false))
    }

    @MainActor
    @Test("Undo persists after reloading the ledger, including a completion saved before animation")
    func undoPersists() throws {
        let store = try AssignmentStore(inMemory: true)
        let assignment = Assignment(source: .canvas, sourceID: "completion-guide-test", kind: .assignment,
                                    course: "GUIDE TEST", title: "Practice", dueAt: nil, url: nil)
        let state = AppState(assignmentStore: store)
        state.commitCompletion(assignment)
        #expect(AppState(assignmentStore: store).isCompleted(assignment))
        state.markActive(assignment)
        #expect(!state.isCompleted(assignment))
        #expect(!AppState(assignmentStore: store).isCompleted(assignment))
    }
}
