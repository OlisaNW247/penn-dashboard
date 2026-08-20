import Foundation

/// App-Group-backed `UserDefaults`, so the widget can read the same
/// preferences the app writes.
///
/// Everything used to live in `UserDefaults.standard`, which is private to the
/// app container. The ledger was already shared (`AssignmentStore` writes into
/// the App Group), so the widget could see *assignments* but none of the user's
/// decisions about them: a course you hid, renamed, or deleted in the app still
/// showed up on the Home Screen under its raw Canvas name. The widget wasn't
/// wrong — it genuinely could not see those preferences.
///
/// Lives in `LowHangingFruitKit` rather than `LowHangingFruitUI` so the widget
/// extension — which links only Kit — can read it too. That is the entire
/// point: preferences the widget cannot see are preferences it renders wrong.
///
/// Reading `store` performs a one-time copy of every known key out of
/// `.standard` and into the suite, so an existing install keeps its settings
/// across the update.
public enum SharedDefaults {
    /// Same container as the ledger — one App Group for the whole app.
    public static let suiteName = AssignmentStore.appGroupID

    /// Set in the suite once the copy has run, so it happens exactly once.
    private static let migrationFlagKey = "sharedDefaults.migratedFromStandard.v1"

    /// Keys read outside the app process (the widget), so the name lives in one
    /// place rather than being retyped in an extension that can't be told when
    /// it drifts.
    public static let hiddenCoursesKey = "hiddenCourseKeys"
    public static let deletedCoursesKey = "deletedCourseKeys"
    public static let courseNameOverridesKey = "courseNameOverrides"

    /// Every key the app has ever written to `.standard`.
    ///
    /// Listed explicitly rather than enumerated from `dictionaryRepresentation()`
    /// because that also returns the system-injected defaults (locale,
    /// keyboard, accessibility), and copying those into a suite that then
    /// shadows them is a genuinely confusing class of bug.
    ///
    /// `canvasICSURL` is deliberately absent: the feed URL is a bearer
    /// credential and now lives in the Keychain via `ICSFeedURLStore`. Copying
    /// it into a second unencrypted store would undo that.
    private static let migratedKeys: [String] = [
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

    /// The defaults every non-credential preference should go through.
    ///
    /// Falls back to `.standard` if the suite can't be opened — which happens
    /// in unit tests and previews, where there's no App Group entitlement.
    /// Behaviour there is exactly what it was before this type existed.
    ///
    /// `nonisolated(unsafe)` because `UserDefaults` isn't marked `Sendable`,
    /// even though it is documented as thread-safe and every access here is a
    /// plain get/set. `@MainActor` — the other way to satisfy the checker — is
    /// not available: `LedgerWidgetReader.snapshot()` is deliberately
    /// nonisolated because WidgetKit's `TimelineProvider` callbacks don't run
    /// on the main actor, and it has to read these preferences.
    nonisolated(unsafe) public static let store: UserDefaults = {
        guard let suite = UserDefaults(suiteName: suiteName) else { return .standard }
        migrateFromStandardIfNeeded(into: suite)
        return suite
    }()

    private static func migrateFromStandardIfNeeded(into suite: UserDefaults) {
        guard !suite.bool(forKey: migrationFlagKey) else { return }
        let standard = UserDefaults.standard
        for key in migratedKeys {
            guard let value = standard.object(forKey: key) else { continue }
            suite.set(value, forKey: key)
        }
        suite.set(true, forKey: migrationFlagKey)
        // The originals are left in place on purpose. They cost a few KB and
        // are never read again, and keeping them means a migration that goes
        // wrong is recoverable rather than a one-way loss of every setting the
        // user has.
    }
}
