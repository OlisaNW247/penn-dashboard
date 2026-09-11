import Foundation
import Testing
@testable import LowHangingFruitKit

/// Coverage for the Kit side of `map-categories` (`backend/PROTOCOL.md`):
/// `MapCategoriesRequest`/`Response` (`Models/BackendWire.swift`),
/// `SharedCategoryMapping` (`Models/SharedCategoryMapping.swift`), and
/// `GradeCategoryMapBuilder.fromSharedMapping`. The PHYS 0151 fixture below
/// is copied verbatim from `GradeCategoryMapBuilderTests` so both suites
/// exercise the same real-phone shape without depending on each other.
@Suite("Shared category mapping (map-categories)")
struct SharedCategoryMappingTests {

    private func item(_ id: String, points: Double, score: Double? = nil, name: String? = nil) -> GradeItem {
        GradeItem(id: id, name: name ?? id, pointsPossible: points, score: score)
    }

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

    /// `syllabusScheme()` with one category's `expectedItemCount` overridden,
    /// so the expected-count precedence tests can exercise "the syllabus
    /// said something" without touching the shared base fixture.
    private func syllabusScheme(expectedItemCount: Int, for categoryName: String) -> SyllabusGradingScheme {
        let base = syllabusScheme()
        let categories = base.categories.map { category -> SyllabusCategory in
            guard category.name == categoryName else { return category }
            return SyllabusCategory(
                id: category.id,
                name: category.name,
                weightPercent: category.weightPercent,
                dropLowest: category.dropLowest,
                expectedItemCount: expectedItemCount,
                evidence: category.evidence
            )
        }
        return SyllabusGradingScheme(categories: categories, confidence: base.confidence, rawWeightSum: base.rawWeightSum)
    }

    private func categoriesReplacingItem(_ id: String, in categories: [GradeCategory], with replacement: GradeItem) -> [GradeCategory] {
        categories.map { category in
            GradeCategory(
                id: category.id,
                name: category.name,
                weight: category.weight,
                dropLowest: category.dropLowest,
                dropHighest: category.dropHighest,
                neverDropIDs: category.neverDropIDs,
                items: category.items.map { $0.id == id ? replacement : $0 }
            )
        }
    }

    // MARK: - MapCategoriesRequest

    @Test("request encodes only structure, never a score or submission state")
    func requestNeverCarriesScore() throws {
        let scored = categoriesReplacingItem(
            "quiz1", in: canvasCategories(),
            with: item("quiz1", points: 10, score: 8, name: "Quiz 1")
        )
        let request = MapCategoriesRequest(courseID: "phys-151", canvasCategories: scored)
        let data = try JSONEncoder().encode(request)
        let json = String(data: data, encoding: .utf8) ?? ""

        #expect(!json.contains("score"))
        #expect(!json.contains("submitted"))
        #expect(json.contains("pointsPossible"))
        #expect(json.contains("Quizzes"))
        #expect(json.contains("Problem Sets"))
    }

    @Test("localStructureHash is order-independent but sensitive to a name change")
    func localStructureHashOrderAndSensitivity() {
        let base = canvasCategories()
        let baseRequest = MapCategoriesRequest(courseID: "c", canvasCategories: base)

        let reordered = base.reversed().map { category in
            GradeCategory(
                id: category.id,
                name: category.name,
                weight: category.weight,
                dropLowest: category.dropLowest,
                dropHighest: category.dropHighest,
                neverDropIDs: category.neverDropIDs,
                items: Array(category.items.reversed())
            )
        }
        let reorderedRequest = MapCategoriesRequest(courseID: "c", canvasCategories: Array(reordered))
        #expect(baseRequest.localStructureHash == reorderedRequest.localStructureHash)

        let renamed = categoriesReplacingItem(
            "quiz1", in: base,
            with: item("quiz1", points: 10, name: "Quiz One (renamed)")
        )
        let renamedRequest = MapCategoriesRequest(courseID: "c", canvasCategories: renamed)
        #expect(baseRequest.localStructureHash != renamedRequest.localStructureHash)
    }

    // MARK: - Decoding

