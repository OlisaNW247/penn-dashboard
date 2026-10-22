import Foundation
import LowHangingFruitKit

// MARK: – Pairing and encrypted sync with the student's laptop
//
// docs/CHROME_EXTENSION.md ("Pairing", "Phone sync, end to end encrypted") is
// the contract; `Sync/*` in the Kit is the pure layer (snapshot, merge, apply
// plan, envelope), `DeviceSyncClient` and `SyncKeyStore` are the I/O. This file
// is only the wiring between them and `AppState`. Written without a compiler
// (CLAUDE.md, Traps: blind commits), so it keeps to calls whose definitions
// were read, and keeps every decision that can be pure in `DeviceSyncRules`.
//
// One pass (`deviceSyncPass`): read every other device's blob, merge once over
// all of them, apply what a remote won through the same stores a tap writes,
// then seal and put this phone's own snapshot, rebuilt after applying.
//
// **Reminders, the widget and the Sweeper follow without code here.** Every
// applied action ends in `rebuildDashboardItems()` (directly, or through
// `removeManualAssignment` and the other existing mutators), which republishes
// the widget snapshot (`publishWidgetSnapshot`) and the announcement badge, and
// republishes `assignments`/`laterAssignments`/`assessments`. `DashboardViewModel`
// reloads from those publishes, and `ContentView.refresh()`, where the pass
// runs, calls `vm.reload` and `scheduler.reschedule(from: vm.items)` straight
// after it, which is where due-date reminders and the Smooth Sweeper
// (`BerserkAlarmPlan`, planned inside `reschedule`) are made or cancelled from
// the finished state of each item. A pass at launch (`RootCore`) has no
// reschedule of its own; the next foreground refresh does it.

/// Counts how deep a "this change came from another device" section is, so the
/// tap hooks (`AppState.recordSyncChange`) can tell a student's tap from the
/// sync's own writes.
///
/// A class with `run`, not a flag set and cleared by hand: the clearing is a
/// `defer`, so an early return or a throw cannot leave the phone believing it
/// is applying forever (after which no tap would ever be recorded and the
/// laptop would never hear of anything). A class rather than a struct property
/// because `gate.run { self.something() }` on a struct stored in `self` would
/// be an overlapping access to it.
final class RemoteApplyGate {
    private(set) var depth = 0
    var isApplying: Bool { depth > 0 }

    func run<T>(_ body: () throws -> T) rethrows -> T {
        depth += 1
        defer { depth -= 1 }
        return try body()
    }
}

/// The yes/no decisions of device sync, pure and `nonisolated` so a test can
/// walk them without an `AppState` (CLAUDE.md, the `decidedText` trap).
enum DeviceSyncRules {
    /// At most one pass per this long. The refresh loop runs every 5 minutes
    /// and every foreground activation runs it again, so a student flicking
    /// between apps would otherwise put and get on every flick.
    nonisolated static let minimumInterval: TimeInterval = 120

    /// Whether this install may talk to the device-sync functions at all: a
    /// real account (not preview or demo data), past onboarding, at Penn (the
    /// backend's shared tables are Penn's, `AppState+CourseKnowledge`), with a
    /// backend configured.
    nonisolated static func isAvailable(isFixtureData: Bool, isPenn: Bool,
                                        hasBackend: Bool, needsOnboarding: Bool) -> Bool {
        !isFixtureData && isPenn && hasBackend && !needsOnboarding
    }

    /// Whether a pass starts now. `force` (right after pairing) skips only the
    /// throttle: never a missing key, never a pass already in flight, never a
    /// background wake (CLAUDE.md, Traps: background wakes crash and have never
    /// run real work, so sync is foreground only). A clock that moved back
    /// (`now < lastRun`) does not freeze sync until it catches up.
    nonisolated static func shouldRun(isAvailable: Bool, hasKey: Bool, isRunning: Bool,
                                      isBackground: Bool, lastRun: Date?, now: Date,
                                      force: Bool = false) -> Bool {
        guard isAvailable, hasKey, !isRunning, !isBackground else { return false }
        if force { return true }
        guard let lastRun else { return true }
        return now < lastRun || now.timeIntervalSince(lastRun) >= minimumInterval
    }

    /// Whether a student's tap is stamped in `SyncChangeLog`. Not while a
    /// remote plan is being applied (the remote's own time is recorded after,
    /// from `plan.adoptedTimes`), and not on fixture data, whose ids mean
    /// nothing on a real install.
    nonisolated static func shouldRecord(isApplyingRemote: Bool, isFixtureData: Bool) -> Bool {
        !isApplyingRemote && !isFixtureData
    }

