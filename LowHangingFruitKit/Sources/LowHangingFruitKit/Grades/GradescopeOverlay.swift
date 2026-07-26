import Foundation

/// Fuzzy-matches Gradescope's already-scored items onto Canvas grade items and
/// fills the gap — never adds an assignment (docs/grades.md §4, §5). Pure
/// logic, no I/O: the caller is responsible for scoping `gradescopeItems` to
/// one course (already course-matched via `CourseCode`) before calling `apply`.
///
/// **The iron rule:** Gradescope may only fill a Canvas `GradeItem` whose
/// `score` is currently `nil`. Priority is Canvas score > Gradescope early
/// score > none, and a Gradescope item that names an assignment Canvas already
/// scored is silently dropped — "not even shown as unmatched, it agreed" (§4
/// step 1) — rather than listed as unmatched. (The prose a few lines below
/// that rule in the spec also describes that case as landing in the unmatched
/// list; this implementation follows the more specific/deliberate step-1
/// wording, which is also what CP5's own test list assumes by naming
/// "Canvas-score-present → no overwrite" as a case distinct from "unmatched
/// listing.")
public enum GradescopeOverlay {
    /// Why a scored Gradescope item didn't end up filling anything.
    public enum UnmatchedReason: String, Sendable, Hashable {
        /// No Canvas assignment name matched at all.
        case noCandidate
        /// 2+ open Canvas candidates tied on name and couldn't be
        /// disambiguated by max points either.
        case ambiguous
        /// The only name-matching Canvas item(s) were already filled by
        /// another Gradescope item earlier in this same pass (one Gradescope
        /// item fills at most one Canvas item and vice versa).
        case alreadyFilled
    }

    /// A Gradescope score that never got applied to the course's math —
    /// surfaced in the UI's "unmatched" review list, never counted.
    public struct UnmatchedItem: Sendable, Hashable {
        public let title: String
        public let scoreEarned: Double
        public let scoreMax: Double
        public let reason: UnmatchedReason

        public init(title: String, scoreEarned: Double, scoreMax: Double, reason: UnmatchedReason) {
            self.title = title
            self.scoreEarned = scoreEarned
            self.scoreMax = scoreMax
            self.reason = reason
        }
    }

    /// A lower-confidence (token/fuzzy) name match (docs/grades.md §5 item 4)
    /// — proposed, never auto-applied. The UI surfaces this as a suggestion
    /// next to the unmatched list with an explicit confirm action; confirming
    /// persists the mapping (`normalizedKey(gradescopeTitle)` → `itemID`) so
    /// the user isn't re-asked on the next sync.
    public struct SuggestedMatch: Sendable, Hashable {
        public let categoryID: String
        public let itemID: String
        public let itemName: String
        public let gradescopeTitle: String
        public let scoreEarned: Double
        public let scoreMax: Double
        /// Jaccard similarity of the two titles' normalized token sets, 0...1.
        public let confidence: Double

        public init(
            categoryID: String,
            itemID: String,
            itemName: String,
            gradescopeTitle: String,
            scoreEarned: Double,
            scoreMax: Double,
            confidence: Double
        ) {
            self.categoryID = categoryID
            self.itemID = itemID
            self.itemName = itemName
            self.gradescopeTitle = gradescopeTitle
            self.scoreEarned = scoreEarned
            self.scoreMax = scoreMax
            self.confidence = confidence
        }
    }

    public struct Result: Sendable {
        /// `categories`, with any successfully-matched item's `score` /
        /// `scoreSource` filled in. Never adds or removes an item or category.
        public let categories: [GradeCategory]
        public let unmatched: [UnmatchedItem]
        /// Fuzzy candidates awaiting user confirmation (docs/grades.md §5 item
        /// 4) — never counted in `categories` until confirmed.
        public let suggested: [SuggestedMatch]

        public init(categories: [GradeCategory], unmatched: [UnmatchedItem], suggested: [SuggestedMatch] = []) {
            self.categories = categories
            self.unmatched = unmatched
            self.suggested = suggested
        }
    }

