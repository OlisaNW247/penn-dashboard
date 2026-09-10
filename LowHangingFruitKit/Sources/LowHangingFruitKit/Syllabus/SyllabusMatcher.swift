import Foundation

/// Maps a syllabus's grading categories onto the course's Canvas assignment
/// groups. The syllabus says "Problem Sets"; Canvas says "Homework". Until
/// those two are the same thing, a syllabus weight can't reach the math.
///
/// Same three tiers as the Gradescope overlay (docs/grades.md §5), and the
/// same rule: exact matches apply, fuzzy matches are *proposed*, and anything
/// left over is shown rather than guessed at.
///
/// **Many-to-one (2026-09-10).** A real PHYS 0151 syllabus lists one 10%
/// "HomeWorks" category that Canvas's site splits across two assignment
/// groups, "Problem Sets" and "Worksheets" — the professor's own site
/// structure, not the syllabus's. So a single syllabus category can now claim
/// SEVERAL Canvas groups (`Match.canvasCategoryIDs`); a Canvas group still
/// belongs to at most one syllabus category. Recognizing this doesn't need
/// fuzzy guessing most of the time — "Problem Sets" and "Worksheets" are both
/// unambiguously homework, "Midterm 2" is unambiguously an exam — so a small,
/// deterministic synonym table (below) is checked BEFORE falling back to
/// token-similarity fuzzy matching, and a synonym hit applies immediately
/// (`.exact`, per that tier's existing "normalize identically" contract —
/// the synonym table is simply part of what normalizing identically now
/// means for a category name, the same way `TitleNormalizer` already folds
/// "PSet" and "Problem Set" together for assignment TITLES). Numbered exam
/// names are the one place a synonym match still isn't safe to assume:
/// "Midterm 1" and "Midterm 2" are the same FAMILY but not the same THING, so
/// they only ever match each other by number (see `examNumbersCompatible`).
public enum SyllabusMatcher {
    /// Minimum token-set similarity for a fuzzy proposal. Low enough that
    /// "Case Writeups" reaches "Case Studies" (⅓), high enough that unrelated
    /// names don't pair up.
    public static let fuzzyThreshold = 0.3

    public enum Tier: String, Sendable, Hashable, Codable {
        /// Names normalize identically — applied without asking. This also
        /// covers a synonym-table hit (docs above): "Worksheets" and
        /// "HomeWorks" are different strings but the same category, exactly
        /// as confidently as a literal string match, so it gets the same
        /// tier rather than a new one that every existing exhaustive
        /// `switch` on `Tier` (there is one in `SyllabusSetupView`) would
        /// have to be taught about.
        case exact
        /// The user previously confirmed this pairing; applied like an exact
        /// match so they aren't re-asked on every refresh.
        case confirmed
        /// Proposed. Never counted until confirmed.
        case fuzzy
        /// No Canvas group looks like this syllabus category.
        case unmatched
    }

    public struct Match: Sendable, Hashable, Identifiable {
        public let syllabusCategoryID: String
        public let syllabusName: String
        public let weightPercent: Double
        /// Every Canvas group this syllabus category claimed — the
        /// many-to-one fold. Empty exactly when `tier == .unmatched`.
        public let canvasCategoryIDs: [String]
        public let canvasCategoryNames: [String]
        /// Token-set similarity, 1 for exact/confirmed/synonym.
        public let confidence: Double
        public let tier: Tier

        public init(
            syllabusCategoryID: String,
            syllabusName: String,
            weightPercent: Double,
            canvasCategoryIDs: [String],
            canvasCategoryNames: [String],
            confidence: Double,
            tier: Tier
        ) {
            self.syllabusCategoryID = syllabusCategoryID
            self.syllabusName = syllabusName
            self.weightPercent = weightPercent
            self.canvasCategoryIDs = canvasCategoryIDs
            self.canvasCategoryNames = canvasCategoryNames
            self.confidence = confidence
            self.tier = tier
        }

