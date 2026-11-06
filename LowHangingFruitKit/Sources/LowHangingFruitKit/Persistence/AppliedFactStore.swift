import Foundation
import SwiftData

/// Versioned schema for the applied-fact store, the twin of
/// `GradeHistorySchemaV1`. 1.0.0 from the first file written, so the next
/// change is a migration and not a failed open that silently drops the
/// student's verdicts.
enum AppliedFactSchemaV1: VersionedSchema {
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    static var models: [any PersistentModel.Type] { [StoredAppliedFact.self] }
}

enum AppliedFactMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [AppliedFactSchemaV1.self] }

    static var stages: [MigrationStage] { [] }
}

/// The phone's copy of the facts the server extracted from pooled course
/// documents, with what was done with each and what the student said.
///
/// **Why its own store file, and not a model in the ledger's schema.** Adding
/// an entity to `LedgerSchemaV1` would force a ledger migration on every
/// phone, and the widget opens `Assignments.store` with a one-entity container
/// that would then disagree with the app about the file. Facts are of no use
/// to the widget. The cost of a separate file is nothing; the cost of touching
/// the ledger's schema is the one thing in this app that cannot be undone.
///
/// **A fact never deletes or completes anything**, and this store never
/// deletes a fact on its own initiative: `upsert` only adds. The two removals
/// that exist are deliberate and named: `purge(courseIDs:)` (disconnecting
/// Canvas, mirroring how course material is cleared) and
/// `removeFacts(documentID:contentHash:)` (the server withdrew a revision).
@MainActor
public final class AppliedFactStore {
    public static let appGroupID = AssignmentStore.appGroupID

    private let container: ModelContainer
    private var context: ModelContext { container.mainContext }

    public let isPersistent: Bool
    /// Why the store is running in memory when the file could not be used;
    /// nil on a file store and on the deliberate in-memory path.
    public let storageFailureReason: String?

    public private(set) var lastSaveError: String?
    public private(set) var failedSaveCount: Int = 0
    public private(set) var lastReadError: String?
    public private(set) var failedReadCount: Int = 0

    private static func makeContainer(_ config: ModelConfiguration) throws -> ModelContainer {
        try ModelContainer(
            for: Schema(versionedSchema: AppliedFactSchemaV1.self),
            migrationPlan: AppliedFactMigrationPlan.self,
            configurations: config
        )
    }

    // cloudKitDatabase is pinned to .none for the reason documented on
    // GradeHistoryStore: the default adopts the app's iCloud container.
    public init(inMemory: Bool = false, storageFailureReason: String? = nil) throws {
        let config = ModelConfiguration(isStoredInMemoryOnly: inMemory, cloudKitDatabase: .none)
        self.container = try Self.makeContainer(config)
        self.isPersistent = !inMemory
        self.storageFailureReason = inMemory ? storageFailureReason : nil
    }

    public init(url: URL) throws {
        let config = ModelConfiguration(url: url, cloudKitDatabase: .none)
        self.container = try Self.makeContainer(config)
        self.isPersistent = true
        self.storageFailureReason = nil
    }

