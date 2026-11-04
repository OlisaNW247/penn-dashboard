import Foundation
import Testing
@testable import LowHangingFruitKit

@Suite struct WorkItemIdentityTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    private func day(_ n: Double) -> Date { t0.addingTimeInterval(n * 86_400) }

    private func item(_ ref: String, _ title: String, due: Date?, _ aliases: WorkItemAlias...) -> WorkItemIdentity {
        WorkItemIdentity(ref: ref, aliases: Set(aliases), title: title, dueAt: due)
    }

    private func isMerge(_ o: WorkItemMatcher.Outcome, _ tier: WorkItemMatcher.Tier) -> Bool {
        if case let .merge(m) = o { return m.tier == tier }
        return false
    }

    // MARK: Aliases

    @Test func aliasStableStringRoundTrips() throws {
        let all: [WorkItemAlias] = [
            .canvasAssignment("1"), .canvasQuiz("2"), .moduleItem("3"),
            .moduleContent(type: "Assignment", id: "4"), .gradescopeAssignment("9/8"),
            .discussionTopic("5"), .planner(type: "quiz", id: "6"), .mapItem("m"),
            .fact("f:1"), .feedUID("event-assignment-7"),
        ]
        for alias in all {
            #expect(WorkItemAlias(stableString: alias.stableString) == alias)
            let data = try JSONEncoder().encode(alias)
            #expect(try JSONDecoder().decode(WorkItemAlias.self, from: data) == alias)
        }
        #expect(WorkItemAlias(stableString: "nonsense") == nil)
    }

    @Test func moduleItemIDIsNotAnAssignmentID() {
        #expect(WorkItemAlias.moduleItem("4812").canonical != .canvasAssignment("4812"))
        #expect(WorkItemAlias.moduleContent(type: "Assignment", id: "4812").canonical == .canvasAssignment("4812"))
    }

    // MARK: Must merge

    @Test func feedRowAndModuleItemShareContentID() {
        let feed = Assignment(
            source: .canvas, sourceID: "event-assignment-4812", kind: .assignment,
            course: "PHYS 151", title: "Lab 3", dueAt: day(1),
            url: URL(string: "https://canvas.example.edu/calendar?include_contexts=course_9#assignment_4812"))
        let feedID = WorkItemIdentity.from(feed)
        let module = item("mod", "Reading: Lab 3 handout", due: nil,
                          .moduleItem("77"), .moduleContent(type: "Assignment", id: "4812"))
        #expect(feedID.aliases.contains(.canvasAssignment("4812")))
        #expect(isMerge(WorkItemMatcher.match(feedID, module), .deterministic))
    }

    @Test func gradescopeAndCanvasMergeByTitleAndDate() {
        let canvas = item("c", "Homework 3", due: day(2), .canvasAssignment("1"))
        let gs = item("g", "HW3", due: day(2).addingTimeInterval(3600), .gradescopeAssignment("1/2"))
        #expect(isMerge(WorkItemMatcher.match(canvas, gs), .titleAndDate))
    }

    @Test func numberWordsRomansAndCourseCodesFold() {
        let a = item("a", "CIS 1210 Quiz Three", due: day(1))
        let b = item("b", "Quiz III", due: day(1))
        let c = item("c", "Quiz 3 [CIS 1210]", due: day(1))
        #expect(isMerge(WorkItemMatcher.match(a, b), .titleAndDate))
        #expect(isMerge(WorkItemMatcher.match(b, c), .titleAndDate))
    }

    // MARK: Must not merge

    @Test func labThreeAndLabThreeReportWithDifferentIDsRefused() {
        let a = item("a", "Lab 3", due: day(1), .canvasAssignment("111"))
        let b = item("b", "Lab 3 Report", due: day(1), .canvasAssignment("222"))
        #expect(WorkItemMatcher.match(a, b) == .refused("different Canvas assignment ids"))
    }

    @Test func labThreeAndLabThreeReportWithoutIDsStaysApart() {
        let a = item("a", "Lab 3", due: day(1))
        let b = item("b", "Lab 3 Report", due: day(1))
        #expect(WorkItemMatcher.match(a, b) == .noMatch)
    }

    @Test func sameTitleTwoWeeksApartStaysApart() {
        let a = item("a", "Reading Response", due: day(1))
        let b = item("b", "Reading Response", due: day(15))
        #expect(WorkItemMatcher.match(a, b) == .noMatch)
    }

    @Test func oneDatedOneUndatedStaysApart() {
        let a = item("a", "HW 3", due: day(1))
        let b = item("b", "HW 3", due: nil)
        #expect(WorkItemMatcher.match(a, b) == .noMatch)
    }

    @Test func hardRuleBeatsIdenticalTitle() {
        let a = item("a", "Quiz 1", due: day(1), .canvasAssignment("1"))
        let b = item("b", "Quiz 1", due: day(1), .canvasAssignment("2"))
        #expect(WorkItemMatcher.match(a, b) == .refused("different Canvas assignment ids"))
    }

    @Test func hardRuleBeatsSharedNonCanvasAlias() {
        let a = item("a", "X", due: nil, .canvasAssignment("1"), .fact("f"))
        let b = item("b", "X", due: nil, .canvasAssignment("2"), .fact("f"))
        #expect(WorkItemMatcher.match(a, b) == .refused("different Canvas assignment ids"))
    }

    // MARK: Tier 3

    @Test func quizThreeIsQuizTwoForChapterTwentyTwoOnlyByTarget() {
        let canvas = item("canvas:quiz3", "Quiz 3", due: day(4), .canvasAssignment("30"))
        let fact = item("fact:1", "Quiz 2 for Chap. 22", due: day(4), .fact("1"))
        #expect(WorkItemMatcher.match(canvas, fact) == .noMatch)
        let other = item("canvas:quiz4", "Quiz 4", due: day(8), .canvasAssignment("31"))
        let index = [canvas, other]
        #expect(WorkItemMatcher.resolve(target: "canvas:quiz3", among: index)?.ref == "canvas:quiz3")
        #expect(WorkItemMatcher.resolve(target: WorkItemAlias.canvasAssignment("31").stableString, among: index)?.ref == "canvas:quiz4")
        #expect(isMerge(WorkItemMatcher.match(factTarget: "canvas:quiz3", fact: fact, among: index), .modelTarget))
    }

    @Test func targetIsNeverFreeTextOrAmbiguous() {
        let a = item("a", "Quiz 3", due: nil, .canvasAssignment("1"))
        let b = item("b", "Quiz 3", due: nil, .canvasAssignment("1"))
        #expect(WorkItemMatcher.resolve(target: "Quiz 3", among: [a, b]) == nil)
        #expect(WorkItemMatcher.resolve(target: "canvas-assignment:1", among: [a, b]) == nil)
    }

    @Test func targetCannotOverrideHardRule() {
        let fact = item("f", "Quiz", due: nil, .canvasAssignment("9"))
        let cand = item("c", "Quiz 3", due: nil, .canvasAssignment("1"))
        #expect(WorkItemMatcher.match(factTarget: "c", fact: fact, among: [cand]) == .refused("different Canvas assignment ids"))
    }

    // MARK: Merge record

    @Test func mergeRecordRoundTripsAndSplits() throws {
        let a = item("a", "HW 3", due: day(1), .canvasAssignment("1"))
        let b = item("b", "Homework 3", due: day(1), .gradescopeAssignment("9/8"))
        guard case let .merge(m) = WorkItemMatcher.match(a, b) else { Issue.record("expected merge"); return }
        let record = WorkItemMergeRecord(first: a, second: b, match: m, mergedAt: t0)
        let data = try JSONEncoder().encode(record)
        let back = try JSONDecoder().decode(WorkItemMergeRecord.self, from: data)
        #expect(back == record)
        let (x, y) = back.split()
        #expect(x == a && y == b)
        #expect(back.tier == .titleAndDate)
        #expect(back.mergedAt == t0)
    }

    // MARK: Deduplicator integration

    @Test func matchPairsNeverPairsConflictingCanvasIDs() {
        // Gradescope rows carry no Canvas id, so the veto is exercised via the
        // shared helper the collapse paths now use.
        let a = Assignment(source: .canvas, sourceID: "event-assignment-111", kind: .assignment,
                           course: "C 100", title: "Lab 3", dueAt: day(1), url: nil)
        let b = Assignment(source: .canvasModules, sourceID: "module-item-5", kind: .event,
                           course: "C 100", title: "Lab 3 Report", dueAt: day(1),
                           url: URL(string: "https://c.example.edu/courses/1/assignments/222"))
        #expect(AssignmentDeduplicator.haveConflictingCanvasAssignmentIDs(a, b))
    }
}
