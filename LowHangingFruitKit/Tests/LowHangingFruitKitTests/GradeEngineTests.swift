import Foundation
import Testing
@testable import LowHangingFruitKit

/// Exhaustive coverage of docs/grades.md §2–3 (the math + edge-case table),
/// plus the CP1-review decisions (past-due handling, differsFromCanvas
/// threshold, drop-suppression, manual weight precedence).
@Suite("Grade engine")
struct GradeEngineTests {

    // MARK: - Helpers

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
        weight: Double? = nil,
        dropLowest: Int = 0,
        dropHighest: Int = 0,
        neverDrop: Set<String> = [],
        items: [GradeItem]
    ) -> GradeCategory {
        GradeCategory(
            id: id, name: id, weight: weight,
            dropLowest: dropLowest, dropHighest: dropHighest,
            neverDropIDs: neverDrop, items: items
        )
    }

    private func approx(_ a: Double, _ b: Double, tolerance: Double = 0.0001) -> Bool {
        abs(a - b) < tolerance
    }

    private let past = Date(timeIntervalSince1970: 0)
    private let future = Date(timeIntervalSince1970: 4_000_000_000)
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    // MARK: - Empty / no-scores states

    @Test("empty course: weighted mode has no scores yet, 0% decided")
    func emptyCourseWeightedMode() {
        let result = GradeEngine.compute(.init(courseUsesWeights: true, categories: [], now: now))
        #expect(result.mode == .weighted)
        #expect(result.currentPercent == nil)
        #expect(result.decidedFraction == 0)
        #expect(result.pendingGradingCount == 0)
    }

    @Test("empty course: points mode has no scores yet, 0% decided")
    func emptyCoursePointsMode() {
        let result = GradeEngine.compute(.init(courseUsesWeights: false, categories: [], now: now))
        #expect(result.mode == .points)
        #expect(result.currentPercent == nil)
        #expect(result.decidedFraction == 0)
    }

    // MARK: - Excused / nil-score / omit

    @Test("all-excused category is excluded everywhere (current grade renormalizes it away)")
    func allExcusedCategoryExcluded() {
        let excusedCat = category("excused", weight: 60, items: [
            item("e1", points: 100, score: 0, excused: true),
            item("e2", points: 100, score: 100, excused: true),
        ])
        let realCat = category("real", weight: 40, items: [
            item("r1", points: 100, score: 80),
        ])
        let result = GradeEngine.compute(.init(courseUsesWeights: true, categories: [excusedCat, realCat], now: now))

        // Only "real" has scored work -> current grade is exactly its own percent (80%).
        #expect(result.currentPercent.map { approx($0, 80) } ?? false)
        let excusedResult = result.categories.first { $0.id == "excused" }!
        #expect(excusedResult.earned == 0)
        #expect(excusedResult.possibleScored == 0)
        #expect(excusedResult.possibleTotal == 0)
        #expect(excusedResult.scoredCount == 0)
    }

    @Test("score == nil is excluded from math regardless of submission state, but counted as pending when past due")
    func scoreNilExcludedButPendingWhenPastDue() {
        let cat = category("hw", weight: 100, items: [
            item("scored", points: 10, score: 8),
            item("submittedUngraded", points: 10, score: nil, dueAt: past),
        ])
        let result = GradeEngine.compute(.init(courseUsesWeights: true, categories: [cat], now: now))

        // Only the scored item counts toward the grade.
        #expect(result.currentPercent.map { approx($0, 80) } ?? false)
        let catResult = result.categories.first!
        #expect(catResult.possibleScored == 10) // not 20
        #expect(catResult.scoredCount == 1)
        // But it's surfaced as pending, not silently dropped or auto-zeroed.
        #expect(result.pendingGradingCount == 1)
    }

    @Test("future-due unscored item is excluded from the grade and NOT counted as pending")
    func futureDueUnscoredNotPending() {
        let cat = category("hw", weight: 100, items: [
            item("scored", points: 10, score: 8),
            item("notYetDue", points: 10, score: nil, dueAt: future),
            item("noDueDate", points: 10, score: nil, dueAt: nil),
        ])
        let result = GradeEngine.compute(.init(courseUsesWeights: true, categories: [cat], now: now))
        #expect(result.pendingGradingCount == 0)
    }

    @Test("omit_from_final_grade excludes the item entirely, even when scored")
    func omitFromFinalGradeExcludedEverywhere() {
        let cat = category("hw", weight: 100, items: [
            item("counts", points: 10, score: 8),
            item("omitted", points: 1000, score: 1000, omit: true),
        ])
        let result = GradeEngine.compute(.init(courseUsesWeights: true, categories: [cat], now: now))
        #expect(result.currentPercent.map { approx($0, 80) } ?? false)
        let catResult = result.categories.first!
        #expect(catResult.possibleTotal == 10) // omitted item never enters possibleTotal either
        #expect(catResult.totalCount == 1)
    }

    // MARK: - Extra credit / points_possible == 0

    @Test("extra credit adds to earned but never to a possible denominator, can push grade over 100%")
    func extraCreditPushesAboveHundred() {
        let cat = category("hw", weight: 100, items: [
            item("real", points: 100, score: 95),
            item("bonus", points: 0, score: 10), // EC: adds to earned only
        ])
        let result = GradeEngine.compute(.init(courseUsesWeights: false, categories: [cat], now: now))
        // (95 + 10) / 100 = 105%
        #expect(result.currentPercent.map { approx($0, 105) } ?? false)
    }

    @Test("pure extra-credit category (possible == 0) never divides by zero; category percent is nil")
    func pureExtraCreditCategoryNoDivideByZero() {
        let ecCat = category("ec", weight: 50, items: [
            item("bonus1", points: 0, score: 5),
            item("bonus2", points: 0, score: 3),
        ])
        let realCat = category("real", weight: 50, items: [
            item("r1", points: 100, score: 90),
        ])
        let result = GradeEngine.compute(.init(courseUsesWeights: true, categories: [ecCat, realCat], now: now))

        let ecResult = result.categories.first { $0.id == "ec" }!
        #expect(ecResult.percent == nil) // no possible points scored -> no ratio, not NaN
        // Current grade renormalizes over "real" only, since EC has possibleScored == 0.
        #expect(result.currentPercent.map { approx($0, 90) } ?? false)
        // % decided: EC's possibleTotal is also 0, so it contributes 0 but its
        // weight still divides the total (no divide-by-zero, no crash).
        #expect(result.decidedFraction.isFinite)
        #expect(approx(result.decidedFraction, 0.5)) // only "real" (weight 50) is fully decided
    }

    // MARK: - Drop lowest / highest

    @Test("drop-lowest is suppressed below 2 scored items: no drop, no NaN")
    func singleScoredItemDropLowestSuppressed() {
        let cat = category("hw", weight: 100, dropLowest: 1, items: [
            item("only", points: 10, score: 6),
        ])
        let result = GradeEngine.compute(.init(courseUsesWeights: true, categories: [cat], now: now))
        let catResult = result.categories.first!
        #expect(catResult.droppedItemIDs.isEmpty)
        #expect(catResult.earned == 6)
        #expect(catResult.possibleScored == 10)
        #expect(result.currentPercent.map { approx($0, 60) } ?? false)
    }

    @Test("drop-lowest removes the single worst ratio once >= 2 scored items exist")
    func dropLowestRemovesWorstItem() {
        let cat = category("hw", weight: 100, dropLowest: 1, items: [
            item("bad", points: 10, score: 2),   // 20%
            item("good", points: 10, score: 9),  // 90%
        ])
        let result = GradeEngine.compute(.init(courseUsesWeights: true, categories: [cat], now: now))
        let catResult = result.categories.first!
        #expect(catResult.droppedItemIDs == ["bad"])
        #expect(catResult.earned == 9)
        #expect(catResult.possibleScored == 10)
        // % decided ignores drops (stays monotonic with grading progress, not policy).
        #expect(approx(result.decidedFraction, 1.0))
    }

    @Test("never_drop protects a pinned item even when it has the lowest ratio")
    func neverDropProtectsPinnedItem() {
        let cat = category("hw", weight: 100, dropLowest: 1, neverDrop: ["pinnedWorst"], items: [
            item("pinnedWorst", points: 10, score: 1),  // 10%, would normally drop
            item("nextWorst", points: 10, score: 5),    // 50%
            item("best", points: 10, score: 9),         // 90%
        ])
        let result = GradeEngine.compute(.init(courseUsesWeights: true, categories: [cat], now: now))
        let catResult = result.categories.first!
        #expect(catResult.droppedItemIDs == ["nextWorst"])
        #expect(catResult.earned == 1 + 9)
        #expect(catResult.possibleScored == 20)
    }

    @Test("drop-lowest and drop-highest can both apply, always keeping at least one item")
    func dropLowestAndDropHighestTogether() {
        let cat = category("hw", weight: 100, dropLowest: 1, dropHighest: 1, items: [
            item("lowest", points: 10, score: 1),
            item("mid", points: 10, score: 5),
            item("highest", points: 10, score: 10),
        ])
        let result = GradeEngine.compute(.init(courseUsesWeights: true, categories: [cat], now: now))
        let catResult = result.categories.first!
        #expect(catResult.droppedItemIDs == ["lowest", "highest"])
        #expect(catResult.earned == 5)
        #expect(catResult.possibleScored == 10)
    }

    @Test("dropLowestOverrides takes precedence over the category's Canvas drop rule, suppression still applies regardless of source")
    func dropLowestOverrideAndSuppressionRegardlessOfSource() {
        // Canvas says no drop; manual override turns it on. Still suppressed at 1 scored item.
        let cat = category("hw", weight: 100, dropLowest: 0, items: [
            item("only", points: 10, score: 4),
        ])
        let result = GradeEngine.compute(.init(
            courseUsesWeights: true, categories: [cat],
            dropLowestOverrides: ["hw": 1], now: now
        ))
        let catResult = result.categories.first!
        #expect(catResult.droppedItemIDs.isEmpty) // still suppressed, no NaN
        #expect(catResult.earned == 4)
    }

    // MARK: - Zero-weight categories

    @Test("zero-weight category is excluded from both current grade and % decided")
    func zeroWeightCategoryFullyExcluded() {
        let zeroCat = category("bonus-cat", weight: 0, items: [
            item("z1", points: 100, score: 100),
        ])
        let realCat = category("real", weight: 100, items: [
            item("r1", points: 100, score: 50),
        ])
        let withZero = GradeEngine.compute(.init(courseUsesWeights: true, categories: [zeroCat, realCat], now: now))
        let withoutZero = GradeEngine.compute(.init(courseUsesWeights: true, categories: [realCat], now: now))

        #expect(withZero.currentPercent == withoutZero.currentPercent)
        #expect(approx(withZero.decidedFraction, withoutZero.decidedFraction))
        #expect(approx(withZero.currentPercent ?? -1, 50))
    }

    // MARK: - Renormalization

    @Test("weighted category with no scored items is excluded from current grade (renormalized) but still divides % decided")
    func categoryWithNoScoredItemsRenormalizes() {
        let untouched = category("untouched", weight: 20, items: [
            item("u1", points: 50, score: nil),
            item("u2", points: 50, score: nil),
        ])
        let hw = category("hw", weight: 40, items: [
            // 1 of 10 graded — used again below for the "4% not 40%" case.
            item("h1", points: 10, score: 10),
            item("h2", points: 10, score: nil), item("h3", points: 10, score: nil),
            item("h4", points: 10, score: nil), item("h5", points: 10, score: nil),
            item("h6", points: 10, score: nil), item("h7", points: 10, score: nil),
            item("h8", points: 10, score: nil), item("h9", points: 10, score: nil),
            item("h10", points: 10, score: nil),
        ])
        let exam = category("exam", weight: 40, items: [
            item("e1", points: 100, score: 90),
        ])
        let result = GradeEngine.compute(.init(courseUsesWeights: true, categories: [untouched, hw, exam], now: now))

        // Current grade renormalizes over hw (100%) and exam (90%) only, weight 40/40.
        #expect(result.currentPercent.map { approx($0, 95) } ?? false) // (40*100 + 40*90)/80

        // % decided: untouched contributes 0 but its weight (20) still divides the
        // total (20+40+40=100). hw contributes 0.4*(10/100)=0.04, exam contributes 0.4*1=0.4.
        // untouched contributes 0.2*(0/100)=0.
        #expect(approx(result.decidedFraction, 0.44))
    }

    @Test("% decided: 1 of 10 items graded in a 40%-weight category contributes 4%, not 40%")
    func partialCategoryContributesProportionally() {
        let hw = category("hw", weight: 40, items:
            [item("h1", points: 10, score: 10)] +
            (2...10).map { item("h\($0)", points: 10, score: nil) }
        )
        let exam = category("exam", weight: 60, items: [
            item("e1", points: 100, score: 90),
        ])
        let result = GradeEngine.compute(.init(courseUsesWeights: true, categories: [hw, exam], now: now))
        // 0.4*(10/100) + 0.6*(100/100) = 0.04 + 0.6 = 0.64 -- NOT 0.4 + 0.6 = 1.0
        #expect(approx(result.decidedFraction, 0.64))
        #expect(!approx(result.decidedFraction, 1.0))
    }

    @Test("weights that don't sum to 100 normalize by the actual participating sum")
    func weightsNotSummingTo100Normalize() {
        let a = category("a", weight: 30, items: [item("a1", points: 100, score: 60)])
        let b = category("b", weight: 30, items: [item("b1", points: 100, score: 90)])
        // "c" has no scored work at all -> excluded from current grade renormalization.
        let c = category("c", weight: 30, items: [item("c1", points: 100, score: nil)])
        let result = GradeEngine.compute(.init(courseUsesWeights: true, categories: [a, b, c], now: now))
        // Renormalized over a (30) and b (30) only: (30*60 + 30*90)/60 = 75.
        #expect(result.currentPercent.map { approx($0, 75) } ?? false)
    }

    // MARK: - Manual weight overrides

    @Test("manual weight override beats a garbage Canvas weight")
    func manualWeightBeatsGarbageCanvasWeight() {
        // courseUsesWeights is false -> Canvas's group_weight (999, garbage) must never be read.
        let cat = category("hw", weight: 999, items: [item("h1", points: 10, score: 5)])
        let result = GradeEngine.compute(.init(
            courseUsesWeights: false, categories: [cat],
            manualWeights: ["hw": 40], now: now
        ))
        let catResult = result.categories.first!
        #expect(catResult.effectiveWeight == 40)
        #expect(catResult.weightSource == .manual)
    }

    @Test("manual weights on a points-mode course switch the whole course to weighted mode")
    func manualWeightsSwitchModeToWeighted() {
        let cat = category("hw", items: [item("h1", points: 10, score: 5)])
        let result = GradeEngine.compute(.init(
            courseUsesWeights: false, categories: [cat],
            manualWeights: ["hw": 100], now: now
        ))
        #expect(result.mode == .weighted)
    }

    // MARK: - differsFromCanvas

    @Test("differsFromCanvas stays silent at 0.9 percentage points (below the 1.0pp threshold)")
    func differsFromCanvasSilentBelowThreshold() {
        #expect(!GradeEngine.differsFromCanvas(computed: 90.0, canvasScore: 89.1))
    }

    @Test("differsFromCanvas flags at 1.1 percentage points (above the 1.0pp threshold)")
    func differsFromCanvasFlaggedAboveThreshold() {
        #expect(GradeEngine.differsFromCanvas(computed: 90.0, canvasScore: 88.9))
    }

    @Test("differsFromCanvas never fires when Canvas's score is nil (hidden totals)")
    func differsFromCanvasNilCanvasScoreNeverFlags() {
        #expect(!GradeEngine.differsFromCanvas(computed: 90.0, canvasScore: nil))
    }

    // MARK: - Points mode

    @Test("points mode: current grade is sum(earned)/sum(possible) over scored items only")
    func pointsModeCurrentGrade() {
        let cats = [
            category("a", items: [item("a1", points: 100, score: 80), item("a2", points: 100, score: nil)]),
            category("b", items: [item("b1", points: 50, score: 45)]),
        ]
        let result = GradeEngine.compute(.init(courseUsesWeights: false, categories: cats, now: now))
        // (80+45)/(100+50) = 125/150
        #expect(result.currentPercent.map { approx($0, 125.0 / 150.0 * 100) } ?? false)
    }

    @Test("points mode: % decided is sum(possible scored)/sum(possible all)")
    func pointsModeDecidedFraction() {
        let cats = [
            category("a", items: [item("a1", points: 100, score: 80), item("a2", points: 100, score: nil)]),
            category("b", items: [item("b1", points: 50, score: 45)]),
        ]
        let result = GradeEngine.compute(.init(courseUsesWeights: false, categories: cats, now: now))
        // scored possible = 100 + 50 = 150; total possible = 100+100+50 = 250
        #expect(approx(result.decidedFraction, 150.0 / 250.0))
    }

    @Test("points mode ignores category weights entirely (implicit single bucket)")
    func pointsModeIgnoresWeights() {
        let cats = [
            category("a", weight: 9999, items: [item("a1", points: 100, score: 100)]),
            category("b", weight: -50, items: [item("b1", points: 100, score: 0)]),
        ]
        let result = GradeEngine.compute(.init(courseUsesWeights: false, categories: cats, now: now))
        #expect(result.currentPercent.map { approx($0, 50) } ?? false)
    }

    // MARK: - Pending count aggregation

    @Test("pending grading count aggregates past-due unscored items across categories")
    func pendingCountAggregatesAcrossCategories() {
        let a = category("a", weight: 50, items: [
            item("a1", points: 10, score: 8),
            item("a2", points: 10, score: nil, dueAt: past),
        ])
        let b = category("b", weight: 50, items: [
            item("b1", points: 10, score: nil, dueAt: past),
            item("b2", points: 10, score: nil, dueAt: past),
        ])
        let result = GradeEngine.compute(.init(courseUsesWeights: true, categories: [a, b], now: now))
        #expect(result.pendingGradingCount == 3)
    }
}
