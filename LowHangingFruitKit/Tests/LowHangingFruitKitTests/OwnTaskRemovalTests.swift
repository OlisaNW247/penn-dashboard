import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// Which removal an opened card offers, as a pure rule, and the words it uses.
/// A student's own one-off task is deleted; an occurrence of a recurring task
/// stops repeating (deleting one would just be re-minted by its rule); nothing
/// from a feed, and nothing in preview or demo data, offers either.
@Suite("Which removal a card offers")
struct OwnTaskRemovalRuleTests {
    private func assignment(
        _ source: Assignment.Source,
        sourceID: String
    ) -> Assignment {
        Assignment(source: source, sourceID: sourceID, kind: .assignment,
                   course: "OWNRULE 0001", title: "Rule probe", dueAt: nil, url: nil)
    }

    private func firstOccurrence(of origin: RecurringTask.Origin) throws -> (RecurringTask, Assignment) {
        let task = RecurringTask(title: "Rule probe", course: "OWNRULE 0001", weekday: 3, hour: 23,
                                 minute: 59, startDate: Date(), endDate: nil, origin: origin)
        return (task, try #require(task.upcomingAssignments().first))
    }

    @Test("a student's one-off task offers delete")
    func oneOffOffersDelete() {
        let task = ManualAssignment(title: "Rule probe", course: "OWNRULE 0001", dueAt: nil)
        #expect(OwnTaskRemoval.offered(for: task.asAssignment(), isUsingFixtureData: false)
                == .deleteTask(id: task.id))
    }

    @Test("an occurrence of a recurring task offers stop repeating, whoever suggested the task")
    func occurrenceOffersStopRepeating() throws {
        for origin in [RecurringTask.Origin.manual, .canvasSyllabus, .canvasAnnouncement] {
            let (task, occurrence) = try firstOccurrence(of: origin)
            #expect(OwnTaskRemoval.offered(for: occurrence, isUsingFixtureData: false)
                    == .stopRepeating(taskID: task.id), "\(origin)")
        }
    }

    @Test("feed items offer nothing, even one whose id happens to look like an occurrence")
    func feedItemsOfferNothing() {
        let lookalike = "\(UUID().uuidString)-1790000000"
        for source in [Assignment.Source.canvas, .gradescope, .canvasModules, .canvasAnnouncement] {
            for sourceID in ["12345", "event-assignment-678", lookalike] {
                #expect(OwnTaskRemoval.offered(for: assignment(source, sourceID: sourceID),
                                               isUsingFixtureData: false) == nil,
                        "\(source) \(sourceID)")
            }
        }
    }

    @Test("a manual item that is neither a one-off nor an occurrence offers nothing")
    func unrecognisedManualOffersNothing() {
        for sourceID in ["whatever", "manual-not-a-uuid", UUID().uuidString, "\(UUID().uuidString)-x"] {
            #expect(OwnTaskRemoval.offered(for: assignment(.manual, sourceID: sourceID),
                                           isUsingFixtureData: false) == nil, "\(sourceID)")
        }
    }

    @Test("preview and demo data offer nothing, for either kind of task")
    func fixtureDataOffersNothing() throws {
        let task = ManualAssignment(title: "Rule probe", course: "OWNRULE 0001", dueAt: nil)
        let (_, occurrence) = try firstOccurrence(of: .manual)
        #expect(OwnTaskRemoval.offered(for: task.asAssignment(), isUsingFixtureData: true) == nil)
        #expect(OwnTaskRemoval.offered(for: occurrence, isUsingFixtureData: true) == nil)
    }

    @Test("the words are the short ones")
    func words() {
        let id = UUID()
        #expect(OwnTaskRemoval.deleteTask(id: id).buttonLabel == "delete")
        #expect(OwnTaskRemoval.deleteTask(id: id).confirmationTitle == "delete this task?")
        #expect(OwnTaskRemoval.deleteTask(id: id).confirmLabel == "delete")
        #expect(OwnTaskRemoval.deleteTask(id: id).accessibilityLabel == "delete task")
        #expect(OwnTaskRemoval.stopRepeating(taskID: id).buttonLabel == "stop repeating")
        #expect(OwnTaskRemoval.stopRepeating(taskID: id).confirmationTitle == "stop repeating?")
        #expect(OwnTaskRemoval.stopRepeating(taskID: id).confirmLabel == "stop")
        #expect(OwnTaskRemoval.stopRepeating(taskID: id).accessibilityLabel == "stop repeating task")
        #expect(OwnTaskRemoval.cancelLabel == "cancel")
    }
}

