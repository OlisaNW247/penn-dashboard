import Combine
import Foundation
import Testing
import UserNotifications
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// "edit date" on a card, end to end.
///
/// It used to live only in `DashboardViewModel.items`, so a relaunch lost it and
/// the widget and ask never saw it. `AppState` owns the edits now (persisted,
/// `AppState+DueDateEdits.swift`), and every reader asks it. These tests are
/// that contract: the edit survives a new `AppState`, the card, the reminders,
/// the widget snapshot and both of ask's pools carry it, clearing and pruning do
/// what they say, and a preview or an `AppState` that was not handed a scratch
/// suite never writes the key.
///
/// **How this stays out of the shared domain.** The edits key, once written to
/// `UserDefaults.lhf`, would be read by the `AppState.init` of every suite
/// running alongside this one. So under the test runner an `AppState` keeps its
/// edits in memory only unless it is constructed with `dueDateEditsDefaults:`
/// (a scratch suite); every state in this file but one is, and each scratch
/// suite is deleted afterwards. `anAppStateThatDidNotOptInNeverTouchesTheSharedKey`
/// is the one that looks from the outside, and it is the only test that touches
/// the real key at all.
///
/// Items are Gradescope unless the test needs Canvas: an overdue Canvas item can
/// sit in the first-launch submission hold (another suite saving cookies to the
/// Keychain at the same instant makes Grade Watcher "usable"), which would make
/// an overdue-bucket assertion depend on whoever else is running. Gradescope
/// work never sits in that hold. Assertions are scoped to this suite's own
/// courses and titles, because an `AppState` loads the manual-work blob from the
/// shared domain and a fresh one is not an empty dashboard on a used Mac.
@MainActor
@Suite("Edited due dates")
struct DueDateEditTests {
    private static let course = "DUEEDIT 0001"
    private static let otherCourse = "DUEEDIT 0002"

    /// One `AppState` over a fresh in-memory ledger, with the edits backed by a
    /// scratch suite.
    @MainActor
    private struct Harness {
        private(set) var state: AppState
        let store: AssignmentStore
        let defaults: UserDefaults
        private let suite: String

        init() throws {
            suite = "lhf.due-date-edits.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suite)!
            store = try AssignmentStore(inMemory: true)
            state = AppState(assignmentStore: store, dueDateEditsDefaults: defaults)
            // Pinned per instance: the persisted preview flag lives in the shared
            // domain, where another suite can flip it while this one runs, and an
            // edit is (rightly) ignored in preview. `nil` would mean "ask".
            state.forceFixtureDataForTesting(false)
        }

        func tearDown() {
            defaults.removePersistentDomain(forName: suite)
        }

        /// The next launch: a new `AppState` over the same ledger and the same
        /// defaults, which is all a relaunch preserves.
        mutating func relaunch() {
            state = AppState(assignmentStore: store, dueDateEditsDefaults: defaults)
            state.forceFixtureDataForTesting(false)
        }

        /// What `sync()` does with a fetched Canvas feed, minus the network:
        /// reconcile into the ledger, put the result in the pool, rebuild.
        func syncCanvas(_ fetched: [Assignment], at now: Date = Date()) {
            let result = store.reconcile(fetched, source: .canvas)
            state.canvasItems = result.items.sorted(by: Assignment.isOrderedByDueDate)
            state.rebuildDashboardItemsForTesting(now: now)
        }

        /// The same for `syncGradescope`.
        func syncGradescope(_ fetched: [Assignment], at now: Date = Date()) {
            let result = store.reconcile(fetched, source: .gradescope)
            state.gradescopeItems = result.items
            state.rebuildDashboardItemsForTesting(now: now)
        }

        /// What is stored under the key right now.
        var persisted: [String: Date] { DueDateEditStore(defaults: defaults).load() }
        var storedKeyIsAbsent: Bool { defaults.object(forKey: SharedDefaults.dueDateEditsKey) == nil }
    }

    /// Whole seconds, so no comparison here depends on sub-microsecond rounding.
    private static func now() -> Date {
        Date(timeIntervalSinceReferenceDate: Date().timeIntervalSinceReferenceDate.rounded(.down))
    }

    private func item(
        _ id: String,
        _ title: String,
        due: Date?,
        source: Assignment.Source = .gradescope,
        course: String = DueDateEditTests.course
    ) -> Assignment {
        Assignment(source: source, sourceID: id, kind: .assignment,
                   course: course, title: title, dueAt: due, url: nil)
    }

    private func isoTimestamp(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter.string(from: date)
    }

