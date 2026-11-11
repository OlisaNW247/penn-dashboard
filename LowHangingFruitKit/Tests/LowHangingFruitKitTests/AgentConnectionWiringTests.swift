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

    @Test("the Profile row is gated on canUseAgentConnection")
    func rowGated() throws {
        let src = try uiSource("SettingsPage.swift")
        guard !src.isEmpty else { return }
        let gate = try #require(src.range(of: "if state.canUseAgentConnection {"))
        let sheet = try #require(src.range(of: "AgentConnectionCopy.rowLabel"))
        #expect(gate.upperBound <= sheet.lowerBound)
        #expect(sheet.lowerBound.utf16Offset(in: src) - gate.upperBound.utf16Offset(in: src) < 300)
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
        // Since 2026-11-11 both passes go through `AgentPassRules.shouldStart`
        // (its gates are pinned with a fixed clock in `V11PhoneStateTests`).
        for gate in ["AgentPassRules.shouldStart(", "canUseAgentConnection", "agentConnectionEnabled",
                     "renewalContext == .background", "isFixtureData: isUsingFixtureData", "agentDraftsThrottle"] {
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
