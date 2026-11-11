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
        #expect(item.agentChipText == "drafted by claude" && item.factCaveatText == nil)
    }

    @Test("prev: a draft the student sent says submitted by you, drafted by its agent")
    func submittedInPrev() async throws {
        try await withCleanKeys {
            let state = try makeState()
            #expect(state.agentSubmittedNamesByItemID().isEmpty)
            try state.agentSubmitAttempts.begin(draftID: "smd_1", assignmentID: Self.item.id, agentName: "Claude")
            #expect(state.agentSubmittedNamesByItemID().isEmpty, "no outcome yet")
            state.agentSubmitAttempts.finish(draftID: "smd_1", outcome: .submitted, canvasSubmissionID: "9")
            try state.agentSubmitAttempts.begin(draftID: "smd_2", assignmentID: "other")
            state.agentSubmitAttempts.finish(draftID: "smd_2", outcome: .failed)
            #expect(state.agentSubmittedNamesByItemID() == [Self.item.id: "claude"])

            var done = DashItem(assignment: Self.item, dueOverride: nil, isCompleted: true, completedAt: nil,
                                agentSubmittedBy: "claude")
            #expect(done.caveatText == "submitted by you \u{00B7} drafted by claude")
            done.isCompleted = false
            #expect(done.caveatText == nil, "only on a completed card")
            state.agentSubmitAttempts.removeAll()
        }
    }

    @Test("an item the phone can never send is not online, without asking canvas")
    func acceptanceWithoutNetwork() async throws {
        try await withCleanKeys {
            let state = try makeState()
            let draft = AgentDraft(id: "smd_9", assignmentID: "x", kind: .text, body: "a")
            #expect(await state.agentDraftAcceptance(for: draft, item: nil) == .known(.notOnline))
            let quiz = AgentSnapshot.WorkItem(id: "x", course: "C", title: "Q", kind: .quiz, dueAt: nil, done: false,
                                              noSubmission: false, url: nil, source: "canvas",
                                              canvasAssignmentID: "34", canvasCourseID: "12")
            #expect(await state.agentDraftAcceptance(for: draft, item: quiz) == .known(.notOnline))

            // What the structured sources read off the assignments list is
            // used first when it lets the student send, and cached per draft:
            // no GET.
            let calls = Calls()
            state.agentRulesFetchForTesting = { _, _ in calls.count += 1; return .refused(.offline) }
            var ps = quiz; ps.kind = .assignment
            state.canvasSubmissionRulesByAssignmentID["34"] = CanvasSubmissionRules(submissionTypes: ["online_upload"])
            let fileOnly = CanvasAcceptance.online(text: false, url: false, file: true, extensions: [])
            #expect(await state.agentDraftAcceptance(for: draft, item: ps) == .known(fileOnly))
            state.canvasSubmissionRulesByAssignmentID = [:]
            #expect(await state.agentDraftAcceptance(for: draft, item: ps) == .known(fileOnly))
            #expect(calls.count == 0)
            state.clearAgentDraftsLocally()
            #expect(state.agentDraftAcceptanceByDraftID.isEmpty)
        }
    }

    final class Calls: @unchecked Sendable { var count = 0 }

    @Test("a stale locked list is confirmed live before it blocks: a live unlock opens the sheet")
    func staleLockedList() async throws {
        try await withCleanKeys {
            let state = try makeState()
            let draft = AgentDraft(id: "smd_s", assignmentID: "x", kind: .text, body: "a")
            let item = AgentSnapshot.WorkItem(id: "x", course: "C", title: "PS", kind: .assignment, dueAt: nil, done: false,
                                              noSubmission: false, url: nil, source: "canvas",
                                              canvasAssignmentID: "34", canvasCourseID: "12")
            state.canvasSubmissionRulesByAssignmentID["34"] = CanvasSubmissionRules(submissionTypes: ["online_upload"], lockedForUser: true)
            let calls = Calls()
            state.agentRulesFetchForTesting = { course, assignment in
                calls.count += 1
                #expect(course == "12" && assignment == "34")
                return .rules(CanvasSubmissionRules(submissionTypes: ["online_upload"], canSubmit: true))
            }
            let open = CanvasAcceptance.online(text: false, url: false, file: true, extensions: [])
            #expect(await state.agentDraftAcceptance(for: draft, item: item) == .known(open))
            #expect(calls.count == 1)
            // The confirmed answer is cached, for the draft and for the list.
            #expect(await state.agentDraftAcceptance(for: draft, item: item) == .known(open))
            #expect(calls.count == 1)
            #expect(state.canvasSubmissionRulesByAssignmentID["34"]?.lockedForUser == false)

            // A stale "nothing online" that the live read cannot confirm does
            // not block: the sheet falls back to the draft's own kind.
            let other = AgentDraft(id: "smd_t", assignmentID: "x", kind: .text, body: "a")
            state.canvasSubmissionRulesByAssignmentID["34"] = CanvasSubmissionRules(submissionTypes: ["on_paper"])
            state.agentRulesFetchForTesting = { _, _ in calls.count += 1; return .refused(.offline) }
            #expect(await state.agentDraftAcceptance(for: other, item: item) == .refused(.offline))
            #expect(calls.count == 2)

            // A live lock does block, and is cached.
            let third = AgentDraft(id: "smd_u", assignmentID: "x", kind: .text, body: "a")
            state.agentRulesFetchForTesting = { _, _ in calls.count += 1; return .rules(.init(submissionTypes: ["online_upload"], lockedForUser: true)) }
            #expect(await state.agentDraftAcceptance(for: third, item: item) == .known(.locked))
            #expect(state.agentDraftAcceptanceByDraftID["smd_u"] == .locked)
            // forceLive asks again even with a cached answer.
            state.agentRulesFetchForTesting = { _, _ in calls.count += 1; return .rules(.init(submissionTypes: ["online_text_entry"])) }
            #expect(await state.agentDraftAcceptance(for: third, item: item, forceLive: true)
                    == .known(.online(text: true, url: false, file: false, extensions: [])))
            state.agentRulesFetchForTesting = nil
        }
    }

    @Test("a draft on the linked half of a pair completes the card the student sees")
    func linkedItemCompletes() async throws {
        try await withCleanKeys {
            let state = try makeState()
            let card = Assignment(source: .canvas, sourceID: "event-assignment-77", kind: .assignment,
                                  course: "PHYS 0151", title: "Problem Set 8", dueAt: nil, url: nil,
                                  linkedID: "gradescope:ps8")
            state.assignments = [card]
            #expect(state.shownAssignment(forItemID: card.id)?.id == card.id)
            #expect(state.shownAssignment(forItemID: "gradescope:ps8")?.id == card.id)
            #expect(state.shownAssignment(forItemID: "nothing") == nil)
            state.completeAfterAgentSubmit(itemID: "gradescope:ps8")
            #expect(state.isCompleted(card))
        }
    }
}
