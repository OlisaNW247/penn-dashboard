import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// The applier for Canvas's structured sources (`AppState+StructuredSources`).
/// The fetch is a canned `RunResult` handed to `applyStructuredSources`, so no
/// network is touched. Everything uses scratch defaults, an in-memory ledger
/// and a pinned clock; nothing here writes the shared `UserDefaults` domain.
@MainActor
@Suite("Structured Canvas sources: applied to the ledger")
struct StructuredSourcesWiringTests {
    private let course = CourseSummary(
        courseID: "7", code: "STRW 0151", name: "Structured wiring",
        url: URL(string: "https://canvas.upenn.edu/courses/7"), section: nil
    )
    private let now = ISO8601DateFormatter().date(from: "2026-11-05T12:00:00Z")!
    private func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    private func feedRow(_ assignmentID: String, title: String, due: String = "2026-11-25T17:00:00Z") -> Assignment {
        Assignment(
            source: .canvas, sourceID: "event-assignment-\(assignmentID)", kind: .assignment,
            course: course.code, title: title, dueAt: date(due),
            url: URL(string: "https://canvas.upenn.edu/courses/7/assignments/\(assignmentID)")
        )
    }

    private func makeState(_ seed: [Assignment]) throws -> (AppState, AssignmentStore, UserDefaults) {
        let suite = "StructuredSourcesWiringTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let store = try AssignmentStore(inMemory: true)
        store.upsert(seed)
        let state = AppState(assignmentStore: store, dueDateEditsDefaults: defaults)
        state.forceFixtureDataForTesting(false)
        state.structuredDefaults = defaults
        state.structuredSourcesCoursesForTesting = [course]
        return (state, store, defaults)
    }

    private func run(
        planner: [CanvasPlannerItem] = [],
        modules: [CanvasStructuredModule] = [],
        assignments: [CanvasOverrideAssignment] = [],
        assignmentsComplete: Bool = false,
        sessionExpired: Bool = false
    ) -> CanvasStructuredSourcesClient.RunResult {
        var result = CanvasStructuredSourcesClient.RunResult()
        var c = CanvasStructuredSourcesClient.CourseResult(courseID: "7")
        c.modules = modules
        c.assignments = assignments
        if assignmentsComplete { c.completedEndpoints = [.assignments] }
        result.courses = [c]
        result.planner = planner
        result.sessionExpired = sessionExpired
        return result
    }

    private func shown(_ state: AppState) -> [Assignment] {
        (state.assignments + state.laterAssignments + state.assessments).filter { $0.course == course.code }
    }

    private func titles(_ state: AppState) -> [String] { shown(state).map(\.title) }

    private func rebuild(_ state: AppState) { state.rebuildDashboardItemsForTesting(now: now) }

    // MARK: Rows

    @Test("a module-only assignment shows on the dashboard as a .canvasModules row")
    func moduleOnlyAssignment() throws {
        let (state, _, _) = try makeState([feedRow("55", title: "Feed PSet")])
        state.applyStructuredSources(run: run(modules: [
            .init(id: "1", name: "W1", items: [
                .init(id: "11", type: "Assignment", contentID: "99", title: "Module-only essay",
                      dueAt: date("2026-11-28T17:00:00Z")),
            ]),
        ]), courses: [course])
        rebuild(state)
        let card = try #require(shown(state).first { $0.title == "Module-only essay" })
        #expect(card.source == .canvasModules)
        #expect(titles(state).contains("Feed PSet"))
    }

    @Test("applying twice refreshes a row by id and never duplicates it")
    func noDuplicates() throws {
        let (state, store, _) = try makeState([])
        let r = run(modules: [.init(id: "1", name: "W1", items: [
            .init(id: "11", type: "Assignment", contentID: "99", title: "Essay", dueAt: date("2026-11-28T17:00:00Z")),
        ])])
        state.applyStructuredSources(run: r, courses: [course])
        state.applyStructuredSources(run: r, courses: [course])
        #expect(store.allRowsForTesting().filter { $0.sourceID == "module-item-11" }.count == 1)
    }

