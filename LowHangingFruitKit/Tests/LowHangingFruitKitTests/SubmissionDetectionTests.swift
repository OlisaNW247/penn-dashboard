import Foundation
import Testing
@testable import LowHangingFruitKit

/// Coverage for automatic submission detection: `AssignmentSubmissionInfo
/// .indicatesSubmitted` (the conservative "did they actually turn it in?"
/// rule) and `Assignment.canvasAssignmentID` (the join key back to it).
@Suite("Submission detection")
struct SubmissionDetectionTests {

    // MARK: - Helpers

    private func submission(
        workflowState: CanvasSubmissionState,
        submittedAt: Date? = nil,
        isMissing: Bool = false,
        isLate: Bool = false
    ) -> AssignmentSubmissionInfo {
        AssignmentSubmissionInfo(
            assignmentID: "1",
            workflowState: workflowState,
            submittedAt: submittedAt,
            isMissing: isMissing,
            isLate: isLate
        )
    }

    private let someDate = Date(timeIntervalSince1970: 1_700_000_000)

    // MARK: - indicatesSubmitted

    @Test("workflow_state submitted indicates submitted")
    func submittedWorkflowState() {
        #expect(submission(workflowState: .submitted).indicatesSubmitted)
    }

    @Test("workflow_state pending_review indicates submitted")
    func pendingReviewWorkflowState() {
        #expect(submission(workflowState: .pendingReview).indicatesSubmitted)
    }

    @Test("workflow_state unsubmitted with no submittedAt is not submitted")
    func unsubmittedWorkflowState() {
        #expect(!submission(workflowState: .unsubmitted).indicatesSubmitted)
    }

    @Test("workflow_state unknown with no submittedAt is not submitted")
    func unknownWorkflowState() {
        #expect(!submission(workflowState: .unknown).indicatesSubmitted)
    }

    @Test("graded with a real submittedAt and not missing indicates submitted")
    func gradedWithSubmittedAt() {
        #expect(submission(workflowState: .graded, submittedAt: someDate, isMissing: false).indicatesSubmitted)
    }

    @Test("graded but isMissing (professor entered a zero on missing work) is not submitted")
    func gradedButMissing() {
        #expect(!submission(workflowState: .graded, submittedAt: nil, isMissing: true).indicatesSubmitted)
    }

    @Test("unsubmitted workflow_state but a submittedAt is present (defensive) still indicates submitted")
    func unsubmittedWithSubmittedAtIsDefensivelySubmitted() {
        #expect(submission(workflowState: .unsubmitted, submittedAt: someDate).indicatesSubmitted)
    }

    @Test("isMissing always wins, even when submittedAt is set")
    func missingAlwaysWinsEvenWithSubmittedAt() {
        #expect(!submission(workflowState: .submitted, submittedAt: someDate, isMissing: true).indicatesSubmitted)
    }

    // MARK: - Assignment.canvasAssignmentID

    private func canvasAssignment(url: URL?, sourceID: String) -> Assignment {
        Assignment(
            source: .canvas,
            sourceID: sourceID,
            kind: .assignment,
            course: "TEST 1000",
            title: "Test item",
            dueAt: nil,
            url: url
        )
    }

    @Test("canvas assignment with an /assignments/ URL extracts the numeric id")
    func canvasAssignmentIDFromURL() {
        let a = canvasAssignment(
            url: URL(string: "https://canvas.upenn.edu/courses/1/assignments/12345"),
            sourceID: "event-assignment-12345@canvas.upenn.edu"
        )
        #expect(a.canvasAssignmentID == "12345")
    }

    @Test("canvas assignment with no URL falls back to the sourceID UID")
    func canvasAssignmentIDFromSourceIDFallback() {
        let a = canvasAssignment(url: nil, sourceID: "event-assignment-67890@canvas.upenn.edu")
        #expect(a.canvasAssignmentID == "67890")
    }

    @Test("canvas quiz-style URL and sourceID use a different id space and yield nil")
    func canvasQuizYieldsNil() {
        let a = canvasAssignment(
            url: URL(string: "https://canvas.upenn.edu/courses/1/quizzes/999"),
            sourceID: "event-quiz-999@canvas.upenn.edu"
        )
        #expect(a.canvasAssignmentID == nil)
    }

    @Test("gradescope source never yields a canvas assignment id")
    func gradescopeSourceYieldsNil() {
        let a = Assignment(
            source: .gradescope,
            sourceID: "gradescope-123",
            kind: .assignment,
            course: "TEST 1000",
            title: "Test item",
            dueAt: nil,
            url: URL(string: "https://canvas.upenn.edu/courses/1/assignments/12345")
        )
        #expect(a.canvasAssignmentID == nil)
    }

    @Test("manual source never yields a canvas assignment id")
    func manualSourceYieldsNil() {
        let a = Assignment(
            source: .manual,
            sourceID: "manual-1",
            kind: .assignment,
            course: "TEST 1000",
            title: "Test item",
            dueAt: nil,
            url: nil
        )
        #expect(a.canvasAssignmentID == nil)
    }
}
