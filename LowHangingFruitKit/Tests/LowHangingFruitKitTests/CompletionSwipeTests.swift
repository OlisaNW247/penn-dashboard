import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

@Suite("Completion gestures")
struct CompletionSwipeTests {
    @Test("A drag that starts more vertical than sideways belongs to the scroll")
    func verticalStartIsScroll() {
        #expect(CompletionSwipe.axis(width: 4, height: 18) == .vertical)
        #expect(CompletionSwipe.axis(width: -12, height: -19) == .vertical)
        // A tie is a scroll: a lost scroll is the bug, a lost swipe is a retry.
        #expect(CompletionSwipe.axis(width: 18, height: 18) == .vertical)
        #expect(CompletionSwipe.axis(width: 0, height: 0) == .vertical)
    }

    @Test("A drag that starts clearly sideways is a swipe, either way")
    func horizontalStartIsSwipe() {
        #expect(CompletionSwipe.axis(width: 19, height: 4) == .horizontal)
        #expect(CompletionSwipe.axis(width: -19, height: 6) == .horizontal)
    }

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

    @Test("Either direction completes an active card; vertical never does; undo stays left-only")
    func eitherDirectionCompletes() {
        #expect(CompletionSwipe.acceptsCompletion(horizontal: -70, vertical: 0, predicted: -70))
        #expect(CompletionSwipe.acceptsCompletion(horizontal: 70, vertical: 0, predicted: 70))
        #expect(CompletionSwipe.acceptsCompletion(horizontal: -45, vertical: 0, predicted: -90))
        #expect(!CompletionSwipe.acceptsCompletion(horizontal: -45, vertical: 0, predicted: -20))
        #expect(!CompletionSwipe.acceptsCompletion(horizontal: 0, vertical: 120, predicted: 0))
        #expect(!CompletionSwipe.acceptsCompletion(horizontal: -70, vertical: 90, predicted: -70))
        #expect(!CompletionSwipe.accepts(horizontal: 70, vertical: 0, predicted: 90, undo: true))
    }

    @Test("The active card uses the either-direction rule; prev keeps left-only undo")
    func sourceUsage() throws {
        let ui = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/LowHangingFruitUI")
        let card = try String(contentsOf: ui.appendingPathComponent("AssignmentCardView.swift"), encoding: .utf8)
        let done = try String(contentsOf: ui.appendingPathComponent("DoneView.swift"), encoding: .utf8)
        #expect(card.contains("acceptsCompletion"))
        #expect(done.contains("CompletionSwipe.accepts("))
        #expect(done.contains("undo: true"))
    }
}
