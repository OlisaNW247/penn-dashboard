import Foundation

/// What matching needs to know about one work item: every name it is known
/// by, plus its title and due date for the weaker tiers.
///
/// Built from an `Assignment` (`from(_:)`) or, for the structured sources that
/// are not `Assignment` rows yet (module items, planner items, map items,
/// facts), by passing aliases directly. Pure value, no clock, no storage.
public struct WorkItemIdentity: Sendable, Hashable, Codable {
    /// A caller-chosen handle (for an `Assignment`, its `id`). Tier 3 resolves
    /// a model's `target` against this and against the aliases.
    public let ref: String
    public let aliases: Set<WorkItemAlias>
    public let title: String
    public let dueAt: Date?
    public let course: String?

    public init(ref: String, aliases: Set<WorkItemAlias>, title: String, dueAt: Date?, course: String? = nil) {
        self.ref = ref
        self.aliases = aliases
        self.title = title
        self.dueAt = dueAt
        self.course = course
    }

    /// Aliases folded to canonical form; the set Tier 1 intersects.
    public var canonicalAliases: Set<WorkItemAlias> { Set(aliases.map(\.canonical)) }

    /// Every distinct Canvas assignment id this item is known by. More than
    /// one means the item contradicts itself, which the matcher treats as
    /// "no opinion" rather than guessing which is right.
    public var canvasAssignmentIDs: Set<String> {
        Set(aliases.compactMap(\.canvasAssignmentID))
    }

    /// Derives aliases from what an `Assignment` already carries. Each rule
    /// mirrors the id-space caveats in `Assignment.canvasAssignmentID`:
    /// a `.canvasModules` row's sourceID is a module ITEM id and is recorded
    /// as one, never as an assignment id; the assignment id comes only from
    /// the URL for that source.
    public static func from(_ assignment: Assignment) -> WorkItemIdentity {
        var aliases: Set<WorkItemAlias> = []
        if let id = assignment.canvasAssignmentID {
            aliases.insert(.canvasAssignment(id))
        }
        let sourceID = assignment.sourceID
        switch assignment.source {
        case .canvas:
            aliases.insert(.feedUID(sourceID))
        case .canvasModules:
            if let id = trailingDigits(of: sourceID, after: "module-item-") {
                aliases.insert(.moduleItem(id))
            }
        case .gradescope:
            aliases.insert(.gradescopeAssignment(gradescopeKey(sourceID)))
        case .canvasAnnouncement, .canvasSuggestion, .manual:
            break
        }
        return WorkItemIdentity(
            ref: assignment.id,
            aliases: aliases,
            title: assignment.title,
            dueAt: assignment.dueAt,
            course: assignment.course
        )
    }

    /// Gradescope sourceIDs look like `course-<c>-assignment-<a>`. Assignment
    /// ids are unique per course only in practice, so the course stays in the
    /// key; an unrecognised shape is kept whole rather than guessed at.
    private static func gradescopeKey(_ sourceID: String) -> String {
        let parts = sourceID.split(separator: "-")
        if parts.count == 4, parts[0] == "course", parts[2] == "assignment" {
            return "\(parts[1])/\(parts[3])"
        }
        return sourceID
    }

    private static func trailingDigits(of sourceID: String, after prefix: String) -> String? {
        guard sourceID.hasPrefix(prefix) else { return nil }
        let rest = sourceID.dropFirst(prefix.count)
        return !rest.isEmpty && rest.allSatisfy(\.isNumber) ? String(rest) : nil
    }
}
