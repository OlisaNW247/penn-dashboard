import SwiftUI
import LowHangingFruitKit

/// The questions the planner says only the student's own advisor can settle
/// (a course counted twice, a placement exam, a heavier load), and the two taps
/// that put the advisor's answers back. An answer is the student's own note: it
/// is saved with the plan and goes to the server only inside the next plan
/// request. "update plan" asks the planner again through the chat's own send
/// path, so there is one way a plan is made.
///
/// Presented by whichever view hosts it (the semester table, in every tab and
/// in the full view, and the chat), because a sheet cannot present over another
/// presenter's sheet. `onUpdate` is the host's: the table opens the chat with a
/// pending prompt, the chat sends the prompt itself.
struct DegreeAdvisorQuestionsSheet: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    /// The one message "update plan" sends.
    static let updatePrompt = "update my plan with my advisor's answers"

    /// Called after the sheet has dismissed itself.
    let onUpdate: () -> Void

    private var notes: DegreeAdvisorNotes? { state.degreePlan.advisor }

    /// The line that opens this sheet, in the table and in the chat: the count
    /// of questions still open, or, once all are answered, what to do next.
    nonisolated static func entryText(_ notes: DegreeAdvisorNotes) -> String {
        let open = notes.openCount
        if open > 0 { return "ask your advisor · \(open)" }
        return notes.hasChanges ? "advisor answers · update plan" : "advisor answers"
    }

    /// Unanswered first, each group in the server's order.
    nonisolated static func ordered(_ notes: DegreeAdvisorNotes) -> [DegreeAdvisorQuestion] {
        let open = notes.questions.filter { notes.answers[$0.id] == nil }
        let answered = notes.questions.filter { notes.answers[$0.id] != nil }
        return open + answered
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 12) {
                    Text("ask your advisor")
                        .font(.lhfSerif(28))
                        .foregroundStyle(Color.smoothInk)
                        .accessibilityAddTraits(.isHeader)
                    if let notes {
                        ForEach(Self.ordered(notes)) { question in
                            card(question, answer: notes.answers[question.id])
                        }
                    }
                }
                .padding(20)
            }
            .background(Color.smoothPaper.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) {
                if notes?.hasChanges == true {
                    Button {
                        dismiss()
                        onUpdate()
                    } label: {
                        Text("update plan")
                            .font(.lhfSans(15, weight: .semibold))
                            .foregroundStyle(Color.smoothInk)
                            .frame(maxWidth: .infinity)
                            .frame(height: 48)
                            .background(Color.smoothGrape,
                                        in: RoundedRectangle(cornerRadius: 15, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Color.smoothPaper)
                }
            }
            .navigationTitle("")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button("copy") {
                        DegreeAdvisorView.copyToPasteboard(notes?.copyText ?? "")
                    }
                    .disabled((notes?.copyText ?? "").isEmpty)
                }
            }
        }
        .environmentObject(state)
        .lhfSheetTheme()
    }

    private func card(_ question: DegreeAdvisorQuestion, answer: DegreeAdvisorAnswer?) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(question.question)
                .font(.lhfSans(15))
                .foregroundStyle(Color.smoothInk)
                .fixedSize(horizontal: false, vertical: true)
            if let detail = question.detail, !detail.isEmpty {
                Text(detail)
                    .font(.lhfSans(12))
                    .foregroundStyle(Color.smoothMuted)
            }
            HStack(spacing: 8) {
                answerButton("yes", value: .yes, current: answer, id: question.id,
                             fill: Color.smoothTeal)
                answerButton("no", value: .no, current: answer, id: question.id,
                             fill: Color.smoothTomato.opacity(0.3))
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.v2Card, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(Color.smoothRule.opacity(0.72), lineWidth: 1)
        }
    }

    /// Tapping the selected button again clears the answer.
    private func answerButton(
        _ label: String, value: DegreeAdvisorAnswer, current: DegreeAdvisorAnswer?,
        id: String, fill: Color
    ) -> some View {
        let selected = current == value
        return Button {
            state.setDegreeAdvisorAnswer(selected ? nil : value, for: id)
        } label: {
            Text(label)
                .font(.lhfSans(13, weight: .semibold))
                .foregroundStyle(Color.smoothInk)
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(selected ? fill : Color.smoothSurface.opacity(0.58), in: Capsule())
                .overlay { Capsule().stroke(Color.smoothRule.opacity(0.72), lineWidth: 1.25) }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}
