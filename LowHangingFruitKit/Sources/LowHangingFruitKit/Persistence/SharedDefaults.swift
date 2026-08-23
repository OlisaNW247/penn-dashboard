import Foundation

/// Where every LHF preference lives.
///
/// **Why this exists.** Preferences used to sit in `UserDefaults.standard`,
/// which is the *app's private* defaults domain. The widget extension is a
/// separate process with its own private domain, so it physically could not read
/// completions, hidden/deleted courses, or manual assignments — which is why
/// `LedgerWidgetReader` has to derive "finished" from the ledger's own
/// `isFinished`/`completedAt` instead of the real completion set.
///
/// Moving the same keys into the App Group suite puts them in a container both
/// processes can open, without changing a single key name.
public enum SharedDefaults {
    /// Same container as the ledger and the widget snapshot — `WidgetSharing`
    /// stays the single source of truth for the id.
    public static var appGroupID: String { WidgetSharing.appGroupID }

    /// The handful of keys that are read from *outside* the app process.
    ///
    /// Everything else is written and read by one type, which can keep its key
    /// name private. These three are the exception: `LedgerWidgetReader` needs
    /// them to honour hidden courses, deleted courses and custom names, and it
    /// lives in an extension that cannot be told when `AppState` renames a
    /// string literal. A silent drift here doesn't crash — the widget just goes
    /// back to advertising a class the user already deleted, which is precisely
    /// the bug that made the widget read preferences in the first place.
    public static let hiddenCoursesKey = "hiddenCourseKeys"
    public static let deletedCoursesKey = "deletedCourseKeys"
    public static let courseNameOverridesKey = "courseNameOverrides"

    /// The App Group suite, or nil when this process has no App Group
    /// entitlement (unit tests, SwiftUI previews, an unsigned binary).
    ///
    /// The entitlement — not `UserDefaults(suiteName:)` — is what's actually
    /// probed: that initializer returns a usable object for almost any name, so
    /// it can't tell us whether the container is really shared. Asking
    /// `FileManager` for the container is the same test `AssignmentStore` and
    /// `WidgetSnapshotStore` already use, so all three agree on when the group
    /// is available.
    public static func sharedSuite() -> UserDefaults? {
        guard FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID) != nil
        else { return nil }
        return UserDefaults(suiteName: appGroupID)
    }

    /// True inside a widget/app extension. Extensions get their *own* private
    /// `.standard` domain, which never held the app's preferences, so they must
    /// never run the migration — doing so would plant the marker and leave the
    /// app's real data stranded in a domain nothing reads any more.
    static var isAppExtension: Bool {
        Bundle.main.bundleURL.pathExtension == "appex"
    }

    /// Resolves the suite and, on the app side, performs the one-time copy out
    /// of `.standard` before anyone reads a value from it.
    static func resolve() -> UserDefaults {
        guard let suite = sharedSuite() else { return .standard }
        if !isAppExtension {
            SharedDefaultsMigration.run(from: .standard, to: suite)
        }
        return suite
    }
}

public extension UserDefaults {
    /// The one accessor every LHF preference read and write goes through.
    ///
    /// Resolves to the App Group suite, falling back to `.standard` when the
    /// group is unavailable — so tests and previews keep working (and keep
    /// persisting) instead of crashing or quietly dropping writes.
    ///
    /// `static let` is lazy and runs exactly once per process, which is also
    /// what makes it a safe home for the migration: whichever type touches
    /// preferences first — `AppState`, `GradeWatcherStore` or
    /// `NotificationScheduler` — the copy has already happened by the time it
    /// reads. That removes the initialization-order trap of migrating from one
    /// designated place (`AppState.init` runs its stored-property initializers,
    /// `GradeWatcherStore()` among them, *before* its own body).
    /// `nonisolated(unsafe)` because `UserDefaults` is not `Sendable` but *is*
    /// documented as thread-safe — the same reason `UserDefaults.standard` is
    /// itself reachable from any isolation. The lazy `static let` initializer
    /// still runs exactly once, so concurrent first access can't double-migrate.
    nonisolated(unsafe) static let lhf: UserDefaults = SharedDefaults.resolve()
}

