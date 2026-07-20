import Foundation
import Testing
@testable import LowHangingFruitKit

/// Fixture-based decoding tests for `CanvasGradesClient` — no network calls.
/// Every test drives `CanvasGradesClient.decodeSnapshot(...)`, the pure
/// (network-free) seam the client's networked `fetchSnapshot` also calls, with
/// realistic Canvas JSON, then feeds the resulting `CourseGradeSnapshot`
/// straight into `GradeEngine.compute()` to prove the whole pipeline —
/// fetch-shape decode through to the math — produces sane end-to-end results.
@Suite("Canvas grades client")
struct CanvasGradesClientTests {

    private func data(_ json: String) -> Data { Data(json.utf8) }

    private func iso(_ string: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)!
    }

    private func approx(_ a: Double, _ b: Double, tolerance: Double = 0.001) -> Bool {
        abs(a - b) < tolerance
    }

    // MARK: - Weighted course, end-to-end through GradeEngine

    private static let weightedCourseJSON = """
    while(1);{
      "apply_assignment_group_weights": true,
      "enrollments": [
        {"type": "student", "computed_current_score": 91.4}
      ]
    }
    """

    private static let weightedGroupsJSON = """
    [
      {
        "id": 501,
        "name": "Homework",
        "group_weight": 40,
        "rules": {"drop_lowest": 0, "never_drop": []},
        "assignments": [
          {
            "id": 1001,
            "name": "HW1",
            "points_possible": 10,
            "omit_from_final_grade": false,
            "due_at": "2026-01-01T04:59:00Z",
            "submission": {"score": 8, "excused": false, "workflow_state": "graded", "missing": false, "late": false, "submitted_at": "2025-12-31T23:00:00Z"}
          },
          {
            "id": 1002,
            "name": "HW2",
            "points_possible": 10,
            "omit_from_final_grade": false,
            "due_at": "2026-01-05T04:59:00Z",
            "submission": {"score": null, "excused": false, "workflow_state": "unsubmitted", "missing": true, "late": false, "submitted_at": null}
          }
        ]
      },
      {
        "id": 502,
        "name": "Exams",
        "group_weight": 60,
        "rules": null,
        "assignments": [
          {
            "id": 2001,
            "name": "Midterm",
            "points_possible": 100,
            "omit_from_final_grade": false,
            "due_at": "2026-03-01T04:59:00Z",
            "submission": {"score": 95, "excused": false, "workflow_state": "graded", "missing": false, "late": false, "submitted_at": "2026-03-01T05:00:00Z"}
          }
        ]
      }
    ]
    """

    @Test("weighted course decodes and feeds GradeEngine to a sane 89% / 80% decided, with a submission side-channel")
    func weightedCourseEndToEnd() throws {
        let now = iso("2026-01-10T00:00:00Z")
        let snapshot = try CanvasGradesClient.decodeSnapshot(
            courseID: "123",
            courseJSON: data(Self.weightedCourseJSON),
            assignmentGroupPages: [data(Self.weightedGroupsJSON)],
            now: now
        )

        #expect(snapshot.courseUsesWeights)
        #expect(snapshot.categories.count == 2)
        #expect(approx(snapshot.canvasComputedCurrentScore ?? -1, 91.4))

        // Submission side-channel: one client serves the paused
        // submission-detection work too (HANDOFF.md).
        #expect(snapshot.submissions.count == 3)
        let hw2Submission = try #require(snapshot.submissions.first { $0.assignmentID == "1002" })
        #expect(hw2Submission.workflowState == .unsubmitted)
        #expect(hw2Submission.isMissing)
        #expect(hw2Submission.submittedAt == nil)

        let result = GradeEngine.compute(.init(
            courseUsesWeights: snapshot.courseUsesWeights,
            categories: snapshot.categories,
            now: now
        ))
        #expect(result.mode == .weighted)
        // Homework: 8/10 = 80% @ 40 weight. Exams: 95/100 = 95% @ 60 weight.
        // (40*80 + 60*95) / 100 = 89.
        #expect(result.currentPercent.map { approx($0, 89) } ?? false)
        // Homework 10/20 possible scored * weight 0.4 = 0.2; Exams 100/100 * 0.6 = 0.6.
        #expect(approx(result.decidedFraction, 0.8))
        // HW2 is past-due (relative to `now`) and unscored.
        #expect(result.pendingGradingCount == 1)

        // Canvas's own cross-check disagrees by > 1pt (89 vs 91.4) — should surface.
        #expect(GradeEngine.differsFromCanvas(computed: result.currentPercent!, canvasScore: snapshot.canvasComputedCurrentScore))
    }

    // MARK: - Points mode: apply_assignment_group_weights == false, garbage group_weight

    private static let pointsCourseJSON = """
    {
      "apply_assignment_group_weights": false,
      "enrollments": [
        {"type": "student", "computed_current_score": 93.0}
      ]
    }
    """

    private static let pointsGroupsJSON = """
    [
      {
        "id": 601,
        "name": "Labs",
        "group_weight": "N/A",
        "assignments": [
          {"id": 3001, "name": "Lab1", "points_possible": 20, "omit_from_final_grade": false, "due_at": null, "submission": {"score": 18, "excused": false, "workflow_state": "graded"}},
          {"id": 3002, "name": "Lab2", "points_possible": 20, "omit_from_final_grade": false, "due_at": "2027-01-01T00:00:00Z", "submission": null}
        ]
      },
      {
        "id": 602,
        "name": "Quizzes",
        "group_weight": null,
        "assignments": [
          {"id": 3101, "name": "Quiz1", "points_possible": 10, "omit_from_final_grade": false, "submission": {"score": 10, "excused": false, "workflow_state": "graded"}}
        ]
      }
    ]
    """

    @Test("points-mode course tolerates garbage group_weight values and ignores them entirely")
    func pointsModeGarbageWeightsIgnored() throws {
        let snapshot = try CanvasGradesClient.decodeSnapshot(
            courseID: "456",
            courseJSON: data(Self.pointsCourseJSON),
            assignmentGroupPages: [data(Self.pointsGroupsJSON)]
        )

        #expect(!snapshot.courseUsesWeights)
        // "N/A" fails Double parsing -> nil; JSON null -> nil. Both decode
        // without throwing.
        #expect(snapshot.categories.first { $0.id == "601" }?.weight == nil)
        #expect(snapshot.categories.first { $0.id == "602" }?.weight == nil)

        let result = GradeEngine.compute(.init(
            courseUsesWeights: snapshot.courseUsesWeights,
            categories: snapshot.categories
        ))
        #expect(result.mode == .points)
        // One implicit bucket: (18 + 10) / (20 + 10) = 93.33%.
        #expect(result.currentPercent.map { approx($0, 28.0 / 30.0 * 100) } ?? false)
        // Scored possible (20 + 10) / all possible (20 + 20 + 10) = 0.6.
        #expect(approx(result.decidedFraction, 0.6))
    }

    // MARK: - Hidden totals: computed_current_score nil is a normal state

    private static let hiddenTotalsCourseJSON = """
    {
      "apply_assignment_group_weights": true,
      "enrollments": [
        {"type": "student", "computed_current_score": null}
      ]
    }
    """

    private static let hiddenTotalsGroupsJSON = """
    [
      {
        "id": 701,
        "name": "Everything",
        "group_weight": 100,
        "assignments": [
          {"id": 4001, "name": "A1", "points_possible": 50, "omit_from_final_grade": false, "submission": {"score": 40, "excused": false, "workflow_state": "graded"}}
        ]
      }
    ]
    """

    @Test("hidden-totals course: nil computed_current_score is a normal state, not an error, and suppresses the cross-check note")
    func hiddenTotalsIsNormalNotError() throws {
        let snapshot = try CanvasGradesClient.decodeSnapshot(
            courseID: "789",
            courseJSON: data(Self.hiddenTotalsCourseJSON),
            assignmentGroupPages: [data(Self.hiddenTotalsGroupsJSON)]
        )

        #expect(snapshot.canvasComputedCurrentScore == nil)

        let result = GradeEngine.compute(.init(
            courseUsesWeights: snapshot.courseUsesWeights,
            categories: snapshot.categories
        ))
        #expect(result.currentPercent.map { approx($0, 80) } ?? false)
        // No Canvas number to disagree with -> never surfaces "differs".
        #expect(!GradeEngine.differsFromCanvas(computed: result.currentPercent!, canvasScore: snapshot.canvasComputedCurrentScore))
    }

    // MARK: - Excused submission

    private static let excusedGroupsJSON = """
    [
      {
        "id": 801,
        "name": "Homework",
        "group_weight": 100,
        "assignments": [
          {"id": 5001, "name": "Excused HW", "points_possible": 10, "omit_from_final_grade": false, "submission": {"score": 10, "excused": true, "workflow_state": "graded"}},
          {"id": 5002, "name": "Real HW", "points_possible": 10, "omit_from_final_grade": false, "submission": {"score": 7, "excused": false, "workflow_state": "graded"}}
        ]
      }
    ]
    """

    @Test("excused submission decodes isExcused, and the engine drops it from both earned and possible")
    func excusedSubmissionExcludedByEngine() throws {
        let snapshot = try CanvasGradesClient.decodeSnapshot(
            courseID: "999",
            courseJSON: data(Self.pointsCourseJSON), // weights flag irrelevant here
            assignmentGroupPages: [data(Self.excusedGroupsJSON)]
        )

        let category = try #require(snapshot.categories.first)
        let excusedItem = try #require(category.items.first { $0.id == "5001" })
        #expect(excusedItem.isExcused)
        #expect(excusedItem.score == 10) // raw score preserved; engine is what excludes it

        let result = GradeEngine.compute(.init(courseUsesWeights: true, categories: snapshot.categories))
        let categoryResult = try #require(result.categories.first)
        // Excused item removed entirely -- only "Real HW" (7/10) counts.
        #expect(categoryResult.totalCount == 1)
        #expect(categoryResult.earned == 7)
        #expect(categoryResult.possibleScored == 10)
    }

    // MARK: - Pagination

    private static let paginationPage1JSON = """
    [{"id": 901, "name": "Group A", "group_weight": 50, "assignments": [{"id": 6001, "name": "A1", "points_possible": 10, "omit_from_final_grade": false, "submission": {"score": 5, "excused": false}}]}]
    """
    private static let paginationPage2JSON = """
    [{"id": 902, "name": "Group B", "group_weight": 50, "assignments": [{"id": 6002, "name": "B1", "points_possible": 10, "omit_from_final_grade": false, "submission": {"score": 9, "excused": false}}]}]
    """

    @Test("multiple assignment_groups pages merge into one snapshot")
    func paginationMergesPages() throws {
        let snapshot = try CanvasGradesClient.decodeSnapshot(
            courseID: "111",
            courseJSON: data(Self.pointsCourseJSON),
            assignmentGroupPages: [data(Self.paginationPage1JSON), data(Self.paginationPage2JSON)]
        )
        #expect(snapshot.categories.map(\.id).sorted() == ["901", "902"])
        #expect(snapshot.categories.flatMap(\.items).count == 2)
    }

    @Test("Link header parsing finds rel=\"next\" among multiple relations")
    func linkHeaderParsesNext() {
        let header = "<https://canvas.upenn.edu/api/v1/courses/1/assignment_groups?page=1>; rel=\"first\", <https://canvas.upenn.edu/api/v1/courses/1/assignment_groups?page=3>; rel=\"next\", <https://canvas.upenn.edu/api/v1/courses/1/assignment_groups?page=10>; rel=\"last\""
        let next = CanvasGradesClient.nextPageURL(fromLinkHeader: header)
        #expect(next?.absoluteString == "https://canvas.upenn.edu/api/v1/courses/1/assignment_groups?page=3")
    }

    @Test("Link header with no next relation returns nil")
    func linkHeaderNoNextReturnsNil() {
        let header = "<https://canvas.upenn.edu/api/v1/courses/1/assignment_groups?page=1>; rel=\"first\", <https://canvas.upenn.edu/api/v1/courses/1/assignment_groups?page=1>; rel=\"last\""
        #expect(CanvasGradesClient.nextPageURL(fromLinkHeader: header) == nil)
        #expect(CanvasGradesClient.nextPageURL(fromLinkHeader: nil) == nil)
    }

    // MARK: - Security: next-page URL must be same-host https, or cookies would leak

    private static let base = URL(string: "https://canvas.upenn.edu")!

    @Test("same-host https next-page URL is trusted")
    func nextPageURLSameHostHTTPSTrusted() {
        let url = URL(string: "https://canvas.upenn.edu/api/v1/courses/1/assignment_groups?page=2")!
        #expect(CanvasGradesClient.isTrustedNextPageURL(url, baseURL: Self.base))
    }

    @Test("same-host https next-page URL is trusted case-insensitively")
    func nextPageURLHostCaseInsensitive() {
        let url = URL(string: "https://CANVAS.UPENN.EDU/api/v1/courses/1/assignment_groups?page=2")!
        #expect(CanvasGradesClient.isTrustedNextPageURL(url, baseURL: Self.base))
    }

    @Test("off-host next-page URL is rejected (would leak the session cookie to a third party)")
    func nextPageURLOffHostRejected() {
        let url = URL(string: "https://evil.example.com/api/v1/courses/1/assignment_groups?page=2")!
        #expect(!CanvasGradesClient.isTrustedNextPageURL(url, baseURL: Self.base))
    }

    @Test("suffix-trick host (canvas.upenn.edu.evil.com) is rejected, not just a substring match")
    func nextPageURLSuffixTrickRejected() {
        let url = URL(string: "https://canvas.upenn.edu.evil.com/api/v1/courses/1/assignment_groups?page=2")!
        #expect(!CanvasGradesClient.isTrustedNextPageURL(url, baseURL: Self.base))
    }

    @Test("plain http next-page URL is rejected even on the same host")
    func nextPageURLHTTPRejected() {
        let url = URL(string: "http://canvas.upenn.edu/api/v1/courses/1/assignment_groups?page=2")!
        #expect(!CanvasGradesClient.isTrustedNextPageURL(url, baseURL: Self.base))
    }

    // MARK: - XSSI prefix + session-expiry detection

    @Test("stripXSSIPrefix removes Canvas's while(1); guard, and is a no-op without it")
    func xssiPrefixStripped() {
        let withPrefix = data("while(1);{\"a\":1}")
        let stripped = CanvasGradesClient.stripXSSIPrefix(withPrefix)
        #expect(stripped == data("{\"a\":1}"))

        let withoutPrefix = data("{\"a\":1}")
        #expect(CanvasGradesClient.stripXSSIPrefix(withoutPrefix) == withoutPrefix)
    }

    @Test("looksLikeHTML detects a silent redirect-to-login body vs real JSON")
    func looksLikeHTMLDetectsLoginRedirect() {
        #expect(CanvasGradesClient.looksLikeHTML(data("<!DOCTYPE html><html><body>Log in</body></html>")))
        #expect(!CanvasGradesClient.looksLikeHTML(data("{\"apply_assignment_group_weights\": true}")))
        #expect(!CanvasGradesClient.looksLikeHTML(data("  \n  [{\"id\": 1}]")))
    }

    // MARK: - never_drop tolerates string ids, drop rules flow through to the engine

    private static let dropRulesGroupsJSON = """
    [
      {
        "id": 1001,
        "name": "Homework",
        "group_weight": 100,
        "rules": {"drop_lowest": 1, "never_drop": ["9001"]},
        "assignments": [
          {"id": 9001, "name": "Pinned worst", "points_possible": 10, "omit_from_final_grade": false, "submission": {"score": 1, "excused": false}},
          {"id": 9002, "name": "Mid", "points_possible": 10, "omit_from_final_grade": false, "submission": {"score": 5, "excused": false}},
          {"id": 9003, "name": "Best", "points_possible": 10, "omit_from_final_grade": false, "submission": {"score": 9, "excused": false}}
        ]
      }
    ]
    """

    @Test("string-typed never_drop id matches the numeric assignment id and protects it from drop-lowest")
    func neverDropStringIDMatchesNumericAssignment() throws {
        let snapshot = try CanvasGradesClient.decodeSnapshot(
            courseID: "222",
            courseJSON: data(Self.hiddenTotalsCourseJSON),
            assignmentGroupPages: [data(Self.dropRulesGroupsJSON)]
        )
        let category = try #require(snapshot.categories.first)
        #expect(category.neverDropIDs == ["9001"])
        #expect(category.dropLowest == 1)

        let result = GradeEngine.compute(.init(courseUsesWeights: true, categories: snapshot.categories))
        let categoryResult = try #require(result.categories.first)
        // "Mid" (9002) has the next-lowest ratio and isn't pinned -> dropped.
        // "Pinned worst" (9001) would normally drop but is protected.
        #expect(categoryResult.droppedItemIDs == ["9002"])
        #expect(categoryResult.earned == 1 + 9)
    }

    // MARK: - Course info decode is itself lenient (no "id" field required, missing enrollments)

    @Test("course info with no enrollments array decodes with a nil cross-check score")
    func courseInfoMissingEnrollments() throws {
        let snapshot = try CanvasGradesClient.decodeSnapshot(
            courseID: "333",
            courseJSON: data("{\"apply_assignment_group_weights\": false}"),
            assignmentGroupPages: [data(Self.paginationPage1JSON)]
        )
        #expect(!snapshot.courseUsesWeights)
        #expect(snapshot.canvasComputedCurrentScore == nil)
    }

    // MARK: - Decoding failure surfaces as a distinct, catchable error

    @Test("malformed assignment_groups JSON throws decodingFailed, not a crash")
    func malformedGroupsJSONThrows() {
        #expect(throws: CanvasGradesClient.Error.self) {
            _ = try CanvasGradesClient.decodeSnapshot(
                courseID: "444",
                courseJSON: data(Self.pointsCourseJSON),
                assignmentGroupPages: [data("not json at all")]
            )
        }
    }
}
