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

    public struct Result: Sendable {
        /// `categories`, with any successfully-matched item's `score` /
        /// `scoreSource` filled in. Never adds or removes an item or category.
        public let categories: [GradeCategory]
        public let unmatched: [UnmatchedItem]
    }

    /// Applies the overlay. `gradescopeItems` should already be scoped to this
    /// course; only entries with both `scoreEarned` and `scoreMax` present are
    /// considered (an ungraded Gradescope item has nothing to overlay and isn't
    /// "unmatched" — it's simply irrelevant here).
    public static func apply(categories: [GradeCategory], gradescopeItems: [Assignment]) -> Result {
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

        for g in scoredItems {
            guard let earned = g.scoreEarned, let max = g.scoreMax else { continue }
            let gTokens = normalize(g.title)

            let allMatches: [(categoryIndex: Int, itemIndex: Int, item: GradeItem)] =
                categories.enumerated().flatMap { categoryIndex, category in
                    category.items.enumerated().compactMap { itemIndex, item in
                        normalize(item.name) == gTokens ? (categoryIndex, itemIndex, item) : nil
                    }
                }

            guard !allMatches.isEmpty else {
                unmatched.append(UnmatchedItem(title: g.title, scoreEarned: earned, scoreMax: max, reason: .noCandidate))
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

            usedItemIDs.insert(winner.item.id)
            let filled = GradeItem(
                id: winner.item.id,
                name: winner.item.name,
                pointsPossible: winner.item.pointsPossible,
                score: earned,
                scoreSource: .gradescopeEarly,
                isExcused: winner.item.isExcused,
                omitFromFinalGrade: winner.item.omitFromFinalGrade,
                dueAt: winner.item.dueAt
            )
            var items = mutableCategories[winner.categoryIndex].items
            items[winner.itemIndex] = filled
            let category = mutableCategories[winner.categoryIndex]
            mutableCategories[winner.categoryIndex] = GradeCategory(
                id: category.id,
                name: category.name,
                weight: category.weight,
                dropLowest: category.dropLowest,
                dropHighest: category.dropHighest,
                neverDropIDs: category.neverDropIDs,
                items: items
            )
        }

        return Result(categories: mutableCategories, unmatched: unmatched)
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
    /// item 3); the lower-confidence fuzzy/edit-distance tier (§5 item 4, meant
    /// to be user-confirmable) isn't implemented in CP5 — see the checkpoint
    /// report for why.
    public static func namesMatch(_ a: String, _ b: String) -> Bool {
        normalize(a) == normalize(b)
    }

    static func normalize(_ raw: String) -> [String] {
        var s = raw.lowercased()
        s = s.replacingOccurrences(of: #"[^a-z0-9\s]"#, with: " ", options: .regularExpression)
        // Phrase-level collapse before word-splitting so "problem set" (two
        // words) lines up with single-word "pset"/"homework".
        s = s.replacingOccurrences(of: #"\bproblem\s+sets?\b"#, with: "hw", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)

        guard !s.isEmpty else { return [] }

        var tokens: [String] = []
        for word in s.split(separator: " ") {
            tokens.append(contentsOf: splitLetterDigitRuns(String(word)))
        }
        return tokens.map(canonicalize)
    }

    /// Splits a token like "hw3" into ["hw", "3"] at the letter/digit
    /// boundary, so "HW3" and "HW 3" normalize to the same token sequence.
    private static func splitLetterDigitRuns(_ word: String) -> [String] {
        var result: [String] = []
        var current = ""
        var currentIsDigit: Bool?
        for ch in word {
            let isDigit = ch.isNumber
            if currentIsDigit == nil || currentIsDigit == isDigit {
                current.append(ch)
            } else {
                result.append(current)
                current = String(ch)
            }
            currentIsDigit = isDigit
        }
        if !current.isEmpty { result.append(current) }
        return result
    }

    private static func canonicalize(_ token: String) -> String {
        // Numeric tokens compare by value, so leading zeros don't matter.
        if let intValue = Int(token) { return String(intValue) }
        switch token {
        case "hw", "homework", "pset", "psets": return "hw"
        case "lab", "labs": return "lab"
        case "quiz", "quizzes": return "quiz"
        default: return token
        }
    }
}