    /// Below this Jaccard similarity on normalized token sets, two titles
    /// aren't even proposed as a fuzzy match (docs/grades.md §5 item 4).
    private static let fuzzyMatchThreshold = 0.5

    /// Applies the overlay. `gradescopeItems` should already be scoped to this
    /// course; only entries with both `scoreEarned` and `scoreMax` present are
    /// considered (an ungraded Gradescope item has nothing to overlay and isn't
    /// "unmatched" — it's simply irrelevant here).
    ///
    /// `confirmedMappings` is `normalizedKey(gradescopeTitle) → Canvas item id`
    /// — previously user-confirmed fuzzy matches (docs/grades.md §5, last
    /// paragraph). A confirmed mapping auto-applies exactly like an exact
    /// match, so the user isn't re-asked every sync.
    public static func apply(
        categories: [GradeCategory],
        gradescopeItems: [Assignment],
        confirmedMappings: [String: String] = [:]
    ) -> Result {
        let scoredItems = gradescopeItems.filter { $0.scoreEarned != nil && $0.scoreMax != nil }
        guard !scoredItems.isEmpty else {
            return Result(categories: categories, unmatched: [])
        }

        // Canvas items that had no score BEFORE this overlay ran — computed
        // once, up front, so mutating a copy below never changes how a later
        // Gradescope item classifies an item ("originally open" is a fixed
        // fact about the input, not a moving target as we fill things in).
        let originallyOpenIDs = Set(
            categories.flatMap(\.items).filter { $0.score == nil }.map(\.id)
        )

        var mutableCategories = categories
        var usedItemIDs: Set<String> = []
        var unmatched: [UnmatchedItem] = []
        var suggested: [SuggestedMatch] = []

        func fill(categoryIndex: Int, itemIndex: Int, original: GradeItem, earned: Double) {
            usedItemIDs.insert(original.id)
            let filled = GradeItem(
                id: original.id,
                name: original.name,
                pointsPossible: original.pointsPossible,
                score: earned,
                scoreSource: .gradescopeEarly,
                isExcused: original.isExcused,
                omitFromFinalGrade: original.omitFromFinalGrade,
                dueAt: original.dueAt
            )
            var items = mutableCategories[categoryIndex].items
            items[itemIndex] = filled
            let category = mutableCategories[categoryIndex]
            mutableCategories[categoryIndex] = GradeCategory(
                id: category.id,
                name: category.name,
                weight: category.weight,
                dropLowest: category.dropLowest,
                dropHighest: category.dropHighest,
                neverDropIDs: category.neverDropIDs,
                items: items
            )
        }

        /// Locates an item by id in the ORIGINAL (unmutated) `categories`, so
        /// a confirmed mapping is looked up against a stable index regardless
        /// of what earlier Gradescope items in this same pass already filled.
        func locate(itemID: String) -> (categoryIndex: Int, itemIndex: Int, item: GradeItem)? {
            for (categoryIndex, category) in categories.enumerated() {
                if let itemIndex = category.items.firstIndex(where: { $0.id == itemID }) {
                    return (categoryIndex, itemIndex, category.items[itemIndex])
                }
            }
            return nil
        }

        for g in scoredItems {
            guard let earned = g.scoreEarned, let max = g.scoreMax else { continue }
            let gTokens = normalize(g.title)
            let gKey = tokenKey(gTokens)

            // A previously-confirmed fuzzy match short-circuits everything
            // else — it behaves exactly like an exact match from here on.
            if let confirmedItemID = confirmedMappings[gKey],
               let located = locate(itemID: confirmedItemID),
               originallyOpenIDs.contains(located.item.id),
               !usedItemIDs.contains(located.item.id) {
                fill(categoryIndex: located.categoryIndex, itemIndex: located.itemIndex, original: located.item, earned: earned)
                continue
            }

            let allMatches: [(categoryIndex: Int, itemIndex: Int, item: GradeItem)] =
                categories.enumerated().flatMap { categoryIndex, category in
                    category.items.enumerated().compactMap { itemIndex, item in
                        normalize(item.name) == gTokens ? (categoryIndex, itemIndex, item) : nil
                    }
                }

            guard !allMatches.isEmpty else {
                // No exact match — try the lower-confidence fuzzy tier
                // (docs/grades.md §5 item 4) before giving up entirely.
                let allFuzzy = fuzzyCandidates(gTokens: gTokens, categories: categories, usedItemIDs: usedItemIDs)
                let openFuzzy = allFuzzy.filter { originallyOpenIDs.contains($0.item.id) }

                guard !openFuzzy.isEmpty else {
                    if allFuzzy.contains(where: { !originallyOpenIDs.contains($0.item.id) }) {
                        // The only fuzzy candidate(s) are items Canvas already
                        // scored — same iron rule as the exact-match tier:
                        // silently dropped, not unmatched (it agreed).
                        continue
                    }
                    unmatched.append(UnmatchedItem(title: g.title, scoreEarned: earned, scoreMax: max, reason: .noCandidate))
                    continue
                }

                if let winner = bestFuzzyCandidate(openFuzzy, targetPoints: max) {
                    // Proposed only — never auto-applied (spec: "user-confirmable").
                    suggested.append(SuggestedMatch(
                        categoryID: categories[winner.categoryIndex].id,
                        itemID: winner.item.id,
                        itemName: winner.item.name,
                        gradescopeTitle: g.title,
                        scoreEarned: earned,
                        scoreMax: max,
                        confidence: winner.score
                    ))
                } else {
                    // Multiple open fuzzy candidates, tied, unresolved by the
                    // max-points tiebreaker either — same as the exact-match
                    // ambiguity case, but at the fuzzy tier.
                    unmatched.append(UnmatchedItem(title: g.title, scoreEarned: earned, scoreMax: max, reason: .ambiguous))
                }
                continue
            }

            let openMatches = allMatches.filter {
                originallyOpenIDs.contains($0.item.id) && !usedItemIDs.contains($0.item.id)
            }
            let canvasScoredMatches = allMatches.filter { !originallyOpenIDs.contains($0.item.id) }

            guard !openMatches.isEmpty else {
                if !canvasScoredMatches.isEmpty {
                    // Canvas already has a score for every name-match — the
                    // iron rule says Gradescope never overwrites it. Silently
                    // dropped, not unmatched (see the type-level doc comment).
                    continue
                }
                // Every name-match was an item this same pass already filled.
                unmatched.append(UnmatchedItem(title: g.title, scoreEarned: earned, scoreMax: max, reason: .alreadyFilled))
                continue
            }

            let winner: (categoryIndex: Int, itemIndex: Int, item: GradeItem)
            if openMatches.count == 1 {
                winner = openMatches[0]
            } else if let tieBroken = uniqueMaxPointsMatch(openMatches, target: max) {
                winner = tieBroken
            } else {
                unmatched.append(UnmatchedItem(title: g.title, scoreEarned: earned, scoreMax: max, reason: .ambiguous))
                continue
            }

            fill(categoryIndex: winner.categoryIndex, itemIndex: winner.itemIndex, original: winner.item, earned: earned)
        }

        return Result(categories: mutableCategories, unmatched: unmatched, suggested: suggested)
    }

