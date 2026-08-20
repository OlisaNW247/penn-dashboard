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
}
