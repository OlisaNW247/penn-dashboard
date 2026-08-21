import Testing
import Foundation
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// Covers the ledger hardening pass: pruning, user-created work, and completion
/// as a projection rather than a parallel truth.
@MainActor
struct LedgerHardeningTests {

    private func canvas(_ id: String, course: String, title: String = "HW", due: Date?) -> Assignment {
        Assignment(source: .canvas, sourceID: id, kind: .assignment,
                   course: course, title: title, dueAt: due,
                   url: URL(string: "https://canvas.upenn.edu/courses/1/assignments/\(id)"))
    }

    private func manual(_ title: String, course: String, due: Date?) -> ManualAssignment {
        ManualAssignment(title: title, course: course, dueAt: due)
    }

    // MARK: Pruning

    @Test("an aged-out row is deleted, not just hidden")
    func pruneRemovesAgedRows() throws {
        let store = try AssignmentStore(inMemory: true)
        let longAgo = Date().addingTimeInterval(-90 * 86_400)

        _ = store.reconcile([canvas("p1", course: "PRUNE 100", due: longAgo)], source: .canvas)
        #expect(store.rowCount() == 1)

        // Gone from the feed and long past due: invisible to every read, and
        // previously immortal on disk.
        _ = store.reconcile([canvas("p2", course: "PRUNE 100", due: Date())], source: .canvas)

        #expect(!store.currentAssignments().contains { $0.sourceID == "p1" })
        #expect(store.rowCount() == 1, "the aged row should have been collected, not merely filtered")
    }

    @Test("pruning never reclaims finished work")
    func pruneSparesFinishedWork() throws {
        let store = try AssignmentStore(inMemory: true)
        let longAgo = Date().addingTimeInterval(-90 * 86_400)
        let done = canvas("done1", course: "PRUNE 200", due: longAgo)

        _ = store.reconcile([done], source: .canvas)
        store.setCompleted(ids: [done.id], at: longAgo)

        // Drops out of the feed entirely, well past the grace period.
        _ = store.reconcile([canvas("other", course: "PRUNE 200", due: Date())], source: .canvas)

        #expect(store.rowCount() == 2, "a completed assignment is the archive, not an abandoned item")
        #expect(store.stats().finished == 1)
    }

    @Test("pruning is bounded by the same predicate as the read filter")
    func pruneLeavesUndatedAndPresentRows() throws {
        let store = try AssignmentStore(inMemory: true)
        // Undated, and still in the feed: neither can age out.
        _ = store.reconcile([canvas("u1", course: "PRUNE 300", due: nil),
                             canvas("k1", course: "PRUNE 300", due: Date())], source: .canvas)
        _ = store.reconcile([canvas("u1", course: "PRUNE 300", due: nil),
                             canvas("k1", course: "PRUNE 300", due: Date())], source: .canvas)
        #expect(store.rowCount() == 2)
        #expect(store.pruneAgedOut() == 0)
    }

    // MARK: User-created work

    @Test("a manual assignment lands on the ledger and survives a reopen")
    func manualWorkIsDurable() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lhf-manual-\(UUID().uuidString).store")
        let item = manual("Read chapter 4", course: "HIST 1000", due: Date().addingTimeInterval(86_400))

        let first = try AssignmentStore(url: url)
        first.upsert([item.asAssignment()])
        #expect(first.assignments(source: .manual).count == 1)

