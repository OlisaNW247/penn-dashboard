import SwiftUI
import LowHangingFruitKit

/// Renders `GradeExplanation` — the pure "how this is calculated" model the
/// Kit builds from a `GradeBreakdown`. Trimmed for the minimal Grade Watcher
/// rebuild (docs/grades.md — the report used to carry full sentences; now
/// numbers and a table): mode line, formula line, decided line, then a
/// compact per-category table (name · weight · expected count · contribution).
///
/// Dropped, and where each went: `headlineNote` (the attendance-only aside)
/// is redundant with the headline itself, which already says "no graded work
/// yet" plus the attendance percent (`GradeCourseCardView.headlineText`).
/// `canvasLine` moved out of this view entirely, into the report's own
/// "differs from canvas" line in its collapsed "how" section, built the same
/// way the card used to build its chip. The "you edited" / "needs a home"
/// badges and the left-out-categories sentence are dropped outright — the
/// table's own weight and expected-count columns already show a category is
/// zero-weight, unmapped, or thin without a sentence spelling it out. The
/// `compact` parameter is kept only so existing call sites keep compiling;
/// both densities now render identically, since there is no full/compact
/// split left to differ.
struct GradeExplanationView: View {
    let explanation: GradeExplanation
    var compact: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(explanation.modeLine)
                .font(.lhfSans(11))
                .foregroundStyle(Color.v2RingSub)

            Text(explanation.formulaLine)
                .font(.lhfSans(11))
                .foregroundStyle(Color.v2DateText)
                .fixedSize(horizontal: false, vertical: true)

            Text(explanation.decidedLine)
                .font(.lhfSans(11))
                .foregroundStyle(Color.v2Ink)
                .fixedSize(horizontal: false, vertical: true)

            categoryTable
        }
    }

    // MARK: - Category table

    private var categoryTable: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(explanation.categoryLines) { line in
                categoryRow(line)
            }
        }
        .padding(.top, 2)
    }

    /// name · weight · expected count (or "—") · contribution (or "—").
    private func categoryRow(_ line: GradeExplanation.CategoryLine) -> some View {
        HStack(spacing: 8) {
            Text(line.name)
                .font(.lhfSans(11))
                .foregroundStyle(Color.v2Ink)
                .lineLimit(1)
            Spacer(minLength: 6)
            Text(line.weightText)
                .font(.lhfSans(11))
                .foregroundStyle(Color.v2RingSub)
            Text(line.expectedCountText ?? "\u{2014}")
                .font(.lhfSans(11))
                .foregroundStyle(Color.v2RingSub)
            Text(line.contributionText ?? "\u{2014}")
                .font(.lhfSans(11))
                .foregroundStyle(Color.v2RingSub)
        }
        .accessibilityElement(children: .combine)
    }
}
