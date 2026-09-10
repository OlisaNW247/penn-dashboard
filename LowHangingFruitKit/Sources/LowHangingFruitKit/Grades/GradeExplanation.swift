import Foundation

/// The pure "how this is calculated" model behind Grade Watcher's explanation
/// panel. Nothing here does math -- it only reads a `GradeBreakdown` that
/// `GradeEngine.compute` already produced and turns it into copy, so the UI
/// never has to re-derive "why does my grade say this" from raw numbers, and
/// this file is the one place that can drift out of sync with the engine if
/// a new field ever needs explaining.
///
/// House style: lowercase copy ("no scores yet", "you edited"), percentages
/// at most one decimal (trimmed to a whole number when the fraction rounds
/// away, e.g. "100%" not "100.0%"), weights shown as integers when they're
/// whole.
public struct GradeExplanation: Sendable, Hashable {
    public struct CategoryLine: Sendable, Hashable, Identifiable {
        public let id: String
        public let name: String
        /// "30%", or "—" in points mode (no weight concept).
        public let weightText: String
        /// "canvas" / "syllabus" / "you edited"; nil in points mode.
        public let weightSourceText: String?
        /// "2 of 3 posted graded", plus " · 12 expected" when the syllabus
        /// gave this category a whole-semester expected count.
        public let gradedText: String
        /// "94%", or "no scores yet" when nothing in the category is graded.
        public let percentText: String
        /// "+28.2 of your grade" style; nil exactly when `participates` is
        /// false (renormalization already excluded this category).
        public let contributionText: String?
        public let participates: Bool
        /// Count of items a `GradeItemOverride` touched (overridden +
        /// excluded), so the UI can flag a category the student has edited.
        public let editedItemCount: Int
    }

    /// e.g. "weighted by category (from canvas)" / "points, no categories
    /// (you chose)".
    public let modeLine: String
    /// One sentence stating the arithmetic actually used for `currentPercent`.
    public let formulaLine: String
    public let categoryLines: [CategoryLine]
    /// "left out until something is graded: Exams (40%), Final (25%)"; nil
    /// when nothing is left out (points mode always leaves this nil, since
    /// it has no weight concept to leave anything out of).
    public let leftOutLine: String?
    /// "41% of the semester decided", or, when the syllabus hasn't given
    /// every relevant category an expected count yet, "63% of what's
    /// posted is graded — semester share unknown until every category has
    /// an expected count".
    public let decidedLine: String
    /// "canvas shows 96.1% — 1.4 points apart" / "matches canvas's own
    /// number" / nil when Canvas reported no score to compare against (or
    /// there's no computed grade yet to compare with).
    public let canvasLine: String?