    /// A manual task's id on the wire is the task's UUID string. Anything else
    /// is not ours to create, and its change time must not be recorded either:
    /// an id with a time and no live task reads as a tombstone
    /// (`SyncSnapshotBuilder.manualFacts`) and would bury the remote's task.
    nonisolated static func manualUUID(_ id: String) -> UUID? {
        UUID(uuidString: id)
    }
}

/// A pairing link waiting for the student's answer; `Identifiable` so a sheet
/// can be presented from it.
struct PendingPairing: Identifiable {
    let id = UUID()
    let link: PairingLink
}

extension AppState {
    // MARK: Availability

    /// Whether pairing and sync are on offer on this install. See
    /// `DeviceSyncRules.isAvailable`.
    var canSyncWithLaptop: Bool {
        DeviceSyncRules.isAvailable(
            isFixtureData: isUsingFixtureData,
            isPenn: canvasInstallation.id == CanvasInstallation.penn.id,
            hasBackend: BackendServices.client != nil,
            needsOnboarding: needsOnboarding
        )
    }

    /// The sheet's input from an opened URL, or nil: anything that is not a
    /// well-formed `smooth://pair` link (`PairingLink` is strict), and every
    /// install that cannot pair, is ignored without a word.
    func pendingPairing(from url: URL) -> PendingPairing? {
        guard canSyncWithLaptop, let link = PairingLink(url: url) else { return nil }
        return PendingPairing(link: link)
    }

    /// Re-reads whether the Keychain holds the key. A Keychain query, so it is
    /// called when Profile opens and by each pass, not per frame.
    func refreshPairedLaptop() {
        let paired = SyncKeyStore.load() != nil
        if hasPairedLaptop != paired { hasPairedLaptop = paired }
    }

    // MARK: Recording the student's taps

    /// Stamps `ids` as changed now. Called from the tap paths (`markCompleted`,
    /// `markActive`, `setDueDateEdit`, the manual and recurring add/remove); a
    /// no-op while a remote plan is applied, which is the whole point of the
    /// gate: otherwise the sync's own writes would be dated "now" and win every
    /// merge, and phone and laptop would take turns overwriting each other.
    func recordSyncChange(_ kind: SyncChangeLog.Kind, ids: [String], at date: Date = Date()) {
        guard DeviceSyncRules.shouldRecord(isApplyingRemote: remoteApplyGate.isApplying,
                                           isFixtureData: isUsingFixtureData),
              let log = syncChangeLog
        else { return }
        for id in ids { log.record(kind: kind, id: id, at: date) }
    }

    // MARK: Pair, unpair

    /// The sheet's "pair": the server links the laptop's user to this phone's
    /// (`claim`), then the key is kept in the Keychain, then one pass runs.
    /// False for any failure, and the sheet says "couldn't pair" without the
    /// reason. If the server linked but the Keychain refused, the link is
    /// undone, so the laptop does not believe it is paired with a phone that
    /// cannot read it.
    func pairLaptop(_ link: PairingLink) async -> Bool {
        guard canSyncWithLaptop, let client = BackendServices.client else { return false }
        let api = DeviceSyncClient(client: client)
        // One laptop at a time: the Keychain holds one key, so pairing a
        // second laptop over the first would leave the first linked on the
        // server and syncing with a key nothing reads any more, silently.
        // Unlinking every device first makes the old laptop see
        // `paired: false` on its next pass and let go of its key. The new
        // laptop is not linked until the claim below, so this cannot
        // unlink it.
        if SyncKeyStore.load() != nil {
            _ = try? await api.unpair()
            dropLaptopKey()
        }
        do {
            try await api.claim(code: link.code)
        } catch {
            return false
        }
        guard SyncKeyStore.save(link.key) else {
            _ = try? await api.unpair()
            return false
        }
        hasPairedLaptop = true
        await deviceSyncPass(force: true)
        return true
    }

    /// Profile's "unpair": the server first, so a failure leaves the key and
    /// the row in place for another try; a laptop that is already unlinked
    /// there (404) counts as done. Then the key goes. The change times stay:
    /// they are the student's own record of when each tap happened, and
    /// clearing them would date every record the Unix epoch at a re-pair,
    /// so the laptop's stale copy would win every one.
    func unpairLaptop() async -> Bool {
        if let client = BackendServices.client {
            do {
                try await DeviceSyncClient(client: client).unpair()
            } catch DeviceSyncError.pairingNotFound {
                // Already unlinked on the server (the laptop unpaired first).
            } catch {
                return false
            }
        }
        dropLaptopKey()
        return true
    }

