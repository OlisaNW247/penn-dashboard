import Foundation
import SwiftUI
import WebKit
import LowHangingFruitKit
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
        case .light: return "Light"
        case .dark:  return "Dark"
        }
    }

    var colorScheme: ColorScheme {
        switch self {
        case .light: return .light
        case .dark:  return .dark
        }
    }
}

@MainActor
final class AppState: ObservableObject {
    @Published var canvasItems: [Assignment] = []
    @Published var gradescopeItems: [Assignment] = []
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
    /// Completed work, as a published PROJECTION of the ledger — not a second
    /// copy of the truth. `AssignmentStore.completionRecord()` is authoritative;
    /// `refreshCompletionFromLedger()` is the only thing that writes these.
    ///
    /// They used to be persisted independently in UserDefaults *and* mirrored
    /// onto the ledger, with nothing reconciling the two on read. A divergence
    /// meant the Done tab and the ledger's aging exemption disagreed about what
    /// was finished — and the aging exemption is what keeps finished work from
    /// being deleted.
    @Published private(set) var completedAssignmentIDs: Set<String>
    /// When each completed item was marked done, so the Done tab keeps its
    /// history. Items completed before timestamps were tracked have no entry;
    /// the Done view falls back to the due date to place them.
    @Published private(set) var completionDates: [String: Date]

    /// Canvas assignment ids the grades fetch reports as submitted (see
    /// `AssignmentSubmissionInfo.indicatesSubmitted`). DERIVED state, recomputed
    /// from grade snapshots on every refresh and NOT persisted — so a Canvas
    /// correction (a retracted submission) self-heals on the next sync instead of
    /// sticking. Consulted by `isCompleted` to auto-file submitted work under Done.
    @Published private(set) var submittedCanvasAssignmentIDs: Set<String> = []

    /// Grade changes detected by the last refresh and not yet announced. The
    /// view layer drains this (it owns the `NotificationScheduler`), so the
    /// store stays free of notification plumbing.
    @Published var pendingGradeChanges: [AssignmentStore.ScoreChange] = []

    /// Courses whose grades have been fetched at least once, so the very first
    /// fetch can establish a baseline silently instead of announcing a whole
    /// term of existing scores. See `notifiableGradeChanges`.
    private var gradeBaselinedCourses: Set<String> = []
    /// Courses the user has switched OFF (no dashboard items, no notifications).
    /// Stored as the *hidden* set so the default — empty — means every course is
    /// shown, and any newly-discovered course shows up automatically.
    @Published private(set) var hiddenCourseKeys: Set<String>
    /// Courses the user deleted from the classes list. Deletion is a superset of
    /// hiding: a deleted course is excluded everywhere a hidden course is
    /// (dashboard, notifications, Grade Watcher) AND is also removed from the
    /// classes list itself — unlike a merely-hidden course, which still shows
    /// there with its toggle off. There's no server-side course to delete (it's
    /// synced from Canvas), so this is purely a local filter the user can undo.
    @Published private(set) var deletedCourseKeys: Set<String>
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
    /// User-chosen display names, keyed by the canonical course code the rest of
    /// the app identifies a class by. Renaming is deliberately cosmetic: hiding,
    /// deletion, notifications and grades all still key on the code, so a
    /// renamed class keeps working and a re-sync can't undo the rename.
    @Published private(set) var courseNameOverrides: [String: String]
    /// Course code -> Canvas numeric course id, remembered once resolved. Ids
    /// only ever arrive attached to an ICS item's URL, so a course whose current
    /// feed entries carry no usable URL would otherwise be invisible to Grade
    /// Watcher even while selected. Caching keeps a selected class fetchable.
    @Published private(set) var canvasCourseIDsByCode: [String: String]

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

