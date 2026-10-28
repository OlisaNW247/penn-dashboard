import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// A Release crash found by audit (2026-10-25): two Canvas assignment groups
/// whose names slug the same ("Homework" and "homework", "Quiz (EC)" and
/// "Quiz - EC", a recycled site with two "Assignments") got the SAME category
/// id from `"map:" + slug(name)`, and `GradeEngine` then built a
/// `Dictionary(uniqueKeysWithValues:)` over those ids and trapped. It ran on
/// every launch, because the automatic sync computes a grade for every course
/// whether or not the grades screen is open, so reinstalling did not help.
///
/// These tests pin the two halves of the fix: ids are distinct at the source
/// (and a name that doesn't collide keeps exactly the id a student's saved
/// edits are keyed on), and every lookup table built from data that came off a
/// network tolerates a duplicate anyway.
@Suite("Duplicate category ids")
struct DuplicateCategoryIDTests {
    private let now = Date(timeIntervalSince1970: 2_000_000_000)

    private func item(_ id: String, points: Double, score: Double? = nil) -> GradeItem {
        GradeItem(id: id, name: id, pointsPossible: points, score: score, scoreSource: score == nil ? nil : .canvas)
    }

    /// "Homework" and "homework" slug the same; "Exams" does not collide with
    /// either, and must keep its bare id.
    private func collidingGroups() -> [GradeCategory] {
        [
            GradeCategory(id: "101", name: "Homework", weight: 30, items: [item("h1", points: 10, score: 8)]),
            GradeCategory(id: "102", name: "homework", weight: 20, items: [item("h2", points: 10, score: 6)]),
            GradeCategory(id: "103", name: "Exams", weight: 50, items: [item("e1", points: 100, score: 90)]),
        ]
    }

    // MARK: - Canvas path (`mirroringCanvas`)

    @Test("two groups that slug the same get distinct ids; the first keeps the bare one")
    func mirroringCanvasDisambiguates() {
        let map = GradeCategoryMapBuilder.mirroringCanvas(collidingGroups(), courseUsesWeights: true)
        let ids = map.categories.map(\.id)

        #expect(ids == ["map:homework", "map:homework-102", "map:exams"])
        #expect(Set(ids).count == ids.count)
        // Nothing is dropped to make the ids unique: both groups survive with
        // their own Canvas group, name and weight.
        #expect(map.categories.map(\.name) == ["Homework", "homework", "Exams"])
        #expect(map.categories.map(\.canvasGroupIDs) == [["101"], ["102"], ["103"]])
        #expect(map.categories.map(\.weightPercent) == [30, 20, 50])
    }

    @Test("a name that doesn't collide keeps exactly \"map:\" + slug, the id persisted edits are keyed on")
    func nonCollidingIDsDoNotMove() {
        let groups = [
            GradeCategory(id: "1", name: "Problem Sets", weight: 40),
            GradeCategory(id: "2", name: "Attendance/Participation", weight: 10),
            GradeCategory(id: "3", name: "Final", weight: 50),
        ]
        let map = GradeCategoryMapBuilder.mirroringCanvas(groups, courseUsesWeights: true)
        #expect(map.categories.map(\.id) == groups.map { "map:" + GradeCategoryMap.slug($0.name) })
        #expect(map.categories.map(\.id) == ["map:problem-sets", "map:attendance-participation", "map:final"])
    }

    @Test("which colliding group keeps the bare id is decided by the lowest Canvas group id, not by fetch order")
    func lowestCanvasGroupIDKeepsTheBareID() {
        let high = GradeCategory(id: "202", name: "Homework")
        let low = GradeCategory(id: "101", name: "homework")
        for groups in [[high, low], [low, high]] {
            let map = GradeCategoryMapBuilder.mirroringCanvas(groups, courseUsesWeights: false)
            let idByGroup = Dictionary(
                uniqueKeysWithValues: map.categories.map { ($0.canvasGroupIDs[0], $0.id) }
            )
            #expect(idByGroup["101"] == "map:homework")
            #expect(idByGroup["202"] == "map:homework-202")
            // Output stays in input order; only the ids are decided by group id.
            #expect(map.categories.map { $0.canvasGroupIDs[0] } == groups.map(\.id))
        }
    }