    @Test("decodes the PROTOCOL.md response shape")
    func decodesProtocolExampleShape() throws {
        let json = """
        {
          "mapping": {
            "categories": [
              { "name": "HomeWorks", "canvasGroupIDs": ["g-pset", "g-work"], "itemIDs": [], "expectedCount": 8 }
            ],
            "excludedItemIDs": ["quiz2"],
            "reasons": { "quiz2": "zero-point placeholder" },
            "extractedAt": "2026-09-10T12:00:00Z",
            "structureHash": "abc123def4567890"
          }
        }
        """
        let response = try JSONDecoder().decode(MapCategoriesResponse.self, from: Data(json.utf8))
        let mapping = try #require(response.mapping)

        #expect(mapping.categories.count == 1)
        #expect(mapping.categories.first?.name == "HomeWorks")
        #expect(mapping.categories.first?.canvasGroupIDs == ["g-pset", "g-work"])
        #expect(mapping.categories.first?.expectedCount == 8)
        #expect(mapping.excludedItemIDs == ["quiz2"])
        #expect(mapping.reasons["quiz2"] == "zero-point placeholder")
        #expect(mapping.extractedAt != nil)
        #expect(mapping.structureHash == "abc123def4567890")
    }

    @Test("{ \"mapping\": null } decodes to a nil mapping")
    func nullMappingDecodesToNil() throws {
        let response = try JSONDecoder().decode(MapCategoriesResponse.self, from: Data(#"{"mapping": null}"#.utf8))
        #expect(response.mapping == nil)
    }

    @Test("missing reasons/excludedItemIDs/itemIDs decode as empty, not a decode failure")
    func missingCollectionsDecodeEmpty() throws {
        let json = """
        {
          "categories": [ { "name": "Quizzes", "canvasGroupIDs": ["g-quiz"], "expectedCount": 5 } ],
          "extractedAt": "2026-09-10T12:00:00Z",
          "structureHash": "deadbeef"
        }
        """
        let mapping = try JSONDecoder().decode(SharedCategoryMapping.self, from: Data(json.utf8))
        #expect(mapping.reasons.isEmpty)
        #expect(mapping.excludedItemIDs.isEmpty)
        #expect(mapping.categories.first?.itemIDs == [])
    }

    @Test("Codable round-trip preserves a whole-second extractedAt")
    func roundTripPreservesWholeSecondDate() throws {
        let original = SharedCategoryMapping(
            categories: [
                SharedCategoryMapping.Category(name: "Quizzes", canvasGroupIDs: ["g-quiz"], itemIDs: [], expectedCount: 5),
            ],
            excludedItemIDs: ["quiz2"],
            reasons: ["quiz2": "zero-point placeholder"],
            extractedAt: Date(timeIntervalSince1970: 1_800_000_000),
            structureHash: "abc123"
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(SharedCategoryMapping.self, from: data)
        #expect(decoded == original)
    }

    // MARK: - GradeCategoryMapBuilder.fromSharedMapping

    @Test("full PHYS 0151 mapping: groups, item assignment, exclusion, empty-group categories, provenance and ids")
    func fromSharedMappingFullFixture() {
        let mapping = SharedCategoryMapping(
            categories: [
                .init(name: "Quizzes", canvasGroupIDs: ["g-quiz"]),
                .init(name: "HomeWorks", canvasGroupIDs: ["g-pset", "g-work"]),
                .init(name: "Attendance/Participation", itemIDs: ["rollcall"]),
                .init(name: "Midterm 1", canvasGroupIDs: ["g-mid1"]),
                .init(name: "Final", canvasGroupIDs: ["g-final"]),
            ],
            excludedItemIDs: ["quiz2"],
            reasons: ["quiz2": "zero-point placeholder"]
        )
        let map = GradeCategoryMapBuilder.fromSharedMapping(mapping, scheme: syllabusScheme(), canvasCategories: canvasCategories())

        func category(_ name: String) -> GradeCategoryMap.Category? {
            map.categories.first { $0.name == name }
        }

        #expect(category("Quizzes")?.canvasGroupIDs == ["g-quiz"])
        #expect(category("HomeWorks")?.canvasGroupIDs == ["g-pset", "g-work"])
        #expect(map.itemAssignments["rollcall"] == category("Attendance/Participation")?.id)
        #expect(map.excludedItemIDs.contains("quiz2"))
        #expect(map.exclusionReasons["quiz2"] == "zero-point placeholder")
        #expect(category("Midterm 2")?.canvasGroupIDs.isEmpty == true)
        #expect(category("Midterm 3")?.canvasGroupIDs.isEmpty == true)
        #expect(map.provenance == .sharedProfile)
        #expect(map.categories.allSatisfy { $0.provenance == .sharedProfile })
        #expect(map.categories.allSatisfy { $0.id == "map:" + GradeCategoryMap.slug($0.name) })
    }

    @Test("a mapping category with no scheme counterpart is dropped and its group ids go unclaimed")
    func unmatchedMappingCategoryDropped() {
        let mapping = SharedCategoryMapping(categories: [
            .init(name: "Labs", canvasGroupIDs: ["g-work"]),
            .init(name: "HomeWorks", canvasGroupIDs: ["g-pset"]),
        ])
        let map = GradeCategoryMapBuilder.fromSharedMapping(mapping, scheme: syllabusScheme(), canvasCategories: canvasCategories())

        #expect(map.categories.contains { $0.name == "Labs" } == false)
        #expect(map.categories.first { $0.name == "HomeWorks" }?.canvasGroupIDs == ["g-pset"])
        #expect(map.categories.allSatisfy { !$0.canvasGroupIDs.contains("g-work") })
    }

    @Test("an unknown group id and an unknown item id are both dropped")
    func unknownIDsDropped() {
        let mapping = SharedCategoryMapping(categories: [
            .init(name: "Quizzes", canvasGroupIDs: ["g-quiz", "g-nope"], itemIDs: ["nope"]),
        ])
        let map = GradeCategoryMapBuilder.fromSharedMapping(mapping, scheme: syllabusScheme(), canvasCategories: canvasCategories())

        #expect(map.categories.first { $0.name == "Quizzes" }?.canvasGroupIDs == ["g-quiz"])
        #expect(map.itemAssignments["nope"] == nil)
    }

    @Test("a group id claimed by two mapping categories goes to the first one only")
    func firstClaimWinsForGroups() {
        let mapping = SharedCategoryMapping(categories: [
            .init(name: "Quizzes", canvasGroupIDs: ["g-quiz"]),
            .init(name: "HomeWorks", canvasGroupIDs: ["g-quiz", "g-pset"]),
        ])
        let map = GradeCategoryMapBuilder.fromSharedMapping(mapping, scheme: syllabusScheme(), canvasCategories: canvasCategories())

        #expect(map.categories.first { $0.name == "Quizzes" }?.canvasGroupIDs == ["g-quiz"])
        #expect(map.categories.first { $0.name == "HomeWorks" }?.canvasGroupIDs == ["g-pset"])
    }

    @Test("an item both excluded and claimed by a category's itemIDs ends up assigned, not excluded")
    func assignedBeatsExcluded() {
        let mapping = SharedCategoryMapping(
            categories: [.init(name: "Quizzes", canvasGroupIDs: ["g-quiz"], itemIDs: ["quiz1"])],
            excludedItemIDs: ["quiz1"],
            reasons: ["quiz1": "should not apply"]
        )
        let map = GradeCategoryMapBuilder.fromSharedMapping(mapping, scheme: syllabusScheme(), canvasCategories: canvasCategories())
        let quizzesID = map.categories.first { $0.name == "Quizzes" }?.id

        #expect(map.itemAssignments["quiz1"] == quizzesID)
        #expect(!map.excludedItemIDs.contains("quiz1"))
        #expect(map.exclusionReasons["quiz1"] == nil)
    }

    @Test("expected count precedence: syllabus, then mapping, then the default chain")
    func expectedCountPrecedence() {
        let canvas = canvasCategories()

        // Syllabus says 8, mapping says 6 -> syllabus wins.
        let syllabusWins = SharedCategoryMapping(categories: [.init(name: "HomeWorks", expectedCount: 6)])
        let mapSyllabusWins = GradeCategoryMapBuilder.fromSharedMapping(
            syllabusWins, scheme: syllabusScheme(expectedItemCount: 8, for: "HomeWorks"), canvasCategories: canvas
        )
        #expect(mapSyllabusWins.categories.first { $0.name == "HomeWorks" }?.expectedCount == 8)

        // Syllabus silent, mapping says 5 -> mapping wins.
        let mappingWins = SharedCategoryMapping(categories: [.init(name: "Quizzes", canvasGroupIDs: ["g-quiz"], expectedCount: 5)])
        let mapMappingWins = GradeCategoryMapBuilder.fromSharedMapping(mappingWins, scheme: syllabusScheme(), canvasCategories: canvas)
        #expect(mapMappingWins.categories.first { $0.name == "Quizzes" }?.expectedCount == 5)

        // Both silent: singular exam name defaults to 1.
        let bothSilent = SharedCategoryMapping(categories: [])
        let mapBothSilent = GradeCategoryMapBuilder.fromSharedMapping(bothSilent, scheme: syllabusScheme(), canvasCategories: canvas)
        #expect(mapBothSilent.categories.first { $0.name == "Midterm 1" }?.expectedCount == 1)

        // Both silent: attendance/participation defaults to 1.
        #expect(mapBothSilent.categories.first { $0.name == "Attendance/Participation" }?.expectedCount == 1)

        // Both silent: no default applies -> nil.
        #expect(mapBothSilent.categories.first { $0.name == "HomeWorks" }?.expectedCount == nil)
    }
}
