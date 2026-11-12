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

/// What the review sheet learned about the assignment when it opened.
enum AgentAcceptanceLookup: Equatable {
    case known(CanvasAcceptance)
    /// The early read could not run (offline, the session, Canvas erred):
    /// the sheet says so in one line and the submit's own preflight decides.
    case refused(CanvasSubmissionClient.Refusal)
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
        guard AgentPassRules.shouldStart(
                  isAvailable: canUseAgentConnection, isEnabled: agentConnectionEnabled,
                  isFixtureData: isUsingFixtureData, isBackground: renewalContext == .background,
                  isRunning: isAgentDraftsRunning, lastRun: lastAgentDraftsAt, now: now,
                  throttle: Self.agentDraftsThrottle, force: force),
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
        // The reports above awaited the network; an opt-out or a Canvas
        // disconnect in that window cleared the drafts, the cache and the
        // notice memory, and applying this list now would put back drafts
        // the server has just deleted (and announce them). Checked again
        // here, not only after `listDrafts`.
        guard agentConnectionEnabled else { return }
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
        var fixture = isUsingFixtureData
        #if DEBUG
        if debugAgentDemo != nil { fixture = false }
        #endif
        guard !fixture, let draft = agentDraft(forItemID: itemID) else { return nil }
        let record = agentSubmitAttempts.record(for: draft.id)
        return AgentDraftDisplay(
            draftID: draft.id, agentName: draft.agentName.lowercased(), preview: draft.preview(maxLines: 2, maxCharacters: 160),
            checkCanvas: record != nil, isUnseen: draft.status == .proposed)
    }

    /// The snapshot's view of an item: its Canvas course and assignment ids.
    /// Built the way the upload builds it, so the ids the phone submits to are
    /// the ids the agent saw.
    func agentSnapshotItem(for itemID: String, now: Date = Date()) -> AgentSnapshot.WorkItem? {
        buildAgentSnapshot(now: now).workList.first { $0.id == itemID }
    }

    // MARK: What Canvas takes

    /// What Canvas takes for this draft's assignment, before the student
    /// decides. Once per draft (cached in memory by draft id). In order: an
    /// item the phone can never send (no Canvas ids, a quiz, Gradescope,
    /// nothing to submit) is "not online" without asking anyone; then what
    /// the last structured-sources run read off the assignments list; then
    /// the submit's own preflight GET, run early. That GET is the same
    /// request the submit already makes first, so it adds no network call
    /// to docs/PRIVACY.md. The submit still runs its own preflight: this
    /// answer shapes the sheet, it never authorises a POST.
    func agentDraftAcceptance(for draft: AgentDraft, item: AgentSnapshot.WorkItem?,
                              forceLive: Bool = false) async -> AgentAcceptanceLookup {
        #if DEBUG
        if let demo = debugAgentDemo { return demo.lookup(for: draft) }
        #endif
        if draft.kind != .unknown, AgentDraftSubmitter.unsupportedReason(draft: draft, item: item) != nil {
            return .known(.notOnline)
        }
        if !forceLive, let cached = agentDraftAcceptanceByDraftID[draft.id] { return .known(cached) }
        guard let item, let courseID = item.canvasCourseID, let assignmentID = item.canvasAssignmentID else {
            return .known(.notOnline)
        }
        // The list's answer may be hours old. It is used as it stands only
        // when it lets the student send; an answer that would block (locked,
        // nothing online) is confirmed with one live GET first, and only the
        // live answer blocks. If that GET cannot be had, nothing blocks: the
        // sheet offers the draft's own kind and the submit's preflight decides.
        if !forceLive, let rules = canvasSubmissionRulesByAssignmentID[assignmentID] {
            let listed = CanvasAcceptance.derive(rules)
            switch listed {
            case .online:
                agentDraftAcceptanceByDraftID[draft.id] = listed
                return .known(listed)
            case .locked, .notOnline:
                break
            }
        }
        guard agentRulesFetchForTesting != nil || !isUsingFixtureData else { return .refused(.preflightFailed) }
        let answer: CanvasSubmissionClient.RulesResult
        if let fetch = agentRulesFetchForTesting {
            answer = await fetch(courseID, assignmentID)
        } else {
            let cookies = await AutoSyncCoordinator.canvasCookies(forHost: canvasInstallation.host)
            let client = CanvasSubmissionClient(session: .shared, baseURL: canvasBaseURL, cookies: cookies)
            answer = await client.fetchRules(courseID: courseID, assignmentID: assignmentID)
        }
        switch answer {
        case .rules(let rules):
            canvasSubmissionRulesByAssignmentID[assignmentID] = rules
            let acceptance = CanvasAcceptance.derive(rules)
            agentDraftAcceptanceByDraftID[draft.id] = acceptance
            return .known(acceptance)
        case .refused(let refusal):
            return .refused(refusal)
        }
    }

    /// After Canvas took a draft: the card the student sees goes to prev, as
    /// a swipe would (`shownAssignment(forItemID:)` finds it through a twin
    /// or linked id), and says "submitted by you · drafted by claude" there.
    /// Canvas's own submitted state agrees on the next refresh.
    func completeAfterAgentSubmit(itemID: String) {
        guard let assignment = shownAssignment(forItemID: itemID) else { return }
        markCompleted(assignment)
    }

    /// prev's "submitted by you · drafted by claude": item id to the
    /// agent's name, for every draft the phone sent and Canvas took. Read
    /// once per dashboard rebuild (the store is a small file).
    func agentSubmittedNamesByItemID() -> [String: String] {
        guard !isUsingFixtureData else { return [:] }
        var names: [String: String] = [:]
        for record in agentSubmitAttempts.all() where record.outcome == .submitted {
            let name = (record.agentName ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            names[record.assignmentID] = (name.isEmpty ? "claude" : name).lowercased()
        }
        return names
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
        #if DEBUG
        if let demo = debugAgentDemo { return demo.initialOutcome ?? .submitted(verified: true) }
        #endif
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
        case .submitted:
            dropAgentDraft(draft.id)
            completeAfterAgentSubmit(itemID: draft.assignmentID)
        case .failed:
            dropAgentDraft(draft.id)
        case .checkCanvas:
            agentDrafts = agentDrafts  // republish: the card now says "check canvas"
        case .refused(.locked):
            agentDraftAcceptanceByDraftID[draft.id] = .locked
        case .refused(.unsupportedType):
            // The early answer was out of date: ask again next time.
            agentDraftAcceptanceByDraftID[draft.id] = nil
        case .refused, .fileUnavailable:
            break
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
        agentDraftAcceptanceByDraftID = [:]
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
