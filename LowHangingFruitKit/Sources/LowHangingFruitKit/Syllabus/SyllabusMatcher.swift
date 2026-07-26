import Foundation

/// Maps a syllabus's grading categories onto the course's Canvas assignment
/// groups. The syllabus says "Problem Sets"; Canvas says "Homework". Until
/// those two are the same thing, a syllabus weight can't reach the math.
///
/// Same three tiers as the Gradescope overlay (docs/grades.md §5), and the
/// same rule: exact matches apply, fuzzy matches are *proposed*, and anything
/// left over is shown rather than guessed at.
public enum SyllabusMatcher {
    /// Minimum token-set similarity for a fuzzy proposal. Low enough that
    /// "Case Writeups" reaches "Case Studies" (⅓), high enough that unrelated
    /// names don't pair up.
    public static let fuzzyThreshold = 0.3

    public enum Tier: String, Sendable, Hashable, Codable {
        /// Names normalize identically — applied without asking.
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
        public let canvasCategoryID: String?
        public let canvasCategoryName: String?
        /// Token-set similarity, 1 for exact/confirmed.
        public let confidence: Double
        public let tier: Tier

        public var id: String { syllabusCategoryID }
        /// Whether this pairing may feed the grade math right now.
        public var isApplied: Bool { tier == .exact || tier == .confirmed }
    }

    public struct Result: Sendable, Hashable {
        public let matches: [Match]
        /// Canvas groups no syllabus category claimed. These are why coverage
        /// can be incomplete, and the report lists them by name so the user
        /// knows exactly what to map.
        public let unmatchedCanvasCategories: [GradeCategory]

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
                guard let id = match.canvasCategoryID else { return }
                result[id] = match.weightPercent
            }
        }
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
        let canvasByID = Dictionary(uniqueKeysWithValues: canvasCategories.map { ($0.id, $0) })

        var used: Set<String> = []
        var matches: [Match] = []

        for category in categories {
            if let confirmedID = confirmed[category.id],
               let canvas = canvasByID[confirmedID],
               !used.contains(confirmedID) {
                used.insert(confirmedID)
                matches.append(Match(
                    syllabusCategoryID: category.id,
                    syllabusName: category.name,
                    weightPercent: category.weightPercent,
                    canvasCategoryID: canvas.id,
                    canvasCategoryName: canvas.name,
                    confidence: 1,
                    tier: .confirmed
                ))
                continue
            }

            let available = canvasCategories.filter { !used.contains($0.id) }

            if let exact = available.first(where: {
                TitleNormalizer.categoryKey($0.name) == TitleNormalizer.categoryKey(category.name)
            }) {
                used.insert(exact.id)
                matches.append(Match(
                    syllabusCategoryID: category.id,
                    syllabusName: category.name,
                    weightPercent: category.weightPercent,
                    canvasCategoryID: exact.id,
                    canvasCategoryName: exact.name,
                    confidence: 1,
                    tier: .exact
                ))
                continue
            }

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
                        syllabusCategoryID: category.id,
                        syllabusName: category.name,
                        weightPercent: category.weightPercent,
                        canvasCategoryID: best.canvas.id,
                        canvasCategoryName: best.canvas.name,
                        confidence: best.score,
                        tier: .fuzzy
                    ))
                    continue
                }
            }

            matches.append(Match(
                syllabusCategoryID: category.id,
                syllabusName: category.name,
                weightPercent: category.weightPercent,
                canvasCategoryID: nil,
                canvasCategoryName: nil,
                confidence: 0,
                tier: .unmatched
            ))
        }

        let claimed = Set(matches.filter(\.isApplied).compactMap(\.canvasCategoryID))
        return Result(
            matches: matches,
            unmatchedCanvasCategories: canvasCategories.filter { !claimed.contains($0.id) }
        )
    }
}
