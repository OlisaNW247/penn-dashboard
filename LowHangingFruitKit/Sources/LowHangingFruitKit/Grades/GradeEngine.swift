import Foundation

/// Pure grade math — no I/O, fully deterministic. See docs/grades.md §2–3.
///
/// Two modes, chosen by the COURSE-level `apply_assignment_group_weights` flag
/// (never by the presence of `group_weight`, which is garbage when the flag is
/// false) or by user-supplied manual weights:
///
/// - **Weighted:** current grade is a renormalized weighted average over the
///   categories that have scored work; % decided is Σ w_c × (scored possible ÷
///   total possible) per category.
/// - **Points:** one implicit bucket; Σ earned ÷ Σ possible over scored items.
///
/// "Scored" always means `score != nil` on a non-excused, non-omitted item —
/// submission state is irrelevant to the math.
public enum GradeEngine {
    /// Everything the engine needs for one course.
    public struct Input: Sendable {
        /// Canvas's course-level `apply_assignment_group_weights` flag.
        public let courseUsesWeights: Bool
        public let categories: [GradeCategory]
        /// User-entered weight overrides (category id → percent). Overrides
        /// Canvas weights per category. On a points-mode course this is
        /// all-or-nothing: manual weights only switch the course into
        /// weighted mode (the ONLY fallback when Canvas has no weights) once
        /// EVERY category has a manual entry — a partial set is ignored
        /// entirely rather than silently zeroing out the categories that
        /// don't have one. Categories without an entry fall back to their
        /// Canvas weight (weighted courses) or 0.
        public let manualWeights: [String: Double]
        /// User overrides for drop-lowest (category id → count). Falls back to
        /// the category's Canvas `rules.drop_lowest`.
        public let dropLowestOverrides: [String: Int]
        /// Which of `manualWeights` came from a confirmed syllabus rather than
        /// being typed in. Purely provenance — it changes the reported
        /// `weightSource`, never the arithmetic — so the UI can distinguish a
        /// weight the user can check against a document from one they entered
        /// by hand.
        public let syllabusWeightedCategoryIDs: Set<String>
        /// Reference time for the past-due-unscored ("pending grading") count.
        public let now: Date

        public init(
            courseUsesWeights: Bool,
            categories: [GradeCategory],
            manualWeights: [String: Double] = [:],
            dropLowestOverrides: [String: Int] = [:],
            syllabusWeightedCategoryIDs: Set<String> = [],
            now: Date = Date()
        ) {
            self.courseUsesWeights = courseUsesWeights
            self.categories = categories
            self.manualWeights = manualWeights
            self.dropLowestOverrides = dropLowestOverrides
            self.syllabusWeightedCategoryIDs = syllabusWeightedCategoryIDs
            self.now = now
        }
    }

    /// Our number vs Canvas's `computed_current_score` cross-check: only a
    /// material disagreement (> 1 percentage point) is worth surfacing —
    /// anything smaller is rounding noise. No Canvas number, no note.
    public static func differsFromCanvas(
        computed: Double,
        canvasScore: Double?,
        threshold: Double = 1.0
    ) -> Bool {
        guard let canvasScore else { return false }
        return abs(computed - canvasScore) > threshold
    }

    public static func compute(_ input: Input) -> GradeBreakdown {
        let weighted = input.courseUsesWeights || manualWeightsCoverEveryCategory(input)
        let tallies = input.categories.map { tally($0, input: input, weighted: weighted) }
        let results = tallies.map(\.result)

        let currentPercent = weighted
            ? weightedCurrentPercent(tallies)
            : pointsCurrentPercent(tallies)
        let decided = weighted
            ? weightedDecidedFraction(tallies)
            : pointsDecidedFraction(tallies)
        let pending = tallies
            .filter { !weighted || ($0.result.effectiveWeight ?? 0) > 0 }
            .reduce(0) { $0 + $1.pendingCount }

        return GradeBreakdown(
            mode: weighted ? .weighted : .points,
            currentPercent: currentPercent,
            decidedFraction: decided,
            pendingGradingCount: pending,
            categories: results
        )
    }

    /// All-or-nothing gate for the points-mode → weighted-mode switch: manual
    /// weights only take effect once EVERY category has one. A partial set
    /// used to flip the whole course to weighted mode while leaving
    /// no-manual-weight categories at `effectiveWeight == 0` — silently
    /// dropping them from the grade. Requiring full coverage means a
    /// half-finished manual-weight edit just leaves the course in points
    /// mode (manual weights ignored) instead of silently corrupting it.
    private static func manualWeightsCoverEveryCategory(_ input: Input) -> Bool {
        guard !input.categories.isEmpty, !input.manualWeights.isEmpty else { return false }
        return input.categories.allSatisfy { input.manualWeights[$0.id] != nil }
    }

    // MARK: - Per-category tally

    private struct CategoryTally {
        let result: GradeBreakdown.CategoryResult
        let pendingCount: Int

        /// Points possible over scored items BEFORE drops — % decided ignores
        /// drop rules so it stays monotonic as scores arrive. Lives on the
        /// result itself now (projections need it too); kept as a shorthand
        /// so the mode math below still reads cleanly.
        var possibleScoredRaw: Double { result.possibleScoredRaw }
    }

