import Foundation
import LowHangingFruitKit
#if canImport(UserNotifications)
import UserNotifications
#endif

// MARK: – The Sweeper's handoff to its notification extension
//
// After a force-quit nothing in the app runs, so nothing cancels an alarm for
// work handed in on the website. The server sends a content-free alert push
// shortly before each ring; the notification extension (`LHFSweeperCheck`, a
// separate process that links only the Kit) wakes for it, asks Canvas's
// planner, and cancels the alarms of work that is in. It can only do that with
// two things the app leaves behind: a manifest of the alarms (what they are,
// which Canvas assignment each belongs to) and a copy of the Canvas cookies.
// This file writes both, and folds back what the extension found. Everything
// runs in the foreground, from the one place the Sweeper's server pass runs.
//
// The wrong version of the cookie copy is erasing it whenever the live jar
// reads empty. An empty live jar mid-renewal is a moment, not a verdict; a
// dead copy only ever makes the extension's read an unknown, and an unknown
// leaves the alarm armed. So an empty jar leaves the last good copy alone.

#if DEBUG
/// The `-LHFSweepProbe` alarm, remembered so every later manifest write keeps
/// listing it. Once per process.
@MainActor
private enum SweepProbeState {
    static var entry: SweepManifest.Entry?
    static var attempted = false
}
#endif

extension AppState {
    /// Writes the manifest for the current plan and refreshes the cookie copy,
    /// but only while a wake push can reach this phone (`wakeReachable` is the
    /// wake's own gate: Penn, backend, token, flag, Sweeper and reminders on).
    /// Otherwise nothing could ever use the copy, so both it and the manifest
    /// are deleted: a second copy of a bearer credential is not kept without a
    /// consumer.
    ///
    /// - Parameters:
    ///   - directory: where the manifest goes; nil under a test runner by
    ///     default, so a test run never reaches the real container.
    ///   - canvasConnected: a test seam. Nil asks the real state, which a test
    ///     runner never does (that reads the shared Keychain).
    func writeSweepHandoff(plan: [PlannedAlarm], wakeReachable: Bool,
                           directory: URL? = SweepFiles.defaultDirectory(),
                           canvasConnected: Bool? = nil, now: Date = Date()) async {
        guard wakeReachable else {
            SweepFiles.deleteManifest(in: directory)
            SweepCookieMirror.deleteAll()
            return
        }
        guard !isUsingFixtureData else { return }
        let connected = canvasConnected ?? (SharedDefaults.isTestRunner ? false : (isCanvasConnected || hasCanvasCredentials))
        guard connected else { return }

        let ledger: [Assignment] = assignmentStore.map {
            $0.assignments(source: .canvas) + $0.assignments(source: .canvasModules)
                + $0.assignments(source: .gradescope)
        } ?? (canvasItems + moduleReadingItems + gradescopeItems)
        var byID: [String: Assignment] = [:]
        for row in ledger where byID[row.id] == nil { byID[row.id] = row }

        // A Gradescope-only row has no Canvas id of its own; its Canvas twin
        // (`linkedID`) does, and a planner read is keyed by that.
        func canvasID(for itemID: String) -> String? {
            guard let row = byID[itemID] else { return nil }
            if let id = row.canvasAssignmentID { return id }
            if let twin = row.linkedID.flatMap({ byID[$0] }) { return twin.canvasAssignmentID }
            return nil
        }

        var entries = plan.map { planned -> SweepManifest.Entry in
            let ids = SubmissionObservation.ids(forAssignmentID: planned.assignmentID, due: planned.dueAt)
            let alarms = ids.alarmIDs.union([planned.id]).sorted { $0.uuidString < $1.uuidString }
            return SweepManifest.Entry(
                itemID: planned.assignmentID, canvasAssignmentID: canvasID(for: planned.assignmentID),
                title: planned.title, fireDate: planned.fireDate, alarmIDs: alarms, requestIDs: ids.requestIDs)
        }

        #if DEBUG
        await armSweepProbeIfAsked(now: now)
        if let probe = SweepProbeState.entry { entries.append(probe) }
        #endif

        SweepFiles.saveManifest(
            SweepManifest(writtenAt: now, canvasBaseURL: canvasBaseURL, entries: entries), in: directory)

        // The live-merged jar, the same one the last-hour poll asks with (see
        // `fetchPlannerWindowForPoll`): the persisted store applies the
        // 24-hour clock rule and reads empty a day after the last save while
        // WebKit still holds a live session.
        guard !SharedDefaults.isTestRunner else { return }
        let cookies = await AutoSyncCoordinator.canvasCookies(forHost: canvasInstallation.host)
        if !cookies.isEmpty {
            SweepCookieMirror.save(cookies: cookies, host: canvasInstallation.host)
        }
    }

