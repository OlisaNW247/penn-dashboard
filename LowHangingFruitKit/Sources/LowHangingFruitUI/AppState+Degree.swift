import Foundation
import LowHangingFruitKit
#if canImport(UIKit)
import UIKit
#endif

// MARK: – Degree progress (Path@Penn's audit, read with the student's own login)
//
// The student's degree audit is read from Penn's Degree Works with the same
// Canvas/PennKey session the rest of the app rides (`DegreeWorksSessionReader`
// for the tokens, `DegreeWorksClient` for the audit). This file is the only
// place that reads touch app state. Its bounds:
//
//  - Penn only, behind `FeatureFlags.degreeProgress`, foreground only, never
//    from a background wake, and never in preview or demo mode (the sample
//    snapshot is shown instead and no network is touched).
//  - Nothing leaves the phone: the audit is kept in `degree-audit.json`
//    (`DegreeAuditStore`), the tokens in the Keychain. Nothing goes to the
//    backend, the laptop sync, iCloud or the tree.
//  - Nothing is written to the ledger and no dashboard card comes from this.
//  - Disconnecting Canvas clears the tokens, the file and the status
//    (`clearDegreeData`, called from `disconnectCanvas`).

/// What the degree screen says about the last read. `line(now:)` is the
/// exact one-line status the screen shows; nil means say nothing.
enum DegreeStatus: Equatable, Sendable {
    case idle
    case reading
    case waitingForDuo
    case needsCanvasSignIn
    case needsGoals
    case failed(String)
    case read(Date)

    /// Lowercase, the least text that works (CLAUDE.md copy rule).
    func line(now: Date) -> String? {
        switch self {
        case .idle:
            return nil
        case .reading:
            return "reading path@penn…"
        case .waitingForDuo:
            return "approve the duo push on this phone"
        case .needsCanvasSignIn:
            return "sign in to canvas"
        case .needsGoals:
            return "pick your degree"
        case let .failed(message):
            return message
        case let .read(date):
            let calendar = Calendar.current
            if calendar.isDate(date, inSameDayAs: now) { return "read today" }
            if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
               calendar.isDate(date, inSameDayAs: yesterday) {
                return "read yesterday"
            }
            return "read \(Self.shortDay(date))"
        }
    }

    /// "nov 7": lowercase month abbreviation, pinned to English so the
    /// screen's words never mix languages.
    private static func shortDay(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "MMM d"
        return formatter.string(from: date).lowercased()
    }
}

/// Collects the key-shape lines a client call reports. The client's callback
/// is `@Sendable`, so the lines go through a lock instead of capturing state.
private final class DegreeShapeCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []

    func set(_ lines: [String]) {
        lock.lock(); defer { lock.unlock() }
        stored = lines
    }

    var lines: [String] {
        lock.lock(); defer { lock.unlock() }
        return stored
    }
}

/// How one authorised call ended.
private enum DegreeCall<Value> {
    case value(Value)
    case needsGoals
    case stop(DegreeStatus)
}

extension AppState {
    nonisolated static let degreeFailedLine = "couldn't read path@penn · retry"
    /// A read is stale after twelve hours (the audit changes at registration
    /// and grade time, not by the minute).
    nonisolated static let degreeStaleAfter: TimeInterval = 12 * 3600
    private static let maxWhatIfs = 5
    /// The degree the student picked when Degree Works would not say, as
    /// JSON-encoded `DegreeGoals` in `UserDefaults.lhf`. Kept so the question
    /// is asked once, not at every stale read; cleared with the rest.
    private static let degreePickedGoalsKey = "degreePickedGoalsV1"

    // MARK: Rules

    /// Whether the feature exists on this install at all: the kill switch is
    /// on, and it is a Penn install or the preview/demo fixtures.
    var degreeFeatureAvailable: Bool {
        FeatureFlags.degreeProgress
            && (canvasInstallation.id == CanvasInstallation.penn.id || isUsingFixtureData)
    }

    nonisolated static func degreeIsStale(readAt: Date?, now: Date) -> Bool {
        guard let readAt else { return true }
        return now.timeIntervalSince(readAt) >= degreeStaleAfter
    }

