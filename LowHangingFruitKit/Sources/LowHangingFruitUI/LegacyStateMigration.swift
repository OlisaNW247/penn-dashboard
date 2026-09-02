import Foundation
import LowHangingFruitKit

/// The app's one-time moves out of loose UserDefaults blobs, in one place.
///
/// **Step 1 (version 1) — completions and grade history onto the SwiftData
/// ledger.** Everything else UserDefaults holds is a preference — a URL, a
/// name, a set of hidden courses — cheap to re-enter and meaningless
/// off-device. These two are not. Completion state is the student's own record
/// of what they finished, and grade history is the only real observed-grade
/// trail the app keeps; both are worth carrying across a reinstall and,
/// eventually, an iCloud sync, and neither can be while it's an opaque JSON
/// blob keyed off a preferences file.
///
/// **Step 2 (version 2) — the four per-course maps into `CoursePreferences`.**
/// This one stays in UserDefaults; it is a preference by the same test that
/// sent step 1's data to the ledger. What changes is the *shape*:
/// `hiddenCourseKeys`, `deletedCourseKeys`, `courseNameOverrides` and
/// `canvasCourseIDsByCode` were four parallel maps that `AppState` loaded and
/// persisted by hand, so every new per-course setting v4 needs would have added
/// a fifth, a sixth and a seventh to the one file every workstream edits. They
/// become one value per course instead. See `CoursePreferences`.
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
    static let currentVersion = 2
    static let versionKey = "ledgerMigrationVersion"

    /// The version each step introduced. A step runs when the stored version is
    /// below its number, so an install that already did step 1 does not re-read
    /// the completion blobs just because step 2 is new. Named constants rather
    /// than bare integers because the gate for a given step must never quietly
    /// become "whatever `currentVersion` happens to be now".
    static let ledgerVersion = 1
    static let coursePreferencesVersion = 2

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
        /// Course records the per-course fold actually *changed*. Zero on a
        /// re-run even though the same four keys were read again — which is the
        /// point, and what makes it a usable idempotence assertion.
        var coursePreferencesImported = 0
    }

    /// Runs any migration steps this install hasn't done yet.
    ///
    /// `defaults` is injected so tests can drive a scratch suite instead of the
    /// real one; the stores are optional because the app tolerates their
    /// creation failing (see `AssignmentStore.makeDefault`), in which case there
    /// is nowhere to migrate *to* and the version is deliberately left unbumped
    /// so a later launch with a working store still gets the data across.
    @MainActor
    /// **Reads the App Group suite, not `.standard`.** `UserDefaults.lhf` is a
    /// lazy `static let` whose initializer runs `SharedDefaultsMigration`, so
    /// merely resolving it has already copied the legacy blobs out of the app's
    /// private domain and into the shared one. Draining them from there means
    /// there is exactly one domain to read, in a guaranteed order, whether or
    /// not this install ever had an App Group entitlement (without one, both
    /// resolve to `.standard` and the result is identical).
    @discardableResult
    static func runIfNeeded(
        defaults: UserDefaults = .lhf,
        assignmentStore: AssignmentStore?,
        gradeHistoryStore: GradeHistoryStore?,
        now: Date = Date()
    ) -> Summary {
        var summary = Summary()
        let storedVersion = defaults.integer(forKey: versionKey)
        guard storedVersion < currentVersion else { return summary }
        summary.didRun = true

        // Step 2 — the per-course maps. Runs first, and outside the store guard
        // below, because it needs no SwiftData store at all: it reads
        // UserDefaults and writes UserDefaults, so it can succeed on a launch
        // where the ledger failed to open entirely.
        if storedVersion < coursePreferencesVersion {
            summary.coursePreferencesImported =
                CoursePreferencesStore.importLegacyCourseState(in: defaults)
        }

        // Step 1 — completions and grade history onto the ledger.
        if storedVersion < ledgerVersion {
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
        }

        // Only claim the version once every store that had somewhere to write
        // actually got its turn — otherwise a launch where one store failed
        // would mark the whole migration done and strand the other's data.
        //
        // Step 2 is gated on the same condition even though it needs no store,
        // because the version is a single number: recording 2 while step 1 was
        // unable to run would put step 1 permanently behind the gate. Leaving
        // the number alone costs step 2 one harmless re-run on the next launch
        // (`importLegacyCourseState` is a no-op when there is nothing to move)
        // and costs step 1 nothing at all.
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
