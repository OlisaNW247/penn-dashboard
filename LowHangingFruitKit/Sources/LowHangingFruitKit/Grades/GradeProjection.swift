import Foundation

/// Where a course can still finish, given what's already scored.
///
/// Everything here is arithmetic over scores that already exist — no
/// hypotheticals, no user-entered "what if I get a 95". The three headline
/// numbers are:
///
/// - **floor** — your final grade if you score 0 on everything left. Already
///   banked; nothing can take it away.
/// - **ceiling** — your final grade if you score 100% on everything left.
/// - **pace** — floor plus the open share scored at your current average: the
///   honest middle, and the one number that answers "if nothing changes."
///
/// `requiredAverage(for:)` inverts the same arithmetic: what you'd have to
/// average on the remaining work to land on a target.
public struct GradeProjection: Sendable, Hashable, Codable {
    /// Share of the final grade already banked, 0…1 (can exceed 1 with extra
    /// credit). This IS the floor, expressed as a fraction.
    public let earnedShare: Double
    /// Share of the final grade still up for grabs, 0…1.
    public let openShare: Double
    /// Final grade if everything remaining scores 0, in percent.
    public var floorPercent: Double { earnedShare * 100 }
    /// Final grade if everything remaining scores 100%, in percent.
    public var ceilingPercent: Double { (earnedShare + openShare) * 100 }
    /// Final grade if the rest goes like the work so far, in percent. Nil when
    /// nothing is scored yet — there's no pace to extrapolate from.
    public let pacePercent: Double?
    /// Gradeable items with no score yet (past-due and upcoming together).
    public let remainingItemCount: Int
    /// Remaining items that aren't past due yet. `remainingItemCount` minus
    /// this is the "waiting on a grade" pile the card already surfaces.
    public let upcomingItemCount: Int

    /// True once nothing is left to grade — floor, ceiling and pace converge
    /// and the grade is final (modulo the professor changing something).
    public var isDecided: Bool { openShare <= 0.0001 }

    public init(
        earnedShare: Double,
        openShare: Double,
        pacePercent: Double?,
        remainingItemCount: Int,
        upcomingItemCount: Int
    ) {
        self.earnedShare = earnedShare
        self.openShare = openShare
        self.pacePercent = pacePercent
        self.remainingItemCount = remainingItemCount
        self.upcomingItemCount = upcomingItemCount
    }

    /// What you'd need to average on everything still open to finish at
    /// `targetPercent`.
    public enum Requirement: Sendable, Hashable {
        /// Already locked in — even scoring 0 from here lands at or above the
        /// target.
        case alreadyReached
        /// Achievable: average this percent (0…100) on the remaining work.
        case need(percent: Double)
        /// Out of reach: 100% on everything left still falls short, by
        /// `shortfall` percentage points.
        case unreachable(shortfall: Double)
        /// Nothing left to score, and the target wasn't met.
        case nothingLeft
    }

    public func requiredAverage(for targetPercent: Double) -> Requirement {
        let target = targetPercent / 100
        if earnedShare >= target { return .alreadyReached }
        guard openShare > 0.0001 else { return .nothingLeft }

        let needed = (target - earnedShare) / openShare
        if needed > 1 {
            // Shortfall expressed on the same scale as the grade itself, so
            // "you'd finish 2.4 points short" reads directly against the target.
            return .unreachable(shortfall: (target - (earnedShare + openShare)) * 100)
        }
        return .need(percent: needed * 100)
    }
}

public enum GradeProjector {
    /// Splits a computed breakdown into banked vs still-open, in both grading
    /// modes.
    ///
    /// Per category: `f` is the fraction of the category's points already
    /// scored (pre-drop, per Decision 6) and `p` is your ratio in the scored,
    /// post-drop part. A category contributes `w · f · p` to the floor and
    /// `w · (1 − f)` to the open share.
    ///
    /// The drop-rule asymmetry (`f` pre-drop, `p` post-drop) is deliberate and
    /// matches how `% decided` is already defined: dropped points still count
    /// as decided — they're never coming back — while the grade itself
    /// correctly ignores them.
    public static func project(_ breakdown: GradeBreakdown) -> GradeProjection {
        let remaining = breakdown.categories.reduce(0) { $0 + ($1.totalCount - $1.scoredCount) }
        let upcoming = max(0, remaining - breakdown.pendingGradingCount)

        switch breakdown.mode {
        case .points:
            return pointsProjection(breakdown, remaining: remaining, upcoming: upcoming)
        case .weighted:
            return weightedProjection(breakdown, remaining: remaining, upcoming: upcoming)
        }
    }

