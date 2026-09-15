import Foundation
import Testing
@testable import LowHangingFruitKit

/// Coverage for `GradeCountPredictor` — the "every category gets SOME
/// predicted whole-semester item count" replacement for the old "no syllabus
/// statement means unknown" rule (see `GradeEngine`'s use of it in `tally`).
/// Each `Prediction.Source` gets its own precedence test, then the pace
/// projection's arithmetic, the flooring rule ("never below what's listed,
/// never below 1"), and `Term`'s own helpers.
@Suite("Grade count predictor")
struct GradeCountPredictorTests {

    private let week: TimeInterval = 7 * 24 * 60 * 60

    private func item(_ id: String, dueAt: Date? = nil) -> GradeItem {
        GradeItem(id: id, name: id, pointsPossible: 10, dueAt: dueAt)
    }

    /// A calendar date pinned to UTC, for building the exact due dates from
    /// the CIS 4500 real-phone evidence without any local-timezone drift.
    private func date(_ year: Int, _ month: Int, _ day: Int) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        return calendar.date(from: components)!
    }

    // MARK: - Source precedence

    @Test("an override wins over a stated count, a name implication, and any pace projection")
    func overrideWinsOverEverything() {
        let start = Date(timeIntervalSince1970: 0)
        let now = start.addingTimeInterval(2 * week)
        let term = GradeCountPredictor.Term(start: start, weeks: 14)
        let prediction = GradeCountPredictor.predict(
            categoryName: "Final", // would imply 1 on its own
            items: [item("a", dueAt: start), item("b", dueAt: start)],
            overrideCount: 9,
            statedCount: 3,
            term: term,
            now: now
        )
        #expect(prediction.count == 9)
        #expect(prediction.source == .override)
    }

    @Test("a syllabus-stated count wins over a name implication and a pace projection when there's no override")
    func statedWinsOverImpliedAndProjected() {
        let start = Date(timeIntervalSince1970: 0)
        let now = start.addingTimeInterval(2 * week)
        let term = GradeCountPredictor.Term(start: start, weeks: 14)
        let prediction = GradeCountPredictor.predict(
            categoryName: "Final",
            items: [item("a", dueAt: start)],
            overrideCount: nil,
            statedCount: 5,
            term: term,
            now: now
        )
        #expect(prediction.count == 5)
        #expect(prediction.source == .stated)
    }

    @Test("a singular exam-like name implies exactly one item, ahead of a pace projection")
    func impliedByNameWinsOverProjection() {
        let start = Date(timeIntervalSince1970: 0)
        let now = start.addingTimeInterval(10 * week) // plenty of pace to project from
        let term = GradeCountPredictor.Term(start: start, weeks: 14)
        let prediction = GradeCountPredictor.predict(
            categoryName: "Midterm 2",
            items: [],
            overrideCount: nil,
            statedCount: nil,
            term: term,
            now: now
        )
        #expect(prediction.count == 1)
        #expect(prediction.source == .impliedByName)
    }

    // MARK: - Fallback to listed

    @Test("no term at all: falls back to the listed count, never a projection built on no information")
    func nilTermFallsBackToListed() {
        let prediction = GradeCountPredictor.predict(
            categoryName: "Quizzes",
            items: [item("q1"), item("q2"), item("q3")],
            overrideCount: nil,
            statedCount: nil,
            term: nil,
            now: Date(timeIntervalSince1970: 0)
        )
        #expect(prediction.count == 3)
        #expect(prediction.source == .listed)
    }

    @Test("under a week into the term: falls back to listed rather than dividing by a near-zero elapsed time")
    func lessThanAWeekElapsedFallsBackToListed() {
        let start = Date(timeIntervalSince1970: 0)
        let now = start.addingTimeInterval(3 * 24 * 60 * 60) // 3 days
        let term = GradeCountPredictor.Term(start: start, weeks: 14)
        let prediction = GradeCountPredictor.predict(
            categoryName: "Quizzes",
            items: [item("q1", dueAt: start)],
            overrideCount: nil,
            statedCount: nil,
            term: term,
            now: now
        )
        #expect(prediction.count == 1)
        #expect(prediction.source == .listed)
    }

    // MARK: - Pace projection arithmetic

    @Test("2 of an eventual 14-week term's items due in the first 2 weeks projects to 14 for the whole semester")
    func projectionArithmetic() {
        let start = Date(timeIntervalSince1970: 0)
        let now = start.addingTimeInterval(2 * week)
        let term = GradeCountPredictor.Term(start: start, weeks: 14)
        let prediction = GradeCountPredictor.predict(
            categoryName: "Quizzes",
            items: [item("q1", dueAt: start), item("q2", dueAt: start.addingTimeInterval(week))],
            overrideCount: nil,
            statedCount: nil,
            term: term,
            now: now
        )
        #expect(prediction.count == 14)
        #expect(prediction.source == .projected)
    }

    @Test("a projection that comes back no bigger than what's already listed reports as listed, not projected")
    func projectionNoBiggerThanListedReportsAsListed() {
        let start = Date(timeIntervalSince1970: 0)
        let now = start.addingTimeInterval(13 * week) // almost the whole term has passed
        let term = GradeCountPredictor.Term(start: start, weeks: 14)
        // 3 items total, only 1 due so far (the other two are due AFTER
        // `now`) -- pace projects to about 1, well under the 3 already
        // listed.
        let prediction = GradeCountPredictor.predict(
            categoryName: "Problem Sets",
            items: [
                item("p1", dueAt: start),
                item("p2", dueAt: start.addingTimeInterval(13.5 * week)),
                item("p3", dueAt: start.addingTimeInterval(13.5 * week)),
            ],
            overrideCount: nil,
            statedCount: nil,
            term: term,
            now: now
        )
        #expect(prediction.count == 3)
        #expect(prediction.source == .listed)
    }

    @Test("items with no due date at all still count toward 'due so far' in the pace projection")
    func undatedItemsCountAsDueSoFar() {
        let start = Date(timeIntervalSince1970: 0)
        let now = start.addingTimeInterval(2 * week)
        let term = GradeCountPredictor.Term(start: start, weeks: 14)
        // One undated item (counts as due so far) plus one item due well in
        // the future (does not) -- if the undated item were NOT counted,
        // dueSoFar would be 0 and the projection would collapse to "listed".
        let prediction = GradeCountPredictor.predict(
            categoryName: "Worksheets",
            items: [item("w1", dueAt: nil), item("w2", dueAt: start.addingTimeInterval(10 * week))],
            overrideCount: nil,
            statedCount: nil,
            term: term,
            now: now
        )
        #expect(prediction.count == 7) // pace 1/2 weeks * 14 weeks = 7
        #expect(prediction.source == .projected)
    }

    // MARK: - Flooring

    @Test("an override smaller than what's already listed is raised to the listed count, never lowered")
    func overrideNeverDropsBelowListed() {
        let prediction = GradeCountPredictor.predict(
            categoryName: "HomeWorks",
            items: [item("h1"), item("h2"), item("h3"), item("h4"), item("h5")],
            overrideCount: 2,
            statedCount: nil,
            term: nil,
            now: Date(timeIntervalSince1970: 0)
        )
        #expect(prediction.count == 5)
        #expect(prediction.source == .override)
    }

    @Test("a stated count smaller than what's already listed is raised the same way")
    func statedNeverDropsBelowListed() {
        let prediction = GradeCountPredictor.predict(
            categoryName: "HomeWorks",
            items: [item("h1"), item("h2"), item("h3")],
            overrideCount: nil,
            statedCount: 1,
            term: nil,
            now: Date(timeIntervalSince1970: 0)
        )
        #expect(prediction.count == 3)
        #expect(prediction.source == .stated)
    }

    @Test("an empty category with no statement and no term never predicts zero")
    func emptyCategoryNeverPredictsZero() {
        let prediction = GradeCountPredictor.predict(
            categoryName: "Exams",
            items: [],
            overrideCount: nil,
            statedCount: nil,
            term: nil,
            now: Date(timeIntervalSince1970: 0)
        )
        #expect(prediction.count == 1)
        #expect(prediction.source == .listed)
    }

    // MARK: - Term

    @Test("term(for:) anchors on the earliest due date across every category, not just the first category given")
    func termPicksEarliestDueDateAcrossCategories() {
        let earliest = Date(timeIntervalSince1970: 1_000_000)
        let later = earliest.addingTimeInterval(5 * week)
        let a = GradeCategory(id: "a", name: "a", items: [item("a1", dueAt: later)])
        let b = GradeCategory(id: "b", name: "b", items: [item("b1", dueAt: earliest), item("b2", dueAt: later)])
        let term = GradeCountPredictor.term(for: [a, b])
        #expect(term?.start == earliest)
    }

    @Test("term(for:) is nil when nothing in any category has a due date")
    func termNilWithNoDueDates() {
        let a = GradeCategory(id: "a", name: "a", items: [item("a1", dueAt: nil)])
        let term = GradeCountPredictor.term(for: [a])
        #expect(term == nil)
    }

    @Test("term(for:) anchors on the current cluster, not a prior year's leftover items, on a recycled Canvas site")
    func recycledSiteGapAnchorsOnCurrentCluster() {
        // The CIS 4500 real-phone shape from 2026-09-15: three 2025 items
        // left over on a reused Canvas site, then the real Fall 2026 work
        // starting 2026-09-11. Before this fix, `term(for:)` anchored on
        // 2025-10-14 -- 48 weeks before "now" -- and `elapsedWeeks(at:)`'s
        // clamp to `0...weeks` saturated at the full 14, which is what
        // actually produced the "week 14 of 14" card on a course that had
        // barely begun.
        let leftoverA = item("met-instructor", dueAt: date(2025, 10, 14))
        let leftoverB = item("class-participation", dueAt: date(2025, 12, 9))
        let leftoverC = item("ed-participation", dueAt: date(2025, 12, 9))
        let currentA = item("course-policy-exercise", dueAt: date(2026, 9, 11))
        let currentB = item("hw1", dueAt: date(2026, 9, 22))
        let currentC = item("final", dueAt: date(2026, 12, 12))
        let categories = [
            GradeCategory(id: "participation", name: "Participation", items: [leftoverA, leftoverB, leftoverC]),
            GradeCategory(id: "assignments", name: "Assignments", items: [currentA, currentB, currentC]),
        ]

        let term = GradeCountPredictor.term(for: categories)

        #expect(term?.start == date(2026, 9, 11))
        // The real evidence date, three days into the current cluster --
        // the card should read "week 1", not "week 14".
        let now = date(2026, 9, 15)
        #expect(term.map { $0.elapsedWeeks(at: now) } ?? .infinity < 1)
    }

    @Test("term(for:) is unaffected on an ordinary single-term course with no large gaps")
    func ordinarySingleTermCourseUnaffected() {
        let earliest = date(2026, 9, 1)
        let items = [
            item("a", dueAt: earliest),
            item("b", dueAt: date(2026, 9, 15)),
            item("c", dueAt: date(2026, 10, 1)),
            item("d", dueAt: date(2026, 11, 1)),
            item("e", dueAt: date(2026, 12, 1)),
        ]
        let category = GradeCategory(id: "a", name: "a", items: items)

        let term = GradeCountPredictor.term(for: [category])

        #expect(term?.start == earliest)
    }

    @Test("a ~5-week winter break between a fall and spring due date is NOT treated as a recycled-site gap")
    func winterBreakGapDoesNotSplitTerm() {
        // Consecutive gaps here are all well under `recycledSiteGapWeeks`
        // (8), including the fall-to-spring one (2025-12-10 to 2026-01-15,
        // about 5 weeks) that this test exists to protect: a threshold
        // under roughly 6 weeks would wrongly treat Penn's own winter break
        // as evidence of a recycled Canvas site and split a real two-
        // semester course's due dates in half at the New Year.
        let earliest = date(2025, 11, 15)
        let items = [
            item("fall-1", dueAt: earliest),
            item("fall-2", dueAt: date(2025, 12, 10)),
            item("spring-1", dueAt: date(2026, 1, 15)),
            item("spring-2", dueAt: date(2026, 2, 10)),
        ]
        let category = GradeCategory(id: "a", name: "a", items: items)

        let term = GradeCountPredictor.term(for: [category])

        #expect(term?.start == earliest)
    }

    @Test("elapsedFraction clamps to 0 before the term starts and to 1 once it's over")
    func elapsedFractionClampsAtBothEnds() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        let term = GradeCountPredictor.Term(start: start, weeks: 14)
        let before = start.addingTimeInterval(-5 * week)
        let after = start.addingTimeInterval(30 * week)
        #expect(term.elapsedFraction(at: before) == 0)
        #expect(term.elapsedFraction(at: after) == 1)
        #expect(term.elapsedWeeks(at: before) == 0)
        #expect(term.elapsedWeeks(at: after) == 14)
    }
}
