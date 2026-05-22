import Foundation
import PennDashboardKit

@MainActor
final class AppState: ObservableObject {
    @Published var canvasItems: [Assignment] = []
    @Published var gradescopeAssignments: [Assignment] = []
    @Published var assignments: [Assignment] = []
    @Published var completedAssignments: [Assignment] = []
    @Published var otherItems: [Assignment] = []
    @Published var recurringTasks: [RecurringTask] = []
    @Published var canvasRequirementSuggestions: [CanvasRequirementSuggestion] = []
    @Published var isLoading = false
    @Published var isGradescopeLoading = false
    @Published var isCanvasDiscoveryLoading = false
    @Published var error: String?
    @Published var syncNotice: String?
    @Published var lastSync: Date?
    @Published var lastGradescopeSync: Date?

    @Published private(set) var canvasICSURL: String
    @Published private(set) var completedAssignmentIDs: Set<String>
    @Published private(set) var isGradescopeConnected: Bool
    @Published private(set) var isCanvasDiscoveryConnected: Bool

    private static let urlKey = "canvasICSURL"
    private static let completedIDsKey = "completedAssignmentIDs"
    private static let recurringTasksKey = "recurringTasks"
    private static let gradescopeConnectedKey = "gradescopeConnected"
    private static let canvasDiscoveryConnectedKey = "canvasDiscoveryConnected"

    init() {
        self.canvasICSURL = UserDefaults.standard.string(forKey: Self.urlKey) ?? ""
        self.completedAssignmentIDs = Set(UserDefaults.standard.stringArray(forKey: Self.completedIDsKey) ?? [])
        self.isGradescopeConnected = UserDefaults.standard.bool(forKey: Self.gradescopeConnectedKey)
        self.isCanvasDiscoveryConnected = UserDefaults.standard.bool(forKey: Self.canvasDiscoveryConnectedKey)
        self.recurringTasks = Self.loadRecurringTasks()
        rebuildDashboardItems()
    }

    func updateCanvasICSURL(_ value: String) {
        canvasICSURL = value.trimmingCharacters(in: .whitespacesAndNewlines)
        UserDefaults.standard.set(canvasICSURL, forKey: Self.urlKey)
        if canvasICSURL.isEmpty {
            canvasItems = []
            otherItems = []
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
            otherItems = fetched.filter { !$0.isAssignment }
            rebuildDashboardItems()
            lastSync = Date()
        } catch {
            self.error = "Sync failed: \(error.localizedDescription)"
        }
    }

    func syncGradescope(cookies: [HTTPCookie]) async {
        await syncGradescope(cookies: cookies, reportErrors: true)
    }

    func syncGradescope(cookies: [HTTPCookie], reportErrors: Bool) async {
        isGradescopeLoading = true
        if reportErrors { error = nil }
        defer { isGradescopeLoading = false }

        do {
            let client = GradescopeClient(cookies: cookies)
            gradescopeAssignments = try await client.fetchAssignments()
            rebuildDashboardItems()
            lastGradescopeSync = Date()
            setGradescopeConnected(true)
            syncNotice = nil
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

    func setGradescopeConnected(_ connected: Bool) {
        isGradescopeConnected = connected
        UserDefaults.standard.set(connected, forKey: Self.gradescopeConnectedKey)
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

    private func rebuildDashboardItems() {
        let recurringAssignments = recurringTasks.flatMap { $0.upcomingAssignments() }
        let allAssignments = (canvasItems.filter(\.isAssignment) + gradescopeAssignments + recurringAssignments)
            .sorted(by: Self.byDueDate)
        assignments = allAssignments.filter { !isCompleted($0) }
        completedAssignments = allAssignments.filter { isCompleted($0) }
    }

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