        // A separate store over the same file is what "survives a relaunch"
        // actually means.
        let second = try AssignmentStore(url: url)
        let reloaded = second.assignments(source: .manual).compactMap(ManualAssignment.init)
        #expect(reloaded.count == 1)
        #expect(reloaded.first?.title == "Read chapter 4")
        #expect(reloaded.first?.id == item.id)
    }

    @Test("manual work never ages out however old it gets")
    func manualWorkNeverAges() throws {
        let store = try AssignmentStore(inMemory: true)
        let ancient = manual("Old todo", course: "MISC", due: Date().addingTimeInterval(-365 * 86_400))
        store.upsert([ancient.asAssignment()])

        // Aging requires having left a feed, and manual work was never in one.
        _ = store.reconcile([canvas("x", course: "MISC", due: Date())], source: .canvas)
        #expect(store.pruneAgedOut() == 0)
        #expect(store.assignments(source: .manual).count == 1)
    }

    @Test("deleting a manual assignment is the one removal that really removes")
    func manualDeletionRemovesTheRow() throws {
        let store = try AssignmentStore(inMemory: true)
        let item = manual("Cancel this", course: "MISC", due: Date())
        store.upsert([item.asAssignment()])
        store.delete(ids: [item.asAssignment().id])
        #expect(store.assignments(source: .manual).isEmpty)
    }

    @Test("a recurring occurrence is not mistaken for an editable manual item")
    func recurringOccurrenceIsNotAManualAssignment() throws {
        let task = RecurringTask(
            title: "Weekly reading", course: "ENGL 0900",
            weekday: 2, hour: 9, minute: 0,
            startDate: Date(), endDate: nil, origin: .manual
        )
        let occurrence = try #require(task.upcomingAssignments().first)
        // Same `.manual` source, but not something the add-sheet can edit — the
        // sourceID prefix is what keeps the two apart.
        #expect(occurrence.source == .manual)
        #expect(ManualAssignment(occurrence) == nil)
    }

    @Test("completing one occurrence of a recurring task doesn't complete the rest")
    func recurringOccurrencesHaveDistinctIdentity() throws {
        let task = RecurringTask(
            title: "Weekly reading", course: "ENGL 0900",
            weekday: 2, hour: 9, minute: 0,
            startDate: Date(), endDate: nil, origin: .manual
        )
        let occurrences = task.upcomingAssignments()
        #expect(occurrences.count > 1)
        #expect(Set(occurrences.map(\.id)).count == occurrences.count)
    }

    // MARK: Completion as a projection

    @Test("completion reported by the ledger is what the app shows")
    func completionComesFromTheLedger() throws {
        let store = try AssignmentStore(inMemory: true)
        let item = canvas("c1", course: "COMP 100", due: Date())
        _ = store.reconcile([item], source: .canvas)

        let state = AppState(assignmentStore: store)
        state.markCompleted(item)

        #expect(state.isCompleted(item))
        #expect(store.completionRecord().dates[item.id] != nil)
        #expect(state.completedAssignmentIDs.contains(item.id))

        state.markActive(item)
        #expect(!state.isCompleted(item))
        #expect(store.completionRecord().dates[item.id] == nil)
    }

    @Test("completing an item with no ledger row creates one")
    func completionCreatesAMissingRow() throws {
        let store = try AssignmentStore(inMemory: true)
        let state = AppState(assignmentStore: store)
        // A recurring occurrence: generated on the fly, never reconciled.
        let task = RecurringTask(
            title: "Standup notes", course: "CIS 1200",
            weekday: 3, hour: 10, minute: 0,
            startDate: Date(), endDate: nil, origin: .manual
        )
        let occurrence = try #require(task.upcomingAssignments().first)

        state.markCompleted(occurrence)

        #expect(store.completionRecord().dates[occurrence.id] != nil,
                "completion is exactly what makes an ephemeral occurrence worth persisting")
        #expect(state.isCompleted(occurrence))
    }

    @Test("a completion survives a relaunch without the old UserDefaults copy")
    func completionSurvivesRelaunch() throws {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lhf-completion-\(UUID().uuidString).store")
        let item = canvas("relaunch1", course: "COMP 300", due: Date())

        let first = try AssignmentStore(url: url)
        _ = first.reconcile([item], source: .canvas)
        AppState(assignmentStore: first).markCompleted(item)

        let second = try AssignmentStore(url: url)
        let reopened = AppState(assignmentStore: second)
        #expect(reopened.isCompleted(item))
        #expect(reopened.completionDates[item.id] != nil)
    }

    // MARK: Ledger health

    @Test("a healthy store reports itself healthy, and says why when it isn't")
    func healthReporting() throws {
        let ondisk = try AssignmentStore(url: URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lhf-health-\(UUID().uuidString).store"))
        #expect(ondisk.stats().isHealthy)
        #expect(ondisk.stats().storageFailureReason == nil)

        let memory = try AssignmentStore(inMemory: true, storageFailureReason: "no App Group")
        // In-memory is never "healthy" — that's the whole point of the flag.
        #expect(!memory.stats().isHealthy)
        #expect(memory.stats().storageFailureReason == "no App Group")
    }
}

/// Regression cover for completing a merged Canvas↔Gradescope item when the
/// pools were assigned directly rather than filled by a sync — preview mode and
/// sample data both do that, and preview mode is the path App Store reviewers
/// take because they can't pass Penn SSO.
@MainActor
struct MergedCompletionWithoutSyncTests {

    @Test("completing a merged item records both identities even with no synced rows")
    func bothIdentitiesRecorded() throws {
        let store = try AssignmentStore(inMemory: true)
        let state = AppState(assignmentStore: store)
        let due = Date().addingTimeInterval(86_400)

        let canvasItem = Assignment(source: .canvas, sourceID: "m-c1", kind: .assignment,
                                    course: "CIS 1200", title: "Homework 3", dueAt: due, url: nil)
        let gradescopeItem = Assignment(source: .gradescope, sourceID: "m-g1", kind: .assignment,
                                        course: "CIS 1200", title: "HW3", dueAt: due, url: nil)
        // Assigned directly — nothing reconciled, so neither has a ledger row.
        state.canvasItems = [canvasItem]
        state.gradescopeItems = [gradescopeItem]
        state.markActive(canvasItem)

        let merged = try #require(state.assignments.first { $0.id == canvasItem.id })
        #expect(merged.linkedID == gradescopeItem.id)

        state.markCompleted(merged)

        #expect(state.isCompleted(canvasItem))
        #expect(state.isCompleted(gradescopeItem),
                "the counterpart needs a row too, or half the merge comes back undone")
        #expect(store.completionRecord().dates[gradescopeItem.id] != nil)
    }
}
