import Foundation
import Testing
@testable import LowHangingFruitKit

/// End-to-end coverage for `GradeEngine.compute` with a `GradeCategoryMap`
/// attached, built from the same PHYS 0151 real-phone fixture as
/// `GradeCategoryMapBuilderTests` (docs/grades.md §14 addendum,
/// 2026-09-10): a "Roll Call Attendance" item (100/100) sitting inside
/// Problem Sets, a zero-point Quiz 2 placeholder, and a syllabus whose
/// Midterm 1/2/3 and Final categories have no posted Canvas work yet. The
/// bug this fixture reproduces: points mode divided the attendance item's
/// 100 points by 160 posted points and reported "100%, 62% decided" — an
/// arithmetically correct, substantively dishonest answer, since the only
/// thing actually graded was attendance.
@Suite("Grade engine — category map (PHYS 0151 fixture)")
struct GradeEngineMapTests {

    private func item(_ id: String, points: Double, score: Double? = nil, name: String? = nil) -> GradeItem {
        GradeItem(id: id, name: name ?? id, pointsPossible: points, score: score)
    }

    private func canvasCategories(problemSet1Score: Double? = nil) -> [GradeCategory] {
        [
            GradeCategory(id: "g-quiz", name: "Quizzes", items: [
                item("quiz1", points: 10, name: "Quiz 1"),
                item("quiz3", points: 10, name: "Quiz 3"),
                item("quiz2", points: 0, name: "Quiz 2"),
            ]),
            GradeCategory(id: "g-pset", name: "Problem Sets", items: [
                item("ps1", points: 10, score: problemSet1Score, name: "Problem Set 1"),
                item("ps2", points: 10, name: "Problem Set 2"),
                item("rollcall", points: 100, score: 100, name: "Roll Call Attendance"),
            ]),
            GradeCategory(id: "g-work", name: "Worksheets", items: [
                item("w1", points: 5, name: "Worksheet 1"),
                item("w2", points: 5, name: "Worksheet 2"),
                item("w31", points: 5, name: "Worksheet 3.1"),
                item("w32", points: 5, name: "Worksheet 3.2"),
            ]),
            GradeCategory(id: "g-mid1", name: "Midterm 1", items: []),
            GradeCategory(id: "g-mid2", name: "Midterm 2", items: []),
            GradeCategory(id: "g-final", name: "Final", items: []),
            GradeCategory(id: "g-imported", name: "Imported Assignments", items: []),
        ]
    }

    private func syllabusScheme() -> SyllabusGradingScheme {
        let pairs: [(String, Double)] = [
            ("Quizzes", 15), ("Midterm 1", 15), ("Midterm 2", 15), ("Midterm 3", 15),
            ("Final", 20), ("HomeWorks", 10), ("Attendance/Participation", 10),
        ]
        let categories = pairs.map { name, weight in
            SyllabusCategory(id: TitleNormalizer.categoryKey(name), name: name, weightPercent: weight)
        }
        return SyllabusGradingScheme(categories: categories, confidence: .high, rawWeightSum: 100)
    }

    private func map(canvas: [GradeCategory]) -> GradeCategoryMap {
        let scheme = syllabusScheme()
        let match = SyllabusMatcher.match(scheme: scheme, canvasCategories: canvas)
        return GradeCategoryMapBuilder.suggested(
            scheme: scheme, match: match, canvasCategories: canvas, provenance: .syllabus
        )!
    }

    private func approx(_ a: Double, _ b: Double, tolerance: Double = 0.001) -> Bool {
        abs(a - b) < tolerance
    }

    @Test("attendance-only: currentPercent is nil, attendanceOnlyPercent is the attendance category's own 100%")
    func attendanceOnlyHeadline() {
        let canvas = canvasCategories()
        let breakdown = GradeEngine.compute(.init(
            courseUsesWeights: false, // Canvas has no group weights turned on -- the map overrides this
            categories: canvas,
            categoryMap: map(canvas: canvas)
        ))

        #expect(breakdown.mode == .weighted) // a category map always forces weighted mode
        #expect(breakdown.currentPercent == nil)
        #expect(breakdown.attendanceOnlyPercent.map { approx($0, 100) } ?? false)
    }

    @Test("decidedFraction (posted-only) is 10% -- exactly attendance's 10% weight, fully posted and scored")
    func decidedFractionIsAttendanceWeightAlone() {
        let canvas = canvasCategories()
        let breakdown = GradeEngine.compute(.init(
            courseUsesWeights: false, categories: canvas, categoryMap: map(canvas: canvas)
        ))
        #expect(approx(breakdown.decidedFraction, 0.10))
    }

    /// `semesterDecidedFraction` is DELIBERATELY nil here, not ~10% — this is
    /// worth spelling out because it's easy to expect otherwise. Midterm 1,
    /// Midterm 2, Midterm 3 and Final each carry a real, nonzero weight AND
    /// a known expected count (1, from the singular-exam-name default), but
    /// NOTHING has been posted for any of them yet (`totalCount == 0`). A
    /// KNOWN expected count with nothing posted is 0% decided, not
    /// "unknown" — we know the semester holds one midterm and that it
    /// doesn't exist in Canvas yet, which is itself an answer — so each of
    /// those four categories' own `semesterDecidedFraction` is exactly 0.
    /// Quizzes and HomeWorks are the ones that are ACTUALLY unknown here:
    /// the syllabus never said how many quizzes or homeworks there will be,
    /// so their `expectedCount` (and therefore `semesterDecidedFraction`) is
    /// nil, and THAT is what poisons the top-level weighted combiner to nil
    /// — `categoriesMissingExpectedCount` names exactly those two, in the
    /// order they appear in the map (Quizzes before HomeWorks), so
    /// `GradeExplanation.decidedLine` can say so instead of a generic
    /// "every category."
    @Test("semesterDecidedFraction is nil only because Quizzes/HomeWorks have no expected count -- not because exams haven't posted")
    func semesterDecidedFractionNilNamesQuizzesAndHomeworks() {
        let canvas = canvasCategories()
        let breakdown = GradeEngine.compute(.init(
            courseUsesWeights: false, categories: canvas, categoryMap: map(canvas: canvas)
        ))
        #expect(breakdown.semesterDecidedFraction == nil)
        #expect(breakdown.categoriesMissingExpectedCount == ["Quizzes", "HomeWorks"])

        let midterm1 = breakdown.categories.first { $0.name == "Midterm 1" }
        #expect(midterm1?.semesterDecidedFraction == 0) // known count, nothing posted -> 0, not nil
    }

