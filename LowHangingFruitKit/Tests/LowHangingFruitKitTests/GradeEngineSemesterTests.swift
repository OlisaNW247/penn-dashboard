import Foundation
import Testing
@testable import LowHangingFruitKit

/// Coverage for the semester-decided estimate (`GradeEngine.Input.expectedCounts`
/// / `GradeBreakdown.semesterDecidedFraction`), item overrides
/// (`Input.itemOverrides` / `GradeItemOverride`), `Input.modeOverride`, and the
/// new `CategoryResult`/`GradeBreakdown` fields (`participates`,
/// `contributionPercent`, `leftOutCategoryIDs`, `participatingWeightSum`) added
/// on top of the original `GradeEngineTests` suite. Kept as its own file/suite
/// (rather than appended to `GradeEngineTests`) so this work can't accidentally
/// corrupt the existing, already-verified test file.
@Suite("Grade engine — semester decided, overrides, mode override")
struct GradeEngineSemesterTests {

    // MARK: - Helpers (mirrors GradeEngineTests' private helpers)

    private func item(
        _ id: String,
        points: Double,
        score: Double? = nil,
        excused: Bool = false,
        omit: Bool = false,
        dueAt: Date? = nil
    ) -> GradeItem {
        GradeItem(
            id: id,
            name: id,
            pointsPossible: points,
            score: score,
            scoreSource: score == nil ? nil : .canvas,
            isExcused: excused,
            omitFromFinalGrade: omit,
            dueAt: dueAt
        )
    }

    private func category(
        _ id: String,
        name: String? = nil,
        weight: Double? = nil,
        dropLowest: Int = 0,
        dropHighest: Int = 0,
        neverDrop: Set<String> = [],
        items: [GradeItem]
    ) -> GradeCategory {
        GradeCategory(
            id: id, name: name ?? id, weight: weight,
            dropLowest: dropLowest, dropHighest: dropHighest,
            neverDropIDs: neverDrop, items: items
        )
    }

    private func approx(_ a: Double, _ b: Double, tolerance: Double = 0.0001) -> Bool {
        abs(a - b) < tolerance
    }

    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    // MARK: - Semester decided fraction (weighted)

    @Test("semester decided: 2 of 3 posted graded, 12 expected -> category and top-level fraction is 2/12")
    func semesterDecidedWithExpectedCount() {
        let lab = category("lab", weight: 60, items: [
            item("l1", points: 10, score: 8),
            item("l2", points: 10, score: 9),
            item("l3", points: 10, score: nil),
        ])
        let result = GradeEngine.compute(.init(
            courseUsesWeights: true, categories: [lab], now: now,
            expectedCounts: ["lab": 12]
        ))
        let labResult = result.categories.first!
        #expect(labResult.expectedCount == 12)
        #expect(labResult.semesterDecidedFraction.map { approx($0, 2.0 / 12.0) } ?? false)
        // Only one non-zero-weight category, so the top-level figure equals it.
        #expect(result.semesterDecidedFraction.map { approx($0, 2.0 / 12.0) } ?? false)
    }

    @Test("an expected count below what's already posted is ignored -- expected possible never drops below posted")
    func expectedCountBelowPostedUsesPosted() {
        let hw = category("hw", weight: 100, items: [
            item("h1", points: 10, score: 10),
            item("h2", points: 10, score: 10),
            item("h3", points: 10, score: nil),
            item("h4", points: 10, score: nil),
            item("h5", points: 10, score: nil),
        ])
        let result = GradeEngine.compute(.init(
            courseUsesWeights: true, categories: [hw], now: now,
            expectedCounts: ["hw": 3] // fewer than the 5 already posted
        ))
        let hwResult = result.categories.first!
        // expectedPossible = avg(10) * max(3, 5) = 50 == possibleTotal, so the
        // semester fraction collapses to the ordinary posted-only fraction.
        #expect(hwResult.semesterDecidedFraction.map { approx($0, 20.0 / 50.0) } ?? false)
        #expect(hwResult.semesterDecidedFraction.map { approx($0, hwResult.possibleScoredRaw / hwResult.possibleTotal) } ?? false)
    }

