import Testing
import Foundation
import SwiftData
@testable import LowHangingFruitKit

/// The ledger's "exactly one row per assignment" invariant, now that it is
/// enforced in code instead of by the database.
///
/// `StoredAssignment.id` used to carry `@Attribute(.unique)`, so a second row
/// for the same assignment was impossible by construction. CloudKit does not
/// support unique constraints, so that attribute had to go before sync can ever
/// be switched on — and with it went the only thing standing between a
/// duplicated feed entry and two cards for one homework.
///
/// These tests are the replacement guarantee. They matter more than most: this
/// ledger is the fix for "I lost my previous assignments", and duplicating a row
/// is the same class of bug as losing one — the student stops trusting the list.
@MainActor
struct AssignmentLedgerUniquenessTests {

    // MARK: Fixtures

    private func canvas(_ id: String, course: String = "UNIQ 1000", title: String = "HW", due: Date? = nil) -> Assignment {
        Assignment(source: .canvas, sourceID: id, kind: .assignment,
                   course: course, title: title, dueAt: due,
                   url: URL(string: "https://canvas.upenn.edu/courses/1/assignments/\(id)"))
    }

    private func gradescope(_ id: String, course: String = "UNIQ 1000", title: String = "HW", due: Date? = nil, submitted: Bool = false) -> Assignment {
        Assignment(source: .gradescope, sourceID: id, kind: .assignment,
                   course: course, title: title, dueAt: due, url: nil, submitted: submitted)
    }

