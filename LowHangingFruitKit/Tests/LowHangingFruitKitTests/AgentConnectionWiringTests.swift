import Foundation
import Testing
@testable import LowHangingFruitUI

@Suite("Agent connection wiring")
struct AgentConnectionWiringTests {
    private func packageRoot() -> URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
    }

    private func uiSource(_ name: String) throws -> String {
        let file = packageRoot().appendingPathComponent("Sources/LowHangingFruitUI/\(name)")
        guard FileManager.default.fileExists(atPath: file.path) else { return "" }
        return try String(contentsOf: file, encoding: .utf8)
    }

    private func body(of source: String, from start: String, to end: String) -> String? {
        guard let a = source.range(of: start), let b = source.range(of: end, range: a.upperBound..<source.endIndex)
        else { return nil }
        return String(source[a.upperBound..<b.lowerBound])
    }

    @Test("refresh() runs the snapshot pass right after the device sync pass")
    func refreshOrder() throws {
        let src = try uiSource("ContentView.swift")
        guard !src.isEmpty else { return }
        let refresh = try #require(body(of: src, from: "private func refresh() async {", to: "private func refreshSessionSourcesAtLaunch"))
        let sync = try #require(refresh.range(of: "await state.deviceSyncPass()"))
        let agent = try #require(refresh.range(of: "await state.agentSnapshotPass()"))
        #expect(sync.upperBound <= agent.lowerBound)
        let settle = try #require(refresh.range(of: "await settleAfterFetch()"))
        #expect(agent.upperBound <= settle.lowerBound)
        #expect(src.components(separatedBy: "agentSnapshotPass(").count == 2, "only the one call")
    }

    @Test("the launch task runs it after the device sync pass")
    func launchTask() throws {
        let src = try uiSource("RootView.swift")
        guard !src.isEmpty else { return }
        let sync = try #require(src.range(of: "await state.deviceSyncPass()"))
        let agent = try #require(src.range(of: "await state.agentSnapshotPass()"))
        #expect(sync.upperBound <= agent.lowerBound)
    }

    @Test("background refresh never touches the agent connection")
    func notInBackground() throws {
        let src = try uiSource("BackgroundRefresh.swift")
        #expect(!src.contains("agentSnapshotPass"))
        #expect(!src.contains("AgentConnection"))
    }

    @Test("disconnecting Canvas deletes the server-side snapshot")
    func disconnectDeletes() throws {
        let src = try uiSource("AppState.swift")
        guard !src.isEmpty else { return }
        let fn = try #require(body(of: src, from: "func disconnectCanvas(", to: "    func disconnectGradescope"))
        #expect(fn.contains("deleteSnapshot"))
        #expect(fn.contains("agentConnectionEnabledKey"))
    }

    @Test("the accounts section holds the agent rows, gated on canUseAgentConnection, after the laptop row")
    func rowGated() throws {
        let src = try uiSource("SettingsPage.swift")
        guard !src.isEmpty else { return }
        let bodyStart = try #require(src.range(of: "var body: some View"))
        let bodyEnd = try #require(src.range(of: ".formStyle(.grouped)", range: bodyStart.upperBound..<src.endIndex))
        let body = String(src[bodyStart.lowerBound..<bodyEnd.upperBound])
        let gate = try #require(body.range(of: "if state.canUseAgentConnection {"))
        let rows = try #require(body.range(of: "ProfileAgentRows()"))
        let laptop = try #require(body.range(of: "ProfileLaptopRow()"))
        let accounts = try #require(body.range(of: "SmoothSectionHeader(\"accounts\""))
        let appearance = try #require(body.range(of: "SmoothSectionHeader(\"appearance\""))
        #expect(gate.upperBound <= rows.lowerBound)
        #expect(rows.lowerBound.utf16Offset(in: body) - gate.upperBound.utf16Offset(in: body) < 120)
        // Inside the accounts section: the header closure follows its rows.
        #expect(laptop.lowerBound < rows.lowerBound && rows.lowerBound < accounts.lowerBound)
        #expect(accounts.lowerBound < appearance.lowerBound)
        // No pushed screen any more.
        #expect(!src.contains("AgentConnectionsView"))
        #expect(try uiSource("AgentConnectionsView.swift").isEmpty)
    }

    @Test("the agent rows: the switch, one line, the agents or none yet, have a code?")
    func agentRowsShape() throws {
        let src = try uiSource("ProfileAgentRows.swift")
        guard !src.isEmpty else { return }
        let start = try #require(src.range(of: "struct ProfileAgentRows: View {"))
        let end = try #require(src.range(of: "struct AgentCodeSheet: View {"))
        let rows = String(src[start.upperBound..<end.lowerBound])
        let toggle = try #require(rows.range(of: "Toggle(AgentConnectionCopy.switchLabel"))
        let line = try #require(rows.range(of: "Text(Self.sharesLine)"))
        let onGate = try #require(rows.range(of: "if state.agentConnectionEnabled {"))
        let none = try #require(rows.range(of: "Text(AgentConnectionCopy.none)"))
        let each = try #require(rows.range(of: "ForEach(connections)"))
        let code = try #require(rows.range(of: "Text(AgentConnectionCopy.codeHeader)"))
        #expect(toggle.lowerBound < line.lowerBound && line.lowerBound < onGate.lowerBound)
        #expect(onGate.upperBound <= none.lowerBound && none.lowerBound < each.lowerBound && each.lowerBound < code.lowerBound)
        // Each agent: its name, when it was last used, a trailing disconnect
        // behind a confirmation, like the laptop row's unpair.
        #expect(rows.contains("Text(item.clientName.lowercased())"))
        #expect(rows.contains("Text(Self.usedText(item.lastUsedAt))"))
        #expect(rows.contains("Text(AgentConnectionCopy.disconnect)"))
        #expect(rows.contains("Button(AgentConnectionCopy.disconnect, role: .destructive)"))
        #expect(rows.contains("AgentCodeSheet()"))
        // Turning it off asks once: a title, disconnect / cancel, no message.
        #expect(rows.contains("if on { setEnabled(true) } else { confirmingOff = true }"))
        let off = try #require(rows.range(of: ".alert(AgentConnectionCopy.offTitle, isPresented: $confirmingOff) {"))
        let offAlert = String(rows[off.upperBound...].prefix(260))
        #expect(offAlert.contains("Button(AgentConnectionCopy.disconnect, role: .destructive) { setEnabled(false) }"))
        #expect(offAlert.contains("Button(AgentConnectionCopy.cancel, role: .cancel) {}"))
        #expect(!offAlert.contains("message:"))
        // The long disclosure is the privacy policy's now, not the screen's.
        #expect(!src.contains("disclosure" + "Items") && !src.contains("offEffect") && !src.contains("recipients"))
        // The code sheet holds the field and the connect button, then the approve sheet.
        let sheet = String(src[end.lowerBound...])
        #expect(sheet.contains("TextField(AgentConnectionCopy.codePlaceholder"))
        #expect(sheet.contains("Text(AgentConnectionCopy.connect)"))
        #expect(sheet.contains("AgentLinkApproveSheet(lookup: shown.lookup)"))
    }

    @Test("the privacy policy still says everything the old screen said")
    func privacyPolicyCarriesTheDisclosure() throws {
        let root = packageRoot().deletingLastPathComponent()
        let policy = try String(contentsOf: root.appendingPathComponent("docs/PRIVACY.md"), encoding: .utf8)
        let a = try #require(policy.range(of: "## Connecting an AI assistant"))
        let b = try #require(policy.range(of: "\n## ", range: a.upperBound..<policy.endIndex))
        let section = String(policy[a.upperBound..<b.lowerBound])
        // What is shared: the work list fields, the classes, own tasks, course material.
        for phrase in ["the class code, the title, the kind", "due date", "whether it is done",
                       "whether there\n    is anything to submit", "Canvas page address",
                       "The list of your classes: code, name and Canvas course id",
                       "Your own tasks", "course material already pooled",
                       // Kept on the server while on.
                       "What our server keeps for this",
                       // Never.
                       "Grades or scores; your name; any\n  password, cookie or session",
                       // Who receives it.
                       "Anthropic", "OpenAI", "our own server (Supabase)",
                       // What off does.
                       "Turn\n  the feature off, which deletes the stored work list and revokes every\n  connection"] {
            #expect(section.contains(phrase), "\(phrase)")
        }
        #expect(section.contains("Profile → accounts → connected agent"))
    }

    @Test("onOpenURL hands the url to pendingAgentLink(from:)")
    func openURL() throws {
        let src = try uiSource("RootView.swift")
        guard !src.isEmpty else { return }
        let handler = try #require(body(of: src, from: ".onOpenURL { url in", to: ".onChange(of: updateGate"))
        #expect(handler.contains("state.pendingAgentLink(from: url)"))
        #expect(handler.contains("guard !isWalled"))
    }

    @Test("refresh() polls drafts after the snapshot pass and before the reload, and announces them")
    func draftsInRefresh() throws {
        let src = try uiSource("ContentView.swift")
        guard !src.isEmpty else { return }
        let refresh = try #require(body(of: src, from: "private func refresh() async {", to: "private func refreshSessionSourcesAtLaunch"))
        let snapshot = try #require(refresh.range(of: "await state.agentSnapshotPass()"))
        let drafts = try #require(refresh.range(of: "await state.agentDraftsPass()"))
        let settle = try #require(refresh.range(of: "await settleAfterFetch()"))
        #expect(snapshot.upperBound <= drafts.lowerBound && drafts.upperBound <= settle.lowerBound)
        #expect(refresh.contains("await announceAgentDrafts()"))
        #expect(src.contains("AgentDraftReviewSheet(draftID:"))
        #expect(src.contains("state.agentConnectionBanner"))
    }

    @Test("the launch task polls drafts; background refresh never does")
    func draftsAtLaunchNotInBackground() throws {
        let root = try uiSource("RootView.swift")
        if !root.isEmpty {
            let snapshot = try #require(root.range(of: "await state.agentSnapshotPass()"))
            let drafts = try #require(root.range(of: "await state.agentDraftsPass()"))
            #expect(snapshot.upperBound <= drafts.lowerBound)
        }
        let bg = try uiSource("BackgroundRefresh.swift")
        #expect(!bg.contains("agentDraftsPass") && !bg.contains("submitAgentDraft"))
    }

    @Test("the drafts pass keeps the snapshot pass's gates")
    func draftsGates() throws {
        let src = try uiSource("AppState+AgentDrafts.swift")
        guard !src.isEmpty else { return }
        let pass = try #require(body(of: src, from: "func agentDraftsPass(", to: "func applyAgentDrafts("))
        for gate in ["canUseAgentConnection", "agentConnectionEnabled", "renewalContext != .background",
                     "!isUsingFixtureData", "agentDraftsThrottle"] {
            #expect(pass.contains(gate), "\(gate)")
        }
    }

    @Test("disconnecting Canvas and opting out clear the phone's drafts and attempts")
    func clears() throws {
        let app = try uiSource("AppState.swift")
        if !app.isEmpty {
            let fn = try #require(body(of: app, from: "func disconnectCanvas(", to: "    func disconnectGradescope"))
            #expect(fn.contains("clearAgentDraftsLocally()"))
        }
        let conn = try uiSource("AppState+AgentConnection.swift")
        let off = try #require(body(of: conn, from: "func setAgentConnectionEnabled(", to: "// MARK: Approving"))
        #expect(off.contains("clearAgentDraftsLocally()"))
        let drafts = try uiSource("AppState+AgentDrafts.swift")
        let clear = try #require(body(of: drafts, from: "func clearAgentDraftsLocally() {", to: "// MARK: Connected banner"))
        #expect(clear.contains("agentSubmitAttempts.removeAll()"))
        #expect(clear.contains("AgentDraftCache.key"))
    }
}
