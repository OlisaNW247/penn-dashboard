import Foundation
import Testing
@testable import LowHangingFruitKit

/// Coverage for docs/grades.md §11 — the grade-over-time reconstruction.
@Suite("Grade trajectory")
struct GradeTrajectoryTests {

    // MARK: - Helpers

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func day(_ n: Int) -> Date {
        now.addingTimeInterval(TimeInterval(-86_400 * n))
    }

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

    private func input(
        weighted: Bool = false,
        categories: [GradeCategory]
    ) -> GradeEngine.Input {
        GradeEngine.Input(courseUsesWeights: weighted, categories: categories, now: now)
    }

    // MARK: - Shape

    @Test("One point per scored due date, plus the current grade at now")
    func pointsPerDueDate() {
        let cats = [GradeCategory(id: "c", name: "HW", items: [
            item("a", points: 10, score: 8, dueAt: day(20)),
            item("b", points: 10, score: 10, dueAt: day(10)),
            item("c", points: 10, score: 6, dueAt: day(5)),
        ])]
        let points = GradeEngine.trajectory(input(categories: cats))

        #expect(points.count == 4)
        #expect(points.map(\.date) == [day(20), day(10), day(5), now])
        #expect(points[0].percent == 80)            // 8/10
        #expect(points[1].percent == 90)            // 18/20
        #expect(points[2].percent == 80)            // 24/30
        #expect(points[3].percent == 80)            // unmasked == current
    }

    @Test("Endpoint always equals the engine's current grade")
    func endpointMatchesCompute() {
        let cats = [GradeCategory(id: "c", name: "HW", items: [
            item("a", points: 50, score: 41, dueAt: day(9)),
            item("b", points: 25, score: 25, dueAt: day(2)),
        ])]
        let engineInput = input(categories: cats)
        let points = GradeEngine.trajectory(engineInput)

        #expect(points.last?.percent == GradeEngine.compute(engineInput).currentPercent)
        #expect(points.last?.date == now)
    }

    @Test("No scored work yields no trajectory")
    func emptyWhenNothingScored() {
        let cats = [GradeCategory(id: "c", name: "HW", items: [
            item("a", points: 10, dueAt: day(5)),
        ])]
        #expect(GradeEngine.trajectory(input(categories: cats)).isEmpty)
    }

    // MARK: - Placement rules

    @Test("Undated scored items count from the first point onward")
    func undatedItemsAlwaysCount() {
        let cats = [GradeCategory(id: "c", name: "HW", items: [
            item("dated", points: 10, score: 10, dueAt: day(8)),
            item("undated", points: 10, score: 5),
        ])]
        let points = GradeEngine.trajectory(input(categories: cats))

        // First (and only dated) cutoff already includes the undated 5/10.
        #expect(points.first?.percent == 75)
    }

    @Test("A score due in the future only appears in the final point")
    func futureDueScoreOnlyAtEnd() {
        let cats = [GradeCategory(id: "c", name: "HW", items: [
            item("past", points: 10, score: 10, dueAt: day(6)),
            item("early", points: 10, score: 6, dueAt: now.addingTimeInterval(86_400)),
        ])]
        let points = GradeEngine.trajectory(input(categories: cats))

        #expect(points.count == 2)
        #expect(points[0].percent == 100)   // early score masked in the past
        #expect(points[1].percent == 80)    // 16/20 today
    }

    @Test("Excused and omitted items never create cutoffs")
    func excusedAndOmittedIgnored() {
        let cats = [GradeCategory(id: "c", name: "HW", items: [
            item("real", points: 10, score: 9, dueAt: day(4)),
            item("exc", points: 10, score: 2, excused: true, dueAt: day(12)),
            item("omit", points: 10, score: 1, omit: true, dueAt: day(11)),
        ])]
        let points = GradeEngine.trajectory(input(categories: cats))

        #expect(points.map(\.date) == [day(4), now])
        #expect(points.allSatisfy { $0.percent == 90 })
    }

    // MARK: - Engine rules replay historically

    @Test("Drop-lowest engages mid-trajectory once two items are scored")
    func dropLowestReplaysHistorically() {
        let cats = [GradeCategory(id: "c", name: "Quizzes", dropLowest: 1, items: [
            item("q1", points: 10, score: 5, dueAt: day(10)),
            item("q2", points: 10, score: 10, dueAt: day(3)),
        ])]
        let points = GradeEngine.trajectory(input(categories: cats))

        // At q1's cutoff only one item is scored, so the drop is suppressed
        // (§3); once q2 lands, drop-lowest removes q1.
        #expect(points[0].percent == 50)
        #expect(points[1].percent == 100)
        #expect(points[2].percent == 100)
    }

    @Test("Weighted mode renormalizes at every point")
    func weightedRenormalizesPerPoint() {
        let cats = [
            GradeCategory(id: "hw", name: "HW", weight: 40, items: [
                item("h1", points: 10, score: 9, dueAt: day(14)),
            ]),
            GradeCategory(id: "ex", name: "Exams", weight: 60, items: [
                item("e1", points: 100, score: 70, dueAt: day(2)),
            ]),
        ]
        let points = GradeEngine.trajectory(input(weighted: true, categories: cats))

        #expect(points.count == 3)
        // Only HW scored: renormalized to 100% HW.
        #expect(points[0].percent == 90)
        // Both scored: 0.4·90 + 0.6·70 = 78.
        #expect(abs(points[1].percent - 78) < 0.0001)
        #expect(abs(points[2].percent - 78) < 0.0001)
    }
}
