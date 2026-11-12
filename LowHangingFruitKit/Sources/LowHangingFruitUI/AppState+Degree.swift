import Foundation
import LowHangingFruitKit
#if canImport(UIKit)
import UIKit
#endif

// MARK: – Degree progress (Path@Penn's audit, read with the student's own login)
//
// The student's degree audit is read from Path@Penn's advising page
// (`https://courses.upenn.edu/`) by `PathPortal`: one hidden WebView that lets
// the page sign in with the same Canvas/PennKey session the rest of the app
// rides, then asks the page's own scripts for the student's degrees, the audit
// and Penn's program catalogue (docs/DEGREE_PROGRESS_V12_BUILD_SPEC.md, "The
// rewrite contract"). This file is the only place those reads touch app state.
// Its bounds:
//
//  - Penn only, behind `FeatureFlags.degreeProgress`, foreground only, never
//    from a background wake, and never in preview or demo mode (the sample
//    snapshot is shown instead and the portal is never touched).
//  - Nothing leaves the phone: the audit is kept in `degree-audit.json`
//    (`DegreeAuditStore`). No token is ever in Swift, so nothing is in the
//    Keychain for this feature. Nothing goes to the backend, the laptop sync,
//    iCloud or the tree.
//  - Nothing is written to the ledger and no dashboard card comes from this.
//  - Disconnecting Canvas clears the file, the status and the WebView
//    (`clearDegreeData`, called from `disconnectCanvas`).
//  - Code decides nothing about requirements: the audit is Penn's. The one
//    thing rebuilt here is a what-if audit's `goals`, because the page's
//    reply may not echo an added minor (see `runWhatIf`).

/// What the degree screen says about the last read. `line(now:)` is the
/// exact one-line status the screen shows; nil means say nothing.
enum DegreeStatus: Equatable, Sendable {
    case idle
    case reading
    case waitingForDuo
    case needsCanvasSignIn
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

extension AppState {
    nonisolated static let degreeFailedLine = "couldn't read path@penn · retry"
    /// A read is stale after seven days. The audit changes at registration and
    /// when grades post, and a read costs a hidden sign-in to Penn (the page's
    /// token lasts a day, so every automatic read is a sign-in and can be a
    /// Duo push). Pull-to-refresh is the student's way to read now. It was 12
    /// hours until 2026-11-12, which asked for a sign-in twice a day for data
    /// that had not moved.
    nonisolated static let degreeStaleAfter: TimeInterval = 7 * 24 * 3600
    private static let maxWhatIfs = 4
    /// Which of the student's degrees is audited, as `StudentDegree.id`. Kept
    /// in `UserDefaults.lhf` as well as the snapshot so the choice survives a
    /// snapshot that is cleared or quarantined.
    private static let degreeSelectedKey = "degreeSelectedIDV1"

    // MARK: Rules

    /// Whether the feature exists on this install at all: the kill switch is
    /// on, and it is a Penn install or the preview/demo fixtures.
    var degreeFeatureAvailable: Bool {
        FeatureFlags.degreeProgress
            && (canvasInstallation.id == CanvasInstallation.penn.id || isUsingFixtureData)
    }

    /// Penn's code-to-name maps flattened for `DegreeGoals.title(descriptions:)`.
    var degreeDescriptions: [String: String] {
        degree.dictionaries?.descriptions ?? [:]
    }

