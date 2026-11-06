import Foundation

// Decoders for the structured Canvas endpoints the "composed day" reads
// (docs/DAY_PLANNER_RESEARCH_2026-11-03.md, Part 3). Everything here is
// deliberately tolerant: every field is optional, ids may arrive as numbers
// or strings, and a field of an unexpected shape reads as absent rather than
// failing the object. These are *facts Canvas states*, read to correct and
// annotate the ledger, so a half-readable item is worth more than a thrown
// page. The tempting wrong fix is a strict `Decodable` struct per endpoint:
// the first Canvas instance that sends `"submissions": false` (the planner
// does, for items with no submission) would then drop the whole page.

// MARK: - Tolerant decoding helpers

extension KeyedDecodingContainer {
    /// A string for a value that may be a string, an integer or a double
    /// (Canvas ids are integers in JSON but a few endpoints stringify them).
    fileprivate func flexString(_ key: Key) -> String? {
        if let string = try? decodeIfPresent(String.self, forKey: key) { return string }
        if let int = try? decodeIfPresent(Int64.self, forKey: key) { return String(int) }
        if let double = try? decodeIfPresent(Double.self, forKey: key) {
            // `Int64(_:)` traps outside its range (a JSON `1e300` is a valid
            // number), so convert only a finite integral value that fits.
            if double.isFinite, double == double.rounded(), double >= -9.2e18, double <= 9.2e18 {
                return String(Int64(double))
            }
            return String(double)
        }
        return nil
    }

    fileprivate func lenientString(_ key: Key) -> String? {
        (try? decodeIfPresent(String.self, forKey: key)) ?? nil
    }

    fileprivate func lenientBool(_ key: Key) -> Bool? {
        (try? decodeIfPresent(Bool.self, forKey: key)) ?? nil
    }

    fileprivate func lenientDouble(_ key: Key) -> Double? {
        (try? decodeIfPresent(Double.self, forKey: key)) ?? nil
    }

    fileprivate func lenientInt(_ key: Key) -> Int? {
        (try? decodeIfPresent(Int.self, forKey: key)) ?? nil
    }

    fileprivate func lenientDate(_ key: Key) -> Date? {
        guard let raw = lenientString(key), !raw.isEmpty else { return nil }
        return CourseContentAPI.parseDate(raw)
    }

    fileprivate func lenientObject<T: Decodable>(_ type: T.Type, _ key: Key) -> T? {
        (try? decodeIfPresent(type, forKey: key)) ?? nil
    }

    fileprivate func lenientList<T: Decodable>(_ type: T.Type, _ key: Key) -> [T] {
        ((try? decodeIfPresent(LossyArray<T>.self, forKey: key)) ?? nil)?.elements ?? []
    }
}

private enum AnyKey: CodingKey {
    case any(String)
    init?(stringValue: String) { self = .any(stringValue) }
    init?(intValue: Int) { nil }
    var stringValue: String { if case let .any(s) = self { return s }; return "" }
    var intValue: Int? { nil }
}

// MARK: - Planner

