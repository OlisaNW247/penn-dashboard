import Foundation
import Testing
@testable import LowHangingFruitKit

/// Coverage for `GradeExplanation.make`, the pure "how this is calculated"
/// model Grade Watcher's explanation panel renders. One weighted fixture (also
/// covering `leftOutLine`, the "semester decided" `decidedLine` variant, and
/// all three `canvasLine` variants) and one points fixture (covering the
/// "posted only" `decidedLine` variant and the points-mode category-line
/// shape). Every expected number below is worked by hand against
/// `GradeEngine`'s documented formulas — see the inline comments for the
/// arithmetic.
@Suite("Grade explanation")
struct GradeExplanationTests {

    // MARK: - Helpers

    private func item(_ id: String, points: Double, score: Double? = nil, dueAt: Date? = nil) -> GradeItem {
        GradeItem(id: id, name: id, pointsPossible: points, score: score, scoreSource: score == nil ? nil : .canvas, dueAt: dueAt)
    }

    private func category(_ id: String, name: String, weight: Double? = nil, items: [GradeItem]) -> GradeCategory {
        GradeCategory(id: id, name: name, weight: weight, items: items)
    }

    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    /// Homework (30%, 1 of 2 posted graded, 8/10 -> 80%), Exams (50%, 1 of 1
    /// posted graded, 90/100 -> 90%), Untouched (20%, nothing scored yet).
    /// Every category has an `expectedCounts` entry, so the semester-decided
    /// estimate resolves: hw 10/40=0.25, exams 100/100=1.0, untouched
    /// 0/100=0 -> weighted by 30/50/20 out of 100 -> 0.575 (57.5%).
    /// currentPercent (participating hw+exams, weight 80): (30*80 + 50*90)/80
    /// = 86.25.
    private func weightedFixture() -> GradeBreakdown {
        let hw = category("hw", name: "Homework", weight: 30, items: [
            item("h1", points: 10, score: 8),
            item("h2", points: 10, score: nil),
        ])
        let exams = category("exams", name: "Exams", weight: 50, items: [
            item("e1", points: 100, score: 90),
        ])
        let untouched = category("untouched", name: "Untouched", weight: 20, items: [
            item("u1", points: 50, score: nil),
        ])
        return GradeEngine.compute(.init(
            courseUsesWeights: true, categories: [hw, exams, untouched], now: now,
            expectedCounts: ["hw": 4, "exams": 1, "untouched": 2]
        ))
    }

    /// Assignments (1 of 2 posted graded, 40/50 -> 80%), Quizzes (1 of 1
    /// posted graded, 20/20 -> 100%). No `expectedCounts`, so the semester
    /// estimate is unknown; posted-only decided = (50+20)/(100+20) = 70/120
    /// (58.3%). currentPercent = (40+20)/(50+20) = 60/70 (~85.7%).
    private func pointsFixture() -> GradeBreakdown {
        let asgn = category("asgn", name: "Assignments", items: [
            item("p1", points: 50, score: 40),
            item("p2", points: 50, score: nil),
        ])
        let quiz = category("quiz", name: "Quizzes", items: [
            item("q1", points: 20, score: 20),
        ])
        return GradeEngine.compute(.init(courseUsesWeights: false, categories: [asgn, quiz], now: now))
    }

    // MARK: - Weighted fixture

