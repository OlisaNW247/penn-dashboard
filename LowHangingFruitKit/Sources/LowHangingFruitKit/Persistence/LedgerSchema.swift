import Foundation
import SwiftData

/// Versioned schema for the assignment ledger.
///
/// Without this, `ModelContainer(for: StoredAssignment.self, …)` pins the store
/// to an anonymous, unversioned schema. That works right up until a field is
/// added, renamed, or retyped — at which point the container init throws on an
/// existing store, `AssignmentStore.makeDefault()` swallows it, and the app
/// silently falls back to an in-memory ledger. The user sees an empty
/// dashboard, every completion and pairing gone, no error and no crash: exactly
/// the data loss the ledger exists to prevent.
///
/// Declaring the schema — even at a single version with no migration stages
/// yet — is what makes the *next* schema change a routine migration instead of
/// a silent wipe. Adding a version later means: freeze the current models into
/// a `LedgerSchemaV<n>` enum, add the new one, and append a `MigrationStage`.
enum LedgerSchemaV1: VersionedSchema {
    /// 1.0.0 matches the version SwiftData assigns an unversioned schema, so
    /// stores created before this file existed (dev builds on v3) are adopted
    /// in place rather than treated as incompatible.
    static var versionIdentifier: Schema.Version { Schema.Version(1, 0, 0) }

    static var models: [any PersistentModel.Type] { [StoredAssignment.self] }
}

/// Migration path across every ledger schema version the app has ever shipped.
///
/// `stages` is empty because V1 is the first — there is nothing to migrate
/// *from* yet. It is deliberately not omitted: the plan is wired into every
/// `ModelContainer` the app builds, so a future version only has to append to
/// `schemas` and `stages` rather than retrofit migration support under a store
/// that already holds a semester of real data.
enum LedgerMigrationPlan: SchemaMigrationPlan {
    static var schemas: [any VersionedSchema.Type] { [LedgerSchemaV1.self] }

    static var stages: [MigrationStage] { [] }

    /// The newest schema in the plan: the one every container opens at.
    /// Declared here, beside `schemas`, so that adding a version is one edit
    /// and the app and the widget cannot disagree about which one is current.
    static var currentSchema: any VersionedSchema.Type { schemas.last ?? LedgerSchemaV1.self }
}

// MARK: - Opening the store: one door for the app and the widget

/// The only place a ledger `ModelContainer` is built.
///
/// **Why one door.** The ledger file is opened by two processes: the app
/// (`AssignmentStore.makeContainer`) and the widget extension
/// (`LedgerWidgetReader`). The widget used to build
/// `ModelContainer(for: StoredAssignment.self, …)`, an anonymous, unversioned
/// schema, while the app went through `LedgerSchemaV1` and
/// `LedgerMigrationPlan`. That is harmless while there is one version. The
/// day a second exists it is a bug in both directions: one process migrates
/// the file, and the other, still asking for the unversioned model, either
/// fails to open it, so the widget sits blank, or opens a store whose model
/// hash it does not know. Building both through this function makes "same
/// schema, same plan" true by construction.
///
/// **Only the app migrates.** The system may launch the widget before the app
/// after an update. `allowMigration: false`, which the widget passes, makes
/// the door refuse (`LedgerContainerError.migrationNeeded`) a store whose
/// recorded version is older than the schema being opened, so the widget shows
/// its snapshot, or nothing, until the app has run and migrated the file with
/// the copy taken first. Letting the widget migrate would put the migration,
/// and its copy, in a process with a few seconds and a memory limit.
///
/// **What it does besides open.** Before the first open at a newer schema
/// than the one a store was last opened at, it copies the store aside
/// (`LedgerStoreBackup`). A migration is the one operation that rewrites
/// every row in a file the student cannot rebuild, and it runs the first
/// time a build is launched on a phone nobody has tested it against.
///
/// `schema` and `plan` are parameters so a test can rehearse a V1 to V2
/// migration against a throwaway plan; production callers pass neither.
enum LedgerContainerError: Error, Equatable {
    /// The store on disk was last opened at `recorded`, older than the
    /// `needed` schema, and the caller is not allowed to migrate it.
    case migrationNeeded(recorded: Schema.Version, needed: Schema.Version)
}

enum LedgerContainer {
    static func make(
        _ configuration: ModelConfiguration,
        schema: any VersionedSchema.Type = LedgerMigrationPlan.currentSchema,
        plan: any SchemaMigrationPlan.Type = LedgerMigrationPlan.self,
        allowMigration: Bool = true
    ) throws -> ModelContainer {
        // An in-memory store has no file to protect and no marker to keep.
        let storeURL: URL? = configuration.isStoredInMemoryOnly ? nil : configuration.url
        if let storeURL, !allowMigration, FileManager.default.fileExists(atPath: storeURL.path) {
            let recorded = LedgerStoreBackup.recordedVersion(for: storeURL)
            if recorded < schema.versionIdentifier {
                throw LedgerContainerError.migrationNeeded(recorded: recorded, needed: schema.versionIdentifier)
            }
        }
        if let storeURL {
            LedgerStoreBackup.prepare(storeURL: storeURL, opening: schema.versionIdentifier)
        }
        let container = try ModelContainer(
            for: Schema(versionedSchema: schema),
            migrationPlan: plan,
            configurations: configuration
        )
        if let storeURL {
            LedgerStoreBackup.recordOpened(storeURL: storeURL, version: schema.versionIdentifier)
        }
        return container
    }
}

