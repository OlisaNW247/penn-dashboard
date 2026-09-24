import SwiftUI
import LowHangingFruitKit

/// The dashboard's "?" button: when the list is long and nothing is on fire,
/// hand the student one thing to start on, picked at random from the next
/// assignment in each class (`DashboardViewModel.pickCandidates`). "another"
/// rerolls without repeating the current pick; nothing is marked, moved or
/// scheduled — it is a nudge, not a planner.
struct PickAssignmentSheet: View {
    let candidates: [DashItem]

    @Environment(\.dismiss) private var dismiss
    @Environment(\.courseNameOverrides) private var courseNameOverrides
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var pick: DashItem?
    @State private var diceTurns: Double = 0

    var body: some View {
        VStack(spacing: 18) {
            Image(systemName: "dice.fill")
                .font(.system(size: 26, weight: .semibold))
                .foregroundStyle(Color.smoothGrape)
                .frame(width: 58, height: 58)
                .background(Circle().fill(Color.smoothGrape.opacity(0.16)))
                .rotationEffect(.degrees(diceTurns))
                .accessibilityHidden(true)

            if let pick {
                VStack(spacing: 8) {
                    Text("try this one")
                        .font(.lhfMono(11, weight: .semibold))
                        .tracking(0.6)
                        .foregroundStyle(Color.smoothMuted)
                    Text(pick.assignment.displayCourse(overrides: courseNameOverrides).uppercased())
                        .font(.lhfMono(10, weight: .semibold))
                        .tracking(1.1)
                        .foregroundStyle(smoothTaskTextAccent(pick.due))
                    Text(pick.assignment.title)
                        .font(.lhfAssignmentTitle(22))
                        .foregroundStyle(Color.smoothInk)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                    if let due = pick.due {
                        Text("due \(Self.relative(due))")
                            .font(.lhfMono(12))
                            .foregroundStyle(Color.smoothMuted)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 16)
                .frame(maxWidth: .infinity)
                .background(smoothTaskFill(pick.due), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .id(pick.id)
                .transition(.asymmetric(insertion: .scale(scale: 0.94).combined(with: .opacity), removal: .opacity))
            } else {
                Text("nothing due in the next two weeks.")
                    .font(.lhfSerif(18))
                    .foregroundStyle(Color.smoothInk)
            }

            HStack(spacing: 10) {
                if candidates.count > 1 {
                    Button("another") { reroll() }
                        .buttonStyle(.bordered)
                }
                Button(pick == nil ? "ok" : "on it") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
            .font(.lhfSecondary(15, weight: .semibold))
            .tint(Color.smoothGrape)
        }
        .padding(.horizontal, 24)
        .padding(.top, 28)
        .padding(.bottom, 16)
        .frame(maxWidth: .infinity)
        .background(Color.smoothPaper.ignoresSafeArea())
        .presentationDetents([.height(380)])
        .presentationDragIndicator(.visible)
        .onAppear { if pick == nil { reroll() } }
    }

    private func reroll() {
        let others = candidates.filter { $0.id != pick?.id }
        guard let next = others.randomElement() ?? candidates.randomElement() else { return }
        lhfHapticLight()
        withAnimation(reduceMotion ? nil : .spring(response: 0.4, dampingFraction: 0.75)) {
            pick = next
            diceTurns += 180
        }
    }

    private static func relative(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .full
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}