    private func dropLaptopKey() {
        SyncKeyStore.delete()
        hasPairedLaptop = false
    }

    /// What disconnecting Canvas does locally, since `delete-account` removes
    /// the links server-side: the key, and the change times too, because the
    /// student is leaving altogether and nothing should outlive the account.
    func forgetPairedLaptopLocally() {
        SyncKeyStore.delete()
        syncChangeLog?.clear()
        hasPairedLaptop = false
    }

    // MARK: The pass

    /// One sync pass. A silent no-op without a key, on fixture data, in a
    /// background wake, inside the throttle, or while another pass is running.
    /// Every failure is swallowed: no banner, no notice (copy rule), and the
    /// next pass tries again from scratch, since nothing here is incremental.
    func deviceSyncPass(force: Bool = false, now: Date = Date()) async {
        let storedKey = SyncKeyStore.load()
        if hasPairedLaptop != (storedKey != nil) { hasPairedLaptop = storedKey != nil }
        guard DeviceSyncRules.shouldRun(
                isAvailable: canSyncWithLaptop, hasKey: storedKey != nil,
                isRunning: isDeviceSyncRunning, isBackground: renewalContext == .background,
                lastRun: lastDeviceSyncAt, now: now, force: force),
              let key = storedKey, let client = BackendServices.client, let log = syncChangeLog
        else { return }

        isDeviceSyncRunning = true
        lastDeviceSyncAt = now
        defer { isDeviceSyncRunning = false }

        do {
            let api = DeviceSyncClient(client: client)
            let deviceID = log.deviceID()
            let blobs = try await api.get()

            // The student may have unpaired while the request was out.
            guard SyncKeyStore.load() != nil else { return }

            // Everything from here to the `put` is synchronous: nothing the
            // student does can land between building the local snapshot and
            // applying the plan made from it.
            var remotes: [SyncSnapshot] = []
            for blob in blobs where blob.deviceId != deviceID {
                // A blob that does not open or parse (another key, a newer
                // format) is skipped; it never fails the pass.
                guard let plain = try? SyncSnapshotCrypto.open(blob.ciphertext, key: key),
                      let remote = try? SyncSnapshot.decode(plain),
                      remote.deviceId != deviceID
                else { continue }
                remotes.append(remote)
            }

            let local = syncSnapshot(log: log, deviceID: deviceID, now: Date())
            let merged = SyncSnapshotMerge.merge(local: local, remotes: remotes)
            let plan = SyncApplyPlan.plan(local: local, merged: merged.snapshot)
            applySyncPlan(plan, log: log)

            let own = plan.isEmpty ? local : syncSnapshot(log: log, deviceID: deviceID, now: Date())
            let sealed = try SyncSnapshotCrypto.seal(own.canonicalJSON(), key: key)
            try await api.put(deviceId: deviceID, ciphertext: sealed)
        } catch {
            // Silent by design. See the doc comment.
        }
    }

    // MARK: Building this phone's snapshot

    func syncSnapshot(log: SyncChangeLog, deviceID: String, now: Date) -> SyncSnapshot {
        let record = assignmentStore?.completionRecord()
        let completions = SyncSnapshotBuilder.completionFacts(
            doneIDs: record?.ids ?? completedAssignmentIDs,
            completedAt: record?.dates ?? completionDates,
            changeTimes: log.times(kind: .completion))
        let dueEdits = SyncSnapshotBuilder.dueEditFacts(
            edits: dueDateEdits,
            changeTimes: log.times(kind: .dueEdit))

        var live: [SyncSnapshotBuilder.ManualFact] = []
        for task in manualAssignments {
            live.append(SyncSnapshotBuilder.ManualFact(
                id: task.id.uuidString, title: task.title, course: task.course,
                dueAt: task.dueAt, kind: .assignment, repeatsWeekly: false))
        }
        for task in recurringTasks {
            // A recurring task is a rule; the snapshot carries its next
            // occurrence (nil once it has ended).
            let next = task.upcomingAssignments(from: now, weeksAhead: 2).first?.dueAt
            live.append(SyncSnapshotBuilder.ManualFact(
                id: task.id.uuidString, title: task.title, course: task.course,
                dueAt: next, kind: .assignment, repeatsWeekly: true))
        }
        let manual = SyncSnapshotBuilder.manualFacts(live: live, changeTimes: log.times(kind: .manual))

        return SyncSnapshotBuilder.build(
            deviceID: deviceID, now: now, completions: completions, dueEdits: dueEdits,
            manual: manual, workList: syncWorkList())
    }

