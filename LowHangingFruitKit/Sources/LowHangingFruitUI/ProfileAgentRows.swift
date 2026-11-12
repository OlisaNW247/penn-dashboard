import SwiftUI
import LowHangingFruitKit

/// Profile → "connected agent", the agent connection's rows (their own
/// section after accounts since 2026-11-11, headed "connected agent" since
/// 2026-11-12, at Marco's word; before, a
/// "connect an agent · on/off" row pushed a screen of its own). Marco: "under
/// accounts, in profile, it should have connected agent with a toggle and
/// then list what is connected to your agent."
///
/// In order: the switch, labelled "on" (the header says what it is); then,
/// while on, one row per connected agent (its name and "disconnect", drawn
/// like the laptop row's "unpair", behind the same kind of confirmation), or
/// "none yet"; and "connect another", which opens `AgentCodeSheet`; last, on or off, a "privacy
/// policy" link row (the full disclosure Apple 5.1.2(i) asks for is
/// `docs/PRIVACY.md` → "Connecting an AI assistant").
///
/// Turning it off deletes the server's list and disconnects every agent
/// (`AppState.setAgentConnectionEnabled`), so it asks once first: "disconnect
/// every agent?", disconnect / cancel, no message.
struct ProfileAgentRows: View {
    @EnvironmentObject private var state: AppState

    @State private var connections: [AgentConnectionSummary] = []
    @State private var toDisconnect: AgentConnectionSummary?
    @State private var disconnectFailed = false
    @State private var showCode = false
    @State private var confirmingOff = false

    var body: some View {
        Toggle(AgentConnectionCopy.switchLabel, isOn: Binding(
            get: { state.agentConnectionEnabled },
            set: { on in
                if on { setEnabled(true) } else { confirmingOff = true }
            }
        ))
        .alert(AgentConnectionCopy.offTitle, isPresented: $confirmingOff) {
            Button(AgentConnectionCopy.disconnect, role: .destructive) { setEnabled(false) }
            Button(AgentConnectionCopy.cancel, role: .cancel) {}
        }
        .task(id: state.agentConnectionEnabled) { await reload() }
        .onChange(of: state.hasAgentConnections) { _, _ in Task { await reload() } }
        .alert(toDisconnect.map { AgentConnectionCopy.disconnectTitle($0.clientName) } ?? "",
               isPresented: Binding(get: { toDisconnect != nil }, set: { if !$0 { toDisconnect = nil } })) {
            Button(AgentConnectionCopy.disconnect, role: .destructive) {
                if let item = toDisconnect { revoke(item) }
            }
            Button(AgentConnectionCopy.cancel, role: .cancel) {}
        }
        .sheet(isPresented: $showCode, onDismiss: { Task { await reload() } }) {
            AgentCodeSheet().environmentObject(state)
        }

        if state.agentConnectionEnabled {
            if connections.isEmpty {
                Text(AgentConnectionCopy.none)
                    .font(.lhfSecondary(12))
                    .foregroundStyle(Color.smoothMuted)
            }
            ForEach(connections) { item in
                Button { toDisconnect = item } label: {
                    HStack(spacing: 10) {
                        // The name only since 2026-11-12 ("last used 2h ago"
                        // went with Marco's pass).
                        Text(item.clientName.lowercased())
                            .foregroundStyle(Color.smoothInk)
                        Spacer()
                        Text(AgentConnectionCopy.disconnect)
                            .font(.lhfSecondary(12, weight: .medium))
                            .foregroundStyle(Color.smoothMuted)
                        Image(systemName: "chevron.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(Color.smoothMuted)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityElement(children: .combine)
                .accessibilityHint("double tap to disconnect")
            }
            if disconnectFailed {
                Text(AgentConnectionCopy.disconnectFailure)
                    .font(.lhfSecondary(12))
                    .foregroundStyle(Color.smoothTomatoInk)
            }
            Button { showCode = true } label: {
                HStack {
                    Text(AgentConnectionCopy.codeHeader).foregroundStyle(Color.smoothInk)
                    Spacer()
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.smoothMuted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }

        // The block's last row, on or off: a plain link, no sentence (Marco,
        // 2026-11-11, on the line it replaced, "shares your classes and work
        // list with the agent's provider · privacy policy": "All this
        // explanation text ... I need that gone"). The policy carries the
        // whole disclosure.
        if let url = URL(string: AgentConnectionCopy.privacyURL) {
            Link(destination: url) {
                HStack {
                    Text(AgentConnectionCopy.privacyPolicy).foregroundStyle(Color.smoothInk)
                    Spacer()
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(Color.smoothMuted)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func setEnabled(_ on: Bool) {
        Task {
            await state.setAgentConnectionEnabled(on)
            connections = on ? await state.refreshAgentConnections() : []
        }
    }

    private func reload() async {
        connections = state.agentConnectionEnabled ? await state.refreshAgentConnections() : []
    }

    private func revoke(_ item: AgentConnectionSummary) {
        disconnectFailed = false
        Task {
            let ok = await state.revokeAgentConnection(id: item.id)
            disconnectFailed = !ok
            await reload()
        }
    }
}

/// "connect another": the typed 8-letter code from the agent's sign-in page,
/// then the approve sheet over it. Closing the approve sheet closes this one.
struct AgentCodeSheet: View {
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    @State private var code = ""
    @State private var isLookingUp = false
    @State private var codeNotFound = false
    @State private var lookup: AgentLookupPresentation?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField(AgentConnectionCopy.codePlaceholder, text: $code)
#if os(iOS)
                        .textInputAutocapitalization(.characters)
#endif
                        .autocorrectionDisabled()
                        .onSubmit(lookUpCode)
                    Button(action: lookUpCode) {
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
            .sheet(item: $lookup, onDismiss: { dismiss() }) { shown in
                AgentLinkApproveSheet(lookup: shown.lookup).environmentObject(state)
            }
        }
        .lhfSheetTheme()
        .presentationDetents([.height(260)])
#if os(macOS)
        .frame(minWidth: 320, minHeight: 220)
#endif
    }

    private func lookUpCode() {
        guard !isLookingUp, !code.trimmingCharacters(in: .whitespaces).isEmpty else { return }
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
