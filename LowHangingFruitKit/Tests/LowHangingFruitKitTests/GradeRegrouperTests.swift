import Foundation
import Testing
@testable import LowHangingFruitKit

/// Coverage for `GradeRegrouper.apply` — the many-to-one fold, item-level
/// moves, exclusions, and the "nothing Canvas reported ever disappears"
/// guarantee (an unmapped group survives as its own zero-weight category
/// rather than being dropped).
@Suite("Grade regrouper")
struct GradeRegrouperTests {

    private func item(_ id: String, points: Double = 10, score: Double? = nil) -> GradeItem {
        GradeItem(id: id, name: id, pointsPossible: points, score: score)
    }

    @Test("many-to-one: two Canvas groups fold into one map category, preserving item order")
    func manyToOneFold() {
        let canvasCategories = [
            GradeCategory(id: "g-pset", name: "Problem Sets", items: [item("a"), item("b")]),
            GradeCategory(id: "g-work", name: "Worksheets", items: [item("c")]),
        ]
        let map = GradeCategoryMap(categories: [
            .init(id: "map:hw", name: "HomeWorks", weightPercent: 10, canvasGroupIDs: ["g-pset", "g-work"]),
        ])

        let output = GradeRegrouper.apply(map, to: canvasCategories)

        #expect(output.categories.count == 1)
        let hw = output.categories.first!
        #expect(hw.id == "map:hw")
        #expect(hw.weight == 10)
        #expect(hw.items.map(\.id) == ["a", "b", "c"])
        #expect(output.groupNamesByCategoryID["map:hw"] == ["Problem Sets", "Worksheets"])
        #expect(output.unmappedGroupIDs.isEmpty)
    }

    @Test("an item assignment moves an item into a different category than its own group's fold")
    func itemAssignmentMovesItem() {
        let canvasCategories = [
            GradeCategory(id: "g-pset", name: "Problem Sets", items: [item("rollcall", points: 100, score: 100), item("ps1")]),
        ]
        let map = GradeCategoryMap(
            categories: [
                .init(id: "map:hw", name: "HomeWorks", weightPercent: 10, canvasGroupIDs: ["g-pset"]),
                .init(id: "map:attendance", name: "Attendance/Participation", weightPercent: 10),
            ],
            itemAssignments: ["rollcall": "map:attendance"]
        )

        let output = GradeRegrouper.apply(map, to: canvasCategories)
        let byID = Dictionary(uniqueKeysWithValues: output.categories.map { ($0.id, $0) })

        #expect(byID["map:attendance"]?.items.map(\.id) == ["rollcall"])
        #expect(byID["map:hw"]?.items.map(\.id) == ["ps1"])
        #expect(output.movedItemIDs == ["rollcall"])
    }

    @Test("an excluded item is dropped from every category and reported in excludedItemIDs")
    func excludedItemDropped() {
        let canvasCategories = [
            GradeCategory(id: "g-quiz", name: "Quizzes", items: [item("quiz1"), item("quiz2", points: 0)]),
        ]
        let map = GradeCategoryMap(
            categories: [.init(id: "map:quiz", name: "Quizzes", weightPercent: 15, canvasGroupIDs: ["g-quiz"])],
            excludedItemIDs: ["quiz2"],
            exclusionReasons: ["quiz2": "zero-point placeholder"]
        )

        let output = GradeRegrouper.apply(map, to: canvasCategories)
        let quizCategory = output.categories.first { $0.id == "map:quiz" }!

        #expect(quizCategory.items.map(\.id) == ["quiz1"])
        #expect(output.excludedItemIDs == ["quiz2"])
    }

    @Test("a Canvas group the map never claimed survives as its own zero-weight category")
    func unmappedGroupSurvivesAtZeroWeight() {
        let canvasCategories = [
            GradeCategory(id: "g-pset", name: "Problem Sets", weight: 40, items: [item("ps1")]),
            GradeCategory(id: "g-import", name: "Imported Assignments", weight: 5, items: [item("x")]),
        ]
        let map = GradeCategoryMap(categories: [
            .init(id: "map:hw", name: "HomeWorks", weightPercent: 10, canvasGroupIDs: ["g-pset"]),
        ])

        let output = GradeRegrouper.apply(map, to: canvasCategories)
        let unmapped = output.categories.first { $0.id == "g-import" }

        #expect(output.unmappedGroupIDs == ["g-import"])
        #expect(unmapped?.weight == 0)
        #expect(unmapped?.items.map(\.id) == ["x"])
    }

    @Test("a map category with no Canvas groups is still emitted, empty, because its weight still counts")
    func emptyMapCategoryEmitted() {
        let canvasCategories = [GradeCategory(id: "g-mid1", name: "Midterm 1", items: [item("m1")])]
        let map = GradeCategoryMap(categories: [
            .init(id: "map:mid1", name: "Midterm 1", weightPercent: 15, canvasGroupIDs: ["g-mid1"]),
            .init(id: "map:mid3", name: "Midterm 3", weightPercent: 15, canvasGroupIDs: []),
        ])

        let output = GradeRegrouper.apply(map, to: canvasCategories)
        let mid3 = output.categories.first { $0.id == "map:mid3" }

        #expect(mid3 != nil)
        #expect(mid3?.items.isEmpty == true)
        #expect(mid3?.weight == 15)
    }
}

@Suite("GradeRegrouper: Canvas drop rules survive the fold")
struct GradeRegrouperDropRuleTests {
    private func group(_ id: String, dropHighest: Int = 0, neverDrop: Set<String> = []) -> GradeCategory {
        GradeCategory(id: id, name: id, weight: 50, dropLowest: 1, dropHighest: dropHighest, neverDropIDs: neverDrop,
                      items: [GradeItem(id: "\(id)-1", name: "\(id) 1", pointsPossible: 10, score: 8)])
    }

    @Test("a one-to-one fold keeps never-drop ids and drop-highest")
    func oneToOneKeepsRules() {
        let map = GradeCategoryMap(categories: [
            .init(id: "map:a", name: "A", weightPercent: 50, dropLowest: 1, canvasGroupIDs: ["a"], provenance: .canvas)
        ], provenance: .canvas)
        let out = GradeRegrouper.apply(map, to: [group("a", dropHighest: 1, neverDrop: ["a-1"])])
        let folded = out.categories.first { $0.id == "map:a" }
        #expect(folded?.dropHighest == 1)
        #expect(folded?.neverDropIDs == ["a-1"])
    }

    @Test("a many-to-one fold unions never-drop ids and does not guess drop-highest")
    func manyToOneUnionsNeverDrop() {
        let map = GradeCategoryMap(categories: [
            .init(id: "map:hw", name: "HomeWorks", weightPercent: 10, canvasGroupIDs: ["a", "b"], provenance: .syllabus)
        ], provenance: .syllabus)
        let out = GradeRegrouper.apply(map, to: [group("a", dropHighest: 1, neverDrop: ["a-1"]), group("b", dropHighest: 2, neverDrop: ["b-1"])])
        let folded = out.categories.first { $0.id == "map:hw" }
        #expect(folded?.neverDropIDs == ["a-1", "b-1"])
        #expect(folded?.dropHighest == 0)
    }
}