    /// One implicit bucket: the final grade is Σ earned ÷ Σ possible over the
    /// whole course, so the floor is simply what's earned over the course's
    /// full point total.
    private static func pointsProjection(
        _ breakdown: GradeBreakdown,
        remaining: Int,
        upcoming: Int
    ) -> GradeProjection {
        let totalPossible = breakdown.categories.reduce(0) { $0 + $1.possibleTotal }
        guard totalPossible > 0 else {
            return GradeProjection(earnedShare: 0, openShare: 0, pacePercent: nil,
                                   remainingItemCount: remaining, upcomingItemCount: upcoming)
        }

        let earned = breakdown.categories.reduce(0) { $0 + $1.earned }
        let scoredRaw = breakdown.categories.reduce(0) { $0 + $1.possibleScoredRaw }

        let earnedShare = earned / totalPossible
        let openShare = max(0, (totalPossible - scoredRaw) / totalPossible)
        return GradeProjection(
            earnedShare: earnedShare,
            openShare: openShare,
            pacePercent: pace(earnedShare: earnedShare, openShare: openShare, breakdown: breakdown),
            remainingItemCount: remaining,
            upcomingItemCount: upcoming
        )
    }

    private static func weightedProjection(
        _ breakdown: GradeBreakdown,
        remaining: Int,
        upcoming: Int
    ) -> GradeProjection {
        // Zero-weight categories don't count toward the grade, so they can't
        // contribute to the floor or the open share either (docs/grades.md
        // Decision 7) — and their unscored items shouldn't be advertised as
        // "remaining work" that could move the grade.
        let counting = breakdown.categories.filter { ($0.effectiveWeight ?? 0) > 0 }
        let totalWeight = counting.reduce(0) { $0 + ($1.effectiveWeight ?? 0) }
        guard totalWeight > 0 else {
            return GradeProjection(earnedShare: 0, openShare: 0, pacePercent: nil,
                                   remainingItemCount: remaining, upcomingItemCount: upcoming)
        }

        var earnedShare = 0.0
        var openShare = 0.0
        for category in counting {
            let w = (category.effectiveWeight ?? 0) / totalWeight
            // A category with no point-bearing work at all (pure extra credit,
            // or nothing set up yet) is entirely open: we can't claim any of
            // its weight is decided, and dividing by its zero total would be
            // the classic way to produce a NaN grade.
            guard category.possibleTotal > 0 else {
                openShare += w
                continue
            }
            let decidedFraction = min(1, category.possibleScoredRaw / category.possibleTotal)
            let ratio = category.possibleScored > 0 ? category.earned / category.possibleScored : 0
            earnedShare += w * decidedFraction * ratio
            openShare += w * (1 - decidedFraction)
        }

        let countingRemaining = counting.reduce(0) { $0 + ($1.totalCount - $1.scoredCount) }
        return GradeProjection(
            earnedShare: earnedShare,
            openShare: max(0, openShare),
            pacePercent: pace(earnedShare: earnedShare, openShare: openShare, breakdown: breakdown),
            remainingItemCount: countingRemaining,
            upcomingItemCount: max(0, countingRemaining - breakdown.pendingGradingCount)
        )
    }

    /// Floor plus the open share scored at the current grade. Nil when there's
    /// no current grade to extrapolate from — projecting "no scores yet"
    /// forward would be inventing a number.
    private static func pace(
        earnedShare: Double,
        openShare: Double,
        breakdown: GradeBreakdown
    ) -> Double? {
        guard let current = breakdown.currentPercent else { return nil }
        return (earnedShare + openShare * (current / 100)) * 100
    }
}
