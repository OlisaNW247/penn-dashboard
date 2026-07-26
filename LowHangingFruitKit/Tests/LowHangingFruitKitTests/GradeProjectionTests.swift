import Foundation
import Testing
@testable import LowHangingFruitKit

/// Coverage for docs/grades.md §13 — floor / pace / ceiling and the
/// "what would I need" inversion.
@Suite("Grade projection")
struct GradeProjectionTests {

    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func item(_ id: String, points: Double, score: Double? = nil,
                      excused: Bool = false, omit: Bool = false, dueAt: Date? = nil) -> GradeItem {
        GradeItem(id: id, name: id, pointsPossible: points, score: score,
                  scoreSource: score == nil ? nil : .canvas,
                  isExcused: excused, omitFromFinalGrade: omit, dueAt: dueAt)
    }

    private func project(weighted: Bool, categories: [GradeCategory],
                         manualWeights: [String: Double] = [:]) -> GradeProjection {
        let breakdown = GradeEngine.compute(.init(
            courseUsesWeights: weighted,
            categories: categories,
            manualWeights: manualWeights,
            now: now
        ))
        return GradeProjector.project(breakdown)
    }

    // MARK: - Points mode

    @Test("points mode: floor is earned over the course's whole point total")
    func pointsFloor() {
        // 90/100 scored, 100 more points still to come.
        let projection = project(weighted: false, categories: [
            GradeCategory(id: "c", name: "All", items: [
                item("a", points: 100, score: 90),
                item("b", points: 100),
            ]),
        ])

        #expect(abs(projection.floorPercent - 45) < 0.001)     // 90/200
        #expect(abs(projection.ceilingPercent - 95) < 0.001)   // 190/200
        #expect(abs(projection.openShare - 0.5) < 0.001)
        // Current grade is 90%, so pace = 45 + 50×0.9.
        #expect(abs((projection.pacePercent ?? 0) - 90) < 0.001)
    }

    @Test("everything graded means floor == ceiling and the course is decided")
    func fullyGraded() {
        let projection = project(weighted: false, categories: [
            GradeCategory(id: "c", name: "All", items: [
                item("a", points: 100, score: 88),
            ]),
        ])

        #expect(projection.isDecided)
        #expect(abs(projection.floorPercent - projection.ceilingPercent) < 0.001)
        #expect(projection.remainingItemCount == 0)
    }

    // MARK: - Weighted mode

    @Test("weighted mode: an ungraded category is entirely open")
    func weightedOpenCategory() {
        let projection = project(weighted: true, categories: [
            GradeCategory(id: "hw", name: "Homework", weight: 50, items: [
                item("a", points: 100, score: 100),
            ]),
            GradeCategory(id: "final", name: "Final", weight: 50, items: [
                item("b", points: 100),
            ]),
        ])

        // Half the grade banked at 100%, half untouched.
        #expect(abs(projection.floorPercent - 50) < 0.001)
        #expect(abs(projection.ceilingPercent - 100) < 0.001)
        #expect(abs(projection.openShare - 0.5) < 0.001)
    }

    @Test("weights that don't sum to 100 are renormalized, not taken literally")
    func renormalizedWeights() {
        // 30 + 30 = 60 total weight; each is really half the grade.
        let projection = project(weighted: true, categories: [
            GradeCategory(id: "a", name: "A", weight: 30, items: [item("x", points: 10, score: 10)]),
            GradeCategory(id: "b", name: "B", weight: 30, items: [item("y", points: 10)]),
        ])

        #expect(abs(projection.floorPercent - 50) < 0.001)
        #expect(abs(projection.ceilingPercent - 100) < 0.001)
    }

    @Test("zero-weight categories contribute to neither the floor nor the open share")
    func zeroWeightIgnored() {
        let projection = project(weighted: true, categories: [
            GradeCategory(id: "real", name: "Real", weight: 100, items: [
                item("a", points: 100, score: 80),
            ]),
            GradeCategory(id: "extra", name: "Extra", weight: 0, items: [
                item("b", points: 100),
            ]),
        ])

        #expect(projection.isDecided)
        #expect(abs(projection.floorPercent - 80) < 0.001)
        // The zero-weight category's unscored item isn't "remaining work" —
        // scoring it can't move the grade.
        #expect(projection.remainingItemCount == 0)
    }

