import Foundation
import SwiftUI
import WebKit
import LowHangingFruitKit
import os
#if canImport(WidgetKit)
import WidgetKit
#endif

/// The app's Light/Dark appearance setting (Settings → Appearance). Default
/// is `.light`, matching the original fixed warm-greige palette exactly, so
/// existing users see zero visual change until they opt in.
enum AppearanceMode: String, CaseIterable, Identifiable {
    case light
    case dark

    var id: String { rawValue }

    var label: String {
        switch self {
        case .light: return "light"
        case .dark:  return "dark"
        }
    }

    var colorScheme: ColorScheme {
        switch self {
        case .light: return .light
        case .dark:  return .dark
        }
    }
}

/// Per-course tally of `canvasItems` kinds, for the diagnostics-only feed
/// histogram (`AppState.courseIntelDiagnosticLines`). Counts and kinds only —
/// never a title, so it stays inside the same privacy budget as the rest of
/// the diagnostics report.
private struct CourseFeedKindTally {
    var assignment = 0
    var quiz = 0
    var event = 0
    var other = 0
    var undated = 0
}

@MainActor
final class AppState: ObservableObject {
    @Published var canvasItems: [Assignment] = []
    @Published var gradescopeItems: [Assignment] = []
    /// Readings imported from a probed (silent) course's Modules page via
    /// `CanvasModulesClient`, for courses whose readings/silent-course nudge
    /// was answered "include" (docs/READINGS_COURSES_PLAN.md). Kept separate
    /// from `canvasItems` because these never came through the ICS feed —
    /// `refreshCourseIntel` is what fills it, ledger-backed the same way via
    /// `AssignmentStore.reconcile(_:source: .canvasModules)`. Read-only
    /// outside this file; `rebuildDashboardItems` folds it into the Canvas
    /// pool it filters.
    @Published private(set) var moduleReadingItems: [Assignment] = []
    /// Canvas ∪ Gradescope with cross-posted pairs collapsed — the same pool the
    /// incomplete buckets below are filtered out of, but kept whole so callers
    /// that need completed work (the Done tab) see one item per assignment
    /// instead of the two raw feed entries a merge hid.
    @Published private(set) var mergedCoursework: [Assignment] = []
    @Published var assignments: [Assignment] = []
    @Published var laterAssignments: [Assignment] = []
    @Published var assessments: [Assignment] = []
    @Published var recurringTasks: [RecurringTask] = []
    @Published private(set) var manualAssignments: [ManualAssignment] = []
    @Published var canvasRequirementSuggestions: [CanvasRequirementSuggestion] = []
    @Published var isLoading = false
    @Published var isCanvasDiscoveryLoading = false
    @Published var isGradescopeLoading = false
    @Published var error: String?
    @Published var syncNotice: String?
    @Published var lastSync: Date?
    @Published var lastGradescopeSync: Date?

    @Published private(set) var canvasICSURL: String
    /// Everything the user has ticked off. **Derived, not persisted** — this is
    /// a read model rebuilt from the ledger's rows (`AssignmentStore
    /// .completionRecord()`) after every mutation and at launch. It used to be
    /// written to UserDefaults *as well as* onto the ledger, which meant two
    /// records of the same fact that could disagree; the ledger is now the only
    /// one, and it's the one that survives a reinstall.
    @Published private(set) var completedAssignmentIDs: Set<String> = []
    /// When each completed item was marked done, for the ids where that's known.
    /// Derived from the ledger alongside `completedAssignmentIDs`.
    ///
    /// An id can be completed with no entry here: completions carried over from
    /// builds that predate timestamps know *that* but not *when*. The Done view
    /// falls back to the due date to place those, and the weekly ring skips
    /// them — so the absence is load-bearing, not a gap to paper over.
    @Published private(set) var completionDates: [String: Date] = [:]
    /// Canvas assignment ids the grades fetch reports as submitted (see
    /// `AssignmentSubmissionInfo.indicatesSubmitted`). DERIVED state, recomputed
    /// from grade snapshots on every refresh and NOT persisted — so a Canvas
    /// correction (a retracted submission) self-heals on the next sync instead of
    /// sticking. Consulted by `isCompleted` to auto-file submitted work under Done.
    @Published private(set) var submittedCanvasAssignmentIDs: Set<String> = []

    /// Ledger ids a semester rollover has filed away. **Derived, not
    /// persisted** — rebuilt from the ledger's rows exactly as
    /// `completedAssignmentIDs` is, because the rows are the record and a second
    /// copy is a second thing that can disagree with it.
    ///
    /// This is what keeps archived work off the dashboard. It is deliberately
    /// *not* applied to `mergedCoursework`, which is what the Done tab reads —
    /// archiving is not deletion, and finished work from an archived semester
    /// stays in the student's own history.
    @Published private(set) var archivedAssignmentIDs: Set<String> = []

    /// Terms holding at least one archived row, newest first. Feeds
    /// `withinTermCap`'s past bound, so a leftover from an archived semester
    /// that never made it onto a row — a recurring occurrence, say — is caught
    /// by its term or its due date instead.
    @Published private(set) var archivedTerms: [Term] = []

    /// The rollover the app is currently prepared to offer, or nil when there is
    /// no term boundary to ask about — which is the state for eleven months of
    /// the year, and the reason `ProfileSemesterSection` can sit at the top of
    /// Profile without costing anything.
    @Published private(set) var rolloverOffer: SemesterRollover.Offer?

    /// Grade changes detected by the last refresh and not yet announced. The
    /// view layer drains this (it owns the `NotificationScheduler`), so the
    /// store stays free of notification plumbing.
    @Published var pendingGradeChanges: [AssignmentStore.ScoreChange] = []

    /// Posts "Turned in ✓" confirmations detected in `updateSubmissionState`.
    /// Everywhere else in this file, notification delivery is left to the view
    /// layer (see `pendingGradeChanges` above) because it already owns a
    /// `NotificationScheduler`. `AppState` has no reference to that
    /// view-owned instance and no path to reach it — plumbing one through
    /// would mean threading it into every initializer used by previews and
    /// tests, none of which build a view tree. A private instance here is the
    /// smallest change that still delivers the notification: it carries no
    /// state that must match the app's — `isEnabled` is read fresh from
    /// `UserDefaults.lhf` at init (same source the view-owned instance reads),
    /// and authorization is re-checked live against `UNUserNotificationCenter`
    /// on every call — so a second instance behaves identically to the app's.
    /// "Turned in ✓" confirmations found by the last submission-state
    /// refresh, waiting for the UI layer to post them — same shape and same
    /// reasoning as `pendingGradeChanges` above: `ContentView` owns the one
    /// `NotificationScheduler`, so this store publishes what to say and
    /// stays free of notification plumbing itself.
    @Published var pendingTurnedInNotices: [(title: String, body: String)] = []

    /// Courses whose grades have been fetched at least once, so the very first
    /// fetch can establish a baseline silently instead of announcing a whole
    /// term of existing scores. See `notifiableGradeChanges`.
    private var gradeBaselinedCourses: Set<String> = []
    /// Everything the student has decided about each of their classes: which
    /// are shown, which are deleted, custom names, resolved Canvas ids, and —
    /// from v4 on — per-course notification settings, recurring-item opt-in and
    /// semester archival.
    ///
    /// **This replaced four `UserDefaults` maps that used to live directly on
    /// `AppState`.** Each of them cost this type a stored property, a load line,
    /// a persist method and a key constant, and every new per-course setting
    /// cost another set of all four — on the one file every parallel workstream
    /// needs to touch. The four names those maps had are still exposed below as
    /// forwarding accessors, so no existing call site changed; they now read
    /// through here instead of holding a second copy.
    ///
    /// Add per-course state to `CoursePreferences`, not to `AppState`.
    let coursePreferences: CoursePreferencesStore
    @Published private(set) var isCanvasDiscoveryConnected: Bool
    @Published private(set) var isGradescopeConnected: Bool
    @Published private(set) var hasCompletedOnboarding: Bool
    /// Whether the first-run mission panes (`IntroView`) have been shown.
    /// Deliberately *separate* from `hasCompletedOnboarding`: the Settings
    /// reconnect buttons call `restartOnboarding()`, which clears that flag to
    /// send the user back to the connect checklist. Sharing one flag would
    /// replay the whole product pitch at someone who only wanted to reconnect
    /// Canvas.
    @Published private(set) var hasSeenIntro: Bool
    @Published private(set) var isPreviewMode: Bool
    @Published private(set) var userName: String
    /// Light/Dark appearance, applied app-wide via `.preferredColorScheme` at
    /// the root. Persisted like every other user preference here.
    @Published private(set) var appearanceMode: AppearanceMode
    // MARK: Per-course state — forwarding accessors
    //
    // These four names are what the rest of the app has always called this
    // state, and they keep working unchanged. They are computed, not stored:
    // `coursePreferences` holds the single canonical record and these derive
    // from it, so there is no second copy to fall out of step. Views still
    // update because `AppState` republishes the store's `willChange` as its own
    // `objectWillChange` (see `init`).

    /// Courses the user has switched OFF (no dashboard items, no notifications).
    /// Read as the *hidden* set so the default — empty — means every course is
    /// shown, and any newly-discovered course shows up automatically.
    var hiddenCourseKeys: Set<String> { coursePreferences.hiddenCourseKeys }

    /// Courses the user deleted from the classes list. Deletion is a superset of
    /// hiding: a deleted course is excluded everywhere a hidden course is
    /// (dashboard, notifications, Grade Watcher) AND is also removed from the
    /// classes list itself — unlike a merely-hidden course, which still shows
    /// there with its toggle off. There's no server-side course to delete (it's
    /// synced from Canvas), so this is purely a local filter the user can undo.
    var deletedCourseKeys: Set<String> { coursePreferences.deletedCourseKeys }

    /// User-chosen display names, keyed by the canonical course code the rest of
    /// the app identifies a class by. Renaming is deliberately cosmetic: hiding,
    /// deletion, notifications and grades all still key on the code, so a
    /// renamed class keeps working and a re-sync can't undo the rename.
    var courseNameOverrides: [String: String] { coursePreferences.courseNameOverrides }

    /// Course code -> Canvas numeric course id, remembered once resolved. Ids
    /// only ever arrive attached to an ICS item's URL, so a course whose current
    /// feed entries carry no usable URL would otherwise be invisible to Grade
    /// Watcher even while selected. Caching keeps a selected class fetchable.
    var canvasCourseIDsByCode: [String: String] { coursePreferences.canvasCourseIDsByCode }

    /// Per-course answer to the readings/silent-course nudge
    /// (docs/READINGS_COURSES_PLAN.md), keyed by `CourseProfileReport
    /// .courseKey`. Default is exclude — a course with no entry here shows
    /// none of its opted-in content, so existing users see zero change
    /// until they answer a nudge or flip the Settings toggle. Deliberately
    /// never consulted by Grade Watcher / course-selection paths (see the
    /// plan's "Hard requirement — Grade Watcher independence").
    @Published private(set) var courseContentDecisions: [String: CourseContentDecision]
    /// The one nudge the UI may present this app-open ("no nag storms" —
    /// docs/READINGS_COURSES_PLAN.md). Set by `queueNudgeIfNeeded()`, cleared
    /// by `resolveCourseNudge`/`dismissCourseNudge`.
    @Published var pendingCourseNudge: CourseProfileReport?
    /// The authenticated course list from the last successful
    /// `refreshCourseIntel`, persisted (id -> name) so SILENT detection
    /// survives a launch with no live Canvas session — a course with zero
    /// feed items is otherwise invisible to LHF at all (see `CourseProfile
    /// .unknownSilent` vs `.silent`).
    private var enrolledCanvasCourses: [CanvasCourseDiscoveryParser.Course]
    /// Per-course probe results from this launch's `refreshCourseIntel`
    /// runs. In-memory only: a probe surviving relaunch could misreport a
    /// course as `.silent` (probed, found nothing) when it's really
    /// `.unknownSilent` (no session to probe with) this launch.
    private var courseProbes: [String: CourseProbeResult] = [:]
    /// The last computed profile for every course seen — feed- or
    /// enrollment-derived. Recomputed by `recomputeCourseProfiles()`.
    private var courseProfileReports: [CourseProfileReport] = []
    /// Whether a nudge has already been surfaced this launch.
    /// `pendingCourseNudge == nil` alone can't tell "never queued" apart
    /// from "queued, then resolved" — without this a resolve during this
    /// launch would let the next sync immediately queue another one.
    private var nudgePresentedThisLaunch = false

    /// Canvas grade snapshots for the selected courses (Settings → Grade
    /// Watcher). Its own `ObservableObject` so CP4's view can observe it
    /// directly; `refreshGradeWatcher` is the only thing that drives it here.
    let gradeWatcher: GradeWatcherStore

    /// Durable assignment ledger. A sync reconciles into it instead of replacing
    /// the in-memory arrays wholesale, so previously-seen assignments (and
    /// completed work) survive a rolling Canvas feed and flaky fetches. Optional
    /// so that if the SwiftData store can't be created the app degrades to its
    /// old non-persistent behavior rather than crashing. In unit tests there's no
    /// App Group entitlement, so each `AppState()` gets its own fresh in-memory
    /// store — no disk, no cross-test leakage.
    let assignmentStore: AssignmentStore?

    /// Durable home for observed grade history, alongside the assignment
    /// ledger in the same App Group container.
    let gradeHistoryStore: GradeHistoryStore?

    /// Settings → "Sync between my devices" (docs/LAPTOP_INTEGRATION_PLAN.md
    /// Tier 2). Default off: existing users see zero change until they opt
    /// in. Toggling this republishes immediately via `setCloudSyncEnabled`,
    /// but see `cloudSyncEnabledAtLaunch` for why neither `assignmentStore`
    /// nor `cloudPrefsMirror` reconfigure themselves until the next launch.
    @Published private(set) var cloudSyncEnabled: Bool

    /// `cloudSyncEnabled` as read from `UserDefaults.lhf` at the top of this
    /// launch's `init` — i.e. what `assignmentStore` was actually built with
    /// (`AssignmentStore.makeDefault(syncEnabled:)`) and what
    /// `cloudPrefsMirror` was actually constructed with. Swapping a live
    /// SwiftData `ModelContainer`, or restarting the iCloud key-value
    /// observer, out from under a running app is not worth the risk, so a
    /// toggle flipped mid-session is deliberately queued rather than applied
    /// live. Settings compares the live `cloudSyncEnabled` against this `let`
    /// to tell the user their change is queued instead of implying it
    /// already took effect.
    let cloudSyncEnabledAtLaunch: Bool

    /// Mirrors a small allowlist of preference keys (course-content
    /// decisions, deleted/hidden courses, renames) through the user's own
    /// iCloud key-value store when sync is enabled. Inert under
    /// `SharedDefaults.isTestRunner` or when sync is off — see
    /// `CloudPrefsMirror`'s own doc comment for the conflict semantics and
    /// exactly which keys it touches.
    let cloudPrefsMirror: CloudPrefsMirror

    private static let userNameKey = "userName"
    // The four per-course keys that used to be listed here — `hiddenCourseKeys`,
    // `deletedCourseKeys`, `courseNameOverrides`, `canvasCourseIDsByCode` — now
    // belong to `CoursePreferencesStore`, which is the only thing that writes
    // them. `SharedDefaults` still declares the three the widget reads.
    private static let recurringTasksKey = "recurringTasks"
    private static let manualAssignmentsKey = "manualAssignments"
    private static let canvasDiscoveryConnectedKey = "canvasDiscoveryConnected"
    private static let gradescopeConnectedKey = "gradescopeConnected"
    private static let onboardingCompletedKey = "hasCompletedOnboarding"
    private static let introSeenKey = "hasSeenIntro"
    private static let previewModeKey = "isPreviewMode"
    private static let appearanceModeKey = "appearanceMode"
    private static let gradeBaselinedCoursesKey = "gradeBaselinedCourses"
    /// The term code of the most recent rollover the student waved away. A
    /// preference by every test in `docs/persistence-explained.md` §3 — losing
    /// it costs one re-offered card, nothing more — so it stays in defaults
    /// rather than going near the ledger.
    private static let rolloverDismissedTermKey = "rolloverDismissedTerm"
    private static let enrolledCanvasCoursesKey = "enrolledCanvasCoursesV1"
    /// docs/LAPTOP_INTEGRATION_PLAN.md Tier 2 — read directly by
    /// `CloudSyncToggleTests`'s own hardcoded copy of this string (the same
    /// convention `CourseContentDecisionStoreTests` uses for
    /// `CourseContentDecisionStore`'s key), not by `CloudPrefsMirror`, which
    /// never mirrors this key itself (sync's own on/off state is
    /// necessarily per-device, not something to sync).
    private static let cloudSyncEnabledKey = "cloudSyncEnabledV1"

