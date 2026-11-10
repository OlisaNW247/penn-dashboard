import Foundation
import LowHangingFruitKit

/// What a dashboard card shows of a draft: the chip, the preview, and which
/// one button the opened card offers. Snapshotted into `DashItem` at reload,
/// like `fact`, so the card holds no `AppState`.
struct AgentDraftDisplay: Equatable {
    let draftID: String
    let agentName: String
    let preview: String?
    /// A submission went out and nobody knows whether Canvas took it: the
    /// card offers "check canvas" instead of "review and submit".
    let checkCanvas: Bool
    let isUnseen: Bool
}

/// Phase 3 and 4 of the agent connection on the phone
/// (docs/AGENT_CONNECTION_PLAN_V11_2026-11-07.md): drafts arrive by polling
/// (decision 7), show on their card, are reviewed in a sheet and are either
/// declined or submitted to Canvas from the phone with the student's own
/// session. The agent never submits; the server never talks to Canvas.
///
/// The poll runs beside `agentSnapshotPass` under the same gates (Penn, a
/// backend, the opt-in on, never in a background wake) and at most every five
/// minutes. Every failure is silent: a draft that did not arrive this pass
/// arrives on the next one.
extension AppState {
    static let agentDraftsThrottle: TimeInterval = 300

    // MARK: The pass

    func agentDraftsPass(force: Bool = false, now: Date = Date()) async {
        guard canUseAgentConnection, agentConnectionEnabled, !isUsingFixtureData,
              renewalContext != .background, !isAgentDraftsRunning,
              force || lastAgentDraftsAt.map({ now < $0 || now.timeIntervalSince($0) >= Self.agentDraftsThrottle }) ?? true,
              let api = agentAPI
        else { return }
        isAgentDraftsRunning = true
        lastAgentDraftsAt = now
        defer { isAgentDraftsRunning = false }

        // Connections first, so a sign-in that finished since the last pass
        // says so on the dashboard ("connected to claude").
        _ = await refreshAgentConnections()

        guard let list = try? await api.listDrafts(), agentConnectionEnabled else { return }

        // Reports the server never acknowledged (a submit whose `draft` call
        // failed): sent again here. A report, never a submission.
        var acknowledged = Set<String>()
        for draft in list {
            guard let record = agentSubmitAttempts.record(for: draft.id),
                  let decision = AgentDraftSubmitter.pendingReport(for: record) else { continue }
            if await reportAgentDraft(draft.id, decision, api: api) {
                agentSubmitAttempts.markReported(draftID: draft.id)
                acknowledged.insert(draft.id)
            }
        }
        applyAgentDrafts(list.filter { !acknowledged.contains($0.id) })
    }

    /// Takes a fresh list: replaces the drafts, the cache, and plans the
    /// notifications. Split from the pass so it is testable without a network.
    func applyAgentDrafts(_ list: [AgentDraft]) {
        let open = list.filter { $0.status.isOpen }
        agentDrafts = open
        AgentDraftCache.save(open, to: .lhf)

        let already = UserDefaults.lhf.stringArray(forKey: AgentDraftNotices.notifiedKey) ?? []
        let titles = Dictionary(
            (assignments + laterAssignments + assessments).map { ($0.id, $0.title) },
            uniquingKeysWith: { a, _ in a })
        let planned = AgentDraftNotices.plan(drafts: open, alreadyNotified: already) { titles[$0] }
        UserDefaults.lhf.set(planned.remembered, forKey: AgentDraftNotices.notifiedKey)
        pendingAgentDraftNotices += planned.notices.map { (title: $0.title, body: $0.body) }
    }

    // MARK: Reading

    /// The draft a card shows: the newest open one for that item that the
    /// phone has not already sent or failed. More than one draft per item
    /// shows only the newest (Known gaps).
    func agentDraft(forItemID itemID: String) -> AgentDraft? {
        agentDrafts.first { draft in
            guard draft.assignmentID == itemID, draft.status.isOpen else { return false }
            switch agentSubmitAttempts.record(for: draft.id)?.outcome {
            case .submitted?, .failed?: return false
            case .indeterminate?, nil: return true
            }
        }
    }

    func agentDraftDisplay(forItemID itemID: String) -> AgentDraftDisplay? {
        guard !isUsingFixtureData, let draft = agentDraft(forItemID: itemID) else { return nil }
        let record = agentSubmitAttempts.record(for: draft.id)
        return AgentDraftDisplay(
            draftID: draft.id, agentName: draft.agentName.lowercased(), preview: draft.preview(),
            checkCanvas: record != nil, isUnseen: draft.status == .proposed)
    }

    /// The snapshot's view of an item: its Canvas course and assignment ids.
    /// Built the way the upload builds it, so the ids the phone submits to are
    /// the ids the agent saw.
    func agentSnapshotItem(for itemID: String, now: Date = Date()) -> AgentSnapshot.WorkItem? {
        buildAgentSnapshot(now: now).workList.first { $0.id == itemID }
    }

    // MARK: Decisions

    /// The first open of its card. Fire and forget; a failure leaves it
    /// `proposed`, and the next open asks again.
    func markAgentDraftSeen(_ draftID: String) async {
        guard let index = agentDrafts.firstIndex(where: { $0.id == draftID }),
              agentDrafts[index].status == .proposed, let api = agentAPI else { return }
        if await reportAgentDraft(draftID, .seen, api: api) {
            if let i = agentDrafts.firstIndex(where: { $0.id == draftID }) { agentDrafts[i].status = .seen }
            AgentDraftCache.save(agentDrafts, to: .lhf)
        }
    }