/// One entry of `GET /api/v1/planner/items`: Canvas's own merged to-do list.
public struct CanvasPlannerItem: Decodable, Sendable, Hashable {
    /// "assignment", "quiz", "discussion_topic", "wiki_page", "planner_note",
    /// "announcement", "calendar_event", ... passed through uninterpreted.
    public let plannableType: String
    public let plannableID: String?
    public let title: String?
    public let dueAt: Date?
    /// The to-do date for pages, notes and discussions (`plannable.todo_date`).
    public let todoDate: Date?
    /// `plannable.url`, which Canvas sends for wiki pages (the page slug).
    public let pageURL: String?
    public let courseID: String?
    public let htmlURL: String?
    public let markedComplete: Bool
    public let dismissed: Bool
    /// `submissions.submitted` etc.; nil when Canvas sent `false` or nothing.
    public let submitted: Bool?
    public let missing: Bool?
    public let graded: Bool?
    /// `plannable.assignment_id`: for a quiz, the id of the assignment that
    /// backs it, which is what a feed row carries. Not every Canvas sends it.
    public let assignmentID: String?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        func key(_ s: String) -> AnyKey { AnyKey(stringValue: s)! }
        plannableType = c.lenientString(key("plannable_type")) ?? ""
        plannableID = c.flexString(key("plannable_id"))
        courseID = c.flexString(key("course_id"))
        htmlURL = c.lenientString(key("html_url"))
        if let plannable = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: key("plannable")) {
            title = plannable.lenientString(key("title")) ?? plannable.lenientString(key("name"))
            dueAt = plannable.lenientDate(key("due_at"))
            todoDate = plannable.lenientDate(key("todo_date"))
            pageURL = plannable.lenientString(key("url"))
            assignmentID = plannable.flexString(key("assignment_id"))
        } else {
            title = nil; dueAt = nil; todoDate = nil; pageURL = nil; assignmentID = nil
        }
        if let override = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: key("planner_override")) {
            markedComplete = override.lenientBool(key("marked_complete")) ?? false
            dismissed = override.lenientBool(key("dismissed")) ?? false
        } else {
            markedComplete = false; dismissed = false
        }
        if let subs = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: key("submissions")) {
            submitted = subs.lenientBool(key("submitted"))
            missing = subs.lenientBool(key("missing"))
            graded = subs.lenientBool(key("graded"))
        } else {
            submitted = nil; missing = nil; graded = nil
        }
    }

    public init(
        plannableType: String, plannableID: String?, title: String? = nil, dueAt: Date? = nil,
        todoDate: Date? = nil, pageURL: String? = nil, courseID: String? = nil, htmlURL: String? = nil,
        markedComplete: Bool = false, dismissed: Bool = false,
        submitted: Bool? = nil, missing: Bool? = nil, graded: Bool? = nil, assignmentID: String? = nil
    ) {
        self.assignmentID = assignmentID
        self.plannableType = plannableType; self.plannableID = plannableID; self.title = title
        self.dueAt = dueAt; self.todoDate = todoDate; self.pageURL = pageURL; self.courseID = courseID
        self.htmlURL = htmlURL; self.markedComplete = markedComplete; self.dismissed = dismissed
        self.submitted = submitted; self.missing = missing; self.graded = graded
    }
}

// MARK: - Modules at item grain

public struct CanvasStructuredModuleItem: Decodable, Sendable, Hashable {
    public let id: String
    public let moduleID: String?
    /// "Assignment", "Quiz", "Discussion", "Page", "File", "ExternalUrl", "SubHeader", ...
    public let type: String
    public let contentID: String?
    public let title: String
    /// `completion_requirement.type` ("must_view", "must_submit", "min_score", ...).
    public let completionRequirementType: String?
    /// `completion_requirement.completed`; nil when the item has no requirement.
    public let completionCompleted: Bool?
    public let dueAt: Date?
    public let unlockAt: Date?
    public let lockAt: Date?
    public let pointsPossible: Double?
    public let htmlURL: String?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        func key(_ s: String) -> AnyKey { AnyKey(stringValue: s)! }
        // An item with no id cannot be keyed anywhere; let the lossy list drop it.
        guard let id = c.flexString(key("id")) else {
            throw DecodingError.keyNotFound(key("id"), .init(codingPath: c.codingPath, debugDescription: "module item without id"))
        }
        self.id = id
        moduleID = c.flexString(key("module_id"))
        type = c.lenientString(key("type")) ?? ""
        contentID = c.flexString(key("content_id"))
        title = c.lenientString(key("title")) ?? ""
        htmlURL = c.lenientString(key("html_url"))
        if let req = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: key("completion_requirement")) {
            completionRequirementType = req.lenientString(key("type"))
            completionCompleted = req.lenientBool(key("completed"))
        } else {
            completionRequirementType = nil; completionCompleted = nil
        }
        if let details = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: key("content_details")) {
            dueAt = details.lenientDate(key("due_at"))
            unlockAt = details.lenientDate(key("unlock_at"))
            lockAt = details.lenientDate(key("lock_at"))
            pointsPossible = details.lenientDouble(key("points_possible"))
        } else {
            dueAt = nil; unlockAt = nil; lockAt = nil; pointsPossible = nil
        }
    }

    public init(
        id: String, moduleID: String? = nil, type: String, contentID: String? = nil, title: String,
        completionRequirementType: String? = nil, completionCompleted: Bool? = nil,
        dueAt: Date? = nil, unlockAt: Date? = nil, lockAt: Date? = nil, pointsPossible: Double? = nil,
        htmlURL: String? = nil
    ) {
        self.id = id; self.moduleID = moduleID; self.type = type; self.contentID = contentID
        self.title = title; self.completionRequirementType = completionRequirementType
        self.completionCompleted = completionCompleted; self.dueAt = dueAt; self.unlockAt = unlockAt
        self.lockAt = lockAt; self.pointsPossible = pointsPossible; self.htmlURL = htmlURL
    }
}