    @Test("an existing .canvasModules reading is not retired by the apply")
    func readingSurvives() throws {
        let reading = Assignment(
            source: .canvasModules, sourceID: "module-item-500", kind: .event, course: course.code,
            title: "Read ch. 4", dueAt: date("2026-11-20T17:00:00Z"), url: nil
        )
        let (state, store, _) = try makeState([reading])
        state.applyStructuredSources(run: run(modules: [.init(id: "1", name: "W1", items: [
            .init(id: "11", type: "Assignment", contentID: "99", title: "Essay", dueAt: date("2026-11-28T17:00:00Z")),
        ])]), courses: [course])
        let row = try #require(store.allRowsForTesting().first { $0.sourceID == "module-item-500" })
        #expect(!row.isGoneFromFeed)
        #expect(store.assignments(source: .canvasModules).contains { $0.sourceID == "module-item-500" })
    }

    // MARK: Completions and dismissals

    @Test("planner marked_complete shows the feed card as done and never sets userCompleted")
    func plannerComplete() throws {
        let (state, store, _) = try makeState([feedRow("55", title: "Ticked in Canvas"), feedRow("56", title: "Open")])
        rebuild(state)
        #expect(titles(state).contains("Ticked in Canvas"))
        state.applyStructuredSources(run: run(planner: [
            .init(plannableType: "assignment", plannableID: "55", courseID: "7", markedComplete: true),
        ]), courses: [course])
        rebuild(state)
        #expect(!titles(state).contains("Ticked in Canvas"))
        #expect(titles(state).contains("Open"))
        let row = try #require(store.allRowsForTesting().first { $0.sourceID == "event-assignment-55" })
        #expect(!row.userCompleted)
        // It is in prev.
        let vm = DashboardViewModel()
        vm.bind(to: state)
        let done = vm.doneSections(now: now).flatMap(\.items).map(\.assignment.title)
        #expect(done.contains("Ticked in Canvas"))
    }

    @Test("a module requirement met on a module-only quiz completes it by source id")
    func moduleRequirementBySource() throws {
        let (state, _, _) = try makeState([])
        state.applyStructuredSources(run: run(modules: [.init(id: "1", name: "W1", items: [
            .init(id: "21", type: "Quiz", contentID: "5", title: "Quiz 1", completionRequirementType: "must_submit", completionCompleted: true,
                  dueAt: date("2026-11-26T17:00:00Z")),
        ])]), courses: [course])
        rebuild(state)
        #expect(!titles(state).contains("Quiz 1"))
    }

    // MARK: Undoing a Canvas-derived completion

    /// A run that read everything in full, so Canvas's silence means something.
    private func fullRun(planner: [CanvasPlannerItem]) -> CanvasStructuredSourcesClient.RunResult {
        var r = run(planner: planner)
        r.plannerCompleted = true
        r.missingCompleted = true
        r.courses[0].completedEndpoints = [.modules, .assignments]
        return r
    }

    private func tick(_ id: String = "55") -> CanvasPlannerItem {
        .init(plannableType: "assignment", plannableID: id, courseID: "7", markedComplete: true)
    }

    @Test("marking a Canvas-ticked card active lasts: the next rebuild and the same planner tick do not re-complete it")
    func unTickLasts() throws {
        let (state, _, _) = try makeState([feedRow("55", title: "Ticked in Canvas")])
        state.applyStructuredSources(run: fullRun(planner: [tick()]), courses: [course], now: now)
        rebuild(state)
        #expect(!titles(state).contains("Ticked in Canvas"))

        let card = feedRow("55", title: "Ticked in Canvas")
        state.markActive(card)
        #expect(state.structuredCompletionOverrides.contains(card.id))
        #expect(titles(state).contains("Ticked in Canvas"))

        rebuild(state)
        state.applyStructuredSources(run: fullRun(planner: [tick()]), courses: [course], now: now)
        rebuild(state)
        #expect(titles(state).contains("Ticked in Canvas"))
        #expect(!state.isCompleted(card))
        // The override is persisted beside the set.
        #expect(Set(state.structuredDefaults?.stringArray(forKey: "structuredCompletionOverridesV1") ?? []) == [card.id])
    }