    /// App Group file when entitled; hermetic in-memory under tests (the
    /// `isTestRunner` guard every store here carries, see CLAUDE.md); an
    /// in-memory fallback that says why otherwise.
    public static func makeDefault() -> AppliedFactStore? {
        if SharedDefaults.isTestRunner { return try? AppliedFactStore(inMemory: true) }
        let url = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID)?
            .appending(path: "AppliedFacts.store")
        return openOrFallBack(at: url)
    }

    static func openOrFallBack(at url: URL?) -> AppliedFactStore? {
        let failure: String
        if let url {
            do {
                return try AppliedFactStore(url: url)
            } catch {
                failure = "Saved course updates couldn't be opened (\(error.localizedDescription)). "
                    + "This session is being kept in memory only."
            }
        } else {
            failure = "The app isn't entitled for its shared App Group container, "
                + "so course updates can't be saved to disk."
        }
        return try? AppliedFactStore(inMemory: true, storageFailureReason: failure)
    }

    // MARK: Reading

    /// Every stored fact, oldest `seq` first. A failed fetch reads as empty
    /// and is counted (`failedReadCount`). Rows this build cannot decode (a
    /// type from a newer build) are skipped, not deleted.
    public func all() -> [AppliedFact] {
        ((try? allRows()) ?? []).compactMap(\.snapshot).sorted { $0.seq < $1.seq }
    }

    /// The facts that were applied to one ledger row (`Assignment.id`).
    public func facts(forItem itemID: String) -> [AppliedFact] {
        let rows = (try? fetch(FetchDescriptor<StoredAppliedFact>(
            predicate: #Predicate { $0.resolvedItemID == itemID }
        ))) ?? []
        return rows.compactMap(\.snapshot).sorted { $0.seq < $1.seq }
    }

    /// The highest `seq` stored, 0 when empty: the `factsSince` to send. A
    /// plain max rather than the server's own `factsCursor` because that is
    /// not persisted anywhere; the cost is re-reading rows the server
    /// withheld, which `upsert` dedupes. Callers may prefer
    /// `max(cursor(), response.factsCursor ?? 0)` within one session.
    public func cursor() -> Int {
        ((try? allRows()) ?? []).map(\.seq).max() ?? 0
    }

    // MARK: Writing

    /// Stores facts not already held. Idempotent by fact id: a fact seen
    /// again is left exactly as it is, so the student's override and the
    /// applied record survive a re-read. Never deletes. Returns how many rows
    /// were added.
    @discardableResult
    public func upsert(facts: [CourseFactWire], now: Date) -> Int {
        guard !facts.isEmpty, let existing = try? allRows() else { return 0 }
        var known = Set(existing.map(\.factID))
        var added = 0
        for wire in facts {
            let fact = AppliedFact(wire: wire, receivedAt: now)
            guard known.insert(fact.id).inserted else { continue }
            context.insert(StoredAppliedFact(fact: fact))
            added += 1
        }
        if added > 0 { saveChanges() }
        return added
    }

    /// Records the student's verdict. `.none` clears it. Returns false when
    /// no such fact is held or the save failed.
    @discardableResult
    public func setOverride(factID: String, to override: FactOverride, now: Date) -> Bool {
        guard let row = (try? rows(factID: factID))?.first else { return false }
        row.studentOverrideRaw = override.rawValue
        row.overrideAt = override == .none ? nil : now
        return saveChanges()
    }

    /// Writes an evaluation back: which facts applied (and to which row),
    /// and which a newer fact replaced. Only the bookkeeping columns change;
    /// the fact's own content and the student's override are never touched.
    /// A fact an evaluation did not list as applied loses its `appliedAt`
    /// (it may since have been rejected or superseded), but nothing is ever
    /// removed.
    @discardableResult
    public func record(_ effects: FactEffects, now: Date) -> Bool {
        guard let rows = try? allRows() else { return false }
        var superseded: [String: Int] = [:]
        for entry in effects.redundant {
            if case let .supersededBySeq(seq) = entry.reason { superseded[entry.factID] = seq }
        }
        for row in rows {
            row.resolvedItemID = effects.resolvedItems[row.factID]
            row.supersededBySeq = superseded[row.factID]
            if effects.applied.contains(row.factID) {
                if row.appliedAt == nil { row.appliedAt = now }
            } else {
                row.appliedAt = nil
            }
        }
        return saveChanges()
    }

    /// Disconnect: removes every fact of the given Canvas courses, with the
    /// student's verdicts on them. The one wholesale deletion path, called
    /// where course material is cleared, because facts are derived from that
    /// material and a signed-out phone should hold none of it.
    @discardableResult
    public func purge(courseIDs: Set<String>) -> Int {
        guard !courseIDs.isEmpty, let rows = try? allRows() else { return 0 }
        let doomed = rows.filter { courseIDs.contains($0.courseID) }
        for row in doomed { context.delete(row) }
        if !doomed.isEmpty { saveChanges() }
        return doomed.count
    }

    /// Drops the facts a given revision of a document produced: the server
    /// withdraws a fact whose document has since been edited, and a phone
    /// that already stored it must not keep showing a cancellation the
    /// instructor took back. Scoped to the exact `(document, hash)` so the
    /// new revision's facts, stored under their own hash, are untouched.
    @discardableResult
    public func removeFacts(documentID: String, contentHash: String) -> Int {
        guard let rows = try? allRows() else { return 0 }
        // A rejected fact is the student's verdict, kept: the revised post's
        // fact has a new id, and the engine matches the rejection by (course,
        // type, target) to keep an undone cancel undone. Deleting it here
        // would let the very edit that "fixes" the post bring the cancel back.
        let doomed = rows.filter {
            $0.documentID == documentID && $0.contentHash == contentHash
                && $0.studentOverrideRaw != FactOverride.rejected.rawValue
        }
        for row in doomed { context.delete(row) }
        if !doomed.isEmpty { saveChanges() }
        return doomed.count
    }

    /// Drops every fact of a document the server no longer lists (the post
    /// was deleted, or the instructor took it back), whatever revision the
    /// fact came from. Rejected facts stay, as in `removeFacts(documentID:contentHash:)`:
    /// the verdict outlives the fact. Returns how many were removed.
    @discardableResult
    public func removeFacts(documentID: String) -> Int {
        guard let rows = try? allRows() else { return 0 }
        let doomed = rows.filter {
            $0.documentID == documentID && $0.studentOverrideRaw != FactOverride.rejected.rawValue
        }
        for row in doomed { context.delete(row) }
        if !doomed.isEmpty { saveChanges() }
        return doomed.count
    }

    // MARK: Internals

    @discardableResult
    private func saveChanges(_ operation: String = #function) -> Bool {
        guard context.hasChanges else { return true }
        do {
            try context.save()
            lastSaveError = nil
            return true
        } catch {
            failedSaveCount += 1
            lastSaveError = "\(operation) — \(error.localizedDescription)"
            return false
        }
    }

    private func rows(factID: String) throws -> [StoredAppliedFact] {
        try fetch(FetchDescriptor<StoredAppliedFact>(predicate: #Predicate { $0.factID == factID }))
    }

    private func allRows() throws -> [StoredAppliedFact] {
        try fetch(FetchDescriptor<StoredAppliedFact>())
    }

    private func fetch(_ descriptor: FetchDescriptor<StoredAppliedFact>, _ operation: String = #function) throws -> [StoredAppliedFact] {
        do {
            let rows = try context.fetch(descriptor)
            lastReadError = nil
            return rows
        } catch {
            failedReadCount += 1
            lastReadError = "\(operation) — \(error.localizedDescription)"
            throw error
        }
    }
}
