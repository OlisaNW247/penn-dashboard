import SwiftUI
import LowHangingFruitKit

/// Every word the agent connection screens print, in one place so a test can
/// pin them (copy rule: lowercase, short, no raw errors).
enum AgentConnectionCopy {
    // Approve sheet
    static func heading(_ name: String) -> String { "connect \(name)?" }
    static let reads = "reads your classes and work"
    static let drafts = ", proposes drafts for you to review"
    static let question = "did you just start this?"
    static let pick = "pick the number the page shows"
    static let notNow = "not now"
    static func connected(_ name: String) -> String { "connected · go back to \(name)" }
    static let mismatch = "didn't match"
    static let failure = "couldn't connect"

    // Connections screen
    static let rowLabel = "connect an agent"
    static let on = "on"
    static let off = "off"
    static let switchLabel = "connect an agent"
    static let disclosureIntro = "shared with an agent you connect, and kept on smooth's server while this is on:"
    static let disclosureItems = [
        "your work list: class, title, kind, due date, done or not, whether there is anything to submit, the canvas link",
        "your classes: code, name, canvas id",
        "your own tasks",
        "course material already pooled for your classes",
    ]
    static let never = "never: grades, your name, passwords or sessions"
    static let recipients = "who receives it: the agent provider you connect (anthropic for claude, openai for chatgpt) and smooth's server"
    static let offEffect = "turning this off deletes the list and disconnects every agent"
    static let privacyPolicy = "privacy policy"
    static let privacyURL = "https://github.com/OlisaNW247/penn-dashboard/blob/v10/docs/PRIVACY.md"
    static let connectedHeader = "connected"
    static let none = "none yet"
    static let neverUsed = "never used"
    static func lastUsed(_ relative: String) -> String { "last used \(relative)" }
    static let disconnect = "disconnect"
    static func disconnectTitle(_ name: String) -> String { "disconnect \(name)?" }
    static let cancel = "cancel"
    static let disconnectFailure = "couldn't disconnect"
    static let codeHeader = "have a code?"
    static let codePlaceholder = "XXXX-XXXX"
    static let connect = "connect"
    static let codeNotFound = "code not found"
}

/// "connect <agent>?": shown for `smooth://link?c=...` or a typed code. The
/// student confirms by picking the number the agent's page shows; a wrong
/// number denies the request on the server, so the sheet then stays dead and
/// the student starts again from the agent.
struct AgentLinkApproveSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    let lookup: AgentPendingLookup
    @State private var isWorking = false
    @State private var result: Result?

    private enum Result { case connected, mismatch, failed }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    SmoothFormHeader(title: AgentConnectionCopy.heading(lookup.clientName),
                                     accent: .smoothTeal, spark: .smoothGrape)
                }
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets(top: 0, leading: 4, bottom: 0, trailing: 4))
                .listRowSeparator(.hidden)

                Section {
                    if !lookup.clientHost.isEmpty {
                        Text(lookup.clientHost)
                            .font(.lhfSecondary(12))
                            .foregroundStyle(Color.smoothMuted)
                    }
                    Text(AgentConnectionCopy.reads + (lookup.scopes.contains("draft") ? AgentConnectionCopy.drafts : ""))
                    Text(AgentConnectionCopy.question)
                    Text(AgentConnectionCopy.pick)
                        .foregroundStyle(Color.smoothMuted)
                    HStack(spacing: 12) {
                        ForEach(lookup.choices, id: \.self) { number in
                            Button { pick(number) } label: {
                                Text("\(number)")
                                    .font(.lhfSecondary(24, weight: .semibold))
                                    .frame(maxWidth: .infinity, minHeight: 56)
                            }
                            .buttonStyle(.borderedProminent)
                            .tint(Color.smoothTeal)
                            .disabled(isWorking || result != nil)
                        }
                    }
                    .listRowInsets(EdgeInsets(top: 8, leading: 16, bottom: 8, trailing: 16))

                    Button(AgentConnectionCopy.notNow) { notNow() }
                        .disabled(isWorking || result == .connected)

                    switch result {
                    case .connected:
                        Text(AgentConnectionCopy.connected(lookup.clientName))
                            .font(.lhfSecondary(12))
                    case .mismatch:
                        Text(AgentConnectionCopy.mismatch)
                            .font(.lhfSecondary(12)).foregroundStyle(Color.smoothTomatoInk)
                    case .failed:
                        Text(AgentConnectionCopy.failure)
                            .font(.lhfSecondary(12)).foregroundStyle(Color.smoothTomatoInk)
                    case nil:
                        EmptyView()
                    }
                }
                .smoothSectionBackground(.smoothTeal)
            }
            .formStyle(.grouped)
            .font(.lhfSecondary(15))
            .foregroundStyle(Color.smoothInk)
            .smoothFormChrome(accent: .smoothTeal)
            .navigationTitle("")
#if os(iOS)
            .navigationBarTitleDisplayMode(.inline)
#endif
        }
        .lhfSheetTheme()
        .presentationDetents([.medium])
        .interactiveDismissDisabled(isWorking)
#if os(macOS)
        .frame(minWidth: 320, minHeight: 360)
#endif
    }

    private func pick(_ number: Int) {
        guard !isWorking, result == nil else { return }
        isWorking = true
        Task {
            let ok = await state.approveAgentLink(id: lookup.id, picked: number)
            isWorking = false
            if ok {
                result = .connected
                try? await Task.sleep(nanoseconds: 1_000_000_000)
                dismiss()
            } else {
                // A wrong number is denied by the server; a failed call is
                // indistinguishable here, and either way the student restarts
                // from the agent.
                result = .mismatch
            }
        }
    }

    private func notNow() {
        Task {
            await state.denyAgentLink(id: lookup.id)
            dismiss()
        }
    }
}