/// Deleting a one-off task and stopping a recurring one, end to end through the
/// view model and `AppState`: where it disappears, what is kept, what a
/// relaunch brings back.
///
/// **How this stays out of the shared domain.** Removing a task writes the
/// recurring-task or one-off blob, and an edited due date is cleared from its
/// store; written to `UserDefaults.lhf`, either would be read back by the
/// `AppState.init` of every suite running alongside. Every state here is built
/// with `dueDateEditsDefaults:` and `ownTasksDefaults:` over one scratch suite,
/// deleted afterwards, so nothing in this file writes the shared domain. A
/// relaunch is a new `AppState` over the same ledger and the same suite, which
/// is all a relaunch preserves. Assertions are scoped to this suite's own
/// course and titles.
@MainActor
@Suite("Removing the student's own tasks")
struct OwnTaskRemovalTests {
    private static let course = "OWNTASK 0001"

    @MainActor
    private struct Harness {
        private(set) var state: AppState
        private(set) var store: AssignmentStore
        let defaults: UserDefaults
        private let suite: String
        private let storeURL: URL?

        /// `onDisk` opens the ledger as a file, which is what the app does: one-off
        /// tasks then live on the ledger. In memory is the fallback the app takes
        /// when the App Group is missing, where the defaults blob is the durable
        /// copy instead. Both paths exist, so both are tested.
        init(onDisk: Bool = false) throws {
            suite = "lhf.own-task-removal.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suite)!
            if onDisk {
                let url = URL(fileURLWithPath: NSTemporaryDirectory())
                    .appendingPathComponent("lhf-own-task-\(UUID().uuidString).store")
                storeURL = url
                store = try AssignmentStore(url: url)
            } else {
                storeURL = nil
                store = try AssignmentStore(inMemory: true)
            }
            state = AppState(assignmentStore: store, dueDateEditsDefaults: defaults,
                             ownTasksDefaults: defaults)
            // Pinned per instance, as `DueDateEditTests` does: the persisted preview
            // flag is in the shared domain, where another suite can flip it.
            state.forceFixtureDataForTesting(false)
        }

        func tearDown() {
            defaults.removePersistentDomain(forName: suite)
            if let storeURL {
                for suffix in ["", "-wal", "-shm"] {
                    try? FileManager.default.removeItem(atPath: storeURL.path + suffix)
                }
            }
        }

        mutating func relaunch() throws {
            if let storeURL { store = try AssignmentStore(url: storeURL) }
            state = AppState(assignmentStore: store, dueDateEditsDefaults: defaults,
                             ownTasksDefaults: defaults)
            state.forceFixtureDataForTesting(false)
        }

        /// What is stored under the recurring-task key right now.
        var storedRecurringTasks: [RecurringTask] {
            guard let data = defaults.data(forKey: "recurringTasks") else { return [] }
            return (try? JSONDecoder().decode([RecurringTask].self, from: data)) ?? []
        }

        /// What is stored under the one-off key right now (the in-memory fallback's copy).
        var storedOneOffs: [ManualAssignment] {
            guard let data = defaults.data(forKey: "manualAssignments") else { return [] }
            return (try? JSONDecoder().decode([ManualAssignment].self, from: data)) ?? []
        }

        var storedEdits: [String: Date] { DueDateEditStore(defaults: defaults).load() }
    }

    // MARK: Fixtures

    /// A one-off task due in 36 hours: inside both the todo window (48h) and the
    /// all window (7d), and far enough out for a reminder to be planned.
    private func oneOff(_ title: String, due: Date = Date().addingTimeInterval(36 * 3_600)) -> ManualAssignment {
        ManualAssignment(title: title, course: Self.course, dueAt: due)
    }

    /// A weekly task whose first occurrence is tomorrow at 23:59, started a
    /// month ago. About ten occurrences fall inside the generator's horizon.
    private func weekly(_ title: String, origin: RecurringTask.Origin = .manual) -> RecurringTask {
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        return RecurringTask(
            title: title, course: Self.course,
            weekday: Calendar.current.component(.weekday, from: tomorrow), hour: 23, minute: 59,
            startDate: Date().addingTimeInterval(-30 * 86_400), endDate: nil, origin: origin)
    }