    // MARK: - Fuzzy tier (docs/grades.md §5 item 4)

    /// Canvas items (open or already Canvas-scored — the caller separates
    /// those, mirroring the exact-match tier's iron-rule handling) whose
    /// normalized token set is at least `fuzzyMatchThreshold` similar
    /// (Jaccard) to the Gradescope title's, excluding exact matches (those are
    /// handled by the exact-match tier above and never reach here) and items
    /// another Gradescope item already filled this pass.
    private static func fuzzyCandidates(
        gTokens: [String],
        categories: [GradeCategory],
        usedItemIDs: Set<String>
    ) -> [(categoryIndex: Int, itemIndex: Int, item: GradeItem, score: Double)] {
        let gSet = Set(gTokens)
        guard !gSet.isEmpty else { return [] }
        return categories.enumerated().flatMap { categoryIndex, category in
            category.items.enumerated().compactMap { itemIndex, item -> (Int, Int, GradeItem, Double)? in
                guard !usedItemIDs.contains(item.id) else { return nil }
                let iTokens = normalize(item.name)
                guard iTokens != gTokens else { return nil } // exact match, not this tier
                let iSet = Set(iTokens)
                guard !iSet.isEmpty else { return nil }
                let score = jaccardSimilarity(gSet, iSet)
                guard score >= fuzzyMatchThreshold else { return nil }
                return (categoryIndex, itemIndex, item, score)
            }
        }
    }