    @Test("Canvas group ids compare as numbers, so 9 outranks 10")
    func canvasGroupIDsCompareNumerically() {
        // As strings "10" < "9"; as numbers 9 is the lower id and keeps the bare one.
        for groups in [
            [GradeCategory(id: "10", name: "Quiz"), GradeCategory(id: "9", name: "quiz")],
            [GradeCategory(id: "9", name: "quiz"), GradeCategory(id: "10", name: "Quiz")],
        ] {
            let map = GradeCategoryMapBuilder.mirroringCanvas(groups, courseUsesWeights: false)
            let idByGroup = Dictionary(
                uniqueKeysWithValues: map.categories.map { ($0.canvasGroupIDs[0], $0.id) }
            )
            #expect(idByGroup["9"] == "map:quiz")
            #expect(idByGroup["10"] == "map:quiz-10")
        }
    }

    @Test("three-way collision: every later group is suffixed with its own Canvas group id")
    func threeWayCollision() {
        let groups = [
            GradeCategory(id: "7", name: "Quiz (EC)"),
            GradeCategory(id: "8", name: "Quiz - EC"),
            GradeCategory(id: "9", name: "quiz ec"),
        ]
        let ids = GradeCategoryMapBuilder.mirroringCanvas(groups, courseUsesWeights: false).categories.map(\.id)
        #expect(ids == ["map:quiz-ec", "map:quiz-ec-8", "map:quiz-ec-9"])
    }

    @Test("a suffixed id never lands on a bare id another group owns")
    func suffixedIDYieldsToABareID() {
        // The second "Homework" is group "2", so its suffixed id would be
        // "map:homework-2", which is the bare id of the group named
        // "Homework 2". The bare id belongs to its name, so the suffixed one
        // moves.
        let groups = [
            GradeCategory(id: "1", name: "Homework"),
            GradeCategory(id: "2", name: "homework"),
            GradeCategory(id: "5", name: "Homework 2"),
        ]
        let ids = GradeCategoryMapBuilder.mirroringCanvas(groups, courseUsesWeights: false).categories.map(\.id)
        #expect(Set(ids).count == 3)
        #expect(ids[0] == "map:homework")
        #expect(ids[2] == "map:homework-2")
        #expect(ids[1] != "map:homework-2")
    }

    // MARK: - Syllabus paths (`suggested`, `fromSharedMapping`, `from(profile:)`)

    @Test("syllabus scheme: two categories that slug the same get distinct ids, first keeps the bare one")
    func suggestedDisambiguates() {
        let scheme = SyllabusGradingScheme(
            categories: [
                SyllabusCategory(id: "homework-a", name: "Homework", weightPercent: 30),
                SyllabusCategory(id: "homework-b", name: "HOMEWORK", weightPercent: 20),
                SyllabusCategory(id: "exams", name: "Exams", weightPercent: 50),
            ],
            confidence: .high,
            rawWeightSum: 100
        )
        let map = GradeCategoryMapBuilder.suggested(
            scheme: scheme, match: nil, canvasCategories: [], provenance: .syllabus
        )
        let ids = map?.categories.map(\.id)
        #expect(ids == ["map:homework", "map:homework-2", "map:exams"])
        #expect(map?.categories.map(\.name) == ["Homework", "HOMEWORK", "Exams"])
    }

    @Test("syllabus scheme whose categories share a syllabus id builds a map instead of trapping")
    func suggestedToleratesRepeatedSyllabusIDs() {
        // "Quiz" and "Quizzes" normalize to one `SyllabusCategory.id`; the
        // matcher then emits two matches under it. First match wins.
        let scheme = SyllabusGradingScheme(
            categories: [
                SyllabusCategory(id: "quiz", name: "Quiz", weightPercent: 50),
                SyllabusCategory(id: "quiz", name: "Quizzes", weightPercent: 50),
            ],
            confidence: .high,
            rawWeightSum: 100
        )
        let canvas = [GradeCategory(id: "g1", name: "Quizzes")]
        let match = SyllabusMatcher.match(scheme: scheme, canvasCategories: canvas)
        let map = GradeCategoryMapBuilder.suggested(
            scheme: scheme, match: match, canvasCategories: canvas, provenance: .syllabus
        )
        #expect(map?.categories.count == 2)
        #expect(Set(map?.categories.map(\.id) ?? []).count == 2)
    }

