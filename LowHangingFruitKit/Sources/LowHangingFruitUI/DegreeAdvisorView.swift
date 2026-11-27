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
    var notice: String? = nil
    /// The engine's schedule card, built once when the reply arrives.
    var planLines: DegreeAdvisorPlanLines? = nil
    var email: String? = nil
    /// A failed reply the student can fix by asking again.
    var canRetry: Bool = false
}

/// The display lines of an engine plan's card. Pure, so a test can read them
/// and the view never builds a list in its body.
struct DegreeAdvisorPlanLines: Equatable {
    struct Scenario: Equatable {
        let text: String
        let isChosen: Bool
        let meetsTarget: Bool
    }
    let scenarios: [Scenario]
    /// "21.5 cu left · 28 without double counting"
    let totals: String
    let unfilled: [String]
    let petitions: [String]

    static let maxUnfilled = 4
    static let maxPetitions = 3
}

/// The degree screen's chat sheet. A message sends the audit and plan as text
/// to smooth's server, only when the student sends it; nothing is stored there.
/// Edits the model proposes are applied at once, with an undo on the latest
/// one, because the plan is the student's own sketch and one tap restores it.
/// When the model needs a program's audit it does not have (a concentration the
/// student has not declared), the phone reads Penn's what-if for it, swaps it
/// in and asks again within the same send; `activeAudits` keeps that audit for
/// the next question.
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
    @State private var stage: String?
    @State private var activeAudits: [DegreeLabeledAudit]?
    @State private var showQuestions = false

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

    /// One decimal at most, none when whole: "5", "5.5".
    nonisolated static func creditsText(_ value: Double) -> String {
        guard value.isFinite, abs(value) < 1e9 else { return "0" }
        let rounded = (value * 10).rounded() / 10
        if rounded == rounded.rounded() { return String(Int(rounded)) }
        return String(format: "%.1f", rounded)
    }

    /// One scenario row. "best" plans at the top load with 4 cu summers and the
    /// approvals, so it must not read like "approved" (the same load and
    /// summers, no extras): `6.5 cu · 4 cu summers · approvals → spring 2028`.
    nonisolated static func scenarioText(_ scenario: DegreeEngineScenario) -> String {
        var text: String
        if scenario.id == "best" {
            text = "\(creditsText(scenario.maxLoad)) cu · 4 cu summers · approvals"
        } else {
            text = "\(creditsText(scenario.maxLoad)) cu · " + (scenario.summer ? "summer" : "no summer")
        }
        if let finish = scenario.finishTerm, !finish.isEmpty {
            text += " → \(DegreePlanMath.termLabel(finish))"
        }
        return text
    }

    /// The card under an answer that carries an engine plan.
    nonisolated static func planLines(_ plan: DegreeEnginePlan) -> DegreeAdvisorPlanLines {
        let scenarios = plan.scenarios.map { scenario -> DegreeAdvisorPlanLines.Scenario in
            return DegreeAdvisorPlanLines.Scenario(
                text: scenarioText(scenario), isChosen: scenario.id == plan.chosen,
                meetsTarget: scenario.meetsTarget)
        }
        let totals = "\(creditsText(plan.remainingCredits)) cu left · "
            + "\(creditsText(plan.remainingCreditsWithoutOverlap)) without double counting"

        var unfilled: [String] = plan.unfilled.prefix(DegreeAdvisorPlanLines.maxUnfilled).map { item in
            item.reason.isEmpty ? "not planned: \(item.label)" : "not planned: \(item.label) · \(item.reason)"
        }
        if plan.unfilled.count > DegreeAdvisorPlanLines.maxUnfilled {
            unfilled.append("+\(plan.unfilled.count - DegreeAdvisorPlanLines.maxUnfilled) more")
        }

        var petitions: [String] = plan.petitions.prefix(DegreeAdvisorPlanLines.maxPetitions).map { item in
            item.slots.isEmpty
                ? "ask your advisor: \(item.code)"
                : "ask your advisor: \(item.code) for \(item.slots.joined(separator: " + "))"
        }
        if plan.petitions.count > DegreeAdvisorPlanLines.maxPetitions {
            petitions.append("+\(plan.petitions.count - DegreeAdvisorPlanLines.maxPetitions) more")
        }
        return DegreeAdvisorPlanLines(scenarios: scenarios, totals: totals, unfilled: unfilled, petitions: petitions)
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

    private var latestPlanMessageID: UUID? {
        messages.last(where: { $0.planLines != nil })?.id
    }

    /// Takes the table's pending "update plan" prompt, exactly once: it is
    /// cleared before it is sent, so a second appearance finds nothing.
    private func consumePendingPrompt() {
        guard let prompt = state.degreeAdvisorPendingPrompt else { return }
        state.degreeAdvisorPendingPrompt = nil
        send(prompt)
    }

    var body: some View {
        advisorContent
            .pathSignInSheet()
    }

    private var advisorContent: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Text("plan with ai")
                    .font(.lhfSerif(28))
                    .foregroundStyle(Color.smoothInk)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 10)
                    .accessibilityAddTraits(.isHeader)
                Divider().overlay(Color.smoothRule.opacity(0.6))
                conversation
                    .sheet(isPresented: $showQuestions) {
                        DegreeAdvisorQuestionsSheet(onUpdate: {
                            send(DegreeAdvisorQuestionsSheet.updatePrompt)
                        })
                        .environmentObject(state)
                    }
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
        .onAppear { consumePendingPrompt() }
        .onChange(of: state.degreeAdvisorPendingPrompt) { _, _ in consumePendingPrompt() }
        .task {
            // The model can only ask for a what-if audit ("plan toward a
            // finance concentration") from the list of programs the phone
            // holds, and that list is otherwise loaded only by the what-if
            // tab. Opening the chat is the student asking for planning help,
            // so it is loaded here too; it returns at once when cached.
            if state.degree.programs.isEmpty {
                _ = await state.loadDegreePrograms()
            }
        }
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
                        HStack(spacing: 8) {
                            ProgressView()
                                .controlSize(.small)
                            // The status, not the stage closure, carries the
                            // Duo wait, so a push already waiting from a tap on
                            // the degree screen shows here too.
                            if state.degreeInteractiveSignIn {
                                Text(DegreeStatus.finishSigningIn.line(now: Date()) ?? "")
                                    .font(.lhfSans(12, weight: .semibold))
                                    .foregroundStyle(Color.smoothInk)
                            } else if state.degreeStatus == .waitingForDuo {
                                Text(DegreeStatus.waitingForDuo.line(now: Date()) ?? "")
                                    .font(.lhfSans(12, weight: .semibold))
                                    .foregroundStyle(Color.smoothInk)
                            } else if let stage {
                                Text(stage)
                                    .font(.lhfSans(12))
                                    .foregroundStyle(Color.smoothMuted)
                            }
                        }
                        .id("waiting")
                    }
                }
                .padding(20)
            }
            .onChange(of: messages.count) { _, _ in
                if let last = messages.last {
                    withAnimation { proxy.scrollTo(last.id, anchor: last.isUser ? .bottom : .top) }
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
                if let notice = message.notice {
                    HStack(spacing: 5) {
                        Image(systemName: "arrow.triangle.2.circlepath")
                            .font(.system(size: 11))
                        Text(notice)
                            .font(.lhfSans(12))
                    }
                    .foregroundStyle(Color.smoothMuted)
                }
                Text(message.text)
                    .font(.lhfSans(14))
                    .lineSpacing(3)
                    .foregroundStyle(message.failed ? Color.smoothMuted : Color.smoothInk)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if message.canRetry, !waiting, messages.last?.id == message.id {
                    Button { retry() } label: {
                        Text("try again")
                            .font(.lhfSans(13, weight: .semibold))
                            .foregroundStyle(Color.smoothGrapeInk)
                    }
                    .buttonStyle(.plain)
                }
                if let lines = message.planLines {
                    planCard(lines)
                    if message.id == latestPlanMessageID, let notes = state.degreePlan.advisor,
                       !notes.questions.isEmpty {
                        Button { showQuestions = true } label: {
                            Text(DegreeAdvisorQuestionsSheet.entryText(notes))
                                .font(.lhfSans(13, weight: .semibold))
                                .foregroundStyle(Color.smoothGrapeInk)
                        }
                        .buttonStyle(.plain)
                    }
                }
                if !message.changes.isEmpty {
                    changesCard(message)
                }
                if let email = message.email {
                    emailDisclosure(email)
                }
            }
        }
    }

    private func planCard(_ lines: DegreeAdvisorPlanLines) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(lines.scenarios.enumerated()), id: \.offset) { _, scenario in
                HStack(spacing: 6) {
                    if scenario.meetsTarget {
                        Image(systemName: "checkmark")
                            .font(.system(size: 11, weight: .bold))
                            .foregroundStyle(Color.smoothTealInk)
                            .accessibilityLabel("meets your target")
                    }
                    Text(scenario.text)
                        .font(.lhfSans(13, weight: scenario.isChosen ? .bold : .regular))
                        .foregroundStyle(Color.smoothInk)
                }
            }
            Text(lines.totals)
                .font(.lhfSans(13))
                .foregroundStyle(Color.smoothInk)
            ForEach(Array(lines.unfilled.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.lhfSans(12))
                    .foregroundStyle(Color.smoothMuted)
            }
            ForEach(Array(lines.petitions.enumerated()), id: \.offset) { _, line in
                Text(line)
                    .font(.lhfSans(12))
                    .foregroundStyle(Color.smoothMuted)
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

    private func emailDisclosure(_ email: String) -> some View {
        DisclosureGroup("advisor email") {
            VStack(alignment: .leading, spacing: 8) {
                Text(email)
                    .font(.lhfSans(13))
                    .foregroundStyle(Color.smoothInk)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button { Self.copyToPasteboard(email) } label: {
                    Text("copy")
                        .font(.lhfSans(13, weight: .semibold))
                        .foregroundStyle(Color.smoothGrapeInk)
                }
                .buttonStyle(.plain)
            }
            .padding(.top, 6)
        }
        .font(.lhfSans(13))
        .foregroundStyle(Color.smoothInk)
    }

    static func copyToPasteboard(_ text: String) {
#if os(iOS)
        UIPasteboard.general.string = text
#elseif os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
#endif
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

    /// "try again" re-sends the question of the failed exchange: the failed
    /// reply goes, the student's own message stays and is not repeated.
    private func retry() {
        guard !waiting, let last = messages.last, !last.isUser, last.canRetry,
              let asked = messages.last(where: { $0.isUser }) else { return }
        send(asked.text, retrying: true)
    }

    private func send(_ raw: String, retrying: Bool = false) {
        let question = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !waiting, !question.isEmpty else { return }
        if retrying, let last = messages.last, !last.isUser, last.failed { messages.removeLast() }
        let earlier: [DegreeAdvisorMessage] = retrying ? Array(messages.dropLast()) : messages
        let turns: [DegreeAdvisorTurn] = earlier.compactMap { message in
            message.failed ? nil
                : DegreeAdvisorTurn(role: message.isUser ? "user" : "assistant", content: message.text)
        }
        if !retrying {
            messages.append(DegreeAdvisorMessage(id: UUID(), isUser: true, text: question,
                                                 changes: [], planBefore: nil, undone: false, failed: false))
        }
        draft = ""
        waiting = true
        let sent = activeAudits ?? audits
        stage = "planning…"
        Task {
            let reply = await state.askDegreeAdvisor(question: question, turns: turns, audits: sent,
                                                     onStage: { stage = $0 })
            if let used = reply.audits { activeAudits = used }
            stage = nil
            messages.append(DegreeAdvisorMessage(id: UUID(), isUser: false, text: reply.answer,
                                                 changes: reply.changes, planBefore: reply.planBefore,
                                                 undone: false, failed: reply.failed,
                                                 notice: reply.notice,
                                                 planLines: reply.plan.map { Self.planLines($0) },
                                                 email: reply.email,
                                                 canRetry: reply.canRetry))
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
