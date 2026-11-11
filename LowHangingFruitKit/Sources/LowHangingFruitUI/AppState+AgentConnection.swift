import Foundation
import LowHangingFruitKit

/// A `smooth://link` request waiting to be looked up; `Identifiable` so a
/// `.task(id:)` can key on it.
struct PendingAgentLink: Identifiable {
    let id = UUID()
    let request: AgentLinkRequest
}

/// A looked-up request on its way to the approve sheet.
struct AgentLookupPresentation: Identifiable {
    let id = UUID()
    let lookup: AgentPendingLookup
}

/// The phone's side of the agent connection
/// (docs/AGENT_CONNECTION_PLAN_V11_2026-11-07.md): approve a sign-in, keep the
/// connection list, and upload the closed-field snapshot while the student has
/// it switched on. Every failure is swallowed or reduced to a Bool; nothing
/// here logs a pending id, a code or a snapshot.
extension AppState {
    static let agentSnapshotThrottle: TimeInterval = 600

    /// Same conditions as `canSyncWithLaptop`, behind the feature's kill switch.
    var canUseAgentConnection: Bool {
        FeatureFlags.agentConnection && canSyncWithLaptop
    }

    // MARK: Opt-in

    func setAgentConnectionEnabled(_ on: Bool) async {
        UserDefaults.lhf.set(on, forKey: SharedDefaults.agentConnectionEnabledKey)
        agentConnectionEnabled = on
        if on {
            await agentSnapshotPass(force: true)
        } else {
            if let backend = BackendServices.client {
                // Also revokes every connection server-side.
                _ = try? await AgentConnectionClient(client: backend).deleteSnapshot()
            }
            hasAgentConnections = false
            clearAgentDraftsLocally()
        }
    }

    // MARK: Approving

    func pendingAgentLink(from url: URL) -> AgentLinkRequest? {
        guard canUseAgentConnection else { return nil }
        return AgentLinkRequest(url: url)
    }

    var agentAPI: AgentConnectionClient? {
        guard canUseAgentConnection, let backend = BackendServices.client else { return nil }
        return AgentConnectionClient(client: backend)
    }

    func lookupAgentLink(_ request: AgentLinkRequest) async -> AgentPendingLookup? {
        guard let api = agentAPI else { return nil }
        return try? await api.lookup(pendingID: request.pendingID)
    }

    func lookupAgentCode(_ typed: String) async -> AgentPendingLookup? {
        guard let api = agentAPI, let code = AgentUserCode.normalize(typed) else { return nil }
        return try? await api.lookup(typedCode: code)
    }

    /// True when the picked number matched. False can mean the server denied
    /// the request (wrong number) or the call failed.
    func approveAgentLink(id: String, picked: Int) async -> Bool {
        guard let api = agentAPI, let approved = try? await api.approve(pendingID: id, picked: picked),
              approved else { return false }
        if !agentConnectionEnabled {
            UserDefaults.lhf.set(true, forKey: SharedDefaults.agentConnectionEnabledKey)
            agentConnectionEnabled = true
        }
        // The server has a list the moment the agent connects.
        await agentSnapshotPass(force: true)
        _ = await refreshAgentConnections()
        return true
    }

    func denyAgentLink(id: String) async {
        guard let api = agentAPI else { return }
        try? await api.deny(pendingID: id)
    }

    func refreshAgentConnections() async -> [AgentConnectionSummary] {
        guard let api = agentAPI, let list = try? await api.listConnections() else { return [] }
        hasAgentConnections = !list.isEmpty
        // Only a list that answered: a failed call must not read as "every
        // connection is new" on the next one.
        noteAgentConnections(list)
        return list
    }

    func revokeAgentConnection(id: String) async -> Bool {
        guard let api = agentAPI, let revoked = try? await api.revoke(connectionID: id) else { return false }
        _ = await refreshAgentConnections()
        return revoked
    }

    // MARK: The pass