    @Test("server profile: weights whose names normalize to one key get distinct syllabus ids, none dropped")
    func profileSchemeDisambiguatesSyllabusIDs() {
        let profile = CourseGradingProfile(
            courseID: "1",
            weights: [
                .init(name: "Quiz", percent: 20),
                .init(name: "Quizzes", percent: 30),
                .init(name: "Exams", percent: 50),
            ],
            components: [],
            extractedAt: now
        )
        let scheme = SyllabusGradingScheme.from(profile: profile)
        #expect(scheme?.categories.map(\.id) == ["quiz", "quiz-2", "exam"])
        #expect(scheme?.categories.map(\.weightPercent) == [20, 30, 50])
    }

    @Test("pooled server mapping: scheme names that slug the same get distinct ids, and claims go to the last, as they always did")
    func sharedMappingDisambiguates() {
        let scheme = SyllabusGradingScheme(
            categories: [
                SyllabusCategory(id: "a", name: "Homework", weightPercent: 50),
                SyllabusCategory(id: "b", name: "homework", weightPercent: 50),
            ],
            confidence: .high,
            rawWeightSum: 100
        )
        let canvas = [GradeCategory(id: "g1", name: "Homework")]
        let mapping = SharedCategoryMapping(categories: [
            .init(name: "Homework", canvasGroupIDs: ["g1"]),
        ])
        let map = GradeCategoryMapBuilder.fromSharedMapping(mapping, scheme: scheme, canvasCategories: canvas)
        #expect(map.categories.map(\.id) == ["map:homework", "map:homework-2"])
        // The group is claimed once, by the LAST scheme category with that
        // `categoryKey` (what overwriting `schemeByKey` has always done), so
        // this hotfix changes nothing for input that never collided on an id.
        #expect(map.categories.map(\.canvasGroupIDs) == [[], ["g1"]])
    }

    // MARK: - Engine

    @Test("the engine computes over a mirrored map with colliding groups, and both are in the result")
    func engineSurvivesCollidingGroups() {
        let groups = collidingGroups()
        let map = GradeCategoryMapBuilder.mirroringCanvas(groups, courseUsesWeights: true)
        let breakdown = GradeEngine.compute(.init(
            courseUsesWeights: true, categories: groups, now: now, categoryMap: map
        ))

        let names = breakdown.categories.map(\.name)
        #expect(names.contains("Homework"))
        #expect(names.contains("homework"))
        #expect(names.contains("Exams"))
        let ids = breakdown.categories.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(breakdown.currentPercent != nil)
    }

    @Test("the engine tolerates a map that already carries duplicate ids, as an older build could have saved")
    func engineSurvivesAnAlreadyDuplicatedMap() {
        // Built by hand to bypass the builders: this is the shape that
        // trapped, and a map persisted or suggested by an older build can
        // still have it.
        let groups = collidingGroups()
        let map = GradeCategoryMap(
            categories: [
                .init(id: "map:homework", name: "Homework", weightPercent: 30, expectedCount: 4,
                      canvasGroupIDs: ["101"], provenance: .canvas),
                .init(id: "map:homework", name: "homework", weightPercent: 20, expectedCount: 4,
                      canvasGroupIDs: ["102"], provenance: .student),
                .init(id: "map:exams", name: "Exams", weightPercent: 50, canvasGroupIDs: ["103"], provenance: .canvas),
            ],
            provenance: .canvas
        )
        let breakdown = GradeEngine.compute(.init(
            courseUsesWeights: true, categories: groups, now: now, categoryMap: map
        ))
        #expect(breakdown.categories.count == 3)

        // And the explanation built from it, whose "left out" lookup is also
        // keyed on category id.
        let explanation = GradeExplanation.make(from: breakdown, canvasScore: nil)
        #expect(explanation.categoryLines.count == 3)
    }

