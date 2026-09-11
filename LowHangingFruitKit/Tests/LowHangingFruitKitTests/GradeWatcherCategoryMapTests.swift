import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// Covers `GradeWatcherStore`'s category-map layer (docs/grades.md §14
/// addendum, round 3): `CategoryMapEdits` as a diff over a suggested map,
/// `GradeWatcherStore.apply(_:to:)` as the pure function that folds a diff
/// into a map, and `effectiveCategoryMap`/the mutating editors that build
/// and persist a course's edits.
///
/// Reuses the exact real-phone PHYS 0151 fixture from
/// `GradeCategoryMapBuilderTests` (Canvas assignment groups Quizzes /
/// Problem Sets / Worksheets / Midterm 1 / Midterm 2 / Final / Imported
/// Assignments; a syllabus promising Quizzes 15, Midterm 1 15, Midterm 2 15,
/// Midterm 3 15, Final 20, HomeWorks 10, Attendance/Participation 10; a
/// "Roll Call Attendance" item sitting inside Problem Sets; a zero-point
/// "Quiz 2" placeholder) — copied rather than imported, since test files
/// can't import each other's private fixture helpers.
@MainActor
@Suite("Grade Watcher category map", .serialized)
struct GradeWatcherCategoryMapTests {
    /// Every `UserDefaults.lhf` key any test in this suite writes to, either
    /// directly or through a store method that persists as a side effect
    /// (`attachSyllabus` also flips `gradeWatcherWatchedCourses`).
    private static let touchedKeys = [
        "gradeWatcherCategoryMapEdits",
        "gradeWatcherSyllabusSchemes",
        "gradeWatcherWatchedCourses",
        "gradeWatcherConfirmedCategoryMappings",
        "gradeWatcherManualWeights",
        "gradeWatcherExpectedCounts",
    ]

    /// Backs up every touched key's exact prior value, runs `body` against a
    /// clean slate, then restores exactly what was there before — on the way
    /// in as well as out, matching `GradeWatcherStoreOverridesTests`'s
    /// pattern, since an interrupted earlier run could otherwise leave this
    /// suite starting from stale state too.
    private func isolated<T>(_ body: () throws -> T) rethrows -> T {
        let defaults = UserDefaults.lhf
        let backups = Self.touchedKeys.map { ($0, defaults.object(forKey: $0)) }
        for key in Self.touchedKeys { defaults.removeObject(forKey: key) }
        defer {
            for (key, value) in backups {
                if let value {
                    defaults.set(value, forKey: key)
                } else {
                    defaults.removeObject(forKey: key)
                }
            }
        }
        return try body()
    }

    // MARK: - PHYS 0151 fixture (copied from GradeCategoryMapBuilderTests)

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

    private func makeSnapshot(courseID: String, courseUsesWeights: Bool = true, categories: [GradeCategory]) -> CourseGradeSnapshot {
        CourseGradeSnapshot(
            courseID: courseID,
            courseUsesWeights: courseUsesWeights,
            categories: categories,
            canvasComputedCurrentScore: nil,
            submissions: [],
            fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )
    }

    // MARK: - `GradeWatcherStore.apply(_:to:)` — pure, per edit kind

    private func plainMap() -> GradeCategoryMap {
        GradeCategoryMap(
            categories: [
                GradeCategoryMap.Category(id: "map:a", name: "A", weightPercent: 50, canvasGroupIDs: ["g1"], provenance: .canvas),
                GradeCategoryMap.Category(id: "map:b", name: "B", weightPercent: 50, canvasGroupIDs: ["g2"], provenance: .canvas),
            ],
            provenance: .canvas
        )
    }

    @Test("apply: an empty edits value changes nothing")
    func applyEmptyEdits() {
        let map = plainMap()
        let result = GradeWatcherStore.apply(GradeWatcherStore.CategoryMapEdits(), to: map)
        #expect(result == map)
    }

    @Test("apply: groupAssignments moves a group out of its old category and into the new one")
    func applyGroupAssignmentMoves() {
        var edits = GradeWatcherStore.CategoryMapEdits()
        edits.groupAssignments["g1"] = "map:b"
        let result = GradeWatcherStore.apply(edits, to: plainMap())
        #expect(result.categories.first { $0.id == "map:a" }?.canvasGroupIDs == [])
        #expect(result.categories.first { $0.id == "map:b" }?.canvasGroupIDs.contains("g1") == true)
        #expect(result.categories.first { $0.id == "map:b" }?.canvasGroupIDs.contains("g2") == true)
    }

