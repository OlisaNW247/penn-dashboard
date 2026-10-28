import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// B15's upgrade hazard. Recurring ids used to end in the instant an
/// occurrence lands on in the phone's zone and now end in the instant it would
/// land on in Eastern time. Eastern phones are unchanged; a Pacific phone's
/// ids all change once, and these tests hold that the ticks and edited dates
/// the student already has follow them.
@Suite("Recurring ticks and edited dates survive the id change", .serialized)
@MainActor
struct RecurringOccurrenceRekeyTests {

    private static let pacific = TimeZone(identifier: "America/Los_Angeles")!
    private static let eastern = TimeZone(identifier: "America/New_York")!
    private static let now = Date(timeIntervalSince1970: 1_792_000_000)   // mid-October 2026
    private static let taskID = UUID(uuidString: "11111111-2222-3333-4444-555555555555")!

    private func task() -> RecurringTask {
        RecurringTask(
            id: Self.taskID, title: "Weekly reading", course: "CIS 1110",
            weekday: 3, hour: 21, minute: 0,
            startDate: Date(timeIntervalSince1970: 1_700_000_000), endDate: nil, origin: .manual
        )
    }

    private func calendar(_ zone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return calendar
    }

    /// What the previous builds wrote for an occurrence: the instant itself.
    private func legacyID(_ occurrence: Assignment) -> String {
        "\(occurrence.source.rawValue):\(Self.taskID.uuidString)-\(Int(occurrence.dueAt!.timeIntervalSince1970))"
    }