    private func titles(_ sections: [DashSection]) -> [String] {
        sections.flatMap(\.items).map(\.assignment.title)
    }

    private func card(_ vm: DashboardViewModel, titled title: String) throws -> DashItem {
        try #require(vm.items.first { $0.assignment.title == title && !$0.isCompleted })
    }

    /// Reminders plan from the view model's items, so this is the reminder plan
    /// the dashboard would hand the scheduler. Identifiers carry the assignment id.
    private func reminderIdentifiers(_ vm: DashboardViewModel) -> [String] {
        let scratch = "lhf.own-task-removal.reminders.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: scratch)!
        defer { defaults.removePersistentDomain(forName: scratch) }
        return NotificationScheduler(defaults: defaults)
            .plannedRequests(from: vm.items.filter { $0.assignment.course == Self.course },
                             preferences: CoursePreferencesStore(defaults: defaults))
            .map(\.identifier)
    }

    // MARK: Deleting a one-off task

    @Test("deleting a one-off task takes it out of todo, all, the widget and the reminder plan, and it stays gone",
          arguments: [true, false])
    func deleteOneOff(onDisk: Bool) throws {
        var h = try Harness(onDisk: onDisk)
        defer { h.tearDown() }
        let task = oneOff("Own task delete me")
        h.state.addManualAssignment(task)

        let vm = DashboardViewModel()
        vm.bind(to: h.state)
        let shown = try card(vm, titled: task.title)
        #expect(shown.removal == .deleteTask(id: task.id), "the card is offered delete")
        // The assertions below mean something only if it was there to begin with.
        #expect(titles(vm.todoSections()).contains(task.title))
        #expect(titles(vm.allSections()).contains(task.title))
        #expect(h.state.widgetNextDueItems().contains { $0.title == task.title })
        #expect(reminderIdentifiers(vm).contains { $0.contains(task.id.uuidString) })

        vm.removeOwnTask(shown)

        // At once, before AppState's republish reaches the view model.
        #expect(!titles(vm.todoSections()).contains(task.title))
        #expect(!titles(vm.allSections()).contains(task.title))
        #expect(!reminderIdentifiers(vm).contains { $0.contains(task.id.uuidString) })
        // And in AppState, which is what the widget and ask read.
        #expect(!h.state.widgetNextDueItems().contains { $0.title == task.title })
        #expect(!h.state.manualAssignments.contains { $0.id == task.id })
        #expect(!h.state.assignments.contains { $0.title == task.title })
        #expect(!h.state.laterAssignments.contains { $0.title == task.title })
        if onDisk {
            #expect(!h.store.assignments(source: .manual).contains { $0.title == task.title })
        } else {
            #expect(!h.storedOneOffs.contains { $0.id == task.id })
        }

        vm.reload()
        #expect(!titles(vm.allSections()).contains(task.title), "a reload does not bring it back")

        try h.relaunch()
        let after = DashboardViewModel()
        after.bind(to: h.state)
        #expect(!after.items.contains { $0.assignment.title == task.title }, "a relaunch does not either")
        #expect(!h.state.manualAssignments.contains { $0.id == task.id })
    }

    @Test("deleting one one-off task leaves the others, and a recurring task, alone")
    func deleteLeavesTheRest() throws {
        let h = try Harness(onDisk: true)
        defer { h.tearDown() }
        let doomed = oneOff("Own task doomed")
        let kept = oneOff("Own task kept", due: Date().addingTimeInterval(40 * 3_600))
        let repeating = weekly("Own task keeps repeating")
        h.state.addManualAssignment(doomed)
        h.state.addManualAssignment(kept)
        h.state.addRecurringTask(repeating)

        let vm = DashboardViewModel()
        vm.bind(to: h.state)
        vm.removeOwnTask(try card(vm, titled: doomed.title))

        #expect(h.state.manualAssignments.map(\.id) == [kept.id])
        #expect(h.state.recurringTasks.map(\.id) == [repeating.id])
        #expect(vm.items.contains { $0.assignment.title == kept.title })
        #expect(vm.items.contains { $0.assignment.title == repeating.title })
    }