    // `GradeCountPredictor` means a category with no stated/override count and
    // no due-date term to project from no longer reads as "unknown" -- it
    // falls back to exactly the LISTED count (what's already posted), which
    // makes its `semesterDecidedFraction` collapse to precisely the
    // posted-only ratio. This replaces the old test of this name, whose
    // premise ("missing count -> nil") the predictor exists specifically to
    // retire; see also `GradeCountPredictorTests` for the predictor's own
    // unit coverage of exactly this fallback rule.
    @Test("no term and no stated/override count: semesterDecidedFraction falls back to exactly the posted-only ratio, never nil")
    func noTermFallsBackToPostedOnlyRatio() {
        let hw = category("hw", weight: 100, items: [
            item("h1", points: 10, score: 10),
            item("h2", points: 10, score: 10),
            item("h3", points: 10, score: nil),
            item("h4", points: 10, score: nil),
            item("h5", points: 10, score: nil),
        ])
        // No item carries a `dueAt`, so `GradeCountPredictor.term(for:)` has
        // nothing to anchor a term to -- this exercises the nil-term branch
        // specifically, not just "no stated count."
        let result = GradeEngine.compute(.init(courseUsesWeights: true, categories: [hw], now: now))
        #expect(result.term == nil)
        #expect(result.semesterDecidedFraction != nil)
        #expect(result.semesterDecidedFraction.map { approx($0, 20.0 / 50.0) } ?? false)
        #expect(approx(result.decidedFraction, 20.0 / 50.0)) // the two now agree exactly, with no term to diverge from
        #expect(result.categoriesMissingExpectedCount.isEmpty)
    }

    @Test("an attendance category's semesterDecidedFraction is decided by elapsed time, not by how many items are posted")
    func attendanceCategoryDecidedByTime() {
        let start = Date(timeIntervalSince1970: 1_000_000_000)
        let laterNow = start.addingTimeInterval(7 * 24 * 60 * 60) // one week into a 14-week term
        // A due date on some OTHER category anchors the term; the attendance
        // category itself carries a single scored Roll Call item with no due
        // date of its own, which is the ordinary case (Canvas's attendance
        // tool doesn't stamp a due date on every row it creates).
        let lecture = category("lecture", weight: 80, items: [
            item("l1", points: 100, score: nil, dueAt: start),
        ])
        let attendance = category("attendance", name: "Attendance", weight: 20, items: [
            item("a1", points: 10, score: 10),
        ])
        let result = GradeEngine.compute(.init(
            courseUsesWeights: true, categories: [lecture, attendance], now: laterNow
        ))
        let attendanceResult = result.categories.first { $0.name == "Attendance" }
        #expect(attendanceResult?.isAttendance == true)
        // One week of a 14-week term has elapsed.
        #expect(attendanceResult?.semesterDecidedFraction.map { approx($0, 1.0 / 14.0, tolerance: 0.01) } ?? false)
    }

    @Test("GradeBreakdown.term is populated once any item carries a due date, and nil when none do")
    func termPopulatedFromDueDates() {
        let start = Date(timeIntervalSince1970: 1_000_000_000)
        let dated = category("dated", items: [item("d1", points: 10, score: nil, dueAt: start)])
        let withTerm = GradeEngine.compute(.init(courseUsesWeights: false, categories: [dated], now: now))
        #expect(withTerm.term?.start == start)

        let undated = category("undated", items: [item("u1", points: 10, score: nil)])
        let withoutTerm = GradeEngine.compute(.init(courseUsesWeights: false, categories: [undated], now: now))
        #expect(withoutTerm.term == nil)
    }

    // MARK: - Semester decided fraction (points)

    @Test("points mode: semester decided sums raw scored/expected points across categories before dividing")
    func pointsModeSemesterDecided() {
        let a = category("a", items: [
            item("a1", points: 10, score: 8),
            item("a2", points: 10, score: nil),
        ])
        let b = category("b", items: [
            item("b1", points: 20, score: 15),
        ])
        let result = GradeEngine.compute(.init(
            courseUsesWeights: false, categories: [a, b], now: now,
            expectedCounts: ["a": 4, "b": 2]
        ))
        #expect(result.mode == .points)
        // a: avg 10 * max(4,2)=4 -> expectedPossible 40; raw scored 10.
        // b: avg 20 * max(2,1)=2 -> expectedPossible 40; raw scored 20.
        // (10+20) / (40+40) = 30/80.
        #expect(result.semesterDecidedFraction.map { approx($0, 30.0 / 80.0) } ?? false)
    }

    // MARK: - No-grade-without-decided

    @Test("a scored zero-point item with nothing else yields no percent and 0% decided, not 100%/0%")
    func scoredZeroPointItemAloneYieldsNoPercent() {
        let ec = category("ec", weight: 100, items: [
            item("bonus", points: 0, score: 5),
        ])
        let result = GradeEngine.compute(.init(courseUsesWeights: true, categories: [ec], now: now))
        #expect(result.currentPercent == nil)
        #expect(result.decidedFraction == 0)
    }

    // MARK: - Item overrides

