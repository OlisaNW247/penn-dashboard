import Foundation

/// An assignment as the assistant sees it: the dashboard's `Assignment` plus
/// the completion state the app layer tracks. Built by the UI from `AppState`
/// so the Kit never has to know about UserDefaults.
public struct WorkItem: Sendable, Hashable, Identifiable {
    public let id: String
    public let course: String
    public let title: String
    public let kind: Assignment.Kind
    public let dueAt: Date?
    public let url: URL?
    /// Marked done in LHF, or reported as submitted by Canvas.
    public let isCompleted: Bool

    public init(id: String, course: String, title: String, kind: Assignment.Kind, dueAt: Date?, url: URL?, isCompleted: Bool) {
        self.id = id
        self.course = course
        self.title = title
        self.kind = kind
        self.dueAt = dueAt
        self.url = url
        self.isCompleted = isCompleted
    }

    public init(assignment: Assignment, isCompleted: Bool, dueOverride: Date? = nil) {
        self.init(
            id: assignment.id,
            course: assignment.course,
            title: assignment.title,
            kind: assignment.kind,
            dueAt: dueOverride ?? assignment.dueAt,
            url: assignment.url,
            isCompleted: isCompleted || assignment.submitted
        )
    }

    /// Quizzes, midterms, and exams. Mirrors the dashboard's Assessments rule.
    public var isAssessment: Bool {
        Self.looksLikeAssessment(title: title, kind: kind)
    }

    public static func looksLikeAssessment(title: String, kind: Assignment.Kind) -> Bool {
        if kind == .quiz { return true }
        let pattern = #"(?i)\b(midterms?|exams?|quiz|quizzes|prelims?|finals|final exam)\b"#
        return title.range(of: pattern, options: .regularExpression) != nil
    }

    /// Canvas course id parsed from the item URL, when it has one.
    public var courseID: String? {
        guard let url else { return nil }
        let parts = url.pathComponents
        guard let index = parts.firstIndex(of: "courses"), parts.indices.contains(parts.index(after: index)) else { return nil }
        return parts[parts.index(after: index)]
    }
}

/// Everything the answerer needs for one question. Built fresh per question
/// so it always reflects the latest sync and completion state.
public struct AskKnowledgeContext: Sendable {
    public var userName: String
    public var now: Date
    public var calendar: Calendar
    public var items: [WorkItem]
    public var knowledge: CourseKnowledgeBase
    public var search: CourseSearch

    public init(
        userName: String = "",
        now: Date = Date(),
        calendar: Calendar = .current,
        items: [WorkItem],
        knowledge: CourseKnowledgeBase
    ) {
        self.userName = userName
        self.now = now
        self.calendar = calendar
        self.items = items
        self.knowledge = knowledge
        self.search = CourseSearch(knowledge: knowledge)
    }

    /// Courses known from either source, deduplicated by short code.
    public var courses: [CourseSummary] {
        var byCode: [String: CourseSummary] = [:]
        for course in knowledge.courses { byCode[CourseMatcher.normalize(course.code)] = course }
        for item in items {
            let key = CourseMatcher.normalize(item.course)
            guard !key.isEmpty, byCode[key] == nil else { continue }
            byCode[key] = CourseSummary(courseID: item.courseID ?? key, code: item.course, name: item.course, url: nil)
        }
        return byCode.values.sorted { $0.code.localizedCaseInsensitiveCompare($1.code) == .orderedAscending }
    }
}
