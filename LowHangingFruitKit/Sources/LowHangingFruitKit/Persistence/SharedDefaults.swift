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
        guard !isTestRunner,
              FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID) != nil
        else { return nil }
        return UserDefaults(suiteName: appGroupID)
    }

    /// True when this process is a test runner. Load-bearing on macOS:
    /// unlike iOS, `containerURL(forSecurityApplicationGroupIdentifier:)`
    /// resolves for UNSANDBOXED processes with no App Group entitlement at
    /// all — which is exactly what `swift test` is — so without this guard
    /// the test suite reads and writes the REAL Mac app's shared defaults,
    /// ledger, and widget snapshot. Observed in the wild the day the Mac
    /// app became a daily driver: test fixtures ("DEDUPE 9999" rows) on the
    /// real dashboard. `XCTestCase` only loads inside test processes, and
    /// the env keys cover the harness variants.
    public static var isTestRunner: Bool {
        if NSClassFromString("XCTestCase") != nil { return true }
        let env = ProcessInfo.processInfo.environment
        return env["XCTestConfigurationFilePath"] != nil
            || env["XCTestBundlePath"] != nil
            || env["XCTestSessionIdentifier"] != nil
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
    public static let legacyKeys: [String] = [
        // AppState
        "userName",
        // `canvasICSURL` is deliberately NOT migrated. It was on this list when
        // preferences moved to the App Group, and correctly so at the time. The
        // Canvas login hardening then moved the feed URL to the Keychain
        // (`ICSFeedURLStore`) because `…/feeds/calendars/user_<token>.ics`
        // embeds a per-user token — anyone holding the URL can read that
        // student's assignments with no further authentication. Copying it into
        // the shared suite would put a bearer credential back into unencrypted,
        // backed-up storage and undo that. Removed when the two lines merged.
        "completedAssignmentIDs",
        "completionDates",
        "hiddenCourseKeys",
        "deletedCourseKeys",
        "recurringTasks",
        "manualAssignments",
        "canvasDiscoveryConnected",
        "gradescopeConnected",
        "hasCompletedOnboarding",
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
