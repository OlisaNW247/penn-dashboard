import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// Facts from the server on the dashboard (`AppState+AppliedFacts`). Facts are
/// ingested through `ingestFacts` (the sync's own entry), so no network is
/// touched. Everything uses scratch defaults, an in-memory ledger, an
/// in-memory fact store and a pinned clock; nothing here writes the shared
/// `UserDefaults` domain.
///
/// The Canvas course id (8141) is this suite's own on purpose: `AppState`
/// caches `[code: id]` in the shared preferences, so an id another suite also
/// uses can map to that suite's code and the facts then resolve in no course.
@MainActor
@Suite("Applied facts: wired to the dashboard")
struct AppliedFactsWiringTests {
    private let course = CourseSummary(
        courseID: "8141", code: "FACT 0151", name: "Fact wiring",
        url: URL(string: "https://canvas.upenn.edu/courses/8141"), section: nil
    )
    private let now = ISO8601DateFormatter().date(from: "2026-11-05T12:00:00Z")!
    private func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }
    private let documentID = "announcement:8141:900"

    /// Due inside todo's two-day window.
    private func feedRow(_ id: String, title: String, due: String = "2026-11-06T17:00:00Z") -> Assignment {
        Assignment(
            source: .canvas, sourceID: "event-assignment-\(id)", kind: .assignment,
            course: course.code, title: title, dueAt: date(due),
            url: URL(string: "https://canvas.upenn.edu/courses/8141/assignments/\(id)")
        )
    }

    private func makeState(_ seed: [Assignment]) throws -> (AppState, AssignmentStore, AppliedFactStore, UserDefaults) {
        let suite = "AppliedFactsWiringTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = try AssignmentStore(inMemory: true)
        store.upsert(seed)
        let facts = try AppliedFactStore(inMemory: true)
        let state = AppState(assignmentStore: store, dueDateEditsDefaults: defaults)
        state.forceFixtureDataForTesting(false)
        state.appliedFactStore = facts
        state.factsDefaults = defaults
        state.structuredDefaults = defaults
        // The announcement post the facts came from, so a source link exists.
        let post = CourseDocument(
            courseID: "8141", course: course.code, kind: .announcement, sourceID: "900",
            title: "Update", url: URL(string: "https://canvas.upenn.edu/courses/8141/discussion_topics/900"),
            text: "body", fetchedAt: date("2026-11-01T00:00:00Z")
        )
        var knowledge = CourseKnowledgeBase()
        knowledge.documents = [post]
        state.courseKnowledge = knowledge
        return (state, store, facts, defaults)
    }

    private func wire(
        _ seq: Int, _ type: CourseFactWire.FactType, target: String? = "55", title: String? = nil,
        dueAt: Date? = nil, kind: CourseFactWire.Kind? = nil,
        confidence: CourseFactWire.Confidence = .high, hash: String = "h1"
    ) -> CourseFactWire {
        CourseFactWire(
            seq: seq, courseID: "8141", documentID: documentID, contentHash: hash, type: type,
            target: target, title: title, dueAt: dueAt, kind: kind, quote: "the instructor said so",
            confidence: confidence, postedAt: date("2026-11-04T09:00:00Z")
        )
    }

    private func rebuild(_ state: AppState) { state.rebuildDashboardItemsForTesting(now: now) }

    private func viewModel(_ state: AppState) -> DashboardViewModel {
        let vm = DashboardViewModel()
        vm.bind(to: state)
        vm.reload()
        return vm
    }

    private func titles(_ sections: [DashSection]) -> [String] { sections.flatMap(\.items).map(\.assignment.title) }

    private func ledgerRow(_ store: AssignmentStore, _ sourceID: String) -> StoredAssignment? {
        store.allRowsForTesting().first { $0.sourceID == sourceID }
    }

    // MARK: Cancel

    @Test("a high-confidence cancel leaves todo, stays in all as cancelled, and the ledger row is untouched")
    func cancelHidesFromTodoOnly() throws {
        let (state, store, _, _) = try makeState([feedRow("55", title: "Quiz 4"), feedRow("56", title: "Other")])
        rebuild(state)
        #expect(titles(viewModel(state).todoSections(now: now)).contains("Quiz 4"))

        state.ingestFacts([wire(1, .cancel)], cursor: 1, now: now)
        rebuild(state)
        let vm = viewModel(state)
        #expect(!titles(vm.todoSections(now: now)).contains("Quiz 4"))
        #expect(titles(vm.todoSections(now: now)).contains("Other"))
        let card = try #require(vm.allSections(now: now).flatMap(\.items).first { $0.assignment.title == "Quiz 4" })
        #expect(card.caveatText?.contains("cancelled") == true)
        #expect(!card.isCompleted)
        let row = try #require(ledgerRow(store, "event-assignment-55"))
        #expect(!row.userCompleted)
        #expect(!row.isGoneFromFeed)
        // No reminder for it, and not "next due" in the widget.
        #expect(!state.widgetNextDueItems().contains { $0.title == "Quiz 4" })
    }

    @Test("rejecting a cancel brings the card back to todo")
    func undoCancel() throws {
        let (state, _, _, _) = try makeState([feedRow("55", title: "Quiz 4")])
        state.ingestFacts([wire(1, .cancel)], cursor: 1, now: now)
        rebuild(state)
        let factID = AppliedFact.factID(documentID: documentID, seq: 1)
        #expect(state.factDisplay.values.first?.factIDs == [factID])

        state.rejectFact(factID: factID, now: now)
        let vm = viewModel(state)
        #expect(titles(vm.todoSections(now: now)).contains("Quiz 4"))
        #expect(state.factDisplay.isEmpty)
        // Listed as undone, plainly.
        #expect(state.factChangeGroups.contains { $0.isUndone && $0.rows.first?.word == "undone" })
    }

    @Test("a medium-confidence cancel is not applied and goes to the review list")
    func mediumCancelNeedsReview() throws {
        let (state, _, _, _) = try makeState([feedRow("55", title: "Quiz 4")])
        state.ingestFacts([wire(1, .cancel, confidence: .medium)], cursor: 1, now: now)
        rebuild(state)
        #expect(titles(viewModel(state).todoSections(now: now)).contains("Quiz 4"))
        #expect(state.factDisplay.isEmpty)
        let review = try #require(state.factReviewRows.first)
        #expect(review.courseCode == course.code)
        #expect(review.quote == "the instructor said so")
        #expect(review.url == URL(string: "https://canvas.upenn.edu/courses/8141/discussion_topics/900"))
        #expect(state.appliedFactKeys.isEmpty)
    }

    // MARK: Reschedule

    @Test("a reschedule moves the card and keeps the original date for display")
    func rescheduleMoves() throws {
        let (state, store, _, _) = try makeState([feedRow("55", title: "PSet 3", due: "2026-11-06T17:00:00Z")])
        let moved = date("2026-11-20T17:00:00Z")
        state.ingestFacts([wire(1, .reschedule, dueAt: moved)], cursor: 1, now: now)
        rebuild(state)
        let vm = viewModel(state)
        #expect(!titles(vm.todoSections(now: now)).contains("PSet 3"))
        let card = try #require(vm.allSections(now: now).flatMap(\.items).first { $0.assignment.title == "PSet 3" })
        #expect(card.due == moved)
        #expect(card.fact?.movedFrom == date("2026-11-06T17:00:00Z"))
        #expect(card.caveatText?.contains("moved") == true)
        // The ledger keeps what Canvas said.
        let row = try #require(ledgerRow(store, "event-assignment-55"))
        #expect(row.dueAt == date("2026-11-06T17:00:00Z"))
    }

    @Test("a student's own date edit beats a reschedule")
    func studentEditBeatsReschedule() throws {
        let item = feedRow("55", title: "PSet 3", due: "2026-11-06T17:00:00Z")
        let (state, _, _, _) = try makeState([item])
        let mine = date("2026-11-07T17:00:00Z")
        state.setDueDateEdit(mine, for: item)
        state.ingestFacts([wire(1, .reschedule, dueAt: date("2026-11-20T17:00:00Z"))], cursor: 1, now: now)
        rebuild(state)
        let card = try #require(viewModel(state).items.first { $0.assignment.title == "PSet 3" })
        #expect(card.due == mine)
        #expect(card.fact == nil)
    }

    // MARK: New tasks

    @Test("a new_task creates exactly one announcement row, and a second rebuild creates no duplicate")
    func newTaskOnce() throws {
        let (state, store, _, _) = try makeState([feedRow("55", title: "PSet 3")])
        state.ingestFacts([wire(1, .newTask, target: nil, title: "Bring a calculator form",
                                dueAt: date("2026-11-06T20:00:00Z"), kind: .submission)], cursor: 1, now: now)
        rebuild(state)
        rebuild(state)
        let sourceID = FactApplication.taskSourceID(documentID: documentID, seq: 1)
        let rows = store.allRowsForTesting().filter { $0.sourceID == sourceID }
        #expect(rows.count == 1)
        #expect(rows.first?.sourceRaw == Assignment.Source.canvasAnnouncement.rawValue)
        let vm = viewModel(state)
        let card = try #require(vm.items.first { $0.assignment.title == "Bring a calculator form" })
        #expect(card.caveatText == "from announcements")
        #expect(card.fact?.factIDs == [AppliedFact.factID(documentID: documentID, seq: 1)])
        #expect(titles(vm.todoSections(now: now)).contains("Bring a calculator form"))
    }

    @Test("undoing a new_task hides its row and keeps it in the ledger")
    func undoNewTask() throws {
        let (state, store, _, _) = try makeState([])
        state.ingestFacts([wire(1, .newTask, target: nil, title: "Extra reading",
                                dueAt: date("2026-11-06T20:00:00Z"), kind: .submission)], cursor: 1, now: now)
        rebuild(state)
        #expect(viewModel(state).items.contains { $0.assignment.title == "Extra reading" })

        state.rejectFact(factID: AppliedFact.factID(documentID: documentID, seq: 1), now: now)
        let vm = viewModel(state)
        #expect(!vm.items.contains { $0.assignment.title == "Extra reading" })
        #expect(ledgerRow(store, FactApplication.taskSourceID(documentID: documentID, seq: 1)) != nil)
        // And a rebuild does not write it again or bring it back.
        rebuild(state)
        #expect(!viewModel(state).items.contains { $0.assignment.title == "Extra reading" })
        #expect(store.allRowsForTesting().filter { $0.sourceID.hasPrefix("fact-") }.count == 1)
    }

    @Test("announcement presence never judges a fact row: its sourceID is not an announcement find")
    func presenceSkipsFactRows() {
        let sourceID = FactApplication.taskSourceID(documentID: documentID, seq: 1)
        #expect(sourceID.hasPrefix(AppState.factRowPrefix))
        // `reconcileAnnouncementPresence` only flags rows this parses; a nil
        // here is why a fact row is never marked gone.
        #expect(AnnouncementRecord.announcementID(fromFindSourceID: sourceID) == nil)
        let row = Assignment(source: .canvasAnnouncement, sourceID: sourceID, kind: .assignment,
                             course: course.code, title: "x", dueAt: nil, url: nil)
        #expect(AppState.isFactRow(row))
    }

    // MARK: Sync

    @Test("a stale document hash removes its facts once the local copy is the newer revision")
    func staleRevisionPruned() throws {
        let (state, _, facts, _) = try makeState([feedRow("55", title: "Quiz 4")])
        state.ingestFacts([wire(1, .cancel, hash: "old-hash")], cursor: 1, now: now)
        #expect(state.courseKnowledge.documents.first?.contentHash != "old-hash")
        // The phone's copy was fetched BEFORE the fact arrived: it is the older
        // revision, so the fact is kept for the next sync.
        #expect(state.pruneStaleFacts() == 0)
        #expect(facts.all().count == 1)
        // Re-fetched after the fact arrived: now the old revision's fact goes.
        var knowledge = state.courseKnowledge
        let post = try #require(knowledge.documents.first)
        knowledge.documents = [CourseDocument(
            courseID: post.courseID, course: post.course, kind: post.kind, sourceID: post.sourceID,
            title: post.title, url: post.url, text: "edited body", fetchedAt: now.addingTimeInterval(3_600)
        )]
        state.courseKnowledge = knowledge
        #expect(state.pruneStaleFacts() == 1)
        #expect(facts.all().isEmpty)
        rebuild(state)
        #expect(titles(viewModel(state).todoSections(now: now)).contains("Quiz 4"))
    }

    @Test("new-revision facts survive a sync whose document download left the local copy old")
    func newRevisionFactsSurviveStaleLocalDocument() throws {
        let (state, _, facts, _) = try makeState([feedRow("55", title: "Quiz 4")])
        let manifest = SyncManifestResponse(facts: [wire(1, .cancel, hash: "new-revision")], factsCursor: 1)
        state.receiveManifestFacts(manifest, now: now)
        #expect(facts.all().count == 1)
        #expect(state.factsSinceForRequest() == 1)
        #expect(!titles(viewModel(state).todoSections(now: now)).contains("Quiz 4"))
    }

    @Test("the cursor advances only when nothing failed and every fact is held")
    func cursorRule() {
        let w = [wire(4, .note, title: "x")]
        let held: Set<String> = [AppliedFact.factID(documentID: documentID, seq: 4)]
        #expect(AppState.mayAdvanceFactsCursor(savesFailed: 0, readsFailed: 0, wires: w, stored: held))
        #expect(!AppState.mayAdvanceFactsCursor(savesFailed: 1, readsFailed: 0, wires: w, stored: held))
        #expect(!AppState.mayAdvanceFactsCursor(savesFailed: 0, readsFailed: 1, wires: w, stored: held))
        #expect(!AppState.mayAdvanceFactsCursor(savesFailed: 0, readsFailed: 0, wires: w, stored: []))
    }

    // MARK: Canvas's section date beats prose

    @Test("a reschedule equal to Canvas's section date is redundant; a differing one is listed for review")
    func sectionDateBeatsFact() throws {
        let item = feedRow("55", title: "PSet 3", due: "2026-11-06T17:00:00Z")
        let (state, _, _, _) = try makeState([item])
        let sectionDate = date("2026-11-07T17:00:00Z")
        state.structuredDueOverrides[item.id] = sectionDate

        // Equal: nothing applied, nothing listed.
        state.ingestFacts([wire(1, .reschedule, dueAt: sectionDate)], cursor: 1, now: now)
        rebuild(state)
        #expect(state.factDisplay.isEmpty)
        #expect(state.factReviewRows.isEmpty)

        // Differing: listed, card date unchanged.
        state.ingestFacts([wire(2, .reschedule, dueAt: date("2026-11-20T17:00:00Z"), hash: "h2")], cursor: 2, now: now)
        rebuild(state)
        #expect(state.factDisplay.isEmpty)
        #expect(state.factReviewRows.map(\.id) == [AppliedFact.factID(documentID: documentID, seq: 2)])
        let card = try #require(viewModel(state).items.first { $0.assignment.title == "PSet 3" })
        #expect(card.due == sectionDate)
    }

    @Test("a fact of the document's current hash is kept")
    func currentRevisionKept() throws {
        let (state, _, facts, _) = try makeState([feedRow("55", title: "Quiz 4")])
        let hash = try #require(state.courseKnowledge.documents.first?.contentHash)
        state.ingestFacts([wire(1, .cancel, hash: hash)], cursor: 1, now: now)
        #expect(state.pruneStaleFacts() == 0)
        #expect(facts.all().count == 1)
    }

    @Test("the stored cursor never moves backwards, ignores nil, and never passes 2^53")
    func cursorBounds() throws {
        let (state, _, _, defaults) = try makeState([feedRow("55", title: "Quiz 4")])
        let key = AppState.FactKey.cursor
        state.ingestFacts([wire(10, .note, title: "a")], cursor: 10, now: now)
        #expect(defaults.object(forKey: key) as? Int == 10)
        state.ingestFacts([wire(3, .note, title: "b")], cursor: 3, now: now)
        #expect(defaults.object(forKey: key) as? Int == 10, "never backwards")
        state.ingestFacts([wire(4, .note, title: "c")], cursor: nil, now: now)
        #expect(defaults.object(forKey: key) as? Int == 10, "a nil cursor moves nothing")
        state.ingestFacts([wire(5, .note, title: "d")], cursor: CourseFactWire.maxSeq + 1, now: now)
        #expect(defaults.object(forKey: key) as? Int == 10, "out of range is ignored")
        state.ingestFacts([wire(6, .note, title: "e")], cursor: Int.max, now: now)
        #expect(defaults.object(forKey: key) as? Int == 10)
        state.ingestFacts([wire(7, .note, title: "f")], cursor: CourseFactWire.maxSeq, now: now)
        #expect(defaults.object(forKey: key) as? Int == CourseFactWire.maxSeq)
    }

    @Test("disconnect purges the facts and the cursor")
    func purgeOnDisconnect() throws {
        let (state, _, facts, defaults) = try makeState([feedRow("55", title: "Quiz 4")])
        state.ingestFacts([wire(1, .cancel)], cursor: 9, now: now)
        rebuild(state)
        #expect(defaults.object(forKey: AppState.FactKey.cursor) as? Int == 9)
        state.clearAppliedFacts()
        #expect(facts.all().isEmpty)
        #expect(defaults.object(forKey: AppState.FactKey.cursor) == nil)
        #expect(state.factDisplay.isEmpty)
        #expect(state.factsSinceForRequest() == nil)
    }

    @Test("the manifest request carries factsSince once a cursor is persisted")
    func requestCarriesCursor() throws {
        let (state, _, _, defaults) = try makeState([])
        #expect(state.makeSyncManifestRequest(courses: [course], documents: []).factsSince == nil)
        state.ingestFacts([wire(3, .note, title: "fyi")], cursor: 12, now: now)
        #expect(defaults.object(forKey: AppState.FactKey.cursor) as? Int == 12)
        #expect(state.makeSyncManifestRequest(courses: [course], documents: []).factsSince == 12)
        // A smaller cursor never moves it back.
        state.ingestFacts([], cursor: 5, now: now)
        #expect(state.factsSinceForRequest() == 12)
    }

    // MARK: Megaphone

    @Test("applied facts are grouped by item, count toward the badge, and read once opened")
    func megaphoneGroupsAndBadge() throws {
        let (state, _, _, _) = try makeState([feedRow("55", title: "Quiz 4")])
        state.ingestFacts([wire(1, .cancel), wire(2, .note, title: "bring ID")], cursor: 2, now: now)
        rebuild(state)
        let group = try #require(state.factChangeGroups.first)
        #expect(group.title == "Quiz 4")
        #expect(group.rows.map(\.word).sorted() == ["cancelled", "changed"])
        #expect(group.url == URL(string: "https://canvas.upenn.edu/courses/8141/discussion_topics/900"))
        #expect(state.appliedFactKeys.count == 2)
        #expect(AnnouncementReadState.unreadCount(finds: [], records: [], seen: [], facts: state.appliedFactKeys) == 2)
        #expect(AnnouncementReadState.unreadCount(
            finds: [], records: [], seen: Set(state.appliedFactKeys), facts: state.appliedFactKeys) == 0)
        let ids = AnnouncementReadState.newIDs(finds: [], records: [], seen: [], facts: state.appliedFactKeys)
        #expect(ids.contains(AnnouncementReadState.factKey(AppliedFact.factID(documentID: documentID, seq: 1))))
    }

    @Test("a note shows its quote, truncated to one line, on the card")
    func noteDetail() throws {
        let long = String(repeating: "word ", count: 60)
        #expect(AppState.oneLineQuote(long).count <= AppState.factQuoteLimit)
        #expect(AppState.oneLineQuote("a\n  b") == "a b")
        let (state, _, _, _) = try makeState([feedRow("55", title: "Quiz 4")])
        state.ingestFacts([wire(1, .note, title: nil)], cursor: 1, now: now)
        rebuild(state)
        let card = try #require(viewModel(state).items.first { $0.assignment.title == "Quiz 4" })
        #expect(card.fact?.details.first?.text == "the instructor said so")
        #expect(card.fact?.details.first?.postURL != nil)
        #expect(card.caveatText == "changed")
    }

    // MARK: Invariant

    @Test("the engine's cancel never completes the item")
    func cancelNeverCompletes() throws {
        let (state, store, _, _) = try makeState([feedRow("55", title: "Quiz 4")])
        state.ingestFacts([wire(1, .cancel)], cursor: 1, now: now)
        rebuild(state)
        #expect(!state.isCompleted(feedRow("55", title: "Quiz 4")))
        #expect(store.allRowsForTesting().allSatisfy { !$0.userCompleted })
    }
}
