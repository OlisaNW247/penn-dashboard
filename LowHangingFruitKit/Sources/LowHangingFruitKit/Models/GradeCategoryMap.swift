import Foundation

/// A student-facing (or syllabus-derived) restatement of a course's grading
/// categories, independent of however Canvas happened to bucket its
/// assignment groups.
///
/// The gap this closes: Canvas's assignment groups are an administrative
/// artifact of how a professor set up the site, not a statement of what the
/// syllabus actually weighs. A real PHYS 0151 lecture site split one syllabus
/// category ("HomeWorks", 10% of the grade) across two Canvas groups
/// ("Problem Sets" and "Worksheets"), buried an unrelated 100-point
/// "Roll Call Attendance" item from Canvas's own attendance tool inside
/// "Problem Sets", and carried a zero-point placeholder quiz with no score.
/// Feeding that straight to `GradeEngine` in points mode divides the
/// attendance item's 100 points by whatever else happens to be posted and
/// calls it 62% — an answer that is arithmetically correct and substantively
/// dishonest. `GradeCategoryMap` is the layer that says, once, "these Canvas
/// groups are really one category," "this item doesn't belong to any
/// category," and "ignore this placeholder," so the engine only ever sees
/// the corrected picture (via `GradeRegrouper`).
public struct GradeCategoryMap: Sendable, Hashable, Codable {
    /// Who produced this map — shown next to every weight so the student can
    /// tell "read off your syllabus" from "you typed this in," same spirit as
    /// `ScoreSource`/`GradingModeSource` elsewhere in Grade Watcher.
    public enum Provenance: String, Sendable, Hashable, Codable {
        /// Mirrors Canvas's own assignment groups one-to-one — the map exists
        /// only so a course with no syllabus still goes through one code path.
        case canvas
        /// Built from a parsed or server-extracted syllabus grading scheme.
        case syllabus
        /// Built from the backend's pooled `CourseGradingProfile`, shared
        /// across everyone enrolled rather than parsed fresh on this device.
        case sharedProfile
        /// The student edited the map by hand (moved an item, renamed a
        /// category, changed a weight).
        case student
    }

    /// One category as the student/syllabus states it — the unit
    /// `GradeRegrouper` folds Canvas groups and items into.
    public struct Category: Sendable, Hashable, Codable, Identifiable {
        /// Stable id, conventionally `"map:" + GradeCategoryMap.slug(name)`
        /// (callers building a category are expected to compute it that way;
        /// it isn't derived automatically here so a caller can also keep an
        /// existing id across a rename). Prefixed so a map category's id can
        /// never collide with a raw Canvas assignment-group id if the two
        /// ever end up in the same lookup table. Matches the pattern
        /// `SyllabusCategory.id` already uses for the same reason (confirmed
        /// mappings must survive a re-import).
        public let id: String
        public var name: String
        public var weightPercent: Double
        /// Whole-semester expected item count, same meaning as
        /// `GradeEngine.Input.expectedCounts` but living on the map so a
        /// syllabus-derived default (`GradeCategoryMapBuilder
        /// .defaultExpectedCount`) travels with the category instead of
        /// needing a second lookup table.
        public var expectedCount: Int?
        public var dropLowest: Int
        /// Canvas assignment-group ids folded into this one category — the
        /// many-to-one fold that is this type's whole reason to exist.
        public var canvasGroupIDs: [String]
        public var provenance: Provenance

        public init(
            id: String,
            name: String,
            weightPercent: Double,
            expectedCount: Int? = nil,
            dropLowest: Int = 0,
            canvasGroupIDs: [String] = [],
            provenance: Provenance = .syllabus
        ) {
            self.id = id
            self.name = name
            self.weightPercent = weightPercent
            self.expectedCount = expectedCount
            self.dropLowest = dropLowest
            self.canvasGroupIDs = canvasGroupIDs
            self.provenance = provenance
        }
    }

    public var categories: [Category]
    /// Canvas item id → category id. Exceptions to plain group membership —
    /// today, the only producer of these is `GradeItemClassifier
    /// .autoAssignments` routing a Canvas attendance-tool item (which usually
    /// sits inside some unrelated group like "Problem Sets") to whichever
    /// category is actually named for attendance/participation.
    public var itemAssignments: [String: String]
    /// Items removed from all math by this map — Canvas placeholders with no
    /// points and no score, or an attendance item when the map has nowhere
    /// to put it. Distinct from `GradeItemOverride.isExcluded`: that is the
    /// STUDENT overriding one item; this is the map's own classification,
    /// and is expected to change automatically as Canvas's data changes
    /// (e.g. once the placeholder quiz gets a real score, it stops being a
    /// placeholder and a re-suggested map won't exclude it).
    public var excludedItemIDs: Set<String>
    /// Item id → a short, lowercase, human-readable reason, shown next to the
    /// exclusion in the explanation panel so "why is this missing" always has
    /// an answer on screen rather than requiring a trip to Canvas.
    public var exclusionReasons: [String: String]
    /// How the map as a whole was produced. A category can in principle carry
    /// its own more specific provenance in the future, but today the whole
    /// map is built (and re-suggested) in one pass, so one value covers it.
    public var provenance: Provenance

    public init(
        categories: [Category] = [],
        itemAssignments: [String: String] = [:],
        excludedItemIDs: Set<String> = [],
        exclusionReasons: [String: String] = [:],
        provenance: Provenance = .canvas
    ) {
        self.categories = categories
        self.itemAssignments = itemAssignments
        self.excludedItemIDs = excludedItemIDs
        self.exclusionReasons = exclusionReasons
        self.provenance = provenance
    }

    /// Lowercase, alnum runs joined by `-` — e.g. `"HomeWorks"` → `"homeworks"`,
    /// `"Attendance/Participation"` → `"attendance-participation"`. Used to
    /// build `Category.id` so it stays stable and readable across re-imports
    /// without leaking punctuation into an identifier.
    public static func slug(_ name: String) -> String {
        let lowered = name.lowercased()
        var runs: [String] = []
        var current = ""
        for scalar in lowered.unicodeScalars {
            if CharacterSet.alphanumerics.contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                runs.append(current)
                current = ""
            }
        }
        if !current.isEmpty { runs.append(current) }
        return runs.joined(separator: "-")
    }

    public func category(forGroupID groupID: String) -> Category? {
        categories.first { $0.canvasGroupIDs.contains(groupID) }
    }

    /// Resolves an item to its map category. `itemAssignments` is the
    /// exception list and always wins; failing that, the item's own Canvas
    /// group decides — which is why this needs the group id as a second
    /// parameter rather than just the item id.
    public func category(forItemID itemID: String, inGroupID groupID: String) -> Category? {
        if let assignedID = itemAssignments[itemID] {
            return categories.first { $0.id == assignedID }
        }
        return category(forGroupID: groupID)
    }
}
