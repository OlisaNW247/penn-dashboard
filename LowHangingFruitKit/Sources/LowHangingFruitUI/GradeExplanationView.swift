import SwiftUI
import LowHangingFruitKit

/// Renders `GradeExplanation` — the pure "how this is calculated" model the
/// Kit builds from a `GradeBreakdown`. This view does no math of its own; it
/// only lays the model's already-worded lines out.
///
/// Two densities share one view rather than two, because the compact
/// (card) and full (report) renderings must never drift into saying
/// different things about the same course — the card's three-line summary
/// (mode, decided, canvas cross-check) is a strict subset of the report's
/// full panel (adds the formula sentence, the per-category table, and the
/// left-out-categories line).
struct GradeExplanationView: View {
    let explanation: GradeExplanation
    var compact: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // "no graded work yet · attendance 100%" -- only ever present
            // when every scored item in the course is attendance-only
            // (`GradeBreakdown.attendanceOnlyPercent`), and only shown in
            // full mode: the compact card panel already has its own
            // attendance-only headline (`GradeCourseCardView.headlineText`),
            // and repeating the note there would just be saying the same
            // thing twice in the same card.
            if !compact, let headlineNote = explanation.headlineNote {
                Text(headlineNote)
                    .font(.lhfSans(12, weight: .medium))
                    .foregroundStyle(Color.v2SpineAmber)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Text(explanation.modeLine)
                .font(.lhfSans(11))
                .foregroundStyle(Color.v2RingSub)

            if !compact {
                Text(explanation.formulaLine)
                    .font(.lhfSans(11))
                    .foregroundStyle(Color.v2DateText)
                    .fixedSize(horizontal: false, vertical: true)

                categoryTable

                if let leftOutLine = explanation.leftOutLine {
                    Text(leftOutLine)
                        .font(.lhfSans(10.5))
                        .foregroundStyle(Color.v2RingSub)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            Text(explanation.decidedLine)
                .font(.lhfSans(12, weight: .medium))
                .foregroundStyle(Color.v2Ink)
                .fixedSize(horizontal: false, vertical: true)

            if let canvasLine = explanation.canvasLine {
                Text(canvasLine)
                    .font(.lhfSans(10.5))
                    .foregroundStyle(Color.v2RingSub)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Category table (full mode only)

    private var categoryTable: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(explanation.categoryLines) { line in
                categoryRow(line)
            }
        }
        .padding(.vertical, 2)
    }

    private func categoryRow(_ line: GradeExplanation.CategoryLine) -> some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(line.name)
                        .font(.lhfSans(11.5, weight: .medium))
                        .foregroundStyle(line.participates ? Color.v2Ink : Color.v2RingSub)
                        .fixedSize(horizontal: false, vertical: true)
                    // "you edited" here is a count of touched ITEMS inside the
                    // category (docs/grades.md), distinct from the weight's
                    // own "you edited" source badge below -- a student can
                    // edit an item's score without ever touching the
                    // category's weight, so the two badges are independent.
                    if line.editedItemCount > 0 {
                        explanationBadge("you edited")
                    }
                }
                Text(line.gradedText)
                    .font(.lhfSans(9.5))
                    .foregroundStyle(Color.v2RingSub)
                    .fixedSize(horizontal: false, vertical: true)
                // "from canvas groups: problem sets, worksheets" -- the fold
                // a `GradeCategoryMap` performed to make this one category.
                if let groupsText = line.groupsText {
                    Text(groupsText)
                        .font(.lhfSans(9.5))
                        .foregroundStyle(Color.v2RingSub)
                        .fixedSize(horizontal: false, vertical: true)
                }
                // A Canvas group the map never claimed, surfaced as its own
                // zero-weight passthrough category (`GradeRegrouper`) rather
                // than silently dropped -- the chip is the loud version of
                // "why doesn't this add up," matching `GradeCategoryMapEditor`'s
                // "needs a home" block for the same groups.
                if line.isUnmapped {
                    Chip(text: "needs a home", color: .v2SpineAmber)
                }
            }

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 4) {
                    if let weightSourceText = line.weightSourceText {
                        explanationBadge(weightSourceText)
                    }
                    Text(line.weightText)
                        .font(.lhfSans(11, weight: .semibold))
                        .foregroundStyle(line.participates ? Color.v2Ink : Color.v2RingSub)
                }
                Text(line.percentText)
                    .font(.lhfSans(10.5))
                    .foregroundStyle(Color.v2RingSub)
                if let contributionText = line.contributionText {
                    Text(contributionText)
                        .font(.lhfSans(9.5))
                        .foregroundStyle(Color.v2RingSub)
                }
            }
        }
        // Non-participating rows (renormalization left them out of
        // `currentPercent`) are dimmed rather than hidden -- the student
        // still needs to see the category exists and why it's not counting.
        .opacity(line.participates ? 1 : 0.55)
        .accessibilityElement(children: .combine)
    }

    /// Matches the dashboard's "nothing to submit" caveat register
    /// (`AssignmentCardView`'s caveat text): 9pt semibold, `v2CourseCode`.
    private func explanationBadge(_ text: String) -> some View {
        Text(text)
            .font(.lhfSans(9, weight: .semibold))
            .foregroundStyle(Color.v2CourseCode)
    }
}