    @Test("apply: groupAssignments with \"\" explicitly unmaps a group")
    func applyGroupAssignmentUnmaps() {
        var edits = GradeWatcherStore.CategoryMapEdits()
        edits.groupAssignments["g1"] = ""
        let result = GradeWatcherStore.apply(edits, to: plainMap())
        #expect(result.categories.flatMap(\.canvasGroupIDs).contains("g1") == false)
    }

    @Test("apply: itemAssignments sets an item-level override")
    func applyItemAssignment() {
        var edits = GradeWatcherStore.CategoryMapEdits()
        edits.itemAssignments["item1"] = "map:b"
        let result = GradeWatcherStore.apply(edits, to: plainMap())
        #expect(result.itemAssignments["item1"] == "map:b")
    }

    @Test("apply: excludedItemIDs adds an exclusion; includedItemIDs clears one and its reason")
    func applyExclusionAndInclusion() {
        var map = plainMap()
        map.excludedItemIDs.insert("already-excluded")
        map.exclusionReasons["already-excluded"] = "zero-point placeholder"

        var edits = GradeWatcherStore.CategoryMapEdits()
        edits.excludedItemIDs.insert("new-exclusion")
        edits.includedItemIDs.insert("already-excluded")

        let result = GradeWatcherStore.apply(edits, to: map)
        #expect(result.excludedItemIDs.contains("new-exclusion"))
        #expect(!result.excludedItemIDs.contains("already-excluded"))
        #expect(result.exclusionReasons["already-excluded"] == nil)
    }

    @Test("apply: renamedCategories is cosmetic only")
    func applyRename() {
        var edits = GradeWatcherStore.CategoryMapEdits()
        edits.renamedCategories["map:a"] = "Alpha"
        let result = GradeWatcherStore.apply(edits, to: plainMap())
        let renamed = result.categories.first { $0.id == "map:a" }
        #expect(renamed?.name == "Alpha")
        #expect(renamed?.weightPercent == 50)
        #expect(renamed?.canvasGroupIDs == ["g1"])
    }

    @Test("apply: addedCategories appends a new student category")
    func applyAddedCategory() {
        var edits = GradeWatcherStore.CategoryMapEdits()
        let added = GradeCategoryMap.Category(id: "map:extra-credit", name: "Extra Credit", weightPercent: 0, provenance: .student)
        edits.addedCategories.append(added)
        let result = GradeWatcherStore.apply(edits, to: plainMap())
        #expect(result.categories.count == 3)
        #expect(result.categories.contains { $0.id == "map:extra-credit" })
    }

    @Test("apply: removedCategoryIDs drops a category entirely")
    func applyRemovedCategory() {
        var edits = GradeWatcherStore.CategoryMapEdits()
        edits.removedCategoryIDs.insert("map:b")
        let result = GradeWatcherStore.apply(edits, to: plainMap())
        #expect(result.categories.count == 1)
        #expect(!result.categories.contains { $0.id == "map:b" })
    }

    // MARK: - `effectiveCategoryMap`

    @Test("effectiveCategoryMap with no syllabus mirrors Canvas one-to-one")
    func effectiveMapMirrorsCanvasWithoutSyllabus() {
        isolated {
            let store = GradeWatcherStore(historyStore: nil)
            store.loadPreviewSnapshots(["1001": makeSnapshot(courseID: "1001", categories: canvasCategories())])

            let map = store.effectiveCategoryMap(courseID: "1001")
            #expect(map.provenance == .canvas)
            #expect(map.categories.count == canvasCategories().count)
            // A plain mirror folds each Canvas group into its own category
            // one-to-one; nothing is unmapped.
            let output = GradeRegrouper.apply(map, to: canvasCategories())
            #expect(output.unmappedGroupIDs.isEmpty)
        }
    }

    @Test("effectiveCategoryMap after attachSyllabus folds HomeWorks from Problem Sets + Worksheets and assigns the attendance item")
    func effectiveMapAfterAttachSyllabus() {
        isolated {
            let store = GradeWatcherStore(historyStore: nil)
            store.loadPreviewSnapshots(["1001": makeSnapshot(courseID: "1001", categories: canvasCategories())])
            store.attachSyllabus(AttachedSyllabus(scheme: syllabusScheme(), source: .pasted), courseID: "1001")

            let map = store.effectiveCategoryMap(courseID: "1001")
            let hw = map.categories.first { $0.name == "HomeWorks" }
            #expect(Set(hw?.canvasGroupIDs ?? []) == ["g-pset", "g-work"])

            let attendance = map.categories.first { $0.name == "Attendance/Participation" }
            #expect(map.itemAssignments["rollcall"] == attendance?.id)
            #expect(map.excludedItemIDs.contains("quiz2"))
        }
    }