    /// Picks the single best fuzzy candidate: highest Jaccard score, with the
    /// max-points tiebreaker (docs/grades.md §5 item 5) applied when two or
    /// more candidates tie on that top score. Returns nil (still ambiguous)
    /// when the tie can't be resolved.
    private static func bestFuzzyCandidate(
        _ candidates: [(categoryIndex: Int, itemIndex: Int, item: GradeItem, score: Double)],
        targetPoints: Double
    ) -> (categoryIndex: Int, itemIndex: Int, item: GradeItem, score: Double)? {
        guard let topScore = candidates.map(\.score).max() else { return nil }
        let top = candidates.filter { $0.score == topScore }
        if top.count == 1 { return top[0] }

        let tied = top.map { (categoryIndex: $0.categoryIndex, itemIndex: $0.itemIndex, item: $0.item) }
        guard let tieBroken = uniqueMaxPointsMatch(tied, target: targetPoints) else { return nil }
        return (tieBroken.categoryIndex, tieBroken.itemIndex, tieBroken.item, topScore)
    }

    /// |A ∩ B| / |A ∪ B|, the standard Jaccard similarity coefficient over two
    /// normalized token sets (docs/grades.md §5 item 4 names this explicitly).
    private static func jaccardSimilarity(_ a: Set<String>, _ b: Set<String>) -> Double {
        TitleNormalizer.jaccard(a, b)
    }

    /// docs/grades.md §5.5: when multiple open candidates tie on name, prefer
    /// the one whose `pointsPossible` equals Gradescope's max points — but only
    /// if that narrows the field to exactly one; otherwise it's still ambiguous.
    private static func uniqueMaxPointsMatch(
        _ candidates: [(categoryIndex: Int, itemIndex: Int, item: GradeItem)],
        target: Double
    ) -> (categoryIndex: Int, itemIndex: Int, item: GradeItem)? {
        let matching = candidates.filter { abs($0.item.pointsPossible - target) < 0.001 }
        return matching.count == 1 ? matching[0] : nil
    }

    // MARK: - Name normalization (docs/grades.md §5.1)

    /// Two titles are considered the same assignment if they reduce to the
    /// same token sequence: lowercase, punctuation stripped, "HW" / "Homework"
    /// / "PSet" / "Problem Set" collapsed to one canonical `hw` token (a
    /// "problem set" and "homework" are the same kind of thing under different
    /// professors' naming), "Lab"/"Labs" → `lab`, "Quiz"/"Quizzes" → `quiz`,
    /// and numbers compared by value so "03" == "3" and "HW3" == "Homework 3"
    /// == "hw 03". Only exact normalized equality auto-applies here (spec §5
    /// item 3); the lower-confidence fuzzy tier (§5 item 4) is a separate,
    /// never-auto-applied path — see `fuzzyCandidates`/`bestFuzzyCandidate`
    /// above, which run only when this returns false for every Canvas item.
    public static func namesMatch(_ a: String, _ b: String) -> Bool {
        normalize(a) == normalize(b)
    }

    /// Stable string key for a normalized token sequence — used to key
    /// confirmed-mapping persistence (`apply(confirmedMappings:)`) by "course +
    /// normalized title" (docs/grades.md §5, last paragraph) without exposing
    /// the token array representation to callers outside this module.
    public static func normalizedKey(_ raw: String) -> String {
        tokenKey(normalize(raw))
    }

    private static func tokenKey(_ tokens: [String]) -> String {
        tokens.joined(separator: " ")
    }

    static func normalize(_ raw: String) -> [String] {
        TitleNormalizer.tokens(raw)
    }
}