    /// `assignmentStore` is injectable so tests can supply a specific in-memory
    /// or temp-file store (and drive it across simulated launches). The default
    /// nil resolves to `AssignmentStore.makeDefault()` — persistent in the real
    /// app, fresh in-memory in unit tests.
    init(
        assignmentStore: AssignmentStore? = nil,
        gradeHistoryStore: GradeHistoryStore? = nil
    ) {
        // Keychain-backed (docs/CANVAS_LOGIN_HARDENING.md item 3c) — the feed
        // URL is itself a bearer credential, since Canvas embeds a per-user
        // token directly in it. `ICSFeedURLStore.load()` transparently migrates
        // a pre-existing UserDefaults value in and deletes the original.
        self.canvasICSURL = ICSFeedURLStore.load()
        self.isCanvasDiscoveryConnected = UserDefaults.lhf.bool(forKey: Self.canvasDiscoveryConnectedKey)
        self.isGradescopeConnected = UserDefaults.lhf.bool(forKey: Self.gradescopeConnectedKey)
        self.hasCompletedOnboarding = UserDefaults.lhf.bool(forKey: Self.onboardingCompletedKey)
        self.hasSeenIntro = UserDefaults.lhf.bool(forKey: Self.introSeenKey)
        self.isPreviewMode = UserDefaults.lhf.bool(forKey: Self.previewModeKey)
        self.userName = UserDefaults.lhf.string(forKey: Self.userNameKey) ?? ""
        self.appearanceMode = AppearanceMode(
            rawValue: UserDefaults.lhf.string(forKey: Self.appearanceModeKey) ?? ""
        ) ?? .light
        self.gradeBaselinedCourses = Set(
            UserDefaults.lhf.stringArray(forKey: Self.gradeBaselinedCoursesKey) ?? []
        )
        self.courseContentDecisions = CourseContentDecisionStore.load()
        self.enrolledCanvasCourses = Self.loadStringMap(Self.enrolledCanvasCoursesKey)
            .map { CanvasCourseDiscoveryParser.Course(id: $0.key, name: $0.value) }
        self.recurringTasks = Self.loadRecurringTasks()
        self.manualAssignments = Self.loadManualAssignments()

        // Read once, at the top of this launch, and handed to both the
        // ledger's own opt-in CloudKit mirroring and this launch's
        // `CloudPrefsMirror` — see `cloudSyncEnabledAtLaunch`'s doc comment
        // for why a toggle flipped mid-session doesn't reconfigure either
        // one until the next launch reads this again.
        let syncEnabledAtLaunch = UserDefaults.lhf.bool(forKey: Self.cloudSyncEnabledKey)
        self.cloudSyncEnabled = syncEnabledAtLaunch
        self.cloudSyncEnabledAtLaunch = syncEnabledAtLaunch
        self.cloudPrefsMirror = CloudPrefsMirror(enabled: syncEnabledAtLaunch)

        // Seed the in-memory pools from the durable ledger so the class list and
        // dashboard are populated on the very first frame — before any network
        // sync returns — instead of starting empty every launch.
        let store = assignmentStore ?? AssignmentStore.makeDefault(syncEnabled: syncEnabledAtLaunch)
        self.assignmentStore = store
        let historyStore = gradeHistoryStore ?? GradeHistoryStore.makeDefault()
        self.gradeHistoryStore = historyStore

        // Move completion state and observed grade history off the old
        // UserDefaults blobs and onto the ledger, and fold the four per-course
        // maps into `CoursePreferences`, before anything reads any of them.
        // One-time (version-gated) and idempotent — see `LegacyStateMigration`.
        LegacyStateMigration.runIfNeeded(
            assignmentStore: store,
            gradeHistoryStore: historyStore
        )
        // Both constructed after the migration so they read migrated state
        // rather than an empty store. Ordering is load-bearing for
        // `coursePreferences` in particular: constructing it first would load an
        // empty map, and its next save would then write that emptiness over the
        // four legacy keys the migration had not yet read.
        self.coursePreferences = CoursePreferencesStore()
        self.gradeWatcher = GradeWatcherStore(historyStore: historyStore)

        // Republish the store's changes as our own. `hiddenCourseKeys` and the
        // three names beside it used to be `@Published` properties here; they
        // are computed forwarding accessors now, and a computed property
        // publishes nothing. Without this relay, hiding or renaming a class
        // would update the store and leave every view observing `AppState`
        // showing the old value until something unrelated redrew it.
        coursePreferences.willChange = { [weak self] in self?.objectWillChange.send() }

        // Cloud push on every genuine preference change (docs/
        // LAPTOP_INTEGRATION_PLAN.md Tier 2). The store persists synchronously
        // in `commit`, so by the time this fires the blob under
        // `CoursePreferencesStore.storageKey` — the value the mirror copies —
        // is already the new state. Guarded per-call on `cloudSyncEnabled`
        // rather than baked in at construction so flipping the toggle takes
        // effect for pushes immediately, matching `setCourseContentDecision`.
        coursePreferences.didChange = { [weak self] in
            guard let self, self.cloudSyncEnabled else { return }
            self.cloudPrefsMirror.push(key: CoursePreferencesStore.storageKey)
        }

        // Runs before `store.currentAssignments()` seeds `canvasItems`/
        // `gradescopeItems`/`moduleReadingItems` below — those arrays are a
        // snapshot taken once, not a live view of the ledger, so normalizing
        // the ledger *after* they were seeded would leave this launch's
        // dashboard reading stale raw course names until the next sync. Every
        // stored property already has a value by this point, so the instance
        // call is legal.
        normalizeStoredCourseNames()

        if let store {
            // Completion is read back out of the ledger rather than out of its
            // own UserDefaults copy: one record of the fact, and the one that
            // survives a reinstall.
            let completion = store.completionRecord()
            self.completedAssignmentIDs = completion.ids
            self.completionDates = completion.dates

            let persisted = store.currentAssignments()
            self.canvasItems = persisted.filter { $0.source == .canvas }
            self.gradescopeItems = persisted.filter { $0.source == .gradescope }
            // Module-imported readings (docs/READINGS_COURSES_PLAN.md) survive
            // a relaunch the same way canvasItems/gradescopeItems do — read
            // back out of the same `currentAssignments()` snapshot rather than
            // a second ledger query, so the dashboard has last session's
            // opted-in readings from the first frame, before any refresh runs.
            self.moduleReadingItems = persisted.filter { $0.source == .canvasModules }
            // Submission state used to be blank until the first successful grade
            // refresh landed — so auto-filed work sat back on the active list on
            // every cold launch, and stayed there forever if the Canvas session
            // had lapsed. Seed it from the ledger instead; a live refresh still
            // overwrites this with Canvas's current truth.
            self.submittedCanvasAssignmentIDs = store.submittedCanvasAssignmentIDs()

            // Manual work moves onto the ledger, with the UserDefaults blob read
            // once as a migration source and then dropped — the same shape as
            // `ICSFeedURLStore`. Guarded on `isPersistent` because dropping the
            // blob while the ledger is the in-memory fallback would destroy the
            // user's own assignments on the next launch, which is the precise
            // opposite of the point.
            if store.isPersistent {
                store.upsert(self.manualAssignments.map { $0.asAssignment() })
                UserDefaults.lhf.removeObject(forKey: Self.manualAssignmentsKey)
                self.manualAssignments = store
                    .assignments(source: .manual)
                    .compactMap(ManualAssignment.init)
            }
        }

        // Outside the block on purpose: a no-op without a store, and calling
        // instance methods mid-init is only legal once every stored property is
        // initialized. `LegacyStateMigration.runIfNeeded` has already folded any
        // pre-ledger completions onto rows by this point, so this one derivation
        // sees the complete picture.
        reloadCompletionFromLedger()

        // Wired here rather than at `cloudPrefsMirror`'s own construction
        // above: forming a closure that captures `self` isn't legal until
        // every stored property above has an initial value — true as early
        // as `normalizeStoredCourseNames()`'s call site above, and still
        // true here.
        //
        // `CloudPrefsMirror` calls this closure from a plain, non-isolated
        // context (its `NSUbiquitousKeyValueStore.didChangeExternally`
        // observer, registered with `queue: .main` but not statically
        // MainActor-isolated) — so the actual call into this `@MainActor`
        // type's `reloadMirroredPreferences()` is wrapped in `Task
        // { @MainActor in ... }` here, the standard bridge for re-entering
        // an actor from a callback-based system API, rather than calling it
        // directly and relying on `queue: .main` alone.
        cloudPrefsMirror.onExternalChange = { [weak self] _ in
            Task { @MainActor in
                self?.reloadMirroredPreferences()
            }
        }

        rebuildDashboardItems()

        // Backfill for anyone who onboarded before the intro existed: they have
        // `hasCompletedOnboarding` but no `hasSeenIntro`, so without this the
        // first Settings reconnect (`restartOnboarding()`) would drop them into
        // a first-run pitch they've long since outgrown. Reads the *persisted*
        // onboarding flag, so it has to run before the preview and demo seams
        // below force that flag true.
        if hasCompletedOnboarding && !hasSeenIntro {
            hasSeenIntro = true
            UserDefaults.lhf.set(true, forKey: Self.introSeenKey)
        }

        // Preview (demo) mode persists across launches so an App Store reviewer
        // who relaunches still lands on the populated sample dashboard.
        if isPreviewMode {
            hasCompletedOnboarding = true
            hasSeenIntro = true
            if userName.isEmpty { userName = "there" }
            loadPreviewData()
        }

        #if DEBUG
        // Screenshot/preview seam: launch with `-LHFDemoData` to skip onboarding
        // and show a fully-populated dashboard. DEBUG-only; never in release.
        if ProcessInfo.processInfo.arguments.contains("-LHFDemoData") {
            hasCompletedOnboarding = true
            hasSeenIntro = true
            userName = "Marco"
        }
        #endif

        refreshCanvasSessionExpiredState()
    }

    /// One-time-per-launch (but idempotent, and safe to re-run every launch)
    /// sweep that rewrites every stored course string — ledger rows,
    /// hidden/deleted sets, renames, and content decisions — through
    /// `CourseCode.parse`. Canvas descriptors like
    /// "BAN_CIS-2400-001 202630" used to fail to parse and get stored
    /// verbatim, both as ledger rows and as the preference keys below; a
    /// parser fix producing a clean code for them going forward does
    /// nothing for data already on disk, so the same course would
    /// otherwise go on appearing under both its raw registrar string and
    /// its clean code forever. Cheap at a student's few hundred rows, and
    /// re-running self-heals raw names that arrive later from an
    /// unmigrated device via sync.
    ///
    /// Called once from `init`, right after every stored property has an
    /// initial value and — crucially — before `store.currentAssignments()`
    /// seeds `canvasItems`/`gradescopeItems`/`moduleReadingItems` for this
    /// launch, so the ledger sweep below lands before anything reads it.
    /// See the call site's comment for why that ordering matters.
    private func normalizeStoredCourseNames() {
        let norm = { (name: String) -> String in CourseCode.parse(name).code }

        assignmentStore?.normalizeCourseNames(norm)

        // Re-keys hidden/deleted/renames/ids in one pass — every record now
        // lives in the `coursePreferences` blob, so this is the whole of what
        // the four per-map normalizations used to do. Variants of the same
        // course merge onto one record (collision rules in
        // `normalizeCourseKeys`), and a genuine change persists, refreshes the
        // widget's legacy projection, and pushes to the cloud mirror via
        // `didChange` — all wired before this runs in `init`.
        coursePreferences.normalizeCourseKeys(norm)

        // Collision rule: keep the decision with the most recent
        // `decidedAt` — the freshest answer to the nudge is the one that
        // should survive.
        var normalizedDecisions: [String: CourseContentDecision] = [:]
        for (oldKey, decision) in courseContentDecisions {
            let newKey = norm(oldKey)
            if let existing = normalizedDecisions[newKey], existing.decidedAt >= decision.decidedAt {
                continue
            }
            normalizedDecisions[newKey] = decision
        }
        if normalizedDecisions != courseContentDecisions {
            courseContentDecisions = normalizedDecisions
            CourseContentDecisionStore.save(courseContentDecisions)
            // `cloudPrefsMirror` is already constructed by the time `init`
            // calls this method, so the push IS possible here — same
            // "push at the point the local write happens" pattern as
            // `setCourseContentDecision` below, just running once at launch
            // instead of on a user action.
            if cloudSyncEnabled { cloudPrefsMirror.push(key: "courseContentDecisionsV1") }
        }
    }

    /// First-run onboarding is required until both core data sources are connected.
    var needsOnboarding: Bool { !hasCompletedOnboarding }

    /// True until the mission panes have been shown once. Only ever consulted
    /// alongside `needsOnboarding` (see `RootView`), so a returning user can't
    /// be sent back through the pitch.
    var needsIntro: Bool { !hasSeenIntro }

    /// Marks the mission panes as shown — whether the user read all three or
    /// skipped them. Never cleared by `restartOnboarding()`.
    func completeIntro() {
        hasSeenIntro = true
        UserDefaults.lhf.set(true, forKey: Self.introSeenKey)
    }

    /// True when the store is showing bundled fixtures rather than a real
    /// account: the reviewer-facing preview, or the DEBUG screenshot seam.
    /// Both need the same treatment everywhere the app would otherwise reach
    /// for the network or for Canvas-derived identifiers.
    var isUsingFixtureData: Bool {
        if isPreviewMode { return true }
        #if DEBUG
        return ProcessInfo.processInfo.arguments.contains("-LHFDemoData")
        #else
        return false
        #endif
    }

    /// True once the Canvas calendar feed has been captured automatically.
    var isCanvasConnected: Bool { !canvasICSURL.isEmpty }

    /// True when there's an actual Canvas login session for Grade Watcher's
    /// cookie-authenticated REST calls to use. Deliberately NOT
    /// `isCanvasConnected` (`!canvasICSURL.isEmpty`): that's true for BOTH
    /// Canvas connection paths — the in-app Penn SSO login, which captures the
    /// cookie session Grade Watcher needs, AND a manually pasted calendar feed
    /// link (docs/CANVAS_LOGIN_HARDENING.md item 3b), which carries no cookies
    /// at all — so it can't tell the one path Grade Watcher can work on apart
    /// from the one where every fetch would fail.
    ///
    /// Fixture/preview mode short-circuits to true because Grade Watcher runs
    /// entirely off bundled sample data there, never the network, and preview
    /// is the only way through the app for someone who can't pass Penn SSO —
    /// notably an App Store reviewer (see `isUsingFixtureData`).
    ///
    /// `canvasSessionExpired` also counts as available — the same
    /// cookies-or-expired test `DiagnosticsReport.canvasConnectPath` uses.
    /// An expired session means a cookie login DID happen at some point, and
    /// Grade Watcher's own "Reconnect Canvas" affordance is where that gets
    /// fixed; treating expiry as unavailable would hide the one screen that
    /// can recover it.
    var canUseGradeWatcher: Bool {
        if isUsingFixtureData { return true }
        return !SessionCookieStore.load(service: .canvas).isEmpty || canvasSessionExpired
    }

    /// True when the Canvas login *session* (the cookie-authed one, used for
    /// automatic submission detection and Canvas Scan — see
    /// `AutoSyncCoordinator.refreshCanvasGrades`) has gone stale and needs a
    /// fresh login. Deliberately DISTINCT from `isCanvasConnected`
    /// (`!canvasICSURL.isEmpty`): the two are orthogonal, since the ICS
    /// calendar feed keeps working on its own token long after the cookie
    /// session that originally captured it has expired, and a user who
    /// pasted their feed link manually (docs/CANVAS_LOGIN_HARDENING.md item
    /// 3b) never had a cookie session to expire in the first place — that
    /// user must never see a reconnect nag. Refreshed from
    /// `SessionCookieStore`'s Keychain state, not from any single failed
    /// fetch, so it can't get stuck true after a successful reconnect or
    /// stuck false for a feed-only user (docs/CANVAS_LOGIN_HARDENING.md item 3d).
    @Published private(set) var canvasSessionExpired = false

    /// True while `CanvasLoginPane` (OnboardingView.swift) is on screen — set
    /// on its appear, cleared on its disappear. Not `@Published`: nothing
    /// renders off this, it exists purely as a guard `CanvasSessionRenewer`
    /// consults before touching `LoginDataStores.canvas` (session-longevity
    /// Layer 2 — see that type's doc comment), so a background silent-renewal
    /// attempt can never run concurrently with the visible login pane reading
    /// from/writing to the same isolated `WKWebsiteDataStore`.
    /// The `didSet` closes the guard's other half: the gate stops a NEW
    /// silent attempt while the pane is open, and this aborts an ALREADY
    /// IN-FLIGHT one the moment the pane opens — likely in practice, since
    /// the same expiry transition that starts a silent attempt also surfaces
    /// the reconnect banner the user is now responding to. Both types are
    /// `@MainActor`, so the teardown is synchronous with the flag flip.
    var isCanvasLoginPaneActive = false {
        didSet {
            if isCanvasLoginPaneActive {
                canvasSessionRenewer?.abortForLoginPane()
            }
        }
    }