public struct CanvasStructuredModule: Decodable, Sendable, Hashable {
    public let id: String?
    public let name: String
    /// "locked", "unlocked", "started", "completed" (Canvas's per-student state).
    public let state: String?
    public let unlockAt: Date?
    public let position: Int?
    public let items: [CanvasStructuredModuleItem]
    /// Items present in the response that could not be read.
    public let droppedItemCount: Int

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        func key(_ s: String) -> AnyKey { AnyKey(stringValue: s)! }
        id = c.flexString(key("id"))
        name = c.lenientString(key("name")) ?? ""
        state = c.lenientString(key("state"))
        unlockAt = c.lenientDate(key("unlock_at"))
        position = c.lenientInt(key("position"))
        let lossy = (try? c.decodeIfPresent(LossyArray<CanvasStructuredModuleItem>.self, forKey: key("items"))) ?? nil
        items = lossy?.elements ?? []
        droppedItemCount = lossy?.droppedCount ?? 0
    }

    public init(id: String?, name: String, state: String? = nil, unlockAt: Date? = nil, position: Int? = nil,
                items: [CanvasStructuredModuleItem], droppedItemCount: Int = 0) {
        self.id = id; self.name = name; self.state = state; self.unlockAt = unlockAt
        self.position = position; self.items = items; self.droppedItemCount = droppedItemCount
    }
}

// MARK: - Assignments with overrides

public struct CanvasAssignmentDate: Decodable, Sendable, Hashable {
    public let dueAt: Date?
    /// True for the assignment's own (default) dates; false for a section or
    /// student override.
    public let base: Bool
    public let title: String?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        func key(_ s: String) -> AnyKey { AnyKey(stringValue: s)! }
        dueAt = c.lenientDate(key("due_at"))
        base = c.lenientBool(key("base")) ?? false
        title = c.lenientString(key("title"))
    }

    public init(dueAt: Date?, base: Bool, title: String? = nil) {
        self.dueAt = dueAt; self.base = base; self.title = title
    }
}

public struct CanvasAssignmentOverride: Decodable, Sendable, Hashable {
    public let id: String?
    public let dueAt: Date?
    public let title: String?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        func key(_ s: String) -> AnyKey { AnyKey(stringValue: s)! }
        id = c.flexString(key("id"))
        dueAt = c.lenientDate(key("due_at"))
        title = c.lenientString(key("title"))
    }

    public init(id: String?, dueAt: Date?, title: String? = nil) {
        self.id = id; self.dueAt = dueAt; self.title = title
    }
}