        public var id: String { syllabusCategoryID }
        /// Whether this pairing may feed the grade math right now.
        public var isApplied: Bool { tier == .exact || tier == .confirmed }
        /// First claimed Canvas group, or nil for an unmatched category —
        /// kept for every caller written before many-to-one existed
        /// (`SyllabusReconciler`, `SyllabusSetupView`, the original test
        /// suite below), none of which need to know about a fold to do their
        /// job of reporting on or picking ONE representative group.
        public var canvasCategoryID: String? { canvasCategoryIDs.first }
        public var canvasCategoryName: String? { canvasCategoryNames.first }
    }

    public struct Result: Sendable, Hashable {
        public let matches: [Match]
        /// Canvas groups no syllabus category claimed. These are why coverage
        /// can be incomplete, and the report lists them by name so the user
        /// knows exactly what to map.
        public let unmatchedCanvasCategories: [GradeCategory]
        /// Syllabus categories with no Canvas group at all — surfaced
        /// separately from `unmatchedCanvasCategories` because the fix is
        /// different: an unmatched CANVAS category needs mapping to
        /// something; an unmatched SYLLABUS category (e.g. "Midterm 3" on a
        /// syllabus that promises three midterms when Canvas has only
        /// created two) needs nothing from the user yet — it's simply not
        /// posted, and will resolve itself once the professor creates it.
        public let unmatchedSyllabusCategories: [SyllabusCategory]
        /// Canvas category id → the weight of the syllabus category that
        /// claimed it, for every APPLIED match regardless of overall
        /// coverage. Unlike `canvasWeights` below, this is never gated on
        /// `isCompleteCoverage` — `GradeCategoryMapBuilder` wants "whatever
        /// we're confident about" even when the syllabus doesn't cover the
        /// whole course, which is exactly the situation
        /// `GradeEngine`'s all-or-nothing `manualWeights` can't tolerate but
        /// a category MAP (weighted per its own categories, unmapped groups
        /// simply carrying weight 0) can.
        public let appliedWeights: [String: Double]

        public init(
            matches: [Match],
            unmatchedCanvasCategories: [GradeCategory],
            unmatchedSyllabusCategories: [SyllabusCategory] = [],
            appliedWeights: [String: Double] = [:]
        ) {
            self.matches = matches
            self.unmatchedCanvasCategories = unmatchedCanvasCategories
            self.unmatchedSyllabusCategories = unmatchedSyllabusCategories
            self.appliedWeights = appliedWeights
        }

        /// True when every Canvas group that can carry weight has an applied
        /// syllabus weight.
        ///
        /// This gates everything, because `GradeEngine` treats manual weights
        /// as all-or-nothing: a partial set would silently zero out the
        /// categories it doesn't cover. Half a syllabus is worse than none.
        public var isCompleteCoverage: Bool {
            unmatchedCanvasCategories.isEmpty && matches.allSatisfy(\.isApplied)
        }

        /// Canvas category id → weight, ready for `GradeEngine.Input`. Empty
        /// unless coverage is complete.
        public var canvasWeights: [String: Double] {
            guard isCompleteCoverage else { return [:] }
            return matches.reduce(into: [:]) { result, match in
                guard match.isApplied else { return }
                for id in match.canvasCategoryIDs { result[id] = match.weightPercent }
            }
        }
    }

    // MARK: - Synonym families

    /// A syllabus/Canvas category name reduced to a family + optional
    /// trailing number, e.g. "Midterm 2" → (`.exam`, 2), "Exams" → (`.exam`,
    /// nil), "Problem Sets" → (`.homework`, nil). `nil` overall means the
    /// name doesn't recognizably belong to any family, so only the fuzzy tier
    /// can still match it.
    private enum Family: String {
        case homework, exam, quiz, lab, project, participation, finalExam
    }

