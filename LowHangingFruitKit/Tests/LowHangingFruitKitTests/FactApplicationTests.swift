import Foundation
import Testing
@testable import LowHangingFruitKit

@Suite("Fact application (precedence engine)")
struct FactApplicationTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let due = Date(timeIntervalSince1970: 1_800_500_000)
    private static let codes = ["1234": "CIS 2400", "99": "MATH 1400"]

    private func canvasItem(
        _ id: String, title: String = "PSet 3", course: String = "CIS 2400", due: Date? = FactApplicationTests.due
    ) -> Assignment {
        Assignment(
            source: .canvas, sourceID: "event-assignment-\(id)", kind: .assignment, course: course,
            title: title, dueAt: due,
            url: URL(string: "https://canvas.upenn.edu/calendar?include_contexts=course_1234&month=1&year=2027#assignment_\(id)")
        )
    }

    private func fact(
        _ seq: Int, _ type: CourseFactWire.FactType, target: String? = "555", title: String? = nil,
        dueAt: Date? = nil, kind: CourseFactWire.Kind? = nil,
        confidence: CourseFactWire.Confidence = .high, posted: TimeInterval? = nil,
        course: String = "1234", doc: String = "announcement:1234:55",
        override: FactOverride = .none
    ) -> AppliedFact {
        AppliedFact(
            seq: seq, courseID: course, documentID: doc, contentHash: "h", type: type, target: target,
            title: title, dueAt: dueAt, kind: kind, quote: "the quote", confidence: confidence,
            postedAt: posted.map { Self.now.addingTimeInterval($0) }, studentOverride: override
        )
    }

    private func run(_ facts: [AppliedFact], _ items: [FactItem], urls: [String: URL] = [:]) -> FactEffects {
        FactApplication.evaluate(facts: facts, items: items, courseCodeByID: Self.codes, documentURLs: urls, now: Self.now)
    }

    private var itemID: String { canvasItem("555").id }

    // MARK: Rule 4 and the basic effects

    @Test("a high-confidence cancel hides and tags; nothing is completed")
    func cancelHides() {
        let out = run([fact(1, .cancel)], [FactItem(canvasItem("555"))])
        #expect(out.items[itemID]?.cancelled == .init(by: "announcement:1234:55#1"))
        #expect(out.applied == ["announcement:1234:55#1"])
        #expect(out.resolvedItems["announcement:1234:55#1"] == itemID)
        #expect(out.newTasks.isEmpty)
    }

    @Test("reschedule, scope change and note land on the resolved row")
    func otherEffects() {
        let moved = Self.due.addingTimeInterval(86_400)
        let out = run([
            fact(1, .reschedule, dueAt: moved),
            fact(2, .scopeChange, title: "Only part A"),
            fact(3, .note, title: nil),
        ], [FactItem(canvasItem("555"))])
        let effects = out.items[itemID]
        #expect(effects?.rescheduled == .init(to: moved, from: Self.due, by: "announcement:1234:55#1"))
        #expect(effects?.scopeChanged?.note == "Only part A")
        #expect(effects?.notes.map(\.text) == ["the quote"])
        #expect(out.applied.count == 3)
    }

    // MARK: Canvas's structured date

    @Test("with a section date, an equal reschedule is redundant and a differing one needs review")
    func structuredDateBeatsReschedule() {
        let item = FactItem(assignment: canvasItem("555"), userCompleted: false, editedDueDate: nil,
                            isGoneFromFeed: false, canvasDueAt: Self.due, hasStructuredDueDate: true)
        let equal = run([fact(1, .reschedule, dueAt: Self.due)], [item])
        #expect(equal.items.isEmpty && equal.needsReview.isEmpty)
        #expect(equal.redundant.map(\.reason) == [.appliedByCanvas])

        let differing = run([fact(1, .reschedule, dueAt: Self.due.addingTimeInterval(86_400))], [item])
        #expect(differing.items.isEmpty)
        #expect(differing.needsReview.map(\.reason) == [.disagreesWithCanvasDate])

        let plain = run([fact(1, .reschedule, dueAt: Self.due.addingTimeInterval(86_400))], [FactItem(canvasItem("555"))])
        #expect(plain.items[itemID]?.rescheduled != nil)
    }

    // MARK: Rule 1, the student wins

    @Test("a completed item, a hand-edited date, and a rejected fact are never applied")
    func studentWins() {
        let done = FactItem(assignment: canvasItem("555"), userCompleted: true, editedDueDate: nil, isGoneFromFeed: false, canvasDueAt: Self.due)
        let edited = FactItem(assignment: canvasItem("555"), userCompleted: false, editedDueDate: Self.due.addingTimeInterval(7_200), isGoneFromFeed: false, canvasDueAt: Self.due)
        for item in [done, edited] {
            let out = run([fact(1, .cancel)], [item])
            #expect(out.items.isEmpty)
            #expect(out.redundant == [.init(factID: "announcement:1234:55#1", reason: .studentOverride)])
        }
        let rejected = run([fact(1, .cancel, override: .rejected)], [FactItem(canvasItem("555"))])
        #expect(rejected.items.isEmpty)
        #expect(rejected.redundant == [.init(factID: "announcement:1234:55#1", reason: .studentOverride)])
    }

    @Test("a confirmed fact is applied even over a hand edit and a completion")
    func confirmedWins() {
        let edited = FactItem(assignment: canvasItem("555"), userCompleted: true, editedDueDate: Self.due.addingTimeInterval(1), isGoneFromFeed: false, canvasDueAt: Self.due)
        let moved = Self.due.addingTimeInterval(86_400)
        let out = run([fact(1, .reschedule, dueAt: moved, override: .confirmed)], [edited])
        #expect(out.items[itemID]?.rescheduled?.to == moved)
    }

    @Test("a rejected newer fact does not retire an older one")
    func rejectedDoesNotSupersede() {
        let a = Self.due.addingTimeInterval(86_400), b = Self.due.addingTimeInterval(172_800)
        let out = run([
            fact(1, .reschedule, dueAt: a, posted: 10),
            fact(2, .reschedule, dueAt: b, posted: 20, override: .rejected),
        ], [FactItem(canvasItem("555"))])
        #expect(out.items[itemID]?.rescheduled?.to == a)
    }

    // MARK: Rule 2, Canvas wins over prose

    @Test("a reschedule that matches Canvas within a minute is redundant; a different one applies")
    func canvasAgrees() {
        let near = run([fact(1, .reschedule, dueAt: Self.due.addingTimeInterval(45))], [FactItem(canvasItem("555"))])
        #expect(near.items.isEmpty)
        #expect(near.redundant == [.init(factID: "announcement:1234:55#1", reason: .appliedByCanvas)])
        let far = run([fact(1, .reschedule, dueAt: Self.due.addingTimeInterval(120))], [FactItem(canvasItem("555"))])
        #expect(far.items[itemID]?.rescheduled != nil)
    }

    @Test("a cancel on an item already gone from the feed is a redundant confirmation")
    func cancelOnGoneItem() {
        let gone = FactItem(assignment: canvasItem("555"), userCompleted: false, editedDueDate: nil, isGoneFromFeed: true, canvasDueAt: Self.due)
        let out = run([fact(1, .cancel)], [gone])
        #expect(out.items.isEmpty)
        #expect(out.redundant.first?.reason == .appliedByCanvas)
    }

    @Test("a new task Canvas already lists is redundant, and its own earlier row is not mistaken for a duplicate")
    func newTaskDuplicates() {
        let existing = FactItem(canvasItem("555", title: "PSet 3"))
        let dup = run([fact(1, .newTask, target: nil, title: "PSet 3", dueAt: Self.due, kind: .submission)], [existing])
        #expect(dup.newTasks.isEmpty)
        #expect(dup.redundant.first?.reason == .appliedByCanvas)

        let first = run([fact(2, .newTask, target: nil, title: "Bring a calculator", dueAt: Self.due, kind: .preparation)], [])
        let row = first.newTasks[0].assignment
        let second = run([fact(2, .newTask, target: nil, title: "Bring a calculator", dueAt: Self.due, kind: .preparation)], [FactItem(row)])
        #expect(second.newTasks.map(\.assignment.id) == [row.id])
    }

    // MARK: Rule 3, newest wins

    @Test("newest by postedAt then seq wins; older ones are superseded")
    func supersessionOrder() {
        let a = Self.due.addingTimeInterval(86_400), b = Self.due.addingTimeInterval(172_800), c = Self.due.addingTimeInterval(259_200)
        // seq 3 was extracted last but POSTED first; seq 2 is the newest statement.
        let out = run([
            fact(3, .reschedule, dueAt: a, posted: 5),
            fact(2, .reschedule, dueAt: b, posted: 50),
            fact(1, .reschedule, dueAt: c, posted: 50),
        ], [FactItem(canvasItem("555"))])
        #expect(out.items[itemID]?.rescheduled?.to == b)
        let reasons = Dictionary(uniqueKeysWithValues: out.redundant.map { ($0.factID, $0.reason) })
        #expect(reasons["announcement:1234:55#3"] == .supersededBySeq(2))
        #expect(reasons["announcement:1234:55#1"] == .supersededBySeq(2))
    }

    @Test("an older reschedule does not resurface when the newer one agrees with Canvas")
    func olderDoesNotResurface() {
        let stale = Self.due.addingTimeInterval(86_400)
        let out = run([
            fact(1, .reschedule, dueAt: stale, posted: 1),
            fact(2, .reschedule, dueAt: Self.due, posted: 2),
        ], [FactItem(canvasItem("555"))])
        #expect(out.items.isEmpty)
        let reasons = Dictionary(uniqueKeysWithValues: out.redundant.map { ($0.factID, $0.reason) })
        #expect(reasons["announcement:1234:55#1"] == .supersededBySeq(2))
        #expect(reasons["announcement:1234:55#2"] == .appliedByCanvas)
    }

    // MARK: Rule 5 and the confidence gate

    @Test("an unresolvable cancel, reschedule or scope change goes to review, not applied")
    func unresolvableGoesToReview() {
        let items = [FactItem(canvasItem("555"))]
        let out = run([
            fact(1, .cancel, target: "999"),
            fact(2, .reschedule, target: nil, dueAt: Self.due.addingTimeInterval(9_999)),
            fact(3, .scopeChange, target: "module:abc123", title: "x"),
        ], items)
        #expect(out.items.isEmpty)
        #expect(out.needsReview.map(\.fact.seq) == [1, 2, 3])
        #expect(out.needsReview.allSatisfy { $0.reason == .unresolvedTarget })
    }

    @Test("a target resolves only among its own course's rows")
    func otherCourseDoesNotResolve() {
        let other = FactItem(canvasItem("555", course: "MATH 1400"))
        let out = run([fact(1, .cancel)], [other])
        #expect(out.items.isEmpty)
        #expect(out.needsReview.first?.reason == .unresolvedTarget)
    }

    @Test("a reschedule with no usable date goes to review")
    func rescheduleWithoutDate() {
        let out = run([fact(1, .reschedule, dueAt: nil)], [FactItem(canvasItem("555"))])
        #expect(out.items.isEmpty)
        #expect(out.needsReview.first?.reason == .missingDetail)
    }

    @Test("an unresolvable new_task is still a task, shaped as an announcement row")
    func newTaskShape() throws {
        let url = URL(string: "https://canvas.upenn.edu/courses/1234/discussion_topics/55")
        let out = run(
            [fact(7, .newTask, target: nil, title: "Read ch. 4", dueAt: Self.due, kind: .submission)],
            [FactItem(canvasItem("555"))],
            urls: ["announcement:1234:55": try #require(url)]
        )
        let task = try #require(out.newTasks.first?.assignment)
        #expect(task.source == .canvasAnnouncement)
        #expect(task.sourceID == "fact-announcement:1234:55-7")
        #expect(task.announcementOrigin == .canvas)
        #expect(task.kind == .assignment)
        #expect(task.course == "CIS 2400")
        #expect(task.dueAt == Self.due)
        #expect(task.url == url)
        #expect(!task.submitted)
        #expect(out.applied == ["announcement:1234:55#7"])
    }

    @Test("a new_task kind maps: event to event, preparation and unstated to other")
    func newTaskKinds() {
        let out = run([
            fact(1, .newTask, target: nil, title: "Review session", kind: .event),
            fact(2, .newTask, target: nil, title: "Bring laptop", kind: .preparation),
            fact(3, .newTask, target: nil, title: "Sign form", kind: nil),
        ], [])
        let kinds = Dictionary(uniqueKeysWithValues: out.newTasks.map { ($0.assignment.title, $0.assignment.kind) })
        #expect(kinds == ["Review session": .event, "Bring laptop": .other, "Sign form": .other])
    }

    @Test("a medium-confidence cancel is reviewed, not applied; confirmed applies; high applies")
    func mediumCancel() {
        let items = [FactItem(canvasItem("555"))]
        let medium = run([fact(1, .cancel, confidence: .medium)], items)
        #expect(medium.items.isEmpty)
        #expect(medium.needsReview.first?.reason == .mediumConfidenceCancel)
        #expect(run([fact(1, .cancel, confidence: .medium, override: .confirmed)], items).items[itemID]?.cancelled != nil)
        #expect(run([fact(1, .cancel, confidence: .high)], items).items[itemID]?.cancelled != nil)
        // The gate is for cancels only: a medium reschedule still applies.
        #expect(run([fact(1, .reschedule, dueAt: Self.due.addingTimeInterval(9_000), confidence: .medium)], items).items[itemID]?.rescheduled != nil)
    }

    @Test("a needs_review fact is listed and never applied, even when confirmed")
    func needsReviewNeverApplies() {
        let out = run([fact(1, .needsReview, override: .confirmed)], [FactItem(canvasItem("555"))])
        #expect(out.items.isEmpty && out.newTasks.isEmpty && out.applied.isEmpty)
        #expect(out.needsReview.first?.reason == .flaggedByExtractor)
    }

    @Test("a fact for a course the phone cannot name by code goes to review")
    func unknownCourse() {
        let out = run([fact(1, .cancel, course: "777"), fact(2, .newTask, target: nil, title: "x", course: "777")], [])
        #expect(out.needsReview.map(\.reason) == [.unknownCourse, .unknownCourse])
    }

    // MARK: The ledger invariant

    @Test("over generated inputs the engine never completes, deletes or invents a row id")
    func ledgerInvariant() {
        var rng = SeededGenerator(seed: 0xFAC7)
        let types = CourseFactWire.FactType.allCases
        let overrides = FactOverride.allCases
        for round in 0..<200 {
            let ids = ["555", "556", "557"]
            let items: [FactItem] = ids.enumerated().map { index, id in
                FactItem(
                    assignment: canvasItem(id, title: "Task \(index) \(id)", due: Self.due.addingTimeInterval(Double(index) * 90_000)),
                    userCompleted: Bool.random(using: &rng),
                    editedDueDate: Bool.random(using: &rng) ? Self.due : nil,
                    isGoneFromFeed: Bool.random(using: &rng),
                    canvasDueAt: Self.due.addingTimeInterval(Double(index) * 90_000)
                )
            }
            let facts: [AppliedFact] = (0..<Int.random(in: 0...12, using: &rng)).map { seq in
                fact(
                    seq + 1, types.randomElement(using: &rng)!,
                    target: [nil, "555", "556", "999", "module:zz"].randomElement(using: &rng)!,
                    title: ["Quiz 1", nil, "Read"].randomElement(using: &rng)!,
                    dueAt: [nil, Self.due, Self.due.addingTimeInterval(500_000)].randomElement(using: &rng)!,
                    confidence: Bool.random(using: &rng) ? .high : .medium,
                    posted: Double(Int.random(in: 0...5, using: &rng)),
                    override: overrides.randomElement(using: &rng)!
                )
            }
            let out = run(facts, items)
            let known = Set(items.map(\.assignment.id))
            let factIDs = Set(facts.map(\.id))

            #expect(Set(out.items.keys).isSubset(of: known), "round \(round): effects only on existing rows")
            #expect(out.newTasks.allSatisfy { !known.contains($0.assignment.id) && $0.assignment.source == .canvasAnnouncement && !$0.assignment.submitted })
            #expect(out.applied.isSubset(of: factIDs))
            // Every fact is accounted for in exactly one bucket.
            let accounted = out.applied.union(out.needsReview.map(\.fact.id)).union(out.redundant.map(\.factID))
            #expect(accounted == factIDs, "round \(round)")
            // A rejected fact never applies; an item the student finished or edited
            // is untouched unless the student confirmed a fact for it.
            for rejected in facts where rejected.studentOverride == .rejected { #expect(!out.applied.contains(rejected.id)) }
            for item in items where (item.userCompleted || item.editedDueDate != nil) && !facts.contains(where: { $0.studentOverride == .confirmed }) {
                #expect(out.items[item.assignment.id] == nil, "round \(round)")
            }
        }
    }
}
