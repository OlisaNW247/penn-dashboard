import Foundation

/// Recognizes two kinds of Canvas item that the raw feed cannot tell apart
/// from ordinary graded work, but that a `GradeCategoryMap` needs to handle
/// specially: attendance-tool entries (which usually land in whatever group
/// happened to be first in the course, not a category that means anything)
/// and zero-point placeholders (a Canvas quiz created but never scored, which
/// is not "posted work" in any sense that should count toward the math).
///
/// Nothing here is a heuristic in the fuzzy-matching sense — every rule is a
/// simple, explainable check a student could verify themselves by looking at
/// the item, which matters because `autoAssignments` below acts on these
/// classifications without asking first.
public enum GradeItemClassifier {
    /// Canvas's own "Roll Call Attendance" / "Attendance" tool creates one
    /// assignment per course, almost always inside whatever group the
    /// professor left as the default, with a name that says what it is and,
    /// when Canvas reports it, a `submission_types` of `["attendance"]`.
    /// Matching on name is the more reliable signal in practice — the
    /// `attendance` submission type is a newer field and not every Canvas
    /// instance's API surfaces it — so either one is sufficient.
    public static func isAttendanceItem(_ item: GradeItem) -> Bool {
        if let types = item.submissionTypes, types.contains("attendance") {
            return true
        }
        return isAttendanceLikeName(item.name)
    }

    /// A Canvas item that exists (it has a row) but carries no points and no
    /// score — a quiz shell created for a future date, or a placeholder the
    /// professor hasn't filled in yet. `pointsPossible == 0` alone would also
    /// catch legitimate extra-credit items, which DO carry a score once
    /// they're graded; requiring `score == nil` too is what tells the two
    /// apart. (An extra-credit item that's been scored is handled by the
    /// engine's existing zero-possible-divides-nothing rule, untouched here.)
    public static func isPlaceholder(_ item: GradeItem) -> Bool {
        item.pointsPossible == 0 && item.score == nil
    }

    /// Whether a CATEGORY name (syllabus or Canvas group) itself means
    /// attendance/participation — distinct from `isAttendanceItem`, which
    /// asks the same question about one assignment.
    public static func isAttendanceCategoryName(_ name: String) -> Bool {
        name.range(of: #"(?i)\b(attendance|participation)\b"#, options: .regularExpression) != nil
    }

    private static func isAttendanceLikeName(_ name: String) -> Bool {
        name.range(of: #"(?i)\b(attendance|roll call|participation)\b"#, options: .regularExpression) != nil
    }

    /// Additions a map should make automatically, before anything the student
    /// or syllabus stated is applied: route attendance items to whichever map
    /// category is named for attendance/participation (there's rarely more
    /// than one, so the first is taken), or exclude them with a reason when
    /// the map has no such category to route them to; exclude placeholders
    /// outright, since a zero-point unscored item has nothing to contribute
    /// either way.
    ///
    /// Deliberately blind to `map.excludedItemIDs`/`itemAssignments` already
    /// present — this only ever ADDS entries for items neither one already
    /// covers, so calling it twice (or after a student has already made their
    /// own edit to the same item) never clobbers a prior decision. Callers
    /// that want the auto-assignments merged into a map do that themselves
    /// (`GradeCategoryMapBuilder.suggested`).
    public static func autoAssignments(
        canvasCategories: [GradeCategory],
        map: GradeCategoryMap
    ) -> (itemAssignments: [String: String], excludedItemIDs: Set<String>, reasons: [String: String]) {
        var itemAssignments: [String: String] = [:]
        var excludedItemIDs: Set<String> = []
        var reasons: [String: String] = [:]

        let attendanceCategoryID = map.categories.first { isAttendanceCategoryName($0.name) }?.id

        for category in canvasCategories {
            for item in category.items {
                if map.itemAssignments[item.id] != nil || map.excludedItemIDs.contains(item.id) {
                    continue
                }

                if isAttendanceItem(item) {
                    if let attendanceCategoryID {
                        itemAssignments[item.id] = attendanceCategoryID
                    } else {
                        excludedItemIDs.insert(item.id)
                        reasons[item.id] = "attendance tool item, no attendance category"
                    }
                    continue
                }

                if isPlaceholder(item) {
                    excludedItemIDs.insert(item.id)
                    reasons[item.id] = "zero-point placeholder"
                }
            }
        }

        return (itemAssignments, excludedItemIDs, reasons)
    }
}
