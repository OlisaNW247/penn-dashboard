import Foundation
import Testing
@testable import LowHangingFruitKit

@Suite("Gradescope overlay matcher")
struct GradescopeOverlayTests {
    private static let courseURL = URL(string: "https://www.gradescope.com/courses/1")!

    private static func gsItem(_ title: String, earned: Double?, max: Double?) -> Assignment {
        Assignment(
            source: .gradescope,
            sourceID: "course-1-assignment-\(title)",
            kind: .assignment,
            course: "CIS 1200",
            title: title,
            dueAt: nil,
            url: nil,
            scoreEarned: earned,
            scoreMax: max
        )
    }

    private static func canvasItem(
        id: String,
        name: String,
        points: Double,
        score: Double? = nil
    ) -> GradeItem {
        GradeItem(
            id: id,
            name: name,
            pointsPossible: points,
            score: score,
            scoreSource: score != nil ? .canvas : nil
        )
    }

    // MARK: - Name normalization

    @Test("exact normalized match")
    func exactMatch() {
        #expect(GradescopeOverlay.namesMatch("Homework 3", "Homework 3"))
    }

    @Test("case and punctuation insensitive")
    func caseAndPunctuationInsensitive() {
        #expect(GradescopeOverlay.namesMatch("HOMEWORK 3!", "homework, 3."))
    }

    @Test("HW / Homework / Problem Set / PSet all equivalent, with number equivalence")
    func fuzzyEquivalences() {
        #expect(GradescopeOverlay.namesMatch("HW3", "Homework 3"))
        #expect(GradescopeOverlay.namesMatch("HW3", "hw 03"))
        #expect(GradescopeOverlay.namesMatch("Homework 3", "Problem Set 3"))
        #expect(GradescopeOverlay.namesMatch("PSet 3", "hw3"))
        #expect(GradescopeOverlay.namesMatch("Lab 2", "labs 02"))
        #expect(GradescopeOverlay.namesMatch("Quiz 5", "quizzes 5"))
    }

    @Test("different assignment numbers never match")
    func differentNumbersDontMatch() {
        #expect(!GradescopeOverlay.namesMatch("Homework 3", "Homework 4"))
    }

    @Test("different assignment kinds never match")
    func differentKindsDontMatch() {
        #expect(!GradescopeOverlay.namesMatch("Lab 3", "Quiz 3"))
    }

    // MARK: - apply(): core fill behavior

    @Test("exact match fills the open Canvas item and tags gradescopeEarly")
    func fillsExactMatch() {
        let categories = [
            GradeCategory(id: "c1", name: "Homework", items: [
                Self.canvasItem(id: "a1", name: "Homework 3", points: 100),
            ]),
        ]
        let gs = [Self.gsItem("Homework 3", earned: 87.5, max: 100)]

        let result = GradescopeOverlay.apply(categories: categories, gradescopeItems: gs)

        let item = result.categories[0].items[0]
        #expect(item.score == 87.5)
        #expect(item.scoreSource == .gradescopeEarly)
        #expect(result.unmatched.isEmpty)
    }

    @Test("fuzzy equivalence fills across naming drift")
    func fillsFuzzyMatch() {
        let categories = [
            GradeCategory(id: "c1", name: "Homework", items: [
                Self.canvasItem(id: "a1", name: "Problem Set 3", points: 50),
            ]),
        ]
        let gs = [Self.gsItem("HW3", earned: 45, max: 50)]

        let result = GradescopeOverlay.apply(categories: categories, gradescopeItems: gs)

        #expect(result.categories[0].items[0].score == 45)
        #expect(result.categories[0].items[0].scoreSource == .gradescopeEarly)
        #expect(result.unmatched.isEmpty)
    }

    @Test("max-points tiebreaker picks the candidate whose points match")
    func maxPointsTiebreaker() {
        let categories = [
            GradeCategory(id: "c1", name: "Homework", items: [
                Self.canvasItem(id: "a1", name: "Homework 3", points: 50),
                Self.canvasItem(id: "a2", name: "Homework 3", points: 100),
            ]),
        ]
        let gs = [Self.gsItem("Homework 3", earned: 90, max: 100)]

        let result = GradescopeOverlay.apply(categories: categories, gradescopeItems: gs)

        let byID = Dictionary(uniqueKeysWithValues: result.categories[0].items.map { ($0.id, $0) })
        #expect(byID["a1"]?.score == nil)
        #expect(byID["a2"]?.score == 90)
        #expect(byID["a2"]?.scoreSource == .gradescopeEarly)
        #expect(result.unmatched.isEmpty)
    }

