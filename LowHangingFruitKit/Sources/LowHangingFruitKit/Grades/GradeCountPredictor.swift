import Foundation

/// Turns whatever the app currently knows about ONE grade category — a
/// student's own override, a syllabus-stated count, the implication baked
/// into the category's own name ("Midterm 2" only ever means one), or
/// nothing at all — into a single predicted item count for the WHOLE
/// semester, with a `Source` so the UI can say where the number came from.
///
/// This exists so `GradeEngine` never has to fall back to "we don't know"
/// (`semesterDecidedFraction == nil`) just because a syllabus never got
/// around to stating how many quizzes there will be. Before this type
/// existed, a category with no stated count contributed nothing to the
/// semester estimate at all, and in weighted mode that poisoned the WHOLE
/// course's estimate to nil the instant any weighted category couldn't
/// answer — so a course with a syllabus that names every category's WEIGHT
/// but not every category's COUNT (the common case: syllabi state "quizzes
/// are worth 15%" far more often than "there will be 8 quizzes") permanently
/// read as "semester share unknown," which is a worse answer than a rough
/// projection would have been.
///
/// The wrong design here — and it looks completely reasonable at first — is
/// to treat the number of items ALREADY POSTED as the semester count. Two
/// weeks into term, with 2 of an eventual 14 quizzes posted and both graded,
/// that reads as "100% of quizzes decided," which is exactly the real-phone
/// bug ("63% of your grade is decided" from 2 of a semester's 12 labs) this
/// whole feature exists to fix, just relocated to a new cause: a prediction
/// has to reason about the REST of the semester, not just what already
/// exists in Canvas today.
public enum GradeCountPredictor {
    /// A predicted whole-semester item count for one category, plus where it
    /// came from.
    public struct Prediction: Sendable, Hashable, Codable {
        /// Where a `Prediction.count` came from, ordered by precedence —
        /// each is tried only after every source above it came back empty.
        public enum Source: String, Sendable, Hashable, Codable {
            /// The student typed a count (`GradeEngine.Input.expectedCounts`).
            case override
            /// The syllabus, or a category map built from one, stated it.
            case stated
            /// The category's own name implies exactly one item — "Midterm
            /// 2", "Final" — so no syllabus statement was ever needed.
            case impliedByName
            /// Canvas already lists this many items and there was no term to
            /// project a bigger number from (no due date anywhere in the
            /// category, or the term just started), or the projection came
            /// back no bigger than what's already listed.
            case listed
            /// The category's own pace-so-far, projected across the whole
            /// term, exceeds what Canvas has listed.
            case projected
        }

        public let count: Int
        public let source: Source

        public init(count: Int, source: Source) {
            self.count = count
            self.source = source
        }
    }

    /// The academic term a course's own items imply: start = the earliest
    /// `dueAt` across every item in every category, length `weeks` (default
    /// 14 — a Penn semester's ordinary run of instruction before finals).
    ///
    /// Anchored on the earliest DUE DATE rather than the registrar's actual
    /// term-start date because the registrar's dates aren't on the device
    /// yet (`docs`/known-gaps: the catalog carries components, not term
    /// boundaries, as of this writing) — the earliest thing Canvas has ever
    /// asked the student to do is the only start-of-term signal already in
    /// hand. It is necessarily a slight underestimate of the true term start
    /// (classes start before the first assignment is due), which makes
    /// `elapsedFraction` run slightly FAST rather than slow — the safer
    /// direction, since a projection that thinks more of the term has
    /// passed than actually has still floors its count at what Canvas has
    /// already listed, while one that thinks LESS has passed could predict
    /// a count lower than reality and read as more "decided" than it is.
    public struct Term: Sendable, Hashable, Codable {
        public let start: Date
        public let weeks: Double

        public init(start: Date, weeks: Double = 14) {
            self.start = start
            self.weeks = weeks
        }