    /// Lazily-created, reused across calls so its own cooldown/in-flight
    /// state (see `CanvasSessionRenewer.gate`) persists between the multiple
    /// observer sites that can trigger `attemptSilentCanvasRenewal()`.
    private var canvasSessionRenewer: CanvasSessionRenewer?

    /// Recomputes `canvasSessionExpired` from `SessionCookieStore`'s current
    /// Keychain state. Call after anything that could change it: connecting,
    /// disconnecting, or a periodic dashboard refresh.
    ///
    /// A false-to-true transition here is also the trigger for a SILENT
    /// Canvas re-login attempt (session-longevity Layer 2 —
    /// `CanvasSessionRenewer`), fired once per transition rather than from
    /// every individual call site: `CanvasSessionRenewer.renewIfNeeded()`'s
    /// own cooldown/in-flight/pane-active guards make it safe to call from
    /// the launch/connect/disconnect recompute sites without any further
    /// gating here. `disconnectCanvas()` calls this too, but never actually
    /// trips this branch in practice: `SessionCookieStore.remove(service:)`
    /// deletes that service's Keychain item outright, so
    /// `isExpired(service:)` — which requires a NON-empty, now-all-stale
    /// persisted set — reads `false` (never-connected) immediately
    /// afterward, not `true`. No special-casing needed for that call site;
    /// verified by tracing `SessionCookieStore.isExpired`'s definition.
    func refreshCanvasSessionExpiredState() {
        let wasExpired = canvasSessionExpired
        canvasSessionExpired = SessionCookieStore.isExpired(service: .canvas)
        if canvasSessionExpired && !wasExpired {
            Task { await attemptSilentCanvasRenewal() }
        }
    }

    /// Attempts one SILENT Canvas re-login (session-longevity Layer 2) before
    /// the user ever sees the "needs a refresh" banner — see
    /// `CanvasSessionRenewer`'s doc comment for the full mechanism and its
    /// safety rules. Fire-and-forget from every call site; safe to call
    /// redundantly since the renewer's own guards make repeat calls within
    /// the same cooldown window a no-op.
    ///
    /// Gated here (rather than inside `CanvasSessionRenewer`) on
    /// `isUsingFixtureData`: that flag is `AppState`'s own state, and the
    /// renewer is deliberately kept free of any `AppState` dependency beyond
    /// the `isLoginPaneActive` closure it's constructed with.
    func attemptSilentCanvasRenewal() async {
        guard !isUsingFixtureData else { return }
        let renewer = canvasSessionRenewer ?? CanvasSessionRenewer(isLoginPaneActive: { [weak self] in
            self?.isCanvasLoginPaneActive ?? false
        })
        canvasSessionRenewer = renewer

        let outcome = await renewer.renewIfNeeded()
        guard outcome == .renewed else { return }

        refreshCanvasSessionExpiredState()
        let cookies = await AutoSyncCoordinator.canvasCookies()
        guard !cookies.isEmpty else { return }
        await refreshGradeWatcher(cookies: cookies)
    }

    func completeOnboarding() {
        hasCompletedOnboarding = true
        UserDefaults.lhf.set(true, forKey: Self.onboardingCompletedKey)
    }

    /// The user's first name, captured during onboarding and shown in the
    /// dashboard greeting ("Hello, Marco").
    func updateName(_ name: String) {
        userName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.lhf.set(userName, forKey: Self.userNameKey)
    }

    /// Switches the app's Light/Dark appearance (Settings → Appearance).
    func setAppearanceMode(_ mode: AppearanceMode) {
        appearanceMode = mode
        UserDefaults.lhf.set(mode.rawValue, forKey: Self.appearanceModeKey)
    }

    // MARK: - iCloud sync (Settings → "Sync between my devices")

    /// Persists and republishes the toggle immediately. Deliberately does
    /// NOT rebuild `assignmentStore` or reconfigure `cloudPrefsMirror` here —
    /// swapping a live SwiftData `ModelContainer` (or tearing down and
    /// re-arming the iCloud key-value observer) out from under a running app
    /// is not worth the risk this feature already goes out of its way to
    /// avoid elsewhere. Both wait for the next launch's `init` to read the
    /// freshly-persisted value — see `cloudSyncEnabledAtLaunch`.
    func setCloudSyncEnabled(_ enabled: Bool) {
        cloudSyncEnabled = enabled
        UserDefaults.lhf.set(enabled, forKey: Self.cloudSyncEnabledKey)
    }

    /// Called by `cloudPrefsMirror.onExternalChange` after a pull from
    /// iCloud wrote fresh values for one or more mirrored keys into
    /// `UserDefaults.lhf` (another device's course deletion, rename, or
    /// content decision). Re-reads every mirrored key from disk — the same
    /// reads `init` itself does on a cold launch — rather than trying to
    /// patch in just the keys that changed, so this can never drift from
    /// `init`'s own parsing of the same keys. Whole-value last-writer-wins
    /// (see `CloudPrefsMirror`'s doc comment) means there is nothing to
    /// merge: whatever is now on disk for a key is simply this device's new
    /// truth for it. Finishes with `rebuildDashboardItems()` so a deleted or
    /// newly-included course takes effect on screen immediately, without
    /// waiting for the next sync or relaunch.
    private func reloadMirroredPreferences() {
        coursePreferences.reloadFromDefaults()
        courseContentDecisions = CourseContentDecisionStore.load()
        rebuildDashboardItems()
    }

    /// Sends the user back to the connect flow (used by the dashboard's reconnect
    /// buttons). Already-connected services stay connected and show as done.
    ///
    /// Deliberately leaves `hasSeenIntro` alone: this lands the user on the
    /// connect checklist, not back at the first-run pitch.
    func restartOnboarding() {
        hasCompletedOnboarding = false
        UserDefaults.lhf.set(false, forKey: Self.onboardingCompletedKey)
        // Leaving onboarding via "Connect Canvas" also exits the demo, so a real
        // student who tapped Preview can switch to their own Canvas cleanly.
        let wasPreview = isPreviewMode
        isPreviewMode = false
        UserDefaults.lhf.set(false, forKey: Self.previewModeKey)
        if wasPreview {
            // Drop the fixtures on the way out. They'd never render again
            // (their course ids leave with preview mode), but leaving demo
            // grades in the store means the first real refresh merges into
            // sample data rather than starting clean.
            canvasItems = []
            gradeWatcher.clearAll()
            rebuildDashboardItems()
        }
    }

    /// Enters a read-only demo populated with sample courses and assignments, so
    /// anyone who can't pass Penn SSO (notably an App Store reviewer) can explore
    /// the full app. No network, no login; the dashboard reads bundled fixtures.
    /// Populates the demo's *shared* state — the class list, the widget
    /// snapshot, and Grade Watcher — from the bundled fixtures.
    ///
    /// The dashboard itself doesn't come through here: `ContentView` hands
    /// `DashboardViewModel` its own `SampleData` items and never binds to this
    /// store in preview. But everything that reads `AppState` directly
    /// (Settings → Classes, the class picker, Grade Watcher's course list) was
    /// reading an empty store and rendering an empty screen, which is exactly
    /// the "app looks broken" impression preview mode exists to prevent.
    ///
    /// Deliberately non-destructive: it never touches `completedAssignmentIDs`
    /// or `completionDates` (unlike DEBUG's `loadSampleData`), so a real
    /// student who taps Preview out of curiosity doesn't lose their own
    /// completion history.
    func loadPreviewData() {
        canvasItems = SampleData.items().map(\.assignment)
        rebuildDashboardItems()
        gradeWatcher.loadPreviewSnapshots(SampleData.gradeSnapshots())
    }

    func enterPreviewMode() {
        isPreviewMode = true
        UserDefaults.lhf.set(true, forKey: Self.previewModeKey)
        // Preview is entered *from* the intro's first pane, so the panes have
        // served their purpose. Marking them seen also keeps a reviewer who
        // later taps Connect Canvas (via `restartOnboarding()`) on the
        // checklist instead of replaying the pitch.
        completeIntro()
        if userName.isEmpty { userName = "there" }
        // Seed immediately, not just on the next launch: `init` only reaches
        // `loadPreviewData` when preview mode was already persisted, so
        // without this the reviewer who just tapped "Preview with sample data"
        // gets an empty class list and an empty Grade Watcher until they
        // relaunch the app.
        loadPreviewData()
        completeOnboarding()
    }

    /// Sets the Canvas calendar feed URL — either captured automatically from
    /// a login (`connectCanvas`) or pasted by hand (docs/CANVAS_LOGIN_HARDENING.md
    /// item 3b, "Paste your Canvas calendar link"). Canvas's own "Calendar
    /// Feed" copy button on the web hands out a `webcal://` URL, which
    /// `URLSession`/`CanvasICSClient` can't fetch directly — rewritten to
    /// `https://` here (identical resource, different scheme) so pasting
    /// exactly what Canvas gives you just works.
    func updateCanvasICSURL(_ value: String) {
        canvasICSURL = Self.rewritingWebcalScheme(value.trimmingCharacters(in: .whitespacesAndNewlines))
        ICSFeedURLStore.save(canvasICSURL)
        if canvasICSURL.isEmpty {
            canvasItems = []
            rebuildDashboardItems()
            error = nil
            lastSync = nil
        }
    }

    /// Rewrites a leading `webcal://` to `https://`, case-insensitively.
    /// `webcal:` is just a hint to calendar apps to subscribe rather than
    /// download once — the resource behind it is identical over `https:`,
    /// which is what `URLSession` needs to fetch it at all. A no-op for any
    /// other scheme (including an already-`https://` URL).
    static func rewritingWebcalScheme(_ value: String) -> String {
        guard value.range(of: "^webcal://", options: [.regularExpression, .caseInsensitive]) != nil else {
            return value
        }
        return "https://" + value.dropFirst("webcal://".count)
    }

    // MARK: - Disconnecting (Settings → Account)

    /// Signs out of Canvas: drops the captured calendar feed, purges the
    /// Keychain session cookies, and clears everything derived from them.
    ///
    /// There's no account to delete on our side (no backend, no sign-up), but
    /// the app does hold live credentials for two services, and until now the
    /// only way to get rid of them was to delete the app — `SessionCookieStore`
    /// had no caller in the UI at all.
    ///
    /// Gradescope's cookies are keyed and stored separately
    /// (`SessionCookieStore.Service.gradescope`, not `.clear()`) — see
    /// `SessionCookieStore`'s doc comment for why this matters even though
    /// Canvas and Gradescope can both leave cookies on `upenn.edu` (Penn
    /// SSO) — so disconnecting one service never silently signs the user out
    /// of the other.
    func disconnectCanvas() {
        SessionCookieStore.remove(service: .canvas)
        updateCanvasICSURL("")
        coursePreferences.clearAllCanvasCourseIDs()
        // Readings/silent-course detection (docs/READINGS_COURSES_PLAN.md) is
        // Canvas-session-derived state too — clear it wholesale so a
        // reconnect re-probes and re-asks from scratch instead of inheriting
        // decisions tied to a fingerprint history the new session may never
        // reproduce. This is deliberate, not an oversight: see the plan's
        // "Hard requirement — Grade Watcher independence" for why this never
        // touches `canvasCourseIDsByCode`'s Grade Watcher role beyond the
        // clear already above.
        enrolledCanvasCourses = []
        UserDefaults.lhf.removeObject(forKey: Self.enrolledCanvasCoursesKey)
        courseProbes = [:]
        courseProfileReports = []
        nudgePresentedThisLaunch = false
        courseContentDecisions = [:]
        CourseContentDecisionStore.clear()
        // Propagate the clear to the iCloud copy too, or the next external
        // pull resurrects decisions this disconnect just threw away.
        if cloudSyncEnabled { cloudPrefsMirror.push(key: "courseContentDecisionsV1") }
        pendingCourseNudge = nil
        submittedCanvasAssignmentIDs = []
        gradeWatcher.clearAll()
        // Drop the durable ledger's Canvas rows too, or a disconnected
        // account's work survives in the store and reappears on the dashboard.
        assignmentStore?.purge(source: .canvas)
        // Module-imported readings are session-derived the same way the probe
        // state above is — purge their ledger rows too, or a disconnected
        // account's readings survive the reconnect and reappear once the
        // course re-qualifies for a decision.
        assignmentStore?.purge(source: .canvasModules)
        moduleReadingItems = []
        reloadCompletionFromLedger()
        rebuildDashboardItems()
        refreshCanvasSessionExpiredState()
        // Also drop the live WebView cookie/cache jar for Canvas's isolated
        // store, not just the Keychain copy above — otherwise a still-resident
        // WKWebsiteDataStore session survives disconnect and gets presented
        // to a "Reconnect" attempt later in the same app process (see
        // docs/CANVAS_LOGIN_DIAGNOSIS.md H1/H2).
        Task {
            await WebsiteDataReset.purgeWebsiteData(
                matchingDomainContains: Self.canvasLoginDomainHints,
                in: LoginDataStores.canvas
            )
        }
    }

    /// Signs out of Gradescope: purges its cookies and everything scraped with
    /// them. Canvas stays connected.
    func disconnectGradescope() {
        SessionCookieStore.remove(service: .gradescope)
        setGradescopeConnected(false)
        gradescopeItems = []
        // Ledger rows too — same reasoning as disconnectCanvas.
        assignmentStore?.purge(source: .gradescope)
        reloadCompletionFromLedger()
        rebuildDashboardItems()
        Task {
            await WebsiteDataReset.purgeWebsiteData(
                matchingDomainContains: ["gradescope"],
                in: LoginDataStores.gradescope
            )
        }
    }

    /// Domain substrings covering the whole Canvas/Penn SSO login chain.
    ///
    /// `WebsiteDataReset.purgeWebsiteData` matches these against
    /// `WKWebsiteDataRecord.displayName`, which WebKit derives as the
    /// record's eTLD+1 (registrable domain) — e.g. a cookie on
    /// `canvas.upenn.edu` or `idp.pennkey.upenn.edu` both report a
    /// `displayName` of `"upenn.edu"`, NOT `"canvas.upenn.edu"` or
    /// `"pennkey.upenn.edu"`. So `"canvas"` and `"pennkey"` as needles never
    /// match anything — they were silently dead. `"upenn"` (covers the SP and
    /// the Shibboleth IdP), `"duosecurity"` (Duo 2FA, if reached), and
    /// `"instructure"` (Canvas's own SaaS domain, for Instructure-hosted
    /// instances or embedded Canvas resources that don't live under
    /// upenn.edu) are what actually match real records. Shared by the
    /// pre-login purge in `OnboardingView`'s login panes and the
    /// post-disconnect purge above so both stay in sync.
    static let canvasLoginDomainHints = ["upenn", "duosecurity", "instructure"]

    /// Onboarding's "Trouble connecting? Reset login data" escape hatch. Wipes
    /// every trace of a stuck/stale login: the live `WKWebsiteDataStore`
    /// (cookies, cache, local storage — all domains, not just Canvas's, since
    /// this is the button a lost user reaches for when nothing else worked),
    /// the Keychain-persisted cookie copy, and every connected-service flag.
    ///
    /// This exists because a full delete-and-reinstall — the only other way
    /// to reach a clean slate — does NOT actually reach one: `SessionCookieStore`
    /// lives in the Keychain, which iOS keeps across app deletion by design,
    /// and onboarding never runs the code path that would replay those
    /// cookies anyway (`AutoSyncCoordinator` is only reachable from the
    /// post-onboarding dashboard). So reinstalling clears less state than
    /// this button does, while looking to the user like it should clear
    /// everything. This button is the actual "start completely over."
    func resetAllLoginData() async {
        disconnectCanvas()
        disconnectGradescope()
        setCanvasDiscoveryConnected(false)
        SessionCookieStore.clear()
        // Sweeps the legacy shared store, both isolated per-service stores,
        // AND `HTTPCookieStorage.shared` (docs/CANVAS_LOGIN_HARDENING.md item
        // 2d) — the one jar nothing else here touches, since it's a separate,
        // non-WebKit cookie storage.
        await WebsiteDataReset.purgeAllLoginStores()
        // Diagnostics shouldn't outlive a reset — nothing sensitive is in it
        // (host/path/status only), but it's specific to the login attempt(s)
        // being thrown away.
        LoginDiagnosticsLog.shared.clear()
    }

    func syncIfConfigured() async {
        guard !canvasICSURL.isEmpty else { return }
        await sync()
    }