    private func card(_ vm: DashboardViewModel, _ assignment: Assignment) throws -> DashItem {
        try #require(vm.items.first { $0.id == assignment.id })
    }

    private func overdueIDs(_ vm: DashboardViewModel, now: Date) -> Set<String> {
        Set(vm.todoSections(now: now).filter { $0.id == "overdue" }.flatMap(\.items).map(\.id))
    }

    // MARK: Survives a relaunch

    @Test("an edited date survives a new AppState over the same defaults")
    func editSurvivesARelaunch() throws {
        var h = try Harness()
        defer { h.tearDown() }
        let now = Self.now()
        let hw = item("hw", "Edit me", due: now.addingTimeInterval(2 * 86_400))
        let moved = now.addingTimeInterval(5 * 86_400)
        h.syncGradescope([hw], at: now)

        // Through the view model, as the sheet does it.
        var vm = DashboardViewModel()
        vm.bind(to: h.state)
        vm.setDue(try card(vm, hw), to: moved)
        #expect(h.persisted == [hw.id: moved])

        h.relaunch()
        #expect(h.state.dueDateEdits == [hw.id: moved], "read back at init")
        vm = DashboardViewModel()
        vm.bind(to: h.state)
        let reloaded = try card(vm, hw)
        #expect(reloaded.dueOverride == moved)
        #expect(reloaded.due == moved)
        #expect(reloaded.assignment.dueAt == hw.dueAt, "the feed's own date is untouched")
    }

    @Test("the student's edit wins over a later change in the feed's date")
    func editBeatsALaterFeedChange() throws {
        let h = try Harness()
        defer { h.tearDown() }
        let now = Self.now()
        let hw = item("hw", "Moved by me, then by the prof", due: now.addingTimeInterval(2 * 86_400))
        h.syncGradescope([hw], at: now)
        let moved = now.addingTimeInterval(4 * 86_400)
        h.state.setDueDateEdit(moved, for: hw)

        let profMoved = item("hw", "Moved by me, then by the prof", due: now.addingTimeInterval(3 * 86_400))
        h.syncGradescope([profMoved], at: now)

        let vm = DashboardViewModel()
        vm.bind(to: h.state)
        let shown = try card(vm, hw)
        #expect(shown.assignment.dueAt == profMoved.dueAt, "the feed change did land")
        #expect(shown.due == moved, "and the student's date still wins")
    }

    @Test("a change to the edits publishes, so a bound view model reloads")
    func editsPublish() throws {
        let h = try Harness()
        defer { h.tearDown() }
        let now = Self.now()
        let hw = item("hw", "Publishes", due: now.addingTimeInterval(86_400))
        h.syncGradescope([hw], at: now)

        var fired = 0
        let subscription = h.state.objectWillChange.sink { fired += 1 }
        h.state.setDueDateEdit(now.addingTimeInterval(3 * 86_400), for: hw)
        #expect(fired > 0)
        subscription.cancel()
    }

    // MARK: Every reader sees it