    /// The pure rule for "should a real read start now". Fixtures never read:
    /// they are handled before this is asked.
    nonisolated static func shouldRefreshDegree(
        isPenn: Bool,
        flag: Bool,
        fixture: Bool,
        isForeground: Bool,
        stale: Bool,
        force: Bool
    ) -> Bool {
        guard flag, isPenn, !fixture, isForeground else { return false }
        return stale || force
    }

    private var degreeIsForeground: Bool {
        #if os(iOS)
        if SharedDefaults.isTestRunner { return true }
        return UIApplication.shared.applicationState == .active
        #else
        return true
        #endif
    }

    // MARK: Launch and clear

    /// Loads the saved snapshot (or the sample, in fixture mode). Cheap and
    /// network-free, so it is safe at launch.
    func loadDegreeSnapshotAtLaunch() {
        guard FeatureFlags.degreeProgress else { return }
        if isUsingFixtureData {
            degree = SampleData.degreeSnapshot()
            degreeStatus = .read(Date())
            return
        }
        guard canvasInstallation.id == CanvasInstallation.penn.id else { return }
        let snapshot = degreeStore.load()
        degree = snapshot
        if let current = snapshot.current {
            degreeStatus = .read(current.fetchedAt)
        }
    }

    /// Everything this feature keeps, gone: the tokens, the file, the
    /// in-memory snapshot, the status and the read throttle. Called on a
    /// Canvas disconnect, because the audit was read through that login.
    func clearDegreeData() {
        // A read in flight cannot be stopped mid-await, only told its work no
        // longer counts: every write below the awaits checks this number.
        degreeGeneration += 1
        degreeRefreshTask?.cancel()
        degreeRefreshTask = nil
        DegreeWorksTokenStore.remove()
        degreeStore.clear()
        degree = .empty
        degreeStatus = .idle
        degreeSessionReader.resetThrottle()
        UserDefaults.lhf.removeObject(forKey: "degreeRecentWhatIfsV1")
        UserDefaults.lhf.removeObject(forKey: Self.degreePickedGoalsKey)
        #if DEBUG
        DebugDegreeLog.clear()
        #endif
    }

    // MARK: Reads

    /// Reads the current audit when the rule says to (or when forced).
    func refreshDegreeAudit(force: Bool = false) async {
        if isUsingFixtureData {
            guard FeatureFlags.degreeProgress else { return }
            degree = SampleData.degreeSnapshot()
            degreeStatus = .read(Date())
            return
        }
        let readAt: Date? = {
            if case let .read(date) = degreeStatus { return date }
            return degree.current?.fetchedAt
        }()
        guard Self.shouldRefreshDegree(
            isPenn: canvasInstallation.id == CanvasInstallation.penn.id,
            flag: FeatureFlags.degreeProgress,
            fixture: false,
            isForeground: degreeIsForeground,
            stale: Self.degreeIsStale(readAt: readAt, now: Date()),
            force: force
        ) else { return }

        if let running = degreeRefreshTask {
            await running.value
            return
        }
        let task = Task { await self.performDegreeRefresh(force: force) }
        degreeRefreshTask = task
        await task.value
        degreeRefreshTask = nil
    }

    private func performDegreeRefresh(force: Bool) async {
        let generation = degreeGeneration
        let now = Date()
        degreeStatus = .reading
        let collector = DegreeShapeCollector()
        let client = degreeClient
        // A degree the student already picked is audited again as picked, so
        // Degree Works is not asked to guess it (and the student is not asked
        // again) every twelve hours; only when that fails does the ordinary
        // read run. A rejected token is the one failure that must reach
        // `degreeCall`, which owns the single re-read.
        let picked: DegreeGoals? = UserDefaults.lhf.data(forKey: Self.degreePickedGoalsKey)
            .flatMap { try? JSONDecoder().decode(DegreeGoals.self, from: $0) }
        let result = await degreeCall(now: now, force: force) { tokens -> DegreeAudit in
            if let picked {
                do {
                    return try await client.fetchAudit(
                        tokens: tokens, goals: picked, keepCurriculum: true, isWhatIf: false,
                        now: now, shape: { collector.set($0) }
                    )
                } catch DegreeWorksClient.Failure.tokensRejected {
                    throw DegreeWorksClient.Failure.tokensRejected
                } catch {
                    // Fall through to the ordinary read below.
                }
            }
            return try await client.fetchCurrentAudit(tokens: tokens, now: now, shape: { collector.set($0) })
        }
        guard generation == degreeGeneration else { return }
        switch result {
        case let .value(audit):
            adoptDegreeShape(collector.lines)
            degree.current = audit
            persistDegree()
            degreeStatus = .read(now)
        case .needsGoals:
            degreeStatus = .needsGoals
        case let .stop(status):
            degreeStatus = status
        }
    }

