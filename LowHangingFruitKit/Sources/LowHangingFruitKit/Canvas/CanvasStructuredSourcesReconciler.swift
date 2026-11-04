import Foundation

/// What Canvas states as structured data, as plain facts for the UI layer to
/// apply to the ledger later. This type applies nothing itself.
///
/// The invariant from CLAUDE.md, "nothing the student did is ever lost",
/// shapes the vocabulary: there is no "delete" anywhere in here. A Canvas
/// dismissal is a *hide* signal, a missing flag is an annotation, and a due
/// date correction is a proposed value, never an overwrite of the student's
/// own edit (that decision belongs to the applier).
public struct CanvasStructuredSignals: Codable, Sendable, Equatable {
    /// How to find the ledger row a signal is about. Exactly one is set:
    /// `assignmentID` is the real Canvas assignment id (what
    /// `Assignment.canvasAssignmentID` returns, so it joins feed rows and
    /// module rows alike); `sourceID` is for things with no assignment id
    /// (a quiz module item, a page, a planner note), in this file's forms.
    public struct Ref: Codable, Sendable, Hashable {
        public let assignmentID: String?
        public let sourceID: String?
        public static func assignment(_ id: String) -> Ref { Ref(assignmentID: id, sourceID: nil) }
        public static func source(_ id: String) -> Ref { Ref(assignmentID: nil, sourceID: id) }
    }

    public enum CompletionReason: String, Codable, Sendable {
        /// The student ticked it in Canvas's Planner.
        case plannerMarkedComplete
        /// Canvas reports a submission on the planner item.
        case plannerSubmitted
        /// A module `completion_requirement` is met.
        case moduleRequirement
        /// The missing-submissions list carried a planner mark.
        case missingListMarkedComplete
    }

    public struct Completion: Codable, Sendable, Hashable {
        public let ref: Ref
        public let courseID: String
        public let reason: CompletionReason
    }

    /// The student dismissed it in Canvas's Planner. Hide, never delete.
    public struct Dismissal: Codable, Sendable, Hashable {
        public let ref: Ref
        public let courseID: String
    }

    /// The student's own effective due date for an assignment, when it
    /// differs in kind from the feed's (a section override).
    public struct DueDateCorrection: Codable, Sendable, Hashable {
        public let assignmentID: String
        public let courseID: String
        public let dueAt: Date
    }

    public struct Missing: Codable, Sendable, Hashable {
        public let assignmentID: String
        public let courseID: String?
        public let title: String
        public let dueAt: Date?
    }

    /// A ledger row to upsert, as plain data (`Assignment` itself is not
    /// `Codable`). `assignment` rebuilds it.
    public struct Row: Codable, Sendable, Hashable {
        public let source: Assignment.Source
        public let sourceID: String
        public let kind: Assignment.Kind
        public let course: String
        public let title: String
        public let dueAt: Date?
        public let url: String?
        public let submitted: Bool

        public var assignment: Assignment {
            Assignment(source: source, sourceID: sourceID, kind: kind, course: course, title: title,
                       dueAt: dueAt, url: url.flatMap(URL.init(string:)), submitted: submitted)
        }
    }

    public var completions: [Completion] = []
    public var dismissals: [Dismissal] = []
    public var dueDateCorrections: [DueDateCorrection] = []
    public var missing: [Missing] = []
    public var rows: [Row] = []

    public init() {}

    public var isEmpty: Bool {
        completions.isEmpty && dismissals.isEmpty && dueDateCorrections.isEmpty && missing.isEmpty && rows.isEmpty
    }
}

