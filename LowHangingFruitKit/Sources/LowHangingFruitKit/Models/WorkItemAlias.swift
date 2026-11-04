import Foundation

/// One name a work item is known by, in one source's id space.
///
/// The same Canvas assignment arrives as an ICS UID, as a module item's
/// `content_id`, as a planner item's `plannable_id`, and (when it is a quiz)
/// under a quiz id that is a DIFFERENT number from its assignment id. Those
/// are all true names for one thing, but only when the id space is the same:
/// comparing a module item id (a wrapper object) with an assignment id is
/// the "coincidental digit names someone else's submission" bug that
/// `Assignment.canvasAssignmentID` already documents. So an alias carries its
/// space, and two aliases are equal only inside one space.
///
/// `canonical` folds the spellings that are provably the same space: a module
/// item whose content type is Assignment, and a planner item whose plannable
/// type is assignment, are Canvas assignment ids. Nothing else is folded. The
/// wrong fix would be comparing raw digit strings across cases, which is how
/// a module item id 4812 would "match" assignment 4812.
public enum WorkItemAlias: Sendable, Hashable, Codable {
    case canvasAssignment(String)
    case canvasQuiz(String)
    case moduleItem(String)
    /// `content_id` plus Canvas's module item `type` ("Assignment", "Quiz", ...).
    case moduleContent(type: String, id: String)
    case gradescopeAssignment(String)
    case discussionTopic(String)
    /// Planner `plannable_type` ("assignment", "quiz", "discussion_topic", ...) plus id.
    case planner(type: String, id: String)
    case mapItem(String)
    case fact(String)
    case feedUID(String)

    /// The alias with equivalent spellings folded into one case, so a plain
    /// `==` on canonical values is the Tier 1 test.
    public var canonical: WorkItemAlias {
        switch self {
        case let .moduleContent(type, id), let .planner(type, id):
            switch type.lowercased() {
            case "assignment": return .canvasAssignment(id)
            case "quiz": return .canvasQuiz(id)
            case "discussion", "discussiontopic", "discussion_topic": return .discussionTopic(id)
            default: return self
            }
        default:
            return self
        }
    }

    /// Set when this is a Canvas assignment id, the only space the hard
    /// "different ids never merge" rule is stated over.
    public var canvasAssignmentID: String? {
        if case let .canvasAssignment(id) = canonical { return id }
        return nil
    }

    // MARK: Stable string form

    /// `space:value` (`type` and `id` joined by `/` for the two typed cases).
    /// Persisted, so the prefixes are frozen; ids never contain `:` in the
    /// first segment because only the first colon splits.
    public var stableString: String {
        switch self {
        case let .canvasAssignment(id): return "canvas-assignment:\(id)"
        case let .canvasQuiz(id): return "canvas-quiz:\(id)"
        case let .moduleItem(id): return "module-item:\(id)"
        case let .moduleContent(type, id): return "module-content:\(type)/\(id)"
        case let .gradescopeAssignment(id): return "gradescope-assignment:\(id)"
        case let .discussionTopic(id): return "discussion-topic:\(id)"
        case let .planner(type, id): return "planner:\(type)/\(id)"
        case let .mapItem(id): return "map-item:\(id)"
        case let .fact(id): return "fact:\(id)"
        case let .feedUID(uid): return "feed-uid:\(uid)"
        }
    }

    public init?(stableString: String) {
        guard let colon = stableString.firstIndex(of: ":") else { return nil }
        let space = String(stableString[..<colon])
        let value = String(stableString[stableString.index(after: colon)...])
        guard !value.isEmpty else { return nil }
        func typed() -> (String, String)? {
            guard let slash = value.firstIndex(of: "/") else { return nil }
            let type = String(value[..<slash])
            let id = String(value[value.index(after: slash)...])
            return type.isEmpty || id.isEmpty ? nil : (type, id)
        }
        switch space {
        case "canvas-assignment": self = .canvasAssignment(value)
        case "canvas-quiz": self = .canvasQuiz(value)
        case "module-item": self = .moduleItem(value)
        case "module-content":
            guard let (t, i) = typed() else { return nil }
            self = .moduleContent(type: t, id: i)
        case "gradescope-assignment": self = .gradescopeAssignment(value)
        case "discussion-topic": self = .discussionTopic(value)
        case "planner":
            guard let (t, i) = typed() else { return nil }
            self = .planner(type: t, id: i)
        case "map-item": self = .mapItem(value)
        case "fact": self = .fact(value)
        case "feed-uid": self = .feedUID(value)
        default: return nil
        }
    }

    public init(from decoder: Decoder) throws {
        let raw = try decoder.singleValueContainer().decode(String.self)
        guard let alias = WorkItemAlias(stableString: raw) else {
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath,
                debugDescription: "Unrecognised work item alias \(raw)"
            ))
        }
        self = alias
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(stableString)
    }
}
