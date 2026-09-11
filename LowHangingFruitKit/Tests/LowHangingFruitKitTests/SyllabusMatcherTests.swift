import Foundation
import Testing
@testable import LowHangingFruitKit

/// Coverage for docs/grades.md §13 — mapping syllabus categories onto Canvas
/// assignment groups, and the all-or-nothing coverage gate that protects the
/// engine's manual-weight rule.
@Suite("Syllabus matching")
struct SyllabusMatcherTests {

    private func canvas(_ id: String, _ name: String, items: Int = 1) -> GradeCategory {
        GradeCategory(id: id, name: name, items: (0..<items).map {
            GradeItem(id: "\(id)-\($0)", name: "item \($0)", pointsPossible: 100)
        })
    }

    private func scheme(_ pairs: [(String, Double)], counts: [String: Int] = [:]) -> SyllabusGradingScheme {
        let categories = pairs.map { name, weight in
            SyllabusCategory(
                id: TitleNormalizer.categoryKey(name),
                name: name,
                weightPercent: weight,
                expectedItemCount: counts[name]
            )
        }
        return SyllabusGradingScheme(
            categories: categories,
            confidence: .high,
            rawWeightSum: pairs.reduce(0) { $0 + $1.1 }
        )
    }

    // MARK: - Tiers

    @Test("identical names match exactly and apply without asking")
    func exactMatch() {
        let result = SyllabusMatcher.match(
            scheme: scheme([("Homework", 50), ("Final", 50)]),
            canvasCategories: [canvas("1", "Homework"), canvas("2", "Final")]
        )

        #expect(result.matches.allSatisfy { $0.tier == .exact })
        #expect(result.isCompleteCoverage)
        #expect(result.canvasWeights["1"] == 50)
    }

    @Test("'Problem Sets' matches Canvas's 'Homework' — the same thing under two names")
    func synonymMatch() {
        let result = SyllabusMatcher.match(
            scheme: scheme([("Problem Sets", 60), ("Exams", 40)]),
            canvasCategories: [canvas("1", "Homework"), canvas("2", "Exams")]
        )

        let psets = result.matches.first { $0.syllabusName == "Problem Sets" }
        #expect(psets?.canvasCategoryID == "1")
        #expect(psets?.tier == .exact)
    }

    @Test("plural and singular category names match")
    func pluralMatch() {
        let result = SyllabusMatcher.match(
            scheme: scheme([("Papers", 70), ("Participation", 30)]),
            canvasCategories: [canvas("1", "Paper"), canvas("2", "Participation")]
        )

        #expect(result.isCompleteCoverage)
    }

    @Test("a near-miss name is proposed, not applied")
    func fuzzyIsNotApplied() {
        let result = SyllabusMatcher.match(
            scheme: scheme([("Case Writeups", 60), ("Participation", 40)]),
            canvasCategories: [canvas("1", "Case Studies"), canvas("2", "Participation")]
        )

        let cases = result.matches.first { $0.syllabusName == "Case Writeups" }
        #expect(cases?.tier == .fuzzy)
        #expect(cases?.isApplied == false)
        // A fuzzy proposal must not reach the engine.
        #expect(result.isCompleteCoverage == false)
        #expect(result.canvasWeights.isEmpty)
    }

    @Test("an unrelated name matches nothing")
    func unmatched() {
        let result = SyllabusMatcher.match(
            scheme: scheme([("Fieldwork Journal", 50), ("Final", 50)]),
            canvasCategories: [canvas("1", "Homework"), canvas("2", "Final")]
        )

        let journal = result.matches.first { $0.syllabusName == "Fieldwork Journal" }
        #expect(journal?.tier == .unmatched)
        #expect(journal?.canvasCategoryID == nil)
    }

    @Test("a confirmed mapping applies like an exact match on every later pass")
    func confirmedMapping() {
        let result = SyllabusMatcher.match(
            scheme: scheme([("Case Writeups", 60), ("Participation", 40)]),
            canvasCategories: [canvas("1", "Case Studies"), canvas("2", "Participation")],
            confirmed: [TitleNormalizer.categoryKey("Case Writeups"): "1"]
        )

        let cases = result.matches.first { $0.syllabusName == "Case Writeups" }
        #expect(cases?.tier == .confirmed)
        #expect(cases?.isApplied == true)
        #expect(result.isCompleteCoverage)
        #expect(result.canvasWeights["1"] == 60)
    }

    // MARK: - Coverage gate

    @Test("a Canvas group with no syllabus weight blocks coverage")
    func uncoveredCanvasGroupBlocks() {
        let result = SyllabusMatcher.match(
            scheme: scheme([("Homework", 50), ("Final", 50)]),
            canvasCategories: [canvas("1", "Homework"), canvas("2", "Final"), canvas("3", "Attendance")]
        )

        #expect(result.isCompleteCoverage == false)
        #expect(result.unmatchedCanvasCategories.map(\.id) == ["3"])
        // Partial weights must never reach the engine: the engine's manual
        // weights are all-or-nothing and would zero out Attendance.
        #expect(result.canvasWeights.isEmpty)
    }

