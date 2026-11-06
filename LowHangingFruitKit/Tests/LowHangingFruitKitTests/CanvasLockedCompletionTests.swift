import Testing
import Foundation
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// prev must not offer a swipe-back on work Canvas alone keeps completed
/// (test report 2026-11-06, finding 6). Seeds go through an in-memory ledger
/// and `forceFixtureDataForTesting`, never `UserDefaults.lhf`.
@MainActor
@Suite("Canvas-locked completion")
struct CanvasLockedCompletionTests {

    private func assignment(_ id: String, submitted: Bool = false, canvasID: String? = nil) -> Assignment {
        let tail = canvasID.map { "/assignments/\($0)" } ?? ""
        return Assignment(source: .canvas, sourceID: id, kind: .assignment,
                          course: "LOCK 100", title: "Item \(id)",
                          dueAt: Date().addingTimeInterval(2 * 86_400),
                          url: URL(string: "https://canvas.upenn.edu/courses/1\(tail)"),
                          submitted: submitted)
    }

    private func state(submitted ids: Set<String> = [], items: [Assignment]) throws -> (AppState, AssignmentStore) {
        let store = try AssignmentStore(inMemory: true)
        _ = store.reconcile(items, source: .canvas)
        if !ids.isEmpty {
            _ = store.applySubmissionState(submittedCanvasAssignmentIDs: ids, scores: [:])
        }
        let state = AppState(assignmentStore: store)
        state.forceFixtureDataForTesting(false)
        state.canvasItems = store.currentAssignments()
        state.rebuildDashboardItemsForTesting(now: Date())
        return (state, store)
    }

    @Test("a submitted assignment is locked")
    func submittedIsLocked() throws {
        let a = assignment("s1", submitted: true)
        let (state, _) = try state(items: [a])
        #expect(state.completionIsLockedByCanvas(a))
    }

    @Test("an id in the submitted set is locked")
    func submittedSetIsLocked() throws {
        let a = assignment("s2", canvasID: "77")
        #expect(a.canvasAssignmentID == "77")
        let (state, _) = try state(submitted: ["77"], items: [a])
        #expect(state.completionIsLockedByCanvas(a))
    }

    @Test("the student's own tick alone is not locked")
    func studentTickIsNotLocked() throws {
        let a = assignment("s3", canvasID: "78")
        let (state, _) = try state(items: [a])
        state.markCompleted(a)
        #expect(state.isCompleted(a))
        #expect(!state.completionIsLockedByCanvas(a))
    }

    @Test("an untouched assignment is not locked")
    func plainIsNotLocked() throws {
        let a = assignment("s4", canvasID: "79")
        let (state, _) = try state(items: [a])
        #expect(!state.completionIsLockedByCanvas(a))
    }

    @Test("structured completion alone is not locked")
    func structuredIsNotLocked() throws {
        let a = assignment("s5", canvasID: "80")
        let (state, _) = try state(items: [a])
        state.structuredCompletedItemIDs = [a.id]
        #expect(state.isCompleted(a))
        #expect(!state.completionIsLockedByCanvas(a))
    }

    @Test("completed cards carry canMarkActive from the lock")
    func cardsCarryCanMarkActive() throws {
        let locked = assignment("v1", canvasID: "90")
        let ticked = assignment("v2", canvasID: "81")
        let (state, _) = try state(submitted: ["90"], items: [locked, ticked])
        state.markCompleted(ticked)
        state.rebuildDashboardItemsForTesting(now: Date())
        let vm = DashboardViewModel()
        vm.bind(to: state)
        let l = try #require(vm.items.first { $0.id == locked.id })
        let t = try #require(vm.items.first { $0.id == ticked.id })
        #expect(l.isCompleted && !l.canMarkActive)
        #expect(t.isCompleted && t.canMarkActive)
    }

    @Test("DoneView resets the undo latch and gates the gesture on canMarkActive")
    func doneViewSource() throws {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/LowHangingFruitUI/DoneView.swift")
        let source = try String(contentsOf: url, encoding: .utf8)
        let undoBody = try #require(source.range(of: "onTap()\n"))
        #expect(source[undoBody.upperBound...].contains("didUndo = false"))
        #expect(source.contains("guard item.canMarkActive, !didUndo"))
        #expect(source.contains("item.canMarkActive ? \"Tap or swipe left to mark incomplete\" : \"turned in on canvas\""))
    }
}