    private func scratchStore() throws -> (AssignmentStore, URL) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("rekey-\(UUID().uuidString).store")
        return (try AssignmentStore(url: url), url)
    }

    private func scratchDefaults() -> UserDefaults {
        let name = "rekey-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        return defaults
    }

    @Test("a Pacific phone's tick and edited date move to the id this build mints")
    func pacificTicksAndEditsFollow() throws {
        let (store, url) = try scratchStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let defaults = scratchDefaults()
        let editStore = DueDateEditStore(defaults: scratchDefaults())

        let occurrences = task().upcomingAssignments(from: Self.now, weeksAhead: 4, calendar: calendar(Self.pacific))
        try #require(occurrences.count >= 3)
        let ticked = occurrences[0], edited = occurrences[1], untouched = occurrences[2]
        // The ids this build mints are not the ones earlier builds wrote.
        #expect(ticked.id != legacyID(ticked))

        let tickedAt = Date(timeIntervalSince1970: 1_791_000_123)
        let editedTo = Date(timeIntervalSince1970: 1_793_000_000)
        store.setCompleted(ids: [legacyID(ticked)], at: tickedAt)
        editStore.save([legacyID(edited): editedTo])

        let outcome = RecurringOccurrenceRekey.runIfNeeded(
            assignmentStore: store, dueDateEditStore: editStore, defaults: defaults, zone: Self.pacific
        )

        #expect(outcome == .init(completionsCopied: 1, editsCopied: 1))
        let record = store.completionRecord()
        #expect(record.ids.contains(ticked.id))
        #expect(record.dates[ticked.id] == tickedAt)
        #expect(!record.ids.contains(untouched.id))
        #expect(editStore.load()[edited.id] == editedTo)
        // Copied, not moved: the old row and the old edit are still there.
        #expect(record.ids.contains(legacyID(ticked)))
        #expect(editStore.load()[legacyID(edited)] == editedTo)
    }

    @Test("it runs once: a second launch adds nothing and does not chain ids")
    func runsOnce() throws {
        let (store, url) = try scratchStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let defaults = scratchDefaults()
        let editStore = DueDateEditStore(defaults: scratchDefaults())
        let occurrence = try #require(
            task().upcomingAssignments(from: Self.now, weeksAhead: 2, calendar: calendar(Self.pacific)).first
        )
        store.setCompleted(ids: [legacyID(occurrence)], at: Self.now)

        RecurringOccurrenceRekey.runIfNeeded(assignmentStore: store, dueDateEditStore: editStore, defaults: defaults, zone: Self.pacific)
        let afterFirst = store.completionRecord()
        let second = RecurringOccurrenceRekey.runIfNeeded(
            assignmentStore: store, dueDateEditStore: editStore, defaults: defaults, zone: Self.pacific
        )

        #expect(second == .init())
        #expect(store.completionRecord() == afterFirst)
        #expect(defaults.bool(forKey: RecurringOccurrenceRekey.doneKey))
    }

    @Test("an Eastern phone's ids do not change, so nothing is copied")
    func easternIsAUnchanged() throws {
        let (store, url) = try scratchStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let editStore = DueDateEditStore(defaults: scratchDefaults())
        let occurrence = try #require(
            task().upcomingAssignments(from: Self.now, weeksAhead: 2, calendar: calendar(Self.eastern)).first
        )
        #expect(occurrence.id == legacyID(occurrence))
        store.setCompleted(ids: [occurrence.id], at: Self.now)
        editStore.save([occurrence.id: Self.now])

        let outcome = RecurringOccurrenceRekey.runIfNeeded(
            assignmentStore: store, dueDateEditStore: editStore, defaults: scratchDefaults(), zone: Self.eastern
        )
        #expect(outcome == .init())
        #expect(store.completionRecord().ids == [occurrence.id])
    }

    @Test("only occurrence ids are touched: one-off manual tasks, Canvas rows and ticks with no time are left alone")
    func otherIDsAreLeftAlone() throws {
        let (store, url) = try scratchStore()
        defer { try? FileManager.default.removeItem(at: url) }
        let manual = "manual:manual-\(UUID().uuidString)"
        let canvas = "canvas:12345-67890"
        let bareNumber = "manual:\(Self.taskID.uuidString)"   // a UUID with no number on the end
        store.setCompleted(ids: [manual, canvas, bareNumber], at: Self.now)

        let before = store.completionRecord()
        let outcome = RecurringOccurrenceRekey.runIfNeeded(
            assignmentStore: store, dueDateEditStore: nil, defaults: scratchDefaults(), zone: Self.pacific
        )
        #expect(outcome == .init())
        #expect(store.completionRecord() == before)

        #expect(RecurringOccurrenceRekey.newID(forLegacyID: manual, zone: Self.pacific) == nil)
        #expect(RecurringOccurrenceRekey.newID(forLegacyID: canvas, zone: Self.pacific) == nil)
        #expect(RecurringOccurrenceRekey.newID(forLegacyID: bareNumber, zone: Self.pacific) == nil)
        #expect(RecurringOccurrenceRekey.newID(forLegacyID: "no colon", zone: Self.pacific) == nil)
    }

    @Test("with no persistent ledger it does nothing and leaves the flag for a later launch")
    func needsARealLedger() throws {
        let defaults = scratchDefaults()
        let memory = try AssignmentStore(inMemory: true)
        #expect(RecurringOccurrenceRekey.runIfNeeded(assignmentStore: memory, dueDateEditStore: nil, defaults: defaults, zone: Self.pacific) == .init())
        #expect(RecurringOccurrenceRekey.runIfNeeded(assignmentStore: nil, dueDateEditStore: nil, defaults: defaults, zone: Self.pacific) == .init())
        #expect(!defaults.bool(forKey: RecurringOccurrenceRekey.doneKey))
    }

    @Test("AppState runs it at launch, on a ledger that is on disk")
    func appStateRunsIt() throws {
        let (store, url) = try scratchStore()
        defer { try? FileManager.default.removeItem(at: url) }
        // The flag lives in the shared domain, as in production; put back
        // whatever was there so no other suite sees a difference.
        let previous = UserDefaults.lhf.object(forKey: RecurringOccurrenceRekey.doneKey)
        defer {
            if let previous { UserDefaults.lhf.set(previous, forKey: RecurringOccurrenceRekey.doneKey) }
            else { UserDefaults.lhf.removeObject(forKey: RecurringOccurrenceRekey.doneKey) }
        }
        UserDefaults.lhf.removeObject(forKey: RecurringOccurrenceRekey.doneKey)

        _ = AppState(assignmentStore: store)

        #expect(UserDefaults.lhf.bool(forKey: RecurringOccurrenceRekey.doneKey))
    }

    @Test("the new id for a legacy id is the id the generator mints, for every occurrence")
    func newIDIsWhatTheGeneratorMints() {
        for zone in [Self.pacific, TimeZone(identifier: "America/Chicago")!, TimeZone(identifier: "Asia/Tokyo")!] {
            for occurrence in task().upcomingAssignments(from: Self.now, weeksAhead: 10, calendar: calendar(zone)) {
                let mapped = RecurringOccurrenceRekey.newID(forLegacyID: legacyID(occurrence), zone: zone)
                #expect(mapped == occurrence.id, "\(zone.identifier)")
            }
        }
    }
}
