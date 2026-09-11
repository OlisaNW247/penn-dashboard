import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// Covers `GradeWatcherStore`'s `map-categories` layer: caching the
/// server's per-course `SharedCategoryMapping` answer, the student's
/// accept/decline decision against a specific Canvas structure hash, and
/// `suggestedCategoryMap`'s precedence once one is accepted.
///
/// Reuses the exact real-phone PHYS 0151 fixture from
/// `GradeWatcherCategoryMapTests`/`SharedCategoryMappingTests` (Canvas
/// assignment groups Quizzes / Problem Sets / Worksheets / Midterm 1 /
/// Midterm 2 / Final / Imported Assignments; a syllabus promising Quizzes
/// 15, Midterm 1 15, Midterm 2 15, Midterm 3 15, Final 20, HomeWorks 10,
/// Attendance/Participation 10) — copied rather than imported, since test
/// files can't import each other's private fixture helpers.
///
/// One important fact about this fixture, confirmed by
/// `GradeWatcherCategoryMapTests.effectiveMapAfterAttachSyllabus`: the LOCAL
/// syllabus matcher already folds "Problem Sets" + "Worksheets" into
/// "HomeWorks" on its own (`SyllabusMatcher`'s synonym table lists
/// "worksheet" and "assignment" as `.homework`-family members), so a shared
/// mapping that ALSO only names those same two groups reproduces the local
/// answer exactly rather than differing from it. Every "the shared mapping
/// differs from local" fixture below therefore adds "Imported Assignments"
/// (`g-imported`) into HomeWorks — a fold the local synonym/fuzzy table
/// genuinely does not make on its own (confirmed by the same test: Imported
/// Assignments is the "junk nobody asked for" group that stays unmapped) —
/// rather than the brief's original "Worksheets" example, which turns out
/// not to actually differ given this fixture's real matcher behavior.
@MainActor
@Suite("Grade Watcher shared category mapping (map-categories)", .serialized)
struct GradeWatcherSharedMappingTests {
    private static let touchedKeys = [
        "gradeWatcherSharedCategoryMappings",
        "gradeWatcherSharedMappingDecisions",
        "gradeWatcherSyllabusSchemes",
        "gradeWatcherWatchedCourses",
        "gradeWatcherConfirmedCategoryMappings",
        "gradeWatcherCategoryMapEdits",
    ]

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

    // MARK: - PHYS 0151 fixture (copied from GradeWatcherCategoryMapTests)

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

    /// The local matcher's own default fold for this fixture, restated as a
    /// `SharedCategoryMapping` so it can be handed back to the store as a
    /// "the server agrees" answer.
    private func localEquivalentMapping() -> SharedCategoryMapping {
        SharedCategoryMapping(categories: [
            .init(name: "Quizzes", canvasGroupIDs: ["g-quiz"]),
            .init(name: "HomeWorks", canvasGroupIDs: ["g-pset", "g-work"]),
            .init(name: "Midterm 1", canvasGroupIDs: ["g-mid1"]),
            .init(name: "Midterm 2", canvasGroupIDs: ["g-mid2"]),
            .init(name: "Final", canvasGroupIDs: ["g-final"]),
        ])
    }

    /// The same shape as `localEquivalentMapping`, but folding "Imported
    /// Assignments" into HomeWorks too — a fold the local matcher does not
    /// make on its own (see this suite's header comment) — so this always
    /// differs from `suggestedCategoryMap`.
    private func differingMapping() -> SharedCategoryMapping {
        SharedCategoryMapping(categories: [
            .init(name: "Quizzes", canvasGroupIDs: ["g-quiz"]),
            .init(name: "HomeWorks", canvasGroupIDs: ["g-pset", "g-work", "g-imported"]),
            .init(name: "Midterm 1", canvasGroupIDs: ["g-mid1"]),
            .init(name: "Midterm 2", canvasGroupIDs: ["g-mid2"]),
            .init(name: "Final", canvasGroupIDs: ["g-final"]),
        ])
    }

    private func makeAttachedStore(courseID: String = "1001") -> GradeWatcherStore {
        let store = GradeWatcherStore(historyStore: nil)
        store.loadPreviewSnapshots([courseID: makeSnapshot(courseID: courseID, categories: canvasCategories())])
        store.attachSyllabus(AttachedSyllabus(scheme: syllabusScheme(), source: .pasted), courseID: courseID)
        return store
    }