    @Test("two syllabus categories never claim the same Canvas group")
    func noDoubleClaim() {
        let result = SyllabusMatcher.match(
            scheme: scheme([("Exams", 50), ("Exam Review", 50)]),
            canvasCategories: [canvas("1", "Exams")]
        )

        let claimed = result.matches.compactMap(\.canvasCategoryID)
        #expect(Set(claimed).count == claimed.count)
    }

    @Test("a tie between two equally plausible groups is left unmatched rather than guessed")
    func ambiguousIsUnmatched() {
        let result = SyllabusMatcher.match(
            scheme: scheme([("Weekly Assignment", 100)]),
            canvasCategories: [canvas("1", "Weekly Quiz"), canvas("2", "Weekly Lab")]
        )

        #expect(result.matches.first?.tier == .unmatched)
    }

    @Test("heavier categories win the greedy assignment")
    func heavierWinsFirst() {
        let result = SyllabusMatcher.match(
            scheme: scheme([("Final Exam", 70), ("Exam Prep", 30)]),
            canvasCategories: [canvas("1", "Exams")]
        )

        let applied = result.matches.first { $0.canvasCategoryID == "1" }
        #expect(applied?.syllabusName == "Final Exam")
    }
}

/// Coverage for the 2026-09-10 many-to-one/synonym-family addendum
/// (docs/grades.md §14 addendum): a syllabus category claiming SEVERAL
/// Canvas groups at once, the numbered-exam exception, and `appliedWeights`
/// as a coverage-independent counterpart to `canvasWeights`. Kept as its own
/// suite in this same file (rather than folded into `SyllabusMatcherTests`
/// above) so this work can't accidentally corrupt the existing, already-
/// verified suite -- the same reasoning `GradeEngineSemesterTests` documents
/// for staying separate from `GradeEngineTests`.
@Suite("Syllabus matching — synonyms and many-to-one")
struct SyllabusMatcherSynonymTests {

    private func canvas(_ id: String, _ name: String, items: Int = 1) -> GradeCategory {
        GradeCategory(id: id, name: name, items: (0..<items).map {
            GradeItem(id: "\(id)-\($0)", name: "item \($0)", pointsPossible: 100)
        })
    }

    private func scheme(_ pairs: [(String, Double)]) -> SyllabusGradingScheme {
        let categories = pairs.map { name, weight in
            SyllabusCategory(id: TitleNormalizer.categoryKey(name), name: name, weightPercent: weight)
        }
        return SyllabusGradingScheme(categories: categories, confidence: .high, rawWeightSum: pairs.reduce(0) { $0 + $1.1 })
    }

    // MARK: - Synonym family, many-to-one

    @Test("a synonym-family category folds SEVERAL Canvas groups into one syllabus category")
    func manyToOneViaFamily() {
        let result = SyllabusMatcher.match(
            scheme: scheme([("HomeWorks", 10), ("Final", 90)]),
            canvasCategories: [canvas("1", "Problem Sets"), canvas("2", "Worksheets"), canvas("3", "Final")]
        )

        let hw = result.matches.first { $0.syllabusName == "HomeWorks" }
        #expect(Set(hw?.canvasCategoryIDs ?? []) == ["1", "2"])
        #expect(hw?.tier == .exact) // deterministic vocabulary, not a guess -- applied without asking
        #expect(hw?.isApplied == true)
        #expect(result.isCompleteCoverage)
    }

    @Test("a bare 'Assignment' group also joins the homework family fold")
    func assignmentJoinsHomeworkFamily() {
        let result = SyllabusMatcher.match(
            scheme: scheme([("HomeWorks", 10), ("Final", 90)]),
            canvasCategories: [canvas("1", "Problem Sets"), canvas("2", "Assignment"), canvas("3", "Final")]
        )

        let hw = result.matches.first { $0.syllabusName == "HomeWorks" }
        #expect(Set(hw?.canvasCategoryIDs ?? []) == ["1", "2"])
    }

    // MARK: - Numbered exams

    @Test("numbered exam names match by number, even across the exam family's own synonyms")
    func numberedExamsMatchAcrossSynonyms() {
        let result = SyllabusMatcher.match(
            scheme: scheme([("Exam 1", 40), ("Exam 2", 60)]),
            canvasCategories: [canvas("1", "Midterm 1"), canvas("2", "Midterm 2")]
        )

        let exam1 = result.matches.first { $0.syllabusName == "Exam 1" }
        let exam2 = result.matches.first { $0.syllabusName == "Exam 2" }
        #expect(exam1?.canvasCategoryID == "1")
        #expect(exam2?.canvasCategoryID == "2")
        #expect(result.isCompleteCoverage)
    }

    @Test("a numbered syllabus category never claims the wrong-numbered Canvas group")
    func numberedExamNeverClaimsWrongNumber() {
        let result = SyllabusMatcher.match(
            scheme: scheme([("Exam 1", 100)]),
            canvasCategories: [canvas("2", "Midterm 2")]
        )

        let exam1 = result.matches.first { $0.syllabusName == "Exam 1" }
        #expect(exam1?.tier == .unmatched)
    }