    /// Recovers course attribution for a Canvas calendar item that fell into
    /// `unknownCourse` because its SUMMARY carried no `[Course Name]` suffix.
    /// Sanitized on-device diagnostics showed this happening for real: 17
    /// `.event` items with no suffix all bucketed under "(unknown course)",
    /// while the course they actually belonged to (enrolled, Canvas id known)
    /// had zero feed items and profiled as SILENT. The SUMMARY doesn't name
    /// the course, but the event's own URL still embeds the Canvas course id
    /// (`courseID(from:)`) — the only recoverable attribution left — so an
    /// unknown-course item whose URL resolves to an id in `enrolledCanvasCourses`
    /// is re-keyed to that course. An item whose URL points at a course id that
    /// ISN'T enrolled deliberately stays `unknownCourse`: that's an
    /// institution-wide calendar entry (a holiday, a "no class / no exams"
    /// day), not a misattributed one.
    ///
    /// Internal, not private, so it's directly testable — see
    /// `UnknownCourseAttributionTests.swift` — the same reasoning as
    /// `isEnrolledCourseCurrent`.
    func attributingUnknownCourse(_ item: Assignment) -> Assignment {
        guard item.course == Self.unknownCourse,
              let url = item.url,
              let id = Self.courseID(from: url),
              let match = enrolledCanvasCourses.first(where: { $0.id == id })
        else { return item }
        return Assignment(
            source: item.source,
            sourceID: item.sourceID,
            kind: item.kind,
            course: Self.courseKey(forEnrolled: match),
            title: item.title,
            dueAt: item.dueAt,
            url: item.url,
            term: item.term,
            submitted: item.submitted,
            scoreEarned: item.scoreEarned,
            scoreMax: item.scoreMax,
            linkedID: item.linkedID
        )
    }

    func sync() async {
        guard let url = URL(string: canvasICSURL), !canvasICSURL.isEmpty else {
            error = "Paste your Canvas calendar feed URL first."
            return
        }
        isLoading = true
        error = nil
        defer { isLoading = false }
        do {
            let client = CanvasICSClient(feedURL: url)
            // Re-attribute unknown-course items by their URL's course id
            // BEFORE reconciling: `StoredAssignment.refresh(from:now:)` copies
            // `course` from the feed item on every sync a row is seen again
            // (verified by reading it), so doing this first means the
            // ledger's course field picks up the correction on this very
            // sync rather than needing a special-case write. On a fresh
            // install the first sync can run before `enrolledCanvasCourses`
            // has ever been populated, so attribution can lag one sync —
            // it self-heals on the next one since `course` is feed-refreshed
            // every time.
            let fetched = try await client.fetchCalendarItems()
                .map(attributingUnknownCourse)
                .sorted(by: Self.byDueDate)
            // Reconcile into the durable ledger rather than replacing the pool:
            // items that dropped out of the rolling feed are retained, and a
            // suspiciously empty fetch is refused so one blip can't wipe the list.
            if let store = assignmentStore {
                let result = store.reconcile(fetched, source: .canvas)
                canvasItems = result.items.sorted(by: Self.byDueDate)
                if result.wasSuspectedPartial {
                    syncNotice = "couldn't fully refresh canvas just now. showing your saved assignments."
                }
                // Rows this reconcile just created may be the ones a carried-over
                // completion has been waiting for.
                reloadCompletionFromLedger()
            } else {
                canvasItems = fetched
            }
            rebuildDashboardItems()
            recomputeCourseProfiles()
            lastSync = Date()
        } catch {
            self.error = "Sync failed: \(error.localizedDescription)"
        }
    }

    /// One-step Canvas connect for onboarding: captures the personal ICS feed URL
    /// from the logged-in session, syncs Canvas, then scans for requirements.
    /// Returns true once the feed was captured (the bar for "Canvas connected").
    @discardableResult
    func connectCanvas(cookies: [HTTPCookie]) async -> Bool {
        isCanvasDiscoveryLoading = true
        error = nil
        defer { isCanvasDiscoveryLoading = false }

        guard !cookies.isEmpty else {
            error = "No Canvas session was found yet. Finish logging in to Canvas, then try again."
            return false
        }

        let client = CanvasDiscoveryClient(cookies: cookies)
        do {
            let feedURL = try await client.discoverCalendarFeedURL()
            updateCanvasICSURL(feedURL.absoluteString)
        } catch {
            self.error = error.localizedDescription
            return false
        }

        await sync()
        refreshCanvasSessionExpiredState()
        return isCanvasConnected
    }

    func scanCanvasRequirements(cookies: [HTTPCookie]) async {
        await scanCanvasRequirements(cookies: cookies, reportErrors: true)
    }

    func scanCanvasRequirements(cookies: [HTTPCookie], reportErrors: Bool) async {
        isCanvasDiscoveryLoading = true
        if reportErrors { error = nil }
        defer { isCanvasDiscoveryLoading = false }

        let courseIDs = canvasCourseIDs()

        do {
            let client = CanvasDiscoveryClient(cookies: cookies)
            canvasRequirementSuggestions = try await client.scan(courseIDs: courseIDs)
            setCanvasDiscoveryConnected(true)
            syncNotice = canvasRequirementSuggestions.isEmpty ? "Canvas Scan connected. No recurring syllabus or announcement requirements found yet." : nil
        } catch {
            setCanvasDiscoveryConnected(false)
            let message = "Canvas Scan needs you to reconnect or open Canvas once."
            if reportErrors {
                self.error = "\(message) \(error.localizedDescription)"
            } else {
                self.syncNotice = message
            }
        }
    }

    func setCanvasDiscoveryConnected(_ connected: Bool) {
        isCanvasDiscoveryConnected = connected
        UserDefaults.lhf.set(connected, forKey: Self.canvasDiscoveryConnectedKey)
    }

    func syncGradescope(cookies: [HTTPCookie]) async {
        await syncGradescope(cookies: cookies, reportErrors: true)
    }

    /// Scrapes the user's Gradescope assignments using the captured login cookies
    /// and folds them into the dashboard. Cookie sessions expire server-side; on
    /// failure we mark Gradescope disconnected so the UI can prompt a reconnect.
    func syncGradescope(cookies: [HTTPCookie], reportErrors: Bool) async {
        // Reentrancy guard: the 5-min loop and a scene-activation can both fire a
        // sync; without this they'd run two full scrapes concurrently. The check
        // and set are synchronous on the main actor, so there's no TOCTOU window.
        guard !isGradescopeLoading else { return }
        isGradescopeLoading = true
        if reportErrors { error = nil }
        defer { isGradescopeLoading = false }

        guard !cookies.isEmpty else {
            if reportErrors { error = "No Gradescope session was found yet. Finish logging in, then try again." }
            setGradescopeConnected(false)
            return
        }

        do {
            let client = GradescopeClient(cookies: cookies)
            // Normalize Gradescope's course labels through the same parser as
            // Canvas so a course shared by both sources collapses to one picker
            // entry (e.g. "CIS 2400 Systems Programming" → "CIS 2400").
            let fetched = try await client.fetchAssignments().map(Self.normalizingCourse)
            // Same durable reconciliation as Canvas (see `sync()`).
            if let store = assignmentStore {
                gradescopeItems = store.reconcile(fetched, source: .gradescope).items
                reloadCompletionFromLedger()
            } else {
                gradescopeItems = fetched
            }
            lastGradescopeSync = Date()
            setGradescopeConnected(true)
            rebuildDashboardItems()
        } catch {
            setGradescopeConnected(false)
            let message = "Gradescope needs you to reconnect."
            if reportErrors {
                self.error = "\(message) \(error.localizedDescription)"
            } else {
                self.syncNotice = message
            }
        }
    }

    func setGradescopeConnected(_ connected: Bool) {
        isGradescopeConnected = connected
        UserDefaults.lhf.set(connected, forKey: Self.gradescopeConnectedKey)
    }

    /// Refreshes Grade Watcher for the SELECTED courses only (docs/grades.md
    /// Decision 4) — a course the user hid from the dashboard via the class
    /// picker is also skipped here, so we never fetch grades for a course
    /// nobody asked to see.
    func refreshGradeWatcher(cookies: [HTTPCookie]) async {
        // The demo has no session and must never reach the network. Re-seed
        // the fixtures instead of falling through to a refresh that would set
        // the "No saved Canvas session" banner over the sample grades.
        guard !isUsingFixtureData else {
            gradeWatcher.loadPreviewSnapshots(SampleData.gradeSnapshots())
            return
        }

        // Piggyback on Gradescope items this launch's throttled AutoSyncCoordinator
        // sync already fetched (docs/grades.md §4/§9) — never a second, unthrottled
        // Gradescope scrape just for the overlay.
        await gradeWatcher.refresh(
            courseIDs: selectedCanvasCourseIDs(),
            cookies: cookies,
            gradescopeItems: isGradescopeConnected ? gradescopeItems : []
        )
        updateSubmissionState()

        // Second trigger site for session-longevity Layer 2
        // (`CanvasSessionRenewer`): a per-course 401 this refresh folded into
        // `isSessionExpired` can surface a lapsed session before
        // `canvasSessionExpired`'s own launch/connect/disconnect cadence
        // catches up. Fire-and-forget, kept here rather than inside
        // `GradeWatcherStore` itself so that store stays free of any
        // renewer/WebKit dependency; safe to call alongside the
        // `refreshCanvasSessionExpiredState()` trigger site since the
        // renewer's own cooldown/in-flight guards make redundant calls a
        // no-op.
        if gradeWatcher.isSessionExpired {
            Task { await attemptSilentCanvasRenewal() }
        }
    }

    /// Discovers the full enrolled-course list (including courses with zero
    /// feed presence) and probes the ones the feed hasn't already covered,
    /// so SILENT and READINGS_ON_CALENDAR courses can be detected and
    /// explained (docs/READINGS_COURSES_PLAN.md Phase 2). Mirrors
    /// `refreshGradeWatcher`'s guard and cookie handling — fixture/demo mode
    /// never reaches the network, and an empty cookie set is a silent no-op
    /// rather than an error the user has to dismiss.
    ///
    /// This is entirely a DETECTION/list-visibility path. Its only effect on
    /// Grade Watcher is additive — folding newly-discovered courses into
    /// `canvasCourseIDsByCode` so they become watchable at all — never a
    /// removal, and never anything routed through `courseContentDecisions`
    /// (see the plan's "Hard requirement — Grade Watcher independence").
    func refreshCourseIntel(cookies: [HTTPCookie]) async {
        guard !isUsingFixtureData, !cookies.isEmpty else { return }

        let client = CanvasDiscoveryClient(cookies: cookies)
        // Backstop behind `CanvasCourseDiscoveryParser.currentEnrollmentLinks`'s
        // HTML-section split: that filter is best-effort page-shape scraping,
        // so anything that leaks through (a redesign quietly renames the
        // markers, an odd cross-listed section) gets one more chance to be
        // caught here by its own course-code term suffix.
        //
        // `CourseCode.containsExplicitCode` filters out enrollment entries
        // whose Canvas display name never carries a real DEPT+number course
        // code — sanitized on-device data showed these are Canvas
        // community/resource sites the enrollment scrape can't otherwise
        // tell apart from a real class: "Chemistry Diagnostic 2024-2025",
        // "Math Diagnostic 2024-2025", "Penn Engineering Class of 2028",
        // "Physics Exam Archive", "The Studios @ Venture Labs",
        // "Connections@Wharton". A real class ("ACCT 1010", "LGST 1010")
        // always parses. Effect, traced through the rest of this file: a
        // filtered-out entry never enters `enrolledCanvasCourses`, so it's
        // never folded into `canvasCourseIDsByCode` (`mergeEnrolledCoursesIntoCourseIDCache`
        // below — keeps it out of the Grade Watcher picker), never reaches
        // the probe loop or `CourseProfileEngine.reports` (never nudged,
        // never listed in Settings' "Courses & content"), and a junk entry
        // that snuck into `canvasCourseIDsByCode` on an earlier launch gets
        // dropped by `pruneStaleCourseIDCacheEntries` below on this one,
        // since it's absent from `currentEnrolledKeys` and (being a resource
        // site, not a class) has no feed or Gradescope items either. One
        // known accepted false positive: "TAP 2028" parses like a course
        // code and survives this filter; a user who doesn't want it toggles
        // it off manually like any other course.
        let enrolled = await client.discoverEnrolledCourses()
            .filter { Self.isEnrolledCourseCurrent($0) && CourseCode.containsExplicitCode($0.name) }
        if !enrolled.isEmpty {
            enrolledCanvasCourses = enrolled
            // The enrolled list just arrived or changed, which is exactly
            // when an item stuck at `unknownCourse` (its URL's course id
            // wasn't enrolled yet) might now resolve. Re-attribute in memory
            // and rebuild so the correction shows up without waiting for the
            // next feed sync. Deliberately BEFORE `pruneStaleCourseIDCacheEntries`
            // and the probe loop below: both read `canvasItems.map(\.course)`
            // to decide what already has feed presence, and a still-unknown
            // course would make the probe fetch it needlessly (or the prune
            // wrongly treat its cache entry as stale).
            canvasItems = canvasItems.map(attributingUnknownCourse)
            rebuildDashboardItems()
            persistEnrolledCanvasCourses()
            pruneStaleCourseIDCacheEntries(
                currentEnrolledKeys: Set(enrolled.map { Self.courseKey(forEnrolled: $0) })
            )
        }

        mergeEnrolledCoursesIntoCourseIDCache()

        // Probe only courses the feed hasn't already accounted for (a course
        // with feed items is never SILENT — see `CourseProfileEngine
        // .reports`) and that have no probe result yet this launch. Capped
        // at 8 per refresh so a heavy course load can't turn one refresh
        // into dozens of sequential HTML fetches.
        let feedCourseKeys = Set(canvasItems.map(\.course))
        let toProbe = enrolledCanvasCourses
            .filter { course in
                !feedCourseKeys.contains(Self.courseKey(forEnrolled: course))
                    && courseProbes[course.id] == nil
            }
            .prefix(8)

        for course in toProbe {
            let courseKey = Self.courseKey(forEnrolled: course)
            // The JSON modules API (`CanvasModulesClient`) is the robust
            // source for a course's readings — it's tried FIRST. Only when it
            // throws (expired session, HTTP error — never on a merely empty
            // result, which still counts as "probed, found nothing") do we
            // fall back to the HTML scrape (`fetchModulesReadings`) that ran
            // here before, keeping that path's exact result semantics.
            let modulesClient = CanvasModulesClient(cookies: cookies)
            if let items = try? await modulesClient.fetchModuleItems(courseID: course.id) {
                courseProbes[course.id] = CourseProbeResult(submittableAssignmentCount: nil, moduleReadingCount: items.count)
                // A course probed for the first time this launch that ALSO
                // already carries an "include" decision from a previous
                // session (the common nudge-then-relaunch case) is imported
                // right away via the shared `importModuleReadings`, instead
                // of collecting into a batch reconciled once after this
                // loop. This costs one extra `fetchModuleItems` call for that
                // course (`importModuleReadings` fetches its own copy rather
                // than taking `items` as a parameter, so it can be shared
                // verbatim with `importReadingsIfNeeded` below) — an
                // acceptable trade for not having a second, batch-shaped
                // import path with its own reconcile/upsert semantics to
                // keep in sync with this one.
                if !items.isEmpty && courseContentDecisions[courseKey]?.choice == .include {
                    _ = await importModuleReadings(courseKey: courseKey, courseID: course.id, cookies: cookies)
                }
                continue
            }
            // A thrown fetch (expired session, HTTP error) leaves NO probe
            // entry — that's what keeps `.unknownSilent` honest instead of
            // quietly reporting "probed, found nothing" for a course LHF
            // never actually looked at this launch.
            guard let items = try? await client.fetchModulesReadings(courseID: course.id) else { continue }
            courseProbes[course.id] = CourseProbeResult(submittableAssignmentCount: nil, moduleReadingCount: items.count)
        }

        rebuildDashboardItems()

        recomputeCourseProfiles()
    }