    /// Takes in what the extension found handed in while the app was not
    /// running, through the planner applier, so the student's overrides, the
    /// twin rules and the cancel all run their one existing path. The ledger
    /// keeps a single writer: the extension only appends to the inbox.
    func foldSweepInbox(directory: URL? = SweepFiles.defaultDirectory(),
                        clearDelivered: Bool = !SharedDefaults.isTestRunner, now: Date = Date()) {
        #if canImport(UserNotifications)
        if clearDelivered {
            // The "checking your next deadline" and "not turned in yet" lines
            // never add to the inbox, so this runs on every pass, not only
            // when something was found. `UNUserNotificationCenter.current()`
            // traps inside `swift test`, hence the flag.
            Task {
                let center = UNUserNotificationCenter.current()
                let delivered = await center.deliveredNotifications()
                let ids = delivered.filter { $0.request.content.threadIdentifier == "sweeper" }
                    .map(\.request.identifier)
                if !ids.isEmpty { center.removeDeliveredNotifications(withIdentifiers: ids) }
            }
        }
        #endif

        // `applyPlannerWindow` does nothing under these two conditions, so
        // draining first would throw the extension's findings away. Leave the
        // file for a pass that can use it.
        guard FeatureFlags.structuredCanvasSources, !isUsingFixtureData else { return }
        let inbox = SweepFiles.drainInbox(in: directory)
        guard !inbox.records.isEmpty else { return }

        var seen = Set<String>()
        let items: [CanvasPlannerItem] = inbox.records.compactMap { record in
            guard let id = record.canvasAssignmentID, seen.insert(id).inserted else { return nil }
            return CanvasPlannerItem(plannableType: "assignment", plannableID: id,
                                     submitted: true, assignmentID: id)
        }
        if !items.isEmpty {
            applyPlannerWindow(PlannerWindowResult(items: items, completed: true), now: now)
        }
    }

    #if DEBUG
    /// `-LHFSweepProbe`: one real AlarmKit alarm 16 minutes out, listed in the
    /// manifest as a probe, so the extension's cancel path can be watched on a
    /// phone without handing in real work. The app's own reconcile may remove
    /// an alarm that is not in its plan; if so, re-launch with the flag.
    private func armSweepProbeIfAsked(now: Date) async {
        guard !SharedDefaults.isTestRunner, !SweepProbeState.attempted,
              ProcessInfo.processInfo.arguments.contains("-LHFSweepProbe") else { return }
        SweepProbeState.attempted = true
        #if canImport(AlarmKit) && os(iOS)
        guard #available(iOS 26.0, *) else { return }
        let alarmID = UUID(uuidString: "5EEB0000-0000-4000-8000-000000000001")!
        let fire = now.addingTimeInterval(16 * 60)
        let planned = PlannedAlarm(id: alarmID, assignmentID: "sweep-probe", fireDate: fire, title: "sweep probe",
                                   course: "probe", dueAt: fire.addingTimeInterval(60), link: nil)
        do {
            try await BerserkAlarmScheduler.shared.schedule(planned)
        } catch {
            print("LHF-SWEEP probe failed \(String(describing: error))")
            return
        }
        SweepProbeState.entry = SweepManifest.Entry(
            itemID: "sweep-probe", canvasAssignmentID: nil, title: "sweep probe", fireDate: fire,
            alarmIDs: [alarmID], requestIDs: [], probe: true)
        print("LHF-SWEEP probe armed \(ISO8601DateFormatter().string(from: fire))")
        #endif
    }
    #endif
}
