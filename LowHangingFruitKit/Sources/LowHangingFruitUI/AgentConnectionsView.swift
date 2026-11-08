import SwiftUI
import LowHangingFruitKit

/// Profile → accounts → "connect an agent": the opt-in, the disclosure Apple
/// 5.1.2(i) asks for, the connected agents, and a typed-code fallback.
struct AgentConnectionsView: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var connections: [AgentConnectionSummary] = []
    @State private var toDisconnect: AgentConnectionSummary?
    @State private var disconnectFailed = false
    @State private var code = ""
    @State private var isLookingUp = false
    @State private var codeNotFound = false
    @State private var lookup: AgentLookupPresentation?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle(AgentConnectionCopy.switchLabel, isOn: Binding(
                        get: { state.agentConnectionEnabled },
                        set: { on in Task { await state.setAgentConnectionEnabled(on); connections = await state.refreshAgentConnections() } }
                    ))
                    VStack(alignment: .leading, spacing: 6) {
                        Text(AgentConnectionCopy.disclosureIntro)
                        ForEach(AgentConnectionCopy.disclosureItems, id: \.self) { Text("· " + $0) }
                        Text(AgentConnectionCopy.never)
                        Text(AgentConnectionCopy.recipients)
                        Text(AgentConnectionCopy.offEffect)
                        if let url = URL(string: AgentConnectionCopy.privacyURL) {
                            Link(AgentConnectionCopy.privacyPolicy, destination: url)
                        }
                    }
                    .font(.lhfSecondary(12))
                    .foregroundStyle(Color.smoothMuted)
                }
                .smoothSectionBackground(.smoothTeal)

                Section {
                    if connections.isEmpty {
                        Text(AgentConnectionCopy.none).foregroundStyle(Color.smoothMuted)
                    }
                    ForEach(connections) { item in
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.clientName)
                                Text(item.lastUsedAt.map { AgentConnectionCopy.lastUsed(Self.relative($0)) }
                                     ?? AgentConnectionCopy.neverUsed)
                                    .font(.lhfSecondary(12))
                                    .foregroundStyle(Color.smoothMuted)
                            }
                            Spacer()
                            Button(AgentConnectionCopy.disconnect) { toDisconnect = item }
                                .buttonStyle(.borderless)
                        }
                    }
                    if disconnectFailed {
                        Text(AgentConnectionCopy.disconnectFailure)
                            .font(.lhfSecondary(12)).foregroundStyle(Color.smoothTomatoInk)
                    }
                } header: {
                    SmoothSectionHeader(AgentConnectionCopy.connectedHeader, accent: .smoothCobalt)
                }
                .smoothSectionBackground(.smoothTeal)

                Section {
                    TextField(AgentConnectionCopy.codePlaceholder, text: $code)
#if os(iOS)
                        .textInputAutocapitalization(.characters)
#endif
                        .autocorrectionDisabled()
                    Button {
                        lookUpCode()
                    } label: {
                        HStack(spacing: 10) {
                            if isLookingUp { ProgressView().controlSize(.small) }
                            Text(AgentConnectionCopy.connect)
                        }
                    }
                    .disabled(isLookingUp || code.trimmingCharacters(in: .whitespaces).isEmpty)
                    if codeNotFound {
                        Text(AgentConnectionCopy.codeNotFound)
                            .font(.lhfSecondary(12)).foregroundStyle(Color.smoothTomatoInk)
                    }
                } header: {
                    SmoothSectionHeader(AgentConnectionCopy.codeHeader, accent: .smoothCobalt)
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
            .task { connections = await state.refreshAgentConnections() }
            .alert(toDisconnect.map { AgentConnectionCopy.disconnectTitle($0.clientName) } ?? "",
                   isPresented: Binding(get: { toDisconnect != nil }, set: { if !$0 { toDisconnect = nil } })) {
                Button(AgentConnectionCopy.disconnect, role: .destructive) {
                    if let item = toDisconnect { revoke(item) }
                }
                Button(AgentConnectionCopy.cancel, role: .cancel) {}
            }
            .sheet(item: $lookup, onDismiss: {
                Task { connections = await state.refreshAgentConnections() }
            }) { shown in
                AgentLinkApproveSheet(lookup: shown.lookup).environmentObject(state)
            }
        }
        .lhfSheetTheme()
#if os(macOS)
        .frame(minWidth: 360, minHeight: 480)
#endif
    }

    private static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: date, relativeTo: Date())
    }

    private func revoke(_ item: AgentConnectionSummary) {
        disconnectFailed = false
        Task {
            let ok = await state.revokeAgentConnection(id: item.id)
            disconnectFailed = !ok
            connections = await state.refreshAgentConnections()
        }
    }

    private func lookUpCode() {
        guard !isLookingUp else { return }
        isLookingUp = true
        codeNotFound = false
        Task {
            let found = await state.lookupAgentCode(code)
            isLookingUp = false
            if let found {
                code = ""
                lookup = AgentLookupPresentation(lookup: found)
            } else {
                codeNotFound = true
            }
        }
    }
}