    /// True when the server took the decline (or had already decided it).
    func declineAgentDraft(_ draftID: String) async -> Bool {
        guard let api = agentAPI else { return false }
        guard agentSubmitAttempts.record(for: draftID) == nil else { return false }
        guard await reportAgentDraft(draftID, .declined, api: api) else { return false }
        dropAgentDraft(draftID)
        return true
    }

    /// Sends one draft to Canvas. See `AgentDraftSubmitter` for the order and
    /// the never-twice rule; this supplies the pieces from the live app.
    func submitAgentDraft(_ draftID: String, pdf: RenderedDraftPDF? = nil) async -> AgentSubmitResult {
        guard !isUsingFixtureData, let draft = agentDrafts.first(where: { $0.id == draftID }) else {
            return .refused(.missingIDs)
        }
        let item = agentSnapshotItem(for: draft.assignmentID)
        let cookies = await AutoSyncCoordinator.canvasCookies(forHost: canvasInstallation.host)
        let client = CanvasSubmissionClient(session: .shared, baseURL: canvasBaseURL, cookies: cookies)
        let api = agentAPI
        let result = await AgentDraftSubmitter.run(
            draft: draft, item: item, store: agentSubmitAttempts,
            loadFile: { await self.loadAgentDraftFile(draft) },
            submit: { courseID, assignmentID, payload, before in
                await client.submit(courseID: courseID, assignmentID: assignmentID, payload: payload, beforeFirstPost: before)
            },
            report: { decision in
                guard let api else { return false }
                return await self.reportAgentDraft(draft.id, decision, api: api)
            },
            pdf: pdf)
        switch result {
        case .submitted, .failed: dropAgentDraft(draft.id)
        case .checkCanvas: agentDrafts = agentDrafts  // republish: the card now says "check canvas"
        case .refused, .fileUnavailable: break
        }
        return result
    }

    /// The draft's bytes from its signed URL; a URL past its two minutes is
    /// replaced by asking for the list again, once.
    func loadAgentDraftFile(_ draft: AgentDraft) async -> Data? {
        if let data = await Self.fetchSignedFile(draft.fileURL) { return data }
        guard let fresh = await refetchAgentDraft(draft.id) else { return nil }
        return await Self.fetchSignedFile(fresh.fileURL)
    }

    /// A fresh copy of one draft (a new signed URL), merged into the list.
    func refetchAgentDraft(_ draftID: String) async -> AgentDraft? {
        guard let api = agentAPI, let list = try? await api.listDrafts() else { return nil }
        let fresh = list.first { $0.id == draftID }
        if let fresh, let i = agentDrafts.firstIndex(where: { $0.id == draftID }) { agentDrafts[i] = fresh }
        return fresh
    }

    /// A signed Storage URL carries its own token: no app credential goes
    /// with it, and nothing is cached.
    nonisolated static func fetchSignedFile(_ raw: String?) async -> Data? {
        guard let raw, let url = URL(string: raw), url.scheme == "https" else { return nil }
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        request.cachePolicy = .reloadIgnoringLocalCacheData
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, (200..<300).contains(http.statusCode),
              !data.isEmpty
        else { return nil }
        return data
    }

    // MARK: Plumbing

    /// True when the server applied the decision, or answered that the draft
    /// already left an open state (409) or is gone (404): either way there is
    /// nothing more to tell it.
    func reportAgentDraft(_ draftID: String, _ decision: AgentDraftDecision, api: AgentConnectionClient) async -> Bool {
        do {
            try await api.decide(draftID: draftID, decision)
            return true
        } catch AgentConnectionError.alreadyDecided, AgentConnectionError.notFound {
            return true
        } catch {
            return false
        }
    }

    func dropAgentDraft(_ draftID: String) {
        agentDrafts.removeAll { $0.id == draftID }
        AgentDraftCache.save(agentDrafts, to: .lhf)
    }

    /// Opt-out and Canvas disconnect: the server deletes the drafts at the
    /// same moment, so the phone forgets them, what it announced, and the
    /// attempt records that could only ever guard those drafts.
    func clearAgentDraftsLocally() {
        agentDrafts = []
        pendingAgentDraftNotices = []
        lastAgentDraftsAt = nil
        agentConnectionBanner = nil
        UserDefaults.lhf.removeObject(forKey: AgentDraftCache.key)
        UserDefaults.lhf.removeObject(forKey: AgentDraftNotices.notifiedKey)
        UserDefaults.lhf.removeObject(forKey: Self.agentKnownConnectionIDsKey)
        agentSubmitAttempts.removeAll()
    }

    // MARK: Connected banner

    static let agentKnownConnectionIDsKey = "agentKnownConnectionIDsV1"

    /// Compares a fresh connection list with the ids the phone has seen. A
    /// new one raises the dashboard line; the very first list on an install
    /// only records, so a connection made before this build says nothing.
    func noteAgentConnections(_ list: [AgentConnectionSummary]) {
        let ids = list.map(\.id)
        defer { UserDefaults.lhf.set(ids, forKey: Self.agentKnownConnectionIDsKey) }
        guard let known = UserDefaults.lhf.stringArray(forKey: Self.agentKnownConnectionIDsKey) else { return }
        let knownSet = Set(known)
        if let fresh = list.first(where: { !knownSet.contains($0.id) }) {
            agentConnectionBanner = AgentConnectionCopy.connectedBanner(fresh.clientName)
        }
    }
}
