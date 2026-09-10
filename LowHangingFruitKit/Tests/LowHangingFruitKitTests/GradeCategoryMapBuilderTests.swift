import Foundation
import Testing
@testable import LowHangingFruitKit

/// End-to-end coverage for `GradeCategoryMapBuilder.suggested`, built from the
/// exact real-phone PHYS 0151 report (docs/grades.md §14 addendum,
/// 2026-09-10): Canvas assignment groups Quizzes / Problem Sets / Worksheets
/// / Midterm 1 / Midterm 2 / Final / Imported Assignments; a syllabus
/// promising Quizzes 15, Midterm 1 15, Midterm 2 15, Midterm 3 15, Final 20,
/// HomeWorks 10, Attendance/Participation 10; a "Roll Call Attendance" item
/// (100/100, Canvas's own attendance tool) sitting inside Problem Sets; and a
/// zero-point "Quiz 2" placeholder.
@Suite("Grade category map builder — PHYS 0151 fixture")
struct GradeCategoryMapBuilderTests {

    private func item(_ id: String, points: Double, score: Double? = nil, name: String? = nil) -> GradeItem {
        GradeItem(id: id, name: name ?? id, pointsPossible: points, score: score)
    }

    /// The course exactly as Canvas reports it: seven assignment groups, no
    /// items yet in the three exam groups or "Imported Assignments" (early
    /// in the term), a Roll Call attendance item buried in Problem Sets, and
    /// a zero-point Quiz 2 placeholder. Posted points sum to 160 -- the exact
    /// number behind the real phone's "62% decided."
    private func canvasCategories() -> [GradeCategory] {
        [
            GradeCategory(id: "g-quiz", name: "Quizzes", items: [
                item("quiz1", points: 10, name: "Quiz 1"),
                item("quiz3", points: 10, name: "Quiz 3"),
                item("quiz2", points: 0, name: "Quiz 2"),
            ]),
            GradeCategory(id: "g-pset", name: "Problem Sets", items: [
                item("ps1", points: 10, name: "Problem Set 1"),
                item("ps2", points: 10, name: "Problem Set 2"),
                item("rollcall", points: 100, score: 100, name: "Roll Call Attendance"),
            ]),
            GradeCategory(id: "g-work", name: "Worksheets", items: [
                item("w1", points: 5, name: "Worksheet 1"),
                item("w2", points: 5, name: "Worksheet 2"),
                item("w31", points: 5, name: "Worksheet 3.1"),
                item("w32", points: 5, name: "Worksheet 3.2"),
            ]),
            GradeCategory(id: "g-mid1", name: "Midterm 1", items: []),
            GradeCategory(id: "g-mid2", name: "Midterm 2", items: []),
            GradeCategory(id: "g-final", name: "Final", items: []),
            GradeCategory(id: "g-imported", name: "Imported Assignments", items: []),
        ]
    }

    private func syllabusScheme() -> SyllabusGradingScheme {
        let pairs: [(String, Double)] = [
            ("Quizzes", 15), ("Midterm 1", 15), ("Midterm 2", 15), ("Midterm 3", 15),
            ("Final", 20), ("HomeWorks", 10), ("Attendance/Participation", 10),
        ]
        let categories = pairs.map { name, weight in
            SyllabusCategory(id: TitleNormalizer.categoryKey(name), name: name, weightPercent: weight)
        }
        return SyllabusGradingScheme(categories: categories, confidence: .high, rawWeightSum: 100)
    }

    private func builtMap() -> GradeCategoryMap {
        let scheme = syllabusScheme()
        let canvas = canvasCategories()
        let match = SyllabusMatcher.match(scheme: scheme, canvasCategories: canvas)
        return GradeCategoryMapBuilder.suggested(
            scheme: scheme, match: match, canvasCategories: canvas, provenance: .syllabus
        )!
    }

    @Test("nil when there's no scheme to build from")
    func nilWithoutScheme() {
        let map = GradeCategoryMapBuilder.suggested(
            scheme: nil, match: nil, canvasCategories: canvasCategories(), provenance: .syllabus
        )
        #expect(map == nil)
    }

    @Test("one map category per syllabus category — seven, matching the syllabus, not Canvas's seven groups by coincidence")
    func oneCategoryPerSyllabusCategory() {
        let map = builtMap()
        #expect(map.categories.count == 7)
        #expect(Set(map.categories.map(\.name)) == [
            "Quizzes", "Midterm 1", "Midterm 2", "Midterm 3", "Final", "HomeWorks", "Attendance/Participation",
        ])
    }

    @Test("HomeWorks folds Problem Sets AND Worksheets — the many-to-one fold")
    func homeworksFoldsTwoGroups() {
        let map = builtMap()
        let hw = map.categories.first { $0.name == "HomeWorks" }
        #expect(Set(hw?.canvasGroupIDs ?? []) == ["g-pset", "g-work"])
        #expect(hw?.expectedCount == nil) // no exam-like default, nothing stated
    }

    @Test("Quizzes, Midterm 1, Midterm 2 and Final each fold their own identically-named Canvas group one-to-one")
    func plainCategoriesFoldOneToOne() {
        let map = builtMap()
        func groupIDs(_ name: String) -> [String] { map.categories.first { $0.name == name }?.canvasGroupIDs ?? [] }
        #expect(groupIDs("Quizzes") == ["g-quiz"])
        #expect(groupIDs("Midterm 1") == ["g-mid1"])
        #expect(groupIDs("Midterm 2") == ["g-mid2"])
        #expect(groupIDs("Final") == ["g-final"])
        // Every singular exam-like name defaults to an expected count of 1.
        #expect(map.categories.first { $0.name == "Midterm 1" }?.expectedCount == 1)
        #expect(map.categories.first { $0.name == "Final" }?.expectedCount == 1)
    }

    @Test("Midterm 3 has no Canvas group yet but is still emitted, with the singular-exam default of 1")
    func midterm3EmptyWithDefaultExpectedCount() {
        let map = builtMap()
        let mid3 = map.categories.first { $0.name == "Midterm 3" }
        #expect(mid3?.canvasGroupIDs.isEmpty == true)
        #expect(mid3?.expectedCount == 1)
    }

    @Test("Attendance/Participation gets the Roll Call item via itemAssignments, not a Canvas group fold")
    func attendanceGetsItemNotGroup() {
        let map = builtMap()
        let attendance = map.categories.first { $0.name == "Attendance/Participation" }
        #expect(attendance?.canvasGroupIDs.isEmpty == true) // no Canvas GROUP is named for it
        #expect(attendance?.expectedCount == 1) // attendance categories default to 1 too
        #expect(map.itemAssignments["rollcall"] == attendance?.id)
    }

    @Test("Quiz 2's zero-point placeholder is excluded with a reason")
    func placeholderExcluded() {
        let map = builtMap()
        #expect(map.excludedItemIDs.contains("quiz2"))
        #expect(map.exclusionReasons["quiz2"] == "zero-point placeholder")
    }

    @Test("Imported Assignments has no syllabus counterpart and stays unmapped once regrouped")
    func importedAssignmentsUnmapped() {
        let map = builtMap()
        let output = GradeRegrouper.apply(map, to: canvasCategories())
        #expect(output.unmappedGroupIDs == ["g-imported"])
    }
}
