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
///
/// Quiz 1/3 and Problem Set 1/2 also carry due dates now (earliest 2 weeks
/// before `now`), so this fixture doubles as end-to-end coverage for
/// `GradeCountPredictor`: a 14-week term anchored on that earliest date, an
/// attendance category decided by elapsed time rather than by how many Roll
/// Call rows are posted, and a Quizzes category with no stated count
/// projecting from its own posting pace.
@Suite("Grade engine — category map (PHYS 0151 fixture)")
struct GradeEngineMapTests {

    private let week: TimeInterval = 7 * 24 * 60 * 60
    private let now = Date(timeIntervalSince1970: 2_000_000_000)
    private var twoWeeksBeforeNow: Date { now.addingTimeInterval(-2 * week) }
    private var oneWeekBeforeNow: Date { now.addingTimeInterval(-1 * week) }

    private func item(
        _ id: String,
        points: Double,
        score: Double? = nil,
        name: String? = nil,
        dueAt: Date? = nil
    ) -> GradeItem {
        GradeItem(id: id, name: name ?? id, pointsPossible: points, score: score, dueAt: dueAt)
    }

    /// `quizzesGraded` scores Quiz 1 and Quiz 3 (both otherwise unscored, as
    /// in the original attendance-only fixture) — a separate knob from due
    /// dates, since a projection's pace comes from WHEN items are due, not
    /// from whether they've been graded yet.
    private func canvasCategories(problemSet1Score: Double? = nil, quizzesGraded: Bool = false) -> [GradeCategory] {
        let quizScore: Double? = quizzesGraded ? 8 : nil
        return [
            GradeCategory(id: "g-quiz", name: "Quizzes", items: [
                item("quiz1", points: 10, score: quizScore, name: "Quiz 1", dueAt: twoWeeksBeforeNow),
                item("quiz3", points: 10, score: quizScore, name: "Quiz 3", dueAt: oneWeekBeforeNow),
                item("quiz2", points: 0, name: "Quiz 2"),
            ]),
            GradeCategory(id: "g-pset", name: "Problem Sets", items: [
                item("ps1", points: 10, score: problemSet1Score, name: "Problem Set 1", dueAt: twoWeeksBeforeNow),
                item("ps2", points: 10, name: "Problem Set 2", dueAt: oneWeekBeforeNow),
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

    /// `quizzesExpectedCount` lets a couple of tests give the syllabus an
    /// explicit "there will be N quizzes" statement — nil (the default)
    /// reproduces the original fixture exactly, where the syllabus never
    /// says how many quizzes there will be.
    private func syllabusScheme(quizzesExpectedCount: Int? = nil) -> SyllabusGradingScheme {
        let pairs: [(String, Double)] = [
            ("Quizzes", 15), ("Midterm 1", 15), ("Midterm 2", 15), ("Midterm 3", 15),
            ("Final", 20), ("HomeWorks", 10), ("Attendance/Participation", 10),
        ]
        let categories = pairs.map { name, weight in
            SyllabusCategory(
                id: TitleNormalizer.categoryKey(name),
                name: name,
                weightPercent: weight,
                expectedItemCount: name == "Quizzes" ? quizzesExpectedCount : nil
            )
        }
        return SyllabusGradingScheme(categories: categories, confidence: .high, rawWeightSum: 100)
    }

    private func map(canvas: [GradeCategory], quizzesExpectedCount: Int? = nil) -> GradeCategoryMap {
        let scheme = syllabusScheme(quizzesExpectedCount: quizzesExpectedCount)
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
            now: now,
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
            courseUsesWeights: false, categories: canvas, now: now, categoryMap: map(canvas: canvas)
        ))
        #expect(approx(breakdown.decidedFraction, 0.10))
    }

    /// Replaces the old "semesterDecidedFraction is nil only because
    /// Quizzes/HomeWorks have no expected count" test — `GradeCountPredictor`
    /// means that case can no longer occur. Attendance/Participation now
    /// reads off elapsed TIME (2 of the term's 14 weeks), not off how many
    /// Roll Call rows are posted, which is why its fraction no longer matches
    /// its being fully scored; an exam with nothing posted still contributes
    /// exactly 0 (a known count -- 1, from the singular-exam-name default --
    /// with none of it in Canvas yet is itself an answer, not "unknown").
    @Test("attendance is decided by elapsed time (2 of a 14-week term), and an exam with nothing posted is exactly 0")
    func attendanceIsTimeBasedAndEmptyExamIsZero() {
        let canvas = canvasCategories()
        let breakdown = GradeEngine.compute(.init(
            courseUsesWeights: false, categories: canvas, now: now, categoryMap: map(canvas: canvas)
        ))
        #expect(breakdown.term?.start == twoWeeksBeforeNow)

        let attendance = breakdown.categories.first { $0.name == "Attendance/Participation" }
        #expect(attendance?.isAttendance == true)
        #expect(attendance?.semesterDecidedFraction.map { approx($0, 2.0 / 14.0) } ?? false)

        let midterm1 = breakdown.categories.first { $0.name == "Midterm 1" }
        #expect(midterm1?.semesterDecidedFraction == 0)
        #expect(midterm1?.isAttendance == false)
    }

    /// Quizzes has no stated count anywhere (the syllabus never said how
    /// many), so it falls to `GradeCountPredictor`'s pace projection: both
    /// posted quizzes are due in the term's first 2 (of 14) weeks, so the
    /// projected whole-semester count is 14 regardless of whether they're
    /// graded yet -- the projection is driven by WHEN work is due, not by
    /// whether it's been scored. Once both are actually graded, the
    /// category's own fraction lands at exactly 2/14, the same number
    /// attendance lands on, since both stories are ultimately "2 of 14 weeks
    /// in."
    @Test("Quizzes has no stated count and projects from its own posting pace to 14, landing at 2/14 decided once graded")
    func quizzesProjectsFromPace() {
        let canvas = canvasCategories(quizzesGraded: true)
        let breakdown = GradeEngine.compute(.init(
            courseUsesWeights: false, categories: canvas, now: now, categoryMap: map(canvas: canvas)
        ))
        let quizzes = breakdown.categories.first { $0.name == "Quizzes" }
        #expect(quizzes?.countPrediction?.source == .projected)
        #expect(quizzes?.countPrediction?.count == 14)
        #expect(quizzes?.semesterDecidedFraction.map { approx($0, 2.0 / 14.0) } ?? false)
    }

    /// Replaces the old "supplying Quizzes/HomeWorks expected counts resolves
    /// the estimate to ~10%" test, whose premise (attendance alone, fully
    /// counted at its 10% weight) no longer holds now that attendance is
    /// time-based. The course-wide estimate is simply never nil anymore, and
    /// -- two weeks into a 14-week term with only attendance actually
    /// scored -- it lands well under the 20% mark a naive "62% decided"
    /// posted-only reading would have suggested.
    @Test("course-wide semesterDecidedFraction is never nil, lands well under 0.2 two weeks into term, and categoriesMissingExpectedCount is retired to empty")
    func courseWideSemesterFractionNeverNilAndReflectsHowLittleHasHappened() {
        let canvas = canvasCategories()
        let breakdown = GradeEngine.compute(.init(
            courseUsesWeights: false, categories: canvas, now: now, categoryMap: map(canvas: canvas)
        ))
        #expect(breakdown.term != nil)
        #expect(breakdown.categoriesMissingExpectedCount.isEmpty)
        #expect(breakdown.semesterDecidedFraction != nil)
        #expect((breakdown.semesterDecidedFraction ?? 1) < 0.2)
    }

    @Test("a syllabus-stated Quizzes count beats the pace projection")
    func statedCountBeatsProjection() {
        let canvas = canvasCategories()
        let breakdown = GradeEngine.compute(.init(
            courseUsesWeights: false, categories: canvas, now: now,
            categoryMap: map(canvas: canvas, quizzesExpectedCount: 5)
        ))
        let quizzes = breakdown.categories.first { $0.name == "Quizzes" }
        #expect(quizzes?.countPrediction?.source == .stated)
        #expect(quizzes?.countPrediction?.count == 5)
    }

    @Test("a student's own override count beats a syllabus-stated one")
    func overrideBeatsStatedCount() {
        let canvas = canvasCategories()
        let breakdown = GradeEngine.compute(.init(
            courseUsesWeights: false, categories: canvas, now: now,
            expectedCounts: ["map:quizzes": 20],
            categoryMap: map(canvas: canvas, quizzesExpectedCount: 5)
        ))
        let quizzes = breakdown.categories.first { $0.name == "Quizzes" }
        #expect(quizzes?.countPrediction?.source == .override)
        #expect(quizzes?.countPrediction?.count == 20)
    }

    @Test("mirroringCanvas over a points-mode course stays points mode and grades normally once something is scored")
    func mirroringCanvasStaysPointsMode() {
        let canvas = canvasCategories(problemSet1Score: 9)
        let mirrored = GradeCategoryMapBuilder.mirroringCanvas(canvas, courseUsesWeights: false)
        let breakdown = GradeEngine.compute(.init(
            courseUsesWeights: false, categories: canvas, now: now, categoryMap: mirrored
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
            courseUsesWeights: false, categories: canvas, now: now, categoryMap: map(canvas: canvas)
        ))

        #expect(breakdown.currentPercent != nil)
        #expect(breakdown.attendanceOnlyPercent == nil)
    }

    @Test("Quiz 2's placeholder never counts toward totalCount/possibleTotal")
    func placeholderNeverCountsTowardTotals() {
        let canvas = canvasCategories()
        let breakdown = GradeEngine.compute(.init(
            courseUsesWeights: false, categories: canvas, now: now, categoryMap: map(canvas: canvas)
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
            courseUsesWeights: false, categories: canvas, now: now, categoryMap: map(canvas: canvas)
        ))
        let imported = breakdown.categories.first { $0.name == "Imported Assignments" }
        #expect(imported?.isUnmapped == true)
        #expect(imported?.effectiveWeight == 0)
    }

    @Test("the Roll Call item shows up under Attendance/Participation, tracked as a moved item")
    func rollCallTrackedAsMoved() {
        let canvas = canvasCategories()
        let breakdown = GradeEngine.compute(.init(
            courseUsesWeights: false, categories: canvas, now: now, categoryMap: map(canvas: canvas)
        ))
        let attendance = breakdown.categories.first { $0.name == "Attendance/Participation" }
        #expect(attendance?.movedItemIDs == ["rollcall"])
        #expect(attendance?.earned == 100)
    }

    @Test("HomeWorks reports the Canvas groups folded into it")
    func homeworksReportsFoldedGroupNames() {
        let canvas = canvasCategories()
        let breakdown = GradeEngine.compute(.init(
            courseUsesWeights: false, categories: canvas, now: now, categoryMap: map(canvas: canvas)
        ))
        let hw = breakdown.categories.first { $0.name == "HomeWorks" }
        #expect(Set(hw?.canvasGroupNames ?? []) == ["Problem Sets", "Worksheets"])
    }
}
