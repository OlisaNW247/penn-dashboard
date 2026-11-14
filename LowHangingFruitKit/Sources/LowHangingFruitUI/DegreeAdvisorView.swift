import SwiftUI
import LowHangingFruitKit

/// One line of the degree chat.
struct DegreeAdvisorMessage: Identifiable, Equatable {
    let id: UUID
    let isUser: Bool
    let text: String
    var changes: [DegreeAdvisorChange]
    var planBefore: DegreePlan?
    var undone: Bool
    var failed: Bool
}

/// The degree screen's chat sheet. A message sends the audit and plan as text
/// to smooth's server, only when the student sends it; nothing is stored there.
/// Edits the model proposes are applied at once, with an undo on the latest
/// one, because the plan is the student's own sketch and one tap restores it.
/// The wrong fix would be a confirmation step on every edit, which undoes the
/// ask that it add courses for you.
struct DegreeAdvisorView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss

    /// Owned by the screen so the conversation survives closing the sheet.
    @Binding var messages: [DegreeAdvisorMessage]
    let audits: [DegreeLabeledAudit]

    @State private var draft = ""
    @State private var waiting = false

    nonisolated static func starters(hasSeveralDegrees: Bool, nextTermLabel: String?) -> [String] {
        let label = nextTermLabel ?? "next semester"
        if hasSeveralDegrees {
            return ["what should i take in \(label) for both degrees?",
                    "fill \(label) with classes that count",
                    "what's left in each degree?"]
        }
        return ["what should i take in \(label)?",
                "fill \(label) with classes that count",
                "what's left to finish?"]
    }

    private var nextTermLabel: String? {
        state.degreePlan.terms.first.map { DegreePlanMath.termLabel($0.termCode) }
    }

    private var canSend: Bool {
        !waiting && !draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var latestChangeID: UUID? {
        messages.last(where: { !$0.changes.isEmpty })?.id
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text("plan with ai")
                    .font(.lhfSerif(28))
                    .foregroundStyle(Color.smoothInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .accessibilityAddTraits(.isHeader)
                conversation
                composer
            }
            .background(Color.smoothPaper.ignoresSafeArea())
            .navigationTitle("")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("close") { dismiss() }
                }
            }
        }
        .environmentObject(state)
        .lhfSheetTheme()
    }

    // MARK: Conversation

    private var conversation: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if messages.isEmpty && !waiting {
                        emptyState
                    }
                    ForEach(messages) { message in
                        row(message)
                            .id(message.id)
                    }
                    if waiting {
                        ProgressView()
                            .controlSize(.small)
                            .id("waiting")
                    }
                }
                .padding(20)
            }
            .onChange(of: messages.count) { _, _ in
                if let last = messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: .bottom) }
                }
            }
            .onChange(of: waiting) { _, isWaiting in
                if isWaiting { withAnimation { proxy.scrollTo("waiting", anchor: .bottom) } }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Self.starters(hasSeveralDegrees: state.degreeHasSeveral,
                                  nextTermLabel: nextTermLabel), id: \.self) { line in
                Button { send(line) } label: {
                    Text(line)
                        .font(.lhfSans(14))
                        .foregroundStyle(Color.smoothInk)
                        .multilineTextAlignment(.leading)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 10)
                        .background(Color.smoothSurface.opacity(0.58), in: Capsule())
                        .overlay { Capsule().stroke(Color.smoothRule.opacity(0.72), lineWidth: 1.25) }
                }
                .buttonStyle(.plain)
            }
            Text("sends your audit and plan to smooth's server to answer. nothing is stored.")
                .font(.lhfSans(12))
                .foregroundStyle(Color.smoothMuted)
        }
    }

    @ViewBuilder
    private func row(_ message: DegreeAdvisorMessage) -> some View {
        if message.isUser {
            HStack {
                Spacer(minLength: 40)
                Text(message.text)
                    .font(.lhfSans(14))
                    .foregroundStyle(Color.smoothInk)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.smoothGrape.opacity(0.28),
                                in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            }
        } else {
            VStack(alignment: .leading, spacing: 8) {
                Text(message.text)
                    .font(.lhfSans(14))
                    .foregroundStyle(message.failed ? Color.smoothMuted : Color.smoothInk)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if !message.changes.isEmpty {
                    changesCard(message)
                }
            }
        }
    }

    private func changesCard(_ message: DegreeAdvisorMessage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(DegreeAdvisor.summary(message.changes).enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.lhfSans(13))
                    .foregroundStyle(Color.smoothInk)
            }
            if message.undone {
                Text("undone")
                    .font(.lhfSans(13))
                    .foregroundStyle(Color.smoothMuted)
            } else if message.id == latestChangeID, let before = message.planBefore {
                Button { undo(message, to: before) } label: {
                    Text("undo")
                        .font(.lhfSans(13, weight: .semibold))
                        .foregroundStyle(Color.smoothGrapeInk)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.v2Card, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.smoothRule.opacity(0.72), lineWidth: 1)
        }
    }

    // MARK: Composer

    private var composer: some View {
        HStack(alignment: .bottom, spacing: 10) {
            TextField("ask about your degree", text: $draft, axis: .vertical)
                .lineLimit(1...4)
                .font(.lhfSans(14))
                .textFieldStyle(.plain)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Color.smoothSurface.opacity(0.58),
                            in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 20, style: .continuous)
                        .stroke(Color.smoothRule.opacity(0.72), lineWidth: 1.25)
                }
#if os(iOS)
                .textInputAutocapitalization(.never)
#endif
            Button { send(draft) } label: {
                Image(systemName: "arrow.up")
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(Color.smoothInk)
                    .frame(width: 38, height: 38)
                    .background(canSend ? Color.smoothGrape : Color.smoothSurface, in: Circle())
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
            .accessibilityLabel("send")
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    // MARK: Actions

    private func send(_ raw: String) {
        let question = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !waiting, !question.isEmpty else { return }
        let turns: [DegreeAdvisorTurn] = messages.compactMap { message in
            message.failed ? nil
                : DegreeAdvisorTurn(role: message.isUser ? "user" : "assistant", content: message.text)
        }
        messages.append(DegreeAdvisorMessage(id: UUID(), isUser: true, text: question,
                                             changes: [], planBefore: nil, undone: false, failed: false))
        draft = ""
        waiting = true
        let sent = audits
        Task {
            let reply = await state.askDegreeAdvisor(question: question, turns: turns, audits: sent)
            messages.append(DegreeAdvisorMessage(id: UUID(), isUser: false, text: reply.answer,
                                                 changes: reply.changes, planBefore: reply.planBefore,
                                                 undone: false, failed: reply.failed))
            waiting = false
        }
    }

    private func undo(_ message: DegreeAdvisorMessage, to plan: DegreePlan) {
        state.undoDegreeAdvisor(to: plan)
        if let index = messages.firstIndex(where: { $0.id == message.id }) {
            messages[index].undone = true
        }
    }
}