    /// Fetches a probed course's Modules-page readings via the JSON API and
    /// upserts them into the ledger as `.canvasModules` rows, then refreshes
    /// `moduleReadingItems` from the ledger. Shared by the probe loop above
    /// (for a course already decided "include" when its first probe of this
    /// launch lands) and `importReadingsIfNeeded` below (the immediate
    /// import that runs the moment a user answers a nudge or flips the
    /// Settings toggle). Returns whether the fetch itself succeeded — a
    /// thrown fetch (expired session, HTTP error) leaves the ledger
    /// untouched rather than being treated as "confirmed empty."
    ///
    /// Persists via `upsert`, not `reconcile`: `upsert` only ever inserts a
    /// new row or refreshes an existing one by id (see `AssignmentStore
    /// .upsert`) — it never marks anything `isGoneFromFeed`. `reconcile` was
    /// the wrong tool here because it partitions by SOURCE, not by course:
    /// reconciling THIS course's freshly-fetched items against the WHOLE
    /// `.canvasModules` ledger meant every other already-imported course's
    /// rows — invisible to this fetch, since it only ever asked Canvas about
    /// one course — looked "missing from a non-empty fetch" and got marked
    /// gone (this is what happened before this fix: one course's import
    /// batch could mark another course's module rows gone). `upsert`
    /// sidesteps that distinction entirely: it only ever touches rows for
    /// the ids in the list it's given.
    private func importModuleReadings(courseKey: String, courseID: String, cookies: [HTTPCookie]) async -> Bool {
        let modulesClient = CanvasModulesClient(cookies: cookies)
        let items: [CanvasModulesClient.ModuleItem]
        do {
            items = try await modulesClient.fetchModuleItems(courseID: courseID)
        } catch {
            recordModuleImport("\(courseKey): fetch failed code=\((error as NSError).code)")
            return false
        }
        recordModuleImport("\(courseKey): fetched \(items.count) items, dated=\(items.filter { $0.dueAt != nil }.count)")

        // Pages/Files can't carry a `due_at` — Canvas's own dashboard still
        // shows them with times because a professor set a per-student
        // "to-do" date, which lives only in the planner API (field evidence:
        // a real course's 55 module readings all imported dated=0 despite
        // showing times on the dashboard). Only worth the extra round trip
        // when something actually needs it. Window: 120 days back to 365
        // days forward covers a whole semester in both directions off one
        // cheap paginated call, so it doesn't need to track term boundaries.
        // Which module-item types this course actually uses — the planner
        // can only date types that map to a plannable (Page/Assignment/Quiz/
        // Discussion); a course built from ExternalUrls or Files is
        // undateable through the planner no matter what, and this line is
        // how the diagnostics report says so. Types + counts only.
        var typeTally: [String: Int] = [:]
        for item in items { typeTally[item.typeRaw, default: 0] += 1 }
        let typeSummary = typeTally.keys.sorted()
            .map { "\($0)=\(typeTally[$0]!)" }
            .joined(separator: " ")
        recordModuleImport("\(courseKey): types \(typeSummary)")

        let overlaidItems: [CanvasModulesClient.ModuleItem]
        if items.contains(where: { $0.dueAt == nil }) {
            let now = Date()
            let plannerStart = now.addingTimeInterval(-120 * 24 * 60 * 60)
            let plannerEnd = now.addingTimeInterval(365 * 24 * 60 * 60)
            var plannerDates: [PlannerDatedItem] = []
            do {
                plannerDates = try await modulesClient.fetchPlannerDates(
                    courseID: courseID,
                    start: plannerStart,
                    end: plannerEnd
                )
                // matched = entries the decoder kept FOR THIS COURSE; a
                // healthy fetch with matched=0 means the planner has nothing
                // for the course (or ids/types don't line up), which is a
                // different failure from the request dying.
                recordModuleImport("\(courseKey): planner fetch ok, matched=\(plannerDates.count)")
            } catch {
                recordModuleImport("\(courseKey): planner fetch failed code=\((error as NSError).code)")
            }
            overlaidItems = CanvasModulesClient.overlayDates(items, planner: plannerDates)
            let newlyDated = overlaidItems.filter { $0.dueAt != nil }.count - items.filter { $0.dueAt != nil }.count
            recordModuleImport("\(courseKey): planner dated=\(newlyDated) of \(items.count)")
        } else {
            overlaidItems = items
            recordModuleImport("\(courseKey): planner dated=0 of \(items.count)")
        }

        let readings = overlaidItems.map { item in
            Assignment(
                source: .canvasModules,
                sourceID: "module-item-\(item.id)",
                kind: .event,
                course: courseKey,
                title: item.title,
                dueAt: item.dueAt,
                url: nil
            )
        }
        if let store = assignmentStore {
            store.upsert(readings)
            moduleReadingItems = store.assignments(source: .canvasModules)
        } else {
            moduleReadingItems = readings
        }
        recordModuleImport("\(courseKey): holding \(moduleReadingItems.count) rows after upsert")
        return true
    }

    /// Imports a just-decided-in course's readings right away, instead of
    /// waiting for the next launch's `refreshCourseIntel` probe loop to
    /// notice the decision. Field evidence this fixes: probes run at most
    /// once per course per launch (the `courseProbes` gate), and import only
    /// ever happened INSIDE that same probe loop — but every include
    /// decision necessarily arrives strictly AFTER the probe that produced
    /// the nudge it's answering, so answering "Add to my list" (`resolveCourseNudge`)
    /// or flipping the Settings toggle on (`setCourseContentIncluded`) used
    /// to import nothing until the app was relaunched. Both call this.
    ///
    /// Fire-and-forget: started as an unstructured `Task`, not awaited by
    /// the caller. That's acceptable because the caller has already updated
    /// `courseContentDecisions`/`pendingCourseNudge` and rebuilt the
    /// dashboard synchronously — this call only needs to catch the ledger
    /// and dashboard up with the freshly-imported readings once the network
    /// round trip completes, the same "sync happens in the background, the
    /// toggle itself is immediate" posture as the rest of this file's
    /// cookie-gathering call sites.
    ///
    /// No-ops in fixture/preview mode, when there's no live Canvas session
    /// to fetch with, or when `courseKey`'s Canvas course id can't be
    /// resolved — the "silent no-op, not a user-facing error" posture
    /// `refreshGradeWatcher`/`refreshCourseIntel` already use for the same
    /// situations.
    func importReadingsIfNeeded(for courseKey: String) {
        guard !isUsingFixtureData else { return }
        guard let courseID = courseProfileReports.first(where: { $0.courseKey == courseKey })?.canvasCourseID
            ?? enrolledCanvasCourses.first(where: { Self.courseKey(forEnrolled: $0) == courseKey })?.id
        else {
            recordModuleImport("\(courseKey): no course id resolvable")
            return
        }

        recordModuleImport("\(courseKey): on-decision import starting")
        Task { @MainActor in
            let cookies = await AutoSyncCoordinator.canvasCookies()
            guard !cookies.isEmpty else {
                recordModuleImport("\(courseKey): no canvas cookies")
                return
            }
            _ = await importModuleReadings(courseKey: courseKey, courseID: courseID, cookies: cookies)
            rebuildDashboardItems()
        }
    }

    /// Folds the enrolled-course list into `canvasCourseIDsByCode` — the map
    /// `selectedCanvasCourseIDs()` reads for Grade Watcher — so a course
    /// with zero feed items (readings-only, or genuinely silent) becomes
    /// watchable at all; today it's invisible to Grade Watcher because
    /// nothing else ever discovers it (docs/READINGS_COURSES_PLAN.md "Hard
    /// requirement — Grade Watcher independence"). Only ADDS: an id already
    /// resolved from a feed item's URL (`updateCanvasCourseIDCache`) is a
    /// stronger source and is never overwritten by this name-parsed one.
    private func mergeEnrolledCoursesIntoCourseIDCache() {
        let byCode = canvasCourseIDsByCode
        var additions: [String: String] = [:]
        for course in enrolledCanvasCourses {
            let key = Self.courseKey(forEnrolled: course)
            // Skip only the degenerate case: an unparseable AND empty raw
            // name, which would otherwise insert a useless "" key. The
            // `byCode[key] == nil` guard keeps this pass add-only: an id
            // already resolved from a feed item's URL is a stronger source
            // and is never overwritten by this name-parsed one.
            guard !key.isEmpty, byCode[key] == nil, additions[key] == nil else { continue }
            additions[key] = course.id
        }
        guard !additions.isEmpty else { return }
        coursePreferences.mergeCanvasCourseIDs(additions)
    }

    /// The same course-key derivation `CourseProfileEngine` uses internally
    /// (parse the enrolled display name; fall back to the raw name when it
    /// doesn't parse), duplicated here because the engine's version is
    /// private — this is the join key between an enrolled course and its
    /// feed items' already-clean `course` field.
    private static func courseKey(forEnrolled course: CanvasCourseDiscoveryParser.Course) -> String {
        let parsed = CourseCode.parse(course.name).code
        return parsed == unknownCourse ? course.name : parsed
    }

    /// True when `course`'s parsed term (from the `YYYYTT` suffix Canvas
    /// embeds in its display name, via `CourseCode.parse`) is absent, or not
    /// strictly before `now`'s term. Internal (not private) and pure so it's
    /// directly testable — see `CurrentEnrollmentTests.swift` — without a
    /// live Canvas session. A course with NO parseable term passes through
    /// unfiltered: the HTML-section filter (`currentEnrollmentLinks`)
    /// already vouched for it, and a term-less course is better shown than
    /// wrongly hidden.
    static func isEnrolledCourseCurrent(_ course: CanvasCourseDiscoveryParser.Course, now: Date = Date()) -> Bool {
        guard let term = CourseCode.parse(course.name).term else { return true }
        return term >= Term(date: now)
    }

    /// Removes `canvasCourseIDsByCode` entries that can only be leftovers
    /// from the earlier over-inclusive `/courses` scrape (the bug
    /// `currentEnrollmentLinks` fixes): a course code that (1) isn't among
    /// this refresh's current enrolled courses, (2) has zero items in this
    /// launch's Canvas feed, and (3) has zero items in Gradescope. Such an
    /// entry has nothing to display and nothing for Grade Watcher to
    /// watch — it can only be dead weight, so it's safe to drop. This isn't
    /// permanent: a course that becomes real again re-enters through either
    /// a fresh discovery pass or its own feed items
    /// (`updateCanvasCourseIDCache`). Deliberately leaves `deletedCourseKeys`
    /// and hidden/selection state untouched — this only prunes the id
    /// lookup table, never a user's own choices.
    func pruneStaleCourseIDCacheEntries(currentEnrolledKeys: Set<String>) {
        let feedCourseKeys = Set(canvasItems.map(\.course))
        let gradescopeCourseKeys = Set(gradescopeItems.map(\.course))

        let byCode = canvasCourseIDsByCode
        let staleKeys = byCode.keys.filter { key in
            !currentEnrolledKeys.contains(key)
                && !feedCourseKeys.contains(key)
                && !gradescopeCourseKeys.contains(key)
        }
        guard !staleKeys.isEmpty else { return }

        for key in staleKeys { coursePreferences.setCanvasCourseID(key, nil) }
    }

    private func persistEnrolledCanvasCourses() {
        let byID = Dictionary(uniqueKeysWithValues: enrolledCanvasCourses.map { ($0.id, $0.name) })
        UserDefaults.lhf.set(byID, forKey: Self.enrolledCanvasCoursesKey)
    }

    /// Recomputes every course's profile from current feed items, the
    /// cached enrolled-course list, and this launch's probes, then queues a
    /// nudge if one is warranted. Call after anything that could change any
    /// of those three inputs — a successful `sync()`, or `refreshCourseIntel`.
    private func recomputeCourseProfiles() {
        // Deliberately `canvasItems`, never `canvasItems + moduleReadingItems`:
        // silence is a property of the ICS FEED (does this course publish
        // anything on the calendar at all?), and `moduleReadingItems` is
        // itself the OUTCOME of probing a course this engine already called
        // silent. Folding imported readings back in here would make an
        // opted-in silent course look `.normal` on the very next refresh and
        // silently stop nudging/managing it.
        courseProfileReports = CourseProfileEngine.reports(
            feedItems: canvasItems,
            enrolledCourses: enrolledCanvasCourses,
            probes: courseProbes
        )
        queueNudgeIfNeeded()
        logCourseIntelDiagnostics()
    }

    /// Surfaces at most one nudge per app-open (docs/READINGS_COURSES_PLAN.md
    /// "no nag storms"). A report is nudge-worthy when its profile is
    /// actionable (`isActionable`) and either no decision has been recorded
    /// for it, or the recorded decision's fingerprint CLASS (the substring
    /// before ":" — "readings"/"silent"/…) differs from the current one: a
    /// silent course whose reading count merely grew isn't re-asked, but one
    /// that starts putting events on the calendar is. A deleted course is
    /// never nudged.
    private func queueNudgeIfNeeded() {
        guard pendingCourseNudge == nil, !nudgePresentedThisLaunch else { return }

        let candidates = courseProfileReports
            .filter { !deletedCourseKeys.contains($0.courseKey) }
            .filter(Self.isActionable)
            .filter { report in
                guard let decision = courseContentDecisions[report.courseKey] else { return true }
                return Self.fingerprintClass(decision.fingerprint) != Self.fingerprintClass(report.fingerprint)
            }
            .sorted { $0.courseKey.localizedStandardCompare($1.courseKey) == .orderedAscending }

        guard let next = candidates.first else { return }
        pendingCourseNudge = next
        nudgePresentedThisLaunch = true
    }

    /// Worth ASKING about: dated readings on the calendar, or a silent
    /// course whose probe found actual module readings. `.normal` (already
    /// represented on the dashboard), `.unknownSilent` (nothing concrete to
    /// show yet — no session to probe with), and a silent course whose probe
    /// came back with zero/no readings never nudge — stricter than
    /// `isManageable` below, which also lists a confirmed-empty silent
    /// course so Settings can say so.
    private static func isActionable(_ report: CourseProfileReport) -> Bool {
        switch report.profile {
        case .readingsOnCalendar:
            return true
        case let .silent(moduleReadingCount):
            return (moduleReadingCount ?? 0) > 0
        case .normal, .unknownSilent:
            return false
        }
    }

    /// Worth LISTING in Settings' "Courses & content" management section:
    /// readings-on-calendar, or any silent course a probe actually reached
    /// (`moduleReadingCount != nil`) — including one that came back
    /// confirmed-empty, which `isActionable` deliberately excludes from the
    /// nudge queue but Settings should still be able to show and explain.
    private static func isManageable(_ report: CourseProfileReport) -> Bool {
        switch report.profile {
        case .readingsOnCalendar:
            return true
        case let .silent(moduleReadingCount):
            return moduleReadingCount != nil
        case .normal, .unknownSilent:
            return false
        }
    }

    /// The stable part of a fingerprint used to decide whether a course's
    /// shape changed enough to re-ask — the substring before the first ":"
    /// (e.g. "readings:10" -> "readings"), or the whole string when there's
    /// no ":" (e.g. "normal", "unknownSilent").
    private static func fingerprintClass(_ fingerprint: String) -> String {
        String(fingerprint.split(separator: ":", maxSplits: 1).first ?? Substring(fingerprint))
    }

    /// Records the user's answer to a course-content nudge — writes the
    /// decision, persists it, clears the pending nudge, and rebuilds so the
    /// choice takes effect immediately.
    func resolveCourseNudge(_ report: CourseProfileReport, include: Bool) {
        setCourseContentDecision(
            courseKey: report.courseKey,
            choice: include ? .include : .exclude,
            fingerprint: report.fingerprint
        )
        pendingCourseNudge = nil
        rebuildDashboardItems()
        // Import right away rather than waiting for next launch's probe loop
        // to notice this decision — see `importReadingsIfNeeded`'s doc
        // comment for the field evidence this fixes.
        if include { importReadingsIfNeeded(for: report.courseKey) }
    }

    /// Dismisses the pending nudge WITHOUT recording a decision, so the same
    /// course is asked again next launch — dismissing isn't an answer.
    func dismissCourseNudge() {
        pendingCourseNudge = nil
    }

    /// Whether `course`'s opted-in content (readings/events) currently shows
    /// on the dashboard. Default is false (exclude) when no decision is on
    /// file — see `CourseContentDecision`'s doc comment.
    func courseContentIncluded(_ course: String) -> Bool {
        courseContentDecisions[course]?.choice == .include
    }

    /// Settings surface ("Courses & content"): sets or overwrites the
    /// decision for `course` directly, independent of any pending nudge.
    /// Uses the current profile report's fingerprint when one is on file for
    /// this course, so a later profile-class change is still measured
    /// against a real fingerprint; falls back to "manual" when this course
    /// has no computed report yet (e.g. set before the first sync this
    /// launch).
    func setCourseContentIncluded(_ course: String, _ include: Bool) {
        let fingerprint = courseProfileReports.first { $0.courseKey == course }?.fingerprint ?? "manual"
        setCourseContentDecision(courseKey: course, choice: include ? .include : .exclude, fingerprint: fingerprint)
        if pendingCourseNudge?.courseKey == course { pendingCourseNudge = nil }
        rebuildDashboardItems()
        // Same immediate-import fix as `resolveCourseNudge` — flipping this
        // toggle on used to import nothing until the next launch's probe
        // loop happened to notice the decision.
        if include { importReadingsIfNeeded(for: course) }
    }

    private func setCourseContentDecision(courseKey: String, choice: CourseContentDecision.Choice, fingerprint: String) {
        courseContentDecisions[courseKey] = CourseContentDecision(
            choice: choice,
            fingerprint: fingerprint,
            decidedAt: Date()
        )
        CourseContentDecisionStore.save(courseContentDecisions)
        if cloudSyncEnabled { cloudPrefsMirror.push(key: "courseContentDecisionsV1") }
    }