    // MARK: - shouldRequestSharedMapping

    @Test("shouldRequestSharedMapping is false with no scheme, true once one is attached, false again after a null answer for the current hash")
    func shouldRequestGating() {
        isolated {
            let store = GradeWatcherStore(historyStore: nil)
            store.loadPreviewSnapshots(["1001": makeSnapshot(courseID: "1001", categories: canvasCategories())])

            #expect(!store.shouldRequestSharedMapping(courseID: "1001"))

            store.attachSyllabus(AttachedSyllabus(scheme: syllabusScheme(), source: .pasted), courseID: "1001")
            #expect(store.shouldRequestSharedMapping(courseID: "1001"))

            guard let hash = store.currentStructureHash(courseID: "1001") else {
                Issue.record("expected a structure hash once a snapshot exists")
                return
            }

            // A null answer from the server is remembered, not re-asked.
            store.setSharedMapping(nil, courseID: "1001", localStructureHash: hash)
            #expect(!store.shouldRequestSharedMapping(courseID: "1001"))
        }
    }

    @Test("shouldRequestSharedMapping is false once the student has edited the category map")
    func shouldRequestFalseAfterEdit() {
        isolated {
            let store = makeAttachedStore()
            #expect(store.shouldRequestSharedMapping(courseID: "1001"))

            store.assignGroup(courseID: "1001", groupID: "g-imported", toCategory: "map:quizzes")
            #expect(!store.shouldRequestSharedMapping(courseID: "1001"))
        }
    }

    @Test("shouldRequestSharedMapping is false once a decision exists for the current hash")
    func shouldRequestFalseAfterDecision() {
        isolated {
            let store = makeAttachedStore()
            #expect(store.shouldRequestSharedMapping(courseID: "1001"))

            store.declineSharedMapping(courseID: "1001")
            #expect(!store.shouldRequestSharedMapping(courseID: "1001"))
        }
    }

    // MARK: - sharedMappingSuggestion

    @Test("sharedMappingSuggestion is nil when the cached record's hash is stale")
    func suggestionNilForStaleHash() {
        isolated {
            let store = makeAttachedStore()
            store.setSharedMapping(differingMapping(), courseID: "1001", localStructureHash: "stale-hash")
            #expect(store.sharedMappingSuggestion(courseID: "1001") == nil)
        }
    }

    @Test("sharedMappingSuggestion is offered when the built map differs from the local suggestion")
    func suggestionOfferedWhenDifferent() {
        isolated {
            let store = makeAttachedStore()
            guard let hash = store.currentStructureHash(courseID: "1001") else {
                Issue.record("expected a hash")
                return
            }
            store.setSharedMapping(differingMapping(), courseID: "1001", localStructureHash: hash)

            let suggestion = store.sharedMappingSuggestion(courseID: "1001")
            #expect(suggestion?.provenance == .sharedProfile)
            let hw = suggestion?.categories.first { $0.name == "HomeWorks" }
            #expect(Set(hw?.canvasGroupIDs ?? []) == ["g-pset", "g-work", "g-imported"])
        }
    }

    @Test("sharedMappingSuggestion is nil when the mapping reproduces the local suggestion exactly")
    func suggestionNilWhenIdentical() {
        isolated {
            let store = makeAttachedStore()
            guard let hash = store.currentStructureHash(courseID: "1001") else {
                Issue.record("expected a hash")
                return
            }
            store.setSharedMapping(localEquivalentMapping(), courseID: "1001", localStructureHash: hash)
            #expect(store.sharedMappingSuggestion(courseID: "1001") == nil)
        }
    }

    // MARK: - acceptSharedMapping

