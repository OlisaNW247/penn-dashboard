import Testing
import Foundation
@testable import LowHangingFruitKit

/// Coverage for the module-imported-assignment submission join added
/// alongside `SubmissionMatcher`: a `.canvasModules` row now reads as
/// submitted the same way a `.canvas` (ICS) row does, either from its own
/// URL-derived `canvasAssignmentID` or, when the module item carried no such
/// URL, from `AssignmentStore.applySubmissionState`'s
/// `fallbackCanvasAssignmentIDs` parameter.
@MainActor
@Suite("Canvas Modules submission join")
struct CanvasModulesSubmissionTests {

    private func moduleRow(
        id: String,
        course: String = "CIS 1200",
        title: String = "Homework 3",
        url: URL? = nil
    ) -> Assignment {
        Assignment(source: .canvasModules, sourceID: id, kind: .assignment,
                   course: course, title: title, dueAt: nil, url: url)
    }

    private func row(_ store: AssignmentStore, _ id: String) -> StoredAssignment? {
        store.allRowsForTesting().first { $0.id == id }
    }

    @Test("a .canvasModules row with an /assignments/ url is marked submitted directly")
    func moduleRowSubmittedByOwnURLID() throws {
        let store = try AssignmentStore(inMemory: true)
        let item = moduleRow(
            id: "module-item-1",
            url: URL(string: "https://canvas.upenn.edu/courses/1/assignments/555")
        )
        _ = store.reconcile([item], source: .canvasModules)

        _ = store.applySubmissionState(submittedCanvasAssignmentIDs: ["555"], scores: [:])

        let stored = try #require(row(store, item.id))
        #expect(stored.canvasSubmitted)
    }

    @Test("a .canvasModules row with no url is marked submitted via fallbackCanvasAssignmentIDs")
    func moduleRowSubmittedByFallbackID() throws {
        let store = try AssignmentStore(inMemory: true)
        let item = moduleRow(id: "module-item-2", url: nil)
        _ = store.reconcile([item], source: .canvasModules)

        _ = store.applySubmissionState(
            submittedCanvasAssignmentIDs: ["777"],
            scores: [:],
            fallbackCanvasAssignmentIDs: [item.id: "777"]
        )

        let stored = try #require(row(store, item.id))
        #expect(stored.canvasSubmitted)
    }

    @Test("a .canvasModules row with no url and no fallback entry is left alone")
    func moduleRowWithoutAnyIDIsUntouched() throws {
        let store = try AssignmentStore(inMemory: true)
        let item = moduleRow(id: "module-item-3", url: nil)
        _ = store.reconcile([item], source: .canvasModules)

        _ = store.applySubmissionState(submittedCanvasAssignmentIDs: ["999"], scores: [:])

        let stored = try #require(row(store, item.id))
        #expect(!stored.canvasSubmitted)
    }

    @Test("submittedCanvasAssignmentIDs() reports a submitted .canvasModules row by its url-derived id")
    func submittedSetIncludesModuleRow() throws {
        let store = try AssignmentStore(inMemory: true)
        let item = moduleRow(
            id: "module-item-4",
            url: URL(string: "https://canvas.upenn.edu/courses/1/assignments/321")
        )
        _ = store.reconcile([item], source: .canvasModules)
        _ = store.applySubmissionState(submittedCanvasAssignmentIDs: ["321"], scores: [:])

        #expect(store.submittedCanvasAssignmentIDs().contains("321"))
    }
}