public struct CanvasOverrideAssignment: Decodable, Sendable, Hashable {
    public let id: String
    public let name: String
    public let dueAt: Date?
    public let allDates: [CanvasAssignmentDate]
    public let overrides: [CanvasAssignmentOverride]
    public let onlyVisibleToOverrides: Bool
    public let published: Bool?
    public let workflowState: String?
    public let submissionTypes: [String]
    public let htmlURL: String?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        func key(_ s: String) -> AnyKey { AnyKey(stringValue: s)! }
        guard let id = c.flexString(key("id")) else {
            throw DecodingError.keyNotFound(key("id"), .init(codingPath: c.codingPath, debugDescription: "assignment without id"))
        }
        self.id = id
        name = c.lenientString(key("name")) ?? ""
        dueAt = c.lenientDate(key("due_at"))
        allDates = c.lenientList(CanvasAssignmentDate.self, key("all_dates"))
        overrides = c.lenientList(CanvasAssignmentOverride.self, key("overrides"))
        onlyVisibleToOverrides = c.lenientBool(key("only_visible_to_overrides")) ?? false
        published = c.lenientBool(key("published"))
        workflowState = c.lenientString(key("workflow_state"))
        submissionTypes = c.lenientList(String.self, key("submission_types"))
        htmlURL = c.lenientString(key("html_url"))
    }

    public init(
        id: String, name: String = "", dueAt: Date? = nil, allDates: [CanvasAssignmentDate] = [],
        overrides: [CanvasAssignmentOverride] = [], onlyVisibleToOverrides: Bool = false,
        published: Bool? = nil, workflowState: String? = nil, submissionTypes: [String] = [], htmlURL: String? = nil
    ) {
        self.id = id; self.name = name; self.dueAt = dueAt; self.allDates = allDates
        self.overrides = overrides; self.onlyVisibleToOverrides = onlyVisibleToOverrides
        self.published = published; self.workflowState = workflowState
        self.submissionTypes = submissionTypes; self.htmlURL = htmlURL
    }

    /// Canvas will not show an unpublished or deleted assignment to a student,
    /// but the field is cheap to honour if one ever slips through.
    public var isLive: Bool {
        if published == false { return false }
        if let state = workflowState, state == "unpublished" || state == "deleted" { return false }
        return true
    }
}

// MARK: - Missing submissions

public struct CanvasMissingSubmission: Decodable, Sendable, Hashable {
    public let assignmentID: String
    public let courseID: String?
    public let name: String
    public let dueAt: Date?
    public let htmlURL: String?
    public let pointsPossible: Double?
    public let plannerMarkedComplete: Bool
    public let plannerDismissed: Bool

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        func key(_ s: String) -> AnyKey { AnyKey(stringValue: s)! }
        guard let id = c.flexString(key("id")) else {
            throw DecodingError.keyNotFound(key("id"), .init(codingPath: c.codingPath, debugDescription: "missing submission without id"))
        }
        assignmentID = id
        courseID = c.flexString(key("course_id"))
        name = c.lenientString(key("name")) ?? ""
        dueAt = c.lenientDate(key("due_at"))
        htmlURL = c.lenientString(key("html_url"))
        pointsPossible = c.lenientDouble(key("points_possible"))
        if let override = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: key("planner_override")) {
            plannerMarkedComplete = override.lenientBool(key("marked_complete")) ?? false
            plannerDismissed = override.lenientBool(key("dismissed")) ?? false
        } else {
            plannerMarkedComplete = false; plannerDismissed = false
        }
    }

    public init(assignmentID: String, courseID: String?, name: String = "", dueAt: Date? = nil,
                htmlURL: String? = nil, pointsPossible: Double? = nil,
                plannerMarkedComplete: Bool = false, plannerDismissed: Bool = false) {
        self.assignmentID = assignmentID; self.courseID = courseID; self.name = name; self.dueAt = dueAt
        self.htmlURL = htmlURL; self.pointsPossible = pointsPossible
        self.plannerMarkedComplete = plannerMarkedComplete; self.plannerDismissed = plannerDismissed
    }
}

// MARK: - Discussion topics and pages

