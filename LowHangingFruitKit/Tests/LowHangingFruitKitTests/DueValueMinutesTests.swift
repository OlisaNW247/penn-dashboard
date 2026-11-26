import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// The card's date column and the spoken/menu-bar due text, inside the last
/// hour. Both used to say "1h" for anything under an hour, so an item due in
/// 8 minutes looked like it had an hour left.
///
/// Only the minute/hour boundary is under test here; everything from an hour
/// up must read exactly as it always did (the "unchanged" tests pin that).
/// The day and weekday forms depend on the calendar and are not touched.
@Suite("Due value inside the last hour")
struct DueValueMinutesTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func card(_ secondsFromNow: TimeInterval) -> (String, String?) {
        let value = smoothDueValue(now.addingTimeInterval(secondsFromNow), now: now)
        return (value.primary, value.secondary)
    }

    // MARK: Card, upcoming

    @Test("30 seconds left reads 1m, never 0m")
    func thirtySeconds() {
        #expect(card(30).0 == "1m")
        #expect(card(30).1 == nil)
    }

    @Test("due right now reads 1m")
    func dueNow() {
        #expect(card(0).0 == "1m")
    }

    @Test("8 minutes left reads 8m")
    func eightMinutes() {
        #expect(card(8 * 60).0 == "8m")
        #expect(card(8 * 60 + 59).0 == "8m", "partial minutes round down")
    }

    @Test("59 minutes left reads 59m, even at 59:59")
    func fiftyNineMinutes() {
        #expect(card(59 * 60).0 == "59m")
        #expect(card(59 * 60 + 59).0 == "59m")
    }

    @Test("an hour or more reads exactly as it did")
    func atAndAboveAnHour() {
        #expect(card(60 * 60).0 == "1h")
        #expect(card(60 * 60 + 59).0 == "1h")
        #expect(card(5 * 3_600).0 == "5h")
        #expect(card(23 * 3_600 + 59 * 60).0 == "23h")
        #expect(card(5 * 3_600).1 == nil)
    }

    // MARK: Card, late

    @Test("30 seconds late reads 1m late, never 0m")
    func thirtySecondsLate() {
        #expect(card(-30).0 == "1m")
        #expect(card(-30).1 == "late")
    }

    @Test("8 minutes late reads 8m late")
    func eightMinutesLate() {
        #expect(card(-8 * 60).0 == "8m")
        #expect(card(-8 * 60).1 == "late")
    }

    @Test("59 minutes late reads 59m late")
    func fiftyNineMinutesLate() {
        #expect(card(-59 * 60).0 == "59m")
        #expect(card(-(59 * 60 + 59)).0 == "59m")
        #expect(card(-59 * 60).1 == "late")
    }

    @Test("an hour or more late reads exactly as it did")
    func atAndAboveAnHourLate() {
        #expect(card(-60 * 60).0 == "1h")
        #expect(card(-60 * 60).1 == "late")
        #expect(card(-3 * 3_600).0 == "3h")
        #expect(card(-23 * 3_600).0 == "23h")
        #expect(card(-23 * 3_600).1 == "late")
    }

    // MARK: Spoken / menu-bar text

    @Test("dueText counts minutes inside the last hour and hours from 60 minutes")
    func dueTextBoundary() {
        func text(_ seconds: TimeInterval) -> String {
            dueText(now.addingTimeInterval(seconds), now: now)
        }
        #expect(text(30) == "1m left")
        #expect(text(8 * 60) == "8m left")
        #expect(text(59 * 60) == "59m left")
        #expect(text(60 * 60) == "1h left")
        #expect(text(5 * 3_600) == "5h left")

        #expect(text(-30) == "1m late")
        #expect(text(-8 * 60) == "8m late")
        #expect(text(-59 * 60) == "59m late")
        #expect(text(-60 * 60) == "1h late")
        #expect(text(-3 * 3_600) == "3h late")
        #expect(dueText(nil, now: now) == "no due date")
    }

    @Test("the spoken label says it is the due time, and keeps the adjusted mark")
    func accessibilityLabel() {
        let soon = now.addingTimeInterval(8 * 60)
        #expect(dueAccessibilityLabel(soon, now: now) == "due, 8m left")
        #expect(dueAccessibilityLabel(now.addingTimeInterval(5 * 3_600), now: now) == "due, 5h left")
        #expect(dueAccessibilityLabel(now.addingTimeInterval(-3 * 3_600), now: now) == "due, 3h late")
        #expect(dueAccessibilityLabel(soon, adjusted: true, now: now) == "due, 8m left, adjusted")
        #expect(dueAccessibilityLabel(nil, now: now) == "no due date")
    }
}

