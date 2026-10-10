import Foundation
import Testing
@testable import LowHangingFruitKit

/// The sign-up backlog rule and its persistence, with no `AppState` involved.
///
/// Every `UserDefaults` here is a scratch suite. The cutoff key is read by
/// every `AppState.init` in every concurrently running suite once it exists in
/// the shared domain, so nothing in this file may ever write it there (see the
/// shared-defaults traps in CLAUDE.md); `neverTouchesTheSharedDomain` below
/// checks that from the outside.
@Suite("Sign-up backlog: the rule")
struct SignupBacklogRuleTests {
    private let signup = Date(timeIntervalSince1970: 1_800_000_000)
    private var rule: SignupBacklog { SignupBacklog(signupAt: signup) }

    private func item(
        _ source: Assignment.Source = .canvas,
        due: Date?
    ) -> Assignment {
        Assignment(source: source, sourceID: "x-1", kind: .assignment,
                   course: "RULE 0001", title: "Work", dueAt: due, url: nil)
    }

    @Test("the window is seven days and the cutoff is sign-up minus the window")
    func windowAndCutoff() {
        #expect(SignupBacklog.window == 7 * 86_400)
        #expect(SignupBacklog.cutoff(forSignupAt: signup) == signup.addingTimeInterval(-7 * 86_400))
        #expect(rule.cutoff == signup.addingTimeInterval(-7 * 86_400))
    }

    @Test("the boundary: exactly seven days overdue at sign-up is shown, a second more is hidden")
    func boundary() {
        let exactly = signup.addingTimeInterval(-7 * 86_400)
        #expect(!rule.hides(item(due: exactly), isFinished: false))
        #expect(rule.hides(item(due: exactly.addingTimeInterval(-1)), isFinished: false))
        #expect(!rule.hides(item(due: exactly.addingTimeInterval(1)), isFinished: false))
    }

    @Test("overdue by less than a week, due today, and due later are all shown")
    func recentAndFutureAreShown() {
        for days in [-6.0, -1.0, 0.0, 3.0, 40.0] {
            let due = signup.addingTimeInterval(days * 86_400)
            #expect(!rule.hides(item(due: due), isFinished: false), "due \(days) days from sign-up")
        }
    }

    @Test("an undated item is never hidden")
    func undatedIsNeverHidden() {
        #expect(!rule.hides(item(due: nil), isFinished: false))
    }

    @Test("finished work is never hidden, however old")
    func finishedIsNeverHidden() {
        let ancient = signup.addingTimeInterval(-90 * 86_400)
        #expect(!rule.hides(item(due: ancient), isFinished: true))
        #expect(rule.hides(item(due: ancient), isFinished: false))
    }

    @Test("every feed source is hidden when old and unfinished",
          arguments: [Assignment.Source.canvas, .canvasModules, .gradescope, .canvasAnnouncement])
    func feedSourcesAreHidden(source: Assignment.Source) {
        let old = signup.addingTimeInterval(-8 * 86_400)
        #expect(SignupBacklog.isFeedSource(source))
        #expect(rule.hides(item(source, due: old), isFinished: false))
    }

    @Test("manual work (which includes recurring tasks) and suggestions are never hidden",
          arguments: [Assignment.Source.manual, .canvasSuggestion])
    func nonFeedSourcesAreNeverHidden(source: Assignment.Source) {
        let old = signup.addingTimeInterval(-30 * 86_400)
        #expect(!SignupBacklog.isFeedSource(source))
        #expect(!rule.hides(item(source, due: old), isFinished: false))
    }

    @Test("the row-shaped overload is the same rule")
    func rowOverloadAgrees() {
        let old = signup.addingTimeInterval(-8 * 86_400)
        #expect(rule.hides(source: .gradescope, dueAt: old, isFinished: false))
        #expect(!rule.hides(source: .manual, dueAt: old, isFinished: false))
        #expect(!rule.hides(source: .canvas, dueAt: nil, isFinished: false))
        #expect(!rule.hides(source: .canvas, dueAt: old, isFinished: true))
    }
}