    @Test("ambiguous when 2+ open candidates tie on name and points can't disambiguate")
    func ambiguousNoFill() {
        let categories = [
            GradeCategory(id: "c1", name: "Homework", items: [
                Self.canvasItem(id: "a1", name: "Homework 3", points: 100),
                Self.canvasItem(id: "a2", name: "Homework 3", points: 100),
            ]),
        ]
        let gs = [Self.gsItem("Homework 3", earned: 90, max: 100)]

        let result = GradescopeOverlay.apply(categories: categories, gradescopeItems: gs)

        #expect(result.categories[0].items.allSatisfy { $0.score == nil })
        #expect(result.unmatched.count == 1)
        #expect(result.unmatched.first?.reason == .ambiguous)
        #expect(result.unmatched.first?.title == "Homework 3")
    }

    @Test("ambiguous when neither tiebreak candidate matches Gradescope's max points")
    func ambiguousWhenTiebreakFindsNoMatch() {
        let categories = [
            GradeCategory(id: "c1", name: "Homework", items: [
                Self.canvasItem(id: "a1", name: "Homework 3", points: 50),
                Self.canvasItem(id: "a2", name: "Homework 3", points: 75),
            ]),
        ]
        let gs = [Self.gsItem("Homework 3", earned: 90, max: 100)]

        let result = GradescopeOverlay.apply(categories: categories, gradescopeItems: gs)

        #expect(result.categories[0].items.allSatisfy { $0.score == nil })
        #expect(result.unmatched.first?.reason == .ambiguous)
    }

    @Test("Canvas score present: never overwritten, and not shown as unmatched")
    func canvasScorePresentNoOverwrite() {
        let categories = [
            GradeCategory(id: "c1", name: "Homework", items: [
                Self.canvasItem(id: "a1", name: "Homework 3", points: 100, score: 95),
            ]),
        ]
        let gs = [Self.gsItem("Homework 3", earned: 87.5, max: 100)]

        let result = GradescopeOverlay.apply(categories: categories, gradescopeItems: gs)

        #expect(result.categories[0].items[0].score == 95)
        #expect(result.categories[0].items[0].scoreSource == .canvas)
        // Iron rule: agreed silently, not listed as unmatched (see type doc comment).
        #expect(result.unmatched.isEmpty)
    }

    @Test("double-fill prevention: a second Gradescope item can't fill an already-filled Canvas item")
    func doubleFillPrevention() {
        let categories = [
            GradeCategory(id: "c1", name: "Homework", items: [
                Self.canvasItem(id: "a1", name: "Homework 3", points: 100),
            ]),
        ]
        // Two distinct Gradescope entries (e.g. a duplicate scrape) both name "Homework 3".
        let gs = [
            Self.gsItem("Homework 3", earned: 87.5, max: 100),
            Self.gsItem("Homework 3", earned: 90, max: 100),
        ]

        let result = GradescopeOverlay.apply(categories: categories, gradescopeItems: gs)

        #expect(result.categories[0].items[0].score == 87.5)
        #expect(result.unmatched.count == 1)
        #expect(result.unmatched.first?.reason == .alreadyFilled)
        #expect(result.unmatched.first?.scoreEarned == 90)
    }

    @Test("no candidate: unmatched with reason noCandidate")
    func noCandidateUnmatched() {
        let categories = [
            GradeCategory(id: "c1", name: "Homework", items: [
                Self.canvasItem(id: "a1", name: "Homework 3", points: 100),
            ]),
        ]
        let gs = [Self.gsItem("Lab 9", earned: 10, max: 10)]

        let result = GradescopeOverlay.apply(categories: categories, gradescopeItems: gs)

        #expect(result.categories[0].items[0].score == nil)
        #expect(result.unmatched.count == 1)
        #expect(result.unmatched.first?.reason == .noCandidate)
        #expect(result.unmatched.first?.title == "Lab 9")
        #expect(result.unmatched.first?.scoreEarned == 10)
        #expect(result.unmatched.first?.scoreMax == 10)
    }