    @Test("completing it yourself afterwards removes the override")
    func ownTickRemovesOverride() throws {
        let (state, _, _) = try makeState([feedRow("55", title: "Ticked in Canvas")])
        state.applyStructuredSources(run: fullRun(planner: [tick()]), courses: [course], now: now)
        rebuild(state)
        let card = feedRow("55", title: "Ticked in Canvas")
        state.markActive(card)
        #expect(state.structuredCompletionOverrides.contains(card.id))
        state.markCompleted(card)
        #expect(state.structuredCompletionOverrides.isEmpty)
        #expect(state.isCompleted(card))
    }

    @Test("a Canvas un-tick seen by a full run retires the completion and any override; a later re-tick completes again")
    func canvasUnTick() throws {
        let (state, _, _) = try makeState([feedRow("55", title: "Ticked in Canvas")])
        state.applyStructuredSources(run: fullRun(planner: [tick()]), courses: [course], now: now)
        let card = feedRow("55", title: "Ticked in Canvas")
        state.markActive(card)
        #expect(state.structuredCompletionOverrides.contains(card.id))

        state.applyStructuredSources(run: fullRun(planner: []), courses: [course], now: now)
        #expect(state.structuredCompletedItemIDs.isEmpty)
        #expect(state.structuredCompletionOverrides.isEmpty)

        state.applyStructuredSources(run: fullRun(planner: [tick()]), courses: [course], now: now)
        #expect(state.isCompleted(card))
    }

    @Test("a partial run, or an item outside the planner window, never drops a completion")
    func partialRunKeepsCompletions() throws {
        let (state, _, _) = try makeState([
            feedRow("55", title: "Ticked in Canvas"),
            feedRow("56", title: "Old tick", due: "2026-09-01T17:00:00Z"),
        ])
        state.applyStructuredSources(run: run(planner: [tick("55"), tick("56")]), courses: [course], now: now)
        #expect(state.structuredCompletedItemIDs.count == 2)

        // Planner unfinished: silence is not a retraction.
        var partial = fullRun(planner: [])
        partial.plannerCompleted = false
        state.applyStructuredSources(run: partial, courses: [course], now: now)
        #expect(state.structuredCompletedItemIDs.count == 2)

        // Modules unfinished for the course: same.
        var noModules = fullRun(planner: [])
        noModules.courses[0].completedEndpoints = [.assignments]
        state.applyStructuredSources(run: noModules, courses: [course], now: now)
        #expect(state.structuredCompletedItemIDs.count == 2)

        // A full run drops the in-window tick, but the 2026-09-01 item is older than the
        // planner's 14-day look-back, so its absence from the answer proves nothing.
        state.applyStructuredSources(run: fullRun(planner: []), courses: [course], now: now)
        #expect(state.structuredCompletedItemIDs.count == 1)
    }

    @Test("a module must_view requirement does not complete the card")
    func mustViewDoesNotComplete() throws {
        let (state, _, _) = try makeState([feedRow("55", title: "Opened only")])
        state.applyStructuredSources(run: run(modules: [.init(id: "1", name: "W1", items: [
            .init(id: "11", type: "Assignment", contentID: "55", title: "Opened only",
                  completionRequirementType: "must_view", completionCompleted: true,
                  dueAt: date("2026-11-25T17:00:00Z")),
        ])]), courses: [course], now: now)
        rebuild(state)
        #expect(titles(state).contains("Opened only"))
        #expect(state.structuredCompletedItemIDs.isEmpty)
    }

    @Test("a dismissed planner item is off todo and all but stays in the ledger")
    func dismissed() throws {
        let (state, store, _) = try makeState([feedRow("55", title: "Dismissed"), feedRow("56", title: "Kept")])
        state.applyStructuredSources(run: run(planner: [
            .init(plannableType: "assignment", plannableID: "55", courseID: "7", dismissed: true),
        ]), courses: [course])
        rebuild(state)
        #expect(!titles(state).contains("Dismissed"))
        #expect(titles(state).contains("Kept"))
        #expect(store.allRowsForTesting().contains { $0.sourceID == "event-assignment-55" && !$0.isGoneFromFeed })
    }