    @Test("weighted fixture: mode/formula lines name the arithmetic actually used")
    func weightedModeAndFormulaLines() {
        let explanation = GradeExplanation.make(from: weightedFixture(), canvasScore: nil)
        #expect(explanation.modeLine == "weighted by category (from canvas)")
        #expect(explanation.formulaLine == "each graded category's percent is multiplied by its weight, "
            + "added together, then divided by the combined weight of categories "
            + "with scored work so far (80%).")
    }

    @Test("weighted fixture: category lines carry weight, source, graded/expected counts, percent and contribution")
    func weightedCategoryLines() {
        let explanation = GradeExplanation.make(from: weightedFixture(), canvasScore: nil)
        #expect(explanation.categoryLines.count == 3)

        let hw = explanation.categoryLines[0]
        #expect(hw.id == "hw")
        #expect(hw.name == "Homework")
        #expect(hw.weightText == "30%")
        #expect(hw.weightSourceText == "canvas")
        #expect(hw.gradedText == "1 of 2 posted graded \u{00b7} 4 expected")
        #expect(hw.percentText == "80%")
        #expect(hw.contributionText == "+30 of your grade") // 80 * (30/80)
        #expect(hw.participates == true)
        #expect(hw.editedItemCount == 0)

        let exams = explanation.categoryLines[1]
        #expect(exams.id == "exams")
        #expect(exams.weightText == "50%")
        #expect(exams.gradedText == "1 of 1 posted graded \u{00b7} 1 expected")
        #expect(exams.percentText == "90%")
        #expect(exams.contributionText == "+56.3 of your grade") // 90 * (50/80) = 56.25 -> 56.3
        #expect(exams.participates == true)

        let untouched = explanation.categoryLines[2]
        #expect(untouched.id == "untouched")
        #expect(untouched.weightText == "20%")
        #expect(untouched.gradedText == "0 of 1 posted graded \u{00b7} 2 expected")
        #expect(untouched.percentText == "no scores yet")
        #expect(untouched.contributionText == nil)
        #expect(untouched.participates == false)
        #expect(untouched.editedItemCount == 0)
    }

    @Test("weighted fixture: leftOutLine names the untouched category with its weight")
    func weightedLeftOutLine() {
        let explanation = GradeExplanation.make(from: weightedFixture(), canvasScore: nil)
        #expect(explanation.leftOutLine == "left out until something is graded: Untouched (20%)")
    }

    @Test("weighted fixture: decidedLine reports the semester estimate once every category has an expected count")
    func weightedDecidedLineSemesterKnown() {
        let explanation = GradeExplanation.make(from: weightedFixture(), canvasScore: nil)
        #expect(explanation.decidedLine == "57.5% of the semester decided")
    }

    @Test("canvasLine: material disagreement names Canvas's number and the gap in points")
    func canvasLineDiffers() {
        let explanation = GradeExplanation.make(from: weightedFixture(), canvasScore: 80.0)
        // computed 86.25 vs canvas 80.0 -> 6.25pp apart, > 1.0pp threshold.
        #expect(explanation.canvasLine == "canvas shows 80% \u{2014} 6.3 points apart")
    }

    @Test("canvasLine: agreement within threshold reads as matching")
    func canvasLineMatches() {
        let explanation = GradeExplanation.make(from: weightedFixture(), canvasScore: 86.25)
        #expect(explanation.canvasLine == "matches canvas's own number")
    }

    @Test("canvasLine: nil when Canvas has no score to compare")
    func canvasLineNilWhenNoCanvasScore() {
        let explanation = GradeExplanation.make(from: weightedFixture(), canvasScore: nil)
        #expect(explanation.canvasLine == nil)
    }

    // MARK: - Points fixture

    @Test("points fixture: mode/formula lines describe the single-bucket arithmetic")
    func pointsModeAndFormulaLines() {
        let explanation = GradeExplanation.make(from: pointsFixture(), canvasScore: nil)
        #expect(explanation.modeLine == "points, no categories (from canvas)")
        #expect(explanation.formulaLine == "every point earned is divided by every point possible in "
            + "graded work so far, in one bucket.")
    }

    @Test("points fixture: category lines have no weight concept and no expected-count suffix")
    func pointsCategoryLines() {
        let explanation = GradeExplanation.make(from: pointsFixture(), canvasScore: nil)
        #expect(explanation.categoryLines.count == 2)

        let asgn = explanation.categoryLines[0]
        #expect(asgn.id == "asgn")
        #expect(asgn.weightText == "\u{2014}")
        #expect(asgn.weightSourceText == nil)
        #expect(asgn.gradedText == "1 of 2 posted graded") // no expectedCounts entry -> no suffix
        #expect(asgn.percentText == "80%")
        #expect(asgn.contributionText == "+57.1 of your grade") // 80 * (50/70)
        #expect(asgn.participates == true)

        let quiz = explanation.categoryLines[1]
        #expect(quiz.id == "quiz")
        #expect(quiz.weightText == "\u{2014}")
        #expect(quiz.gradedText == "1 of 1 posted graded")
        #expect(quiz.percentText == "100%")
        #expect(quiz.contributionText == "+28.6 of your grade") // 100 * (20/70)
        #expect(quiz.participates == true)
    }

    @Test("points fixture: leftOutLine is always nil (no weight concept to leave anything out of)")
    func pointsLeftOutLineNil() {
        let explanation = GradeExplanation.make(from: pointsFixture(), canvasScore: nil)
        #expect(explanation.leftOutLine == nil)
    }

    @Test("points fixture: decidedLine falls back to the posted-only figure when the semester estimate is unknown")
    func pointsDecidedLineSemesterUnknown() {
        let explanation = GradeExplanation.make(from: pointsFixture(), canvasScore: nil)
        #expect(explanation.decidedLine == "58.3% of what's posted is graded "
            + "\u{2014} semester share unknown until every category has an expected count")
    }

    @Test("points fixture: canvasLine is nil when there's no Canvas score to compare")
    func pointsCanvasLineNil() {
        let explanation = GradeExplanation.make(from: pointsFixture(), canvasScore: nil)
        #expect(explanation.canvasLine == nil)
    }

    // MARK: - expectedCountText (GradeCountPredictor wording)

    private let week: TimeInterval = 7 * 24 * 60 * 60

    @Test("expectedCountText: a student override reads '<count> (yours)'")
    func expectedCountTextOverride() {
        let hw = category("hw", name: "Papers", items: [item("h1", points: 10)])
        let breakdown = GradeEngine.compute(.init(
            courseUsesWeights: true, categories: [hw], now: now, expectedCounts: ["hw": 8]
        ))
        let explanation = GradeExplanation.make(from: breakdown, canvasScore: nil)
        #expect(explanation.categoryLines[0].expectedCountText == "8 (yours)")
    }

    @Test("expectedCountText: a syllabus-stated category map count reads '<count> from syllabus'")
    func expectedCountTextStated() {
        let canvas = category("c-quiz", name: "Quizzes", items: [item("q1", points: 10)])
        let map = GradeCategoryMap(categories: [
            GradeCategoryMap.Category(
                id: "map:quizzes", name: "Quizzes", weightPercent: 100,
                expectedCount: 8, canvasGroupIDs: ["c-quiz"], provenance: .syllabus
            ),
        ], provenance: .syllabus)
        let breakdown = GradeEngine.compute(.init(
            courseUsesWeights: false, categories: [canvas], now: now, categoryMap: map
        ))
        let explanation = GradeExplanation.make(from: breakdown, canvasScore: nil)
        #expect(explanation.categoryLines[0].expectedCountText == "8 from syllabus")
    }

    @Test("expectedCountText: a singular exam-like name reads '1 implied by name'")
    func expectedCountTextImpliedByName() {
        let final = category("final", name: "Final", items: [item("f1", points: 100, score: 90)])
        let breakdown = GradeEngine.compute(.init(courseUsesWeights: true, categories: [final], now: now))
        let explanation = GradeExplanation.make(from: breakdown, canvasScore: nil)
        #expect(explanation.categoryLines[0].expectedCountText == "1 implied by name")
    }

    @Test("expectedCountText: no statement, no term to project from -- reads '<posted count> listed'")
    func expectedCountTextListed() {
        let papers = category("papers", name: "Papers", items: [
            item("p1", points: 10), item("p2", points: 10), item("p3", points: 10), item("p4", points: 10),
        ])
        let breakdown = GradeEngine.compute(.init(courseUsesWeights: true, categories: [papers], now: now))
        let explanation = GradeExplanation.make(from: breakdown, canvasScore: nil)
        #expect(explanation.categoryLines[0].expectedCountText == "4 listed")
    }

    @Test("expectedCountText: a pace ahead of what's listed reads '<projected count> projected from pace'")
    func expectedCountTextProjected() {
        let start = Date(timeIntervalSince1970: 1_000_000_000)
        let sevenWeeksIn = start.addingTimeInterval(7 * week)
        let papers = category("papers", name: "Papers", items: [
            item("p1", points: 10, dueAt: start),
            item("p2", points: 10, dueAt: start),
            item("p3", points: 10, dueAt: start),
        ])
        let breakdown = GradeEngine.compute(.init(courseUsesWeights: true, categories: [papers], now: sevenWeeksIn))
        let explanation = GradeExplanation.make(from: breakdown, canvasScore: nil)
        // dueSoFar 3 / elapsed 7 weeks * 14-week term = 6, ahead of the 3 listed.
        #expect(explanation.categoryLines[0].expectedCountText == "6 projected from pace")
    }

    @Test("expectedCountText: an attendance category with no term reads plain 'by time'")
    func expectedCountTextAttendanceNoTerm() {
        let attendance = category("att", name: "Attendance", items: [item("a1", points: 10, score: 10)])
        let breakdown = GradeEngine.compute(.init(courseUsesWeights: true, categories: [attendance], now: now))
        let explanation = GradeExplanation.make(from: breakdown, canvasScore: nil)
        #expect(explanation.categoryLines[0].expectedCountText == "by time")
    }

    @Test("expectedCountText: an attendance category with a known term reads 'by time · week N of M'")
    func expectedCountTextAttendanceWithTerm() {
        let start = Date(timeIntervalSince1970: 1_000_000_000)
        let twoAndAHalfWeeksIn = start.addingTimeInterval(2.5 * week)
        let lecture = category("lecture", name: "Lecture", items: [item("l1", points: 100, dueAt: start)])
        let attendance = category("att", name: "Attendance", items: [item("a1", points: 10, score: 10)])
        let breakdown = GradeEngine.compute(.init(
            courseUsesWeights: true, categories: [lecture, attendance], now: twoAndAHalfWeeksIn
        ))
        let explanation = GradeExplanation.make(from: breakdown, canvasScore: nil)
        let attendanceLine = explanation.categoryLines.first { $0.id == "att" }
        #expect(attendanceLine?.expectedCountText == "by time \u{00b7} week 3 of 14")
    }
}
