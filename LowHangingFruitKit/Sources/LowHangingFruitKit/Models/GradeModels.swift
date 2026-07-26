import Foundation

/// Where a number in the grade math came from. Canvas is authoritative; a
/// Gradescope score is an "early" overlay that fills a gap Canvas hasn't graded
/// yet; manual covers user-entered values (today: category weights).
public enum ScoreSource: String, Sendable, Codable, Hashable {
    case canvas
    case gradescopeEarly
    case manual
    /// A category weight read from the user's own syllabus and confirmed by
    /// them. Distinct from `.manual` so the UI can say where a number came
    /// from — "your syllabus" is checkable against a document; "manual" isn't.
    case syllabus

    /// Short, user-facing provenance label.
    public var label: String {
        switch self {
        case .canvas:          return "Canvas"
        case .gradescopeEarly: return "Gradescope early"
        case .manual:          return "manual"
        case .syllabus:        return "your syllabus"
        }
    }
}

/// One gradeable Canvas assignment as the grade engine sees it. Gradescope
/// never adds items — it may only fill `score` (with `scoreSource` marking the
/// provenance) on an item Canvas already defines.
public struct GradeItem: Sendable, Hashable, Codable, Identifiable {
    /// Canvas assignment id (stringified).
    public let id: String
    public let name: String
    /// Canvas `points_possible`. 0 means extra credit — the item can add earned
    /// points but never contributes to a denominator.
    public let pointsPossible: Double
    /// The awarded score. nil means "not decided yet" — the engine keys off
    /// score presence, never off submission state.
    public let score: Double?
    /// Provenance of `score`; nil when `score` is nil.
    public let scoreSource: ScoreSource?
    /// Canvas `submission.excused` — excluded from BOTH earned and possible.
    public let isExcused: Bool
    /// Canvas `omit_from_final_grade` — excluded from the math entirely.
    public let omitFromFinalGrade: Bool
    /// Due date, used only to count past-due-unscored items ("pending grading").
    public let dueAt: Date?

    public init(
        id: String,
        name: String,
        pointsPossible: Double,
        score: Double? = nil,
        scoreSource: ScoreSource? = nil,
        isExcused: Bool = false,
        omitFromFinalGrade: Bool = false,
        dueAt: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.pointsPossible = pointsPossible
        self.score = score
        self.scoreSource = scoreSource
        self.isExcused = isExcused
        self.omitFromFinalGrade = omitFromFinalGrade
        self.dueAt = dueAt
    }
}

/// One Canvas assignment group. `weight` is Canvas's `group_weight` — it is
/// present-but-garbage unless the COURSE's `apply_assignment_group_weights`
/// flag is true, which is why the engine takes that flag separately and never
/// trusts `weight` on its own.
public struct GradeCategory: Sendable, Hashable, Codable, Identifiable {
    /// Canvas assignment group id (stringified).
    public let id: String
    public let name: String
    /// Canvas `group_weight` in percent (e.g. 40 = 40%). Only meaningful when
    /// the course uses weights.
    public let weight: Double?
    /// Canvas `rules.drop_lowest` (0 = none).
    public let dropLowest: Int
    /// Canvas `rules.drop_highest` (0 = none).
    public let dropHighest: Int
    /// Canvas `rules.never_drop` — assignment ids pinned by the professor.
    public let neverDropIDs: Set<String>
    public let items: [GradeItem]

    public init(
        id: String,
        name: String,
        weight: Double? = nil,
        dropLowest: Int = 0,
        dropHighest: Int = 0,
        neverDropIDs: Set<String> = [],
        items: [GradeItem] = []
    ) {
        self.id = id
        self.name = name
        self.weight = weight
        self.dropLowest = dropLowest
        self.dropHighest = dropHighest
        self.neverDropIDs = neverDropIDs
        self.items = items
    }
}

/// How the course's grade is combined across categories.
public enum GradingMode: String, Sendable, Codable, Hashable {
    /// Categories carry weights (`apply_assignment_group_weights` true, or the
    /// user supplied manual weights).
    case weighted
    /// One implicit bucket: straight points earned over points possible.
    case points
}

/// The engine's full answer for one course: the headline numbers plus the
/// per-category breakdown the UI expands into.
public struct GradeBreakdown: Sendable, Hashable, Codable {
    public struct CategoryResult: Sendable, Hashable, Codable, Identifiable {
        public let id: String
        public let name: String
        /// The weight used in the math, in percent, BEFORE renormalization
        /// (e.g. 40 for a 40% category). nil in points mode.
        public let effectiveWeight: Double?
        /// Where `effectiveWeight` came from (`canvas` or `manual`); nil in
        /// points mode.
        public let weightSource: ScoreSource?
        /// Points earned over scored, kept (post-drop) items.
        public let earned: Double
        /// Points possible over scored, kept (post-drop) items.
        public let possibleScored: Double
        /// Points possible over ALL gradeable items (scored or not, no drops).
        public let possibleTotal: Double
        /// Points possible over scored items **before** drop rules are applied.
        /// This — not `possibleScored` — is what "how much of this category is
        /// decided" means (docs/grades.md Decision 6: % decided ignores drops
        /// so it stays monotonic), and it's what `GradeProjection` divides by
        /// to split the final grade into banked vs still-open.
        public let possibleScoredRaw: Double
        /// Scored gradeable items, before drops.
        public let scoredCount: Int
        /// All gradeable items (excused / omitted excluded).
        public let totalCount: Int
        /// Items removed by drop-lowest / drop-highest rules.
        public let droppedItemIDs: Set<String>

        /// The category's own grade in percent, or nil when nothing scored
        /// carries possible points (extra-credit-only guards divide-by-zero).
        public var percent: Double? {
            guard possibleScored > 0 else { return nil }
            return earned / possibleScored * 100
        }
    }

    public let mode: GradingMode
    /// Current grade in percent (can exceed 100 with extra credit). nil means
    /// "no scores yet" — deliberately distinct from 0%.
    public let currentPercent: Double?
    /// Share of the final grade already decided, 0...1.
    public let decidedFraction: Double
    /// Past-due items still waiting on a score — surfaced so the headline
    /// number never looks silently rosy.
    public let pendingGradingCount: Int
    public let categories: [CategoryResult]
}
