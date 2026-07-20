import Foundation

/// Grade-over-time reconstruction (docs/grades.md §11). Not a persisted
/// history: each point is a full `GradeEngine.compute` over the course's
/// current data with later scores masked out, so the chart is complete from
/// the very first sync and every point inherits the engine's edge-case
/// handling (drops, excused, extra credit, both modes) for free.
extension GradeEngine {
    public struct TrajectoryPoint: Sendable, Hashable, Codable {
        public let date: Date
        public let percent: Double

        public init(date: Date, percent: Double) {
            self.date = date
            self.percent = percent
        }
    }

    /// The course's grade as it stood after each of its own due dates, ending
    /// with the true current grade at `input.now`.
    ///
    /// Placement rules:
    /// - A cutoff exists for each distinct due date (≤ `input.now`) that has a
    ///   scored item. At cutoff `d`, any scored item due after `d` is treated
    ///   as not-yet-decided (its score is masked), exactly matching the
    ///   engine's "scored means score present" rule as of that day.
    /// - Scored items with no due date can't be placed in time, so they count
    ///   from the first point onward.
    /// - A scored item due in the FUTURE (a Gradescope early score, say) only
    ///   appears in the final now-point — the past never contains it.
    /// - The final point is always the unmasked current grade, so the line's
    ///   endpoint agrees with the card's headline number.
    ///
    /// Points where the masked grade is undefined ("no scores yet") are
    /// skipped rather than rendered as 0.
    public static func trajectory(_ input: Input) -> [TrajectoryPoint] {
        let scoredDueDates = Set(
            input.categories
                .flatMap(\.items)
                .filter { !$0.isExcused && !$0.omitFromFinalGrade && $0.score != nil }
                .compactMap(\.dueAt)
                .filter { $0 <= input.now }
        ).sorted()

        var points: [TrajectoryPoint] = []
        for cutoff in scoredDueDates {
            let masked = masking(input, after: cutoff)
            if let percent = compute(masked).currentPercent {
                points.append(TrajectoryPoint(date: cutoff, percent: percent))
            }
        }

        if let current = compute(input).currentPercent {
            points.append(TrajectoryPoint(date: input.now, percent: current))
        }
        return points
    }

    /// A copy of `input` where every scored item due after `cutoff` has its
    /// score removed — the course as the engine would have seen it that day.
    private static func masking(_ input: Input, after cutoff: Date) -> Input {
        let maskedCategories = input.categories.map { category in
            GradeCategory(
                id: category.id,
                name: category.name,
                weight: category.weight,
                dropLowest: category.dropLowest,
                dropHighest: category.dropHighest,
                neverDropIDs: category.neverDropIDs,
                items: category.items.map { item in
                    guard let dueAt = item.dueAt, dueAt > cutoff, item.score != nil else { return item }
                    return GradeItem(
                        id: item.id,
                        name: item.name,
                        pointsPossible: item.pointsPossible,
                        score: nil,
                        scoreSource: nil,
                        isExcused: item.isExcused,
                        omitFromFinalGrade: item.omitFromFinalGrade,
                        dueAt: item.dueAt
                    )
                }
            )
        }
        return Input(
            courseUsesWeights: input.courseUsesWeights,
            categories: maskedCategories,
            manualWeights: input.manualWeights,
            dropLowestOverrides: input.dropLowestOverrides,
            now: input.now
        )
    }
}