    /// The degree being audited: the chosen one, else the first the record lists.
    var selectedStudentDegree: StudentDegree? {
        if let id = degree.selectedDegreeID, let match = degree.degrees.first(where: { $0.id == id }) {
            return match
        }
        return degree.degrees.first
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

    /// What a sign-in outcome means for the status line; nil for `.ready`.
    /// `.throttled` keeps whatever was showing before.
    nonisolated static func degreeStatus(for signIn: PathPortal.SignIn, previous: DegreeStatus) -> DegreeStatus? {
        switch signIn {
        case .ready:
            return nil
        case .needsDuo:
            return .waitingForDuo
        case .noCanvasSession:
            return .needsCanvasSignIn
        case .blocked, .timedOut:
            return .failed(degreeFailedLine)
        case .throttled:
            return previous == .reading ? .idle : previous
        }
    }

    /// The one retry a read gets when the page still held a token but a call
    /// failed (the 24-hour session lapsed under it): invalidate, sign in again,
    /// read again, once. Never a loop.
    nonisolated static func shouldRetryAfterInvalidate(readFailed: Bool, alreadyRetried: Bool) -> Bool {
        readFailed && !alreadyRetried
    }

    /// Which degree is selected once the record has been read again.
    ///
    /// The saved choice stands while the record lists the same degrees. When
    /// the list itself is different, the first one is selected instead, even
    /// if the saved one is still there. That second half exists because of
    /// the build that listed every curriculum the student had ever had
    /// (2026-11-10): the owner tapped through the stale chips, the last one
    /// he tapped happened to be a real second degree, and without this the
    /// corrected build would have opened on it rather than on his major. A
    /// record that changes is rare (a declared or dropped program), and
    /// opening on the first degree after one is the unsurprising thing.
    nonisolated static func degreeSelection(previous: [String], found: [String], saved: String?) -> String? {
        guard let first = found.first else { return nil }
        guard let saved, found.contains(saved) else { return first }
        if !previous.isEmpty, Set(previous) != Set(found) { return first }
        return saved
    }

    /// Where the status goes when a what-if finishes: back to what showed
    /// before it, but only if the status is still the "reading" this call set
    /// (anything else was written by a read that has since finished or failed,
    /// and restoring a `previous` captured before an await would clobber it),
    /// and never to "reading" itself, which another read owns.
    nonisolated static func degreeStatusAfterWhatIf(current: DegreeStatus, previous: DegreeStatus) -> DegreeStatus {
        guard current == .reading, previous != .reading else { return current }
        return previous
    }

    /// Binds the portal to the renewer's PennKey budget (`AppState.swift`,
    /// "the shared PennKey budget") and signs in. Every sign-in in this file
    /// goes through here, so the portal can never fill without the budget.
    private func signInToPath(force: Bool) async -> PathPortal.SignIn {
        let portal = degreePortal
        portal.credentialBudget = { [weak self] in
            self?.pathCredentialBudget() ?? PathPortal.CredentialBudget(
                lastSubmission: nil, lastFailedSubmission: nil,
                passwordRejected: true, autoLoginEnabled: false)
        }
        portal.onCredentialSubmitted = { [weak self] date in self?.notePathCredentialSubmitted(at: date) }
        portal.onCredentialFailed = { [weak self] date in self?.notePathCredentialFailed(at: date) }
        portal.onCredentialRejected = { [weak self] in self?.noteAutoLoginRejected() }
        return await portal.ensureSignedIn(force: force)
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
        var snapshot = degreeStore.load()
        if let saved = UserDefaults.lhf.string(forKey: Self.degreeSelectedKey), !saved.isEmpty {
            snapshot.selectedDegreeID = saved
        }
        degree = snapshot
        if let current = snapshot.current {
            degreeStatus = .read(current.fetchedAt)
        }
    }

    /// Everything this feature keeps, gone: the file, the in-memory snapshot,
    /// the status, the choice of degree and the WebView. Called on a Canvas
    /// disconnect, because the audit was read through that login.
    func clearDegreeData() {
        // A read in flight cannot be stopped mid-await, only told its work no
        // longer counts: every write below the awaits checks this number.
        degreeGeneration += 1
        degreeRefreshTask?.cancel()
        degreeRefreshTask = nil
        degreePortal.reset()
        degreeStore.clear()
        // The plan is degree data too: disconnecting Canvas deletes everything
        // this feature kept, the student's sample course load included, and the
        // loaded flag resets so the next sign-in starts from an empty plan.
        degreePlanStore.clear()
        degreePlan = .empty
        degreePlanLoaded = false
        degree = .empty
        degreeStatus = .idle
        UserDefaults.lhf.removeObject(forKey: "degreeRecentWhatIfsV1")
        UserDefaults.lhf.removeObject(forKey: Self.degreeSelectedKey)
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
        // Only the task this call started, and only if it is still the stored
        // one: `clearDegreeData` or a newer read may have replaced it, and
        // clearing theirs would let a second read start beside it.
        if degreeRefreshTask == task { degreeRefreshTask = nil }
    }

    private func performDegreeRefresh(force: Bool) async {
        let generation = degreeGeneration
        let now = Date()
        let previous = degreeStatus
        degreeStatus = .reading
        let portal = degreePortal

        // At most one retry per refresh (`shouldRetryAfterInvalidate`): a page
        // can keep an in-memory token for a session Penn has already ended, and
        // then every read fails forever unless the page is loaded again.
        var retried = false
        var readAudit: DegreeAudit?
        while readAudit == nil {
            let signIn = await signInToPath(force: force)
            guard generation == degreeGeneration else { return }
            if let stop = Self.degreeStatus(for: signIn, previous: previous) {
                degreeStatus = stop
                return
            }

            let found = await portal.degrees()
            guard generation == degreeGeneration else { return }
            guard !found.isEmpty else {
                if Self.shouldRetryAfterInvalidate(readFailed: true, alreadyRetried: retried) {
                    retried = true
                    portal.invalidateSession()
                    continue
                }
                degreeStatus = .failed(Self.degreeFailedLine)
                return
            }
            // A saved choice the record no longer lists (a dropped degree), or
            // a record whose list changed at all, falls back to the first one
            // (`degreeSelection`).
            let previousIDs = degree.degrees.map(\.id)
            let selectedBefore = degree.selectedDegreeID
            degree.degrees = found
            let chosen = Self.degreeSelection(
                previous: previousIDs, found: found.map(\.id), saved: selectedBefore)
            if let chosen, let selectedBefore, chosen != selectedBefore {
                // The list changed and the choice fell back: move the snapshot
                // with it, so `current` never shows one degree's audit under
                // another degree's chip.
                degree = degree.selecting(chosen, from: selectedBefore)
            } else {
                degree.selectedDegreeID = chosen
            }
            degree = degree.pruningShelves(keeping: found.map(\.id), selected: degree.selectedDegreeID)
            if let id = degree.selectedDegreeID {
                UserDefaults.lhf.set(id, forKey: Self.degreeSelectedKey)
            }
            guard let selected = selectedStudentDegree else {
                degreeStatus = .failed(Self.degreeFailedLine)
                return
            }

            let result = await portal.auditData(degreeInfo: selected.raw)
            guard generation == degreeGeneration else { return }
            if let data = result.data,
               let decoded = try? PathAuditDecoder.decode(
                data, fallbackGoals: selected.goals, isWhatIf: false, now: now) {
                readAudit = decoded
            } else if Self.shouldRetryAfterInvalidate(readFailed: true, alreadyRetried: retried) {
                retried = true
                portal.invalidateSession()
            } else {
                degreeStatus = .failed(Self.degreeFailedLine)
                return
            }
        }
        guard let finished = readAudit else { return }
        degree.current = finished
        persistDegree()
        degreeStatus = .read(now)

        // Which semester each course belongs to, for the semester table. The
        // audit does not say, so it is a second read of the record. A failed
        // read keeps the last map: an empty table for a network blip would be
        // worse than a slightly stale one, and the map only ever grows by a
        // term at a time.
        let terms = await portal.history()
        guard generation == degreeGeneration else { return }
        if let terms {
            let map = terms.timeline()
            if !map.isEmpty, map != degree.history {
                degree.history = map
                persistDegree()
            }
        }

        // Penn's code-to-name maps are fetched once; a failure only means
        // codes show as themselves.
        if degree.dictionaries == nil {
            let maps = await portal.dictionaries()
            guard generation == degreeGeneration else { return }
            if let maps {
                degree.dictionaries = maps
                persistDegree()
            }
        }
    }

    /// The student chose another of their own degrees. The old degree's audit
    /// and what-ifs go on the snapshot's shelf and the new degree's come off
    /// it, so a degree read before shows at once and Penn is asked only when
    /// there is nothing shelved or the read is stale. Throwing the audit away
    /// here, as this used to, made every chip tap a blank screen and a
    /// 30-second sign-in and read of an audit that had not changed.
    func selectDegree(_ id: String) async {
        guard id != selectedStudentDegree?.id else { return }
        if isUsingFixtureData {
            // The demo has no network and holds one sample audit; only the
            // chip moves, and nothing is saved.
            guard degree.degrees.contains(where: { $0.id == id }) else { return }
            degree.selectedDegreeID = id
            return
        }
        guard degreeFeatureAvailable else { return }
        // A read already in flight is auditing the old degree: tell it its
        // work no longer counts, wait for it to wind down, and only then start
        // the real one. Skipping the wait would make `refreshDegreeAudit`
        // join the old task and return having audited the wrong degree.
        degreeGeneration += 1
        let oldID = selectedStudentDegree?.id
        degree = degree.selecting(id, from: oldID)
        if let current = degree.current {
            degreeStatus = .read(current.fetchedAt)
        } else {
            degreeStatus = .idle
        }
        UserDefaults.lhf.set(id, forKey: Self.degreeSelectedKey)
        persistDegree()
        if let running = degreeRefreshTask {
            await running.value
            if degreeRefreshTask == running { degreeRefreshTask = nil }
        }
        // Forced only when nothing is shelved for this degree; otherwise the
        // ordinary staleness rule decides.
        await refreshDegreeAudit(force: degree.current == nil)
    }

    // MARK: What if

    /// Penn's program catalogue (code and title). Cached in the snapshot: it
    /// is about a thousand public rows and never personal.
    func loadDegreePrograms() async -> [PathProgramListing] {
        if isUsingFixtureData { return SampleData.degreeSnapshot().programs }
        guard degreeFeatureAvailable else { return [] }
        if !degree.programs.isEmpty { return degree.programs }
        let generation = degreeGeneration
        // A student's own tap, so the attempt spacing does not apply (the
        // PennKey budget still does, inside the portal). A throttle is never a
        // failure and says nothing; the list is simply not there yet.
        let signIn = await signInToPath(force: true)
        guard generation == degreeGeneration else { return [] }
        if signIn == .throttled { return [] }
        if let stop = Self.degreeStatus(for: signIn, previous: degreeStatus) {
            degreeStatus = stop
            return []
        }
        let list = await degreePortal.programs()
        guard generation == degreeGeneration else { return [] }
        guard !list.isEmpty else {
            degreeStatus = .failed(Self.degreeFailedLine)
            return []
        }
        degree.programs = list
        persistDegree()
        return list
    }

    /// The changes the page would allow for one catalogue entry, as plans the
    /// screen can offer. Empty when the entry could not be read.
    func degreeWhatIfPlans(for programCode: String) async -> [PathWhatIfPlan] {
        if isUsingFixtureData { return Self.fixtureWhatIfPlans(for: programCode) }
        guard degreeFeatureAvailable else { return [] }
        let generation = degreeGeneration
        let signIn = await signInToPath(force: true)
        guard generation == degreeGeneration, signIn == .ready else { return [] }
        guard let info = await degreePortal.programInfo(code: programCode) else { return [] }
        guard generation == degreeGeneration else { return [] }
        return PathWhatIf.plans(for: info, current: degree.degrees)
    }

    /// "What if I switched or added a program": audits the plan's description
    /// and files the result, most recent first, at most four. A failure leaves
    /// the current audit alone and says the failure words.
    func runWhatIf(_ plan: PathWhatIfPlan) async {
        guard degreeFeatureAvailable else { return }
        if isUsingFixtureData {
            runFixtureWhatIf(plan)
            return
        }
        let generation = degreeGeneration
        let now = Date()
        let previous = degreeStatus
        degreeStatus = .reading
        // One retry after a page reload, like the refresh (see there).
        var retried = false
        var whatIfAudit: DegreeAudit?
        while whatIfAudit == nil {
            let signIn = await signInToPath(force: true)
            guard generation == degreeGeneration else { return }
            if signIn == .throttled {
                // Never a failure: nothing was asked.
                degreeStatus = Self.degreeStatusAfterWhatIf(current: degreeStatus, previous: previous)
                return
            }
            if let stop = Self.degreeStatus(for: signIn, previous: previous) {
                degreeStatus = stop
                return
            }
            let result = await degreePortal.auditData(degreeInfo: plan.degreeInfo)
            guard generation == degreeGeneration else { return }
            if let data = result.data,
               let audit = try? PathAuditDecoder.decode(
                data, fallbackGoals: plan.goals, isWhatIf: true, now: now) {
                whatIfAudit = audit
            } else if Self.shouldRetryAfterInvalidate(readFailed: true, alreadyRetried: retried) {
                retried = true
                degreePortal.invalidateSession()
            } else {
                degreeStatus = .failed(Self.degreeFailedLine)
                return
            }
        }
        guard let decoded = whatIfAudit else { return }
        // The decoder takes `goals` from the reply's own `degreeInfo`, which
        // may not reflect an added minor, and the screen keys a what-if by the
        // goals the student asked for. So the audit is rebuilt under the
        // plan's goals; every other field is Penn's, copied as decoded.
        let audit = DegreeAudit(
            goals: plan.goals, isWhatIf: true, percentComplete: decoded.percentComplete,
            degreeLabel: decoded.degreeLabel, catalogYearLabel: decoded.catalogYearLabel,
            blocks: decoded.blocks, courses: decoded.courses, fetchedAt: decoded.fetchedAt)
        degree.whatIfs.removeAll { $0.goals == audit.goals }
        degree.whatIfs.insert(audit, at: 0)
        if degree.whatIfs.count > Self.maxWhatIfs {
            degree.whatIfs.removeLast(degree.whatIfs.count - Self.maxWhatIfs)
        }
        persistDegree()
        degreeStatus = Self.degreeStatusAfterWhatIf(current: degreeStatus, previous: previous)
    }

    // MARK: Fixtures

    /// The demo's plans: no portal, so one invented switch for any entry and
    /// one invented minor for a code ending "-MIN".
    private static func fixtureWhatIfPlans(for programCode: String) -> [PathWhatIfPlan] {
        let base = SampleData.degreeSnapshot().degrees.first
        let stem = programCode.split(separator: "-").first.map(String.init) ?? programCode
        var plans: [PathWhatIfPlan] = []
        let switchInfo: [String: String] = [
            "degc": "BSE", "levl": "UG", "coll": "EU", "major": stem, "program": "EU_BSE",
        ]
        plans.append(PathWhatIfPlan(
            change: .newProgram, programCode: programCode, degreeInfo: switchInfo,
            goals: StudentDegree(raw: switchInfo).goals))
        if programCode.uppercased().hasSuffix("-MIN") {
            var minorInfo = base?.raw ?? switchInfo
            minorInfo["minor"] = stem
            plans.append(PathWhatIfPlan(
                change: .addMinor, programCode: programCode, degreeInfo: minorInfo,
                goals: StudentDegree(raw: minorInfo).goals))
        }
        return plans
    }

    /// The demo's "run": no network, so a what-if the sample already holds for
    /// these goals moves to the front, and otherwise a copy of the first
    /// sample what-if is filed under the plan's goals, so the button visibly
    /// does something. Never saved: the demo must not write its sample to disk.
    private func runFixtureWhatIf(_ plan: PathWhatIfPlan) {
        guard FeatureFlags.degreeProgress else { return }
        let goals = plan.goals
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

    // MARK: Plan

    /// Loads the student's sample course load once per `AppState`: the sample
    /// plan in fixture mode (in memory, never touching disk), the saved file
    /// otherwise, then makes sure there is a first semester to add to.
    func loadDegreePlanIfNeeded(now: Date = Date()) {
        guard !degreePlanLoaded else { return }
        degreePlanLoaded = true
        let loaded = isUsingFixtureData ? SampleData.degreePlan(now: now) : degreePlanStore.load()
        degreePlan = DegreePlanMath.ensuringFirstTerm(loaded, now: now)
    }

    func addPlannedCourse(code: String, title: String?, credits: Double, to termCode: String) {
        let course = PlannedCourse(code: DegreePlanMath.normalizedCode(code), title: title, credits: credits)
        commitDegreePlan(DegreePlanMath.adding(course, to: termCode, in: degreePlan))
    }

    func removePlannedCourse(code: String, from termCode: String) {
        commitDegreePlan(DegreePlanMath.removing(courseCode: code, from: termCode, in: degreePlan))
    }

    /// A drag of a planned course onto another semester, or onto another
    /// planned course (it lands before that one). The rules, including every
    /// refusal, are `DegreePlanMath.moving`.
    func movePlannedCourse(code: String, to termCode: String, before anchorCode: String?) {
        commitDegreePlan(DegreePlanMath.moving(
            courseCode: code, to: termCode, before: anchorCode, in: degreePlan))
    }

    func addPlanTerm(now: Date = Date()) {
        commitDegreePlan(DegreePlanMath.withTermAdded(degreePlan, now: now))
    }

    func removeLastPlanTermIfEmpty() {
        commitDegreePlan(DegreePlanMath.removingLastTermIfEmpty(degreePlan))
    }

    /// Assigns the new plan and saves it, except for the demo's sample, which
    /// must never be written to disk. A failed save costs only the next
    /// launch's copy; the in-memory plan is still right, so it is not an error
    /// the student sees.
    private func commitDegreePlan(_ plan: DegreePlan) {
        guard plan != degreePlan else { return }
        degreePlan = plan
        guard !isUsingFixtureData else { return }
        try? degreePlanStore.save(plan)
    }

    // MARK: Plumbing

    private func persistDegree() {
        // A failed save costs only the next launch's cache; the in-memory
        // snapshot is still right, so it is not an error the student sees.
        try? degreeStore.save(degree)
    }
}