    @Test("a syllabus category with no Canvas group is reported in unmatchedSyllabusCategories")
    func unmatchedSyllabusCategoryReported() {
        let result = SyllabusMatcher.match(
            scheme: scheme([("Midterm 1", 50), ("Midterm 3", 50)]),
            canvasCategories: [canvas("1", "Midterm 1")]
        )

        #expect(result.unmatchedSyllabusCategories.map(\.name) == ["Midterm 3"])
    }

    // MARK: - appliedWeights

    @Test("appliedWeights reports every applied match's weight even when overall coverage is incomplete")
    func appliedWeightsIgnoresCoverageGate() {
        let result = SyllabusMatcher.match(
            scheme: scheme([("Homework", 60), ("Final", 40)]),
            // "Attendance" has no syllabus counterpart, so coverage is incomplete --
            // but Homework/Final should still report their weights.
            canvasCategories: [canvas("1", "Homework"), canvas("2", "Final"), canvas("3", "Attendance")]
        )

        #expect(result.isCompleteCoverage == false)
        #expect(result.canvasWeights.isEmpty) // the OLD, coverage-gated accessor
        #expect(result.appliedWeights["1"] == 60)
        #expect(result.appliedWeights["2"] == 40)
        #expect(result.appliedWeights["3"] == nil)
    }
}

@Suite("Syllabus count reconciliation")
struct SyllabusReconcilerTests {

    private func canvasCategory(id: String, name: String, itemCount: Int, excused: Int = 0) -> GradeCategory {
        var items = (0..<itemCount).map {
            GradeItem(id: "\(id)-\($0)", name: "item \($0)", pointsPossible: 100)
        }
        for index in 0..<excused {
            items.append(GradeItem(id: "\(id)-ex\(index)", name: "excused", pointsPossible: 100, isExcused: true))
        }
        return GradeCategory(id: id, name: name, items: items)
    }

    private func scheme(name: String, weight: Double, expected: Int?) -> SyllabusGradingScheme {
        SyllabusGradingScheme(
            categories: [
                SyllabusCategory(id: TitleNormalizer.categoryKey(name), name: name,
                                 weightPercent: weight, expectedItemCount: expected),
                SyllabusCategory(id: TitleNormalizer.categoryKey("Final"), name: "Final",
                                 weightPercent: 100 - weight),
            ],
            confidence: .high,
            rawWeightSum: 100
        )
    }

    @Test("a syllabus that promises more than Canvas lists reports the gap")
    func gapReported() {
        let canvasCategories = [
            canvasCategory(id: "1", name: "Problem Sets", itemCount: 7),
            canvasCategory(id: "2", name: "Final", itemCount: 1),
        ]
        let scheme = scheme(name: "Problem Sets", weight: 40, expected: 10)
        let match = SyllabusMatcher.match(scheme: scheme, canvasCategories: canvasCategories)

        let gaps = SyllabusReconciler.countGaps(match: match, scheme: scheme, canvasCategories: canvasCategories)
        #expect(gaps.count == 1)
        #expect(gaps.first?.missing == 3)
        #expect(gaps.first?.categoryName == "Problem Sets")
    }

    @Test("no gap is reported once Canvas has caught up")
    func noGapWhenComplete() {
        let canvasCategories = [
            canvasCategory(id: "1", name: "Problem Sets", itemCount: 10),
            canvasCategory(id: "2", name: "Final", itemCount: 1),
        ]
        let scheme = scheme(name: "Problem Sets", weight: 40, expected: 10)
        let match = SyllabusMatcher.match(scheme: scheme, canvasCategories: canvasCategories)

        #expect(SyllabusReconciler.countGaps(match: match, scheme: scheme, canvasCategories: canvasCategories).isEmpty)
    }

    @Test("excused items don't count as work Canvas has listed")
    func excusedNotCounted() {
        let canvasCategories = [
            canvasCategory(id: "1", name: "Problem Sets", itemCount: 8, excused: 2),
            canvasCategory(id: "2", name: "Final", itemCount: 1),
        ]
        let scheme = scheme(name: "Problem Sets", weight: 40, expected: 10)
        let match = SyllabusMatcher.match(scheme: scheme, canvasCategories: canvasCategories)

        let gaps = SyllabusReconciler.countGaps(match: match, scheme: scheme, canvasCategories: canvasCategories)
        #expect(gaps.first?.listedInCanvas == 8)
        #expect(gaps.first?.missing == 2)
    }

    @Test("a category with no stated count produces no gap")
    func noCountNoGap() {
        let canvasCategories = [
            canvasCategory(id: "1", name: "Problem Sets", itemCount: 3),
            canvasCategory(id: "2", name: "Final", itemCount: 1),
        ]
        let scheme = scheme(name: "Problem Sets", weight: 40, expected: nil)
        let match = SyllabusMatcher.match(scheme: scheme, canvasCategories: canvasCategories)

        #expect(SyllabusReconciler.countGaps(match: match, scheme: scheme, canvasCategories: canvasCategories).isEmpty)
    }
}
