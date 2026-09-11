import Foundation
import Testing
@testable import LowHangingFruitKit

/// Coverage for `GradeCategoryMap` itself: the slug helper `Category.id`s are
/// conventionally built from, the two lookup helpers `GradeRegrouper` and the
/// engine rely on, and a Codable round-trip (this type is persisted the same
/// way `manualWeights`/`expectedCounts` are — see docs/grades.md §14.4 — so a
/// silent encode/decode mismatch would corrupt a student's saved map).
@Suite("Grade category map")
struct GradeCategoryMapTests {

    // MARK: - slug

    @Test("slug lowercases and joins alnum runs with a hyphen")
    func slugBasic() {
        #expect(GradeCategoryMap.slug("HomeWorks") == "homeworks")
        #expect(GradeCategoryMap.slug("Attendance/Participation") == "attendance-participation")
        #expect(GradeCategoryMap.slug("Midterm 1") == "midterm-1")
    }

    @Test("slug collapses runs of punctuation rather than leaving empty segments")
    func slugCollapsesPunctuation() {
        #expect(GradeCategoryMap.slug("A & B!!") == "a-b")
        #expect(GradeCategoryMap.slug("  Leading/Trailing  ") == "leading-trailing")
    }

    // MARK: - category(forGroupID:) / category(forItemID:inGroupID:)

    private func map() -> GradeCategoryMap {
        GradeCategoryMap(
            categories: [
                .init(id: "map:hw", name: "HomeWorks", weightPercent: 10, canvasGroupIDs: ["g-pset", "g-worksheet"]),
                .init(id: "map:attendance", name: "Attendance/Participation", weightPercent: 10, canvasGroupIDs: []),
            ],
            itemAssignments: ["item-rollcall": "map:attendance"],
            excludedItemIDs: ["item-quiz2"],
            exclusionReasons: ["item-quiz2": "zero-point placeholder"],
            provenance: .syllabus
        )
    }

    @Test("category(forGroupID:) finds the map category a Canvas group folded into")
    func categoryForGroupID() {
        let m = map()
        #expect(m.category(forGroupID: "g-pset")?.id == "map:hw")
        #expect(m.category(forGroupID: "g-worksheet")?.id == "map:hw")
        #expect(m.category(forGroupID: "g-unrelated") == nil)
    }

    @Test("category(forItemID:inGroupID:) prefers an itemAssignments exception over the item's own group")
    func categoryForItemIDPrefersException() {
        let m = map()
        // The Roll Call item's OWN Canvas group is "g-pset" (folded into
        // HomeWorks), but the exception list moves it to Attendance.
        #expect(m.category(forItemID: "item-rollcall", inGroupID: "g-pset")?.id == "map:attendance")
    }

    @Test("category(forItemID:inGroupID:) falls back to the item's group when there's no exception")
    func categoryForItemIDFallsBackToGroup() {
        let m = map()
        #expect(m.category(forItemID: "item-other", inGroupID: "g-worksheet")?.id == "map:hw")
        #expect(m.category(forItemID: "item-other", inGroupID: "g-unrelated") == nil)
    }

    // MARK: - Codable

    @Test("encodes and decodes back to an equal value")
    func codableRoundTrip() throws {
        let original = map()
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(GradeCategoryMap.self, from: data)
        #expect(decoded == original)
    }
}