    @Test("a dismissal undone in Canvas brings the card back; a failed planner read keeps it")
    func dismissalReversible() throws {
        let (state, _, _) = try makeState([feedRow("55", title: "Planner hidden")])
        func planner(dismissed: Bool, complete: Bool) -> CanvasStructuredSourcesClient.RunResult {
            var r = run(planner: [.init(plannableType: "assignment", plannableID: "55", courseID: "7", dismissed: dismissed)])
            r.plannerCompleted = complete
            return r
        }
        state.applyStructuredSources(run: planner(dismissed: true, complete: true), courses: [course])
        rebuild(state)
        #expect(!titles(state).contains("Planner hidden"))

        // The planner read failed: nothing was seen, so nothing is forgotten.
        var failed = run()
        failed.plannerCompleted = false
        state.applyStructuredSources(run: failed, courses: [course])
        rebuild(state)
        #expect(!titles(state).contains("Planner hidden"))

        // The planner read finished and the item is no longer dismissed.
        state.applyStructuredSources(run: planner(dismissed: false, complete: true), courses: [course])
        rebuild(state)
        #expect(titles(state).contains("Planner hidden"))
    }

    @Test("a dismissed row the student completed still reaches prev")
    func dismissedButCompleted() throws {
        let (state, _, _) = try makeState([feedRow("55", title: "Both")])
        state.applyStructuredSources(run: run(planner: [
            .init(plannableType: "assignment", plannableID: "55", courseID: "7", markedComplete: true, dismissed: true),
        ]), courses: [course])
        rebuild(state)
        let vm = DashboardViewModel()
        vm.bind(to: state)
        #expect(vm.doneSections(now: now).flatMap(\.items).map(\.assignment.title).contains("Both"))
    }

    // MARK: Section dates

    private func override(_ id: String, to due: String) -> CanvasOverrideAssignment {
        .init(id: id, allDates: [
            .init(dueAt: date("2026-11-25T17:00:00Z"), base: true),
            .init(dueAt: date(due), base: false, title: "Section 401"),
        ])
    }

    @Test("a section all_dates override moves the card's due date")
    func overrideMovesDate() throws {
        let (state, store, _) = try makeState([feedRow("55", title: "PSet")])
        state.applyStructuredSources(run: run(assignments: [override("55", to: "2026-11-27T17:00:00Z")]), courses: [course])
        rebuild(state)
        let card = try #require(shown(state).first { $0.title == "PSet" })
        #expect(state.effectiveDueDate(for: card) == date("2026-11-27T17:00:00Z"))
        // The ledger row keeps the feed's own date.
        let row = try #require(store.allRowsForTesting().first { $0.sourceID == "event-assignment-55" })
        #expect(row.dueAt == date("2026-11-25T17:00:00Z"))
    }

    @Test("a student's manual date edit beats the override, and a later override never replaces it")
    func studentEditWins() throws {
        let (state, _, _) = try makeState([feedRow("55", title: "PSet")])
        let mine = date("2026-11-30T17:00:00Z")
        state.applyStructuredSources(run: run(assignments: [override("55", to: "2026-11-27T17:00:00Z")]), courses: [course])
        rebuild(state)
        var card = try #require(shown(state).first { $0.title == "PSet" })
        state.setDueDateEdit(mine, for: card)
        #expect(state.effectiveDueDate(for: card) == mine)
        // Canvas moves the section date again.
        state.applyStructuredSources(run: run(assignments: [override("55", to: "2026-12-02T17:00:00Z")]), courses: [course])
        rebuild(state)
        card = try #require(shown(state).first { $0.title == "PSet" })
        #expect(state.dueDateEdits[card.id] == mine)
        #expect(state.effectiveDueDate(for: card) == mine)
    }