    /// One snapshot upload. A silent no-op unless the feature is available and
    /// switched on, in a background wake, inside the throttle (unless forced),
    /// or while another pass runs.
    func agentSnapshotPass(force: Bool = false, now: Date = Date()) async {
        guard AgentPassRules.shouldStart(
                  isAvailable: canUseAgentConnection, isEnabled: agentConnectionEnabled,
                  isFixtureData: isUsingFixtureData, isBackground: renewalContext == .background,
                  isRunning: isAgentSnapshotRunning, lastRun: lastAgentSnapshotAt, now: now,
                  throttle: Self.agentSnapshotThrottle, force: force),
              let api = agentAPI
        else { return }

        isAgentSnapshotRunning = true
        lastAgentSnapshotAt = now
        defer { isAgentSnapshotRunning = false }

        let snapshot = buildAgentSnapshot(now: now)
        guard AgentSnapshotBuilder.byteSize(snapshot) <= AgentSnapshotBuilder.maxBytes else { return }
        // The student may have switched it off while this was building.
        guard agentConnectionEnabled else { return }
        _ = try? await api.putSnapshot(snapshot)
        // The student switched it off (or disconnected Canvas) while the put
        // was in flight. The opt-out's `delete` may have reached the server
        // first, and a put replaces the row whole, so the work list would be
        // back on the server after the student was told it was deleted. The
        // agents are revoked either way; the list must go too. The wrong fix
        // is making the opt-out wait for this pass: the switch must answer at
        // once, and a pass can be slow.
        if !agentConnectionEnabled { _ = try? await api.deleteSnapshot() }
    }

    func buildAgentSnapshot(now: Date) -> AgentSnapshot {
        var byID: [String: Assignment] = [:]
        for a in assignments + laterAssignments + assessments + mergedCoursework where byID[a.id] == nil {
            byID[a.id] = a
        }
        for task in manualAssignments {
            let a = task.asAssignment()
            if byID[a.id] == nil { byID[a.id] = a }
        }

        let courses = canvasCourseIDsByCode
            .filter { isCourseSelected($0.key) }
            .sorted { $0.key < $1.key }
            .map { AgentSnapshot.Course(courseID: $0.value, code: $0.key, name: courseDisplayName($0.key)) }

        var manual: [AgentSnapshot.ManualItem] = manualAssignments.map {
            .init(id: $0.id.uuidString, course: $0.course, title: $0.title, dueAt: $0.dueAt, repeatsWeekly: false)
        }
        for task in recurringTasks {
            manual.append(.init(
                id: task.id.uuidString, course: task.course, title: task.title,
                dueAt: task.upcomingAssignments(from: now, weeksAhead: 2).first?.dueAt, repeatsWeekly: true))
        }

        return AgentSnapshotBuilder.build(
            courses: courses, work: syncWorkList(),
            noSubmission: { id in byID[id].map { self.requiresNoSubmission($0) } ?? false },
            manual: manual,
            courseIDByCode: { [codes = canvasCourseIDsByCode] in codes[$0] })
    }
}

/// When an agent pass (the snapshot upload, the drafts poll) may start. Pure,
/// so the gates and the throttle are tests with a fixed clock rather than a
/// reading of two guard statements that had drifted apart (the snapshot
/// pass leaned on `canUseAgentConnection` for preview and demo, the drafts
/// pass checked it twice). Every gate is a "never": a feature that is not
/// available (not Penn, no backend, onboarding), the opt-in off, preview or
/// demo data, a background wake (CLAUDE.md, Traps: background wakes have
/// never run real work), or a pass already in flight. `force` skips only the
/// throttle. A clock that moved back (`now < lastRun`) does not freeze the
/// pass until it catches up.
enum AgentPassRules {
    nonisolated static func shouldStart(isAvailable: Bool, isEnabled: Bool, isFixtureData: Bool,
                                        isBackground: Bool, isRunning: Bool, lastRun: Date?,
                                        now: Date, throttle: TimeInterval, force: Bool) -> Bool {
        guard isAvailable, isEnabled, !isFixtureData, !isBackground, !isRunning else { return false }
        if force { return true }
        guard let lastRun else { return true }
        return now < lastRun || now.timeIntervalSince(lastRun) >= throttle
    }
}
