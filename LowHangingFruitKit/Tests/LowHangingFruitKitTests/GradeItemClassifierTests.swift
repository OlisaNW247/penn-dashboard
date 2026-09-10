import Foundation
import Testing
@testable import LowHangingFruitKit

/// Coverage for `GradeItemClassifier` — the two recognizers a
/// `GradeCategoryMap` needs (attendance items, zero-point placeholders) and
/// the automatic assignments built from them. The PHYS 0151 real-phone
/// report (docs/grades.md §14 addendum, 2026-09-10) is what motivated all of
/// this: a "Roll Call Attendance" item sitting inside "Problem Sets", and a
/// zero-point "Quiz 2" placeholder inflating a posted-work denominator.
@Suite("Grade item classifier")
struct GradeItemClassifierTests {

    private func item(
        _ id: String = "i",
        name: String,
        points: Double = 10,
        score: Double? = nil,
        submissionTypes: [String]? = nil
    ) -> GradeItem {
        GradeItem(id: id, name: name, pointsPossible: points, score: score, submissionTypes: submissionTypes)
    }

    // MARK: - isAttendanceItem

    @Test("recognizes attendance items by name")
    func attendanceByName() {
        #expect(GradeItemClassifier.isAttendanceItem(item(name: "Roll Call Attendance", score: 100)))
        #expect(GradeItemClassifier.isAttendanceItem(item(name: "Attendance", score: 100)))
        #expect(GradeItemClassifier.isAttendanceItem(item(name: "Class Participation", score: 100)))
        #expect(GradeItemClassifier.isAttendanceItem(item(name: "roll call - week 3", score: 5)))
    }

    @Test("recognizes attendance items by submission type even with an unrelated name")
    func attendanceBySubmissionType() {
        #expect(GradeItemClassifier.isAttendanceItem(item(name: "Week 3", submissionTypes: ["attendance"])))
    }

    @Test("an ordinary graded item is not mistaken for attendance")
    func notAttendance() {
        #expect(!GradeItemClassifier.isAttendanceItem(item(name: "Problem Set 1", score: 9)))
        #expect(!GradeItemClassifier.isAttendanceItem(item(name: "Imported Assignments", submissionTypes: ["online_upload"])))
    }

    // MARK: - isPlaceholder

    @Test("a zero-point unscored item is a placeholder")
    func placeholderDetected() {
        #expect(GradeItemClassifier.isPlaceholder(item(name: "Quiz 2", points: 0, score: nil)))
    }

    @Test("a zero-point item that HAS been scored is extra credit, not a placeholder")
    func scoredZeroPointIsNotPlaceholder() {
        #expect(!GradeItemClassifier.isPlaceholder(item(name: "Bonus", points: 0, score: 5)))
    }

    @Test("a normal points-bearing unscored item is not a placeholder")
    func normalUnscoredIsNotPlaceholder() {
        #expect(!GradeItemClassifier.isPlaceholder(item(name: "Problem Set 2", points: 10, score: nil)))
    }

    // MARK: - isAttendanceCategoryName

    @Test("category names read as attendance/participation, case-insensitively")
    func attendanceCategoryName() {
        #expect(GradeItemClassifier.isAttendanceCategoryName("Attendance"))
        #expect(GradeItemClassifier.isAttendanceCategoryName("attendance/participation"))
        #expect(GradeItemClassifier.isAttendanceCategoryName("PARTICIPATION"))
        #expect(!GradeItemClassifier.isAttendanceCategoryName("Problem Sets"))
    }

    // MARK: - autoAssignments

    private func canvasCategories() -> [GradeCategory] {
        [
            GradeCategory(id: "g-pset", name: "Problem Sets", items: [
                item("rollcall", name: "Roll Call Attendance", points: 100, score: 100),
                item("ps1", name: "Problem Set 1", points: 10, score: 9),
            ]),
            GradeCategory(id: "g-quiz", name: "Quizzes", items: [
                item("quiz1", name: "Quiz 1", points: 10, score: 8),
                item("quiz2", name: "Quiz 2", points: 0, score: nil),
            ]),
        ]
    }

    @Test("with an attendance category present: the attendance item is assigned there, the placeholder is excluded")
    func autoAssignmentsWithAttendanceCategory() {
        let map = GradeCategoryMap(categories: [
            .init(id: "map:attendance", name: "Attendance/Participation", weightPercent: 10),
        ])
        let result = GradeItemClassifier.autoAssignments(canvasCategories: canvasCategories(), map: map)

        #expect(result.itemAssignments["rollcall"] == "map:attendance")
        #expect(result.excludedItemIDs == ["quiz2"])
        #expect(result.reasons["quiz2"] == "zero-point placeholder")
        // Ordinary graded items are untouched.
        #expect(result.itemAssignments["ps1"] == nil)
        #expect(result.itemAssignments["quiz1"] == nil)
    }

    @Test("with no attendance category: the attendance item is excluded with a reason instead of being assigned")
    func autoAssignmentsWithoutAttendanceCategory() {
        let map = GradeCategoryMap(categories: [
            .init(id: "map:hw", name: "HomeWorks", weightPercent: 10, canvasGroupIDs: ["g-pset"]),
        ])
        let result = GradeItemClassifier.autoAssignments(canvasCategories: canvasCategories(), map: map)

        #expect(result.itemAssignments["rollcall"] == nil)
        #expect(result.excludedItemIDs.contains("rollcall"))
        #expect(result.reasons["rollcall"] == "attendance tool item, no attendance category")
        #expect(result.excludedItemIDs.contains("quiz2"))
    }

    @Test("never overwrites an item the map already assigned or excluded")
    func autoAssignmentsNeverOverwritesExisting() {
        var map = GradeCategoryMap(categories: [
            .init(id: "map:attendance", name: "Attendance/Participation", weightPercent: 10),
            .init(id: "map:hw", name: "HomeWorks", weightPercent: 10, canvasGroupIDs: ["g-pset"]),
        ])
        // The student already excluded the roll call item themselves.
        map.excludedItemIDs.insert("rollcall")

        let result = GradeItemClassifier.autoAssignments(canvasCategories: canvasCategories(), map: map)
        #expect(result.itemAssignments["rollcall"] == nil)
        #expect(!result.excludedItemIDs.contains("rollcall")) // not re-added; it's the caller's existing entry
    }
}