    /// The merged dashboard as the phone shows it: what todo and all list
    /// (`assignments`, `laterAssignments`, `assessments`: announcement tasks and
    /// found exams included) and what prev lists, built the way
    /// `DashboardViewModel.reload` builds them, with the student's edited dates.
    func syncWorkList() -> [SyncSnapshot.WorkItem] {
        func item(_ a: Assignment, done: Bool) -> SyncSnapshot.WorkItem {
            SyncSnapshot.WorkItem(
                id: a.id, course: a.course, title: a.title, dueAt: effectiveDueDate(for: a),
                kind: a.kind, source: a.source.rawValue, url: a.url?.absoluteString, done: done)
        }
        let active = assignments + laterAssignments + assessments
        var seen = Set(active.map { $0.id })
        var out = active.map { item($0, done: false) }
        var pool = mergedCoursework
        for task in manualAssignments { pool.append(task.asAssignment()) }
        for a in pool where isCompleted(a) && !seen.contains(a.id) && isCourseSelected(a.course) {
            seen.insert(a.id)
            out.append(item(a, done: true))
        }
        return out
    }

    // MARK: Applying a remote plan

    /// Applies what a remote won, through the same stores a tap writes, with
    /// the tap hooks silenced; then records every adopted time as the remote's
    /// own. A record whose action was skipped (a flip of `repeatsWeekly`, an id
    /// that is not a UUID, a task the phone could not build) is not adopted: a
    /// time with no live task behind it would read as a tombstone on the next
    /// snapshot and bury the remote's task.
    func applySyncPlan(_ plan: SyncApplyPlan.Plan, log: SyncChangeLog) {
        guard !plan.isEmpty else { return }
        var skipped = Set<String>()
        func mark(_ kind: SyncChangeLog.Kind, _ id: String) { skipped.insert(kind.rawValue + ":" + id) }

        remoteApplyGate.run {
            var completionChanged = false
            let needsPool = plan.actions.contains { action in
                switch action {
                case .complete, .uncomplete: return true
                default: return false
                }
            }
            let pool = needsPool ? syncLookupPool() : [:]

            for action in plan.actions {
                switch action {
                case .complete(let id, let at):
                    guard let store = assignmentStore else { mark(.completion, id); continue }
                    let (ids, prototypes) = syncCompletionTargets(id: id, found: pool[id])
                    store.setCompleted(ids: ids, at: at, prototypes: prototypes)
                    completionChanged = true
                case .uncomplete(let id):
                    guard let store = assignmentStore else { mark(.completion, id); continue }
                    let (ids, _) = syncCompletionTargets(id: id, found: pool[id])
                    store.setCompleted(ids: [], at: nil, clearing: ids)
                    completionChanged = true
                case .setDueEdit(let id, let dueAt):
                    setDueEditFromSync(id: id, dueAt: dueAt)
                case .addManual(let id, let task):
                    if !addManualFromSync(id: id, task: task) { mark(.manual, id) }
                case .updateManual(let id, let task):
                    if !updateManualFromSync(id: id, task: task) { mark(.manual, id) }
                case .removeManual(let id):
                    removeManualFromSync(id: id)
                }
            }
            if completionChanged {
                reloadCompletionFromLedger()
                rebuildDashboardItems()
            }
        }

        for adopted in plan.adoptedTimes where !skipped.contains(adopted.kind.rawValue + ":" + adopted.id) {
            if adopted.kind == .manual, DeviceSyncRules.manualUUID(adopted.id) == nil { continue }
            log.record(kind: adopted.kind, id: adopted.id, at: adopted.at)
        }
    }

    /// Every id a tick on `id` applies to (a merged cross-platform item also
    /// ticks its counterpart, as `markCompleted` does), with the rows to seed a
    /// blank completion-only row from. Mirrors `rowsNeededToComplete`, which is
    /// private to `AppState.swift`. An id the phone has never seen is just
    /// itself: `AssignmentStore.setCompleted` keeps it as a completion-only row
    /// until its feed arrives.
    private func syncCompletionTargets(id: String, found: Assignment?) -> (Set<String>, [Assignment]) {
        guard let found else { return ([id], []) }
        var ids: Set<String> = [found.id]
        guard let linkedID = found.linkedID else { return (ids, [found]) }
        ids.insert(linkedID)
        var rows = [found]
        for candidate in gradescopeItems + canvasItems where candidate.id == linkedID {
            rows.append(candidate)
            break
        }
        return (ids, rows)
    }