    @Test("a category with no point-bearing work is treated as fully open, not as a divide by zero")
    func emptyCategoryIsOpen() {
        let projection = project(weighted: true, categories: [
            GradeCategory(id: "a", name: "Graded", weight: 50, items: [item("x", points: 100, score: 90)]),
            GradeCategory(id: "b", name: "Not set up yet", weight: 50, items: []),
        ])

        #expect(!projection.floorPercent.isNaN)
        #expect(abs(projection.floorPercent - 45) < 0.001)
        #expect(abs(projection.openShare - 0.5) < 0.001)
    }

    @Test("no scores at all yields no pace, and a zero floor")
    func nothingScored() {
        let projection = project(weighted: true, categories: [
            GradeCategory(id: "a", name: "A", weight: 100, items: [item("x", points: 100)]),
        ])

        #expect(projection.pacePercent == nil)
        #expect(abs(projection.floorPercent) < 0.001)
        #expect(abs(projection.ceilingPercent - 100) < 0.001)
    }

    @Test("dropped points still count as decided, matching how % decided is defined")
    func dropRulesDoNotReopenPoints() {
        // Two scored quizzes, lowest dropped, one still to come.
        let projection = project(weighted: true, categories: [
            GradeCategory(id: "q", name: "Quizzes", weight: 100, dropLowest: 1, items: [
                item("a", points: 10, score: 10),
                item("b", points: 10, score: 0),
                item("c", points: 10),
            ]),
        ])

        // 20 of 30 points are decided regardless of the drop, so a third of
        // the grade is still open.
        #expect(abs(projection.openShare - (1.0 / 3.0)) < 0.001)
    }

    // MARK: - Required average

    @Test("required average inverts the projection")
    func requiredAverage() {
        let projection = project(weighted: true, categories: [
            GradeCategory(id: "hw", name: "Homework", weight: 50, items: [item("a", points: 100, score: 80)]),
            GradeCategory(id: "final", name: "Final", weight: 50, items: [item("b", points: 100)]),
        ])

        // Banked 40 points of the final grade; need 50 more from the open 50.
        guard case let .need(percent) = projection.requiredAverage(for: 90) else {
            Issue.record("expected an achievable requirement")
            return
        }
        #expect(abs(percent - 100) < 0.001)
    }

    @Test("a target below the floor is already locked in")
    func alreadyReached() {
        let projection = project(weighted: true, categories: [
            GradeCategory(id: "a", name: "A", weight: 100, items: [
                item("x", points: 100, score: 95),
                item("y", points: 100),
            ]),
        ])

        // Half the points banked at 95% → floor is 47.5.
        #expect(projection.requiredAverage(for: 40) == .alreadyReached)
    }

    @Test("an unreachable target reports how far short 100% would land")
    func unreachable() {
        let projection = project(weighted: true, categories: [
            GradeCategory(id: "a", name: "A", weight: 80, items: [item("x", points: 100, score: 50)]),
            GradeCategory(id: "b", name: "B", weight: 20, items: [item("y", points: 100)]),
        ])

        // Floor 40, ceiling 60 — a 90 is impossible by 30 points.
        guard case let .unreachable(shortfall) = projection.requiredAverage(for: 90) else {
            Issue.record("expected an unreachable requirement")
            return
        }
        #expect(abs(abs(shortfall) - 30) < 0.001)
    }

    @Test("with nothing left to score, a missed target reports nothingLeft rather than a required average")
    func nothingLeft() {
        let projection = project(weighted: true, categories: [
            GradeCategory(id: "a", name: "A", weight: 100, items: [item("x", points: 100, score: 70)]),
        ])

        #expect(projection.requiredAverage(for: 90) == .nothingLeft)
    }

    @Test("excused work leaves the course entirely, so it isn't counted as open")
    func excusedIsNotOpen() {
        let projection = project(weighted: true, categories: [
            GradeCategory(id: "a", name: "A", weight: 100, items: [
                item("x", points: 100, score: 90),
                item("y", points: 100, excused: true),
            ]),
        ])

        #expect(projection.isDecided)
        #expect(abs(projection.floorPercent - 90) < 0.001)
    }

    @Test("pending (past-due, unscored) work is remaining but not upcoming")
    func pendingSplit() {
        let projection = project(weighted: true, categories: [
            GradeCategory(id: "a", name: "A", weight: 100, items: [
                item("x", points: 100, score: 90, dueAt: now.addingTimeInterval(-86_400 * 5)),
                item("y", points: 100, dueAt: now.addingTimeInterval(-86_400)),      // past due
                item("z", points: 100, dueAt: now.addingTimeInterval(86_400 * 5)),   // upcoming
            ]),
        ])

        #expect(projection.remainingItemCount == 2)
        #expect(projection.upcomingItemCount == 1)
    }
}