    @Test("an edit made before the override arrives is kept")
    func editBeforeOverride() throws {
        let (state, _, _) = try makeState([feedRow("55", title: "PSet")])
        rebuild(state)
        let mine = date("2026-12-01T17:00:00Z")
        state.setDueDateEdit(mine, for: try #require(shown(state).first))
        state.applyStructuredSources(run: run(assignments: [override("55", to: "2026-11-27T17:00:00Z")]), courses: [course])
        rebuild(state)
        let card = try #require(shown(state).first)
        #expect(state.effectiveDueDate(for: card) == mine)
    }

    @Test("a fully-read course drops an override Canvas no longer states")
    func overrideRemoved() throws {
        let (state, _, _) = try makeState([feedRow("55", title: "PSet")])
        state.applyStructuredSources(run: run(assignments: [override("55", to: "2026-11-27T17:00:00Z")], assignmentsComplete: true), courses: [course])
        #expect(state.structuredDueOverrides.count == 1)
        state.applyStructuredSources(run: run(assignments: [], assignmentsComplete: true), courses: [course])
        #expect(state.structuredDueOverrides.isEmpty)
    }

    // MARK: Failure modes

    @Test("an expired session applies nothing")
    func sessionExpired() throws {
        let (state, store, _) = try makeState([feedRow("55", title: "PSet")])
        let before = store.allRowsForTesting().count
        let summary = state.applyStructuredSources(run: run(
            planner: [.init(plannableType: "assignment", plannableID: "55", courseID: "7", markedComplete: true, dismissed: true)],
            modules: [.init(id: "1", name: "W1", items: [
                .init(id: "11", type: "Assignment", contentID: "99", title: "Essay", dueAt: date("2026-11-28T17:00:00Z")),
            ])],
            assignments: [override("55", to: "2026-11-27T17:00:00Z")],
            sessionExpired: true
        ), courses: [course])
        #expect(summary.skipped != nil)
        #expect(store.allRowsForTesting().count == before)
        #expect(state.structuredCompletedItemIDs.isEmpty)
        #expect(state.structuredDismissedItemIDs.isEmpty)
        #expect(state.structuredDueOverrides.isEmpty)
    }

    @Test("a run where every endpoint failed leaves the ledger and the sets as they were")
    func failedFetch() throws {
        let (state, store, _) = try makeState([feedRow("55", title: "PSet")])
        state.applyStructuredSources(run: run(assignments: [override("55", to: "2026-11-27T17:00:00Z")]), courses: [course])
        let rowsBefore = store.allRowsForTesting().count
        let overridesBefore = state.structuredDueOverrides
        var failed = CanvasStructuredSourcesClient.RunResult()
        var c = CanvasStructuredSourcesClient.CourseResult(courseID: "7")
        c.failedEndpoints = [.modules, .assignments, .discussionTopics, .pages]
        c.rateLimited = true
        failed.courses = [c]
        failed.rateLimited = true
        state.applyStructuredSources(run: failed, courses: [course])
        rebuild(state)
        #expect(store.allRowsForTesting().count == rowsBefore)
        #expect(state.structuredDueOverrides == overridesBefore)
        #expect(store.allRowsForTesting().allSatisfy { !$0.isGoneFromFeed })
        #expect(titles(state).contains("PSet"))
    }

    @Test("state survives a relaunch through the scratch defaults")
    func persistence() throws {
        let (state, _, defaults) = try makeState([feedRow("55", title: "PSet")])
        state.applyStructuredSources(run: run(
            planner: [.init(plannableType: "assignment", plannableID: "55", courseID: "7", markedComplete: true)],
            assignments: [override("55", to: "2026-11-27T17:00:00Z")]
        ), courses: [course])
        let (next, _, _) = try makeState([])
        next.structuredDefaults = defaults
        next.loadStructuredState()
        #expect(next.structuredCompletedItemIDs == state.structuredCompletedItemIDs)
        #expect(next.structuredDueOverrides == state.structuredDueOverrides)
        #expect(defaults.string(forKey: "lastStructuredSourcesSyncSummaryV1")?.contains("completions=1") == true)
    }
}