    /// The student picked their own degree (Degree Works would not say):
    /// audit that, keeping their curriculum, and keep it as the current audit.
    func pickCurrentGoals(_ goals: DegreeGoals) async {
        guard degreeFeatureAvailable else { return }
        if isUsingFixtureData {
            // The demo has no network; the sample is already the answer.
            degreeStatus = .read(Date())
            return
        }
        let generation = degreeGeneration
        let now = Date()
        degreeStatus = .reading
        let collector = DegreeShapeCollector()
        let client = degreeClient
        let result = await degreeCall(now: now) { tokens in
            try await client.fetchAudit(
                tokens: tokens, goals: goals, keepCurriculum: true, isWhatIf: false,
                now: now, shape: { collector.set($0) }
            )
        }
        guard generation == degreeGeneration else { return }
        switch result {
        case let .value(audit):
            adoptDegreeShape(collector.lines)
            if let data = try? JSONEncoder().encode(goals) {
                UserDefaults.lhf.set(data, forKey: Self.degreePickedGoalsKey)
            }
            degree.current = audit
            persistDegree()
            degreeStatus = .read(now)
        case .needsGoals:
            degreeStatus = .needsGoals
        case let .stop(status):
            degreeStatus = status
        }
    }

    /// "What if I switched or added a program": audits `goals` without
    /// keeping the curriculum and files the result, most recent first, at
    /// most five. A failure leaves the current audit and the status line
    /// alone except for the failure words.
    func runWhatIf(_ goals: DegreeGoals) async {
        guard degreeFeatureAvailable else { return }
        if isUsingFixtureData {
            runFixtureWhatIf(goals)
            return
        }
        let generation = degreeGeneration
        let now = Date()
        let previous = degreeStatus
        degreeStatus = .reading
        let collector = DegreeShapeCollector()
        let client = degreeClient
        let result = await degreeCall(now: now) { tokens in
            try await client.fetchAudit(
                tokens: tokens, goals: goals, keepCurriculum: false, isWhatIf: true,
                now: now, shape: { collector.set($0) }
            )
        }
        guard generation == degreeGeneration else { return }
        switch result {
        case let .value(audit):
            adoptDegreeShape(collector.lines)
            degree.whatIfs.removeAll { $0.goals == audit.goals }
            degree.whatIfs.insert(audit, at: 0)
            if degree.whatIfs.count > Self.maxWhatIfs {
                degree.whatIfs.removeLast(degree.whatIfs.count - Self.maxWhatIfs)
            }
            persistDegree()
            degreeStatus = previous == .reading ? .idle : previous
        case .needsGoals:
            degreeStatus = .failed(Self.degreeFailedLine)
        case let .stop(status):
            degreeStatus = status
        }
    }