public struct CanvasDiscussionTopic: Decodable, Sendable, Hashable {
    public let id: String
    public let title: String
    public let todoDate: Date?
    /// The nested graded-discussion assignment: its id lives in the
    /// *assignment* id space, unlike `id` above.
    public let assignmentID: String?
    public let assignmentDueAt: Date?
    public let published: Bool?
    public let htmlURL: String?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        func key(_ s: String) -> AnyKey { AnyKey(stringValue: s)! }
        guard let id = c.flexString(key("id")) else {
            throw DecodingError.keyNotFound(key("id"), .init(codingPath: c.codingPath, debugDescription: "topic without id"))
        }
        self.id = id
        title = c.lenientString(key("title")) ?? ""
        todoDate = c.lenientDate(key("todo_date"))
        published = c.lenientBool(key("published"))
        htmlURL = c.lenientString(key("html_url"))
        if let nested = try? c.nestedContainer(keyedBy: AnyKey.self, forKey: key("assignment")) {
            assignmentID = nested.flexString(key("id"))
            assignmentDueAt = nested.lenientDate(key("due_at"))
        } else {
            assignmentID = nil; assignmentDueAt = nil
        }
    }

    public init(id: String, title: String = "", todoDate: Date? = nil, assignmentID: String? = nil,
                assignmentDueAt: Date? = nil, published: Bool? = nil, htmlURL: String? = nil) {
        self.id = id; self.title = title; self.todoDate = todoDate; self.assignmentID = assignmentID
        self.assignmentDueAt = assignmentDueAt; self.published = published; self.htmlURL = htmlURL
    }
}

public struct CanvasStructuredPage: Decodable, Sendable, Hashable {
    /// The page slug, which is Canvas's page identifier.
    public let url: String
    public let title: String
    /// Canvas documents `todo_date`; some versions report `student_todo_at`.
    public let todoDate: Date?
    public let published: Bool?
    public let updatedAt: Date?
    public let htmlURL: String?

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: AnyKey.self)
        func key(_ s: String) -> AnyKey { AnyKey(stringValue: s)! }
        guard let url = c.lenientString(key("url")), !url.isEmpty else {
            throw DecodingError.keyNotFound(key("url"), .init(codingPath: c.codingPath, debugDescription: "page without url"))
        }
        self.url = url
        title = c.lenientString(key("title")) ?? ""
        todoDate = c.lenientDate(key("todo_date")) ?? c.lenientDate(key("student_todo_at"))
        published = c.lenientBool(key("published"))
        updatedAt = c.lenientDate(key("updated_at"))
        htmlURL = c.lenientString(key("html_url"))
    }

    public init(url: String, title: String = "", todoDate: Date? = nil, published: Bool? = nil,
                updatedAt: Date? = nil, htmlURL: String? = nil) {
        self.url = url; self.title = title; self.todoDate = todoDate; self.published = published
        self.updatedAt = updatedAt; self.htmlURL = htmlURL
    }
}

// MARK: - Page-level decoding (pure, shared with tests)

public enum CanvasStructuredDecoding {
    /// Decodes pages of one endpoint into a flat list, counting what could not
    /// be read (a bad element, or a whole page that is not a JSON list).
    public static func decode<T: Decodable>(_ type: T.Type, fromPages pages: [Data]) -> (elements: [T], dropped: Int) {
        let decoder = JSONDecoder()
        var out: [T] = []
        var dropped = 0
        for page in pages {
            let stripped = CanvasGradesClient.stripXSSIPrefix(page)
            // The planner and missing-submissions endpoints wrap nothing, but
            // `missing_submissions` has been seen as a bare list only; a
            // non-list page is counted once and skipped.
            guard let list = try? decoder.decode(LossyArray<T>.self, from: stripped) else {
                dropped += 1
                continue
            }
            out.append(contentsOf: list.elements)
            dropped += list.droppedCount
        }
        return (out, dropped)
    }

    public static func modules(fromPages pages: [Data]) -> (elements: [CanvasStructuredModule], dropped: Int) {
        var result = decode(CanvasStructuredModule.self, fromPages: pages)
        result.dropped += result.elements.reduce(0) { $0 + $1.droppedItemCount }
        return result
    }
}