    /// Every member is stored already run through `TitleNormalizer
    /// .categoryKey`, so lookups are a single dictionary hit rather than a
    /// re-normalization at match time. Multi-word members ("final exam")
    /// stay multi-word keys; that's fine, `categoryKey` output for a
    /// single-word input never contains a space so there's no collision.
    private static let familyMembers: [Family: Set<String>] = [
        // Both "hw" and "homework" are listed because `TitleNormalizer`
        // canonicalizes the SINGULAR "Homework" to "hw" at the per-word step
        // (before pluralization is even considered) but has no plural entry,
        // so "Homeworks" only reaches "hw" after `categoryTokens`'
        // *singularize* pass turns "homeworks" into "homework" — the two
        // spellings land on different final tokens depending on whether the
        // professor wrote the name with a trailing "s".
        .homework: ["hw", "homework", "worksheet", "assignment"],
        .exam: ["exam", "midterm", "test"],
        .quiz: ["quiz"],
        .lab: ["lab"],
        .project: ["project"],
        .participation: ["attendance", "participation"],
        .finalExam: ["final", "final exam"],
    ]

    /// Splits off a single trailing numeric token ("Midterm 2" → base
    /// "Midterm", number 2) before family lookup, so "Midterm 1"/"Midterm 2"
    /// both resolve to the `.exam` family instead of each being a family of
    /// one. Only ever meaningful within `.exam` today (see
    /// `examNumbersCompatible`) but computed generically since nothing about
    /// extracting the number is exam-specific.
    private static func baseNameAndNumber(_ name: String) -> (base: String, number: Int?) {
        let tokens = TitleNormalizer.categoryTokens(name)
        guard let last = tokens.last, let number = Int(last) else {
            return (TitleNormalizer.categoryKey(name), nil)
        }
        return (tokens.dropLast().joined(separator: " "), number)
    }

    private static func family(of name: String) -> (family: Family, number: Int?)? {
        let (base, number) = baseNameAndNumber(name)
        for (family, members) in familyMembers where members.contains(base) {
            return (family, number)
        }
        return nil
    }

    /// The numbered-exam exception: two exam-family names match unqualified
    /// UNLESS one or both carry a number, in which case the numbers must
    /// agree — a Canvas "Midterm 1" is never folded into a syllabus "Midterm
    /// 2". A plain name (no number) on one side may still match a numbered
    /// name on the other, but only when nothing on the PLAIN side's own list
    /// is itself numbered — otherwise there's a more specific category that
    /// should have claimed it instead, and guessing which numbered entry a
    /// plain one "really" means is exactly the kind of guess this matcher
    /// refuses to make (ties go to `.unmatched`, not to a coin flip).
    private static func examNumbersCompatible(
        syllabusNumber: Int?,
        canvasNumber: Int?,
        anyNumberedSyllabusSiblingExists: Bool,
        anyNumberedCanvasSiblingExists: Bool
    ) -> Bool {
        if let syllabusNumber, let canvasNumber {
            return syllabusNumber == canvasNumber
        }
        if syllabusNumber == nil, canvasNumber != nil {
            return !anyNumberedSyllabusSiblingExists
        }
        if syllabusNumber != nil, canvasNumber == nil {
            return !anyNumberedCanvasSiblingExists
        }
        // Neither side carries a number -- nothing to disambiguate.
        return true
    }