    @Test("assignGroup persists and survives a fresh store instance")
    func assignGroupPersists() {
        isolated {
            let store = GradeWatcherStore(historyStore: nil)
            store.loadPreviewSnapshots(["1001": makeSnapshot(courseID: "1001", categories: canvasCategories())])
            store.attachSyllabus(AttachedSyllabus(scheme: syllabusScheme(), source: .pasted), courseID: "1001")

            // Move "Imported Assignments" (unmapped by the syllabus) into
            // HomeWorks by hand.
            let hwID = store.effectiveCategoryMap(courseID: "1001").categories.first { $0.name == "HomeWorks" }!.id
            store.assignGroup(courseID: "1001", groupID: "g-imported", toCategory: hwID)
            #expect(store.hasCategoryMapEdits(courseID: "1001"))

            // A fresh store re-reads both the syllabus (`attachSyllabus`
            // above already persisted it) and the edits from
            // `UserDefaults.lhf` on `init`; only the fetched snapshot itself
            // is session-only (`loadPreviewSnapshots` never persists) and
            // has to be re-seeded here to reconstruct the same map.
            let reloaded = GradeWatcherStore(historyStore: nil)
            reloaded.loadPreviewSnapshots(["1001": makeSnapshot(courseID: "1001", categories: canvasCategories())])
            let reloadedMap = reloaded.effectiveCategoryMap(courseID: "1001")
            #expect(reloadedMap.categories.first { $0.id == hwID }?.canvasGroupIDs.contains("g-imported") == true)
        }
    }

    @Test("setItemExcluded(false) brings an automatically excluded item back")
    func includeReversesAutomaticExclusion() {
        isolated {
            let store = GradeWatcherStore(historyStore: nil)
            store.loadPreviewSnapshots(["1001": makeSnapshot(courseID: "1001", categories: canvasCategories())])
            store.attachSyllabus(AttachedSyllabus(scheme: syllabusScheme(), source: .pasted), courseID: "1001")

            // Quiz 2 is automatically excluded as a zero-point placeholder.
            #expect(store.effectiveCategoryMap(courseID: "1001").excludedItemIDs.contains("quiz2"))

            store.setItemExcluded(courseID: "1001", itemID: "quiz2", false)
            #expect(!store.effectiveCategoryMap(courseID: "1001").excludedItemIDs.contains("quiz2"))

            // Reversing it again re-excludes, clearing the inclusion.
            store.setItemExcluded(courseID: "1001", itemID: "quiz2", true)
            #expect(store.effectiveCategoryMap(courseID: "1001").excludedItemIDs.contains("quiz2"))
        }
    }

    @Test("resetCategoryMapEdits clears every edit for a course")
    func resetClearsEdits() {
        isolated {
            let store = GradeWatcherStore(historyStore: nil)
            store.loadPreviewSnapshots(["1001": makeSnapshot(courseID: "1001", categories: canvasCategories())])
            store.assignGroup(courseID: "1001", groupID: "g-imported", toCategory: "map:quizzes")
            store.setItemExcluded(courseID: "1001", itemID: "quiz1", true)
            #expect(store.hasCategoryMapEdits(courseID: "1001"))

            store.resetCategoryMapEdits(courseID: "1001")
            #expect(!store.hasCategoryMapEdits(courseID: "1001"))

            let reloaded = GradeWatcherStore(historyStore: nil)
            #expect(!reloaded.hasCategoryMapEdits(courseID: "1001"))
        }
    }

    // MARK: - `breakdown` under the map: attendance-only fixture

    @Test("breakdown under the map: only the attendance item is scored, so attendanceOnlyPercent is 100 and currentPercent is nil")
    func breakdownAttendanceOnlyUnderMap() {
        isolated {
            let store = GradeWatcherStore(historyStore: nil)
            store.loadPreviewSnapshots(["1001": makeSnapshot(courseID: "1001", categories: canvasCategories())])
            store.attachSyllabus(AttachedSyllabus(scheme: syllabusScheme(), source: .pasted), courseID: "1001")

            let breakdown = store.breakdown(courseID: "1001")
            #expect(breakdown?.currentPercent == nil)
            #expect(breakdown?.attendanceOnlyPercent == 100)
        }
    }
}
