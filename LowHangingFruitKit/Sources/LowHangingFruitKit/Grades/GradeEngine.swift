import Foundation

/// Pure grade math — no I/O, fully deterministic. See docs/grades.md §2–3.
///
/// Two modes, chosen by the COURSE-level `apply_assignment_group_weights` flag
/// (never by the presence of `group_weight`, which is garbage when the flag is
/// false), by user-supplied manual weights, or by an explicit `Input.modeOverride`:
///
/// - **Weighted:** current grade is a renormalized weighted average over the
///   categories that have scored work; % decided is Σ w_c × (scored possible ÷
///   total possible) per category.
/// - **Points:** one implicit bucket; Σ earned ÷ Σ possible over scored items.
///
/// "Scored" always means `score != nil` on a non-excused, non-omitted item —
/// submission state is irrelevant to the math.
///
/// `Input.itemOverrides` (a student's own corrections) are layered onto
/// Canvas's numbers FIRST, before any of the above runs, so a wrong score, a
/// wrong points-possible, or an item the student wants excluded flows through
/// every downstream calculation exactly as if Canvas had reported it that way.
/// `Input.expectedCounts` (from the syllabus — Canvas can't provide this,
/// since it only ever describes work that already exists) feeds a SECOND,
/// separate "share of the semester decided" number (`GradeBreakdown.
/// semesterDecidedFraction`) alongside the original `decidedFraction`, which
/// only ever measures against what Canvas has posted so far and is kept
/// exactly as it was.
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
        /// `weightSource`/`modeSource`, never the arithmetic — so the UI can
        /// distinguish a weight the user can check against a document from
        /// one they entered by hand.
        public let syllabusWeightedCategoryIDs: Set<String>
        /// Reference time for the past-due-unscored ("pending grading") count.
        public let now: Date
        /// Category id → the whole-semester expected item count, read from
        /// the syllabus (`SyllabusCategory.expectedItemCount`, via whatever
        /// maps a syllabus category to a Canvas assignment group). Feeds
        /// `GradeBreakdown.semesterDecidedFraction` only — it never touches
        /// `currentPercent` or the original `decidedFraction`.
        public let expectedCounts: [String: Int]
        /// Item id → a student's own correction to that item. Applied before
        /// any other math in `compute` — see the type-level docs above.
        public let itemOverrides: [String: GradeItemOverride]
        /// Forces weighted or points mode, overriding both
        /// `courseUsesWeights` and the manual-weights-cover-every-category
        /// rule. nil defers to today's rule.
        public let modeOverride: GradingMode?

        public init(
            courseUsesWeights: Bool,
            categories: [GradeCategory],
            manualWeights: [String: Double] = [:],
            dropLowestOverrides: [String: Int] = [:],
            syllabusWeightedCategoryIDs: Set<String> = [],
            now: Date = Date(),
            expectedCounts: [String: Int] = [:],
            itemOverrides: [String: GradeItemOverride] = [:],
            modeOverride: GradingMode? = nil
        ) {
            self.courseUsesWeights = courseUsesWeights
            self.categories = categories
            self.manualWeights = manualWeights
            self.dropLowestOverrides = dropLowestOverrides
            self.syllabusWeightedCategoryIDs = syllabusWeightedCategoryIDs
            self.now = now
            self.expectedCounts = expectedCounts
            self.itemOverrides = itemOverrides
            self.modeOverride = modeOverride
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
        // Overrides are the student's own correction and must be layered onto
        // Canvas's numbers before anything else runs, so every downstream
        // calculation -- mode selection, weights, drops, both flavors of
        // % decided -- sees the corrected item exactly as if Canvas had
        // reported it that way.
        let adjusted = input.categories.map { applyOverrides(to: $0, overrides: input.itemOverrides) }

        let weighted: Bool
        if let modeOverride = input.modeOverride {
            weighted = modeOverride == .weighted
        } else {
            weighted = input.courseUsesWeights || manualWeightsCoverEveryCategory(input)
        }

        let tallies = adjusted.map { entry in
            tally(
                entry.category,
                overriddenItemIDs: entry.overriddenIDs,
                excludedItemIDs: entry.excludedIDs,
                input: input,
                weighted: weighted
            )
        }

        // Cross-category sums `contributionPercent` needs: how much of the
        // participating total each category's own weight (weighted mode) or
        // scored points (points mode) represents.
        let participatingWeightSum: Double? = weighted
            ? tallies.filter { $0.result.participates }.reduce(0.0) { $0 + ($1.result.effectiveWeight ?? 0) }
            : nil
        let participatingPointsSum: Double = tallies
            .filter { $0.result.participates }
            .reduce(0.0) { $0 + $1.result.possibleScored }

        let results: [GradeBreakdown.CategoryResult] = tallies.map { t in
            let r = t.result
            let contribution: Double?
            if r.participates, let percent = r.percent {
                if weighted {
                    let sum = participatingWeightSum ?? 0
                    contribution = sum > 0 ? percent * ((r.effectiveWeight ?? 0) / sum) : nil
                } else {
                    contribution = participatingPointsSum > 0
                        ? percent * (r.possibleScored / participatingPointsSum)
                        : nil
                }
            } else {
                contribution = nil
            }

            return GradeBreakdown.CategoryResult(
                id: r.id,
                name: r.name,
                effectiveWeight: r.effectiveWeight,
                weightSource: r.weightSource,
                earned: r.earned,
                possibleScored: r.possibleScored,
                possibleTotal: r.possibleTotal,
                possibleScoredRaw: r.possibleScoredRaw,
                scoredCount: r.scoredCount,
                totalCount: r.totalCount,
                droppedItemIDs: r.droppedItemIDs,
                expectedCount: r.expectedCount,
                semesterDecidedFraction: r.semesterDecidedFraction,
                participates: r.participates,
                contributionPercent: contribution,
                overriddenItemIDs: r.overriddenItemIDs,
                excludedItemIDs: r.excludedItemIDs
            )
        }

        let rawCurrentPercent = weighted ? weightedCurrentPercent(tallies) : pointsCurrentPercent(tallies)
        let decided = weighted ? weightedDecidedFraction(tallies) : pointsDecidedFraction(tallies)

        // Defense-in-depth: nothing with points possible has been scored means
        // there is no honest percent to show, full stop -- no matter which
        // path produced `rawCurrentPercent`. This is the fix for a real phone
        // that showed "100%" beside "0% decided" from a scored zero-point
        // item: every per-mode helper above already guards its own division,
        // but a single top-level rule is what makes the invariant impossible
        // to reintroduce by accident through some future combination of
        // overrides, manual weights, or a mode override.
        let currentPercent = (decided == 0) ? nil : rawCurrentPercent

        let modeSource: GradingModeSource
        if input.modeOverride != nil {
            modeSource = .manual
        } else if weighted && syllabusWeightsCoverEveryCategory(input) {
            modeSource = .syllabus
        } else {
            modeSource = .canvas
        }

        // Weighted-mode categories that carry real weight but never
        // participated -- the ones renormalization quietly excluded --
        // in the same order the categories were given.
        let leftOutCategoryIDs: [String] = weighted
            ? results.filter { ($0.effectiveWeight ?? 0) > 0 && !$0.participates }.map(\.id)
            : []

        let pending = tallies
            .filter { !weighted || ($0.result.effectiveWeight ?? 0) > 0 }
            .reduce(0) { $0 + $1.pendingCount }

        return GradeBreakdown(
            mode: weighted ? .weighted : .points,
            currentPercent: currentPercent,
            decidedFraction: decided,
            pendingGradingCount: pending,
            categories: results,
            semesterDecidedFraction: semesterDecidedFraction(results, weighted: weighted),
            modeSource: modeSource,
            leftOutCategoryIDs: leftOutCategoryIDs,
            participatingWeightSum: participatingWeightSum
        )
    }

    /// All-or-nothing gate for the points-mode → weighted-mode switch: manual
    /// weights only take effect once EVERY category has one. A partial set
    /// used to flip the whole course to weighted mode while leaving
    /// no-manual-weight categories at `effectiveWeight == 0` — silently
    /// dropping them from the grade. Requiring full coverage means a
    /// half-finished manual-weight edit just leaves the course in points
    /// mode (manual weights ignored) instead of silently corrupting it.
    ///
    /// Operates on `input.categories` (ids/weights, never touched by item
    /// overrides) rather than the override-adjusted categories `compute`
    /// builds, since only category identity matters here.
    private static func manualWeightsCoverEveryCategory(_ input: Input) -> Bool {
        guard !input.categories.isEmpty, !input.manualWeights.isEmpty else { return false }
        return input.categories.allSatisfy { input.manualWeights[$0.id] != nil }
    }

    /// Mirrors `manualWeightsCoverEveryCategory`'s all-or-nothing gate, but
    /// for `modeSource` provenance only: it never changes which weights are
    /// used (that's still `manualWeights`/Canvas), only whether the
    /// breakdown reports the weights as coming from the syllabus or Canvas.
    private static func syllabusWeightsCoverEveryCategory(_ input: Input) -> Bool {
        guard !input.categories.isEmpty, !input.syllabusWeightedCategoryIDs.isEmpty else { return false }
        return input.categories.allSatisfy { input.syllabusWeightedCategoryIDs.contains($0.id) }
    }

    // MARK: - Item overrides

    /// Layers a student's own item-level corrections onto one category's
    /// items before any mode/weight/drop math runs, so the rest of the
    /// engine can stay entirely ignorant of overrides -- it just sees a
    /// category whose items already reflect the correction. `isExcluded`
    /// removes the item outright (exactly like `omitFromFinalGrade`, but
    /// this is the STUDENT's decision rather than Canvas's); a
    /// score/pointsPossible override replaces Canvas's value, and the item's
    /// `scoreSource` becomes `.manual` once it ends up carrying a score
    /// (an override that only touches `pointsPossible` on an otherwise
    /// unscored item leaves the item unscored, so `scoreSource` stays nil —
    /// matching `GradeItem.scoreSource`'s own invariant that it's nil exactly
    /// when `score` is nil).
    private static func applyOverrides(
        to category: GradeCategory,
        overrides: [String: GradeItemOverride]
    ) -> (category: GradeCategory, overriddenIDs: Set<String>, excludedIDs: Set<String>) {
        guard !overrides.isEmpty else { return (category, [], []) }

        var overriddenIDs: Set<String> = []
        var excludedIDs: Set<String> = []

        let items: [GradeItem] = category.items.compactMap { item -> GradeItem? in
            guard let override = overrides[item.id], !override.isEmpty else { return item }

            if override.isExcluded {
                excludedIDs.insert(item.id)
                return nil
            }

            overriddenIDs.insert(item.id)
            let score = override.score ?? item.score
            let pointsPossible = override.pointsPossible ?? item.pointsPossible
            let scoreSource: ScoreSource? = score != nil ? .manual : item.scoreSource

            return GradeItem(
                id: item.id,
                name: item.name,
                pointsPossible: pointsPossible,
                score: score,
                scoreSource: scoreSource,
                isExcused: item.isExcused,
                omitFromFinalGrade: item.omitFromFinalGrade,
                dueAt: item.dueAt,
                submissionTypes: item.submissionTypes
            )
        }

        let adjustedCategory = GradeCategory(
            id: category.id,
            name: category.name,
            weight: category.weight,
            dropLowest: category.dropLowest,
            dropHighest: category.dropHighest,
            neverDropIDs: category.neverDropIDs,
            items: items
        )
        return (adjustedCategory, overriddenIDs, excludedIDs)
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
        overriddenItemIDs: Set<String>,
        excludedItemIDs: Set<String>,
        input: Input,
        weighted: Bool
    ) -> CategoryTally {
        // Excused and omit_from_final_grade items leave the math entirely.
        // (Items an override excluded are already gone from `category.items`
        // by the time this runs — see `applyOverrides`.)
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

        let earned = kept.reduce(0.0) { $0 + ($1.score ?? 0) }
        let possibleScored = kept.reduce(0.0) { $0 + $1.pointsPossible }
        let possibleTotal = gradeable.reduce(0.0) { $0 + $1.pointsPossible }
        let possibleScoredRaw = scored.reduce(0.0) { $0 + $1.pointsPossible }
        let totalCount = gradeable.count

        let expectedCount = input.expectedCounts[category.id]
        let semesterDecidedFraction: Double?
        if let expectedCount,
           let expected = expectedPossible(possibleTotal: possibleTotal, totalCount: totalCount, expectedCount: expectedCount),
           expected > 0 {
            semesterDecidedFraction = possibleScoredRaw / expected
        } else {
            semesterDecidedFraction = nil
        }

        let participates = weighted
            ? (effectiveWeight ?? 0) > 0 && possibleScored > 0
            : possibleScored > 0

        let result = GradeBreakdown.CategoryResult(
            id: category.id,
            name: category.name,
            effectiveWeight: effectiveWeight,
            weightSource: weightSource,
            earned: earned,
            possibleScored: possibleScored,
            possibleTotal: possibleTotal,
            possibleScoredRaw: possibleScoredRaw,
            scoredCount: scored.count,
            totalCount: totalCount,
            droppedItemIDs: dropped,
            expectedCount: expectedCount,
            semesterDecidedFraction: semesterDecidedFraction,
            participates: participates,
            contributionPercent: nil, // filled in by `compute` once cross-category sums are known
            overriddenItemIDs: overriddenItemIDs,
            excludedItemIDs: excludedItemIDs
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

    // MARK: - Semester expected count

    /// Average posted points per item times the expected count for the whole
    /// semester — never less than what's already posted, because a syllabus
    /// that says "10 labs" when 12 are already posted is a stale syllabus,
    /// not evidence that two labs don't count. nil when nothing is posted
    /// yet (`totalCount == 0`): there's no average to extrapolate from.
    private static func expectedPossible(possibleTotal: Double, totalCount: Int, expectedCount: Int) -> Double? {
        guard totalCount > 0 else { return nil }
        let averagePerItem = possibleTotal / Double(totalCount)
        return averagePerItem * Double(max(expectedCount, totalCount))
    }

    /// The course-wide "share of the semester decided" figure. Weighted mode
    /// sums normalized-weight × per-category `semesterDecidedFraction` and
    /// goes nil the moment any non-zero-weight category can't answer (it has
    /// no expected count, or nothing posted yet to average from — a category
    /// with real weight and total silence is exactly the case where "we don't
    /// know" is the honest answer). Points mode instead sums the raw
    /// scored/expected points across every category FIRST and divides once,
    /// so a category with nothing posted yet (`totalCount == 0`) simply
    /// contributes zero to both sums rather than blocking the whole estimate
    /// — there's no weight for it to disproportionately hide behind, so
    /// letting empty categories fall out of the sum is safe in a way it isn't
    /// in weighted mode.
    private static func semesterDecidedFraction(
        _ results: [GradeBreakdown.CategoryResult],
        weighted: Bool
    ) -> Double? {
        if weighted {
            let weightedCats = results.filter { ($0.effectiveWeight ?? 0) > 0 }
            let totalWeight = weightedCats.reduce(0.0) { $0 + ($1.effectiveWeight ?? 0) }
            guard totalWeight > 0 else { return nil }

            var sum = 0.0
            for cat in weightedCats {
                guard let fraction = cat.semesterDecidedFraction else { return nil }
                sum += (cat.effectiveWeight ?? 0) / totalWeight * fraction
            }
            return sum
        }

        var scoredSum = 0.0
        var expectedSum = 0.0
        for cat in results {
            guard cat.totalCount > 0 else { continue }
            guard let expectedCount = cat.expectedCount,
                  let expected = expectedPossible(
                    possibleTotal: cat.possibleTotal,
                    totalCount: cat.totalCount,
                    expectedCount: expectedCount
                  )
            else { return nil }
            scoredSum += cat.possibleScoredRaw
            expectedSum += expected
        }
        guard expectedSum > 0 else { return nil }
        return scoredSum / expectedSum
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