    /// - Parameters:
    ///   - confirmed: syllabus category id → Canvas category id, from previous
    ///     user confirmations.
    public static func match(
        scheme: SyllabusGradingScheme,
        canvasCategories: [GradeCategory],
        confirmed: [String: String] = [:]
    ) -> Result {
        // Heaviest categories first: when two syllabus categories compete for
        // the same Canvas group, the one carrying more of the grade should win
        // the greedy assignment.
        let categories = scheme.normalizedCategories.sorted { $0.weightPercent > $1.weightPercent }

        // Computed once, over the WHOLE scheme/course (not just what's still
        // "available" at some point mid-loop), because the numbered-exam
        // exception above needs to know whether a more specific numbered
        // category exists at all, not whether it happens to still be
        // unclaimed at the moment a particular plain name is considered.
        let anyNumberedSyllabusExamExists = categories.contains { category in
            guard let info = family(of: category.name), info.family == .exam else { return false }
            return info.number != nil
        }
        let anyNumberedCanvasExamExists = canvasCategories.contains { canvas in
            guard let info = family(of: canvas.name), info.family == .exam else { return false }
            return info.number != nil
        }

        var used: Set<String> = []
        var matches: [Match] = []

        for category in categories {
            let available = canvasCategories.filter { !used.contains($0.id) }

            // Tier 1: exact normalized name.
            if let exact = available.first(where: {
                TitleNormalizer.categoryKey($0.name) == TitleNormalizer.categoryKey(category.name)
            }) {
                used.insert(exact.id)
                matches.append(Match(
                    syllabusCategoryID: category.id, syllabusName: category.name,
                    weightPercent: category.weightPercent,
                    canvasCategoryIDs: [exact.id], canvasCategoryNames: [exact.name],
                    confidence: 1, tier: .exact
                ))
                continue
            }

            // Tier 2: a previously confirmed pairing.
            if let confirmedID = confirmed[category.id],
               let canvas = available.first(where: { $0.id == confirmedID }) {
                used.insert(canvas.id)
                matches.append(Match(
                    syllabusCategoryID: category.id, syllabusName: category.name,
                    weightPercent: category.weightPercent,
                    canvasCategoryIDs: [canvas.id], canvasCategoryNames: [canvas.name],
                    confidence: 1, tier: .confirmed
                ))
                continue
            }

            // Tier 3: synonym family — may claim MORE THAN ONE available
            // Canvas group at once (the many-to-one fold).
            if let syllabusFamily = family(of: category.name) {
                let familyMatches = available.filter { canvas in
                    guard let canvasFamily = family(of: canvas.name), canvasFamily.family == syllabusFamily.family else {
                        return false
                    }
                    guard syllabusFamily.family == .exam else { return true }
                    return examNumbersCompatible(
                        syllabusNumber: syllabusFamily.number,
                        canvasNumber: canvasFamily.number,
                        anyNumberedSyllabusSiblingExists: anyNumberedSyllabusExamExists,
                        anyNumberedCanvasSiblingExists: anyNumberedCanvasExamExists
                    )
                }
                if !familyMatches.isEmpty {
                    used.formUnion(familyMatches.map(\.id))
                    matches.append(Match(
                        syllabusCategoryID: category.id, syllabusName: category.name,
                        weightPercent: category.weightPercent,
                        canvasCategoryIDs: familyMatches.map(\.id),
                        canvasCategoryNames: familyMatches.map(\.name),
                        confidence: 1, tier: .exact
                    ))
                    continue
                }
            }

            // Tier 4: fuzzy — proposed, single best candidate, never applied
            // automatically.
            let scored = available
                .map { (canvas: $0, score: TitleNormalizer.categorySimilarity($0.name, category.name)) }
                .filter { $0.score >= fuzzyThreshold }
                .sorted { $0.score > $1.score }

            if let best = scored.first {
                // A tie between two equally-plausible groups is ambiguous, not
                // a match — proposing one at random is how a wrong weight ends
                // up on a real grade.
                let isAmbiguous = scored.count > 1 && abs(scored[1].score - best.score) < 0.0001
                if !isAmbiguous {
                    used.insert(best.canvas.id)
                    matches.append(Match(
                        syllabusCategoryID: category.id, syllabusName: category.name,
                        weightPercent: category.weightPercent,
                        canvasCategoryIDs: [best.canvas.id], canvasCategoryNames: [best.canvas.name],
                        confidence: best.score, tier: .fuzzy
                    ))
                    continue
                }
            }

            matches.append(Match(
                syllabusCategoryID: category.id, syllabusName: category.name,
                weightPercent: category.weightPercent,
                canvasCategoryIDs: [], canvasCategoryNames: [],
                confidence: 0, tier: .unmatched
            ))
        }

        let claimed = Set(matches.filter(\.isApplied).flatMap(\.canvasCategoryIDs))
        let appliedWeights: [String: Double] = matches
            .filter(\.isApplied)
            .reduce(into: [:]) { result, match in
                for id in match.canvasCategoryIDs { result[id] = match.weightPercent }
            }
        let unmatchedSyllabus = categories.filter { category in
            matches.first { $0.syllabusCategoryID == category.id }?.tier == .unmatched
        }

        return Result(
            matches: matches,
            unmatchedCanvasCategories: canvasCategories.filter { !claimed.contains($0.id) },
            unmatchedSyllabusCategories: unmatchedSyllabus,
            appliedWeights: appliedWeights
        )
    }
}
