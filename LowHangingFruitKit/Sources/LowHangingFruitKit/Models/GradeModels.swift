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
    /// Canvas `submission_types` — e.g. `["online_upload"]`, `["none"]`,
    /// `["on_paper", "online_upload"]`. nil/empty when Canvas didn't say.
    public let submissionTypes: [String]?

    public init(
        id: String,
        name: String,
        pointsPossible: Double,
        score: Double? = nil,
        scoreSource: ScoreSource? = nil,
        isExcused: Bool = false,
        omitFromFinalGrade: Bool = false,
        dueAt: Date? = nil,
        submissionTypes: [String]? = nil
    ) {
        self.id = id
        self.name = name
        self.pointsPossible = pointsPossible
        self.score = score
        self.scoreSource = scoreSource
        self.isExcused = isExcused
        self.omitFromFinalGrade = omitFromFinalGrade
        self.dueAt = dueAt
        self.submissionTypes = submissionTypes
    }

    /// True when Canvas expects no online submission for this assignment —
    /// every declared submission type is `none`, `on_paper`, or `not_graded`.
    /// A hybrid (e.g. paper OR online upload) still expects a submission and
    /// stays false. Unknown/absent submission types stay false: never guess
    /// an assignment out of the student's way.
    public var requiresNoSubmission: Bool {
        guard let submissionTypes, !submissionTypes.isEmpty else { return false }
        return submissionTypes.allSatisfy { ["none", "on_paper", "not_graded"].contains($0) }
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

/// A student-entered correction to one Canvas grade item. Distinct from
/// Canvas's own `omit_from_final_grade` and `points_possible`/`score` fields
/// because this is the STUDENT's own decision, layered on top of Canvas's
/// numbers rather than replacing them at the source -- a Canvas correction or
/// resync still shows through the moment the override is cleared. Applied
/// first, before any mode/weight/drop math runs (`GradeEngine.compute`), so
/// the rest of the engine never has to know an override happened.
public struct GradeItemOverride: Sendable, Hashable, Codable {
    /// Replaces Canvas's `score` when non-nil. nil keeps Canvas's score.
    public var score: Double?
    /// Replaces Canvas's `pointsPossible` when non-nil. nil keeps Canvas's
    /// points possible.
    public var pointsPossible: Double?
    /// Removes the item from the math entirely -- earned, possible, and item
    /// counts alike -- exactly like Canvas's own `omit_from_final_grade`, but
    /// this flag is the student's call, not the professor's.
    public var isExcluded: Bool

    public init(score: Double? = nil, pointsPossible: Double? = nil, isExcluded: Bool = false) {
        self.score = score
        self.pointsPossible = pointsPossible
        self.isExcluded = isExcluded
    }

    /// True when this override would change nothing, i.e. it's a leftover
    /// placeholder (e.g. an edit UI that was opened and cancelled) rather than
    /// an actual correction. The engine treats an empty override as if it
    /// weren't present at all.
    public var isEmpty: Bool { score == nil && pointsPossible == nil && !isExcluded }
}

/// Where the weighted-vs-points decision -- and, in weighted mode, the
/// weights themselves -- came from. Distinct from `ScoreSource` (which is
/// per-category/per-item provenance) because this describes the MODE
/// decision for the whole course.
public enum GradingModeSource: String, Sendable, Codable, Hashable {
    /// Canvas's own `apply_assignment_group_weights` flag / `group_weight`s,
    /// or the ordinary points-mode default.
    case canvas
    /// `GradeEngine.Input.modeOverride` forced the mode.
    case manual
    /// Every weight-bearing category's weight is a confirmed syllabus weight
    /// (`Input.syllabusWeightedCategoryIDs` covers every category).
    case syllabus
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
        /// This category's expected item count for the WHOLE semester, read
        /// from the syllabus via `GradeEngine.Input.expectedCounts`. nil when
        /// nothing is known beyond what Canvas has posted so far -- Canvas
        /// only ever tells us about work that already exists.
        public let expectedCount: Int?
        /// This category's share of decided work against the WHOLE SEMESTER,
        /// as opposed to `possibleScoredRaw ÷ possibleTotal` (what the
        /// top-level `decidedFraction` is built from), which only ever sees
        /// items Canvas has posted. This is the fix for the real-phone report
        /// that motivated it: 2 of 3 POSTED labs reading as two-thirds of the
        /// semester when a syllabus says there will be 12. nil when
        /// `expectedCount` is unknown, or when `totalCount == 0` (nothing
        /// posted yet -- there's no average points-per-item to extrapolate
        /// an estimate from).
        public let semesterDecidedFraction: Double?
        /// Whether this category actually counts toward `currentPercent`
        /// right now: weighted mode needs a positive `effectiveWeight` AND
        /// scored, point-bearing work; points mode needs only the latter.
        /// Mirrors the filters `GradeEngine`'s current-percent helpers apply
        /// internally, exposed so callers (the UI, `contributionPercent`
        /// below) don't have to reverse-engineer them.
        public let participates: Bool
        /// How many of the headline `currentPercent` points this category is
        /// responsible for (e.g. "+28.2 of your 91.4") -- a
        /// pie-chart-without-a-pie-chart number. nil exactly when
        /// `participates` is false; summing this across every category with
        /// `participates == true` reproduces `currentPercent`.
        public let contributionPercent: Double?
        /// Items whose `score` or `pointsPossible` a `GradeItemOverride`
        /// replaced, so the UI can badge them distinctly from a Canvas or
        /// Gradescope number.
        public let overriddenItemIDs: Set<String>
        /// Items a `GradeItemOverride` removed from the math entirely
        /// (`isExcluded`) -- kept for the same reason `droppedItemIDs` is,
        /// so the UI can explain why a number looks smaller than the raw
        /// item list rather than leaving it unexplained.
        public let excludedItemIDs: Set<String>

        /// The category's own grade in percent, or nil when nothing scored
        /// carries possible points (extra-credit-only guards divide-by-zero).
        public var percent: Double? {
            guard possibleScored > 0 else { return nil }
            return earned / possibleScored * 100
        }
    }

    public let mode: GradingMode
    /// Current grade in percent (can exceed 100 with extra credit). nil means
    /// "no scores yet" — deliberately distinct from 0%. Also forced to nil
    /// whenever `decidedFraction == 0`, even if a per-mode helper somehow
    /// produced a number: a real phone once showed "100%" next to "0%
    /// decided" from a scored zero-point item, and nothing with points
    /// possible scored means there is no honest percent to show yet.
    public let currentPercent: Double?
    /// Share of the final grade already decided, out of what CANVAS HAS
    /// POSTED so far — NOT the whole semester (see `semesterDecidedFraction`
    /// for that). A course where the professor has posted only 2 of a
    /// semester's 12 labs can read 100% here once those 2 are graded, which
    /// is exactly the real-phone report ("63% decided" two weeks into term)
    /// that `semesterDecidedFraction` exists to correct — as an ADDITIONAL,
    /// more honest number, not by changing what this one has always meant.
    public let decidedFraction: Double
    /// Past-due items still waiting on a score — surfaced so the headline
    /// number never looks silently rosy.
    public let pendingGradingCount: Int
    public let categories: [CategoryResult]
    /// Share of the WHOLE SEMESTER already decided, extrapolated from
    /// `expectedCounts` rather than only what Canvas has posted. Weighted
    /// mode sums normalized-weight × per-category `semesterDecidedFraction`
    /// and goes nil the instant any non-zero-weight category can't answer;
    /// points mode instead sums the raw scored/expected points across every
    /// category first and divides once, so a category with nothing posted
    /// yet contributes zero to both sums rather than blocking the estimate.
    /// See `GradeEngine`'s `semesterDecidedFraction(_:weighted:)` for the
    /// exact rule in each mode.
    public let semesterDecidedFraction: Double?
    /// Where the weighted-vs-points decision (and the weights themselves, in
    /// weighted mode) came from.
    public let modeSource: GradingModeSource
    /// Weighted-mode categories that carry real weight but haven't been
    /// touched yet (no scored, point-bearing work) — the ones renormalization
    /// quietly excludes from `currentPercent`, named so the UI can say so
    /// instead of leaving a silent gap. Always empty in points mode, which
    /// has no weight concept to leave anything out of.
    public let leftOutCategoryIDs: [String]
    /// Σ `effectiveWeight` over the categories renormalization actually used
    /// for `currentPercent` (docs/grades.md §2's weighted-average
    /// denominator) — exposed so callers can compute or check category
    /// contributions without recomputing this filter themselves. nil in
    /// points mode, which has no weights to sum.
    public let participatingWeightSum: Double?
}
