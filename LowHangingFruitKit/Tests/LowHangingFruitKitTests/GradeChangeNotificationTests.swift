import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// Detecting a posted grade, and saying so without becoming spam.
@MainActor
@Suite("Grade change notifications")
struct GradeChangeNotificationTests {

    private func change(
        _ id: String,
        course: String = "CIS 3200",
        title: String = "Midterm",
        previous: Double? = nil,
        earned: Double,
        max: Double? = 100
    ) -> AssignmentStore.ScoreChange {
        .init(assignmentID: id, course: course, title: title,
              previous: previous, earned: earned, max: max)
    }

    // MARK: Detection on the ledger

    private func store() throws -> AssignmentStore { try AssignmentStore(inMemory: true) }

    private func canvas(_ id: String, title: String) -> Assignment {
        Assignment(source: .canvas, sourceID: id, kind: .assignment,
                   course: "CIS 3200", title: title, dueAt: Date(),
                   url: URL(string: "https://canvas.upenn.edu/courses/1/assignments/\(id)"))
    }

    @Test("a score appearing for the first time is reported as newly graded")
    func newGradeDetected() throws {
        let store = try store()
        _ = store.reconcile([canvas("501", title: "Midterm")], source: .canvas)

        let changes = store.applySubmissionState(
            submittedCanvasAssignmentIDs: ["501"],
            scores: ["501": (earned: 78, max: 100)]
        )
        #expect(changes.count == 1)
        #expect(changes[0].isNewlyGraded)
        #expect(changes[0].earned == 78)
        #expect(changes[0].title == "Midterm")
    }

    @Test("an unchanged score is not reported again on the next refresh")
    func idempotentAcrossRefreshes() throws {
        let store = try store()
        _ = store.reconcile([canvas("501", title: "Midterm")], source: .canvas)
        _ = store.applySubmissionState(submittedCanvasAssignmentIDs: ["501"],
                                       scores: ["501": (earned: 78, max: 100)])

        let again = store.applySubmissionState(submittedCanvasAssignmentIDs: ["501"],
                                               scores: ["501": (earned: 78, max: 100)])
        #expect(again.isEmpty)
    }

    @Test("a regrade is reported and carries the previous score")
    func regradeDetected() throws {
        let store = try store()
        _ = store.reconcile([canvas("501", title: "Midterm")], source: .canvas)
        _ = store.applySubmissionState(submittedCanvasAssignmentIDs: ["501"],
                                       scores: ["501": (earned: 78, max: 100)])

        let changes = store.applySubmissionState(submittedCanvasAssignmentIDs: ["501"],
                                                 scores: ["501": (earned: 85, max: 100)])
        #expect(changes.count == 1)
        #expect(!changes[0].isNewlyGraded)
        #expect(changes[0].previous == 78)
        #expect(changes[0].earned == 85)
    }

    @Test("ungraded work reporting a null score is not a grade change")
    func nullScoreIsNotAChange() throws {
        let store = try store()
        _ = store.reconcile([canvas("501", title: "Midterm")], source: .canvas)
        let changes = store.applySubmissionState(submittedCanvasAssignmentIDs: ["501"],
                                                 scores: ["501": (earned: nil, max: 100)])
        #expect(changes.isEmpty)
    }

    // MARK: Wording & collapse

    @Test("a posted grade reads as posted, with the fraction and percent")
    func newlyGradedWording() {
        let requests = NotificationScheduler.gradeRequests([change("1", earned: 18, max: 20)])
        #expect(requests.count == 1)
        #expect(requests[0].content.title.contains("grade posted"))
        #expect(requests[0].content.body.contains("18/20 (90%)"))
    }

    @Test("a regrade reads as updated, not posted")
    func regradeWording() {
        let requests = NotificationScheduler.gradeRequests([
            change("1", previous: 70, earned: 85, max: 100)
        ])
        #expect(requests[0].content.title.contains("grade updated"))
    }

    @Test("a grade with no point total still renders a number")
    func missingMaxDoesNotDivideByZero() {
        #expect(NotificationScheduler.formatScore(change("1", earned: 9, max: nil)) == "9")
        #expect(NotificationScheduler.formatScore(change("1", earned: 9, max: 0)) == "9")
    }

    @Test("fractional scores keep one decimal place")
    func fractionalScores() {
        #expect(NotificationScheduler.formatScore(change("1", earned: 17.5, max: 20)) == "17.5/20 (88%)")
    }

    @Test("a whole assignment group posting at once collapses to one summary")
    func batchCollapses() {
        let many = (1...6).map { change("\($0)", title: "HW \($0)", earned: 10, max: 10) }
        let requests = NotificationScheduler.gradeRequests(many)
        #expect(requests.count == 1)
        #expect(requests[0].content.title.contains("6 new grades"))
        #expect(requests[0].content.body.contains("CIS 3200"))
    }

    @Test("grade notifications are delivered immediately, not scheduled")
    func deliveredImmediately() {
        // A scheduled request would be wiped by reschedule()'s cancelAll().
        let requests = NotificationScheduler.gradeRequests([change("1", earned: 5, max: 5)])
        #expect(requests[0].trigger == nil)
    }

    @Test("newly-posted grades sort ahead of regrades")
    func newsFirst() {
        let requests = NotificationScheduler.gradeRequests([
            change("1", course: "ZZZ 100", title: "Old", previous: 50, earned: 60),
            change("2", course: "AAA 100", title: "New", earned: 95),
        ])
        #expect(requests[0].content.body.contains("New"))
    }
}