@Suite("Sign-up backlog: the decision and its storage")
struct SignupBacklogStoreTests {
    private func scratch() -> (UserDefaults, String) {
        let name = "lhf.signup-backlog-store.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    private let signup = Date(timeIntervalSince1970: 1_800_000_000)

    @Test("nothing is decided on a fresh install, and nothing is hidden")
    func freshIsUndecided() {
        let (defaults, name) = scratch()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SignupBacklogStore(defaults: defaults)
        #expect(store.decision == .undecided)
        #expect(store.decidedBacklog == nil)
        #expect(store.activeBacklog == nil)
        #expect(store.isRevealed == false)
    }

    @Test("the first feed items record sign-up minus seven days")
    func signupRecordsACutoff() {
        let (defaults, name) = scratch()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SignupBacklogStore(defaults: defaults)

        let decision = store.recordSignupIfUndecided(at: signup)
        let expected = signup.addingTimeInterval(-7 * 86_400)
        #expect(decision == .cutoff(expected))
        #expect(store.decidedBacklog == SignupBacklog(cutoff: expected))

        // And it is on disk, not just in the return value: a second store over
        // the same defaults (a relaunch) reads it back.
        #expect(SignupBacklogStore(defaults: defaults).decision == .cutoff(expected))
    }

    @Test("a ledger that already held feed rows records the no-cutoff sentinel")
    func existingInstallRecordsNoCutoff() {
        let (defaults, name) = scratch()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SignupBacklogStore(defaults: defaults)

        #expect(store.recordExistingInstallIfUndecided(ledgerHoldsFeedRows: true) == .noCutoff)
        #expect(store.decision == .noCutoff)
        #expect(store.decidedBacklog == nil)
        // Decided is not the same as undecided: the key exists.
        #expect(defaults.object(forKey: SharedDefaults.signupBacklogCutoffKey) != nil)
        // The sentinel is a cutoff in 1970, so a reader that forgot to
        // special-case it would still hide nothing real.
        #expect((defaults.object(forKey: SharedDefaults.signupBacklogCutoffKey) as? Double) == 0)
    }

    @Test("an empty ledger records nothing: a student who has not synced yet stays undecided")
    func emptyLedgerStaysUndecided() {
        let (defaults, name) = scratch()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SignupBacklogStore(defaults: defaults)

        #expect(store.recordExistingInstallIfUndecided(ledgerHoldsFeedRows: false) == .undecided)
        #expect(store.decision == .undecided)
        #expect(defaults.object(forKey: SharedDefaults.signupBacklogCutoffKey) == nil)
    }

    @Test("the decision is set once: nothing later can move it in either direction")
    func decisionIsSetOnce() {
        let later = signup.addingTimeInterval(30 * 86_400)

        // A cutoff stays the same cutoff: a reconnect a month later (the ledger
        // is empty again after a disconnect, and the clock has moved), a second
        // sign-up moment, and a ledger that now holds rows cannot move it.
        let (defaults, name) = scratch()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SignupBacklogStore(defaults: defaults)
        let first = store.recordSignupIfUndecided(at: signup)
        #expect(store.recordSignupIfUndecided(at: later) == first)
        #expect(store.recordExistingInstallIfUndecided(ledgerHoldsFeedRows: true) == first)
        #expect(store.recordExistingInstallIfUndecided(ledgerHoldsFeedRows: false) == first)

        // The same from the other side: a sentinel stays a sentinel.
        let (otherDefaults, otherName) = scratch()
        defer { otherDefaults.removePersistentDomain(forName: otherName) }
        let existing = SignupBacklogStore(defaults: otherDefaults)
        existing.recordExistingInstallIfUndecided(ledgerHoldsFeedRows: true)
        #expect(existing.recordSignupIfUndecided(at: later) == .noCutoff)
        #expect(existing.recordExistingInstallIfUndecided(ledgerHoldsFeedRows: false) == .noCutoff)
    }

    @Test("the ledger is only consulted while undecided")
    func ledgerQuestionIsLazy() {
        // Once a cutoff is recorded the ledger is never scanned again.
        let (defaults, name) = scratch()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SignupBacklogStore(defaults: defaults)
        var asked = 0
        func ledger() -> Bool { asked += 1; return true }

        store.recordSignupIfUndecided(at: signup)
        store.recordExistingInstallIfUndecided(ledgerHoldsFeedRows: ledger())
        store.recordExistingInstallIfUndecided(ledgerHoldsFeedRows: ledger())
        #expect(asked == 0)

        // And once the sentinel is recorded it is asked exactly the once.
        let (otherDefaults, otherName) = scratch()
        defer { otherDefaults.removePersistentDomain(forName: otherName) }
        let existing = SignupBacklogStore(defaults: otherDefaults)
        existing.recordExistingInstallIfUndecided(ledgerHoldsFeedRows: ledger())
        existing.recordExistingInstallIfUndecided(ledgerHoldsFeedRows: ledger())
        existing.recordExistingInstallIfUndecided(ledgerHoldsFeedRows: ledger())
        #expect(asked == 1)
    }

    @Test("the first launch is claimed exactly once, and the marker survives a relaunch")
    func firstLaunchIsClaimedOnce() {
        let (defaults, name) = scratch()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SignupBacklogStore(defaults: defaults)

        #expect(store.claimFirstLaunch() == true)
        #expect(store.claimFirstLaunch() == false)
        // A relaunch is a new store over the same defaults.
        #expect(SignupBacklogStore(defaults: defaults).claimFirstLaunch() == false)
    }

    @Test("proof from outside the ledger records the sentinel on an empty ledger, without asking the ledger")
    func preDatesFeatureRecordsNoCutoff() {
        let (defaults, name) = scratch()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SignupBacklogStore(defaults: defaults)
        var asked = 0
        func ledger() -> Bool { asked += 1; return false }

        #expect(store.recordExistingInstallIfUndecided(preDatesFeature: true, ledgerHoldsFeedRows: ledger())
                == .noCutoff)
        #expect(asked == 0, "the outside proof settles it; the ledger is not scanned")
        #expect(store.decidedBacklog == nil)
    }

