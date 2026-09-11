import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// Enforces the copy budget behind the minimal Grade Watcher rebuild
/// (docs/grades.md — the card and report used to carry full sentences; the
/// rebuild's whole premise is numbers and short labels instead). Every pure
/// string rule the card/report reduced to a `nonisolated static func` gets
/// checked here: at most six real words, at most 40 characters, no sentence-
/// ending period.
///
/// "Real words" deliberately excludes a lone `\u{00b7}` (the middot the house
/// style uses as a separator, e.g. "12% decided \u{00b7} week 3 of 14") --
/// counting the separator itself as a seventh word would penalize the exact
/// separator this codebase already uses everywhere else, rather than
/// catching an actual sentence. Percent values in every fixture below are
/// whole numbers on purpose, so `formatPercent`'s decimal point in a value
/// like "94.3%" never gets confused for the sentence-ending period this test
/// is actually checking for.
@Suite("Grade Watcher minimal copy budget")
struct GradeMinimalCopyTests {

    private func wordCount(_ text: String) -> Int {
        text.split(separator: " ")
            .filter { $0.contains { $0.isLetter || $0.isNumber } }
            .count
    }

    private func assertBudget(_ text: String, sourceLine: Int = #line) {
        #expect(wordCount(text) <= 6, "\(text) (line \(sourceLine))")
        #expect(text.count <= 40, "\(text) (line \(sourceLine))")
        #expect(!text.contains("."), "\(text) (line \(sourceLine))")
    }

    private func breakdown(
        decidedFraction: Double = 0.63,
        semesterDecidedFraction: Double? = nil,
        currentPercent: Double? = 91,
        attendanceOnlyPercent: Double? = nil,
        term: GradeCountPredictor.Term? = nil
    ) -> GradeBreakdown {
        var result = GradeBreakdown(
            mode: .points,
            currentPercent: currentPercent,
            decidedFraction: decidedFraction,
            pendingGradingCount: 0,
            categories: [],
            semesterDecidedFraction: semesterDecidedFraction,
            modeSource: .canvas,
            leftOutCategoryIDs: [],
            participatingWeightSum: nil,
            attendanceOnlyPercent: attendanceOnlyPercent
        )
        result.term = term
        return result
    }

    // MARK: - statusText

    @Test("statusText: no term -- just the decided percent")
    func statusTextNoTerm() {
        let text = GradeCourseCardView.statusText(for: breakdown(term: nil))
        #expect(text == "63% decided")
        assertBudget(text)
    }

    @Test("statusText: term just started -- week 1, never week 0")
    func statusTextTermWeekOne() {
        let term = GradeCountPredictor.Term(start: Date(), weeks: 14)
        let text = GradeCourseCardView.statusText(for: breakdown(term: term))
        #expect(text == "63% decided \u{00b7} week 1 of 14")
        assertBudget(text)
    }

    @Test("statusText: term fully elapsed -- clamped to the last week, not beyond it")
    func statusTextTermWeekFourteen() {
        let term = GradeCountPredictor.Term(start: Date().addingTimeInterval(-100 * 7 * 86400), weeks: 14)
        let text = GradeCourseCardView.statusText(for: breakdown(term: term))
        #expect(text == "63% decided \u{00b7} week 14 of 14")
        assertBudget(text)
    }

    // MARK: - targetText

    @Test("targetText: every Requirement case reduces to a short phrase")
    func targetTextEveryCase() {
        let reached = GradeReportView.targetText(.alreadyReached)
        #expect(reached == "reached")
        assertBudget(reached)

        let need = GradeReportView.targetText(.need(percent: 94))
        #expect(need == "need 94% avg")
        assertBudget(need)

        let unreachable = GradeReportView.targetText(.unreachable(shortfall: 5))
        #expect(unreachable == "out of reach")
        assertBudget(unreachable)

        let nothingLeft = GradeReportView.targetText(.nothingLeft)
        #expect(nothingLeft == "nothing left")
        assertBudget(nothingLeft)
    }

    // MARK: - rangeText

    @Test("rangeText: floor and ceiling on one line")
    func rangeTextFloorCeiling() {
        let text = GradeReportView.rangeText(floor: 61, ceiling: 97)
        #expect(text == "floor 61% \u{00b7} ceiling 97%")
        assertBudget(text)
    }

    // MARK: - gradescopeMatchText
    //
    // Exempt from the six-word budget on purpose (see the doc comment on
    // `GradeReportView.gradescopeMatchText`): an assignment title is a proper
    // noun the student needs to recognize, not house-style prose, so only
    // the 40-character ceiling applies here, enforced by truncation rather
    // than by word count.

    @Test("gradescopeMatchText: short names pass through untouched")
    func gradescopeMatchTextShortNames() {
        let text = GradeReportView.gradescopeMatchText(gradescopeName: "HW 1", canvasName: "Homework 1")
        #expect(text == "gradescope: HW 1 \u{2192} Homework 1")
        #expect(text.count <= 40)
    }

    @Test("gradescopeMatchText: long names are truncated with an ellipsis to hold the 40-character budget")
    func gradescopeMatchTextLongNamesTruncate() {
        let text = GradeReportView.gradescopeMatchText(
            gradescopeName: "Problem Set Number Seven",
            canvasName: "Homework Assignment Seven"
        )
        #expect(text == "gradescope: Problem Set\u{2026} \u{2192} Homework As\u{2026}")
        #expect(text.count <= 40)
    }

    // MARK: - headlineText (already covered for correctness by
    // GradeDecidedTextTests -- this only checks the copy budget)

    @Test("headlineText: computed percent case stays within budget")
    func headlineTextPercentCaseBudget() {
        let headline = GradeCourseCardView.headlineText(for: breakdown(currentPercent: 91))
        assertBudget(headline.primary)
        #expect(headline.secondary == nil)
    }

    @Test("headlineText: no scores at all stays within budget")
    func headlineTextNoScoresCaseBudget() {
        let headline = GradeCourseCardView.headlineText(for: breakdown(currentPercent: nil, attendanceOnlyPercent: nil))
        assertBudget(headline.primary)
        #expect(headline.secondary == nil)
    }

    @Test("headlineText: attendance-only case stays within budget on both lines")
    func headlineTextAttendanceOnlyCaseBudget() {
        let headline = GradeCourseCardView.headlineText(for: breakdown(currentPercent: nil, attendanceOnlyPercent: 100))
        assertBudget(headline.primary)
        if let secondary = headline.secondary {
            assertBudget(secondary)
        } else {
            Issue.record("attendance-only headline should carry a secondary line")
        }
    }
}
