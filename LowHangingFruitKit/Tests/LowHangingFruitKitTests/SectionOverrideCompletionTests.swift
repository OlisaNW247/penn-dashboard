import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// Section-override ICS rows through `AppState.isCompleted`.
///
/// When a section due-date override applies, Canvas's `to_ics` emits
/// `UID: event-assignment-override-<overrideID>` and
/// `SUMMARY: "<title> (<section>) [<code>]"`, and leaves the `URL` alone, so
/// the real assignment id lives ONLY in the `#assignment_<id>` fragment. The
/// UID's number is a section-override id from a different id space. These
/// tests pin the join all the way to the dashboard's done/not-done answer:
/// the fragment id is looked up in the submitted set, and nothing else is.
///
/// Driving `submittedCanvasAssignmentIDs` needs no network and no shared
/// defaults: `AppState.init` seeds it from the ledger
/// (`store.submittedCanvasAssignmentIDs()`), so each test seeds an in-memory
/// ledger with ordinary rows for the ids it wants "submitted" and builds its
/// own `AppState` over it. The property itself is `private(set)`, which is why
/// the ledger is the seam.
@MainActor
@Suite("Section-override rows through isCompleted")
struct SectionOverrideCompletionTests {

    /// An `AppState` whose submitted set is exactly `ids`, via the ledger.
    private func state(submitted ids: Set<String>) throws -> AppState {
        let store = try AssignmentStore(inMemory: true)
        let seeds = ids.sorted().map { id in
            Assignment(
                source: .canvas, sourceID: "seed-\(id)", kind: .assignment,
                course: "OVR SEED 100", title: "Seed \(id)", dueAt: nil,
                url: URL(string: "https://canvas.upenn.edu/courses/1/assignments/\(id)")
            )
        }
        _ = store.reconcile(seeds, source: .canvas)
        _ = store.applySubmissionState(submittedCanvasAssignmentIDs: ids, scores: [:])
        let state = AppState(assignmentStore: store)
        // The premise of every test below: the set is what the test said.
        #expect(state.submittedCanvasAssignmentIDs == ids)
        return state
    }

    /// The row under test: override UID `99`, real assignment id `42` in the
    /// fragment. `dueAt` is nil so the persisted "nothing to submit" cache can
    /// never auto-file it (`isAutoFiledNoSubmission` needs a past due date),
    /// leaving the submitted-set lookup as the only way it can read done.
    private func overrideRow(fragment: String? = "42") -> Assignment {
        let tail = fragment.map { "#assignment_\($0)" } ?? ""
        return Assignment(
            source: .canvas,
            sourceID: "event-assignment-override-99@canvas.upenn.edu",
            kind: .assignment,
            course: "OVR 100",
            title: "Lab 3 (Section 201) [OVR 100]",
            dueAt: nil,
            url: URL(string: "https://canvas.upenn.edu/calendar?include_contexts=course_1&month=10&year=2026\(tail)")
        )
    }

    @Test("an override row reads done when its fragment's assignment id is in the submitted set")
    func fragmentIDInSetIsCompleted() throws {
        let row = overrideRow()
        #expect(row.canvasAssignmentID == "42")
        #expect(try state(submitted: ["42"]).isCompleted(row))
    }

    @Test("an override row stays not done when the set holds only a longer id that merely starts with its own")
    func longerIDDoesNotMatch() throws {
        let row = overrideRow()
        #expect(!(try state(submitted: ["4242"]).isCompleted(row)))
        #expect(!(try state(submitted: ["420"]).isCompleted(row)))
    }

    @Test("an override row never reads done through the override id in its UID")
    func uidOverrideIDIsNeverUsed() throws {
        let row = overrideRow()
        // 99 is the override id from `event-assignment-override-99`. If the
        // join ever parsed the UID's trailing number, this would read done.
        #expect(!(try state(submitted: ["99"]).isCompleted(row)))
        #expect(!(try state(submitted: ["99", "4242"]).isCompleted(row)))
        // And the fragment still wins when both are present.
        #expect(try state(submitted: ["99", "42"]).isCompleted(row))
    }

    @Test("an override row with no assignment fragment has no id to join on, so the UID number cannot stand in")
    func noFragmentMeansNoJoin() throws {
        let row = overrideRow(fragment: nil)
        #expect(row.canvasAssignmentID == nil)
        #expect(!(try state(submitted: ["99"]).isCompleted(row)))
    }

    @Test("a sub-assignment fragment is not an assignment id")
    func subAssignmentFragmentDoesNotJoin() throws {
        let row = Assignment(
            source: .canvas,
            sourceID: "event-assignment-override-99@canvas.upenn.edu",
            kind: .assignment, course: "OVR 100",
            title: "Lab 3 (Section 201) [OVR 100]", dueAt: nil,
            url: URL(string: "https://canvas.upenn.edu/calendar?include_contexts=course_1#sub_assignment_42")
        )
        #expect(row.canvasAssignmentID == nil)
        #expect(!(try state(submitted: ["42", "99"]).isCompleted(row)))
    }
}
