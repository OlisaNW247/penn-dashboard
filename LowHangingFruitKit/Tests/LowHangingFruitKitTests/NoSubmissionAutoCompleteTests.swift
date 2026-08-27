import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// Coverage for the "attend the review session" auto-complete rule: a Canvas
/// assignment with nothing to submit online should move to the submitted
/// pile once its own deadline passes, and fall back out if the professor
/// later moves the deadline into the future. Exercises the two pure pieces —
/// `GradeItem.requiresNoSubmission` and
/// `AppState.autoSubmittedNoSubmissionIDs` — plus the decoding that feeds
/// `requiresNoSubmission`, all without a network or `GradeWatcherStore`.
@MainActor
@Suite("No-submission auto-complete")
struct NoSubmissionAutoCompleteTests {

    // MARK: - GradeItem.requiresNoSubmission

    private func item(submissionTypes: [String]?, dueAt: Date? = nil) -> GradeItem {
        GradeItem(
            id: "1",
            name: "Fake assignment",
            pointsPossible: 10,
            dueAt: dueAt,
            submissionTypes: submissionTypes
        )
    }

    @Test("[\"none\"] requires no submission")
    func noneRequiresNoSubmission() {
        #expect(item(submissionTypes: ["none"]).requiresNoSubmission)
    }

    @Test("[\"on_paper\"] requires no submission")
    func onPaperRequiresNoSubmission() {
        #expect(item(submissionTypes: ["on_paper"]).requiresNoSubmission)
    }

    @Test("[\"not_graded\"] requires no submission")
    func notGradedRequiresNoSubmission() {
        #expect(item(submissionTypes: ["not_graded"]).requiresNoSubmission)
    }

    @Test("a hybrid of on_paper and online_upload still expects a real submission")
    func hybridStillRequiresSubmission() {
        #expect(!item(submissionTypes: ["on_paper", "online_upload"]).requiresNoSubmission)
    }

    @Test("empty submission_types array does not require no submission")
    func emptyArrayDoesNotQualify() {
        #expect(!item(submissionTypes: []).requiresNoSubmission)
    }

    @Test("nil submission_types (Canvas didn't say) does not require no submission")
    func nilDoesNotQualify() {
        #expect(!item(submissionTypes: nil).requiresNoSubmission)
    }

    @Test("[\"online_upload\"] alone is a normal submittable assignment")
    func onlineUploadDoesNotQualify() {
        #expect(!item(submissionTypes: ["online_upload"]).requiresNoSubmission)
    }

    // MARK: - AppState.autoSubmittedNoSubmissionIDs

    private func snapshot(items: [GradeItem], courseID: String = "1") -> CourseGradeSnapshot {
        CourseGradeSnapshot(
            courseID: courseID,
            courseUsesWeights: false,
            categories: [GradeCategory(id: "cat-1", name: "Everything", items: items)],
            canvasComputedCurrentScore: nil,
            submissions: [],
            fetchedAt: Date()
        )
    }

    @Test("past-due, no-submission-required item is included")
    func pastDueNoSubmissionIncluded() {
        let now = Date()
        let past = now.addingTimeInterval(-3600)
        let snap = snapshot(items: [item(submissionTypes: ["none"], dueAt: past)])
        let ids = AppState.autoSubmittedNoSubmissionIDs(snapshots: [snap], now: now)
        #expect(ids == ["1"])
    }

    @Test("future-due, no-submission-required item is excluded (deadline hasn't passed yet)")
    func futureDueExcluded() {
        let now = Date()
        let future = now.addingTimeInterval(3600)
        let snap = snapshot(items: [item(submissionTypes: ["none"], dueAt: future)])
        let ids = AppState.autoSubmittedNoSubmissionIDs(snapshots: [snap], now: now)
        #expect(ids.isEmpty)
    }

    @Test("past-due but normally submittable item is excluded")
    func pastDueSubmittableExcluded() {
        let now = Date()
        let past = now.addingTimeInterval(-3600)
        let snap = snapshot(items: [item(submissionTypes: ["online_upload"], dueAt: past)])
        let ids = AppState.autoSubmittedNoSubmissionIDs(snapshots: [snap], now: now)
        #expect(ids.isEmpty)
    }

