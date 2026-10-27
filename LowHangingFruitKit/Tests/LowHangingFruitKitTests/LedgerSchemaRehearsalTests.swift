import Foundation
import SwiftData
import Testing
@testable import LowHangingFruitKit

// MARK: - Frozen models (fixtures)

/// A frozen copy of the ledger's V1 model, exactly as it shipped.
///
/// This is a fixture, not a mirror: it is deliberately never updated when
/// `StoredAssignment` changes. Its job is to write a store file the way a
/// 3.x phone already holds one, so the tests below can open that file with the
/// *current* code. Without it the only way to learn that a model change
/// broke every installed ledger is a phone, after release.
///
/// When the live model needs a change, the workflow is the one
/// `LedgerSchema.swift` describes: freeze the live model into the app's own
/// `LedgerSchemaV1`, make the changed one `LedgerSchemaV2`, append a stage.
/// `RehearsalLedgerSchemaV2` below is that migration, rehearsed end to end
/// against a throwaway plan, so the first real one is not also the first run.
enum FrozenLedgerSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }
    static var models: [any PersistentModel.Type] { [StoredAssignment.self] }

    @Model
    final class StoredAssignment {
        var id: String = ""
        var sourceRaw: String = ""
        var sourceID: String = ""
        var kindRaw: String = ""
        var course: String = ""
        var title: String = ""
        var dueAt: Date?
        var urlString: String?
        var termYear: Int?
        var termSeasonRaw: Int?
        var firstSeen: Date = Date(timeIntervalSince1970: 0)
        var lastSeenInFeed: Date = Date(timeIntervalSince1970: 0)
        var isGoneFromFeed: Bool = false
        var completedAt: Date?
        var userCompleted: Bool = false
        var isCompletionOnly: Bool = false
        var canvasSubmitted: Bool = false
        var gradescopeSubmitted: Bool = false
        var canvasSubmissionObservedAt: Date?
        var gradescopeSubmissionObservedAt: Date?
        var scoreEarned: Double?
        var scoreMax: Double?
        var archivedTermYear: Int?
        var archivedTermSeasonRaw: Int?
        var linkedID: String?
        var pairingConfirmedAt: Date?

        init() {}
    }
}

/// What a V2 would look like: V1 plus one new optional field. Test-only; the
/// app has no V2. Used to run a real staged migration through
/// `LedgerContainer` and `LedgerStoreBackup`.
enum RehearsalLedgerSchemaV2: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(2, 0, 0) }
    static var models: [any PersistentModel.Type] { [StoredAssignment.self] }

    @Model
    final class StoredAssignment {
        var id: String = ""
        var sourceRaw: String = ""
        var sourceID: String = ""
        var kindRaw: String = ""
        var course: String = ""
        var title: String = ""
        var dueAt: Date?
        var urlString: String?
        var termYear: Int?
        var termSeasonRaw: Int?
        var firstSeen: Date = Date(timeIntervalSince1970: 0)
        var lastSeenInFeed: Date = Date(timeIntervalSince1970: 0)
        var isGoneFromFeed: Bool = false
        var completedAt: Date?
        var userCompleted: Bool = false
        var isCompletionOnly: Bool = false
        var canvasSubmitted: Bool = false
        var gradescopeSubmitted: Bool = false
        var canvasSubmissionObservedAt: Date?
        var gradescopeSubmissionObservedAt: Date?
        var scoreEarned: Double?
        var scoreMax: Double?
        var archivedTermYear: Int?
        var archivedTermSeasonRaw: Int?
        var linkedID: String?
        var pairingConfirmedAt: Date?
        /// The new field: optional, so the stage is lightweight.
        var accountID: String?

        init() {}
    }
}

enum RehearsalLedgerMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [FrozenLedgerSchemaV1.self, RehearsalLedgerSchemaV2.self] }
    static var stages: [MigrationStage] {
        [.lightweight(fromVersion: FrozenLedgerSchemaV1.self, toVersion: RehearsalLedgerSchemaV2.self)]
    }
}