    @Test("a one-off task that was finished and then deleted is gone from prev and from the ledger's completions",
          arguments: [true, false])
    func deleteAfterCompleting(onDisk: Bool) throws {
        var h = try Harness(onDisk: onDisk)
        defer { h.tearDown() }
        let task = oneOff("Own task finished then deleted")
        h.state.addManualAssignment(task)

        let vm = DashboardViewModel()
        vm.bind(to: h.state)
        vm.complete(try card(vm, titled: task.title))
        vm.reload()
        #expect(titles(vm.doneSections()).contains(task.title), "finished work is in prev before it is deleted")
        if onDisk {
            #expect(h.store.completionRecord().ids.contains(task.asAssignment().id))
        }

        // The card has no button once the task is finished (a finished task is
        // in prev, which has none), so this is the call underneath it.
        h.state.removeManualAssignment(id: task.id)
        vm.reload()

        // Deleting a task deletes its record: the task is the thing the student
        // removed, and a ledger row that outlived it would be a completion of
        // nothing. The id is a fresh UUID, so no later task can collide with it.
        #expect(!titles(vm.doneSections()).contains(task.title))
        if onDisk {
            #expect(!h.store.completionRecord().ids.contains(task.asAssignment().id))
        }

        try h.relaunch()
        let after = DashboardViewModel()
        after.bind(to: h.state)
        #expect(!titles(after.doneSections()).contains(task.title))
        #expect(!after.items.contains { $0.assignment.title == task.title })
    }

    @Test("deleting a one-off task clears its edited due date, even when it was the only task")
    func deleteClearsTheEdit() throws {
        let h = try Harness()
        defer { h.tearDown() }
        let task = oneOff("Own task moved then deleted")
        h.state.addManualAssignment(task)
        let moved = Date().addingTimeInterval(5 * 86_400)
        h.state.setDueDateEdit(moved, for: task.asAssignment())
        #expect(h.state.dueDateEdits[task.asAssignment().id] == moved)
        #expect(h.storedEdits[task.asAssignment().id] == moved)

        // No other one-off task is left to keep the manual family "loaded", which
        // is when `pruneDueDateEdits` stops forgetting; the removal has to.
        h.state.removeManualAssignment(id: task.id)

        #expect(h.state.dueDateEdits[task.asAssignment().id] == nil)
        #expect(h.storedEdits[task.asAssignment().id] == nil, "and the persisted copy")
    }

    // MARK: Stopping a recurring task

    @Test("stopping a recurring task removes every future occurrence everywhere, and a relaunch does not bring it back")
    func stopRepeating() throws {
        var h = try Harness()
        defer { h.tearDown() }
        let task = weekly("Own task weekly reading")
        h.state.addRecurringTask(task)
        let occurrences = task.upcomingAssignments()
        #expect(occurrences.count > 5, "a fixture with several weeks to remove")

        let vm = DashboardViewModel()
        vm.bind(to: h.state)
        let shown = try card(vm, titled: task.title)
        #expect(shown.removal == .stopRepeating(taskID: task.id), "the card is offered stop repeating")
        #expect(titles(vm.todoSections()).contains(task.title))
        #expect(titles(vm.allSections()).filter { $0 == task.title }.count == occurrences.count)
        #expect(h.state.widgetNextDueItems().contains { $0.title == task.title })
        #expect(reminderIdentifiers(vm).contains { $0.contains(task.id.uuidString) })
        #expect(h.storedRecurringTasks.map(\.id) == [task.id])

        vm.removeOwnTask(shown)

        // At once: every unfinished occurrence, not only the tapped one.
        #expect(!vm.items.contains { $0.assignment.title == task.title })
        #expect(!titles(vm.todoSections()).contains(task.title))
        #expect(!titles(vm.allSections()).contains(task.title))
        #expect(!reminderIdentifiers(vm).contains { $0.contains(task.id.uuidString) })
        #expect(!h.state.widgetNextDueItems().contains { $0.title == task.title })
        #expect(h.state.recurringTasks.isEmpty)
        #expect(h.storedRecurringTasks.isEmpty, "the rule is gone from the defaults, not only from memory")
        #expect(!(h.state.assignments + h.state.laterAssignments + h.state.assessments)
            .contains { $0.title == task.title })

        vm.reload()
        #expect(!vm.items.contains { $0.assignment.title == task.title })