    /// Courses worth surfacing in Settings' "Courses & content" management
    /// section: every course with a manageable profile (see `isManageable`),
    /// decided or not.
    var courseContentManageableCourses: [CourseProfileReport] {
        courseProfileReports
            .filter(Self.isManageable)
            .sorted { $0.courseKey.localizedStandardCompare($1.courseKey) == .orderedAscending }
    }

    // MARK: - Diagnostics (course intel)
    //
    // There is no telemetry in this app by design — everything is on-device.
    // These two surfaces (the copyable `DiagnosticsReport` and the console
    // log below) are the ONLY debug channels for a puzzling on-device course
    // profile, so they're read-only projections of state this file already
    // holds, not a new source of truth.
    //
    // Privacy budget, same as `DiagnosticsReport`'s: course codes, profile
    // shapes, counts, item kinds, and dates are fine. NEVER an assignment or
    // reading title, a URL, or a token/cookie value — nothing here ever
    // touches `Assignment.title` or `Assignment.url`.

    /// One line per course's computed profile, one line per course's feed-kind
    /// histogram (built from `canvasItems` alone — titles never enter this
    /// computation), and a final summary line. Consumed verbatim by
    /// `DiagnosticsReport` and mirrored to the console log by
    /// `recomputeCourseProfiles()`.
    var courseIntelDiagnosticLines: [String] {
        var lines: [String] = []

        for report in courseProfileReports {
            lines.append(
                "\(report.courseKey): \(Self.courseProfileDescription(report.profile)) fingerprint=\(report.fingerprint) id=\(report.canvasCourseID ?? "-")"
            )
        }

        var tallies: [String: CourseFeedKindTally] = [:]
        for item in canvasItems {
            var tally = tallies[item.course] ?? CourseFeedKindTally()
            switch item.kind {
            case .assignment: tally.assignment += 1
            case .quiz: tally.quiz += 1
            case .event: tally.event += 1
            case .discussion, .other: tally.other += 1
            }
            if item.dueAt == nil { tally.undated += 1 }
            tallies[item.course] = tally
        }
        for course in tallies.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            let t = tallies[course]!
            lines.append(
                "\(course): feed kinds assignment=\(t.assignment) quiz=\(t.quiz) event=\(t.event) other=\(t.other), undated=\(t.undated)"
            )
        }

        // One line per recorded decision, sorted for stable output — same
        // privacy budget as everything else here: the course key, the
        // include/exclude choice, and the stored fingerprint (a shape+count
        // summary, never a title) are all that's shown, e.g.
        // "decision LGST 1010: include (silent:55)".
        for key in courseContentDecisions.keys.sorted(by: { $0.localizedStandardCompare($1) == .orderedAscending }) {
            let decision = courseContentDecisions[key]!
            let choiceText = decision.choice == .include ? "include" : "exclude"
            lines.append("decision \(key): \(choiceText) (\(decision.fingerprint))")
        }