    @Test("item override replaces Canvas's score for the math and is tracked in overriddenItemIDs")
    func itemOverrideChangesScoreAndTracksID() {
        let hw = category("hw", weight: 100, items: [
            item("h1", points: 10, score: 6), // Canvas says 6/10
        ])
        let result = GradeEngine.compute(.init(
            courseUsesWeights: true, categories: [hw], now: now,
            itemOverrides: ["h1": GradeItemOverride(score: 9)]
        ))
        let hwResult = result.categories.first!
        #expect(hwResult.earned == 9) // overridden value used, not Canvas's 6
        #expect(hwResult.overriddenItemIDs == ["h1"])
        #expect(result.currentPercent.map { approx($0, 90) } ?? false)
    }

    @Test("excluded item override removes it from the math entirely, like omit_from_final_grade")
    func excludedItemOverrideRemovesFromMath() {
        let withExclusion = category("hw", weight: 100, items: [
            item("h1", points: 10, score: 8),
            item("h2", points: 100, score: 100),
        ])
        let withExclusionResult = GradeEngine.compute(.init(
            courseUsesWeights: true, categories: [withExclusion], now: now,
            itemOverrides: ["h2": GradeItemOverride(isExcluded: true)]
        ))
        let baseline = category("hw", weight: 100, items: [
            item("h1", points: 10, score: 8),
        ])
        let baselineResult = GradeEngine.compute(.init(courseUsesWeights: true, categories: [baseline], now: now))

        let excludedCat = withExclusionResult.categories.first!
        let baselineCat = baselineResult.categories.first!
        #expect(excludedCat.excludedItemIDs == ["h2"])
        #expect(excludedCat.earned == baselineCat.earned)
        #expect(excludedCat.possibleScored == baselineCat.possibleScored)
        #expect(excludedCat.possibleTotal == baselineCat.possibleTotal)
        #expect(excludedCat.totalCount == baselineCat.totalCount)
        #expect(excludedCat.scoredCount == baselineCat.scoredCount)
    }

    // MARK: - Mode override

    @Test("modeOverride forces points mode on an otherwise-weighted course, and records modeSource as manual")
    func modeOverrideForcesPointsMode() {
        let hw = category("hw", weight: 40, items: [item("h1", points: 10, score: 8)])
        let exam = category("exam", weight: 60, items: [item("e1", points: 100, score: 90)])
        let result = GradeEngine.compute(.init(
            courseUsesWeights: true, categories: [hw, exam], now: now,
            modeOverride: .points
        ))
        #expect(result.mode == .points)
        #expect(result.modeSource == .manual)
        // Points mode: (8+90)/(10+100).
        #expect(result.currentPercent.map { approx($0, 98.0 / 110.0 * 100) } ?? false)
    }

    // MARK: - leftOutCategoryIDs / participatingWeightSum

    @Test("leftOutCategoryIDs lists weighted categories with real weight but no scored work, in input order; participatingWeightSum sums only the ones that do")
    func leftOutCategoriesAndParticipatingWeightSum() {
        let untouched = category("untouched", weight: 20, items: [item("u1", points: 50, score: nil)])
        let hw = category("hw", weight: 30, items: [item("h1", points: 10, score: 8)])
        let exam = category("exam", weight: 50, items: [item("e1", points: 100, score: nil)])
        let result = GradeEngine.compute(.init(courseUsesWeights: true, categories: [untouched, hw, exam], now: now))
        #expect(result.leftOutCategoryIDs == ["untouched", "exam"])
        #expect(result.participatingWeightSum.map { approx($0, 30) } ?? false)
    }

    // MARK: - contributionPercent

    @Test("contributionPercent across participating categories sums back to currentPercent in weighted mode")
    func contributionPercentSumsToCurrentPercent() {
        let hw = category("hw", weight: 40, items: [item("h1", points: 10, score: 7)])
        let exam = category("exam", weight: 60, items: [item("e1", points: 100, score: 88)])
        let untouched = category("untouched", weight: 20, items: [item("u1", points: 50, score: nil)])
        let result = GradeEngine.compute(.init(courseUsesWeights: true, categories: [hw, exam, untouched], now: now))

        let totalContribution = result.categories.compactMap(\.contributionPercent).reduce(0, +)
        #expect(result.currentPercent != nil)
        #expect(abs(totalContribution - (result.currentPercent ?? 0)) < 0.01)
        // untouched never participated, so it contributes nothing and is left out.
        #expect(result.categories.first { $0.id == "untouched" }?.contributionPercent == nil)
        #expect(result.leftOutCategoryIDs == ["untouched"])
    }
}