/// Pure conversion from fetched Canvas structures to `CanvasStructuredSignals`.
public enum CanvasStructuredSourcesReconciler {
    /// `courses` maps Canvas course id to the dashboard's course key
    /// (`CourseSummary.code`, the identity CLAUDE.md calls the key for
    /// everything). Data for a course id not in the map is ignored: with no
    /// key the row would have no honest course.
    public static func signals(
        from run: CanvasStructuredSourcesClient.RunResult,
        courses: [CourseSummary],
        baseURL: URL = CanvasInstallation.penn.baseURL
    ) -> CanvasStructuredSignals {
        var out = CanvasStructuredSignals()
        var keys: [String: String] = [:]
        for course in courses { keys[course.courseID] = course.code }
        var seenCompletion = Set<CanvasStructuredSignals.Completion>()
        func complete(_ ref: CanvasStructuredSignals.Ref, _ cid: String, _ reason: CanvasStructuredSignals.CompletionReason) {
            let value = CanvasStructuredSignals.Completion(ref: ref, courseID: cid, reason: reason)
            if seenCompletion.insert(value).inserted { out.completions.append(value) }
        }

        // Per-course sources.
        for course in run.courses {
            guard let key = keys[course.courseID] else { continue }
            let cid = course.courseID

            // Discussion topic id -> nested assignment id, so a Discussion
            // module item can carry the right (assignment-space) id.
            var topicAssignment: [String: String] = [:]
            for topic in course.discussionTopics { if let a = topic.assignmentID { topicAssignment[topic.id] = a } }

            // Modules.
            for module in course.modules {
                for item in module.items {
                    guard let kind = moduleKind(item.type) else { continue }
                    let assignmentID = moduleAssignmentID(item, topicAssignment: topicAssignment)
                    let sourceID = "module-item-\(item.id)"
                    let ref: CanvasStructuredSignals.Ref = assignmentID.map { .assignment($0) } ?? .source(sourceID)
                    if item.completionCompleted == true { complete(ref, cid, .moduleRequirement) }
                    // An undated item is not something that is "due".
                    guard let due = item.dueAt else { continue }
                    out.rows.append(.init(
                        source: .canvasModules, sourceID: sourceID, kind: kind, course: key,
                        title: item.title, dueAt: due,
                        url: moduleURL(item, assignmentID: assignmentID, courseID: cid, baseURL: baseURL)?.absoluteString,
                        submitted: item.completionCompleted == true))
                }
            }

            // Assignment overrides -> the student's own due date.
            for assignment in course.assignments where assignment.isLive {
                if let due = effectiveDueDate(assignment) {
                    out.dueDateCorrections.append(.init(assignmentID: assignment.id, courseID: cid, dueAt: due))
                }
            }

            // Graded discussions and to-do dated discussions.
            for topic in course.discussionTopics where topic.published != false {
                let due = topic.assignmentDueAt ?? topic.todoDate
                guard topic.assignmentID != nil || topic.todoDate != nil, let dueAt = due else { continue }
                let url: URL
                if let a = topic.assignmentID {
                    // Same id space as a feed row, so the twin logic joins them.
                    url = baseURL.appendingPathComponent("courses/\(cid)/assignments/\(a)")
                } else {
                    url = topic.htmlURL.flatMap(URL.init(string:))
                        ?? baseURL.appendingPathComponent("courses/\(cid)/discussion_topics/\(topic.id)")
                }
                out.rows.append(.init(source: .canvasModules, sourceID: "discussion_\(topic.id)", kind: .discussion,
                                      course: key, title: topic.title, dueAt: dueAt, url: url.absoluteString, submitted: false))
            }

            // Pages with a to-do date.
            for page in course.pages where page.published != false {
                guard let todo = page.todoDate else { continue }
                let url = page.htmlURL.flatMap(URL.init(string:))
                    ?? baseURL.appendingPathComponent("courses/\(cid)/pages/\(page.url)")
                out.rows.append(.init(source: .canvasModules, sourceID: "page_\(page.url)", kind: .other,
                                      course: key, title: page.title, dueAt: todo, url: url.absoluteString, submitted: false))
            }
        }

        // Planner (user-wide, filtered to known courses).
        for item in run.planner {
            guard let cid = item.courseID, let key = keys[cid], let id = item.plannableID else {
                // Planner notes without a course are real to-dos but have no
                // course key; they are skipped rather than filed under a
                // guessed class.
                continue
            }
            let ref: CanvasStructuredSignals.Ref
            switch item.plannableType {
            case "assignment": ref = .assignment(id)
            case "quiz": ref = .source("quiz_\(id)")
            case "discussion_topic": ref = .source("discussion_\(id)")
            case "wiki_page": ref = .source("page_\(item.pageURL ?? id)")
            case "planner_note": ref = .source("planner-note-\(id)")
            default: continue
            }
            if item.markedComplete { complete(ref, cid, .plannerMarkedComplete) }
            else if item.submitted == true { complete(ref, cid, .plannerSubmitted) }
            if item.dismissed { out.dismissals.append(.init(ref: ref, courseID: cid)) }
            if item.missing == true, item.plannableType == "assignment" {
                out.missing.append(.init(assignmentID: id, courseID: cid, title: item.title ?? "", dueAt: item.dueAt))
            }
            if item.plannableType == "planner_note" {
                out.rows.append(.init(
                    source: .canvasModules, sourceID: "planner-note-\(id)", kind: .other, course: key,
                    title: item.title ?? "", dueAt: item.todoDate ?? item.dueAt,
                    url: item.htmlURL.flatMap { $0.hasPrefix("http") ? $0 : baseURL.absoluteString + $0 },
                    submitted: item.markedComplete))
            }
        }

        // Missing submissions.
        for entry in run.missingSubmissions {
            if let cid = entry.courseID, keys[cid] == nil { continue }
            out.missing.append(.init(assignmentID: entry.assignmentID, courseID: entry.courseID, title: entry.name, dueAt: entry.dueAt))
            if let cid = entry.courseID {
                if entry.plannerMarkedComplete { complete(.assignment(entry.assignmentID), cid, .missingListMarkedComplete) }
                if entry.plannerDismissed { out.dismissals.append(.init(ref: .assignment(entry.assignmentID), courseID: cid)) }
            }
        }

        out.missing = dedupe(out.missing) { $0.assignmentID }
        out.dismissals = dedupe(out.dismissals) { $0.ref.assignmentID ?? $0.ref.sourceID ?? "" }
        out.dueDateCorrections = dedupe(out.dueDateCorrections) { $0.assignmentID }
        out.rows = dedupe(out.rows) { "\($0.source.rawValue):\($0.sourceID)" }
        return out
    }