        // Import-path visibility (2026-08-23): a device kept reporting
        // "toggled include, nothing appeared" and every guard on the import
        // path fails SILENTLY by design — so the path now confesses here.
        // Same privacy budget: keys, counts, and error codes only.
        let datedModuleRows = moduleReadingItems.filter { $0.dueAt != nil }.count
        lines.append("module rows held=\(moduleReadingItems.count) dated=\(datedModuleRows)")
        let moduleInBuckets = (assignments + laterAssignments).filter { $0.source == .canvasModules }.count
        lines.append(
            "buckets near=\(assignments.count) later=\(laterAssignments.count) assessments=\(assessments.count) moduleRowsShown=\(moduleInBuckets)"
        )
        for entry in moduleImportLog {
            lines.append("import \(entry)")
        }
        lines.append(
            "enrolled=\(enrolledCanvasCourses.count) probed=\(courseProbes.count) decisions=\(courseContentDecisions.count)"
        )
        return lines
    }

    /// Rolling record of what the module-reading import path did this
    /// launch — every silent guard exit and every fetch outcome, newest
    /// last, capped so a pathological retry loop can't grow it unbounded.
    /// Course keys, counts, and error codes only; never titles or URLs.
    private(set) var moduleImportLog: [String] = []

    func recordModuleImport(_ entry: String) {
        moduleImportLog.append(entry)
        if moduleImportLog.count > 12 {
            moduleImportLog.removeFirst(moduleImportLog.count - 12)
        }
    }

    /// `<profile-name>(<counts>)` text for `courseIntelDiagnosticLines` — e.g.
    /// `normal`, `readingsOnCalendar(12, through 2026-12-08)`,
    /// `silent(modules: 3)`, `silent(modules: none)`, `unknownSilent`.
    private static func courseProfileDescription(_ profile: CourseProfile) -> String {
        switch profile {
        case .normal:
            return "normal"
        case let .readingsOnCalendar(eventCount, latestDate):
            let dateText = latestDate.map { courseIntelDateFormatter.string(from: $0) } ?? "unknown"
            return "readingsOnCalendar(\(eventCount), through \(dateText))"
        case let .silent(moduleReadingCount):
            let countText = moduleReadingCount.map(String.init) ?? "none"
            return "silent(modules: \(countText))"
        case .unknownSilent:
            return "unknownSilent"
        }
    }

    private static let courseIntelDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        return f
    }()

    /// Console-log mirror of `courseIntelDiagnosticLines`, so a puzzling
    /// on-device profile is visible live in Xcode's console without the user
    /// having to export the copyable report. Same privacy budget as that
    /// report — `.public` is safe here because the content is built to stay
    /// inside it. Skipped in fixture/preview mode: that's sample data, not a
    /// real account worth logging.
    private static let courseIntelLog = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "LHF",
        category: "course-intel"
    )

    private func logCourseIntelDiagnostics() {
        guard !isUsingFixtureData else { return }
        for line in courseIntelDiagnosticLines {
            Self.courseIntelLog.info("\(line, privacy: .public)")
        }
    }

    /// Rewrites an item's course label to the canonical `CourseCode` form so
    /// Gradescope and Canvas agree on course identity (the class picker keys on it).
    private static func normalizingCourse(_ a: Assignment) -> Assignment {
        let cleaned = CourseCode.parse(a.course).code
        guard cleaned != a.course else { return a }
        return Assignment(source: a.source, sourceID: a.sourceID, kind: a.kind,
                          course: cleaned, title: a.title, dueAt: a.dueAt,
                          url: a.url, term: a.term, submitted: a.submitted,
                          scoreEarned: a.scoreEarned, scoreMax: a.scoreMax)
    }

    // MARK: Course selection (class picker)

    /// Every distinct course the app knows about, sorted for a stable picker
    /// order. Drives the onboarding + Profile class list.
    ///
    /// **The union with hand-added classes is the fix for "only one class shows
    /// up".** This list used to be derived purely from what the feeds currently
    /// contain, which sounds reasonable and fails in exactly the week it matters
    /// most: a course that hasn't posted an assignment yet contributes no items,
    /// so it contributes no class, so in week one of a semester most of a
    /// student's timetable simply doesn't exist in the app. `canvasCourseID`
    /// already caches resolved ids so grades survive a quiet week; this is the
    /// same idea for the class list itself.
    ///
    /// Feed courses and hand-added courses share one namespace — the canonical
    /// `CourseCode` — so this is a set union and not a merge. When Canvas
    /// finally posts for a class the student typed in, the two are the same
    /// element and there is nothing to reconcile.
    func allCourseCodes() -> [String] {
        let pool = canvasItems + gradescopeItems
        let codes = Set(pool.map(\.course))
            .union(coursePreferences.manuallyAddedCourseKeys)
            .subtracting([Self.unknownCourse])
        return codes.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// The canonical form of a course code the student typed. Everything that
    /// identifies a class — selection, reminders, grades, dedup — keys on the
    /// output of `CourseCode.parse`, so an added class has to arrive through it
    /// or it will sit next to the feed's copy of the same course forever.
    /// "cis1200", "CIS 1200" and "cis-1200" all land on `CIS 1200`.
    /// A class the feed has never mentioned may legitimately have no course
    /// code at all — a thesis, a reading group, a lab that lives off Canvas — so
    /// a name that doesn't parse is kept as typed rather than refused. The one
    /// thing rejected is a name with nothing nameable in it: `CourseCode.parse`
    /// falls back to the raw string when it recognises nothing, which is right
    /// for a noisy feed descriptor and would otherwise let "???" become a class.
    static func normalizedCourseKey(_ raw: String) -> String? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.contains(where: { $0.isLetter || $0.isNumber }) else { return nil }
        let parsed = CourseCode.parse(trimmed).code
        guard parsed != Self.unknownCourse else { return nil }
        return parsed
    }

    /// Adds a class by hand. Returns the canonical key it was filed under, or
    /// nil when the input wasn't usable.
    ///
    /// Idempotent, and idempotent in the way that matters: adding a class the
    /// feed already supplies is not an error and does not create a second entry
    /// — it just marks the existing course as one the student also vouched for.
    /// A previously deleted class is un-deleted, since typing its name in again
    /// is a clearer statement of intent than the deletion it supersedes.
    @discardableResult
    func addCourse(_ raw: String) -> String? {
        guard let key = Self.normalizedCourseKey(raw) else { return nil }
        coursePreferences.update(key) {
            $0.isManuallyAdded = true
            $0.isDeleted = false
            $0.isVisible = true
            // Typing in a class is a statement about this term. If a rollover
            // had filed it away, bring it back rather than adding a class that
            // is invisible the moment it is created.
            $0.archivedTerm = nil
        }
        rebuildDashboardItems()
        return key
    }

    /// Undoes `addCourse`. Only clears the hand-added mark — a class the feed
    /// is also publishing stays in the list, because it is real regardless of
    /// who mentioned it first. Manual assignments already attached to it are
    /// untouched; they are ledger rows and deleting a label must not delete
    /// work.
    func removeAddedCourse(_ course: String) {
        coursePreferences.setManuallyAdded(course, false)
        rebuildDashboardItems()
    }

    /// Classes the student typed in themselves, sorted.
    func manuallyAddedCourseCodes() -> [String] {
        coursePreferences.manuallyAddedCourseKeys
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// False if the course is hidden OR deleted — both keep it out of the
    /// dashboard, notifications, and Grade Watcher (see `selectedCanvasCourseIDs`).
    func isCourseSelected(_ course: String) -> Bool {
        coursePreferences.isSelected(course)
    }

    /// Toggle a course on/off. Off = hidden from the dashboard and notifications.
    func setCourse(_ course: String, selected: Bool) {
        coursePreferences.setVisible(course, selected)
        rebuildDashboardItems()
    }

    /// Courses to render in the Profile classes list — every known course minus
    /// deleted ones and minus the ones a semester rollover took off the roster.
    /// (Hidden-but-not-deleted courses still appear here, toggled off.)
    ///
    /// Archived courses drop out of the *list* but keep `isCourseSelected`
    /// true, and the split is deliberate. Done reads
    /// `isCourseSelected` when deciding whose finished work to show, so
    /// folding archival into selection would empty last semester out of the
    /// student's own history — which is the thing archiving exists not to do.
    func visibleCourseCodes() -> [String] {
        allCourseCodes().filter {
            !coursePreferences.isDeleted($0) && !coursePreferences.isArchived($0)
        }
    }

    /// Classes a rollover has taken off the roster, sorted. The "you archived
    /// these" list.
    func archivedCourseCodes() -> [String] {
        allCourseCodes()
            .filter { coursePreferences.isArchived($0) }
            .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// Deleted courses, sorted for a stable "Deleted classes" restore list.
    func deletedCourseCodes() -> [String] {
        allCourseCodes().filter { coursePreferences.isDeleted($0) }
    }

    func isCourseDeleted(_ course: String) -> Bool {
        coursePreferences.isDeleted(course)
    }

    /// Removes a course from the classes list. Purely local — there's nothing
    /// to delete on Canvas's end — so it's fully reversible with `restoreCourse`.
    func deleteCourse(_ course: String) {
        coursePreferences.setDeleted(course, true)
        rebuildDashboardItems()
    }

    /// Undoes `deleteCourse`. The course reappears in the classes list at
    /// whatever hidden/shown state it had before deletion — deletion and hiding
    /// are separate fields on one record, so undoing one cannot disturb the
    /// other.
    func restoreCourse(_ course: String) {
        coursePreferences.setDeleted(course, false)
        rebuildDashboardItems()
    }

    /// Classes currently switched on, by code. Kept separate from
    /// `selectedCanvasCourseIDs` so callers can tell "nothing is selected" apart
    /// from "things are selected but have no Canvas id yet" — states that used to
    /// be indistinguishable and produced a misleading empty screen in Grades.
    func selectedCourseCodes() -> [String] {
        visibleCourseCodes().filter { isCourseSelected($0) }
    }

    // MARK: Course names

    /// What to show for a class: the user's own name if they set one, otherwise
    /// the code parsed from Canvas/Gradescope.
    func courseDisplayName(_ course: String) -> String {
        coursePreferences.displayName(for: course)
    }

    func hasCustomName(_ course: String) -> Bool {
        coursePreferences.hasCustomName(course)
    }

    /// Renames a class for display only — every other system (hiding, deletion,
    /// reminders, grades) still keys on `course`, so the rename survives a
    /// re-sync and can't orphan the class. Clearing the field restores the code.
    func renameCourse(_ course: String, to newName: String) {
        coursePreferences.setDisplayName(course, to: newName)
    }

    /// Remembers every course-code -> Canvas-id pair this sync revealed. Called
    /// from `rebuildDashboardItems` (i.e. when items change) rather than from the
    /// `canvasCourseIDs` read path, because that read happens inside SwiftUI body
    /// evaluation and must not publish changes. `mergeCanvasCourseIDs` keeps
    /// that guarantee: it publishes nothing when this sync revealed no new ids.
    private func updateCanvasCourseIDCache() {
        var resolved: [String: String] = [:]
        for item in canvasItems {
            guard item.course != Self.unknownCourse,
                  let url = item.url,
                  let id = Self.courseID(from: url)
            else { continue }
            resolved[item.course] = id
        }
        coursePreferences.mergeCanvasCourseIDs(resolved)
    }

    // MARK: Semester rollover

    /// Re-derives the archive read model from the ledger, and recomputes what
    /// the rollover card should offer.
    ///
    /// Called from `rebuildDashboardItems`, which is the same place the Canvas
    /// id cache is refreshed and for the same reason: it runs whenever the pool
    /// of known items changes, so a sync that brings in this term's first
    /// assignment is what surfaces the offer. Nothing is published unless a
    /// value actually changed — `rebuildDashboardItems` also runs on every
    /// completion toggle, and re-publishing an unchanged offer would redraw the
    /// dashboard for nothing.
    private func refreshArchiveState(now: Date = Date()) {
        guard let store = assignmentStore else { return }
        // One pass over the table for all three answers — see
        // `AssignmentStore.archiveState`. This runs on every completion toggle,
        // so asking three separate questions was three full scans per tick.
        let state = store.archiveState(now: now)
        if state.archivedIDs != archivedAssignmentIDs { archivedAssignmentIDs = state.archivedIDs }
        if state.terms != archivedTerms { archivedTerms = state.terms }

        let resolved = Self.visibleRolloverOffer(
            state.offer,
            dismissedTerm: rolloverDismissedTerm
        )
        if resolved != rolloverOffer { rolloverOffer = resolved }
    }

    /// Applies the student's "not now" to a freshly-detected offer.
    ///
    /// A dismissal is **suppressed rather than remembered forever**, and it is
    /// scoped to the boundary that produced it: waving away "archive Spring
    /// 2026" in August must not also wave away "archive Fall 2026" next
    /// January. When a later boundary comes around `currentTerm` has moved, the
    /// stored term no longer matches, and the card asks again.
    ///
    /// Pure and static so the scoping can be tested without a store, a clock or
    /// a `UserDefaults` domain — it is one comparison, and it is the difference
    /// between a card that respects a "no" and one that nags.
    static func visibleRolloverOffer(
        _ offer: SemesterRollover.Offer?,
        dismissedTerm: Term?
    ) -> SemesterRollover.Offer? {
        guard let offer, dismissedTerm != offer.currentTerm else { return nil }
        return offer
    }

    /// The term whose rollover offer the student most recently dismissed.
    private var rolloverDismissedTerm: Term? {
        UserDefaults.lhf.string(forKey: Self.rolloverDismissedTermKey).flatMap(Term.init(code:))
    }

    /// Files every item belonging to `terms` away, and takes their classes off
    /// the roster. Returns how many ledger rows were stamped.
    ///
    /// **Archiving is not deleting, and the two halves below are why.** The
    /// ledger stamp (`store.archive`) is what stops the work reaching the
    /// dashboard, `reschedule()` and the widget. The course stamp is what takes
    /// the class out of the class list. Neither removes a row, clears a
    /// completion, or touches a score — every archived item is still on disk,
    /// still in `mergedCoursework`, and still in Done. `unarchiveTerms` puts it
    /// all back.
    ///
    /// Only ever called from a control the student tapped, with the count in
    /// front of them.
    @discardableResult
    func archiveTerms(_ terms: Set<Term>, now: Date = Date()) -> Int {
        guard let store = assignmentStore, !terms.isEmpty else { return 0 }

        // Which classes belong to the terms being archived has to be read
        // *before* the rows are stamped: `rolloverOffer` skips archived rows, so
        // asking afterwards returns nothing and the classes would stay on the
        // roster with no items behind them.
        let coursesByTerm = store.rolloverOffer(now: now)?
            .candidates
            .filter { terms.contains($0.term) }
            ?? []

        // Hoisted out of the loop below: it walks every known item, and asking
        // it once per course made archiving quadratic in a student's timetable.
        let stillCurrent = currentTermCourseKeys(now: now)

        let stamped = store.archive(terms: terms, now: now)
        for candidate in coursesByTerm {
            for course in candidate.courseKeys {
                // A class that is also in the *current* term keeps its place.
                // A student retaking CIS 1200 has one course key spanning two
                // terms, and taking it off the roster because last spring was
                // archived would hide a class they are sitting in this week.
                guard !stillCurrent.contains(course) else { continue }
                coursePreferences.setArchivedTerm(course, candidate.term)
            }
        }
        refreshArchiveState(now: now)
        rebuildDashboardItems(now: now)
        return stamped
    }

    /// Course keys with at least one live (unarchived) item in the current term
    /// — the roster as the feed currently describes it.
    private func currentTermCourseKeys(now: Date = Date()) -> Set<String> {
        let current = Term(date: now)
        var keys = coursePreferences.manuallyAddedCourseKeys
        for item in canvasItems + gradescopeItems {
            guard !archivedAssignmentIDs.contains(item.id) else { continue }
            let term = item.term ?? item.dueAt.map { Term(date: $0) }
            if term == current { keys.insert(item.course) }
        }
        return keys
    }

    /// Puts archived terms back on the dashboard and their classes back on the
    /// roster. The way out of a rollover the student regrets.
    @discardableResult
    func unarchiveTerms(_ terms: Set<Term>, now: Date = Date()) -> Int {
        guard let store = assignmentStore, !terms.isEmpty else { return 0 }
        let cleared = store.unarchive(terms: terms, now: now)
        // Read straight off the preferences store rather than through
        // `archivedCourseCodes()`, which filters `allCourseCodes()` — a course
        // whose every item had left the known pool would not appear there, and
        // its archived stamp would then be unclearable by any route the UI
        // offers. The record is the thing being cleared, so the record is what
        // to enumerate.
        for course in coursePreferences.archivedCourseKeys where
            coursePreferences.archivedTerm(for: course).map(terms.contains) == true {
            coursePreferences.setArchivedTerm(course, nil)
        }
        // Clearing the dismissal too: a student who un-archives has changed
        // their mind about this boundary, and the card should be allowed to ask
        // again rather than staying silenced by a tap they've since reversed.
        UserDefaults.lhf.removeObject(forKey: Self.rolloverDismissedTermKey)
        refreshArchiveState(now: now)
        rebuildDashboardItems(now: now)
        return cleared
    }

    /// Dismisses the current rollover offer without archiving anything. Scoped
    /// to the term boundary that produced it, so the next one still asks.
    func dismissRolloverOffer(now: Date = Date()) {
        UserDefaults.lhf.set(Term(date: now).code, forKey: Self.rolloverDismissedTermKey)
        refreshArchiveState(now: now)
    }

    func addRecurringTask(_ task: RecurringTask) {
        recurringTasks.append(task)
        persistRecurringTasks()
        rebuildDashboardItems()
    }

    /// True when manual work is ledger-backed. False only where the ledger fell
    /// back to memory, in which case the UserDefaults blob is still the durable
    /// copy and has to keep being written.
    private var manualWorkIsLedgerBacked: Bool { assignmentStore?.isPersistent == true }

    func addManualAssignment(_ assignment: ManualAssignment) {
        manualAssignments.append(assignment)
        if let store = assignmentStore, manualWorkIsLedgerBacked {
            store.upsert([assignment.asAssignment()])
        } else {
            persistManualAssignments()
        }
        rebuildDashboardItems()
    }

    func removeManualAssignment(id: UUID) {
        let removed = manualAssignments.filter { $0.id == id }
        manualAssignments.removeAll { $0.id == id }
        if let store = assignmentStore, manualWorkIsLedgerBacked {
            // The user deleting their own item is the one case where removing a
            // row is what they actually meant.
            store.delete(ids: Set(removed.map { $0.asAssignment().id }))
        } else {
            persistManualAssignments()
        }
        rebuildDashboardItems()
    }

    func addCanvasSuggestion(_ suggestion: CanvasRequirementSuggestion) {
        addRecurringTask(RecurringTask(
            title: suggestion.title,
            course: suggestion.course,
            weekday: suggestion.weekday,
            hour: suggestion.hour,
            minute: suggestion.minute,
            startDate: Date(),
            endDate: nil,
            origin: RecurringTask.Origin(suggestion.source),
            evidence: suggestion.evidence
        ))
        canvasRequirementSuggestions.removeAll { $0.id == suggestion.id }
    }

    func dismissCanvasSuggestion(_ suggestion: CanvasRequirementSuggestion) {
        canvasRequirementSuggestions.removeAll { $0.id == suggestion.id }
    }

    /// How far ahead "this week" reaches.
    static let dashboardWindow: TimeInterval = 7 * 86_400

    /// Near bucket: overdue OR due within the dashboard window. Its complement
    /// (undated, or beyond the window) is "later" — together they cover the whole
    /// pool with no gap, so items overdue by more than a week still surface.
    static func isNearOrOverdue(_ assignment: Assignment, now: Date = Date()) -> Bool {
        guard let due = assignment.dueAt else { return false }
        return due <= now.addingTimeInterval(dashboardWindow)
    }

    /// An `.event`-kind item (a reading, a lecture, an exam date with nothing
    /// to submit) has no submission to be late on, so it never belongs in
    /// OVERDUE — the product rule is that it simply drops off the dashboard
    /// once its calendar day is over. Undated events are never expired, since
    /// there's no day to compare against.
    static func isExpiredEvent(_ assignment: Assignment, now: Date = Date()) -> Bool {
        guard assignment.kind == .event, let due = assignment.dueAt else { return false }
        let calendar = Calendar.current
        return calendar.startOfDay(for: due) < calendar.startOfDay(for: now)
    }

    /// Keeps the dashboard to the current term so next-term courses Canvas still
    /// lists as "active" can't leak in. When the item's term is known (parsed
    /// from the Canvas course code) we use it directly — exact, and immune to the
    /// fuzzy month→season boundary. Otherwise we fall back to a due-date cap that
    /// is never tighter than the dashboard window, so genuinely-soon items are
    /// safe at term boundaries. Undated and overdue items pass unless their term
    /// has been archived.
    ///
    /// ## The past bound, and why it is a set rather than a comparison
    ///
    /// This function used to read `term <= current`, which bounds only the
    /// future: every past term passed, so an entire prior semester stayed on the
    /// dashboard and kept feeding `reschedule()`. The obvious repair — demanding
    /// `term == current` — is wrong, and expensively so. `Term(date:)` maps
    /// August to fall, so on 23 August a summer course with an August deadline
    /// is a *past* term by that test, and a student still finishing it would
    /// watch their live work vanish with no way to ask for it back.
    ///
    /// So the past bound is `archivedTerms`: a term is excluded once the student
    /// has been shown a count and agreed to file it away, and not before.
    /// Detected and offered, never automatic — the same rule the rollover card
    /// is built on, enforced in the one filter that could otherwise quietly
    /// break it.
    ///
    /// The parameter defaults to empty, which is exactly the old behaviour: with
    /// nothing archived, a past term still passes. That is deliberate rather
    /// than convenient. The term cap is not the mechanism that hides last
    /// semester — the student's confirmed archive is, and this reads it.
    static func withinTermCap(
        _ assignment: Assignment,
        now: Date = Date(),
        archivedTerms: Set<Term> = []
    ) -> Bool {
        let current = Term(date: now)
        if let term = assignment.term {
            if archivedTerms.contains(term) { return false }   // archived past term
            return term <= current                             // future term → excluded
        }
        // An item with no term of its own still belongs to one. Dating it by its
        // due date is what stops an archived semester's leftovers coming back in
        // through the undated-and-overdue door — the specific clause that kept
        // showing a student work from a semester they had already put away.
        guard let due = assignment.dueAt else { return true }
        if archivedTerms.contains(Term(date: due)) { return false }
        let cap = max(current.endDate(), now.addingTimeInterval(dashboardWindow))
        return due <= cap
    }

    /// Stale leftovers — anything due more than 5 months ago — are hidden
    /// everywhere. Undated items are never "too old" since we can't date them.
    static func isTooOld(_ assignment: Assignment, now: Date = Date()) -> Bool {
        guard let due = assignment.dueAt,
              let cutoff = Calendar.current.date(byAdding: .month, value: -5, to: now)
        else { return false }
        return due < cutoff
    }

    static let unknownCourse = "(unknown course)"

    /// Quizzes, midterms, and exams live on their own Assessments page rather than
    /// mixed into coursework. Detected by Canvas's quiz classification or by title.
    static func isAssessment(_ assignment: Assignment) -> Bool {
        if assignment.kind == .quiz { return true }
        // Institution-wide calendar entries — holidays, "no class / no exams"
        // days — carry no course and no submission. Never promote them to
        // assessments even when the title mentions "exam"; this was what surfaced
        // "(unknown course) · Rosh Hashanah no exams" on the dashboard.
        guard assignment.course != Self.unknownCourse else { return false }
        let pattern = #"(?i)\b(midterms?|exams?|quiz|quizzes|prelims?|finals|final exam)\b"#
        return assignment.title.range(of: pattern, options: .regularExpression) != nil
    }

    /// Extra content beyond assignments/assessments that the user has
    /// specifically opted into for this course: a dated calendar event
    /// (reading, discussion prep, etc.) for a course whose
    /// READINGS_ON_CALENDAR/SILENT nudge was answered "include"
    /// (docs/READINGS_COURSES_PLAN.md). Default is exclude — no stored
    /// decision means these stay off the dashboard, so existing users see
    /// zero change until they opt in.
    private func includesAsOptedInContent(_ assignment: Assignment) -> Bool {
        assignment.kind == .event
            && assignment.course != Self.unknownCourse
            && courseContentDecisions[assignment.course]?.choice == .include
    }

    private func rebuildDashboardItems(now: Date = Date()) {
        updateCanvasCourseIDCache()
        refreshArchiveState(now: now)
        let recurringAssignments = recurringTasks.flatMap { $0.upcomingAssignments() }
        let manualItems = manualAssignments.map { $0.asAssignment() }
        // Canvas contributes graded assignments plus anything that reads as an
        // assessment (quizzes/exams), plus — for a course the user opted in via
        // a readings/silent-course nudge or Settings — its dated calendar
        // events (docs/READINGS_COURSES_PLAN.md), whether those events came in
        // on the ICS feed or were imported from a probed course's Modules page
        // (`moduleReadingItems`). Both are `.event`-kind, so
        // `includesAsOptedInContent` gates a module-imported reading exactly
        // the same way it gates a feed one — a course toggled OFF hides its
        // already-imported readings without deleting them from the ledger.
        // Gradescope items are already assignments.
        let canvasPool = canvasItems + moduleReadingItems
        let canvasRelevant = canvasPool.filter { $0.isAssignment || Self.isAssessment($0) || includesAsOptedInContent($0) }
        // Collapse anything a professor posted on BOTH Canvas and Gradescope
        // (same course, matching title/due date — see `AssignmentDeduplicator`)
        // into a single Canvas-anchored item before it ever reaches the
        // dashboard buckets below.
        // Pairings already on the ledger are honored before the live heuristic
        // re-runs, so a merge survives a professor moving one platform's due
        // date out of the heuristic's tolerance; this rebuild's pairings are
        // written back so the merge is durable from here on.
        let storedPairings = assignmentStore?.confirmedPairings() ?? []
        let pairings = AssignmentDeduplicator.matchPairs(
            canvasItems: canvasRelevant,
            gradescopeItems: gradescopeItems,
            confirmedPairings: storedPairings
        )
        assignmentStore?.recordPairings(pairings)
        // Passing the resolved pairings straight through means the heuristic
        // isn't run a second time inside `merge`.
        let dedupedCoursework = AssignmentDeduplicator.merge(
            canvasItems: canvasRelevant,
            gradescopeItems: gradescopeItems,
            confirmedPairings: pairings
        )
        mergedCoursework = dedupedCoursework
        let allItems = (dedupedCoursework + recurringAssignments + manualItems)
            .sorted(by: Self.byDueDate)

        // `mergedCoursework` is assigned above, *before* this filter, and that
        // ordering is what keeps archiving from being deletion: the Done tab
        // reads that pool, so a semester the student put away is still their own
        // history. Only the dashboard buckets below lose it — and, through them,
        // `reschedule()`, which is driven by exactly these arrays.
        let archivedTermSet = Set(archivedTerms)
        let incomplete = allItems.filter { item in
            !isCompleted(item)
                && !Self.isTooOld(item, now: now)
                && isCourseSelected(item.course)          // class picker
                // The per-row archive stamp. Authoritative, because it was
                // resolved against `firstSeen` at the moment the student
                // confirmed — evidence the value type below simply doesn't
                // carry.
                && !archivedAssignmentIDs.contains(item.id)
                // And the term-level bound, for items that never got a row:
                // recurring occurrences are generated fresh on every rebuild.
                && Self.withinTermCap(item, now: now, archivedTerms: archivedTermSet)
        }
        // `.event` items never land in Assessments even when their title
        // matches the exam/quiz regex (`isAssessment` is title-based, and a
        // readings-course opt-in can surface something titled e.g. "Reading
        // quiz prep") — they're opted-in content, always coursework.
        assessments = incomplete.filter { $0.kind != .event && Self.isAssessment($0) }

        // Near (overdue + this week) and later partition the coursework with no
        // gap, so nothing incomplete is silently dropped. An `.event` (reading,
        // lecture, exam date) has nothing to submit, so once its calendar day
        // has passed it isn't "overdue" — it's just gone from the dashboard.
        let coursework = incomplete
            .filter { $0.kind == .event || !Self.isAssessment($0) }
            .filter { !Self.isExpiredEvent($0, now: now) }
        assignments = coursework.filter { Self.isNearOrOverdue($0, now: now) }
        laterAssignments = coursework.filter { !Self.isNearOrOverdue($0, now: now) }
        publishWidgetSnapshot()
    }

    /// Publishes the "next due" snapshot to the shared App Group container and
    /// asks WidgetKit to refresh. The widget extension is a separate process
    /// that can't read AppState, so this file is the bridge. Cheap (a few items
    /// as JSON) and safe when the App Group isn't configured (the store no-ops).
    private func publishWidgetSnapshot() {
        let nextDue = (assignments + assessments + laterAssignments)
            .filter { $0.dueAt != nil }
            .sorted { ($0.dueAt ?? .distantFuture) < ($1.dueAt ?? .distantFuture) }
            .prefix(5)
            .map { WidgetItem(title: $0.title, course: $0.course, dueAt: $0.dueAt) }
        WidgetSnapshotStore.write(WidgetSnapshot(items: Array(nextDue), generatedAt: Date()))
        #if canImport(WidgetKit)
        WidgetCenter.shared.reloadAllTimelines()
        #endif
    }

    #if DEBUG
    /// Loads fake assignments (the preview fixtures) into the live store so the
    /// UI can be exercised without connecting a real Canvas account.
    func loadSampleData() {
        canvasItems = SampleData.items().map(\.assignment)
        completedAssignmentIDs = []
        completionDates = [:]
        rebuildDashboardItems()
    }
    #endif

    /// Marks `assignment` done. When it's a merged cross-platform item
    /// (`linkedID` set — see `AssignmentDeduplicator`), also marks its
    /// Gradescope counterpart done directly, so completion stays correct for
    /// both identities even if a later sync no longer matches the pair.
    func markCompleted(_ assignment: Assignment, at date: Date = Date()) {
        var touched: Set<String> = [assignment.id]
        if let linkedID = assignment.linkedID { touched.insert(linkedID) }

        guard let store = assignmentStore else {
            applyCompletionInMemory(touched, at: date)
            rebuildDashboardItems()
            return
        }
        // The ledger is where completion actually lives. Both the tapped item
        // and, for a merged cross-platform pair, its counterpart are passed as
        // prototypes: `touched` already contains the counterpart's id, but only
        // the tapped item is in hand, so without resolving the other out of the
        // pools it would get a blank completion-only row — a durable record of
        // a completion with no idea what was completed. This also covers work
        // no feed reconciles at all, a manual or recurring task, which would
        // otherwise be dropped for want of a row.
        store.setCompleted(ids: touched, at: date, prototypes: rowsNeededToComplete(assignment))
        reloadCompletionFromLedger()
        rebuildDashboardItems()
    }

    func markActive(_ assignment: Assignment) {
        var touched: Set<String> = [assignment.id]
        if let linkedID = assignment.linkedID { touched.insert(linkedID) }

        guard assignmentStore != nil else {
            // Same session-only degradation as `applyCompletionInMemory`: with
            // no store there is nowhere for the un-tick to be recorded either.
            completedAssignmentIDs.subtract(touched)
            for id in touched { completionDates[id] = nil }
            rebuildDashboardItems()
            return
        }
        assignmentStore?.setCompleted(ids: [], at: nil, clearing: touched)
        reloadCompletionFromLedger()
        rebuildDashboardItems()
    }

    /// The item plus its cross-platform counterpart.
    ///
    /// Completing a merged item marks both ids, but only the item the user
    /// tapped is in hand — the counterpart is just a `linkedID`. Where the pools
    /// came from a sync both already have rows and this changes nothing. Where
    /// they didn't — preview mode and sample data assign `canvasItems` /
    /// `gradescopeItems` directly, and preview mode is the path App Store
    /// reviewers use because they can't pass Penn SSO — the counterpart has no
    /// row, and half the merge comes back undone on the next launch.
    private func rowsNeededToComplete(_ assignment: Assignment) -> [Assignment] {
        guard let linkedID = assignment.linkedID else { return [assignment] }
        let counterpart = (gradescopeItems + canvasItems).first { $0.id == linkedID }
        return [assignment] + (counterpart.map { [$0] } ?? [])
    }

    /// The no-ledger fallback path — reachable only when even an in-memory store
    /// could not be created, where the app degrades to its pre-ledger behaviour
    /// and completion is session-only. Nothing persists here because there is
    /// nowhere left to persist to; `AssignmentStore.makeDefault()` records why
    /// in `storageFailureReason`, and Settings says so out loud rather than
    /// letting it look like it worked.
    private func applyCompletionInMemory(_ ids: Set<String>, at date: Date) {
        completedAssignmentIDs.formUnion(ids)
        for id in ids { completionDates[id] = date }
    }

    /// Re-derives the completion read models from the ledger.
    ///
    /// The mutators above update the published sets optimistically first, then
    /// call this: with a store, the ledger's answer replaces the optimistic one
    /// so the two can never drift; without one (store creation failed — see
    /// `assignmentStore`), the optimistic values stand and completion is
    /// session-only, which is the same degradation the rest of the ledger has.
    private func reloadCompletionFromLedger() {
        guard let record = assignmentStore?.completionRecord() else { return }
        completedAssignmentIDs = record.ids
        completionDates = record.dates
    }



    /// True if EITHER platform reports this done: this item's own submitted
    /// flag/manual completion, its cross-platform counterpart's manual
    /// completion (`linkedID` — e.g. the user completed the Gradescope copy
    /// before the two were ever merged), or Canvas's own submission
    /// side-channel (`submittedCanvasAssignmentIDs`).
    func isCompleted(_ assignment: Assignment) -> Bool {
        if assignment.submitted || completedAssignmentIDs.contains(assignment.id) { return true }
        if let linkedID = assignment.linkedID, completedAssignmentIDs.contains(linkedID) { return true }
        if let canvasID = assignment.canvasAssignmentID,
           submittedCanvasAssignmentIDs.contains(canvasID) {
            return true
        }
        return false
    }

    /// Recomputes `submittedCanvasAssignmentIDs` from the Grade Watcher snapshots'
    /// submission side-channel and rebuilds the dashboard. Called after any grade
    /// refresh. Reads every fetched course's submissions (Grade Watcher only
    /// fetches selected courses, which is exactly the set the dashboard shows).
    func updateSubmissionState() {
        // Captured before the merge below so "Turned in ✓" notifications can
        // diff against what was true a moment ago, not what's about to be true.
        let previousSubmittedIDs = submittedCanvasAssignmentIDs

        var ids: Set<String> = []
        for snapshot in gradeWatcher.snapshots.values {
            for submission in snapshot.submissions where submission.indicatesSubmitted {
                ids.insert(submission.assignmentID)
            }
        }
        // Assignments Canvas expects nothing online for (e.g. "attend the
        // review session") can't ever go "late" the normal way — once their
        // deadline passes they belong with finished work, not in the overdue
        // pile. Folded into `ids` alongside real submissions so both the
        // in-memory set below and the ledger persist below see the same
        // truth, which is what lets a deadline the professor later moves
        // into the future fall back out on the next refresh (replace
        // semantics on `applySubmissionState`, not an additive flag).
        let autoSubmitted = Self.autoSubmittedNoSubmissionIDs(
            snapshots: Array(gradeWatcher.snapshots.values),
            now: Date()
        )
        ids.formUnion(autoSubmitted)
        // Merge rather than replace: the ledger may know about work turned in
        // for a course that isn't in this refresh (deselected, or a fetch that
        // failed mid-loop), and dropping it would bounce finished items back
        // onto the dashboard.
        submittedCanvasAssignmentIDs = ids.union(persistedSubmittedIDsForUnfetchedCourses())

        // "Turned in ✓" confirmations for whatever just newly appeared as
        // submitted. Skipped entirely under fixture/demo data (reviewer
        // preview, DEBUG screenshot seam) — nothing was actually turned in
        // there, so a stray id would just be noise. Also excludes
        // `autoSubmitted`: nothing was turned in for those either — the
        // deadline just passed on work Canvas never expected online — so a
        // "Turned in ✓" notice would be noise at best and alarming at worst.
        if !isUsingFixtureData {
            let newlySubmitted = submittedCanvasAssignmentIDs
                .subtracting(previousSubmittedIDs)
                .subtracting(autoSubmitted)
            let notifications = Self.submissionNotifications(
                newIDs: newlySubmitted,
                previous: previousSubmittedIDs,
                items: canvasItems
            )
            if !notifications.isEmpty {
                pendingTurnedInNotices += notifications
            }
        }

        // Persist onto the ledger so the next cold launch already knows what's
        // turned in — and, more importantly, so a launch with a lapsed Canvas
        // session still does. Only write when a refresh actually produced
        // snapshots; an empty run (no session, nothing selected) must not be
        // read as "nothing is submitted any more" and wipe the persisted truth.
        if !gradeWatcher.snapshots.isEmpty {
            var scores: [String: (earned: Double?, max: Double?)] = [:]
            for snapshot in gradeWatcher.snapshots.values {
                for category in snapshot.categories {
                    for item in category.items {
                        scores[item.id] = (earned: item.score, max: item.pointsPossible)
                    }
                }
            }
            let changes = assignmentStore?.applySubmissionState(
                // The *union*, not the bare fetch. `applySubmissionState` is a
                // full replace by design (so a retraction self-heals), which
                // means handing it only this refresh's ids writes
                // `canvasSubmitted = false` onto every course the refresh
                // didn't cover. The session looks fine — `submittedCanvasAssignmentIDs`
                // above is the union — but the ledger is already wrong, and the
                // next cold launch seeds from the ledger and bounces finished
                // work back onto the dashboard for good.
                submittedCanvasAssignmentIDs: submittedCanvasAssignmentIDs,
                scores: scores,
                // Passing the union above fixes the flags but would corrupt the
                // timestamps if left alone: the ids for courses this refresh
                // never reached come from the ledger, and stamping them
                // "observed now" would relabel last Tuesday's answer as today's.
                // That is the precise lie `hasFreshSubmissionState` exists to
                // catch, so the store is told which ids Canvas genuinely spoke
                // for and dates only those.
                observedCanvasAssignmentIDs: refreshedCanvasAssignmentIDs()
            ) ?? []
            pendingGradeChanges = notifiableGradeChanges(changes)
        }
        rebuildDashboardItems()
    }

    /// Canvas assignment ids that should read as submitted purely because their
    /// deadline has passed and Canvas expects nothing to be submitted for them
    /// (per the owner's rule: an "attend the session" assignment can't be late,
    /// and once its moment has passed it belongs with finished work). Pure so
    /// it can be tested without a network or a GradeWatcherStore. No end-of-day
    /// rounding — assignments carry real deadlines, unlike the calendar
    /// readings handled elsewhere.
    static func autoSubmittedNoSubmissionIDs(
        snapshots: [CourseGradeSnapshot],
        now: Date
    ) -> Set<String> {
        var ids: Set<String> = []
        for snapshot in snapshots {
            for category in snapshot.categories {
                for item in category.items {
                    guard item.requiresNoSubmission, let dueAt = item.dueAt, dueAt < now else { continue }
                    ids.insert(item.id)
                }
            }
        }
        return ids
    }

    /// Pure planning for "Turned in ✓" notifications — mirrors
    /// `NotificationScheduler`'s documented "Planning (pure)" pattern so the
    /// decision logic (what counts as new, what gets skipped, how the body
    /// reads) is unit-testable without touching `UNUserNotificationCenter`.
    /// Not itself gated on `isUsingFixtureData`; the caller
    /// (`updateSubmissionState`) skips invoking this at all for fixture/demo
    /// data.
    static func submissionNotifications(
        newIDs: Set<String>,
        previous: Set<String>,
        items: [Assignment]
    ) -> [(title: String, body: String)] {
        // Cold-start baseline: the first time `submittedCanvasAssignmentIDs`
        // is ever populated (first launch, or the very first Grade Watcher
        // run) there is nothing real to diff against. Treating an empty
        // `previous` as "nothing was submitted before" would read a whole
        // mid-semester backlog of already-turned-in work as newly submitted,
        // and fire a notification for every one of them. Stay silent until
        // there's an actual prior refresh to compare against.
        guard !previous.isEmpty else { return [] }

        // A single pass surfacing more than a handful of "new" submissions is
        // a sync artifact — a deselected/reselected course, a session that
        // just recovered from a lapse, a ledger merge — not five simultaneous
        // real submissions. Skip silently: no log, because this is expected
        // and logging it would just be noise on every one of those paths.
        guard newIDs.count <= 5 else { return [] }

        return newIDs.map { id in
            guard let item = items.first(where: { $0.canvasAssignmentID == id }) else {
                // The id came from the grades feed but isn't (yet, or ever)
                // among the calendar-feed items we hold titles for.
                return (title: "Turned in ✓", body: "An assignment was turned in.")
            }
            let body = item.course.isEmpty ? item.title : "\(item.title) — \(item.course)"
            return (title: "Turned in ✓", body: body)
        }
    }

    /// Grade changes worth telling the user about, and the baseline bookkeeping
    /// that makes that possible.
    ///
    /// The first time a course's grades are ever fetched, every scored item
    /// transitions from "no score on the ledger" to "scored" at once — a whole
    /// semester of homework. Announcing that would mean a wall of notifications
    /// the moment someone connects Canvas. So the first sync for a course only
    /// *records* the baseline and stays silent; from then on a change is real
    /// news.
    private func notifiableGradeChanges(
        _ changes: [AssignmentStore.ScoreChange]
    ) -> [AssignmentStore.ScoreChange] {
        guard !changes.isEmpty else { return [] }
        var baselined = gradeBaselinedCourses
        let notifiable = changes.filter { baselined.contains($0.course) }
        let seen = Set(changes.map(\.course))
        if !seen.isSubset(of: baselined) {
            baselined.formUnion(seen)
            gradeBaselinedCourses = baselined
            UserDefaults.lhf.set(Array(baselined).sorted(), forKey: Self.gradeBaselinedCoursesKey)
        }
        return notifiable
    }

    /// Every Canvas assignment id this refresh actually got an answer about.
    ///
    /// This is the boundary between what the app *learned* just now and what it
    /// is merely still carrying from last time, and two separate things need to
    /// agree on where that boundary is: which persisted submissions survive a
    /// partial refresh, and which rows are entitled to a fresh observation
    /// timestamp. Deriving it once means they cannot drift apart.
    private func refreshedCanvasAssignmentIDs() -> Set<String> {
        Set(
            gradeWatcher.snapshots.values
                .flatMap(\.categories)
                .flatMap(\.items)
                .map(\.id)
        )
    }

    /// Persisted submissions belonging to courses this refresh didn't cover, so
    /// a partial or deselected refresh can't un-submit them in memory.
    private func persistedSubmittedIDsForUnfetchedCourses() -> Set<String> {
        guard let store = assignmentStore else { return [] }
        guard !gradeWatcher.snapshots.isEmpty else { return store.submittedCanvasAssignmentIDs() }

        // Anything this refresh actually saw is authoritative (including a
        // now-retracted submission, which must be allowed to clear). Everything
        // else keeps whatever the ledger last recorded.
        return store.submittedCanvasAssignmentIDs()
            .subtracting(refreshedCanvasAssignmentIDs())
    }

    /// When this item was marked done, if known. Items completed before the app
    /// tracked timestamps return nil — callers fall back to the due date.
    func completedAt(_ assignment: Assignment) -> Date? {
        completionDates[assignment.id]
    }

    private func persistRecurringTasks() {
        guard let data = try? JSONEncoder().encode(recurringTasks) else { return }
        UserDefaults.lhf.set(data, forKey: Self.recurringTasksKey)
    }

    private static func loadRecurringTasks() -> [RecurringTask] {
        guard let data = UserDefaults.lhf.data(forKey: recurringTasksKey),
              let tasks = try? JSONDecoder().decode([RecurringTask].self, from: data)
        else { return [] }
        return tasks
    }

    private func persistManualAssignments() {
        guard let data = try? JSONEncoder().encode(manualAssignments) else { return }
        UserDefaults.lhf.set(data, forKey: Self.manualAssignmentsKey)
    }

    private static func loadManualAssignments() -> [ManualAssignment] {
        guard let data = UserDefaults.lhf.data(forKey: manualAssignmentsKey),
              let items = try? JSONDecoder().decode([ManualAssignment].self, from: data)
        else { return [] }
        return items
    }

    /// Canvas course id -> course code. Built from this sync's items **folded
    /// over** everything resolved on earlier syncs, because a course id only
    /// ever reaches us attached to an ICS item's URL: a class with nothing due
    /// right now, or whose entries carry a calendar-style URL, contributes no id
    /// this time round and would otherwise silently drop out of Grade Watcher.
    /// Pure read — the cache is written by `updateCanvasCourseIDCache`.
    private func canvasCourseIDs() -> [String: String] {
        // Preview mode's sample assignments carry no Canvas URLs, so nothing
        // ever resolved a course id and Grade Watcher showed "Can't reach
        // Canvas for your classes" — the demo's most visible dead end. Serve
        // the fixture ids instead, in memory only: writing them into
        // `canvasCourseIDsByCode` would outlive the demo and later point a
        // real refresh at course ids that don't exist.
        if isUsingFixtureData { return SampleData.previewCourseIDsByID }

        var byCode = canvasCourseIDsByCode
        for item in canvasItems {
            guard item.course != Self.unknownCourse,
                  let url = item.url,
                  let id = Self.courseID(from: url)
            else { continue }
            byCode[item.course] = id
        }
        // Invert to id -> code. Two codes can theoretically point at one id
        // (a cross-listed section); keep the first rather than trapping.
        return Dictionary(byCode.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
    }

    /// Canvas course id -> display name, filtered to the class-picker's
    /// selected set. Drives Grade Watcher (docs/grades.md Decision 4) so a
    /// hidden course is never fetched.
    func selectedCanvasCourseIDs() -> [String: String] {
        canvasCourseIDs().filter { isCourseSelected($0.value) }
    }

    /// Pulls a Canvas course id out of an ICS item's URL. Canvas emits two
    /// shapes: a direct `/courses/<id>/assignments/<id>` link, and — for items
    /// surfaced through the calendar rather than the course — a
    /// `/calendar?include_contexts=course_<id>` link. Only the first was handled
    /// before, so a feed of the second kind resolved no courses at all and Grade
    /// Watcher reported that nothing was selected.
    static func courseID(from url: URL) -> String? {
        let parts = url.pathComponents
        if let index = parts.firstIndex(of: "courses"),
           parts.indices.contains(parts.index(after: index)) {
            let candidate = parts[parts.index(after: index)]
            if !candidate.isEmpty, candidate.allSatisfy(\.isNumber) { return candidate }
        }

        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let contexts = components.queryItems?
                .first(where: { $0.name == "include_contexts" })?.value
        else { return nil }

        for context in contexts.split(separator: ",") where context.hasPrefix("course_") {
            let id = context.dropFirst("course_".count)
            if !id.isEmpty, id.allSatisfy(\.isNumber) { return String(id) }
        }
        return nil
    }

    private static func byDueDate(_ a: Assignment, _ b: Assignment) -> Bool {
        switch (a.dueAt, b.dueAt) {
        case let (lhs?, rhs?): return lhs < rhs
        case (nil, _):         return false   // nil dates sort to the end
        case (_, nil):         return true
        }
    }
}
