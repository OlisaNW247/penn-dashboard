import Foundation
import SwiftUI
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
    @Published private(set) var completedAssignmentIDs: Set<String>
    /// When each completed item was marked done. Persisted so the Done tab keeps
    /// its history across launches (and so completed homework doesn't vanish on
    /// relaunch). IDs completed before this map existed simply have no entry;
    /// the Done view falls back to the due date to place them.
    @Published private(set) var completionDates: [String: Date]
    /// Canvas assignment ids the grades fetch reports as submitted (see
    /// `AssignmentSubmissionInfo.indicatesSubmitted`). DERIVED state, recomputed
    /// from grade snapshots on every refresh and NOT persisted — so a Canvas
    /// correction (a retracted submission) self-heals on the next sync instead of
    /// sticking. Consulted by `isCompleted` to auto-file submitted work under Done.
    @Published private(set) var submittedCanvasAssignmentIDs: Set<String> = []
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
    @Published private(set) var isPreviewMode: Bool
    @Published private(set) var userName: String
    /// Light/Dark appearance, applied app-wide via `.preferredColorScheme` at
    /// the root. Persisted like every other user preference here.
    @Published private(set) var appearanceMode: AppearanceMode

    /// Canvas grade snapshots for the selected courses (Settings → Grade
    /// Watcher). Its own `ObservableObject` so CP4's view can observe it
    /// directly; `refreshGradeWatcher` is the only thing that drives it here.
    let gradeWatcher = GradeWatcherStore()

    private static let userNameKey = "userName"
    private static let urlKey = "canvasICSURL"
    private static let completedIDsKey = "completedAssignmentIDs"
    private static let completionDatesKey = "completionDates"
    private static let hiddenCoursesKey = "hiddenCourseKeys"
    private static let deletedCoursesKey = "deletedCourseKeys"
    private static let recurringTasksKey = "recurringTasks"
    private static let manualAssignmentsKey = "manualAssignments"
    private static let canvasDiscoveryConnectedKey = "canvasDiscoveryConnected"
    private static let gradescopeConnectedKey = "gradescopeConnected"
    private static let onboardingCompletedKey = "hasCompletedOnboarding"
    private static let previewModeKey = "isPreviewMode"
    private static let appearanceModeKey = "appearanceMode"

    init() {
        self.canvasICSURL = UserDefaults.standard.string(forKey: Self.urlKey) ?? ""
        self.completedAssignmentIDs = Set(UserDefaults.standard.stringArray(forKey: Self.completedIDsKey) ?? [])
        self.completionDates = Self.loadCompletionDates()
        self.hiddenCourseKeys = Set(UserDefaults.standard.stringArray(forKey: Self.hiddenCoursesKey) ?? [])
        self.deletedCourseKeys = Set(UserDefaults.standard.stringArray(forKey: Self.deletedCoursesKey) ?? [])
        self.isCanvasDiscoveryConnected = UserDefaults.standard.bool(forKey: Self.canvasDiscoveryConnectedKey)
        self.isGradescopeConnected = UserDefaults.standard.bool(forKey: Self.gradescopeConnectedKey)
        self.hasCompletedOnboarding = UserDefaults.standard.bool(forKey: Self.onboardingCompletedKey)
        self.isPreviewMode = UserDefaults.standard.bool(forKey: Self.previewModeKey)
        self.userName = UserDefaults.standard.string(forKey: Self.userNameKey) ?? ""
        self.appearanceMode = AppearanceMode(
            rawValue: UserDefaults.standard.string(forKey: Self.appearanceModeKey) ?? ""
        ) ?? .light
        self.recurringTasks = Self.loadRecurringTasks()
        self.manualAssignments = Self.loadManualAssignments()
        rebuildDashboardItems()

        // Preview (demo) mode persists across launches so an App Store reviewer
        // who relaunches still lands on the populated sample dashboard.
        if isPreviewMode {
            hasCompletedOnboarding = true
            if userName.isEmpty { userName = "there" }
        }

        #if DEBUG
        // Screenshot/preview seam: launch with `-LHFDemoData` to skip onboarding
        // and show a fully-populated dashboard. DEBUG-only; never in release.
        if ProcessInfo.processInfo.arguments.contains("-LHFDemoData") {
            hasCompletedOnboarding = true
            userName = "Marco"
        }
        #endif
    }

    /// First-run onboarding is required until both core data sources are connected.
    var needsOnboarding: Bool { !hasCompletedOnboarding }

    /// True once the Canvas calendar feed has been captured automatically.
    var isCanvasConnected: Bool { !canvasICSURL.isEmpty }

    func completeOnboarding() {
        hasCompletedOnboarding = true
        UserDefaults.standard.set(true, forKey: Self.onboardingCompletedKey)
    }

    /// The user's first name, captured during onboarding and shown in the
    /// dashboard greeting ("Hello, Marco").
    func updateName(_ name: String) {
        userName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(userName, forKey: Self.userNameKey)
    }

    /// Switches the app's Light/Dark appearance (Settings → Appearance).
    func setAppearanceMode(_ mode: AppearanceMode) {
        appearanceMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: Self.appearanceModeKey)
    }

    /// Sends the user back to the connect flow (used by the dashboard's reconnect
    /// buttons). Already-connected services stay connected and show as done.
    func restartOnboarding() {
        hasCompletedOnboarding = false
        UserDefaults.standard.set(false, forKey: Self.onboardingCompletedKey)
        // Leaving onboarding via "Connect Canvas" also exits the demo, so a real
        // student who tapped Preview can switch to their own Canvas cleanly.
        isPreviewMode = false
        UserDefaults.standard.set(false, forKey: Self.previewModeKey)
    }

    /// Enters a read-only demo populated with sample courses and assignments, so
    /// anyone who can't pass Penn SSO (notably an App Store reviewer) can explore
    /// the full app. No network, no login; the dashboard reads bundled fixtures.
    func enterPreviewMode() {
        isPreviewMode = true
        UserDefaults.standard.set(true, forKey: Self.previewModeKey)
        if userName.isEmpty { userName = "there" }
        completeOnboarding()
    }

    func updateCanvasICSURL(_ value: String) {
        canvasICSURL = value.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(canvasICSURL, forKey: Self.urlKey)
        if canvasICSURL.isEmpty {
            canvasItems = []
            rebuildDashboardItems()
            error = nil
            lastSync = nil
        }
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
            canvasItems = fetched
            rebuildDashboardItems()
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
        UserDefaults.standard.set(connected, forKey: Self.canvasDiscoveryConnectedKey)
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
            gradescopeItems = try await client.fetchAssignments().map(Self.normalizingCourse)
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
        UserDefaults.standard.set(connected, forKey: Self.gradescopeConnectedKey)
    }

    /// Refreshes Grade Watcher for the SELECTED courses only (docs/grades.md
    /// Decision 4) — a course the user hid from the dashboard via the class
    /// picker is also skipped here, so we never fetch grades for a course
    /// nobody asked to see.
    func refreshGradeWatcher(cookies: [HTTPCookie]) async {
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
        UserDefaults.standard.set(hiddenCourseKeys.sorted(), forKey: Self.hiddenCoursesKey)
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
        UserDefaults.standard.set(deletedCourseKeys.sorted(), forKey: Self.deletedCoursesKey)
    }

    func addRecurringTask(_ task: RecurringTask) {
        recurringTasks.append(task)
        persistRecurringTasks()
        rebuildDashboardItems()
    }

    func addManualAssignment(_ assignment: ManualAssignment) {
        manualAssignments.append(assignment)
        persistManualAssignments()
        rebuildDashboardItems()
    }

    func removeManualAssignment(id: UUID) {
        manualAssignments.removeAll { $0.id == id }
        persistManualAssignments()
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

    private func rebuildDashboardItems(now: Date = Date()) {
        let recurringAssignments = recurringTasks.flatMap { $0.upcomingAssignments() }
        let manualItems = manualAssignments.map { $0.asAssignment() }
        // Canvas contributes graded assignments plus anything that reads as an
        // assessment (quizzes/exams). Gradescope items are already assignments.
        let canvasRelevant = canvasItems.filter { $0.isAssignment || Self.isAssessment($0) }
        let allItems = (canvasRelevant + gradescopeItems + recurringAssignments + manualItems)
            .sorted(by: Self.byDueDate)

        let incomplete = allItems.filter { item in
            !isCompleted(item)
                && !Self.isTooOld(item, now: now)
                && isCourseSelected(item.course)          // class picker
                && Self.withinTermCap(item, now: now)     // end-of-term cap
        }
        assessments = incomplete.filter { Self.isAssessment($0) }

        // Near (overdue + this week) and later partition the coursework with no
        // gap, so nothing incomplete is silently dropped.
        let coursework = incomplete.filter { !Self.isAssessment($0) }
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

    func markCompleted(_ assignment: Assignment, at date: Date = Date()) {
        completedAssignmentIDs.insert(assignment.id)
        completionDates[assignment.id] = date
        persistCompletedIDs()
        rebuildDashboardItems()
    }

    func markActive(_ assignment: Assignment) {
        completedAssignmentIDs.remove(assignment.id)
        completionDates[assignment.id] = nil
        persistCompletedIDs()
        rebuildDashboardItems()
    }

    func isCompleted(_ assignment: Assignment) -> Bool {
        if assignment.submitted || completedAssignmentIDs.contains(assignment.id) { return true }
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
        submittedCanvasAssignmentIDs = ids
        rebuildDashboardItems()
    }

    /// When this item was marked done, if known. Items completed before the app
    /// tracked timestamps return nil — callers fall back to the due date.
    func completedAt(_ assignment: Assignment) -> Date? {
        completionDates[assignment.id]
    }

    private func persistCompletedIDs() {
        UserDefaults.standard.set(completedAssignmentIDs.sorted(), forKey: Self.completedIDsKey)
        // Keep the date map trimmed to currently-completed IDs so it can't grow
        // unbounded as items are toggled.
        completionDates = completionDates.filter { completedAssignmentIDs.contains($0.key) }
        if let data = try? JSONEncoder().encode(completionDates) {
            UserDefaults.standard.set(data, forKey: Self.completionDatesKey)
        }
    }

    private static func loadCompletionDates() -> [String: Date] {
        guard let data = UserDefaults.standard.data(forKey: completionDatesKey),
              let map = try? JSONDecoder().decode([String: Date].self, from: data)
        else { return [:] }
        return map
    }

    private func persistRecurringTasks() {
        guard let data = try? JSONEncoder().encode(recurringTasks) else { return }
        UserDefaults.standard.set(data, forKey: Self.recurringTasksKey)
    }

    private static func loadRecurringTasks() -> [RecurringTask] {
        guard let data = UserDefaults.standard.data(forKey: recurringTasksKey),
              let tasks = try? JSONDecoder().decode([RecurringTask].self, from: data)
        else { return [] }
        return tasks
    }

    private func persistManualAssignments() {
        guard let data = try? JSONEncoder().encode(manualAssignments) else { return }
        UserDefaults.standard.set(data, forKey: Self.manualAssignmentsKey)
    }

    private static func loadManualAssignments() -> [ManualAssignment] {
        guard let data = UserDefaults.standard.data(forKey: manualAssignmentsKey),
              let items = try? JSONDecoder().decode([ManualAssignment].self, from: data)
        else { return [] }
        return items
    }

    private func canvasCourseIDs() -> [String: String] {
        var courses: [String: String] = [:]
        for item in canvasItems {
            guard let url = item.url,
                  let courseID = Self.courseID(from: url)
            else { continue }
            courses[courseID] = item.course
        }
        return courses
    }

    /// Canvas course id -> display name, filtered to the class-picker's
    /// selected set. Drives Grade Watcher (docs/grades.md Decision 4) so a
    /// hidden course is never fetched.
    func selectedCanvasCourseIDs() -> [String: String] {
        canvasCourseIDs().filter { isCourseSelected($0.value) }
    }

    private static func courseID(from url: URL) -> String? {
        let parts = url.pathComponents
        guard let index = parts.firstIndex(of: "courses"),
              parts.indices.contains(parts.index(after: index))
        else { return nil }
        return parts[parts.index(after: index)]
    }

    private static func byDueDate(_ a: Assignment, _ b: Assignment) -> Bool {
        switch (a.dueAt, b.dueAt) {
        case let (lhs?, rhs?): return lhs < rhs
        case (nil, _):         return false   // nil dates sort to the end
        case (_, nil):         return true
        }
    }
}
