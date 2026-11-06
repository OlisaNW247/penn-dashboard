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

    // Rewritten 2026-11-05. It used to pin "a rejected newer reschedule leaves
    // an older RESCHEDULE eligible", which is the very hole in undo: a rejection
    // is now a verdict on the key (course, type, target), so an older fact of
    // the same key stays down too. What survives of the old intent is that a
    // rejection never retires a fact of ANOTHER key (here an older cancel).
    @Test("a rejected reschedule is a verdict on its key: older reschedules stay down, an older cancel is not retired by it")
    func rejectedIsAVerdictOnTheKey() {
        let a = Self.due.addingTimeInterval(86_400), b = Self.due.addingTimeInterval(172_800)
        let sameKey = run([
            fact(1, .reschedule, dueAt: a, posted: 10),
            fact(2, .reschedule, dueAt: b, posted: 20, override: .rejected),
        ], [FactItem(canvasItem("555"))])
        #expect(sameKey.items.isEmpty)
        #expect(sameKey.redundant.contains(.init(factID: "announcement:1234:55#1", reason: .studentOverride)))

        let otherKey = run([
            fact(1, .cancel, posted: 10),
            fact(2, .reschedule, dueAt: b, posted: 20, override: .rejected),
        ], [FactItem(canvasItem("555"))])
        #expect(otherKey.items[itemID]?.cancelled != nil)
    }

    // MARK: Rejection outlives the fact id

    @Test("undo lasts through a typo edit to the post: the re-extracted cancel (new id, same post time) stays down")
    func undoSurvivesTypoEdit() {
        let rejected = fact(1, .cancel, posted: 10, override: .rejected)
        let reextracted = fact(7, .cancel, posted: 10) // same document, new revision, new seq
        let out = run([rejected, reextracted], [FactItem(canvasItem("555"))])
        #expect(out.items.isEmpty)
        #expect(out.applied.isEmpty)
        #expect(out.redundant.contains(.init(factID: reextracted.id, reason: .studentOverride)))
    }

    @Test("undo lasts when a second post repeats the news, even one posted earlier")
    func undoSurvivesDuplicatePost() {
        let rejected = fact(1, .cancel, posted: 10, override: .rejected)
        let repeatLater = fact(2, .cancel, posted: 10, doc: "announcement:1234:56")
        let repeatEarlier = fact(3, .cancel, posted: 4, doc: "announcement:1234:57")
        let out = run([rejected, repeatLater, repeatEarlier], [FactItem(canvasItem("555"))])
        #expect(out.items.isEmpty)
    }

    @Test("a genuinely newer post may apply again, and rejecting that one holds too")
    func newerPostReapplies() {
        let old = fact(1, .cancel, posted: 10, override: .rejected)
        let newer = fact(2, .cancel, posted: 50, doc: "announcement:1234:60")
        #expect(run([old, newer], [FactItem(canvasItem("555"))]).items[itemID]?.cancelled != nil)
        let rejectedAgain = fact(2, .cancel, posted: 50, doc: "announcement:1234:60", override: .rejected)
        let again = fact(3, .cancel, posted: 50, doc: "announcement:1234:61")
        #expect(run([old, rejectedAgain, again], [FactItem(canvasItem("555"))]).items.isEmpty)
    }

    @Test("a rejection does not leak to another target, another type, or another course; a confirm lifts it")
    func rejectionIsScopedToItsKey() {
        let rejected = fact(1, .cancel, target: "555", posted: 10, override: .rejected)
        let otherTarget = fact(2, .cancel, target: "556", posted: 10, doc: "announcement:1234:70")
        let items = [FactItem(canvasItem("555")), FactItem(canvasItem("556"))]
        let out = run([rejected, otherTarget], items)
        #expect(out.items[canvasItem("556").id]?.cancelled != nil)
        #expect(out.items[itemID] == nil)
        let confirmed = fact(3, .cancel, target: "555", posted: 10, doc: "announcement:1234:71", override: .confirmed)
        #expect(run([rejected, confirmed], items).items[itemID]?.cancelled != nil)
    }

    @Test("an undated rejected fact holds against any later post: nothing is provably newer")
    func undatedRejectionHolds() {
        let rejected = fact(1, .cancel, posted: nil, override: .rejected)
        let later = fact(2, .cancel, posted: 99, doc: "announcement:1234:80")
        #expect(run([rejected, later], [FactItem(canvasItem("555"))]).items.isEmpty)
    }

    // MARK: Cancel and reschedule share one key

    @Test("a newer reschedule lifts an older cancel; the cancel is superseded, not applied alongside")
    func newerRescheduleLiftsCancel() {
        let back = Self.due.addingTimeInterval(86_400)
        let out = run([
            fact(1, .cancel, posted: 1),
            fact(2, .reschedule, dueAt: back, posted: 3, doc: "announcement:1234:56"),
        ], [FactItem(canvasItem("555"))])
        #expect(out.items[itemID]?.cancelled == nil)
        #expect(out.items[itemID]?.rescheduled?.to == back)
        #expect(out.redundant.contains(.init(factID: "announcement:1234:55#1", reason: .supersededBySeq(2))))
    }

    @Test("a newer cancel beats an older reschedule")
    func newerCancelBeatsReschedule() {
        let moved = Self.due.addingTimeInterval(86_400)
        let out = run([
            fact(1, .reschedule, dueAt: moved, posted: 1),
            fact(2, .cancel, posted: 3, doc: "announcement:1234:56"),
        ], [FactItem(canvasItem("555"))])
        #expect(out.items[itemID]?.cancelled != nil)
        #expect(out.items[itemID]?.rescheduled == nil)
    }

    @Test("a scope change and a note do not share the cancel/reschedule key")
    func scopeChangeKeepsOwnKey() {
        let out = run([
            fact(1, .cancel, posted: 1),
            fact(2, .scopeChange, title: "Only part A", posted: 3, doc: "announcement:1234:56"),
        ], [FactItem(canvasItem("555"))])
        #expect(out.items[itemID]?.cancelled != nil)
        #expect(out.items[itemID]?.scopeChanged != nil)
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

    private func announcementItem(_ title: String, due: Date) -> FactItem {
        FactItem(Assignment(
            source: .canvasAnnouncement, sourceID: "announcement-\(title)", kind: .event, course: "CIS 2400",
            title: title, dueAt: due, url: nil
        ))
    }

    private static let finalDue = Date(timeIntervalSince1970: 1_797_289_200) // 2026-12-14 23:00Z
    private static let paddedFinal = "Take the final exam (Dec 14, 6:00-8:00 PM, ANNS 110)"

    @Test("a padded new_task title is a duplicate of the same exam an announcement already filed as Final Exam")
    func paddedTitleDuplicatesShortItem() {
        let existing = announcementItem("Final Exam", due: Self.finalDue.addingTimeInterval(-3600))
        let out = run([fact(1, .newTask, target: nil, title: Self.paddedFinal, dueAt: Self.finalDue, kind: .event)], [existing])
        #expect(out.newTasks.isEmpty)
        #expect(out.redundant.map(\.reason) == [.appliedByCanvas])
    }

    @Test("the same padded fact beside a different exam on the same day is still a new task")
    func paddedTitleKeepsTitleAgreement() {
        let existing = announcementItem("Midterm 2", due: Self.finalDue)
        let out = run([fact(1, .newTask, target: nil, title: Self.paddedFinal, dueAt: Self.finalDue, kind: .event)], [existing])
        #expect(out.redundant.isEmpty)
        #expect(out.newTasks.count == 1)
        #expect(out.newTasks.first?.assignment.title == Self.paddedFinal)
    }

    @Test("the item side is normalised too: Final Exam (Cumulative) matches a fact Final exam")
    func itemSideNormalised() {
        let existing = announcementItem("Final Exam (Cumulative)", due: Self.finalDue)
        let out = run([fact(1, .newTask, target: nil, title: "Final exam", dueAt: Self.finalDue, kind: .event)], [existing])
        #expect(out.newTasks.isEmpty)
        #expect(out.redundant.map(\.reason) == [.appliedByCanvas])
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

    // MARK: Fuzz: 500 rounds, seeded

    /// One generated scenario. Built from a seed alone, so two builds from the
    /// same seed are the same input, and a red round names its seed.
    private struct Scenario {
        var facts: [AppliedFact]
        var items: [FactItem]
    }

    private func scenario(seed: UInt64, uniqueSeqs: Bool = false) -> Scenario {
        var rng = SeededGenerator(seed: seed)
        let sourceIDs = ["555", "556", "557", "558"]
        var items: [FactItem] = []
        for (index, id) in sourceIDs.enumerated() {
            let course = index == 3 ? "MATH 1400" : "CIS 2400"
            let canvasDue: Date? = rng.chance(0.15) ? nil : Self.due.addingTimeInterval(Double(index) * 90_000)
            items.append(FactItem(
                assignment: canvasItem(id, title: "Task \(index) \(id)", course: course, due: canvasDue),
                userCompleted: rng.chance(0.25),
                editedDueDate: rng.chance(0.25) ? Self.due.addingTimeInterval(7_000) : nil,
                isGoneFromFeed: rng.chance(0.25),
                canvasDueAt: canvasDue,
                hasStructuredDueDate: rng.chance(0.3)
            ))
        }
        if rng.chance(0.5) {
            // A row a fact created on an earlier pass, so a re-evaluation sees its own output.
            items.append(FactItem(Assignment(
                source: .canvasAnnouncement, sourceID: FactApplication.taskSourceID(documentID: "announcement:1234:55", seq: 3),
                kind: .other, course: "CIS 2400", title: "Read", dueAt: Self.due, url: nil
            )))
        }
        let types = CourseFactWire.FactType.allCases
        let targets: [String?] = [nil, "", "555", "556", "557", "558", "999", "module:zz", "abc"]
        let titles: [String?] = [nil, "", "  ", "Quiz 1", "Read", "Task 1 556", "PSet 3"]
        let dues: [Date?] = [nil, Self.due, Self.due.addingTimeInterval(30), Self.due.addingTimeInterval(500_000),
                             Self.due.addingTimeInterval(90_000), Date.distantPast, Date.distantFuture]
        let docs = ["announcement:1234:55", "announcement:1234:56", "ed:1234:9"]
        let courses = ["1234", "1234", "1234", "99", "777"]
        var facts: [AppliedFact] = []
        for index in 0..<rng.int(0...16) {
            // Duplicate seqs are different facts in different documents (the id
            // carries the document); a repeat of one id is the store's job to drop.
            let seq = uniqueSeqs ? index + 1 : rng.int(1...6)
            let doc = uniqueSeqs ? docs[index % docs.count] : rng.pick(docs)
            let candidate = fact(
                seq, rng.pick(types), target: rng.pick(targets), title: rng.pick(titles), dueAt: rng.pick(dues),
                kind: rng.pick([nil, .submission, .preparation, .event]),
                confidence: rng.chance(0.5) ? .high : .medium,
                posted: rng.chance(0.2) ? nil : Double(uniqueSeqs ? rng.int(0...3) * 1000 + index : rng.int(0...3)),
                course: rng.pick(courses), doc: doc,
                override: rng.chance(0.6) ? .none : rng.pick(FactOverride.allCases)
            )
            if !facts.contains(where: { $0.id == candidate.id }) { facts.append(candidate) }
        }
        return Scenario(facts: facts, items: items)
    }

    @Test("500 seeded rounds: nothing completed or deleted, buckets disjoint, no phantom reschedule, deterministic")
    func engineFuzz() {
        // Tallies, so a generator that drifted into producing only trivial
        // rounds fails here instead of passing vacuously.
        var cancels = 0, reschedules = 0, tasks = 0, reviews = 0, redundants = 0
        defer {
            #expect(cancels > 15 && reschedules > 15 && tasks > 30 && reviews > 100 && redundants > 100,
                    "generator coverage: \(cancels) \(reschedules) \(tasks) \(reviews) \(redundants)")
        }
        for round in 0..<500 {
            let seed = 0xFAC7_0000 &+ UInt64(round)
            let input = scenario(seed: seed)
            let out = run(input.facts, input.items)
            let again = run(scenario(seed: seed).facts, scenario(seed: seed).items)
            #expect(out == again, "round \(round) seed \(seed): not deterministic")

            cancels += out.items.values.filter { $0.cancelled != nil }.count
            reschedules += out.items.values.filter { $0.rescheduled != nil }.count
            tasks += out.newTasks.count
            reviews += out.needsReview.count
            redundants += out.redundant.count
            let known = Set(input.items.map(\.assignment.id))
            let factIDs = Set(input.facts.map(\.id))
            let byID = Dictionary(uniqueKeysWithValues: input.items.map { ($0.assignment.id, $0) })

            // The output type cannot complete or delete; what it can do is touch
            // only rows that exist, and add only rows that do not.
            #expect(Set(out.items.keys).isSubset(of: known), "round \(round): effects only on existing rows")
            #expect(out.newTasks.allSatisfy { !known.contains($0.assignment.id) || $0.assignment.source == .canvasAnnouncement })
            #expect(out.newTasks.allSatisfy { !$0.assignment.submitted && $0.assignment.source == .canvasAnnouncement })
            #expect(Set(out.newTasks.map(\.assignment.id)).count == out.newTasks.count, "round \(round): one row per new task")

            // No row is both hidden by a cancel and created as a new task.
            let cancelled = Set(out.items.filter { $0.value.cancelled != nil }.keys)
            #expect(cancelled.isDisjoint(with: Set(out.newTasks.map(\.assignment.id))), "round \(round) seed \(seed)")

            // Every fact the engine names exists in the input.
            #expect(out.applied.isSubset(of: factIDs), "round \(round)")
            #expect(Set(out.needsReview.map(\.fact.id)).isSubset(of: factIDs))
            #expect(Set(out.redundant.map(\.factID)).isSubset(of: factIDs))
            #expect(Set(out.resolvedItems.keys).isSubset(of: factIDs))
            for effects in out.items.values {
                for id in [effects.cancelled?.by, effects.rescheduled?.by, effects.scopeChanged?.by].compactMap({ $0 }) + effects.notes.map(\.by) {
                    #expect(factIDs.contains(id) && out.applied.contains(id), "round \(round): effect by an unapplied fact")
                }
            }

            // Each fact lands in at most one bucket.
            let review = Set(out.needsReview.map(\.fact.id)), redundant = Set(out.redundant.map(\.factID))
            #expect(review.count == out.needsReview.count && redundant.count == out.redundant.count, "round \(round): a fact listed twice")
            #expect(review.isDisjoint(with: redundant), "round \(round) seed \(seed)")
            #expect(review.isDisjoint(with: out.applied), "round \(round) seed \(seed)")
            #expect(redundant.isDisjoint(with: out.applied), "round \(round) seed \(seed)")

            // A reschedule that is applied always moves the date by more than the
            // tolerance Canvas's own value is compared with.
            for (id, effects) in out.items {
                guard let moved = effects.rescheduled, let canvas = byID[id]?.canvasDueAt else { continue }
                #expect(abs(moved.to.timeIntervalSince(canvas)) > FactApplication.sameDateTolerance, "round \(round) seed \(seed)")
            }

            // The student wins: a finished or hand-dated row is untouched unless
            // a fact aimed at it was confirmed.
            let confirmedCourses = Set(input.facts.filter { $0.studentOverride == .confirmed }.map(\.courseID))
            for item in input.items where (item.userCompleted || item.editedDueDate != nil) && confirmedCourses.isEmpty {
                #expect(out.items[item.assignment.id] == nil, "round \(round) seed \(seed)")
            }
            for rejected in input.facts where rejected.studentOverride == .rejected {
                #expect(!out.applied.contains(rejected.id))
            }
        }
    }

    @Test("with unique seqs the outcome does not depend on the order the facts arrive in")
    func engineIgnoresInputOrder() {
        for round in 0..<200 {
            let seed = 0xBEEF_0000 &+ UInt64(round)
            let input = scenario(seed: seed, uniqueSeqs: true)
            var rng = SeededGenerator(seed: seed ^ 0xFFFF)
            let shuffledFacts = input.facts.shuffled(using: &rng)
            let shuffledItems = input.items.shuffled(using: &rng)
            #expect(run(input.facts, input.items) == run(shuffledFacts, shuffledItems), "round \(round) seed \(seed)")
        }
    }

    @Test("two facts tied on postedAt and seq that fight for one row get a stable winner")
    func tieOnPostedAtAndSeq() {
        // Cross-listed sites: two Canvas course ids that carry one code. Different
        // documents, same seq, same postedAt, both rescheduling the same row.
        // The winner is the greater fact id, in any input order, every call.
        let codes = ["1234": "CIS 2400", "5678": "CIS 2400"]
        let first = fact(1, .reschedule, dueAt: Self.due.addingTimeInterval(100_000), posted: 5, course: "1234", doc: "announcement:1234:55")
        let second = fact(1, .reschedule, dueAt: Self.due.addingTimeInterval(200_000), posted: 5, course: "5678", doc: "announcement:5678:77")
        let expected = first.id > second.id ? first.dueAt : second.dueAt
        for round in 0..<60 {
            let input = round.isMultiple(of: 2) ? [first, second] : [second, first]
            let out = FactApplication.evaluate(facts: input, items: [FactItem(canvasItem("555"))], courseCodeByID: codes, now: Self.now)
            #expect(out.items[itemID]?.rescheduled?.to == expected, "round \(round)")
        }
    }
}