    @Test("no-submission-required item with a nil due date is excluded — nothing has passed")
    func nilDueDateExcluded() {
        let now = Date()
        let snap = snapshot(items: [item(submissionTypes: ["none"], dueAt: nil)])
        let ids = AppState.autoSubmittedNoSubmissionIDs(snapshots: [snap], now: now)
        #expect(ids.isEmpty)
    }

    @Test("a deadline moved back into the future falls back out — the helper is a pure function of the current snapshot, not sticky state")
    func movedDeadlineFallsBackOut() {
        let now = Date()
        let past = now.addingTimeInterval(-3600)
        let future = now.addingTimeInterval(3600)

        let stillPastDue = snapshot(items: [item(submissionTypes: ["none"], dueAt: past)])
        #expect(AppState.autoSubmittedNoSubmissionIDs(snapshots: [stillPastDue], now: now) == ["1"])

        let rescheduled = snapshot(items: [item(submissionTypes: ["none"], dueAt: future)])
        #expect(AppState.autoSubmittedNoSubmissionIDs(snapshots: [rescheduled], now: now).isEmpty)
    }

    // MARK: - AppState.noSubmissionAssignmentIDs — the "never notify" superset

    @Test("noSubmissionAssignmentIDs includes every no-submission item regardless of due date; submittable items stay out")
    func noSubmissionSupersetIgnoresDueDates() {
        let now = Date()
        let items = [
            GradeItem(id: "undated", name: "Attend review", pointsPossible: 0,
                      submissionTypes: ["none"]),
            GradeItem(id: "future", name: "Bring worksheet", pointsPossible: 5,
                      dueAt: now.addingTimeInterval(3600), submissionTypes: ["on_paper"]),
            GradeItem(id: "online", name: "PSet upload", pointsPossible: 100,
                      dueAt: now.addingTimeInterval(-3600), submissionTypes: ["online_upload"]),
        ]
        let snap = snapshot(items: items)

        // The notification exclusion has no time component — undated and
        // not-yet-due no-submission items are in — while the auto-submit
        // STATE set still requires a passed deadline, so neither of the two
        // qualifies there. The submittable item appears in neither.
        #expect(AppState.noSubmissionAssignmentIDs(snapshots: [snap]) == ["undated", "future"])
        #expect(AppState.autoSubmittedNoSubmissionIDs(snapshots: [snap], now: now).isEmpty)
    }

    // MARK: - Decoding: submission_types + due_at thread through to GradeItem

    private func data(_ json: String) -> Data { Data(json.utf8) }

    private static let courseJSON = """
    {"apply_assignment_group_weights": false, "enrollments": []}
    """

    @Test("submission_types and due_at decode onto the public GradeItem model")
    func submissionTypesAndDueAtDecode() throws {
        let groupsJSON = """
        [
          {
            "id": 1,
            "name": "Group",
            "assignments": [
              {
                "id": 1001,
                "name": "Attend review session",
                "points_possible": 0,
                "omit_from_final_grade": false,
                "due_at": "2026-01-01T04:59:00Z",
                "submission_types": ["none"],
                "submission": null
              }
            ]
          }
        ]
        """
        let snapshot = try CanvasGradesClient.decodeSnapshot(
            courseID: "1",
            courseJSON: data(Self.courseJSON),
            assignmentGroupPages: [data(groupsJSON)]
        )
        let item = try #require(snapshot.categories.first?.items.first)
        #expect(item.submissionTypes == ["none"])
        #expect(item.dueAt != nil)
        #expect(item.requiresNoSubmission)
    }

    @Test("assignment payload without submission_types or due_at still decodes (tolerant of a Canvas instance omitting either field)")
    func absentFieldsStillDecode() throws {
        let groupsJSON = """
        [
          {
            "id": 1,
            "name": "Group",
            "assignments": [
              {
                "id": 1002,
                "name": "Ordinary upload",
                "points_possible": 10,
                "omit_from_final_grade": false,
                "submission": null
              }
            ]
          }
        ]
        """
        let snapshot = try CanvasGradesClient.decodeSnapshot(
            courseID: "1",
            courseJSON: data(Self.courseJSON),
            assignmentGroupPages: [data(groupsJSON)]
        )
        let item = try #require(snapshot.categories.first?.items.first)
        #expect(item.submissionTypes == nil)
        #expect(item.dueAt == nil)
        #expect(!item.requiresNoSubmission)
    }
}
