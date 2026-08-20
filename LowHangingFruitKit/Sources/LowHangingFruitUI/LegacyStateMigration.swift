import Foundation
import LowHangingFruitKit

/// One-time move of the app's two remaining *data* sets out of UserDefaults and
/// onto the SwiftData ledger.
///
/// Everything else UserDefaults holds is a preference — a URL, a name, a set of
/// hidden courses — cheap to re-enter and meaningless off-device. These two are
/// not. Completion state is the student's own record of what they finished, and
/// grade history is the only real observed-grade trail the app keeps; both are
/// worth carrying across a reinstall and, eventually, an iCloud sync, and
/// neither can be while it's an opaque JSON blob keyed off a preferences file.
///
/// **One-time, but safe to run every launch.** The version gate below is what
/// makes it "one-time" in the ordinary case; the imports underneath are each
/// idempotent anyway, because the version key is itself just a UserDefaults
/// value and a restored-from-backup device can present a stale one. Nothing
/// here overwrites a ledger row that already knows better: an already-completed
/// row is left alone, and a course that already has observations is skipped.
///
/// The legacy keys are deliberately **not deleted**. They cost a few kilobytes,
/// and leaving them means a user who downgrades to an older build — or a
/// migration that has to be re-run after a bug — still has the original data to
/// read. They simply stop being written.
enum LegacyStateMigration {
    /// Bumped when a new migration step is added; `runIfNeeded` runs every step
    /// the stored version hasn't reached.
    static let currentVersion = 1
    static let versionKey = "ledgerMigrationVersion"

    /// The keys being migrated away from. Kept here rather than on `AppState` /
    /// `GradeWatcherStore` because these are the *old* names — nothing writes
    /// them any more, and they should read as history, not as live storage.
    static let legacyCompletedIDsKey = "completedAssignmentIDs"
    static let legacyCompletionDatesKey = "completionDates"
    static let legacyGradeHistoryKey = "gradeWatcherHistory"

    struct Summary: Equatable {
        /// False when the version gate short-circuited and nothing was read.
        var didRun = false
        var completionsImported = 0
        var observationsImported = 0
    }

    /// Runs any migration steps this install hasn't done yet.
    ///
    /// `defaults` is injected so tests can drive a scratch suite instead of
    /// `.standard`; the stores are optional because the app tolerates their
    /// creation failing (see `AssignmentStore.makeDefault`), in which case there
    /// is nowhere to migrate *to* and the version is deliberately left unbumped
    /// so a later launch with a working store still gets the data across.
    @MainActor
    @discardableResult
    static func runIfNeeded(
        defaults: UserDefaults = .standard,
        assignmentStore: AssignmentStore?,
        gradeHistoryStore: GradeHistoryStore?,
        now: Date = Date()
    ) -> Summary {
        var summary = Summary()
        guard defaults.integer(forKey: versionKey) < currentVersion else { return summary }
        guard assignmentStore != nil || gradeHistoryStore != nil else { return summary }
        summary.didRun = true

        if let assignmentStore {
            summary.completionsImported = assignmentStore.importLegacyCompletions(
                ids: legacyCompletedIDs(in: defaults),
                dates: legacyCompletionDates(in: defaults),
                now: now
            )
        }
        if let gradeHistoryStore {
            summary.observationsImported = gradeHistoryStore.importLegacyHistory(
                legacyGradeHistory(in: defaults)
            )
        }

        // Only claim the version once every store that had somewhere to write
        // actually got its turn — otherwise a launch where one store failed
        // would mark the whole migration done and strand the other's data.
        if assignmentStore != nil && gradeHistoryStore != nil {
            defaults.set(currentVersion, forKey: versionKey)
        }
        return summary
    }

    // MARK: Reading the old blobs

    static func legacyCompletedIDs(in defaults: UserDefaults) -> Set<String> {
        Set(defaults.stringArray(forKey: legacyCompletedIDsKey) ?? [])
    }

    static func legacyCompletionDates(in defaults: UserDefaults) -> [String: Date] {
        guard let data = defaults.data(forKey: legacyCompletionDatesKey),
              let map = try? JSONDecoder().decode([String: Date].self, from: data)
        else { return [:] }
        return map
    }

    static func legacyGradeHistory(in defaults: UserDefaults) -> [String: [GradeHistoryStore.Observation]] {
        guard let data = defaults.data(forKey: legacyGradeHistoryKey),
              let map = try? JSONDecoder().decode(
                [String: [GradeHistoryStore.Observation]].self, from: data
              )
        else { return [:] }
        return map
    }
}