/// The one-time copy of existing preferences from the app's private defaults
/// into the shared App Group suite.
///
/// Runs at most once per install, guarded by a marker key stored in the
/// destination, so an upgrading user keeps their completions, class selection
/// and grade history, and a later launch can never overwrite newer values with
/// the stale originals left behind in `.standard`.
public enum SharedDefaultsMigration {
    /// Lives in the *destination* on purpose: the marker then travels with the
    /// data it describes. If the shared container is ever wiped, the marker goes
    /// with it and the legacy values are recovered on the next launch.
    public static let markerKey = "lhf.didMigrateToAppGroup"

    /// Every key that existed in `.standard` when persistence moved into the App
    /// Group. This list is deliberately frozen: keys added after this change are
    /// born in the shared suite and have nothing to migrate, so a new key that
    /// isn't listed here is correct, not an omission.
    ///
    /// `canvasICSURL` is deliberately absent, and its absence is load-bearing.
    /// Canvas's `/feeds/calendars/user_<token>.ics` embeds a per-user token in
    /// the URL itself, so the feed URL is a bearer credential: anyone holding
    /// the string can read that student's assignments and due dates with no
    /// further authentication. `ICSFeedURLStore` moved it into the Keychain for
    /// exactly that reason, migrating the old value out of `.standard` and
    /// deleting it. Listing it here would copy it back out into an unencrypted
    /// App Group container — one that is included in device backups and that
    /// the widget can also read — and leave it there permanently, quietly
    /// undoing the move.
    public static let legacyKeys: [String] = [
        // AppState
        "userName",
        "completedAssignmentIDs",
        "completionDates",
        "hiddenCourseKeys",
        "deletedCourseKeys",
        "recurringTasks",
        "manualAssignments",
        "canvasDiscoveryConnected",
        "gradescopeConnected",
        "hasCompletedOnboarding",
        // Shipped writing to `.standard` briefly before the accessor existed,
        // so unlike the keys born in the shared suite this one really does have
        // something to migrate. Missing it only costs an upgrading user a
        // second showing of the intro, which is why it went unnoticed.
        "hasSeenIntro",
        "isPreviewMode",
        "appearanceMode",
        "courseNameOverrides",
        "canvasCourseIDsByCode",
        "gradeBaselinedCourses",
        // GradeWatcherStore
        "gradeWatcherManualWeights",
        "gradeWatcherConfirmedGradescopeMappings",
        "gradeWatcherHistory",
        "gradeWatcherWatchedCourses",
        "gradeWatcherSyllabusSchemes",
        "gradeWatcherConfirmedCategoryMappings",
        // NotificationScheduler
        "notif.enabled",
        "notif.leadOffsets",
        "notif.digestEnabled",
        "notif.digestHour",
        "notif.digestMinute",
    ]

    public enum Outcome: Equatable, Sendable {
        /// First run: these keys were copied (empty for a fresh install, which
        /// still marks the migration done — there is nothing to find later).
        case migrated(keys: [String])
        /// The marker was already set; nothing was touched.
        case alreadyMigrated
        /// No separate App Group suite to migrate into. Nothing was touched —
        /// crucially including the marker, so a later launch that *does* have
        /// the entitlement still migrates.
        case noSharedSuite
    }

    /// Copies `legacyKeys` from `legacy` into `shared`.
    ///
    /// Injectable on both sides so the migration is testable without an App
    /// Group entitlement, and so the "no App Group" path is reachable by passing
    /// `nil`.
    @discardableResult
    public static func run(from legacy: UserDefaults, to shared: UserDefaults?) -> Outcome {
        guard let shared, shared !== legacy else { return .noSharedSuite }
        guard !shared.bool(forKey: markerKey) else { return .alreadyMigrated }

        var copied: [String] = []
        for key in legacyKeys {
            guard let value = legacy.object(forKey: key) else { continue }
            // Belt and braces alongside the marker: never overwrite a value the
            // destination already holds, so even a marker that somehow got lost
            // can't turn a re-run into data loss.
            guard shared.object(forKey: key) == nil else { continue }
            shared.set(value, forKey: key)
            copied.append(key)
        }

        shared.set(true, forKey: markerKey)
        return .migrated(keys: copied)
    }
}