    @Test("the card, the reminders, the widget and the on-device pool carry the edited date; the server document does not")
    func everyReaderSeesTheEdit() throws {
        var h = try Harness()
        defer { h.tearDown() }
        let now = Self.now()
        let original = now.addingTimeInterval(3 * 86_400)
        let moved = now.addingTimeInterval(4 * 86_400)
        let ahead = item("ahead", "Quoted everywhere", due: original, source: .canvas)
        h.syncCanvas([ahead], at: now)
        h.state.setDueDateEdit(moved, for: ahead)

        // Relaunch first: the readers must get it from the persisted edit, not
        // from anything the first AppState still had in memory.
        h.relaunch()

        // The card.
        let vm = DashboardViewModel()
        vm.bind(to: h.state)
        #expect(try card(vm, ahead).due == moved)

        // Reminders plan from the view model's items, so they follow the card:
        // the 24-hour reminder fires a day before the EDITED date.
        let scratch = "lhf.due-date-edits.reminders.\(UUID().uuidString)"
        let scratchDefaults = UserDefaults(suiteName: scratch)!
        defer { scratchDefaults.removePersistentDomain(forName: scratch) }
        let scheduler = NotificationScheduler(defaults: scratchDefaults)
        let requests = scheduler.plannedRequests(
            from: vm.items.filter { $0.assignment.course == Self.course },
            now: now,
            preferences: CoursePreferencesStore(defaults: scratchDefaults)
        )
        let dayBefore = try #require(requests.first { $0.identifier == "due:\(ahead.id):86400" })
        let trigger = try #require(dayBefore.trigger as? UNCalendarNotificationTrigger)
        let calendar = Calendar.current
        #expect(trigger.dateComponents == calendar.dateComponents(
            [.year, .month, .day, .hour, .minute], from: moved.addingTimeInterval(-86_400)))
        #expect(trigger.dateComponents != calendar.dateComponents(
            [.year, .month, .day, .hour, .minute], from: original.addingTimeInterval(-86_400)))

        // The widget snapshot.
        let widget = try #require(h.state.widgetNextDueItems().first { $0.title == "Quoted everywhere" })
        #expect(widget.dueAt == moved)

        // Ask, on-device.
        let work = try #require(h.state.assistantWorkItems().first { $0.id == ahead.id })
        #expect(work.dueAt == moved)

        // Ask, server path: deliberately the OPPOSITE. The context document is
        // sent to the backend, and docs/PRIVACY.md promises due-date edits never
        // leave the device, so it still names the feed's date (by its ISO
        // timestamp, on the item's line) and the edited date appears nowhere in
        // it. The on-device pool above and this document can therefore disagree
        // about a date the student moved; that is the price of the promise.
        let document = h.state.assistantContextDocument()
        let line = try #require(
            document
                .split(separator: "\n")
                .first { $0.contains("Quoted everywhere") }
        )
        #expect(line.contains("due \(isoTimestamp(original))"), "\(line)")
        #expect(!line.contains(isoTimestamp(moved)), "\(line)")
        #expect(!document.contains(isoTimestamp(moved)), "the edited date is nowhere in what is sent")
    }

    @Test("the widget orders by the edited date, and can show an item the feed left undated")
    func widgetOrdersByTheEditedDate() throws {
        let h = try Harness()
        defer { h.tearDown() }
        let now = Self.now()
        let first = item("first", "Widget order first", due: now.addingTimeInterval(3_600))
        let second = item("second", "Widget order second", due: now.addingTimeInterval(7_200))
        let undated = item("undated", "Widget undated", due: nil)
        h.syncGradescope([first, second, undated], at: now)

        func titles() -> [String] {
            h.state.widgetNextDueItems().map(\.title).filter { $0.hasPrefix("Widget ") }
        }
        #expect(titles() == ["Widget order first", "Widget order second"], "undated is not listed")

        // `first` moves to after `second`; `undated` is given a date.
        h.state.setDueDateEdit(now.addingTimeInterval(6 * 3_600), for: first)
        h.state.setDueDateEdit(now.addingTimeInterval(5_400), for: undated)
        #expect(titles() == ["Widget undated", "Widget order second", "Widget order first"])
    }

    @Test("a cross-posted item is edited under both of its ids, and ask sees both copies edited")
    func crossPostedItemIsEditedUnderBothIds() throws {
        let h = try Harness()
        defer { h.tearDown() }
        let now = Self.now()
        let due = now.addingTimeInterval(2 * 86_400)
        let canvasCopy = item("c1", "Homework 4", due: due, source: .canvas)
        let gradescopeCopy = item("g1", "Homework 4", due: due, source: .gradescope)
        h.syncCanvas([canvasCopy], at: now)
        h.syncGradescope([gradescopeCopy], at: now)

        let vm = DashboardViewModel()
        vm.bind(to: h.state)
        let merged = try #require(
            vm.items.first { $0.assignment.course == Self.course && !$0.isCompleted },
            "the pair collapses to one card"
        )
        #expect(merged.assignment.linkedID != nil)
        let moved = now.addingTimeInterval(4 * 86_400)
        vm.setDue(merged, to: moved)

        #expect(Set(h.state.dueDateEdits.keys) == [canvasCopy.id, gradescopeCopy.id])
        let work = h.state.assistantWorkItems().filter { $0.course == Self.course }
        #expect(Set(work.map(\.id)) == [canvasCopy.id, gradescopeCopy.id])
        #expect(work.allSatisfy { $0.dueAt == moved })

        // And resetting the card clears both.
        vm.setDue(try #require(vm.items.first { $0.id == merged.id }), to: nil)
        #expect(h.state.dueDateEdits.isEmpty)
    }

    // MARK: The dashboard's own placement

    @Test("an overdue item moved to next week leaves overdue, and stays out of it after a relaunch")
    func overdueItemMovedForwardLeavesOverdue() throws {
        var h = try Harness()
        defer { h.tearDown() }
        let now = Self.now()
        let late = item("late", "Overdue until I moved it", due: now.addingTimeInterval(-2 * 86_400))
        h.syncGradescope([late], at: now)

        var vm = DashboardViewModel()
        vm.bind(to: h.state)
        #expect(overdueIDs(vm, now: now).contains(late.id), "starts overdue")

        vm.setDue(try card(vm, late), to: now.addingTimeInterval(7 * 86_400))
        #expect(!overdueIDs(vm, now: now).contains(late.id))
        #expect(vm.allSections(now: now).flatMap(\.items).map(\.id).contains(late.id),
                "and shows up with the rest of the week's work")

        h.relaunch()
        vm = DashboardViewModel()
        vm.bind(to: h.state)
        #expect(!overdueIDs(vm, now: now).contains(late.id), "still not overdue after a relaunch")
        #expect(vm.allSections(now: now).flatMap(\.items).map(\.id).contains(late.id))
    }

    // MARK: Clearing

    @Test("resetting an edit removes it from the card, the store and every reader")
    func clearingRemovesTheEdit() throws {
        let h = try Harness()
        defer { h.tearDown() }
        let now = Self.now()
        let original = now.addingTimeInterval(2 * 86_400)
        let hw = item("hw", "Reset me", due: original)
        h.syncGradescope([hw], at: now)
        let vm = DashboardViewModel()
        vm.bind(to: h.state)
        vm.setDue(try card(vm, hw), to: now.addingTimeInterval(6 * 86_400))
        #expect(!h.storedKeyIsAbsent)

        vm.setDue(try card(vm, hw), to: nil)
        #expect(h.state.dueDateEdits.isEmpty)
        #expect(h.storedKeyIsAbsent, "an empty set of edits leaves no key behind")
        #expect(try card(vm, hw).dueOverride == nil)
        #expect(try card(vm, hw).due == original)
        #expect(h.state.widgetNextDueItems().first { $0.title == "Reset me" }?.dueAt == original)
        #expect(h.state.assistantWorkItems().first { $0.id == hw.id }?.dueAt == original)

        // A reload (a feed refresh republishing) must not bring it back.
        vm.reload(preservingEdits: true)
        #expect(try card(vm, hw).dueOverride == nil)
    }

    @Test("an edit equal to the item's own due date is not stored, and clears an earlier edit")
    func anEditEqualToTheFeedDateIsNotAnEdit() throws {
        let h = try Harness()
        defer { h.tearDown() }
        let now = Self.now()
        let original = now.addingTimeInterval(2 * 86_400)
        let hw = item("hw", "Unchanged", due: original)
        h.syncGradescope([hw], at: now)

        // Saving the sheet without touching the picker.
        let vm = DashboardViewModel()
        vm.bind(to: h.state)
        vm.setDue(try card(vm, hw), to: original)
        #expect(h.state.dueDateEdits.isEmpty)
        #expect(h.storedKeyIsAbsent)
        #expect(try card(vm, hw).dueOverride == nil, "the card does not claim to be edited")

        // And moving it back to the feed's date after a real edit.
        h.state.setDueDateEdit(now.addingTimeInterval(5 * 86_400), for: hw)
        #expect(h.state.dueDateEdits.count == 1)
        h.state.setDueDateEdit(original, for: hw)
        #expect(h.state.dueDateEdits.isEmpty)
        #expect(h.storedKeyIsAbsent)
    }

    // MARK: Pruning

    @Test("an edit for an item that has left the pool is dropped on the next rebuild")
    func pruningDropsAVanishedItem() throws {
        let h = try Harness()
        defer { h.tearDown() }
        let now = Self.now()
        let stays = item("stays", "Stays", due: now.addingTimeInterval(2 * 86_400))
        let leaves = item("leaves", "Leaves", due: now.addingTimeInterval(2 * 86_400))
        h.syncGradescope([stays, leaves], at: now)
        let movedStays = now.addingTimeInterval(4 * 86_400)
        h.state.setDueDateEdit(movedStays, for: stays)
        h.state.setDueDateEdit(now.addingTimeInterval(5 * 86_400), for: leaves)
        #expect(h.state.dueDateEdits.count == 2)

        h.state.gradescopeItems = h.state.gradescopeItems.filter { $0.id != leaves.id }
        h.state.rebuildDashboardItemsForTesting(now: now)

        #expect(h.state.dueDateEdits == [stays.id: movedStays])
        #expect(h.persisted == [stays.id: movedStays], "and the stored copy follows")
    }

    @Test("finished work leaves the lists but not the pool, and keeps its edit")
    func pruningKeepsFinishedWorksEdit() throws {
        let h = try Harness()
        defer { h.tearDown() }
        let now = Self.now()
        let hw = item("hw", "Hidden class work", due: now.addingTimeInterval(2 * 86_400),
                      course: Self.otherCourse)
        h.syncGradescope([hw], at: now)
        let moved = now.addingTimeInterval(4 * 86_400)
        h.state.setDueDateEdit(moved, for: hw)

        // Completed work leaves the todo and all lists but is still in the
        // pool (it is on the prev tab); a prune that read "not on the
        // dashboard" as "gone" would eat the edit of work the student finished.
        h.state.markCompleted(hw)
        defer { h.state.markActive(hw) }
        h.state.rebuildDashboardItemsForTesting(now: now)
        #expect(h.state.dueDateEdits[hw.id] == moved)
    }

    @Test("an empty pool prunes nothing: a launch that has not loaded cannot wipe the edits")
    func pruningSkipsAnEmptyPool() throws {
        let h = try Harness()
        defer { h.tearDown() }
        let now = Self.now()
        let hw = item("hw", "Survives an unloaded pool", due: now.addingTimeInterval(2 * 86_400))
        h.syncGradescope([hw], at: now)
        let moved = now.addingTimeInterval(4 * 86_400)
        h.state.setDueDateEdit(moved, for: hw)

        h.state.pruneDueDateEdits(against: [])
        #expect(h.state.dueDateEdits == [hw.id: moved])
        #expect(h.persisted == [hw.id: moved])
    }

    @Test("fixture data prunes nothing")
    func pruningSkipsFixtureData() throws {
        let h = try Harness()
        defer { h.tearDown() }
        let now = Self.now()
        let hw = item("hw", "Survives preview", due: now.addingTimeInterval(2 * 86_400))
        h.syncGradescope([hw], at: now)
        let moved = now.addingTimeInterval(4 * 86_400)
        h.state.setDueDateEdit(moved, for: hw)

        // Per-instance and memory-only: `enterPreviewMode()` would persist the
        // preview flag in the shared domain and flip every other suite.
        h.state.forceFixtureDataForTesting(true)
        defer { h.state.forceFixtureDataForTesting(false) }
        let stranger = item("stranger", "Not this item", due: now.addingTimeInterval(86_400))
        h.state.pruneDueDateEdits(against: [stranger])
        #expect(h.state.dueDateEdits == [hw.id: moved])
        #expect(h.persisted == [hw.id: moved])
    }

    // MARK: Pruning needs positive evidence, per source

    @Test("a pool of only manual or recurring items prunes no feed edit, and neither of those proves the other")
    func onlyManualItemsPruneNoFeedEdit() throws {
        let h = try Harness()
        defer { h.tearDown() }
        let now = Self.now()
        let moved = now.addingTimeInterval(4 * 86_400)
        let due = now.addingTimeInterval(2 * 86_400)
        let canvas = item("c", "Canvas work", due: due, source: .canvas)
        let gradescope = item("g", "Gradescope work", due: due)
        let modules = item("m", "Module reading", due: due, source: .canvasModules)
        let announced = item("a", "From an announcement", due: due, source: .canvasAnnouncement)
        let ownTask = item("manual-\(UUID().uuidString)", "My own task", due: due, source: .manual)
        let recurring = item(RecurringTask.occurrenceSourceID(taskID: UUID(), due: due),
                             "Weekly reading", due: due, source: .manual)
        let editedAll = [canvas, gradescope, modules, announced, ownTask, recurring]
        for edited in editedAll { h.state.setDueDateEdit(moved, for: edited) }
        #expect(h.state.dueDateEdits.count == editedAll.count)

        // A launch whose feeds have not loaded but which has a manual task:
        // every feed edit stays, and so does the recurring one (a manual item is
        // no evidence about recurring occurrences). The manual family IS loaded
        // here, though, and `ownTask` is not in it, so that one is positively
        // gone.
        let otherManual = item("manual-\(UUID().uuidString)", "Another task", due: due, source: .manual)
        h.state.pruneDueDateEdits(against: [otherManual])
        #expect(h.state.dueDateEdits[ownTask.id] == nil)
        #expect(h.state.dueDateEdits[recurring.id] == moved, "a manual item is no evidence about recurring ones")
        for feed in [canvas, gradescope, modules, announced] {
            #expect(h.state.dueDateEdits[feed.id] == moved, "\(feed.id) kept")
        }

        // The reverse: a recurring occurrence is present, so the manual edit
        // stays (restored first) and the occurrence that is not in it goes.
        let otherOccurrence = item(RecurringTask.occurrenceSourceID(taskID: UUID(), due: due),
                                   "Another reading", due: due, source: .manual)
        h.state.setDueDateEdit(moved, for: ownTask)
        h.state.pruneDueDateEdits(against: [otherOccurrence])
        #expect(h.state.dueDateEdits[ownTask.id] == moved, "a recurring item is no evidence about manual ones")
        #expect(h.state.dueDateEdits[recurring.id] == nil, "but this occurrence is positively gone")
        for feed in [canvas, gradescope, modules, announced] {
            #expect(h.state.dueDateEdits[feed.id] == moved, "\(feed.id) still kept")
        }
        #expect(h.persisted == h.state.dueDateEdits)
    }

    @Test("a launch whose ledger came up empty keeps every feed item's edit")
    func aLaunchWithAnEmptyLedgerKeepsTheEdits() throws {
        let h = try Harness()
        defer { h.tearDown() }
        let now = Self.now()
        let due = now.addingTimeInterval(2 * 86_400)
        let canvas = item("c", "Canvas work", due: due, source: .canvas)
        let gradescope = item("g", "Gradescope work", due: due)
        h.syncCanvas([canvas], at: now)
        h.syncGradescope([gradescope], at: now)
        let moved = now.addingTimeInterval(4 * 86_400)
        h.state.setDueDateEdit(moved, for: canvas)
        h.state.setDueDateEdit(moved, for: gradescope)
        let expected = [canvas.id: moved, gradescope.id: moved]
        #expect(h.persisted == expected)

        // The same defaults, but a ledger with nothing in it. Whatever manual
        // tasks the shared domain happens to hold make the pool non-empty on a
        // used machine, which is exactly the case the per-source rule is for;
        // on a clean one the pool is empty. Either way nothing may be pruned.
        let relaunched = AppState(assignmentStore: try AssignmentStore(inMemory: true),
                                  dueDateEditsDefaults: h.defaults)
        #expect(relaunched.dueDateEdits == expected)
        relaunched.rebuildDashboardItemsForTesting(now: now)
        #expect(relaunched.dueDateEdits == expected)
        #expect(h.persisted == expected, "and the stored copy is untouched")
    }

    @Test("a Canvas item that really vanished is pruned while Canvas is loaded; a source that is not loaded is left alone")
    func aVanishedCanvasItemIsPrunedOnlyWhileCanvasIsLoaded() throws {
        let h = try Harness()
        defer { h.tearDown() }
        let now = Self.now()
        let due = now.addingTimeInterval(2 * 86_400)
        let stays = item("stays", "Canvas stays", due: due, source: .canvas)
        let leaves = item("leaves", "Canvas leaves", due: due, source: .canvas)
        let grades = item("g", "Gradescope work", due: due)
        h.syncCanvas([stays, leaves], at: now)
        h.syncGradescope([grades], at: now)
        let moved = now.addingTimeInterval(4 * 86_400)
        for edited in [stays, leaves, grades] { h.state.setDueDateEdit(moved, for: edited) }
        #expect(h.state.dueDateEdits.count == 3)

        // Canvas still has `stays`; `leaves` is gone from it. Gradescope has not
        // loaded at all in this rebuild, which is no evidence about its edit.
        h.state.canvasItems = h.state.canvasItems.filter { $0.id != leaves.id }
        h.state.gradescopeItems = []
        h.state.rebuildDashboardItemsForTesting(now: now)

        #expect(h.state.dueDateEdits == [stays.id: moved, grades.id: moved])
        #expect(h.persisted == [stays.id: moved, grades.id: moved])

        // Gradescope loads again and still has its item: nothing more to drop.
        h.state.gradescopeItems = h.store.reconcile([grades], source: .gradescope).items
        h.state.rebuildDashboardItemsForTesting(now: now)
        #expect(h.state.dueDateEdits == [stays.id: moved, grades.id: moved])
    }

    @Test("an id whose source cannot be told from the id is kept")
    func anIdOfUnknownSourceIsKept() throws {
        var h = try Harness()
        defer { h.tearDown() }
        let now = Self.now()
        let due = now.addingTimeInterval(2 * 86_400)
        h.syncCanvas([item("c", "Canvas work", due: due, source: .canvas)], at: now)
        h.syncGradescope([item("g", "Gradescope work", due: due)], at: now)

        // Ids this build could not have written: a source it does not know (a
        // newer build's), no source at all, and a `.manual` id that is neither a
        // manual task nor a recurring occurrence. Seeded straight into the
        // store, because `setDueDateEdit` only takes real assignments.
        let strangers: [String: Date] = [
            "mystery:abc": now.addingTimeInterval(3 * 86_400),
            "no-source-prefix-at-all": now.addingTimeInterval(4 * 86_400),
            "manual:something-else": now.addingTimeInterval(5 * 86_400),
        ]
        DueDateEditStore(defaults: h.defaults).save(strangers)

        // Canvas and Gradescope are both loaded on this launch, and the init
        // rebuild has already run with those ids stored.
        h.relaunch()
        #expect(h.state.dueDateEdits == strangers)
        h.state.rebuildDashboardItemsForTesting(now: now)
        #expect(h.state.dueDateEdits == strangers)
        #expect(h.persisted == strangers)
    }

    @Test("an edit on an item a display filter hides is kept, because it is still in the pool")
    func aDisplayFilterDoesNotPruneAnEdit() throws {
        // The sign-up rule withholds feed work that was already a week overdue
        // when the student joined. It is a display filter: the item is in the
        // ledger and in the pool, just not on the lists.
        let backlogSuite = "lhf.due-date-edits.backlog.\(UUID().uuidString)"
        let editsSuite = "lhf.due-date-edits.filter.\(UUID().uuidString)"
        let backlogDefaults = UserDefaults(suiteName: backlogSuite)!
        let editsDefaults = UserDefaults(suiteName: editsSuite)!
        defer {
            backlogDefaults.removePersistentDomain(forName: backlogSuite)
            editsDefaults.removePersistentDomain(forName: editsSuite)
        }
        let store = try AssignmentStore(inMemory: true)
        let state = AppState(
            assignmentStore: store,
            signupBacklogDefaults: backlogDefaults,
            persistedFlagsForSignupBacklog: (complete: false, inPreview: false),
            dueDateEditsDefaults: editsDefaults
        )
        state.forceFixtureDataForTesting(false)

        let now = Self.now()
        let old = item("old", "Withheld by the sign-up rule", due: now.addingTimeInterval(-12 * 86_400))
        let recent = item("recent", "Ordinary overdue work", due: now.addingTimeInterval(-1 * 86_400))
        state.gradescopeItems = store.reconcile([old, recent], source: .gradescope).items
        state.rebuildDashboardItemsForTesting(now: now)
        let listed = Set((state.assignments + state.laterAssignments + state.assessments).map(\.id))
        try #require(state.signupBacklogHiddenCount == 1)
        #expect(!listed.contains(old.id), "hidden from the lists")
        #expect(listed.contains(recent.id))

        let moved = now.addingTimeInterval(3 * 86_400)
        state.setDueDateEdit(moved, for: old)
        state.rebuildDashboardItemsForTesting(now: now)
        #expect(state.dueDateEdits == [old.id: moved])
        #expect(DueDateEditStore(defaults: editsDefaults).load() == [old.id: moved])
    }

    // MARK: Preview and hermeticity

    @Test("preview mode writes nothing; the card keeps the edit for the session")
    func previewModeWritesNothing() throws {
        let h = try Harness()
        defer { h.tearDown() }
        let now = Self.now()
        let hw = item("hw", "Edited in preview", due: now.addingTimeInterval(2 * 86_400))
        h.syncGradescope([hw], at: now)
        h.state.forceFixtureDataForTesting(true)
        defer { h.state.forceFixtureDataForTesting(false) }

        // At the AppState.
        let moved = now.addingTimeInterval(4 * 86_400)
        h.state.setDueDateEdit(moved, for: hw)
        #expect(h.state.dueDateEdits.isEmpty)
        #expect(h.storedKeyIsAbsent)

        // Through the view model, as a reviewer would.
        let vm = DashboardViewModel()
        vm.bind(to: h.state)
        vm.setDue(try card(vm, hw), to: moved)
        #expect(h.state.dueDateEdits.isEmpty)
        #expect(h.storedKeyIsAbsent)
        #expect(try card(vm, hw).due == moved, "the edit shows on the card, as it always did")
        vm.reload(preservingEdits: true)
        #expect(try card(vm, hw).due == moved, "and survives a republish within the session")
    }

    @Test("sample data in the view model never reaches AppState")
    func sampleDataEditsStayOnTheCard() throws {
        let h = try Harness()
        defer { h.tearDown() }
        let vm = DashboardViewModel()
        vm.loadSampleData()
        vm.bind(to: h.state)
        let sample = try #require(vm.items.first { !$0.isCompleted })

        vm.setDue(sample, to: Self.now().addingTimeInterval(9 * 86_400))
        #expect(h.state.dueDateEdits.isEmpty)
        #expect(h.storedKeyIsAbsent)
    }

    @Test("an AppState that did not opt in neither reads nor writes the shared key")
    func anAppStateThatDidNotOptInNeverTouchesTheSharedKey() throws {
        // The one test that touches the real key, and only to prove nothing
        // else does: a value another install left behind must not be read, and
        // an edit made here must not replace it. No `AppState` reads this key
        // unless it was handed a scratch suite, so seeding it cannot reach a
        // concurrently running suite.
        let key = SharedDefaults.dueDateEditsKey
        let planted: [String: Date] = ["gradescope:planted": Date(timeIntervalSinceReferenceDate: 1_000_000)]
        UserDefaults.lhf.set(planted, forKey: key)
        defer { UserDefaults.lhf.removeObject(forKey: key) }

        let store = try AssignmentStore(inMemory: true)
        let state = AppState(assignmentStore: store)
        state.forceFixtureDataForTesting(false)
        #expect(state.dueDateEditStore == nil)
        #expect(state.dueDateEdits.isEmpty, "did not read the shared key")

        let now = Self.now()
        let hw = item("hw", "Optional", due: now.addingTimeInterval(2 * 86_400))
        state.gradescopeItems = store.reconcile([hw], source: .gradescope).items
        state.rebuildDashboardItemsForTesting(now: now)
        let moved = now.addingTimeInterval(4 * 86_400)
        state.setDueDateEdit(moved, for: hw)
        #expect(state.editedDueDate(for: hw) == moved, "edits still work, in memory")
        state.pruneDueDateEdits(against: [item("other", "Other", due: nil)])
        #expect(state.dueDateEdits.isEmpty)

        let stored = UserDefaults.lhf.dictionary(forKey: key) as? [String: Date]
        #expect(stored == planted, "the shared key is exactly as it was planted")
    }

    // MARK: The store

    @Test("the store round-trips dates exactly, skips damaged entries, and removes the key when empty")
    func storeRoundTrip() {
        let suite = "lhf.due-date-edit-store.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DueDateEditStore(defaults: defaults)
        #expect(store.load().isEmpty)

        let precise = Date(timeIntervalSinceReferenceDate: 812_345_678.123456)
        store.save(["canvas:a": precise, "gradescope:b": Date(timeIntervalSinceReferenceDate: 900_000_000)])
        #expect(store.load()["canvas:a"] == precise, "bit-for-bit, not rounded to a second")
        #expect(store.load().count == 2)

        // A damaged entry costs itself, never its neighbours.
        defaults.set(["canvas:a": precise, "canvas:bad": "not a date"], forKey: SharedDefaults.dueDateEditsKey)
        #expect(store.load() == ["canvas:a": precise])

        store.save([:])
        #expect(defaults.object(forKey: SharedDefaults.dueDateEditsKey) == nil)
    }

    // MARK: The widget's class name

    @Test("the widget shows the student's rename for a class, and Misc for a blank one")
    func widgetUsesTheDisplayedClassName() throws {
        let h = try Harness()
        defer { h.tearDown() }
        let now = Self.now()
        let renamed = item("renamed", "Widget renamed class", due: now.addingTimeInterval(3_600),
                           course: Self.otherCourse)
        let plain = item("plain", "Widget plain class", due: now.addingTimeInterval(7_200))
        let blank = item("blank", "Widget blank class", due: now.addingTimeInterval(10_800), course: "")
        h.syncGradescope([renamed, plain, blank], at: now)

        // Same convention as the other rename tests: a code no other suite uses,
        // and the rename undone on the way out.
        h.state.renameCourse(Self.otherCourse, to: "Algorithms")
        defer { h.state.renameCourse(Self.otherCourse, to: "") }

        func course(of title: String) -> String? {
            h.state.widgetNextDueItems().first { $0.title == title }?.course
        }
        #expect(course(of: "Widget renamed class") == "Algorithms")
        #expect(course(of: "Widget plain class") == Self.course, "an un-renamed class keeps its code")
        #expect(course(of: "Widget blank class") == "Misc", "the same word the cards use")

        // The cards read the same string through `displayCourse(overrides:)`.
        let overrides = h.state.courseNameOverrides
        #expect(renamed.displayCourse(overrides: overrides) == "Algorithms")
        #expect(blank.displayCourse(overrides: overrides) == "Misc")

        // Clearing the rename goes back to the code.
        h.state.renameCourse(Self.otherCourse, to: "")
        #expect(course(of: "Widget renamed class") == Self.otherCourse)
    }
}