    @Test("GradeRegrouper tolerates a duplicate Canvas group id and a duplicate map category id")
    func regrouperToleratesDuplicates() {
        let groups = [
            GradeCategory(id: "101", name: "Homework", items: [item("h1", points: 10, score: 8)]),
            GradeCategory(id: "101", name: "Homework again", items: []),
        ]
        let map = GradeCategoryMap(
            categories: [
                .init(id: "map:x", name: "X", weightPercent: 50, canvasGroupIDs: ["101"], provenance: .canvas),
                .init(id: "map:x", name: "Y", weightPercent: 50, provenance: .canvas),
            ],
            provenance: .canvas
        )
        let output = GradeRegrouper.apply(map, to: groups)
        #expect(output.categories.contains { $0.name == "X" })
        #expect(output.groupNamesByCategoryID["map:x"] == ["Homework"])
    }

    // MARK: - Explanation formatting

    @Test("explanation text with an infinite or NaN Canvas score returns instead of trapping")
    func explanationFormattingNonFinite() {
        let breakdown = GradeEngine.compute(.init(
            courseUsesWeights: true, categories: collidingGroups(), now: now
        ))
        for score in [Double.infinity, -Double.infinity, .nan, 1e300, -1e300] {
            let explanation = GradeExplanation.make(from: breakdown, canvasScore: score)
            let rendered = [explanation.canvasLine, explanation.modeLine, explanation.formulaLine, explanation.decidedLine]
                .compactMap { $0 }
                .joined(separator: " | ")
            #expect(!rendered.lowercased().contains("nan"))
            #expect(!rendered.lowercased().contains("inf"))
        }
    }

    @Test("explanation text with a non-finite weight returns instead of trapping")
    func explanationFormattingNonFiniteWeight() {
        for weight in [Double.infinity, .nan] {
            let groups = [
                GradeCategory(id: "a", name: "A", weight: 50, items: [item("a1", points: 10, score: 5)]),
                GradeCategory(id: "b", name: "B", weight: 50, items: [item("b1", points: 10, score: 5)]),
            ]
            let breakdown = GradeEngine.compute(.init(
                courseUsesWeights: true, categories: groups, manualWeights: ["a": weight], now: now
            ))
            let explanation = GradeExplanation.make(from: breakdown, canvasScore: nil)
            #expect(!explanation.categoryLines.isEmpty)
            #expect(!explanation.formulaLine.lowercased().contains("nan"))
            #expect(!explanation.formulaLine.lowercased().contains("inf"))
        }
    }

    @Test("ordinary values still print exactly as before")
    func explanationFormattingOrdinaryValuesUnchanged() {
        let breakdown = GradeEngine.compute(.init(
            courseUsesWeights: true, categories: collidingGroups(), now: now
        ))
        // The fixture computes to 81% (30% x 80, 20% x 60, 50% x 90), so a
        // Canvas score 10 points away is reported, with a whole-number and a
        // one-decimal case.
        let whole = GradeExplanation.make(from: breakdown, canvasScore: 71.0).canvasLine
        let decimal = GradeExplanation.make(from: breakdown, canvasScore: 70.5).canvasLine
        #expect(whole == "canvas shows 71% \u{2014} 10 points apart")
        #expect(decimal == "canvas shows 70.5% \u{2014} 10.5 points apart")
    }

    // MARK: - Store, end to end

    @MainActor
    @Test("a course with colliding groups yields a breakdown and a distinct-id map through the store")
    func storeBreakdownWithCollidingGroups() {
        let courseID = "dup-category-ids-fixture"
        let store = GradeWatcherStore(historyStore: nil)
        // `refresh` itself talks to Canvas through a client with no stub seam,
        // so the fetch result is fed in through the preview-snapshot seam.
        // Everything after it, the effective map and `breakdown(courseID:)`
        // that `recordHistory` calls on every refresh, is the real path.
        store.loadPreviewSnapshots([
            courseID: CourseGradeSnapshot(
                courseID: courseID,
                courseUsesWeights: true,
                categories: collidingGroups(),
                canvasComputedCurrentScore: nil,
                submissions: [],
                fetchedAt: now
            ),
        ], now: now)

        let map = store.effectiveCategoryMap(courseID: courseID)
        let ids = map.categories.map(\.id)
        #expect(Set(ids).count == ids.count)
        #expect(ids.count == 3)

        let breakdown = store.breakdown(courseID: courseID, now: now)
        #expect(breakdown != nil)
        #expect(breakdown?.categories.map(\.name).contains("Homework") == true)
        #expect(breakdown?.categories.map(\.name).contains("homework") == true)
    }
}