/// A copy of the ledger file taken before a migration touches it, and the
/// small marker that says when one is about to.
///
/// **How "about to migrate" is decided.** SwiftData does not say, before it
/// opens a store, which version the file is at. So a marker file beside the
/// store (`Assignments.store.schema-version`, one line, `1.0.0`) records the
/// schema version this store was last opened at, written after every
/// successful open. A store with no marker is a V1 store: every build before
/// this one produced V1 and wrote no marker. A copy is taken only when the
/// marker is *older* than the version about to be opened, so on a fresh
/// install, on every ordinary launch, and under a downgrade nothing is
/// copied, and the first build that ships a V2 copies on its first launch.
///
/// **What the copy is.** `Assignments.store.pre-migration`, with the SQLite
/// write-ahead log beside it (`…pre-migration-wal`) because an uncheckpointed
/// write lives in the `-wal` file, not the main one, and a copy of the main
/// file alone can lose the student's last completions. The `-shm` file is not
/// copied: it is an index SQLite rebuilds from the log on open, and a copy
/// of a live one is a way to produce a pair that disagrees. It is
/// taken **once**: an existing backup is never overwritten, because the second
/// launch of a broken migration would otherwise replace the good copy with the
/// damaged file. The cost is that a later schema change finds the name taken;
/// whoever ships it must move the old copy deliberately. To restore, rename
/// the three files back over the originals with the app closed.
///
/// The copy is finished by a rename (main file last), so a crash mid-copy
/// leaves no `.pre-migration` file, and the next launch tries again, rather
/// than leaving a truncated file that counts as the backup.
///
/// Failing to copy does not stop the open. Refusing to migrate would put the
/// student on the in-memory fallback, which is the failure this exists to
/// prevent; the outcome is returned so a caller can record it.
enum LedgerStoreBackup {
    static let backupSuffix = "pre-migration"
    static let markerSuffix = "schema-version"
    /// SQLite's write-ahead log. Not `-shm`: see the type's note.
    static let sidecars = ["-wal"]

    enum Outcome: Equatable {
        /// No store yet, or the store is already at (or newer than) this version.
        case notNeeded
        /// A backup from an earlier migration is already there and was left alone.
        case alreadyBackedUp
        case backedUp(URL)
        case failed
    }

    static func backupURL(for storeURL: URL) -> URL {
        URL(fileURLWithPath: storeURL.path + "." + backupSuffix)
    }

    static func markerURL(for storeURL: URL) -> URL {
        URL(fileURLWithPath: storeURL.path + "." + markerSuffix)
    }

    /// The version this store was last opened at. V1 when there is no marker
    /// (see the type's note) or the marker cannot be read.
    static func recordedVersion(for storeURL: URL) -> Schema.Version {
        guard let text = try? String(contentsOf: markerURL(for: storeURL), encoding: .utf8) else {
            return LedgerSchemaV1.versionIdentifier
        }
        let parts = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: ".", omittingEmptySubsequences: false)
            .compactMap { Int($0) }
        guard parts.count == 3 else { return LedgerSchemaV1.versionIdentifier }
        return Schema.Version(parts[0], parts[1], parts[2])
    }

    /// Takes the pre-migration copy if opening `version` would migrate `storeURL`.
    @discardableResult
    static func prepare(
        storeURL: URL,
        opening version: Schema.Version,
        fileManager: FileManager = .default
    ) -> Outcome {
        guard fileManager.fileExists(atPath: storeURL.path) else { return .notNeeded }
        guard recordedVersion(for: storeURL) < version else { return .notNeeded }

        let backup = backupURL(for: storeURL)
        guard !fileManager.fileExists(atPath: backup.path) else { return .alreadyBackedUp }

        let staging = URL(fileURLWithPath: backup.path + ".partial")
        var copiedSidecars: [URL] = []
        func cleanUp() {
            try? fileManager.removeItem(at: staging)
            for url in copiedSidecars { try? fileManager.removeItem(at: url) }
        }
        do {
            try? fileManager.removeItem(at: staging)
            for sidecar in sidecars {
                let source = URL(fileURLWithPath: storeURL.path + sidecar)
                guard fileManager.fileExists(atPath: source.path) else { continue }
                let destination = URL(fileURLWithPath: backup.path + sidecar)
                try? fileManager.removeItem(at: destination)
                try fileManager.copyItem(at: source, to: destination)
                copiedSidecars.append(destination)
            }
            try fileManager.copyItem(at: storeURL, to: staging)
            try fileManager.moveItem(at: staging, to: backup)
            return .backedUp(backup)
        } catch {
            cleanUp()
            return .failed
        }
    }

    /// Records that the store at `storeURL` has now been opened at `version`.
    /// Only ever moves the marker forward (or creates it): a process opening an
    /// older schema must not write the older version over a newer one, or the
    /// next launch of the newer build would take a "pre-migration" copy of a
    /// file that is already migrated.
    static func recordOpened(storeURL: URL, version: Schema.Version) {
        guard FileManager.default.fileExists(atPath: storeURL.path) else { return }
        let markerExists = FileManager.default.fileExists(atPath: markerURL(for: storeURL).path)
        guard !markerExists || recordedVersion(for: storeURL) < version else { return }
        let text = "\(version.major).\(version.minor).\(version.patch)\n"
        try? text.write(to: markerURL(for: storeURL), atomically: true, encoding: .utf8)
    }
}
