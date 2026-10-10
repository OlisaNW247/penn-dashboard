import SwiftUI
import LowHangingFruitKit

/// "Done" tab — completed assignments styled as archived: greige surface, muted
/// grey spine, green check, strikethrough title. Tapping un-completes an item.
///
/// Leads with the week's count ("4 down this week") rather than ending on it:
/// with a whole semester of finished work below, the one number worth seeing
/// sat at the bottom of a long scroll. Only this week's cards show by
/// default; the rest of the semester waits behind a single "earlier this
/// semester" row that opens in place, so the tab reads as "this week's
/// progress" first and an archive second.
struct DoneView: View {
    let sections: [DashSection]
    let weeklyDone: Int
    let onUncomplete: (DashItem) -> Void
    /// How many older unfinished assignments the sign-up rule is withholding
    /// (`SignupBacklog`), whether the student has chosen to see them, and the
    /// switch between the two. Defaulted so the tab renders without any of it
    /// (previews, an existing install: the count is zero and the line is absent).
    var backlogHiddenCount: Int = 0
    var backlogRevealed: Bool = false
    var onToggleBacklog: () -> Void = {}

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showsEarlier = false

    private var thisWeek: DashSection? { sections.first { $0.id == "doneWeek" } }
    private var earlier: DashSection? { sections.first { $0.id == "doneSemester" } }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            summary
                .frame(maxWidth: .infinity, alignment: .leading)

            if let thisWeek {
                cards(for: thisWeek)
            }

            if let earlier {
                earlierToggle(count: earlier.items.count)

                if showsEarlier {
                    VStack(alignment: .leading, spacing: 10) {
                        cards(for: earlier)
                    }
                    .transition(.opacity.combined(with: .move(edge: .top)))
                }
            }

            backlogLine
        }
    }

    /// One quiet line at the foot of the tab: the way back to work the sign-up
    /// rule withheld. Absent unless something is actually withheld, so it never
    /// appears for an existing install or for a student with nothing old.
    /// Caption styling matches "nice pace." above; the button's hit area is 44pt
    /// even though its words are small.
    @ViewBuilder
    private var backlogLine: some View {
        if backlogHiddenCount > 0 {
            HStack(alignment: .center, spacing: 4) {
                Text(SignupBacklogCopy.line(count: backlogHiddenCount, revealed: backlogRevealed))
                    .font(.lhfSans(11))
                    .foregroundStyle(Color.v2RingSub)
                    .fixedSize(horizontal: false, vertical: true)
                Button {
                    lhfHapticLight()
                    onToggleBacklog()
                } label: {
                    Text(SignupBacklogCopy.buttonTitle(revealed: backlogRevealed))
                        .font(.lhfSans(11, weight: .semibold))
                        .foregroundStyle(Color.smoothCobaltInk)
                        .frame(minWidth: 44, minHeight: 44)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(SignupBacklogCopy.accessibilityLabel(revealed: backlogRevealed))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var summary: some View {
        VStack(alignment: .leading, spacing: 3) {
            if weeklyDone > 0 {
                Text("\(weeklyDone) down this week.")
                    .font(.lhfSerif(22))
                    .foregroundStyle(Color.smoothInk)
                Text("nice pace.")
                    .font(.lhfSans(11))
                    .foregroundStyle(Color.v2RingSub)
            } else if !sections.isEmpty {
                // Completed work exists, it just wasn't finished this week —
                // don't claim "nothing done yet.".
                Text("nothing new this week.")
                    .font(.lhfSerif(22))
                    .foregroundStyle(Color.smoothInk)
            } else {
                Text("nothing done yet.")
                    .font(.lhfSerif(22))
                    .foregroundStyle(Color.smoothInk)
                Text("let's fix that.")
                    .font(.lhfSans(11))
                    .foregroundStyle(Color.v2RingSub)
            }
        }
        .padding(.top, sections.isEmpty ? 60 : 0)
    }

    private func cards(for section: DashSection) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(section.items) { item in
                DoneCardView(
                    item: item,
                    dayLabel: section.dayLabel?(item),
                    onTap: { onUncomplete(item) }
                )
                .transition(.opacity)
            }
        }
    }

    private func earlierToggle(count: Int) -> some View {
        DisclosureRow(title: "earlier this semester", count: count, isOpen: showsEarlier) {
            withAnimation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.86)) {
                showsEarlier.toggle()
            }
        }
    }
}

/// A completed card keeps its original deadline fill at reduced opacity.
struct DoneCardView: View {
    let item: DashItem
    let dayLabel: String?
    let onTap: () -> Void

    @Environment(\.courseNameOverrides) private var courseNameOverrides

    private let corner: CGFloat = 18

    var body: some View {
        Button {
            lhfHapticLight()
            onTap()
        } label: {
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.assignment.displayCourse(overrides: courseNameOverrides).uppercased())
                        .font(.lhfMono(9.5, weight: .semibold))
                        .tracking(1.1)
                        .foregroundStyle(smoothTaskTextAccent(item.due))
                    Text(item.assignment.title)
                        .font(.lhfAssignmentTitle(20))
                        .foregroundStyle(Color.smoothInk)
                        .strikethrough(true, color: Color.smoothInk)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }

                Spacer(minLength: 8)

                if let dayLabel {
                    Text(dayLabel)
                        .font(.lhfMono(15, weight: .medium))
                        .foregroundStyle(Color.smoothInk)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .background(smoothTaskFill(item.due))
            .clipShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .contentShape(RoundedRectangle(cornerRadius: corner, style: .continuous))
            .opacity(0.55)
        }
        .buttonStyle(.plain)
    }
}

/// The words of the prev tab's backlog line, kept apart from the view so the
/// singular/plural rule can be tested without rendering anything. Lowercase,
/// like the rest of the dashboard's captions.
enum SignupBacklogCopy {
    static func line(count: Int, revealed: Bool) -> String {
        if revealed {
            return count == 1
                ? "showing an older assignment from before you joined"
                : "showing older assignments from before you joined"
        }
        return count == 1
            ? "1 older assignment from before you joined is hidden"
            : "\(count) older assignments from before you joined are hidden"
    }

    static func buttonTitle(revealed: Bool) -> String {
        revealed ? "hide" : "show"
    }

    static func accessibilityLabel(revealed: Bool) -> String {
        revealed
            ? "hide older assignments from before you joined"
            : "show older assignments from before you joined"
    }
}