    // MARK: - Pieces

    /// The student's own due date from `all_dates`: the non-base entry when
    /// present, else nil (nothing to correct). Base-only means the feed
    /// already has the right date.
    ///
    /// Several non-base entries (a student in two sections' overrides) take
    /// the earliest: a date that is too early costs a reminder, one that is
    /// too late costs a missed deadline. The tempting wrong fix is reading
    /// the assignment's top-level `due_at`, which is the base date for
    /// teachers and the exact thing the ICS feed already gets wrong.
    public static func effectiveDueDate(_ assignment: CanvasOverrideAssignment) -> Date? {
        let overrides = assignment.allDates.filter { !$0.base }.compactMap(\.dueAt)
        return overrides.min()
    }

    private static func moduleKind(_ type: String) -> Assignment.Kind? {
        switch type {
        case "Assignment": return .assignment
        case "Quiz": return .quiz
        case "Discussion": return .discussion
        default: return nil
        }
    }

    /// The id a feed row would carry. Only an `Assignment` item's
    /// `content_id` is in the assignment id space; a Quiz's is the quiz id and
    /// a Discussion's the topic id, and joining on those would read someone
    /// else's submission state (the trap documented on
    /// `AppState.moduleReadingAssignment`). A Discussion is resolved through
    /// its topic's nested assignment instead.
    private static func moduleAssignmentID(_ item: CanvasStructuredModuleItem, topicAssignment: [String: String]) -> String? {
        switch item.type {
        case "Assignment": return item.contentID
        case "Discussion": return item.contentID.flatMap { topicAssignment[$0] }
        default: return nil
        }
    }

    private static func moduleURL(_ item: CanvasStructuredModuleItem, assignmentID: String?, courseID: String, baseURL: URL) -> URL? {
        // `/assignments/<id>` is the form `canvasAssignmentID` reads from a
        // `.canvasModules` row, exactly as AppState.moduleReadingAssignment builds it.
        if let assignmentID { return baseURL.appendingPathComponent("courses/\(courseID)/assignments/\(assignmentID)") }
        if let html = item.htmlURL, let url = URL(string: html), url.scheme == "https" { return url }
        return nil
    }

    private static func dedupe<T>(_ items: [T], by key: (T) -> String) -> [T] {
        var seen = Set<String>()
        return items.filter { seen.insert(key($0)).inserted }
    }
}