    @Test("Gradescope never adds an assignment — categories/items are never added or removed")
    func neverAddsAssignments() {
        let categories = [
            GradeCategory(id: "c1", name: "Homework", items: [
                Self.canvasItem(id: "a1", name: "Homework 3", points: 100),
            ]),
        ]
        let gs = [
            Self.gsItem("Homework 3", earned: 90, max: 100),
            Self.gsItem("Totally New Assignment", earned: 10, max: 10),
        ]

        let result = GradescopeOverlay.apply(categories: categories, gradescopeItems: gs)

        #expect(result.categories.count == 1)
        #expect(result.categories[0].items.count == 1)
        #expect(result.unmatched.contains { $0.title == "Totally New Assignment" })
    }

    @Test("ungraded Gradescope items are ignored, not listed as unmatched")
    func ungradedItemsIgnored() {
        let categories = [
            GradeCategory(id: "c1", name: "Homework", items: [
                Self.canvasItem(id: "a1", name: "Homework 3", points: 100),
            ]),
        ]
        let gs = [Self.gsItem("Homework 4", earned: nil, max: nil)]

        let result = GradescopeOverlay.apply(categories: categories, gradescopeItems: gs)

        #expect(result.unmatched.isEmpty)
        #expect(result.categories[0].items[0].score == nil)
    }

    // MARK: - Fuzzy tier (docs/grades.md §5 item 4) — proposed, never auto-applied

    @Test("fuzzy match ('HW 3 — Recursion' vs 'Homework 3') is proposed as a suggestion, not auto-applied")
    func fuzzyMatchIsSuggestedNotApplied() throws {
        let categories = [
            GradeCategory(id: "c1", name: "Homework", items: [
                Self.canvasItem(id: "a1", name: "Homework 3", points: 100),
            ]),
        ]
        let gs = [Self.gsItem("HW 3 \u{2014} Recursion", earned: 90, max: 100)]

        let result = GradescopeOverlay.apply(categories: categories, gradescopeItems: gs)

        // Not auto-applied: the Canvas item stays unscored...
        #expect(result.categories[0].items[0].score == nil)
        #expect(result.unmatched.isEmpty)
        // ...but surfaced as a suggestion for the user to confirm.
        #expect(result.suggested.count == 1)
        let suggestion = try #require(result.suggested.first)
        #expect(suggestion.itemID == "a1")
        #expect(suggestion.itemName == "Homework 3")
        #expect(suggestion.gradescopeTitle == "HW 3 \u{2014} Recursion")
        #expect(suggestion.scoreEarned == 90)
        #expect(suggestion.scoreMax == 100)
        #expect(suggestion.confidence > 0 && suggestion.confidence < 1)
    }

    @Test("a title with no meaningful token overlap at all stays unmatched, not suggested")
    func belowThresholdStaysUnmatched() {
        let categories = [
            GradeCategory(id: "c1", name: "Homework", items: [
                Self.canvasItem(id: "a1", name: "Homework 3", points: 100),
            ]),
        ]
        let gs = [Self.gsItem("Final Project Writeup", earned: 90, max: 100)]

        let result = GradescopeOverlay.apply(categories: categories, gradescopeItems: gs)

        #expect(result.suggested.isEmpty)
        #expect(result.unmatched.count == 1)
        #expect(result.unmatched.first?.reason == .noCandidate)
    }

    @Test("fuzzy candidates tied on similarity are disambiguated by the max-points tiebreaker, then proposed (not applied)")
    func fuzzyTieBrokenByMaxPointsIsStillOnlySuggested() {
        let categories = [
            GradeCategory(id: "c1", name: "Homework", items: [
                Self.canvasItem(id: "a1", name: "Homework 3 Recursion", points: 50),
                Self.canvasItem(id: "a2", name: "Homework 3 Recursion", points: 100),
            ]),
        ]
        // "HW3" fuzzy-matches both equally (same Jaccard score against each
        // identical name); the 100-point Gradescope max should disambiguate.
        let gs = [Self.gsItem("HW3", earned: 90, max: 100)]

        let result = GradescopeOverlay.apply(categories: categories, gradescopeItems: gs)

        #expect(result.categories.flatMap(\.items).allSatisfy { $0.score == nil })
        #expect(result.suggested.count == 1)
        #expect(result.suggested.first?.itemID == "a2")
        #expect(result.unmatched.isEmpty)
    }

