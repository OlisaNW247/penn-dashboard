import Foundation
import LowHangingFruitKit

// MARK: – Course materials for ask
//
// The knowledge base is what lets ask answer a policy question. Before it,
// the only course text on disk was the grading table `SyllabusParser`
// keeps; syllabus prose and announcement bodies were fetched, mined, and
// dropped (see the header of `AssistantContextAssembly.swift`). The
// collector below keeps them, on-device, keyed by Canvas course id.
//
// Which courses: `canvasCourseIDsByCode`, the same code → id map Grade
// Watcher is keyed by, so a course becomes askable exactly when it becomes
// watchable. Which cookies: the ones `AutoSyncCoordinator.canvasCookies()`
// already gathers for grades — this sync piggybacks on that refresh rather
// than opening its own session axis, the way readings detection does.

extension AppState {
    /// Re-sync course materials at most this often on the launch/activation
    /// path. Syllabi change rarely; announcements are also caught by the
    /// Announcement Watcher's own cadence.
    static let courseKnowledgeStaleAfter: TimeInterval = 6 * 3600

    var courseKnowledgeIsStale: Bool {
        guard let last = courseKnowledge.lastSyncedAt else { return true }
        return Date().timeIntervalSince(last) > Self.courseKnowledgeStaleAfter
    }

    /// The knowledge `ask` reasons over. Preview mode (the App Store
    /// reviewer's path and `-LHFDemoData`) gets the bundled sample syllabi so
    /// the screen can be exercised with no Canvas account, exactly as the
    /// dashboard and Grade Watcher do with `SampleData`.
    var assistantKnowledge: CourseKnowledgeBase {
        isUsingFixtureData ? SampleData.knowledge() : courseKnowledge
    }

    /// Every dashboard item, active or done, with the app's completion state
    /// applied — what the on-device answerer computes "what's due" from.
    /// Mirrors the pools `assistantContextDocument()` sends to Claude so the
    /// two backends agree on what exists.
    func assistantWorkItems() -> [WorkItem] {
        let pool = canvasItems + gradescopeItems + moduleReadingItems + announcementItems
            + recurringTasks.flatMap { $0.upcomingAssignments() }
            + manualAssignments.map { $0.asAssignment() }
        var seen: Set<String> = []
        return pool.compactMap { assignment in
            guard seen.insert(assignment.id).inserted else { return nil }
            return WorkItem(assignment: assignment, isCompleted: isCompleted(assignment))
        }
    }

    /// Pulls course materials for every course with a known Canvas id and
    /// stores them on-device. Never throws; problems land in
    /// `courseKnowledgeNotice` for Settings to show.
    func refreshCourseKnowledge(cookies: [HTTPCookie], force: Bool = false) async {
        guard !isUsingFixtureData, !isCourseKnowledgeSyncing else { return }
        guard force || courseKnowledgeIsStale else { return }
        guard !cookies.isEmpty else {
            courseKnowledgeNotice = "reconnect canvas to sync course materials."
            return
        }

        let courses = canvasCourseIDsByCode
            .map { code, id in
                CourseSummary(
                    courseID: id,
                    code: code,
                    name: courseDisplayName(code),
                    url: URL(string: "https://canvas.upenn.edu/courses/\(id)")
                )
            }
            .sorted { $0.code.localizedStandardCompare($1.code) == .orderedAscending }

        isCourseKnowledgeSyncing = true
        defer { isCourseKnowledgeSyncing = false }

        let collector = CourseKnowledgeCollector(cookies: cookies, store: CourseKnowledgeStore.default())
        do {
            let report = try await collector.run(courses: courses)
            courseKnowledge = report.knowledge
            if report.syncedCourses == 0 {
                courseKnowledgeNotice = "couldn't read course materials from canvas. \(report.errors.first ?? "")"
            } else if !report.errors.isEmpty {
                courseKnowledgeNotice = "synced \(report.syncedCourses) courses; some pages were skipped."
            } else {
                courseKnowledgeNotice = nil
            }
        } catch {
            courseKnowledgeNotice = error.localizedDescription
        }
    }

    func clearCourseKnowledge() {
        CourseKnowledgeStore.default().clear()
        courseKnowledge = .empty
        courseKnowledgeNotice = nil
    }
}