    @Test("without outside proof an empty ledger still records nothing, and a cutoff is never overwritten")
    func preDatesFeatureIsOnlyAnAddedSignal() {
        let (defaults, name) = scratch()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SignupBacklogStore(defaults: defaults)
        #expect(store.recordExistingInstallIfUndecided(preDatesFeature: false, ledgerHoldsFeedRows: false)
                == .undecided)

        let first = store.recordSignupIfUndecided(at: signup)
        #expect(store.recordExistingInstallIfUndecided(preDatesFeature: true, ledgerHoldsFeedRows: true) == first)
    }

    @Test("a damaged value leans toward showing everything instead of being decided again")
    func damagedValueIsNoCutoff() {
        let damaged: [Any] = ["garbage", -5.0]
        for bad in damaged {
            let (defaults, name) = scratch()
            defer { defaults.removePersistentDomain(forName: name) }
            defaults.set(bad, forKey: SharedDefaults.signupBacklogCutoffKey)
            let store = SignupBacklogStore(defaults: defaults)
            #expect(store.decision == .noCutoff, "\(bad)")
            #expect(store.recordSignupIfUndecided(at: signup) == .noCutoff)
            #expect(store.recordExistingInstallIfUndecided(ledgerHoldsFeedRows: true) == .noCutoff)
        }
    }

    @Test("the show switch persists beside the cutoff and lifts the active rule, not the decision")
    func revealSwitch() {
        let (defaults, name) = scratch()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SignupBacklogStore(defaults: defaults)
        store.recordSignupIfUndecided(at: signup)
        #expect(store.activeBacklog != nil)

        store.isRevealed = true
        #expect(SignupBacklogStore(defaults: defaults).isRevealed)
        #expect(store.activeBacklog == nil)
        // Still decided, so the count of withheld items can still be taken
        // while they are shown (the line then offers "hide").
        #expect(store.decidedBacklog != nil)

        store.isRevealed = false
        #expect(store.activeBacklog != nil)
    }

    @Test("the keys are versioned and distinct")
    func keyNames() {
        #expect(SharedDefaults.signupBacklogCutoffKey == "signupBacklogCutoffV1")
        #expect(SharedDefaults.signupBacklogRevealedKey == "signupBacklogRevealedV1")
        #expect(SharedDefaults.signupBacklogSeenKey == "signupBacklogSeenV1")
    }

    @Test("nothing in this file wrote the shared domain")
    func neverTouchesTheSharedDomain() {
        #expect(UserDefaults.lhf.object(forKey: SharedDefaults.signupBacklogCutoffKey) == nil)
        #expect(UserDefaults.lhf.object(forKey: SharedDefaults.signupBacklogRevealedKey) == nil)
        #expect(UserDefaults.lhf.object(forKey: SharedDefaults.signupBacklogSeenKey) == nil)
    }
}

@MainActor
@Suite("Sign-up backlog: what counts as an existing install")
struct SignupBacklogLedgerQuestionTests {
    private func feed(_ source: Assignment.Source, _ id: String) -> Assignment {
        Assignment(source: source, sourceID: id, kind: .assignment,
                   course: "LEDG 0001", title: "Work \(id)",
                   dueAt: Date().addingTimeInterval(86_400), url: nil)
    }

    @Test("an empty ledger holds no feed rows")
    func emptyLedger() throws {
        #expect(try AssignmentStore(inMemory: true).holdsFeedRows() == false)
    }

    @Test("manual work alone is not a feed row")
    func manualIsNotFeed() throws {
        let store = try AssignmentStore(inMemory: true)
        store.upsert([feed(.manual, "manual-1")])
        #expect(store.holdsFeedRows() == false)
    }

    @Test("a row from any feed source counts",
          arguments: [Assignment.Source.canvas, .canvasModules, .gradescope, .canvasAnnouncement])
    func feedRowCounts(source: Assignment.Source) throws {
        let store = try AssignmentStore(inMemory: true)
        store.upsert([feed(source, "row-1")])
        #expect(store.holdsFeedRows())
    }