    @Test("acceptSharedMapping makes suggestedCategoryMap read the shared mapping with .sharedProfile provenance, and a later student edit still layers on top")
    func acceptAppliesSharedMapping() {
        isolated {
            let store = makeAttachedStore()
            guard let hash = store.currentStructureHash(courseID: "1001") else {
                Issue.record("expected a hash")
                return
            }
            store.setSharedMapping(localEquivalentMapping(), courseID: "1001", localStructureHash: hash)
            store.acceptSharedMapping(courseID: "1001")

            let suggested = store.suggestedCategoryMap(courseID: "1001")
            #expect(suggested?.provenance == .sharedProfile)
            let hw = suggested?.categories.first { $0.name == "HomeWorks" }
            #expect(hw?.canvasGroupIDs == ["g-pset", "g-work"])

            guard let hwID = hw?.id else {
                Issue.record("expected a HomeWorks category")
                return
            }
            // A subsequent student edit still layers on top of the accepted
            // shared map — accepting a server suggestion is not a dead end
            // for further corrections.
            store.assignGroup(courseID: "1001", groupID: "g-imported", toCategory: hwID)
            let effective = store.effectiveCategoryMap(courseID: "1001")
            #expect(effective.categories.first { $0.id == hwID }?.canvasGroupIDs.contains("g-imported") == true)
        }
    }

    // MARK: - declineSharedMapping / clearSharedMappingDecision

    @Test("declineSharedMapping hides the suggestion and leaves suggestedCategoryMap local; clearSharedMappingDecision brings it back")
    func declineHidesAndClearRestores() {
        isolated {
            let store = makeAttachedStore()
            guard let hash = store.currentStructureHash(courseID: "1001") else {
                Issue.record("expected a hash")
                return
            }
            store.setSharedMapping(differingMapping(), courseID: "1001", localStructureHash: hash)
            #expect(store.sharedMappingSuggestion(courseID: "1001") != nil)

            store.declineSharedMapping(courseID: "1001")
            #expect(store.sharedMappingSuggestion(courseID: "1001") == nil)
            #expect(store.suggestedCategoryMap(courseID: "1001")?.provenance == .syllabus)

            store.clearSharedMappingDecision(courseID: "1001")
            #expect(store.sharedMappingSuggestion(courseID: "1001") != nil)
        }
    }

    // MARK: - Persistence across a fresh store instance

    @Test("records and decisions persist across a fresh GradeWatcherStore instance")
    func persistsAcrossRelaunch() {
        isolated {
            let store = makeAttachedStore()
            guard let hash = store.currentStructureHash(courseID: "1001") else {
                Issue.record("expected a hash")
                return
            }
            store.setSharedMapping(localEquivalentMapping(), courseID: "1001", localStructureHash: hash)
            store.acceptSharedMapping(courseID: "1001")

            let reloaded = GradeWatcherStore(historyStore: nil)
            reloaded.loadPreviewSnapshots(["1001": makeSnapshot(courseID: "1001", categories: canvasCategories())])
            #expect(reloaded.suggestedCategoryMap(courseID: "1001")?.provenance == .sharedProfile)
        }
    }

    // MARK: - resetCategoryMapEdits

    @Test("resetCategoryMapEdits clears an accepted shared-mapping decision too")
    func resetClearsSharedDecision() {
        isolated {
            let store = makeAttachedStore()
            guard let hash = store.currentStructureHash(courseID: "1001") else {
                Issue.record("expected a hash")
                return
            }
            store.setSharedMapping(localEquivalentMapping(), courseID: "1001", localStructureHash: hash)
            store.acceptSharedMapping(courseID: "1001")
            #expect(store.suggestedCategoryMap(courseID: "1001")?.provenance == .sharedProfile)

            store.resetCategoryMapEdits(courseID: "1001")
            #expect(store.suggestedCategoryMap(courseID: "1001")?.provenance == .syllabus)
        }
    }

    // MARK: - mapCategoriesRequest shape

    @Test("mapCategoriesRequest for the fixture carries 7 groups and never a score field")
    func requestShapeAndNoScore() {
        isolated {
            let store = GradeWatcherStore(historyStore: nil)
            store.loadPreviewSnapshots(["1001": makeSnapshot(courseID: "1001", categories: canvasCategories())])

            guard let request = store.mapCategoriesRequest(courseID: "1001") else {
                Issue.record("expected a request")
                return
            }
            #expect(request.groups.count == 7)

            guard let data = try? BackendJSON.encoder().encode(request) else {
                Issue.record("failed to encode request")
                return
            }
            let json = String(data: data, encoding: .utf8) ?? ""
            #expect(!json.contains("\"score\""))
        }
    }
}