    public static func make(
        from breakdown: GradeBreakdown,
        canvasScore: Double?,
        differsThreshold: Double = 1.0
    ) -> GradeExplanation {
        let modeSourceText: String
        switch breakdown.modeSource {
        case .canvas:   modeSourceText = "from canvas"
        case .manual:   modeSourceText = "you chose"
        case .syllabus: modeSourceText = "from your syllabus"
        }

        let modeLine: String
        let formulaLine: String
        switch breakdown.mode {
        case .weighted:
            modeLine = "weighted by category (\(modeSourceText))"
            let weightSumText = compactPercentText(breakdown.participatingWeightSum ?? 0)
            formulaLine = "each graded category's percent is multiplied by its weight, "
                + "added together, then divided by the combined weight of categories "
                + "with scored work so far (\(weightSumText))."
        case .points:
            modeLine = "points, no categories (\(modeSourceText))"
            formulaLine = "every point earned is divided by every point possible in "
                + "graded work so far, in one bucket."
        }

        let categoryLines = breakdown.categories.map { category -> CategoryLine in
            let weightText = breakdown.mode == .points
                ? "\u{2014}"
                : compactPercentText(category.effectiveWeight ?? 0)

            let weightSourceText: String?
            if breakdown.mode == .points {
                weightSourceText = nil
            } else {
                switch category.weightSource {
                case .canvas:          weightSourceText = "canvas"
                case .syllabus:         weightSourceText = "syllabus"
                case .manual:           weightSourceText = "you edited"
                case .gradescopeEarly:  weightSourceText = "gradescope early"
                case nil:               weightSourceText = nil
                }
            }

            var gradedText = "\(category.scoredCount) of \(category.totalCount) posted graded"
            if let expectedCount = category.expectedCount {
                gradedText += " \u{00b7} \(expectedCount) expected"
            }

            let percentText = category.percent.map(compactPercentText) ?? "no scores yet"
            let contributionText = category.contributionPercent.map {
                "+\(compactNumberText($0)) of your grade"
            }

            return CategoryLine(
                id: category.id,
                name: category.name,
                weightText: weightText,
                weightSourceText: weightSourceText,
                gradedText: gradedText,
                percentText: percentText,
                contributionText: contributionText,
                participates: category.participates,
                editedItemCount: category.overriddenItemIDs.count + category.excludedItemIDs.count
            )
        }

        let leftOutLine: String?
        if breakdown.leftOutCategoryIDs.isEmpty {
            leftOutLine = nil
        } else {
            let byID = Dictionary(uniqueKeysWithValues: breakdown.categories.map { ($0.id, $0) })
            let parts = breakdown.leftOutCategoryIDs.compactMap { id -> String? in
                guard let category = byID[id] else { return nil }
                return "\(category.name) (\(compactPercentText(category.effectiveWeight ?? 0)))"
            }
            leftOutLine = parts.isEmpty ? nil : "left out until something is graded: \(parts.joined(separator: ", "))"
        }

        let decidedLine: String
        if let semesterFraction = breakdown.semesterDecidedFraction {
            decidedLine = "\(compactPercentText(semesterFraction * 100)) of the semester decided"
        } else {
            decidedLine = "\(compactPercentText(breakdown.decidedFraction * 100)) of what's posted is graded "
                + "\u{2014} semester share unknown until every category has an expected count"
        }

        let canvasLine: String?
        if let canvasScore, let computed = breakdown.currentPercent {
            if GradeEngine.differsFromCanvas(computed: computed, canvasScore: canvasScore, threshold: differsThreshold) {
                let diff = abs(computed - canvasScore)
                canvasLine = "canvas shows \(compactPercentText(canvasScore)) \u{2014} \(compactNumberText(diff)) points apart"
            } else {
                canvasLine = "matches canvas's own number"
            }
        } else {
            canvasLine = nil
        }

        return GradeExplanation(
            modeLine: modeLine,
            formulaLine: formulaLine,
            categoryLines: categoryLines,
            leftOutLine: leftOutLine,
            decidedLine: decidedLine,
            canvasLine: canvasLine
        )
    }
}

/// "94%" / "94.5%" — at most one decimal, trimmed to a whole number when the
/// fraction rounds away. Deliberately duplicated from LowHangingFruitUI's
/// `formatPercent` rather than shared: the Kit target never depends on the UI
/// target (see the package layout in CLAUDE.md), and this is a three-line
/// rounding rule, not enough to justify a new shared module.
private func compactPercentText(_ value: Double) -> String {
    let rounded = (value * 10).rounded() / 10
    if rounded == rounded.rounded() {
        return "\(Int(rounded))%"
    }
    return String(format: "%.1f%%", rounded)
}

/// Same rounding rule as `compactPercentText`, without the trailing `%`, for
/// values that aren't themselves a percentage (a point-apart difference, a
/// category's raw contribution to the headline grade).
private func compactNumberText(_ value: Double) -> String {
    let rounded = (value * 10).rounded() / 10
    if rounded == rounded.rounded() {
        return "\(Int(rounded))"
    }
    return String(format: "%.1f", rounded)
}