    /// The demo's "run": no network, so a what-if the sample already holds for
    /// these goals moves to the front, and otherwise a copy of the first
    /// sample what-if is filed under the picked goals, so the button visibly
    /// does something.
    private func runFixtureWhatIf(_ goals: DegreeGoals) {
        guard FeatureFlags.degreeProgress else { return }
        var snapshot = degree.current == nil ? SampleData.degreeSnapshot() : degree
        if let index = snapshot.whatIfs.firstIndex(where: { $0.goals == goals }) {
            let match = snapshot.whatIfs.remove(at: index)
            snapshot.whatIfs.insert(match, at: 0)
        } else if let template = snapshot.whatIfs.first ?? snapshot.current {
            let copy = DegreeAudit(
                goals: goals, isWhatIf: true, percentComplete: template.percentComplete,
                degreeLabel: template.degreeLabel, catalogYearLabel: template.catalogYearLabel,
                blocks: template.blocks, courses: template.courses, fetchedAt: Date()
            )
            snapshot.whatIfs.insert(copy, at: 0)
            if snapshot.whatIfs.count > Self.maxWhatIfs {
                snapshot.whatIfs.removeLast(snapshot.whatIfs.count - Self.maxWhatIfs)
            }
        }
        degree = snapshot
    }

    /// The picker's choices, narrowed by what is already `selected`. Nil when
    /// they could not be read; the sheet then says so in the status words.
    func loadDegreeCatalog(selected: DegreeGoals) async -> DegreeGoalCatalog? {
        guard !isUsingFixtureData, degreeFeatureAvailable else { return degree.catalog }
        let generation = degreeGeneration
        let client = degreeClient
        let result = await degreeCall(now: Date()) { tokens in
            try await client.fetchCatalog(tokens: tokens, selected: selected)
        }
        guard generation == degreeGeneration else { return nil }
        guard case let .value(catalog) = result else { return degree.catalog }
        degree.catalog = catalog
        persistDegree()
        return catalog
    }

    // MARK: Plumbing

    private func adoptDegreeShape(_ lines: [String]) {
        guard !lines.isEmpty else { return }
        degree.lastShape = lines
        #if DEBUG
        lines.forEach { DebugDegreeLog.record($0) }
        #endif
    }

    private func persistDegree() {
        // A failed save costs only the next launch's cache; the in-memory
        // snapshot is still right, so it is not an error the student sees.
        try? degreeStore.save(degree)
    }

    /// Runs `operation` with usable tokens: the stored pair when it is still
    /// good, otherwise one read of the session. A rejected pair is dropped and
    /// the session is read once more, never twice (a loop against Penn's SSO
    /// is the thing to avoid).
    private func degreeCall<Value>(
        now: Date,
        force: Bool = false,
        _ operation: (DegreeWorksTokens) async throws -> Value
    ) async -> DegreeCall<Value> {
        let generation = degreeGeneration
        for attempt in 0..<2 {
            let tokens: DegreeWorksTokens
            if attempt == 0, let stored = DegreeWorksTokenStore.load(), stored.isUsable(now: now) {
                tokens = stored
            } else {
                // `force` is the student's own retry; without it a failed read
                // left the reader's throttle standing and the retry did nothing.
                let outcome = await degreeSessionReader.read(force: force || attempt > 0)
                // A disconnect during the read: nothing from it may be kept.
                guard generation == degreeGeneration else { return .stop(.idle) }
                switch outcome {
                case let .landed(read, finalPage):
                    #if DEBUG
                    DebugDegreeLog.record("session landed: \(finalPage)")
                    #endif
                    DegreeWorksTokenStore.save(read)
                    tokens = read
                case .needsDuo:
                    return .stop(.waitingForDuo)
                case .noCanvasSession:
                    return .stop(.needsCanvasSignIn)
                case .noSession:
                    // With no saved PennKey the chain stopped at Penn's login
                    // page and only the student can continue it.
                    return .stop(PennKeyCredentialStore.hasCredentials
                        ? .failed(Self.degreeFailedLine) : .needsCanvasSignIn)
                case .timedOut, .throttled:
                    return .stop(.failed(Self.degreeFailedLine))
                }
            }
            do {
                let value = try await operation(tokens)
                guard generation == degreeGeneration else { return .stop(.idle) }
                return .value(value)
            } catch DegreeWorksClient.Failure.tokensRejected {
                guard generation == degreeGeneration else { return .stop(.idle) }
                DegreeWorksTokenStore.remove()
                continue
            } catch DegreeWorksClient.Failure.needsGoals {
                return .needsGoals
            } catch {
                return .stop(.failed(Self.degreeFailedLine))
            }
        }
        return .stop(.failed(Self.degreeFailedLine))
    }
}