    @Test("a hidden completion-only feed row counts: someone has used this install")
    func completionOnlyCounts() throws {
        let store = try AssignmentStore(inMemory: true)
        store.setCompleted(ids: ["canvas:ticked-before-it-ever-synced"], at: Date())
        #expect(store.holdsFeedRows())
    }

    @Test("rows the caller names as not real (preview samples) are ignored")
    func ignoredIDs() throws {
        let store = try AssignmentStore(inMemory: true)
        store.setCompleted(ids: ["canvas:s-1"], at: Date())
        #expect(store.holdsFeedRows())
        #expect(store.holdsFeedRows(ignoring: ["canvas:s-1"]) == false)
        // ...but a real row beside it still counts.
        store.upsert([feed(.canvas, "real-1")])
        #expect(store.holdsFeedRows(ignoring: ["canvas:s-1"]))
    }
}

@MainActor
@Suite("Sign-up backlog: the widget's ledger fallback")
struct SignupBacklogWidgetReaderTests {
    private func makeStore() throws -> (AssignmentStore, URL) {
        let url = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("lhf-widget-backlog-\(UUID().uuidString).store")
        return (try AssignmentStore(url: url), url)
    }

    private func item(
        _ id: String, title: String, due: Date?, source: Assignment.Source = .canvas
    ) -> Assignment {
        Assignment(source: source, sourceID: id, kind: .assignment,
                   course: "WIDG 0001", title: title, dueAt: due, url: nil)
    }

    private func scratch() -> (UserDefaults, String) {
        let name = "lhf.signup-backlog-widget.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    /// A ledger with one stale item (due 9 days before the sign-up moment), one
    /// recent one (3 days before), one in the future, and an old manual task.
    private func populated() throws -> (url: URL, now: Date) {
        let (store, url) = try makeStore()
        let now = Date()
        _ = store.reconcile([
            item("1", title: "Stale", due: now.addingTimeInterval(-9 * 86_400)),
            item("2", title: "Recent", due: now.addingTimeInterval(-3 * 86_400)),
            item("3", title: "Ahead", due: now.addingTimeInterval(2 * 86_400)),
        ], source: .canvas)
        store.upsert([item("manual-1", title: "My old task",
                           due: now.addingTimeInterval(-30 * 86_400), source: .manual)])
        return (url, now)
    }

    @Test("with a cutoff, the stale unfinished item is left out and everything else stays")
    func honoursTheCutoff() throws {
        let (url, now) = try populated()
        defer { try? FileManager.default.removeItem(at: url) }
        let (defaults, name) = scratch()
        defer { defaults.removePersistentDomain(forName: name) }
        SignupBacklogStore(defaults: defaults).recordSignupIfUndecided(at: now)

        let snapshot = try #require(LedgerWidgetReader.snapshot(storeURL: url, now: now, defaults: defaults))
        #expect(snapshot.items.map(\.title) == ["My old task", "Recent", "Ahead"])
    }

    @Test("with no decision, or the no-cutoff sentinel, the widget shows everything as before")
    func ignoresAnAbsentCutoff() throws {
        let (url, now) = try populated()
        defer { try? FileManager.default.removeItem(at: url) }

        let (undecided, undecidedName) = scratch()
        defer { undecided.removePersistentDomain(forName: undecidedName) }
        let all = ["My old task", "Stale", "Recent", "Ahead"]
        let beforeAnyDecision = try #require(
            LedgerWidgetReader.snapshot(storeURL: url, now: now, defaults: undecided))
        #expect(beforeAnyDecision.items.map(\.title) == all)

        let (existing, existingName) = scratch()
        defer { existing.removePersistentDomain(forName: existingName) }
        SignupBacklogStore(defaults: existing).recordExistingInstallIfUndecided(ledgerHoldsFeedRows: true)
        let onAnExistingInstall = try #require(
            LedgerWidgetReader.snapshot(storeURL: url, now: now, defaults: existing))
        #expect(onAnExistingInstall.items.map(\.title) == all)
    }

    @Test("once the student chooses to see older assignments, the widget agrees with the dashboard")
    func honoursTheRevealSwitch() throws {
        let (url, now) = try populated()
        defer { try? FileManager.default.removeItem(at: url) }
        let (defaults, name) = scratch()
        defer { defaults.removePersistentDomain(forName: name) }
        let store = SignupBacklogStore(defaults: defaults)
        store.recordSignupIfUndecided(at: now)
        store.isRevealed = true

        let snapshot = try #require(LedgerWidgetReader.snapshot(storeURL: url, now: now, defaults: defaults))
        #expect(snapshot.items.map(\.title).contains("Stale"))
    }
}