    /// Once the syllabus (or the student) supplies the two missing counts,
    /// nothing else changes: attendance is the only scored work (1 of its 1
    /// expected item, fully decided), every exam still contributes 0 (known
    /// count, nothing posted), and quizzes/homeworks now ALSO contribute 0
    /// (known count, nothing scored) instead of blocking the estimate.
    /// 10% attendance weight × 1.0 decided = the whole answer.
    @Test("supplying Quizzes/HomeWorks expected counts resolves the estimate to ~10% -- exactly attendance's weight")
    func semesterDecidedFractionResolvesOnceCountsAreKnown() {
        let canvas = canvasCategories()
        let breakdown = GradeEngine.compute(.init(
            courseUsesWeights: false, categories: canvas,
            expectedCounts: ["map:quizzes": 3, "map:homeworks": 8],
            categoryMap: map(canvas: canvas)
        ))
        #expect(breakdown.categoriesMissingExpectedCount.isEmpty)
        #expect(breakdown.semesterDecidedFraction.map { approx($0, 0.10) } ?? false)
    }

    @Test("mirroringCanvas over a points-mode course stays points mode and grades normally once something is scored")
    func mirroringCanvasStaysPointsMode() {
        let canvas = canvasCategories(problemSet1Score: 9)
        let mirrored = GradeCategoryMapBuilder.mirroringCanvas(canvas, courseUsesWeights: false)
        let breakdown = GradeEngine.compute(.init(
            courseUsesWeights: false, categories: canvas, categoryMap: mirrored
        ))

        // Every category in a `courseUsesWeights: false` mirror carries
        // weight 0 on purpose (it mirrors Canvas's own "no weights" flag) --
        // forcing weighted mode over that would make the grade permanently
        // nil. The map still does its job structurally (Quiz 2's placeholder
        // is still gone, Roll Call is still routed to Attendance), it just
        // doesn't flip the course into weighted mode.
        #expect(breakdown.mode == .points)
        #expect(breakdown.currentPercent != nil)
    }

    @Test("once Problem Set 1 is graded, the headline is a real percent again")
    func realGradeOnceSomethingElseIsGraded() {
        let canvas = canvasCategories(problemSet1Score: 9)
        let breakdown = GradeEngine.compute(.init(
            courseUsesWeights: false, categories: canvas, categoryMap: map(canvas: canvas)
        ))

        #expect(breakdown.currentPercent != nil)
        #expect(breakdown.attendanceOnlyPercent == nil)
    }

    @Test("Quiz 2's placeholder never counts toward totalCount/possibleTotal")
    func placeholderNeverCountsTowardTotals() {
        let canvas = canvasCategories()
        let breakdown = GradeEngine.compute(.init(
            courseUsesWeights: false, categories: canvas, categoryMap: map(canvas: canvas)
        ))
        let quizzes = breakdown.categories.first { $0.name == "Quizzes" }
        // Quiz 1 and Quiz 3 only -- Quiz 2 (0 points, unscored) is gone.
        #expect(quizzes?.totalCount == 2)
        #expect(quizzes?.possibleTotal == 20)
    }

    @Test("Imported Assignments comes through as its own zero-weight, unmapped category")
    func importedAssignmentsIsUnmappedZeroWeight() {
        let canvas = canvasCategories()
        let breakdown = GradeEngine.compute(.init(
            courseUsesWeights: false, categories: canvas, categoryMap: map(canvas: canvas)
        ))
        let imported = breakdown.categories.first { $0.name == "Imported Assignments" }
        #expect(imported?.isUnmapped == true)
        #expect(imported?.effectiveWeight == 0)
    }

    @Test("the Roll Call item shows up under Attendance/Participation, tracked as a moved item")
    func rollCallTrackedAsMoved() {
        let canvas = canvasCategories()
        let breakdown = GradeEngine.compute(.init(
            courseUsesWeights: false, categories: canvas, categoryMap: map(canvas: canvas)
        ))
        let attendance = breakdown.categories.first { $0.name == "Attendance/Participation" }
        #expect(attendance?.movedItemIDs == ["rollcall"])
        #expect(attendance?.earned == 100)
    }

    @Test("HomeWorks reports the Canvas groups folded into it")
    func homeworksReportsFoldedGroupNames() {
        let canvas = canvasCategories()
        let breakdown = GradeEngine.compute(.init(
            courseUsesWeights: false, categories: canvas, categoryMap: map(canvas: canvas)
        ))
        let hw = breakdown.categories.first { $0.name == "HomeWorks" }
        #expect(Set(hw?.canvasGroupNames ?? []) == ["Problem Sets", "Worksheets"])
    }
}