    @Test("fuzzy candidates tied on similarity with no max-points tiebreak either land as ambiguous, not suggested")
    func fuzzyTieUnresolvedIsAmbiguous() {
        let categories = [
            GradeCategory(id: "c1", name: "Homework", items: [
                Self.canvasItem(id: "a1", name: "Homework 3 Recursion", points: 40),
                Self.canvasItem(id: "a2", name: "Homework 3 Recursion", points: 75),
            ]),
        ]
        let gs = [Self.gsItem("HW3", earned: 90, max: 100)]

        let result = GradescopeOverlay.apply(categories: categories, gradescopeItems: gs)

        #expect(result.suggested.isEmpty)
        #expect(result.unmatched.count == 1)
        #expect(result.unmatched.first?.reason == .ambiguous)
    }

    @Test("a fuzzy match is never proposed for a Canvas item Canvas already scored")
    func fuzzyMatchNeverProposedOverCanvasScore() {
        let categories = [
            GradeCategory(id: "c1", name: "Homework", items: [
                Self.canvasItem(id: "a1", name: "Homework 3", points: 100, score: 95),
            ]),
        ]
        let gs = [Self.gsItem("HW 3 \u{2014} Recursion", earned: 90, max: 100)]

        let result = GradescopeOverlay.apply(categories: categories, gradescopeItems: gs)

        #expect(result.categories[0].items[0].score == 95) // untouched
        #expect(result.suggested.isEmpty)
        #expect(result.unmatched.isEmpty) // Canvas already agreed -- not even listed
    }

    // MARK: - Confirmed mappings (docs/grades.md §5, last paragraph)

    @Test("a confirmed mapping auto-applies exactly like an exact match, keyed by normalizedKey(gradescopeTitle)")
    func confirmedMappingAutoApplies() {
        let categories = [
            GradeCategory(id: "c1", name: "Homework", items: [
                Self.canvasItem(id: "a1", name: "Homework 3", points: 100),
            ]),
        ]
        let gs = [Self.gsItem("HW 3 \u{2014} Recursion", earned: 90, max: 100)]
        let confirmed = [GradescopeOverlay.normalizedKey("HW 3 \u{2014} Recursion"): "a1"]

        let result = GradescopeOverlay.apply(categories: categories, gradescopeItems: gs, confirmedMappings: confirmed)

        #expect(result.categories[0].items[0].score == 90)
        #expect(result.categories[0].items[0].scoreSource == .gradescopeEarly)
        #expect(result.suggested.isEmpty)
        #expect(result.unmatched.isEmpty)
    }

    @Test("a confirmed mapping is ignored (falls through to normal matching) once the target item already has a Canvas score")
    func confirmedMappingIgnoredWhenTargetAlreadyScored() {
        let categories = [
            GradeCategory(id: "c1", name: "Homework", items: [
                Self.canvasItem(id: "a1", name: "Homework 3", points: 100, score: 95),
            ]),
        ]
        let gs = [Self.gsItem("HW 3 \u{2014} Recursion", earned: 90, max: 100)]
        let confirmed = [GradescopeOverlay.normalizedKey("HW 3 \u{2014} Recursion"): "a1"]

        let result = GradescopeOverlay.apply(categories: categories, gradescopeItems: gs, confirmedMappings: confirmed)

        #expect(result.categories[0].items[0].score == 95) // iron rule still holds
        #expect(result.suggested.isEmpty)
        #expect(result.unmatched.isEmpty)
    }

    @Test("normalizedKey is stable across superficial title differences the same way namesMatch is")
    func normalizedKeyMatchesNamesMatchEquivalence() {
        #expect(GradescopeOverlay.normalizedKey("HW3") == GradescopeOverlay.normalizedKey("Homework 3"))
        #expect(GradescopeOverlay.normalizedKey("HW3") == GradescopeOverlay.normalizedKey("hw 03"))
        #expect(GradescopeOverlay.normalizedKey("Homework 3") != GradescopeOverlay.normalizedKey("Homework 4"))
    }

    @Test("matching is scoped to the items passed in — caller pre-filters by course")
    func matchingIsPerCourseInputOnly() {
        // No cross-course concept inside the overlay itself: it only ever sees
        // whatever categories/items the caller hands it. Two identically-named
        // items in different (hypothetical) courses would just be two separate
        // `apply` calls in practice, so this test documents that a single call
        // fills at most the items actually present in its own `categories`.
        let categories = [
            GradeCategory(id: "c1", name: "Homework", items: [
                Self.canvasItem(id: "a1", name: "Homework 3", points: 100),
            ]),
        ]
        let gs = [Self.gsItem("Homework 3", earned: 90, max: 100)]
        let result = GradescopeOverlay.apply(categories: categories, gradescopeItems: gs)
        #expect(result.categories.flatMap(\.items).count == 1)
    }
}
