import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// Pins what `Assignment.canvasAssignmentID` returns for a sub-assignment UID, so
/// nobody changes it by accident.
///
/// The three expressions behind that property used to be compiled on every call
/// and are now compiled once (`static let`). That is a performance change and must
/// not be an identity change: the id is the join key to submission state and to
/// dedup, so a different answer for any input silently reports someone else's
/// submission as the student's own.
///
/// The value pinned here is what the code returned BEFORE the expressions were
/// hoisted (this test was run against the unmodified property first), and it is
/// arguably not what one would design: the third expression, `assignment-(\d+)`,
/// is unanchored, so it finds "assignment-7" inside "sub_assignment-7" and a
/// sub-assignment (checkpoint) UID resolves to "7". That is the same behaviour
/// `SourceLinkTests.subAssignmentFragmentNotRebuilt` already documents from the
/// other side. Changing it is a decision about identity, not a tidy-up, and
/// belongs in its own change with its own tests; this one only keeps it still.
@Suite("Canvas assignment id: pinned results")
struct CanvasAssignmentIDPinTests {
    private func canvas(
        sourceID: String,
        url: String? = nil,
        source: Assignment.Source = .canvas
    ) -> Assignment {
        Assignment(
            source: source, sourceID: sourceID, kind: .assignment,
            course: "PIN 0001", title: "Pinned",
            dueAt: nil, url: url.flatMap(URL.init(string:))
        )
    }

    @Test("a sub-assignment UID with no URL resolves to the digits after 'assignment-', which is 7")
    func subAssignmentUIDWithNoURL() {
        let a = canvas(sourceID: "event-sub_assignment-7@canvas.upenn.edu")
        #expect(a.canvasAssignmentID == "7")
    }

    @Test("a sub-assignment UID under a #sub_assignment_ fragment still resolves to 7, through the UID")
    func subAssignmentUIDWithSubAssignmentFragment() {
        // The fragment pattern needs a literal "#" before "assignment_", so
        // "#sub_assignment_7" does not match it; the answer comes from the UID.
        let a = canvas(
            sourceID: "event-sub_assignment-7@canvas.upenn.edu",
            url: "https://canvas.upenn.edu/calendar?include_contexts=course_1&month=09&year=2026#sub_assignment_7"
        )
        #expect(a.canvasAssignmentID == "7")
    }

    @Test("the UID fallback is never run for a module-imported row")
    func subAssignmentUIDOnAModuleRowIsNil() {
        let a = canvas(sourceID: "event-sub_assignment-7@canvas.upenn.edu", source: .canvasModules)
        #expect(a.canvasAssignmentID == nil)
    }

    @Test("a section-override UID does not match the UID fallback")
    func overrideUIDIsNil() {
        let a = canvas(sourceID: "event-assignment-override-99@canvas.upenn.edu")
        #expect(a.canvasAssignmentID == nil)
    }

    @Test("the three expressions are still tried in order: path, then fragment, then UID")
    func orderIsPathFragmentUID() {
        let all = canvas(
            sourceID: "event-assignment-3@canvas.upenn.edu",
            url: "https://canvas.upenn.edu/courses/1/assignments/1#assignment_2"
        )
        #expect(all.canvasAssignmentID == "1")
        let fragmentAndUID = canvas(
            sourceID: "event-assignment-3@canvas.upenn.edu",
            url: "https://canvas.upenn.edu/calendar?include_contexts=course_1#assignment_2"
        )
        #expect(fragmentAndUID.canvasAssignmentID == "2")
        let uidOnly = canvas(sourceID: "event-assignment-3@canvas.upenn.edu")
        #expect(uidOnly.canvasAssignmentID == "3")
    }
}