    private func tempStoreURL() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lhf-uniq-\(UUID().uuidString).store")
    }

    /// Writes rows straight into the store file, bypassing `AssignmentStore`
    /// entirely. This is how a duplicate gets onto the ledger in the first
    /// place once the database no longer refuses one — a CloudKit merge of two
    /// devices that each independently created the row, a restored backup, an
    /// interrupted save. Without `.unique` nothing at the storage layer stops
    /// it, so the store has to cope with finding one already there.
    private func writeRawRows(_ rows: [StoredAssignment], to url: URL) throws {
        let container = try ModelContainer(
            for: StoredAssignment.self,
            configurations: ModelConfiguration(url: url)
        )
        let context = ModelContext(container)
        for row in rows { context.insert(row) }
        try context.save()
    }

    /// How many ids the ledger holds more than one row for. Zero is the whole
    /// point of this file.
    private func duplicateCount(_ store: AssignmentStore) -> Int {
        store.stats().duplicateIDs
    }

    // MARK: A feed that repeats itself

    /// The case the database used to absorb silently. Canvas's ICS feed is a
    /// concatenation of per-course calendars; the same UID showing up twice in
    /// one document (a cross-listed course, a merged section) is a real shape,
    /// and the upsert map is built once *before* the insert loop — so without
    /// an in-loop record of what was just created, the second copy misses the
    /// lookup and inserts a twin.
    @Test("the same id twice in one fetch produces one row")
    func duplicateWithinOneBatch() throws {
        let store = try AssignmentStore(inMemory: true)
        let result = store.reconcile([canvas("1"), canvas("1")], source: .canvas)

        #expect(store.rowCount() == 1)
        #expect(result.items.map(\.id) == ["canvas:1"])
        #expect(duplicateCount(store) == 0)
    }

    @Test("a fetch that repeats an id many times still produces one row")
    func manyCopiesInOneBatch() throws {
        let store = try AssignmentStore(inMemory: true)
        let due = Date().addingTimeInterval(3 * 86_400)
        let repeated = Array(repeating: canvas("1", due: due), count: 12)
        _ = store.reconcile(repeated + [canvas("2", due: due)], source: .canvas)

        #expect(store.rowCount() == 2)
        #expect(duplicateCount(store) == 0)
    }

    /// The later copy is the one Canvas listed last, so its fields are the ones
    /// that should win — the row is upserted, not just deduplicated away.
    @Test("the last copy in a batch wins the display fields")
    func lastCopyWinsFields() throws {
        let store = try AssignmentStore(inMemory: true)
        let result = store.reconcile(
            [canvas("1", title: "HW 3"), canvas("1", title: "HW 3 (revised)")],
            source: .canvas
        )
        #expect(store.rowCount() == 1)
        #expect(result.items.first?.title == "HW 3 (revised)")
    }

    // MARK: Repetition over time

    @Test("reconciling the same feed fifty times never grows the ledger")
    func repeatedReconcilesDoNotGrow() throws {
        let store = try AssignmentStore(inMemory: true)
        let due = Date().addingTimeInterval(5 * 86_400)
        let feed = (1...8).map { canvas("\($0)", due: due) }

        for _ in 0..<50 { _ = store.reconcile(feed, source: .canvas) }

        #expect(store.rowCount() == 8)
        #expect(duplicateCount(store) == 0)
    }

    /// A rolling feed: items drop out and come back. Coming back must land on
    /// the row that was retained while it was gone, not beside it.
    @Test("an item that leaves the feed and returns reuses its original row")
    func vanishAndReturnReusesRow() throws {
        let store = try AssignmentStore(inMemory: true)
        let due = Date().addingTimeInterval(5 * 86_400)
        _ = store.reconcile([canvas("1", due: due), canvas("2", due: due)], source: .canvas)
        store.setCompleted(ids: ["canvas:1"], at: Date())

        for _ in 0..<5 {
            _ = store.reconcile([canvas("2", due: due)], source: .canvas)          // 1 gone
            _ = store.reconcile([canvas("1", due: due), canvas("2", due: due)], source: .canvas)  // 1 back
        }

        #expect(store.rowCount() == 2)
        #expect(duplicateCount(store) == 0)
        // And the completion it was carrying is still on the one row.
        #expect(store.stats().finished == 1)
    }

    @Test("interleaved source reconciles never duplicate either side")
    func interleavedSourcesDoNotDuplicate() throws {
        let store = try AssignmentStore(inMemory: true)
        let due = Date().addingTimeInterval(5 * 86_400)
        let canvasFeed = (1...5).map { canvas("c\($0)", due: due) }
        let gradescopeFeed = (1...4).map { gradescope("g\($0)", due: due) }

        for round in 0..<20 {
            // Alternate, and occasionally hand a source a shortened feed so the
            // gone/returned path is exercised in the interleaving too.
            if round.isMultiple(of: 3) {
                _ = store.reconcile(Array(canvasFeed.dropLast()), source: .canvas)
                _ = store.reconcile(gradescopeFeed, source: .gradescope)
            } else {
                _ = store.reconcile(gradescopeFeed, source: .gradescope)
                _ = store.reconcile(canvasFeed, source: .canvas)
            }
        }

        #expect(store.rowCount() == 9)
        let stats = store.stats()
        #expect(stats.canvas == 5)
        #expect(stats.gradescope == 4)
        #expect(stats.duplicateIDs == 0)
    }

    /// Two sources whose `sourceID`s collide. `Assignment.id` namespaces by
    /// source precisely so this stays two assignments — dedup must not be so
    /// eager it merges them.
    @Test("the same sourceID under two sources stays two rows")
    func sameSourceIDAcrossSourcesStaysDistinct() throws {
        let store = try AssignmentStore(inMemory: true)
        _ = store.reconcile([canvas("7")], source: .canvas)
        _ = store.reconcile([gradescope("7")], source: .gradescope)

        #expect(store.rowCount() == 2)
        #expect(Set(store.currentAssignments().map(\.id)) == ["canvas:7", "gradescope:7"])
        #expect(duplicateCount(store) == 0)
    }

    // MARK: Relaunches

    @Test("reconciling across many simulated relaunches never duplicates")
    func relaunchesDoNotDuplicate() throws {
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let due = Date().addingTimeInterval(5 * 86_400)
        let feed = (1...6).map { canvas("\($0)", due: due) }

        for _ in 0..<6 {
            // Each iteration is a fresh launch: a brand-new store instance over
            // the same file, seeding from the ledger and then syncing.
            let store = try AssignmentStore(url: url)
            #expect(store.currentAssignments().count <= 6)
            _ = store.reconcile(feed, source: .canvas)
            #expect(store.rowCount() == 6)
        }

        let final = try AssignmentStore(url: url)
        #expect(final.rowCount() == 6)
        #expect(duplicateCount(final) == 0)
        #expect(Set(final.currentAssignments().map(\.id)).count == 6)
    }

    // MARK: Duplicates that are already on disk

    /// The load-time sweep. Nothing the app does can produce this state — but a
    /// restored backup or (the reason `.unique` had to go at all) a CloudKit
    /// merge of two devices that each created the row independently can. The
    /// ledger has to heal it rather than show the student two of everything.
    @Test("duplicate rows already on disk are collapsed when the store opens")
    func loadTimeSweepCollapsesDuplicates() throws {
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let due = Date().addingTimeInterval(5 * 86_400)

        try writeRawRows([
            StoredAssignment.make(from: canvas("1", due: due), now: Date()),
            StoredAssignment.make(from: canvas("1", due: due), now: Date()),
            StoredAssignment.make(from: canvas("1", due: due), now: Date()),
            StoredAssignment.make(from: canvas("2", due: due), now: Date()),
        ], to: url)

        let store = try AssignmentStore(url: url)
        #expect(store.rowCount() == 2)
        #expect(duplicateCount(store) == 0)
        #expect(Set(store.currentAssignments().map(\.id)) == ["canvas:1", "canvas:2"])
    }

    /// Merging must be conservative in one direction only: toward keeping
    /// things. Every field here is one a student would notice going missing.
    @Test("collapsing duplicates keeps the safer value of every lifecycle field")
    func sweepMergesLifecycleFieldsConservatively() throws {
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let old = Date().addingTimeInterval(-30 * 86_400)
        let recent = Date().addingTimeInterval(-1 * 86_400)
        let completed = Date().addingTimeInterval(-20 * 86_400)
        let due = Date().addingTimeInterval(5 * 86_400)

        // Two halves of the same assignment. Each knows something the other
        // doesn't, and each is missing something the other has.
        let a = StoredAssignment.make(from: canvas("1", title: "Stale copy", due: due), now: old)
        a.firstSeen = old
        a.lastSeenInFeed = old
        a.isGoneFromFeed = true
        a.completedAt = completed
        a.canvasSubmitted = true
        a.linkedID = "gradescope:99"
        a.pairingConfirmedAt = old

        let b = StoredAssignment.make(from: canvas("1", title: "Fresh copy", due: due), now: recent)
        b.firstSeen = recent
        b.lastSeenInFeed = recent
        b.isGoneFromFeed = false
        b.gradescopeSubmitted = true
        b.scoreEarned = 92
        b.scoreMax = 100

        try writeRawRows([a, b], to: url)

        let store = try AssignmentStore(url: url)
        #expect(store.rowCount() == 1)

        let stats = store.stats()
        #expect(stats.duplicateIDs == 0)
        #expect(stats.earliestFirstSeen == old, "the earliest sighting is how far back the archive reaches")
        #expect(stats.latestSeenInFeed == recent, "the latest sighting is what aging is measured from")
        #expect(stats.finished == 1)
        #expect(stats.withScores == 1)
        #expect(stats.goneFromFeed == 0, "still in the feed on either copy means still in the feed")

        // The freshest copy supplies the display fields; everything worth
        // keeping from the stale one rides along.
        let item = try #require(store.currentAssignments().first)
        #expect(item.title == "Fresh copy")
        #expect(item.scoreEarned == 92)
        #expect(item.linkedID == "gradescope:99")
        #expect(store.submittedCanvasAssignmentIDs() == ["1"])
    }

    /// A duplicate discovered mid-life, not at launch — the store instance is
    /// already open when another writer lands one. The next reconcile has to
    /// find it and fold it in rather than treat it as a second assignment.
    @Test("a duplicate landing under a live store is collapsed by the next sync")
    func sweepCollapsesDuplicateFoundDuringSync() throws {
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let due = Date().addingTimeInterval(5 * 86_400)

        let store = try AssignmentStore(url: url)
        _ = store.reconcile([canvas("1", due: due)], source: .canvas)
        store.setCompleted(ids: ["canvas:1"], at: Date())

        // A second writer adds its own copy of the same assignment.
        try writeRawRows(
            [StoredAssignment.make(from: canvas("1", title: "Twin", due: due), now: Date())],
            to: url
        )

        _ = store.reconcile([canvas("1", due: due)], source: .canvas)
        #expect(store.rowCount() == 1)
        #expect(duplicateCount(store) == 0)
        #expect(store.stats().finished == 1, "the completion must survive the collapse")
    }

    // MARK: Read paths

    /// The widget reads rows directly out of the store file and cannot write,
    /// so it can't run the sweep — it has to tolerate a duplicate instead of
    /// showing the same homework twice in a five-item list.
    @Test("the widget's ledger read shows one entry per assignment")
    func widgetReadDeduplicates() throws {
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let due = Date().addingTimeInterval(2 * 86_400)

        try writeRawRows([
            StoredAssignment.make(from: canvas("1", title: "Homework 4", due: due), now: Date()),
            StoredAssignment.make(from: canvas("1", title: "Homework 4", due: due), now: Date()),
            StoredAssignment.make(from: canvas("2", title: "Homework 5", due: due.addingTimeInterval(3600)), now: Date()),
        ], to: url)

        let snapshot = try #require(LedgerWidgetReader.snapshot(storeURL: url))
        #expect(snapshot.items.count == 2)
        #expect(snapshot.items.map(\.title) == ["Homework 4", "Homework 5"])
    }

    // MARK: Purge

    @Test("purge clears every copy of a source's rows")
    func purgeRemovesDuplicatesToo() throws {
        let url = tempStoreURL()
        defer { try? FileManager.default.removeItem(at: url) }
        let due = Date().addingTimeInterval(2 * 86_400)

        try writeRawRows([
            StoredAssignment.make(from: canvas("1", due: due), now: Date()),
            StoredAssignment.make(from: canvas("1", due: due), now: Date()),
            StoredAssignment.make(from: gradescope("9", due: due), now: Date()),
        ], to: url)

        let store = try AssignmentStore(url: url)
        store.purge(source: .canvas)
        #expect(store.rowCount() == 1)
        #expect(store.currentAssignments().map(\.id) == ["gradescope:9"])
    }
}
