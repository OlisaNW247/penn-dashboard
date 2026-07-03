import Foundation
import LowHangingFruitKit

@MainActor
final class AppState: ObservableObject {
    @Published var canvasItems: [Assignment] = []
    @Published var assignments: [Assignment] = []
    @Published var laterAssignments: [Assignment] = []
    @Published var assessments: [Assignment] = []
    @Published var recurringTasks: [RecurringTask] = []
    @Published private(set) var manualAssignments: [ManualAssignment] = []
    @Published var canvasRequirementSuggestions: [CanvasRequirementSuggestion] = []
    @Published var isLoading = false
    @Published var isCanvasDiscoveryLoading = false
    @Published var error: String?
    @Published var syncNotice: String?
    @Published var lastSync: Date?

    @Published private(set) var canvasICSURL: String
    @Published private(set) var completedAssignmentIDs: Set<String>
    @Published private(set) var isCanvasDiscoveryConnected: Bool
    @Published private(set) var hasCompletedOnboarding: Bool
    @Published private(set) var isPreviewMode: Bool
    @Published private(set) var userName: String

    private static let userNameKey = "userName"
    private static let urlKey = "canvasICSURL"
    private static let completedIDsKey = "completedAssignmentIDs"
    private static let recurringTasksKey = "recurringTasks"
    private static let manualAssignmentsKey = "manualAssignments"
    private static let canvasDiscoveryConnectedKey = "canvasDiscoveryConnected"
    private static let onboardingCompletedKey = "hasCompletedOnboarding"
    private static let previewModeKey = "isPreviewMode"

    init() {
        self.canvasICSURL = UserDefaults.standard.string(forKey: Self.urlKey) ?? ""
        self.completedAssignmentIDs = Set(UserDefaults.standard.stringArray(forKey: Self.completedIDsKey) ?? [])
        self.isCanvasDiscoveryConnected = UserDefaults.standard.bool(forKey: Self.canvasDiscoveryConnectedKey)
        self.hasCompletedOnboarding = UserDefaults.standard.bool(forKey: Self.onboardingCompletedKey)
        self.isPreviewMode = UserDefaults.standard.bool(forKey: Self.previewModeKey)
        self.userName = UserDefaults.standard.string(forKey: Self.userNameKey) ?? ""
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

    /// Active assignments are limited to a near-term window: due within the next
    /// week, or overdue by less than a week.
    static let dashboardWindow: TimeInterval = 7 * 86_400

    /// Main dashboard: dated assignments due within the ±1-week window.
    static func isActive(_ assignment: Assignment, now: Date = Date()) -> Bool {
        guard let due = assignment.dueAt else { return false }
        return due >= now.addingTimeInterval(-dashboardWindow)
            && due <= now.addingTimeInterval(dashboardWindow)
    }

    /// Later tab: assignments due more than a week out, plus anything with no
    /// due date (e.g. exams professors upload without a deadline).
    static func isLater(_ assignment: Assignment, now: Date = Date()) -> Bool {
        guard let due = assignment.dueAt else { return true }
        return due > now.addingTimeInterval(dashboardWindow)
    }

    /// Stale leftovers — anything due more than 5 months ago — are hidden
    /// everywhere. Undated items are never "too old" since we can't date them.
    static func isTooOld(_ assignment: Assignment, now: Date = Date()) -> Bool {
        guard let due = assignment.dueAt,
              let cutoff = Calendar.current.date(byAdding: .month, value: -5, to: now)
        else { return false }
        return due < cutoff
    }

    /// Quizzes, midterms, and exams live on their own Assessments page rather than
    /// mixed into coursework. Detected by Canvas's quiz classification or by title.
    static func isAssessment(_ assignment: Assignment) -> Bool {
        if assignment.kind == .quiz { return true }
        let pattern = #"(?i)\b(midterms?|exams?|quiz|quizzes|prelims?|finals|final exam)\b"#
        return assignment.title.range(of: pattern, options: .regularExpression) != nil
    }

    private func rebuildDashboardItems() {
        let recurringAssignments = recurringTasks.flatMap { $0.upcomingAssignments() }
        let manualItems = manualAssignments.map { $0.asAssignment() }
        // Canvas contributes graded assignments plus anything that reads as an
        // assessment (quizzes/exams that aren't classified as plain assignments).
        let canvasRelevant = canvasItems.filter { $0.isAssignment || Self.isAssessment($0) }
        let allItems = (canvasRelevant + recurringAssignments + manualItems)
            .sorted(by: Self.byDueDate)

        let incomplete = allItems.filter { !isCompleted($0) && !Self.isTooOld($0) }
        assessments = incomplete.filter { Self.isAssessment($0) }

        let coursework = incomplete.filter { !Self.isAssessment($0) }
        assignments = coursework.filter { Self.isActive($0) }
        laterAssignments = coursework.filter { Self.isLater($0) }
    }

    #if DEBUG
    /// Loads fake assignments (the preview fixtures) into the live store so the
    /// UI can be exercised without connecting a real Canvas account.
    func loadSampleData() {
        canvasItems = SampleData.items().map(\.assignment)
        completedAssignmentIDs = []
        rebuildDashboardItems()
    }
    #endif

    func markCompleted(_ assignment: Assignment) {
        completedAssignmentIDs.insert(assignment.id)
        persistCompletedIDs()
        rebuildDashboardItems()
    }

    func markActive(_ assignment: Assignment) {
        completedAssignmentIDs.remove(assignment.id)
        persistCompletedIDs()
        rebuildDashboardItems()
    }

    func isCompleted(_ assignment: Assignment) -> Bool {
        assignment.submitted || completedAssignmentIDs.contains(assignment.id)
    }

    private func persistCompletedIDs() {
        UserDefaults.standard.set(completedAssignmentIDs.sorted(), forKey: Self.completedIDsKey)
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