        try h.relaunch()
        #expect(h.state.recurringTasks.isEmpty, "a relaunch reads no rule back")
        let after = DashboardViewModel()
        after.bind(to: h.state)
        #expect(!after.items.contains { $0.assignment.title == task.title })
    }

    @Test("occurrences the student already finished stay on the ledger when their task is stopped, and survive a relaunch")
    func finishedOccurrencesSurvive() throws {
        var h = try Harness(onDisk: true)
        defer { h.tearDown() }
        let task = weekly("Own task finished weekly")
        h.state.addRecurringTask(task)
        let occurrences = task.upcomingAssignments()
        let finished = occurrences[0]
        let untouched = occurrences[1]

        let vm = DashboardViewModel()
        vm.bind(to: h.state)
        vm.complete(try #require(vm.items.first { $0.id == finished.id }))
        #expect(h.store.completionRecord().ids.contains(finished.id))
        let completedAt = try #require(h.store.completionRecord().dates[finished.id])

        vm.removeOwnTask(try #require(vm.items.first { $0.id == untouched.id }))

        // The record is the ledger's, not the task's, and stopping the task
        // touches only the task.
        #expect(h.state.isCompleted(finished))
        #expect(h.store.completionRecord().ids.contains(finished.id))
        #expect(h.store.completionRecord().dates[finished.id] == completedAt)
        #expect(!h.state.isCompleted(untouched))
        #expect(!h.store.completionRecord().ids.contains(untouched.id))

        try h.relaunch()
        #expect(h.state.recurringTasks.isEmpty)
        #expect(h.state.isCompleted(finished), "still finished after a relaunch")
        #expect(h.state.completionDates[finished.id] == completedAt)
    }

    @Test("stopping one recurring task leaves another recurring task and a one-off task alone")
    func stopLeavesTheRest() throws {
        let h = try Harness()
        defer { h.tearDown() }
        let doomed = weekly("Own task weekly doomed")
        let kept = weekly("Own task weekly kept")
        let single = oneOff("Own task single kept")
        h.state.addRecurringTask(doomed)
        h.state.addRecurringTask(kept)
        h.state.addManualAssignment(single)

        let vm = DashboardViewModel()
        vm.bind(to: h.state)
        vm.removeOwnTask(try card(vm, titled: doomed.title))

        #expect(h.state.recurringTasks.map(\.id) == [kept.id])
        #expect(h.storedRecurringTasks.map(\.id) == [kept.id])
        #expect(h.state.manualAssignments.map(\.id) == [single.id])
        #expect(vm.items.filter { $0.assignment.title == kept.title }.count == kept.upcomingAssignments().count)
        #expect(vm.items.contains { $0.assignment.title == single.title })
    }

    @Test("a task the student accepted from a suggestion stops the same way, and is not re-offered by stopping")
    func stopAcceptedSuggestion() throws {
        var h = try Harness()
        defer { h.tearDown() }
        let tomorrow = Calendar.current.date(byAdding: .day, value: 1, to: Date())!
        let suggestion = CanvasRequirementSuggestion(
            course: Self.course, title: "Own task suggested post",
            weekday: Calendar.current.component(.weekday, from: tomorrow), hour: 23, minute: 59,
            source: .syllabus, evidence: "Each week you must post a response")
        h.state.canvasRequirementSuggestions = [suggestion]
        h.state.addCanvasSuggestion(suggestion)
        let task = try #require(h.state.recurringTasks.first)

        let vm = DashboardViewModel()
        vm.bind(to: h.state)
        let shown = try card(vm, titled: suggestion.title)
        #expect(shown.assignment.source == .canvasSuggestion)
        #expect(shown.removal == .stopRepeating(taskID: task.id))

        vm.removeOwnTask(shown)

        #expect(h.state.recurringTasks.isEmpty)
        #expect(!vm.items.contains { $0.assignment.title == suggestion.title })
        // Suggestions live in memory until a scan; stopping must not put one back.
        #expect(h.state.canvasRequirementSuggestions.isEmpty)
        try h.relaunch()
        #expect(h.state.recurringTasks.isEmpty)
    }

    /// An occurrence of `task` that has since passed: the generator no longer
    /// mints it, so only a match on its id can find an edit made to it.
    private func passedOccurrence(of task: RecurringTask) -> Assignment {
        Assignment(
            source: .manual,
            sourceID: RecurringTask.occurrenceSourceID(taskID: task.id, due: Date().addingTimeInterval(-3 * 86_400)),
            kind: .assignment, course: Self.course, title: task.title, dueAt: nil, url: nil)
    }

    @Test("stopping the last recurring task clears the edited due dates of its occurrences, past ones included")
    func stopLastClearsItsEdits() throws {
        let h = try Harness()
        defer { h.tearDown() }
        let doomed = weekly("Own task weekly edited")
        let single = oneOff("Own task single edited")
        h.state.addRecurringTask(doomed)
        h.state.addManualAssignment(single)

        let moved = Date().addingTimeInterval(9 * 86_400)
        h.state.setDueDateEdit(moved, for: try #require(doomed.upcomingAssignments().first))
        h.state.setDueDateEdit(moved, for: passedOccurrence(of: doomed))
        h.state.setDueDateEdit(moved, for: single.asAssignment())
        #expect(h.state.dueDateEdits.count == 3)

        // The rebuild after this cannot forget those two edits: `pruneDueDateEdits`
        // forgets only while the recurring family still has items in the pool, and
        // this was its last task. The removal has to.
        h.state.removeRecurringTask(id: doomed.id)

        #expect(h.state.dueDateEdits == [single.asAssignment().id: moved])
        #expect(h.storedEdits == [single.asAssignment().id: moved], "and the persisted copy")
    }

    @Test("stopping a recurring task leaves the edited due dates of another recurring task and of a one-off task")
    func stopKeepsOtherEdits() throws {
        let h = try Harness()
        defer { h.tearDown() }
        let doomed = weekly("Own task weekly edited")
        let kept = weekly("Own task weekly other")
        let single = oneOff("Own task single edited")
        h.state.addRecurringTask(doomed)
        h.state.addRecurringTask(kept)
        h.state.addManualAssignment(single)

        let moved = Date().addingTimeInterval(9 * 86_400)
        let keptOccurrence = try #require(kept.upcomingAssignments().first)
        h.state.setDueDateEdit(moved, for: try #require(doomed.upcomingAssignments().first))
        h.state.setDueDateEdit(moved, for: passedOccurrence(of: doomed))
        h.state.setDueDateEdit(moved, for: keptOccurrence)
        h.state.setDueDateEdit(moved, for: single.asAssignment())
        #expect(h.state.dueDateEdits.count == 4)

        h.state.removeRecurringTask(id: doomed.id)

        #expect(h.state.dueDateEdits == [keptOccurrence.id: moved, single.asAssignment().id: moved])
        #expect(h.storedEdits == [keptOccurrence.id: moved, single.asAssignment().id: moved], "and the persisted copy")
    }

    // MARK: Preview and demo data

    @Test("nothing is offered, and nothing removed, while the app shows preview or demo data")
    func fixtureDataIsNeverOffered() throws {
        let h = try Harness()
        defer { h.tearDown() }
        let single = oneOff("Own task fixture single")
        let repeating = weekly("Own task fixture weekly")
        h.state.addManualAssignment(single)
        h.state.addRecurringTask(repeating)
        h.state.forceFixtureDataForTesting(true)

        let vm = DashboardViewModel()
        vm.bind(to: h.state)
        let ours = vm.items.filter { $0.assignment.course == Self.course }
        #expect(!ours.isEmpty)
        #expect(ours.allSatisfy { $0.removal == nil })

        vm.removeOwnTask(try #require(ours.first))
        #expect(h.state.manualAssignments.map(\.id) == [single.id])
        #expect(h.state.recurringTasks.map(\.id) == [repeating.id])

        // The in-view-model sample data (previews and the reviewer's demo).
        let sample = DashboardViewModel()
        sample.loadSampleData()
        let before = sample.items.map(\.id)
        #expect(!before.isEmpty)
        #expect(sample.items.allSatisfy { $0.removal == nil })
        sample.removeOwnTask(sample.items[0])
        #expect(sample.items.map(\.id) == before)
    }

    @Test("a feed item's card offers nothing, and asking to remove it removes nothing")
    func feedItemIsNotRemovable() throws {
        let h = try Harness()
        defer { h.tearDown() }
        let feed = Assignment(source: .gradescope, sourceID: "own-task-feed", kind: .assignment,
                              course: Self.course, title: "Own task from gradescope",
                              dueAt: Date().addingTimeInterval(36 * 3_600), url: nil)
        h.state.gradescopeItems = [feed]
        h.state.rebuildDashboardItemsForTesting()

        let vm = DashboardViewModel()
        vm.bind(to: h.state)
        let shown = try card(vm, titled: feed.title)
        #expect(shown.removal == nil)
        vm.removeOwnTask(shown)
        #expect(vm.items.contains { $0.id == feed.id })
        #expect(h.state.gradescopeItems.contains { $0.id == feed.id })
    }
}