        /// Weeks elapsed at `now`, clamped to `0...weeks` — never negative
        /// (a `now` before `start`, e.g. a masked `GradeTrajectory` point
        /// computed before the term's first due date) and never past the
        /// term's own length (a `now` after finals shouldn't inflate the
        /// pace projection beyond what a full semester would have produced).
        public func elapsedWeeks(at now: Date) -> Double {
            let secondsPerWeek = 7.0 * 24.0 * 60.0 * 60.0
            let raw = now.timeIntervalSince(start) / secondsPerWeek
            return min(max(raw, 0), weeks)
        }

        /// `elapsedWeeks(at:) / weeks`, clamped to `0...1`.
        public func elapsedFraction(at now: Date) -> Double {
            guard weeks > 0 else { return 0 }
            return min(max(elapsedWeeks(at: now) / weeks, 0), 1)
        }
    }

    /// The term implied by a set of categories' own items, or nil when none
    /// of them carry a due date at all (a brand-new course sync with no
    /// dates yet) — there is nothing to anchor a term to, so callers fall
    /// back to whatever `predict` does with a nil term (posted-count-only,
    /// never a projection built on no information).
    public static func term(for categories: [GradeCategory], weeks: Double = 14) -> Term? {
        let earliest = categories.flatMap(\.items).compactMap(\.dueAt).min()
        guard let earliest else { return nil }
        return Term(start: earliest, weeks: weeks)
    }

    /// Predicts one category's whole-semester item count. `items` are the
    /// category's own GRADEABLE items — already excluding excused, omitted,
    /// and map-excluded ones; callers pass the same filtered list they tally
    /// the rest of the category's math from, so "how many items exist" and
    /// "how many items are predicted" agree about what counts as an item.
    ///
    /// First match wins, in the order listed on `Prediction.Source`. Every
    /// branch is floored at `max(items.count, 1)` — the predicted count
    /// never drops below what Canvas has already listed (a syllabus or a
    /// stale override that names fewer items than are already posted is a
    /// STALE STATEMENT, not evidence that the extra items don't count — the
    /// same "never below posted" rule `GradeEngine`'s older
    /// `expectedPossible` helper enforced) and never drops to zero (a
    /// category with a real weight and no known count yet still needs SOME
    /// denominator to be honestly "0% decided" rather than undefined).
    public static func predict(
        categoryName: String,
        items: [GradeItem],
        overrideCount: Int?,
        statedCount: Int?,
        term: Term?,
        now: Date
    ) -> Prediction {
        let listed = items.count
        func floored(_ n: Int) -> Int { max(n, listed, 1) }

        if let overrideCount {
            return Prediction(count: floored(overrideCount), source: .override)
        }
        if let statedCount {
            return Prediction(count: floored(statedCount), source: .stated)
        }
        if let implied = GradeCategoryMapBuilder.defaultExpectedCount(forCategoryName: categoryName) {
            return Prediction(count: floored(implied), source: .impliedByName)
        }

        // No statement anywhere -- project from pace, but only once the
        // term has run long enough that "items so far ÷ weeks so far" means
        // anything. Inside the first week (or with no term to measure
        // against at all -- a course synced before any due date exists),
        // dividing by a near-zero `elapsedWeeks` would blow the projection
        // up arbitrarily from a single early item, so fall back to the
        // plain listed count instead.
        guard let term, term.elapsedWeeks(at: now) >= 1 else {
            return Prediction(count: floored(listed), source: .listed)
        }

        let dueSoFar = items.filter { $0.dueAt == nil || $0.dueAt! <= now }.count
        let elapsedWeeks = term.elapsedWeeks(at: now)
        let pace = Double(dueSoFar) / elapsedWeeks
        let projected = Int((pace * term.weeks).rounded())
        let count = max(listed, projected, 1)
        let source: Prediction.Source = projected > listed ? .projected : .listed
        return Prediction(count: count, source: source)
    }
}
