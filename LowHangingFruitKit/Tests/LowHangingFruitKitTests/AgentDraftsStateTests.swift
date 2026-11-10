import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// The drafts' life on `AppState`: the cache, the notices, the card's view of
/// a draft and the "connected to claude" line. Serialized and restoring,
/// because the keys live in the shared `UserDefaults.lhf` domain (CLAUDE.md,
/// the shared-defaults trap).
@MainActor
@Suite("Agent drafts on AppState", .serialized)
struct AgentDraftsStateTests {
    static let keys = [AgentDraftCache.key, AgentDraftNotices.notifiedKey, AppState.agentKnownConnectionIDsKey]

    private func withCleanKeys(_ body: () async throws -> Void) async rethrows {
        let backup = Self.keys.map { UserDefaults.lhf.object(forKey: $0) }
        Self.keys.forEach { UserDefaults.lhf.removeObject(forKey: $0) }
        defer {
            for (key, value) in zip(Self.keys, backup) {
                if let value { UserDefaults.lhf.set(value, forKey: key) } else { UserDefaults.lhf.removeObject(forKey: key) }
            }
        }
        try await body()
    }

    private func makeState() throws -> AppState {
        let suite = "AgentDraftsStateTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        let state = AppState(assignmentStore: try AssignmentStore(inMemory: true), dueDateEditsDefaults: defaults)
        state.forceFixtureDataForTesting(false)
        return state
    }

    private static let item = Assignment(source: .canvas, sourceID: "event-assignment-34", kind: .assignment,
                                         course: "PHYS 0151", title: "Problem Set 7", dueAt: nil, url: nil)

    @Test("a fresh list is cached without content, and notices once per draft")
    func applyCachesAndNotifies() async throws {
        try await withCleanKeys {
            let state = try makeState()
            state.assignments = [Self.item]
            let draft = AgentDraft(id: "smd_1", assignmentID: Self.item.id, kind: .text, body: "answer", clientName: "Claude")
            state.applyAgentDrafts([draft, AgentDraft(id: "smd_2", assignmentID: "other", kind: .text, status: .declined)])
            #expect(state.agentDrafts.map(\.id) == ["smd_1"])
            #expect(AgentDraftCache.load(from: .lhf).map(\.id) == ["smd_1"])
            #expect(AgentDraftCache.load(from: .lhf).first?.body == nil)
            #expect(state.pendingAgentDraftNotices.map(\.title) == ["Claude drafted Problem Set 7"])

            state.pendingAgentDraftNotices = []
            state.applyAgentDrafts([draft])
            #expect(state.pendingAgentDraftNotices.isEmpty, "never twice")
        }
    }

    @Test("the card's view: the chip and preview, then check canvas once a submission went out")
    func display() async throws {
        try await withCleanKeys {
            let state = try makeState()
            let draft = AgentDraft(id: "smd_1", assignmentID: Self.item.id, kind: .text, body: "Line one", clientName: "Claude")
            state.applyAgentDrafts([draft])
            let shown = try #require(state.agentDraftDisplay(forItemID: Self.item.id))
            #expect(shown.agentName == "claude" && shown.preview == "Line one" && !shown.checkCanvas && shown.isUnseen)
            #expect(state.agentDraftDisplay(forItemID: "nothing") == nil)

            try state.agentSubmitAttempts.begin(draftID: "smd_1", assignmentID: Self.item.id)
            state.agentSubmitAttempts.finish(draftID: "smd_1", outcome: .indeterminate)
            #expect(state.agentDraftDisplay(forItemID: Self.item.id)?.checkCanvas == true)

            state.agentSubmitAttempts.finish(draftID: "smd_1", outcome: .submitted, canvasSubmissionID: "9")
            #expect(state.agentDraftDisplay(forItemID: Self.item.id) == nil, "a sent draft leaves its card")

            // A draft with an attempt can never be declined from the phone.
            #expect(await state.declineAgentDraft("smd_1") == false)
        }
    }

    @Test("fixture data shows no drafts")
    func fixture() async throws {
        try await withCleanKeys {
            let state = try makeState()
            state.applyAgentDrafts([AgentDraft(id: "smd_1", assignmentID: Self.item.id, kind: .text, body: "x")])
            state.forceFixtureDataForTesting(true)
            #expect(state.agentDraftDisplay(forItemID: Self.item.id) == nil)
            #expect(await state.submitAgentDraft("smd_1") == .refused(.missingIDs))
        }
    }

    private func connection(_ id: String) -> AgentConnectionSummary {
        AgentConnectionSummary(id: id, clientName: "Claude", clientHost: "claude.ai", scopes: ["read"],
                               createdAt: Date(), lastUsedAt: nil)
    }

    @Test("the first list only records; a connection that appears later raises the line")
    func banner() async throws {
        try await withCleanKeys {
            let state = try makeState()
            state.noteAgentConnections([connection("c1")])
            #expect(state.agentConnectionBanner == nil, "a connection made before this build says nothing")
            state.noteAgentConnections([connection("c1")])
            #expect(state.agentConnectionBanner == nil)
            state.noteAgentConnections([connection("c1"), connection("c2")])
            #expect(state.agentConnectionBanner == "connected to claude")
            state.agentConnectionBanner = nil
            state.noteAgentConnections([connection("c2")])
            #expect(state.agentConnectionBanner == nil)
            state.clearAgentDraftsLocally()
            #expect(UserDefaults.lhf.stringArray(forKey: AppState.agentKnownConnectionIDsKey) == nil)
        }
    }

    @Test("the collapsed card's caveat line carries the chip beside the fact words")
    func caveat() {
        var item = DashItem(assignment: Self.item, dueOverride: nil, isCompleted: false, completedAt: nil)
        #expect(item.caveatText == nil)
        item.agentDraft = AgentDraftDisplay(draftID: "d", agentName: "claude", preview: nil, checkCanvas: false, isUnseen: true)
        #expect(item.caveatText == "drafted by claude")
    }
}