    private static let userNameKey = "userName"
    private static let completedIDsKey = "completedAssignmentIDs"
    private static let completionDatesKey = "completionDates"
    private static let hiddenCoursesKey = "hiddenCourseKeys"
    private static let deletedCoursesKey = "deletedCourseKeys"
    private static let recurringTasksKey = "recurringTasks"
    private static let manualAssignmentsKey = "manualAssignments"
    private static let canvasDiscoveryConnectedKey = "canvasDiscoveryConnected"
    private static let gradescopeConnectedKey = "gradescopeConnected"
    private static let onboardingCompletedKey = "hasCompletedOnboarding"
    private static let introSeenKey = "hasSeenIntro"
    private static let previewModeKey = "isPreviewMode"
    private static let appearanceModeKey = "appearanceMode"
    private static let courseNameOverridesKey = "courseNameOverrides"
    private static let canvasCourseIDsByCodeKey = "canvasCourseIDsByCode"
    private static let gradeBaselinedCoursesKey = "gradeBaselinedCourses"
    private static let enrolledCanvasCoursesKey = "enrolledCanvasCoursesV1"

    /// `assignmentStore` is injectable so tests can supply a specific in-memory
    /// or temp-file store (and drive it across simulated launches). The default
    /// nil resolves to `AssignmentStore.makeDefault()` — persistent in the real
    /// app, fresh in-memory in unit tests.
    init(
        assignmentStore: AssignmentStore? = nil,
        gradeHistoryStore: GradeHistoryStore? = nil
    ) {
        // Keychain-backed (docs/CANVAS_LOGIN_HARDENING.md item 3c) — the feed
        // URL is itself a bearer credential. `ICSFeedURLStore.load()`
        // transparently migrates a pre-existing UserDefaults value in.
        self.canvasICSURL = ICSFeedURLStore.load()
        self.hiddenCourseKeys = Set(UserDefaults.lhf.stringArray(forKey: Self.hiddenCoursesKey) ?? [])
        self.deletedCourseKeys = Set(UserDefaults.lhf.stringArray(forKey: Self.deletedCoursesKey) ?? [])
        self.isCanvasDiscoveryConnected = UserDefaults.lhf.bool(forKey: Self.canvasDiscoveryConnectedKey)
        self.isGradescopeConnected = UserDefaults.lhf.bool(forKey: Self.gradescopeConnectedKey)
        self.hasCompletedOnboarding = UserDefaults.lhf.bool(forKey: Self.onboardingCompletedKey)
        self.hasSeenIntro = UserDefaults.lhf.bool(forKey: Self.introSeenKey)
        self.isPreviewMode = UserDefaults.lhf.bool(forKey: Self.previewModeKey)
        self.userName = UserDefaults.lhf.string(forKey: Self.userNameKey) ?? ""
        self.appearanceMode = AppearanceMode(
            rawValue: UserDefaults.lhf.string(forKey: Self.appearanceModeKey) ?? ""
        ) ?? .light
        self.courseNameOverrides = Self.loadStringMap(Self.courseNameOverridesKey)
        self.canvasCourseIDsByCode = Self.loadStringMap(Self.canvasCourseIDsByCodeKey)
        self.gradeBaselinedCourses = Set(
            UserDefaults.lhf.stringArray(forKey: Self.gradeBaselinedCoursesKey) ?? []
        )
        self.courseContentDecisions = CourseContentDecisionStore.load()
        self.enrolledCanvasCourses = Self.loadStringMap(Self.enrolledCanvasCoursesKey)
            .map { CanvasCourseDiscoveryParser.Course(id: $0.key, name: $0.value) }
        self.recurringTasks = Self.loadRecurringTasks()
        self.manualAssignments = Self.loadManualAssignments()

        // Seed the in-memory pools from the durable ledger so the class list and
        // dashboard are populated on the very first frame — before any network
        // sync returns — instead of starting empty every launch.
        let store = assignmentStore ?? AssignmentStore.makeDefault()
        self.assignmentStore = store
        let historyStore = gradeHistoryStore ?? GradeHistoryStore.makeDefault()
        self.gradeHistoryStore = historyStore

        // Move completion state and observed grade history off the old
        // UserDefaults blobs and onto the ledger, before anything reads either.
        // One-time (version-gated) and idempotent — see `LegacyStateMigration`.
        LegacyStateMigration.runIfNeeded(
            assignmentStore: store,
            gradeHistoryStore: historyStore
        )
        // Constructed after the migration so its history cache is built from the
        // migrated rows rather than an empty store.
        self.gradeWatcher = GradeWatcherStore(historyStore: historyStore)

        // Degraded no-ledger path: if the SwiftData store couldn't be created,
        // there's no ledger to seed completion from, so it starts empty rather
        // than leaving these stored properties uninitialized on this path.
        self.completedAssignmentIDs = []
        self.completionDates = [:]

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

    /// Recomputes `canvasSessionExpired` from `SessionCookieStore`'s current
    /// Keychain state. Call after anything that could change it: connecting,
    /// disconnecting, or a periodic dashboard refresh.
    func refreshCanvasSessionExpiredState() {
        canvasSessionExpired = SessionCookieStore.isExpired(service: .canvas)
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
        canvasCourseIDsByCode = [:]
        UserDefaults.lhf.removeObject(forKey: Self.canvasCourseIDsByCodeKey)
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
        pendingCourseNudge = nil
        submittedCanvasAssignmentIDs = []
        gradeWatcher.clearAll()
        // Drop the durable ledger's Canvas rows too, or a disconnected
        // account's work survives in the store and reappears on the dashboard.
        assignmentStore?.purge(source: .canvas)
        refreshCompletionFromLedger()
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
        refreshCompletionFromLedger()
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
            let fetched = try await client.fetchCalendarItems().sorted(by: Self.byDueDate)
            // Reconcile into the durable ledger rather than replacing the pool:
            // items that dropped out of the rolling feed are retained, and a
            // suspiciously empty fetch is refused so one blip can't wipe the list.
            if let store = assignmentStore {
                let result = store.reconcile(fetched, source: .canvas)
                canvasItems = result.items.sorted(by: Self.byDueDate)
                if result.wasSuspectedPartial {
                    syncNotice = "Couldn't fully refresh Canvas just now — showing your saved assignments."
                }
                // Rows this reconcile just created may be the ones a carried-over
                // completion has been waiting for.
                refreshCompletionFromLedger()
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
                refreshCompletionFromLedger()
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
        let enrolled = await client.discoverEnrolledCourses()
            .filter { Self.isEnrolledCourseCurrent($0) }
        if !enrolled.isEmpty {
            enrolledCanvasCourses = enrolled
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
            // A thrown fetch (expired session, HTTP error) leaves NO probe
            // entry — that's what keeps `.unknownSilent` honest instead of
            // quietly reporting "probed, found nothing" for a course LHF
            // never actually looked at this launch.
            guard let items = try? await client.fetchModulesReadings(courseID: course.id) else { continue }
            courseProbes[course.id] = CourseProbeResult(submittableAssignmentCount: nil, moduleReadingCount: items.count)
        }

        recomputeCourseProfiles()
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
        var byCode = canvasCourseIDsByCode
        for course in enrolledCanvasCourses {
            let key = Self.courseKey(forEnrolled: course)
            // Skip only the degenerate case: an unparseable AND empty raw
            // name, which would otherwise insert a useless "" key.
            guard !key.isEmpty, byCode[key] == nil else { continue }
            byCode[key] = course.id
        }
        guard byCode != canvasCourseIDsByCode else { return }
        canvasCourseIDsByCode = byCode
        UserDefaults.lhf.set(byCode, forKey: Self.canvasCourseIDsByCodeKey)
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

        var byCode = canvasCourseIDsByCode
        let staleKeys = byCode.keys.filter { key in
            !currentEnrolledKeys.contains(key)
                && !feedCourseKeys.contains(key)
                && !gradescopeCourseKeys.contains(key)
        }
        guard !staleKeys.isEmpty else { return }

        for key in staleKeys { byCode.removeValue(forKey: key) }
        canvasCourseIDsByCode = byCode
        UserDefaults.lhf.set(byCode, forKey: Self.canvasCourseIDsByCodeKey)
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
        courseProfileReports = CourseProfileEngine.reports(
            feedItems: canvasItems,
            enrolledCourses: enrolledCanvasCourses,
            probes: courseProbes
        )
        queueNudgeIfNeeded()
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
    }

    private func setCourseContentDecision(courseKey: String, choice: CourseContentDecision.Choice, fingerprint: String) {
        courseContentDecisions[courseKey] = CourseContentDecision(
            choice: choice,
            fingerprint: fingerprint,
            decidedAt: Date()
        )
        CourseContentDecisionStore.save(courseContentDecisions)
    }

    /// Courses worth surfacing in Settings' "Courses & content" management
    /// section: every course with a manageable profile (see `isManageable`),
    /// decided or not.
    var courseContentManageableCourses: [CourseProfileReport] {
        courseProfileReports
            .filter(Self.isManageable)
            .sorted { $0.courseKey.localizedStandardCompare($1.courseKey) == .orderedAscending }
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

    /// Every distinct course currently seen across the connected sources, sorted
    /// for a stable picker order. Drives the onboarding + settings class list.
    func allCourseCodes() -> [String] {
        let pool = canvasItems + gradescopeItems
        let codes = Set(pool.map(\.course)).subtracting([Self.unknownCourse])
        return codes.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// False if the course is hidden OR deleted — both keep it out of the
    /// dashboard, notifications, and Grade Watcher (see `selectedCanvasCourseIDs`).
    func isCourseSelected(_ course: String) -> Bool {
        !hiddenCourseKeys.contains(course) && !deletedCourseKeys.contains(course)
    }

    /// Toggle a course on/off. Off = hidden from the dashboard and notifications.
    func setCourse(_ course: String, selected: Bool) {
        if selected { hiddenCourseKeys.remove(course) }
        else { hiddenCourseKeys.insert(course) }
        persistHiddenCourses()
        rebuildDashboardItems()
    }

    private func persistHiddenCourses() {
        UserDefaults.lhf.set(hiddenCourseKeys.sorted(), forKey: Self.hiddenCoursesKey)
    }

    /// Courses to render in the Settings classes list — every known course
    /// minus deleted ones. (Hidden-but-not-deleted courses still appear here,
    /// toggled off.)
    func visibleCourseCodes() -> [String] {
        allCourseCodes().filter { !deletedCourseKeys.contains($0) }
    }

    /// Deleted courses, sorted for a stable "Deleted classes" restore list.
    func deletedCourseCodes() -> [String] {
        allCourseCodes().filter { deletedCourseKeys.contains($0) }
    }

    func isCourseDeleted(_ course: String) -> Bool {
        deletedCourseKeys.contains(course)
    }

    /// Removes a course from the classes list. Purely local — there's nothing
    /// to delete on Canvas's end — so it's fully reversible with `restoreCourse`.
    func deleteCourse(_ course: String) {
        deletedCourseKeys.insert(course)
        persistDeletedCourses()
        rebuildDashboardItems()
    }

    /// Undoes `deleteCourse`. The course reappears in the classes list at
    /// whatever hidden/shown state it had before deletion.
    func restoreCourse(_ course: String) {
        deletedCourseKeys.remove(course)
        persistDeletedCourses()
        rebuildDashboardItems()
    }

    private func persistDeletedCourses() {
        UserDefaults.lhf.set(deletedCourseKeys.sorted(), forKey: Self.deletedCoursesKey)
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
        guard let custom = courseNameOverrides[course]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !custom.isEmpty
        else { return course }
        return custom
    }

    func hasCustomName(_ course: String) -> Bool {
        courseNameOverrides[course] != nil
    }

    /// Renames a class for display only — every other system (hiding, deletion,
    /// reminders, grades) still keys on `course`, so the rename survives a
    /// re-sync and can't orphan the class. Clearing the field restores the code.
    func renameCourse(_ course: String, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty || trimmed == course {
            courseNameOverrides.removeValue(forKey: course)
        } else {
            courseNameOverrides[course] = trimmed
        }
        UserDefaults.lhf.set(courseNameOverrides, forKey: Self.courseNameOverridesKey)
    }

    /// Remembers every course-code -> Canvas-id pair this sync revealed. Called
    /// from `rebuildDashboardItems` (i.e. when items change) rather than from the
    /// `canvasCourseIDs` read path, because that read happens inside SwiftUI body
    /// evaluation and must not publish changes.
    private func updateCanvasCourseIDCache() {
        var byCode = canvasCourseIDsByCode
        for item in canvasItems {
            guard item.course != Self.unknownCourse,
                  let url = item.url,
                  let id = Self.courseID(from: url)
            else { continue }
            byCode[item.course] = id
        }
        guard byCode != canvasCourseIDsByCode else { return }
        canvasCourseIDsByCode = byCode
        UserDefaults.lhf.set(byCode, forKey: Self.canvasCourseIDsByCodeKey)
    }

    private static func loadStringMap(_ key: String) -> [String: String] {
        UserDefaults.lhf.dictionary(forKey: key) as? [String: String] ?? [:]
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

    /// Keeps the dashboard to the current term so next-term courses Canvas still
    /// lists as "active" can't leak in. When the item's term is known (parsed
    /// from the Canvas course code) we use it directly — exact, and immune to the
    /// fuzzy month→season boundary. Otherwise we fall back to a due-date cap that
    /// is never tighter than the dashboard window, so genuinely-soon items are
    /// safe at term boundaries. Undated and overdue items always pass.
    static func withinTermCap(_ assignment: Assignment, now: Date = Date()) -> Bool {
        let current = Term(date: now)
        if let term = assignment.term { return term <= current }   // future term → excluded
        guard let due = assignment.dueAt else { return true }
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
        let recurringAssignments = recurringTasks.flatMap { $0.upcomingAssignments() }
        let manualItems = manualAssignments.map { $0.asAssignment() }
        // Canvas contributes graded assignments plus anything that reads as an
        // assessment (quizzes/exams), plus — for a course the user opted in via
        // a readings/silent-course nudge or Settings — its dated calendar
        // events (docs/READINGS_COURSES_PLAN.md). Gradescope items are already
        // assignments.
        let canvasRelevant = canvasItems.filter { $0.isAssignment || Self.isAssessment($0) || includesAsOptedInContent($0) }
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

        let incomplete = allItems.filter { item in
            !isCompleted(item)
                && !Self.isTooOld(item, now: now)
                && isCourseSelected(item.course)          // class picker
                && Self.withinTermCap(item, now: now)     // end-of-term cap
        }
        // `.event` items never land in Assessments even when their title
        // matches the exam/quiz regex (`isAssessment` is title-based, and a
        // readings-course opt-in can surface something titled e.g. "Reading
        // quiz prep") — they're opted-in content, always coursework.
        assessments = incomplete.filter { $0.kind != .event && Self.isAssessment($0) }

        // Near (overdue + this week) and later partition the coursework with no
        // gap, so nothing incomplete is silently dropped.
        let coursework = incomplete.filter { $0.kind == .event || !Self.isAssessment($0) }
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
        // A generated occurrence of a recurring task, or a manual item created
        // this launch, may have no row yet. Being completed is exactly what
        // makes it worth a durable record, so create one here — otherwise the
        // ledger could not be the single source of truth for completion.
        store.upsert(rowsNeededToComplete(assignment))
        store.setCompleted(ids: touched, at: date)
        refreshCompletionFromLedger()
        rebuildDashboardItems()
    }

    func markActive(_ assignment: Assignment) {
        var touched: Set<String> = [assignment.id]
        if let linkedID = assignment.linkedID { touched.insert(linkedID) }

        guard let store = assignmentStore else {
            // No ledger at all: the old defaults keys are the only durable
            // store, so un-ticking has to be written back to them directly.
            completedAssignmentIDs.subtract(touched)
            for id in touched { completionDates[id] = nil }
            UserDefaults.lhf.set(completedAssignmentIDs.sorted(), forKey: Self.completedIDsKey)
            if let data = try? JSONEncoder().encode(completionDates) {
                UserDefaults.lhf.set(data, forKey: Self.completionDatesKey)
            }
            rebuildDashboardItems()
            return
        }
        store.setCompleted(ids: [], at: nil, clearing: touched)
        refreshCompletionFromLedger()
        rebuildDashboardItems()
    }

    /// The item plus its cross-platform counterpart, so both identities get a
    /// row before completion is written.
    ///
    /// Completing a merged item marks both ids, but only the item the user
    /// tapped is in hand — the counterpart is just a `linkedID`. When the pools
    /// were filled by a sync, both already have rows and this changes nothing.
    /// When they weren't — preview mode and sample data assign `canvasItems` /
    /// `gradescopeItems` directly, and preview mode is the path App Store
    /// reviewers use because they can't pass Penn SSO — the counterpart has no
    /// row, `setCompleted` silently skips it, and half the merge comes back
    /// undone.
    private func rowsNeededToComplete(_ assignment: Assignment) -> [Assignment] {
        guard let linkedID = assignment.linkedID else { return [assignment] }
        let counterpart = (gradescopeItems + canvasItems).first { $0.id == linkedID }
        return [assignment] + (counterpart.map { [$0] } ?? [])
    }

    /// The no-ledger fallback path. Only reachable when even an in-memory store
    /// could not be created, where the app degrades to its pre-ledger behaviour.
    private func applyCompletionInMemory(_ ids: Set<String>, at date: Date) {
        completedAssignmentIDs.formUnion(ids)
        for id in ids { completionDates[id] = date }
        // With no ledger at all the old defaults keys are the only durable
        // store left, so this path writes them directly. `LegacyStateMigration`
        // drains them onto the ledger the moment one can be opened again.
        UserDefaults.lhf.set(completedAssignmentIDs.sorted(), forKey: Self.completedIDsKey)
        if let data = try? JSONEncoder().encode(completionDates) {
            UserDefaults.lhf.set(data, forKey: Self.completionDatesKey)
        }
    }

    /// Rebuilds the published completion projection from the ledger, unioned
    /// with anything still waiting to be migrated onto it.
    private func refreshCompletionFromLedger() {
        guard let store = assignmentStore else { return }
        let record = store.completionRecord()
        completionDates = record.dates
        completedAssignmentIDs = record.ids
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
        var ids: Set<String> = []
        for snapshot in gradeWatcher.snapshots.values {
            for submission in snapshot.submissions where submission.indicatesSubmitted {
                ids.insert(submission.assignmentID)
            }
        }
        // Merge rather than replace: the ledger may know about work turned in
        // for a course that isn't in this refresh (deselected, or a fetch that
        // failed mid-loop), and dropping it would bounce finished items back
        // onto the dashboard.
        submittedCanvasAssignmentIDs = ids.union(persistedSubmittedIDsForUnfetchedCourses())

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
                submittedCanvasAssignmentIDs: ids,
                scores: scores
            ) ?? []
            pendingGradeChanges = notifiableGradeChanges(changes)
        }
        rebuildDashboardItems()
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

    /// Persisted submissions belonging to courses this refresh didn't cover, so
    /// a partial or deselected refresh can't un-submit them in memory.
    private func persistedSubmittedIDsForUnfetchedCourses() -> Set<String> {
        guard let store = assignmentStore else { return [] }
        guard !gradeWatcher.snapshots.isEmpty else { return store.submittedCanvasAssignmentIDs() }

        // Anything this refresh actually saw is authoritative (including a
        // now-retracted submission, which must be allowed to clear). Everything
        // else keeps whatever the ledger last recorded.
        let refreshedAssignmentIDs = Set(
            gradeWatcher.snapshots.values
                .flatMap(\.categories)
                .flatMap(\.items)
                .map(\.id)
        )
        return store.submittedCanvasAssignmentIDs().subtracting(refreshedAssignmentIDs)
    }

    /// When this item was marked done, if known. Items completed before the app
    /// tracked timestamps return nil — callers fall back to the due date.
    func completedAt(_ assignment: Assignment) -> Date? {
        completionDates[assignment.id]
    }


    private static func loadCompletionDates() -> [String: Date] {
        guard let data = UserDefaults.lhf.data(forKey: completionDatesKey),
              let map = try? JSONDecoder().decode([String: Date].self, from: data)
        else { return [:] }
        return map
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