    /// Every assignment the phone can name by id, first occurrence winning (the
    /// dashboard's merged items before the raw feeds, so a `linkedID` survives).
    private func syncLookupPool() -> [String: Assignment] {
        var manualItems: [Assignment] = []
        for task in manualAssignments { manualItems.append(task.asAssignment()) }
        var recurring: [Assignment] = []
        for task in effectiveRecurringTasks { recurring.append(contentsOf: task.upcomingAssignments()) }
        let groups: [[Assignment]] = [assignments, laterAssignments, assessments, mergedCoursework,
                                      manualItems, recurring, gradescopeItems, canvasItems]
        var out: [String: Assignment] = [:]
        for group in groups {
            for a in group where out[a.id] == nil { out[a.id] = a }
        }
        return out
    }

    /// `setDueDateEdit`'s writes, keyed by id: the dictionary, its persisted
    /// copy, the widget snapshot and the announcement badge. The remote's date
    /// is stored as given; `setDueDateEdit`'s "equal to the item's own date is
    /// not an edit" rule needs the item, which a remote id may not have here.
    private func setDueEditFromSync(id: String, dueAt: Date?) {
        guard !isUsingFixtureData else { return }
        var next = dueDateEdits
        if let dueAt { next[id] = dueAt } else { next.removeValue(forKey: id) }
        guard next != dueDateEdits else { return }
        dueDateEdits = next
        dueDateEditStore?.save(next)
        publishWidgetSnapshot()
        refreshAnnouncementBadge()
    }

    /// False when nothing was added.
    private func addManualFromSync(id: String, task: SyncSnapshot.ManualTask) -> Bool {
        guard let uuid = DeviceSyncRules.manualUUID(id) else { return false }
        if task.repeatsWeekly {
            // A rule needs a weekday and a time, which only a date gives.
            guard let due = task.dueAt,
                  !recurringTasks.contains(where: { $0.id == uuid })
            else { return false }
            let parts = Calendar.current.dateComponents([.weekday, .hour, .minute], from: due)
            addRecurringTask(RecurringTask(
                id: uuid, title: task.title, course: task.course,
                weekday: parts.weekday ?? 1, hour: parts.hour ?? 23, minute: parts.minute ?? 59,
                startDate: due, endDate: nil, origin: .manual))
        } else {
            guard !manualAssignments.contains(where: { $0.id == uuid }) else { return false }
            addManualAssignment(ManualAssignment(id: uuid, title: task.title,
                                                 course: task.course, dueAt: task.dueAt))
        }
        return true
    }

    /// False when nothing was changed because the update cannot apply: the
    /// phone has no such task, or the remote flipped `repeatsWeekly`, which is
    /// skipped (a one-off cannot become a rule without inventing a schedule).
    private func updateManualFromSync(id: String, task: SyncSnapshot.ManualTask) -> Bool {
        guard let uuid = DeviceSyncRules.manualUUID(id) else { return false }
        if let existing = manualAssignments.first(where: { $0.id == uuid }) {
            guard !task.repeatsWeekly else { return false }
            var changed = existing
            changed.title = task.title
            changed.course = task.course
            changed.dueAt = task.dueAt
            if changed != existing { replaceManualAssignment(changed) }
            return true
        }
        if let existing = recurringTasks.first(where: { $0.id == uuid }) {
            guard task.repeatsWeekly else { return false }
            var changed = existing
            changed.title = task.title
            changed.course = task.course
            if let due = task.dueAt {
                // The snapshot's date is the next occurrence, so it carries the
                // schedule's weekday and time but not its start or end.
                let parts = Calendar.current.dateComponents([.weekday, .hour, .minute], from: due)
                changed.weekday = parts.weekday ?? existing.weekday
                changed.hour = parts.hour ?? existing.hour
                changed.minute = parts.minute ?? existing.minute
            }
            if changed != existing { replaceRecurringTask(changed) }
            return true
        }
        return false
    }

    private func removeManualFromSync(id: String) {
        guard let uuid = DeviceSyncRules.manualUUID(id) else { return }
        if manualAssignments.contains(where: { $0.id == uuid }) {
            removeManualAssignment(id: uuid)
        } else if recurringTasks.contains(where: { $0.id == uuid }) {
            removeRecurringTask(id: uuid)
        }
    }
}