// MARK: - Tests

/// B14 of `docs/HARDENING_PLAN_2026-10-25.md`: rehearse the first schema
/// change before it is needed.
///
/// The fixture store is built inside each test from the frozen V1 model above
/// rather than checked in as a binary: SwiftData writes the file the same way
/// under `swift test` as on a phone, so a generated file is a real on-disk V1
/// store, it cannot rot, and the repository holds no student-shaped binary.
@Suite("Ledger schema rehearsal", .serialized)
struct LedgerSchemaRehearsalTests {

    // MARK: Scaffolding

    private func scratchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ledger-rehearsal-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func config(_ url: URL) -> ModelConfiguration {
        ModelConfiguration(url: url, cloudKitDatabase: .none)
    }

    /// Writes a V1 store with three rows (one ticked off) and returns the live
    /// container, so a test can choose to keep it open (an uncheckpointed WAL).
    @discardableResult
    private func writeFrozenV1Store(at url: URL, rows: Int = 3) throws -> ModelContainer {
        let container = try ModelContainer(
            for: Schema(versionedSchema: FrozenLedgerSchemaV1.self),
            configurations: config(url)
        )
        let context = ModelContext(container)
        for index in 0..<rows {
            let row = FrozenLedgerSchemaV1.StoredAssignment()
            row.id = "canvas:\(index)"
            row.sourceRaw = "canvas"
            row.sourceID = "\(index)"
            row.kindRaw = "assignment"
            row.course = "CIS 1110"
            row.title = "Problem set \(index)"
            row.dueAt = Date(timeIntervalSince1970: 1_900_000_000 + Double(index) * 86_400)
            row.firstSeen = Date(timeIntervalSince1970: 1_800_000_000)
            row.lastSeenInFeed = Date(timeIntervalSince1970: 1_800_000_000)
            if index == 0 {
                row.userCompleted = true
                row.completedAt = Date(timeIntervalSince1970: 1_850_000_000)
            }
            context.insert(row)
        }
        try context.save()
        return container
    }

    private func liveRows(at url: URL) throws -> [StoredAssignment] {
        let container = try LedgerContainer.make(config(url))
        return try ModelContext(container).fetch(FetchDescriptor<StoredAssignment>(sortBy: [SortDescriptor(\.id)]))
    }

    // MARK: The frozen model still describes the live one

