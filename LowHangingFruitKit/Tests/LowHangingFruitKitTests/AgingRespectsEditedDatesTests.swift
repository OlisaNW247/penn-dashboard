import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// The ledger's aging rule used to read only the feed's date. A student who
/// had moved a card to next week (an extension) still had a row that was "gone
/// from the feed and 14 days overdue" the moment Canvas stopped listing it, so
/// `pruneAgedOut` deleted it and `AppState.pruneDueDateEdits` then forgot the
/// edit (hardening plan B3, DAT-02). An item now ages only when every date it
/// has is old.
@MainActor
@Suite("Aging respects edited dates")
struct AgingRespectsEditedDatesTests {
    /// Puts `UserDefaults.lhf` back after each test (see `LHFDefaultsGuard`).
    private let defaultsGuard = LHFDefaultsGuard()

    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let day: TimeInterval = 86_400

    private func canvas(_ id: String, due: Date?) -> Assignment {
        Assignment(source: .canvas, sourceID: id, kind: .assignment, course: "CIS 1200", title: "HW \(id)",
                   dueAt: due, url: URL(string: "https://canvas.upenn.edu/courses/1/assignments/\(id)"))
    }

    /// A store holding `old` (flagged gone from the feed) and `keep` (still
    /// listed), with `edits` in force when the feed stopped listing `old`.
    private func ledger(old: Assignment, edits: [String: Date]) throws -> AssignmentStore {
        let store = try AssignmentStore(inMemory: true)
        let keep = canvas("keep", due: Self.now.addingTimeInterval(3 * Self.day))
        _ = store.reconcile([old, keep], source: .canvas, now: Self.now)
        store.editedDueDates = edits
        _ = store.reconcile([keep], source: .canvas, now: Self.now)
        return store
    }

    @Test("a gone row 20 days overdue survives aging when the student moved it to next week")
    func editedAheadSurvives() throws {
        let old = canvas("old", due: Self.now.addingTimeInterval(-20 * Self.day))
        let nextWeek = Self.now.addingTimeInterval(7 * Self.day)
        let store = try ledger(old: old, edits: [old.id: nextWeek])

        #expect(store.rowCount() == 2)
        #expect(Set(store.currentAssignments(now: Self.now).map(\.id)) == [old.id, "canvas:keep"])
        #expect(store.goneFromFeedIDs(source: .canvas) == [old.id])
    }

    @Test("without the edit the same row is aged out, which is the old behaviour and the control")
    func uneditedStillAgesOut() throws {
        let old = canvas("old", due: Self.now.addingTimeInterval(-20 * Self.day))
        let store = try ledger(old: old, edits: [:])

        #expect(store.rowCount() == 1)
        #expect(store.currentAssignments(now: Self.now).map(\.id) == ["canvas:keep"])
    }

    @Test("an edit that is itself old does not keep a row alive, and one inside the grace period does")
    func oldEditDoesNotProtect() throws {
        let old = canvas("old", due: Self.now.addingTimeInterval(-40 * Self.day))
        let longAgo = try ledger(old: old, edits: [old.id: Self.now.addingTimeInterval(-20 * Self.day)])
        #expect(longAgo.rowCount() == 1)

        let recent = try ledger(old: old, edits: [old.id: Self.now.addingTimeInterval(-10 * Self.day)])
        #expect(recent.rowCount() == 2, "10 days ago is inside the 14-day grace")
    }

    @Test("an edit earlier than the feed's date never makes a row age sooner than before")
    func earlierEditNeverAgesSooner() throws {
        let ahead = canvas("old", due: Self.now.addingTimeInterval(3 * Self.day))
        let store = try ledger(old: ahead, edits: [ahead.id: Self.now.addingTimeInterval(-60 * Self.day)])
        #expect(store.rowCount() == 2)
    }

    @Test("an undated row never ages, edited or not")
    func undatedNeverAges() throws {
        let undated = canvas("old", due: nil)
        let store = try ledger(old: undated, edits: [undated.id: Self.now.addingTimeInterval(-60 * Self.day)])
        #expect(store.rowCount() == 2)
    }

    @Test("a student's edit reaches the ledger as it is made and as it is cleared")
    func appStatePushesEdits() throws {
        let store = try AssignmentStore(inMemory: true)
        let state = AppState(assignmentStore: store)
        state.forceFixtureDataForTesting(false)
        let item = canvas("a", due: Self.now.addingTimeInterval(-20 * Self.day))
        let nextWeek = Self.now.addingTimeInterval(7 * Self.day)

        state.setDueDateEdit(nextWeek, for: item)
        #expect(store.editedDueDates[item.id] == nextWeek)

        state.setDueDateEdit(nil, for: item)
        #expect(store.editedDueDates[item.id] == nil)
    }

    @Test("at launch the edits are in the ledger before it is first read, so the edited row is seeded and its edit kept")
    func launchSeedsTheEditedRow() throws {
        let suite = "aging-edits-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        // Real time, not the pinned clock: `AppState.init` reads the ledger as of now.
        let now = Date()
        let old = canvas("old", due: now.addingTimeInterval(-20 * Self.day))
        let keep = canvas("keep", due: now.addingTimeInterval(3 * Self.day))
        let nextWeek = now.addingTimeInterval(7 * Self.day)

        // The last session: the feed stopped listing `old` while its edit was in force.
        let store = try AssignmentStore(inMemory: true)
        store.editedDueDates = [old.id: nextWeek]
        _ = store.reconcile([old, keep], source: .canvas, now: now)
        _ = store.reconcile([keep], source: .canvas, now: now)
        // This launch: a fresh process holding nothing until `AppState` says so.
        store.editedDueDates = [:]
        DueDateEditStore(defaults: defaults).save([old.id: nextWeek])
        #expect(store.rowCount() == 2)

        let state = AppState(assignmentStore: store, dueDateEditsDefaults: defaults)

        #expect(state.canvasItems.contains { $0.id == old.id })
        #expect(state.editedDueDate(for: old) == nextWeek)
        #expect(store.editedDueDates[old.id] == nextWeek)
        #expect(DueDateEditStore(defaults: defaults).load()[old.id] == nextWeek)
    }
}