/// The small line under the due value: the nothing-to-submit word, beaten by
/// "late" because only one word fits in that slot. Since 2026-11-10 the word
/// is "in class" only when Canvas says on paper, the item is an event, or the
/// title names a quiz or exam; otherwise "off canvas" (CIS 3990's Project 2,
/// handed in on a git server, read "in class" before).
@Suite("Due value secondary label")
struct DueValueSecondaryLabelTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("a nothing-to-submit word, not overdue, is shown")
    func shown() {
        let value = smoothDueValue(now.addingTimeInterval(5 * 3600), now: now)
        #expect(value.secondaryLabel(nothingToSubmit: "in class") == "in class")
        #expect(value.secondaryLabel(nothingToSubmit: "off canvas") == "off canvas")
    }

    @Test("nothing to submit and overdue says late")
    func lateWins() {
        let value = smoothDueValue(now.addingTimeInterval(-10 * 3600), now: now)
        #expect(value.secondaryLabel(nothingToSubmit: "in class") == "late")
    }

    @Test("a normal card that is not overdue has no secondary line")
    func normalHasNone() {
        let value = smoothDueValue(now.addingTimeInterval(5 * 3600), now: now)
        #expect(value.secondaryLabel(nothingToSubmit: nil) == nil)
    }

    @Test("the word per Canvas submission type",
          arguments: [
            // (submission_types, title, expected word)
            (["on_paper"], "Lab notebook check", "in class"),
            (["none"], "Project 2: Feature Extension", "off canvas"),
            (["not_graded"], "Reading response", "off canvas"),
            (["none"], "Quiz 7", "in class"),
            (["none"], "Midterm 3", "in class"),
            (["on_paper", "none"], "Worksheet", "in class"),
          ] as [([String], String, String)])
    func wordPerType(types: [String], title: String, expected: String) {
        let grade = GradeItem(id: "1", name: title, pointsPossible: 10, submissionTypes: types)
        #expect(grade.requiresNoSubmission)
        #expect(NothingToSubmitLabel.text(isEvent: false, submitsOnPaper: grade.submitsOnPaper, title: title) == expected)
    }

    @Test("an event keeps in class whatever its title")
    func eventKeepsInClass() {
        #expect(NothingToSubmitLabel.text(isEvent: true, submitsOnPaper: false, title: "Read chapter 27") == "in class")
    }

    @Test("a hybrid or online type is not on paper and not nothing-to-submit")
    func hybridIsNotOnPaper() {
        let hybrid = GradeItem(id: "1", name: "x", pointsPossible: 1, submissionTypes: ["on_paper", "online_upload"])
        #expect(!hybrid.requiresNoSubmission)
        #expect(!hybrid.submitsOnPaper)
        let unknown = GradeItem(id: "2", name: "x", pointsPossible: 1, submissionTypes: nil)
        #expect(!unknown.submitsOnPaper)
    }

    @Test("quiz is matched as a whole word")
    func quizWholeWord() {
        #expect(NothingToSubmitLabel.namesASitting("Quiz 8"))
        #expect(NothingToSubmitLabel.namesASitting("Weekly quizzes"))
        #expect(!NothingToSubmitLabel.namesASitting("Quizlet set"))
        #expect(!NothingToSubmitLabel.namesASitting("Project 2: Feature Extension"))
    }

    @Test("a DashItem says off canvas for a none assignment and in class for an on-paper one")
    func dashItemWord() {
        let a = Assignment(source: .canvas, sourceID: "p2", kind: .assignment, course: "CIS 3990",
                           title: "Project 2: Feature Extension", dueAt: nil, url: nil)
        #expect(DashItem(assignment: a, isCompleted: false, requiresNoSubmission: true).nothingToSubmitLabel == "off canvas")
        #expect(DashItem(assignment: a, isCompleted: false, requiresNoSubmission: true,
                         submitsOnPaper: true).nothingToSubmitLabel == "in class")
        #expect(DashItem(assignment: a, isCompleted: false).nothingToSubmitLabel == nil)
    }
}