    /// The guard that makes the first schema change a decision instead of an
    /// accident. If `StoredAssignment` gains, loses or retypes a property
    /// without a `LedgerSchemaV2` and a stage, an installed store no longer
    /// matches the model the app opens it with. This fails first, in the
    /// edit, not on a phone.
    @Test("the live ledger model still matches the frozen V1 fixture")
    func liveModelMatchesFrozenV1() {
        func describe(_ schema: Schema) -> [String] {
            schema.entities.flatMap { entity in
                entity.attributes.map { "\(entity.name).\($0.name):\($0.valueType):\($0.isOptional)" }
            }.sorted()
        }
        let frozen = describe(Schema(versionedSchema: FrozenLedgerSchemaV1.self))
        let live = describe(Schema(versionedSchema: LedgerSchemaV1.self))
        #expect(!frozen.isEmpty)
        #expect(live == frozen, """
            StoredAssignment no longer matches the frozen V1 ledger model. Do not edit \
            this fixture: freeze the old model as LedgerSchemaV1, make the changed one \
            LedgerSchemaV2, and append a MigrationStage (see LedgerSchema.swift and \
            RehearsalLedgerSchemaV2 in this file for the rehearsed shape).
            """)
        #expect(LedgerSchemaV1.versionIdentifier == FrozenLedgerSchemaV1.versionIdentifier)
    }

    // MARK: An on-disk V1 store opens through the current plan

    @Test("an on-disk V1 store opens through the current plan and keeps every row")
    func onDiskV1OpensThroughCurrentPlan() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Assignments.store")
        try writeFrozenV1Store(at: url)

        let rows = try liveRows(at: url)

        #expect(rows.map(\.id) == ["canvas:0", "canvas:1", "canvas:2"])
        #expect(rows.first?.userCompleted == true)
        #expect(rows.first?.completedAt == Date(timeIntervalSince1970: 1_850_000_000))
        #expect(rows.last?.title == "Problem set 2")
        // Same version as the file: nothing to migrate, nothing copied.
        #expect(!FileManager.default.fileExists(atPath: LedgerStoreBackup.backupURL(for: url).path))
    }

    @Test("the app's own AssignmentStore opens the V1 fixture and sees the completion")
    @MainActor
    func assignmentStoreOpensV1Fixture() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Assignments.store")
        try writeFrozenV1Store(at: url)

        let store = try AssignmentStore(url: url)

        #expect(store.rowCount() == 3)
        #expect(store.completionRecord().ids == ["canvas:0"])
    }

    @Test("the widget reader opens the V1 fixture through the same door as the app")
    func widgetReaderUsesTheSharedDoor() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Assignments.store")
        try writeFrozenV1Store(at: url)
        // The store predates the marker: only an open through `LedgerContainer`
        // writes one, so its presence is the proof of which door was used.
        #expect(!FileManager.default.fileExists(atPath: LedgerStoreBackup.markerURL(for: url).path))

        let scratch = UserDefaults(suiteName: "ledger-rehearsal-\(UUID().uuidString)")!
        let snapshot = LedgerWidgetReader.snapshot(
            storeURL: url, now: Date(timeIntervalSince1970: 1_899_000_000), defaults: scratch
        )

        #expect(snapshot?.items.map(\.title) == ["Problem set 1", "Problem set 2"])
        #expect(FileManager.default.fileExists(atPath: LedgerStoreBackup.markerURL(for: url).path))
        #expect(LedgerStoreBackup.recordedVersion(for: url) == LedgerSchemaV1.versionIdentifier)
    }

    // MARK: A migration, rehearsed

    @Test("a V1 to V2 migration keeps every row, and a copy of the V1 file was taken first")
    func rehearsedMigrationKeepsRowsAndTakesACopy() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Assignments.store")
        try writeFrozenV1Store(at: url)
        let backup = LedgerStoreBackup.backupURL(for: url)
        #expect(!FileManager.default.fileExists(atPath: backup.path))

        // Open the V1 file at V2, through the same door the app uses.
        do {
            let container = try LedgerContainer.make(
                config(url), schema: RehearsalLedgerSchemaV2.self, plan: RehearsalLedgerMigrationPlan.self
            )
            let context = ModelContext(container)
            let rows = try context.fetch(FetchDescriptor<RehearsalLedgerSchemaV2.StoredAssignment>(sortBy: [SortDescriptor(\.id)]))
            #expect(rows.map(\.id) == ["canvas:0", "canvas:1", "canvas:2"])
            #expect(rows.first?.userCompleted == true)
            #expect(rows.allSatisfy { $0.accountID == nil })
            // The new field works on a migrated row.
            rows[1].accountID = "user-77"
            try context.save()
        }

        // The copy exists, and is still a V1 store with the V1 rows: opening
        // it at V1 is how a student's file would be restored.
        #expect(FileManager.default.fileExists(atPath: backup.path))
        let restored = try ModelContainer(
            for: Schema(versionedSchema: FrozenLedgerSchemaV1.self), configurations: config(backup)
        )
        let restoredRows = try ModelContext(restored).fetch(FetchDescriptor<FrozenLedgerSchemaV1.StoredAssignment>())
        #expect(restoredRows.count == 3)
        #expect(restoredRows.filter(\.userCompleted).map(\.id) == ["canvas:0"])

        // The marker moved, so the next launch does not look like a migration.
        #expect(LedgerStoreBackup.recordedVersion(for: url) == RehearsalLedgerSchemaV2.versionIdentifier)
    }

    @Test("the copy is taken once and never overwritten")
    func copyIsTakenOnce() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Assignments.store")
        try writeFrozenV1Store(at: url)
        let version2 = RehearsalLedgerSchemaV2.versionIdentifier

        let first = LedgerStoreBackup.prepare(storeURL: url, opening: version2)
        let backup = LedgerStoreBackup.backupURL(for: url)
        guard case .backedUp(let at) = first else {
            Issue.record("expected a copy, got \(first)")
            return
        }
        #expect(at == backup)
        let original = try Data(contentsOf: backup)

        // The store changes (a half-migrated or damaged file), and a second
        // attempt at the same migration must not replace the good copy.
        try Data("damaged".utf8).write(to: url)
        let second = LedgerStoreBackup.prepare(storeURL: url, opening: version2)

        #expect(second == .alreadyBackedUp)
        #expect(try Data(contentsOf: backup) == original)
        // No half-written staging file is left behind either.
        #expect(!FileManager.default.fileExists(atPath: backup.path + ".partial"))
    }

    @Test("nothing is copied on a fresh install, an ordinary launch, or a downgrade")
    func noCopyWhenNothingMigrates() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Assignments.store")

        // Fresh install: no file yet.
        #expect(LedgerStoreBackup.prepare(storeURL: url, opening: RehearsalLedgerSchemaV2.versionIdentifier) == .notNeeded)
        _ = try LedgerContainer.make(config(url))
        #expect(LedgerStoreBackup.recordedVersion(for: url) == LedgerSchemaV1.versionIdentifier)

        // Ordinary launch: the marker already says V1 and V1 is what opens.
        #expect(LedgerStoreBackup.prepare(storeURL: url, opening: LedgerSchemaV1.versionIdentifier) == .notNeeded)

        // Downgrade: the marker is ahead of what is about to open.
        LedgerStoreBackup.recordOpened(storeURL: url, version: RehearsalLedgerSchemaV2.versionIdentifier)
        #expect(LedgerStoreBackup.recordedVersion(for: url) == RehearsalLedgerSchemaV2.versionIdentifier)
        #expect(LedgerStoreBackup.prepare(storeURL: url, opening: LedgerSchemaV1.versionIdentifier) == .notNeeded)

        #expect(!FileManager.default.fileExists(atPath: LedgerStoreBackup.backupURL(for: url).path))
    }

    @Test("the copy carries writes that are still only in the write-ahead log")
    func copyCarriesTheWriteAheadLog() throws {
        let directory = try scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Assignments.store")
        // Keep the writing container alive: SQLite checkpoints the log into
        // the main file when the last connection closes, so while this is
        // open the rows may exist only in `Assignments.store-wal`.
        let writer = try writeFrozenV1Store(at: url, rows: 5)
        defer { _ = writer }
        let wal = URL(fileURLWithPath: url.path + "-wal")
        let walSize = (try? FileManager.default.attributesOfItem(atPath: wal.path)[.size] as? Int) ?? 0
        try #require(walSize > 0, "the scenario needs an uncheckpointed log to be meaningful")

        let outcome = LedgerStoreBackup.prepare(storeURL: url, opening: RehearsalLedgerSchemaV2.versionIdentifier)
        guard case .backedUp(let backup) = outcome else {
            Issue.record("expected a copy, got \(outcome)")
            return
        }

        let restored = try ModelContainer(
            for: Schema(versionedSchema: FrozenLedgerSchemaV1.self), configurations: config(backup)
        )
        let restoredRows = try ModelContext(restored).fetch(FetchDescriptor<FrozenLedgerSchemaV1.StoredAssignment>())
        #expect(restoredRows.count == 5)
    }

    @Test("an in-memory ledger writes no marker and takes no copy")
    func inMemoryTakesNoCopy() throws {
        _ = try LedgerContainer.make(ModelConfiguration(isStoredInMemoryOnly: true, cloudKitDatabase: .none))
    }
}