    private static func tally(
        _ category: GradeCategory,
        input: Input,
        weighted: Bool
    ) -> CategoryTally {
        // Excused and omit_from_final_grade items leave the math entirely.
        let gradeable = category.items.filter { !$0.isExcused && !$0.omitFromFinalGrade }
        let scored = gradeable.filter { $0.score != nil }

        let dropped = droppedItemIDs(
            scored: scored,
            dropLowest: input.dropLowestOverrides[category.id] ?? category.dropLowest,
            dropHighest: category.dropHighest,
            neverDrop: category.neverDropIDs
        )
        let kept = scored.filter { !dropped.contains($0.id) }

        let weightSource: ScoreSource?
        let effectiveWeight: Double?
        if !weighted {
            (effectiveWeight, weightSource) = (nil, nil)
        } else if let manual = input.manualWeights[category.id] {
            (effectiveWeight, weightSource) = (
                manual,
                input.syllabusWeightedCategoryIDs.contains(category.id) ? .syllabus : .manual
            )
        } else {
            (effectiveWeight, weightSource) = (input.courseUsesWeights ? (category.weight ?? 0) : 0, .canvas)
        }

        let result = GradeBreakdown.CategoryResult(
            id: category.id,
            name: category.name,
            effectiveWeight: effectiveWeight,
            weightSource: weightSource,
            earned: kept.reduce(0) { $0 + ($1.score ?? 0) },
            possibleScored: kept.reduce(0) { $0 + $1.pointsPossible },
            possibleTotal: gradeable.reduce(0) { $0 + $1.pointsPossible },
            possibleScoredRaw: scored.reduce(0) { $0 + $1.pointsPossible },
            scoredCount: scored.count,
            totalCount: gradeable.count,
            droppedItemIDs: dropped
        )

        let pending = gradeable.filter { item in
            item.score == nil && (item.dueAt.map { $0 < input.now } ?? false)
        }.count

        return CategoryTally(result: result, pendingCount: pending)
    }

    /// Applies drop-lowest / drop-highest to the scored items of one category.
    /// Suppressed entirely until ≥ 2 items are scored (avoids NaN/instability);
    /// always keeps at least one scored item; never drops pinned (`never_drop`)
    /// or extra-credit (0-possible — no defined ratio) items.
    private static func droppedItemIDs(
        scored: [GradeItem],
        dropLowest: Int,
        dropHighest: Int,
        neverDrop: Set<String>
    ) -> Set<String> {
        guard scored.count >= 2, dropLowest > 0 || dropHighest > 0 else { return [] }

        let droppable = scored
            .filter { !neverDrop.contains($0.id) && $0.pointsPossible > 0 }
            .sorted { ratio($0) < ratio($1) }
        let maxDrops = scored.count - 1

        let fromBottom = min(max(dropLowest, 0), droppable.count, maxDrops)
        let fromTop = min(max(dropHighest, 0), droppable.count - fromBottom, maxDrops - fromBottom)

        return Set(droppable.prefix(fromBottom).map(\.id))
            .union(droppable.suffix(fromTop).map(\.id))
    }

    private static func ratio(_ item: GradeItem) -> Double {
        (item.score ?? 0) / item.pointsPossible
    }

    // MARK: - Points mode

    private static func pointsCurrentPercent(_ tallies: [CategoryTally]) -> Double? {
        let earned = tallies.reduce(0) { $0 + $1.result.earned }
        let possible = tallies.reduce(0) { $0 + $1.result.possibleScored }
        guard possible > 0 else { return nil }
        return earned / possible * 100
    }

    private static func pointsDecidedFraction(_ tallies: [CategoryTally]) -> Double {
        let scored = tallies.reduce(0) { $0 + $1.possibleScoredRaw }
        let total = tallies.reduce(0) { $0 + $1.result.possibleTotal }
        guard total > 0 else { return 0 }
        return scored / total
    }

    // MARK: - Weighted mode

    /// Renormalized weighted average over the categories that actually have
    /// scored, point-bearing work — categories that haven't happened yet don't
    /// drag the number down.
    private static func weightedCurrentPercent(_ tallies: [CategoryTally]) -> Double? {
        let participating = tallies.filter {
            ($0.result.effectiveWeight ?? 0) > 0 && $0.result.possibleScored > 0
        }
        let totalWeight = participating.reduce(0) { $0 + ($1.result.effectiveWeight ?? 0) }
        guard totalWeight > 0 else { return nil }

        let sum = participating.reduce(0.0) { acc, tally in
            let pct = tally.result.earned / tally.result.possibleScored
            return acc + (tally.result.effectiveWeight ?? 0) * pct
        }
        return sum / totalWeight * 100
    }

    /// Σ over non-zero-weight categories of w_c × (scored possible ÷ total
    /// possible within c), with weights normalized across ALL non-zero-weight
    /// categories — so an untouched future category correctly counts as
    /// still-open, and a half-graded category is only half decided.
    private static func weightedDecidedFraction(_ tallies: [CategoryTally]) -> Double {
        let weightedCats = tallies.filter { ($0.result.effectiveWeight ?? 0) > 0 }
        let totalWeight = weightedCats.reduce(0) { $0 + ($1.result.effectiveWeight ?? 0) }
        guard totalWeight > 0 else { return 0 }

        return weightedCats.reduce(0.0) { acc, tally in
            guard tally.result.possibleTotal > 0 else { return acc }
            let fraction = tally.possibleScoredRaw / tally.result.possibleTotal
            return acc + (tally.result.effectiveWeight ?? 0) / totalWeight * fraction
        }
    }
}
