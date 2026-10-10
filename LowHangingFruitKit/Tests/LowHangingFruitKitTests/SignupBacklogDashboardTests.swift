import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// The sign-up backlog through a real `AppState`: the decision taken at `init`
/// for an existing install, the decision taken in the rebuild that first sees
/// feed items for a new student, and the filter in `rebuildDashboardItems` that
/// applies it. The pure rule and its storage are in `SignupBacklogTests`.
///
/// **Nothing here goes through `sync()`.** `sync()` and `syncGradescope` are
/// not touched by this feature, and they cannot run without a network. What
/// they do with a fetched feed is "reconcile into the ledger, put the result in
/// the pool, rebuild", all in one main-actor turn with no `await` between, so
/// `Harness.syncCanvas` / `syncGradescope` do exactly those three steps through
/// the instance's own store, and the decision happens where it really happens:
/// in `init` and in the rebuild.
///
/// **How this stays out of the shared domain.** The decision key, once written
/// to `UserDefaults.lhf`, would be read by the `AppState.init` of every suite
/// running alongside this one, and a cutoff would then hide the 45-to-90-day-old
/// fixtures that other suites feed into fresh ledgers on purpose (the
/// shared-defaults trap in CLAUDE.md). So under the test runner an `AppState`
/// takes no decision and hides nothing unless it is constructed with
/// `signupBacklogDefaults:` (a scratch suite); every state in this file is, and
/// each scratch suite is deleted afterwards. `neverWritesTheSharedDomain` and
/// `anAppStateThatDidNotOptInTakesNoDecision` check that from the outside.
///
/// **Assertions are scoped to this suite's own courses** (`SIGNUP …`). An
/// `AppState` loads the manual-work and recurring-task blobs from the shared
/// defaults domain, and `SemesterRolloverTests` leaves a manual "Read chapter 1"
/// in it permanently, so a fresh `AppState` is not an empty dashboard on any Mac
/// that has run the suite. Comparing whole buckets would pass on a clean machine
/// and fail on a used one.
///
/// Nothing here calls `addManualAssignment`, `restartOnboarding`,
/// `disconnectCanvas` or `setCourse`: each writes the shared domain (the manual
/// blob, the onboarding flag), the Keychain, or the course-preferences blob.
/// The "reconnect" case is `store.purge(source:)` followed by a second sync,
/// which is what a disconnect-and-reconnect does to the ledger; the "onboarding
/// restart" case is the rebuild with emptied pools that `restartOnboarding`
/// makes. The decision lives only in `SignupBacklogStore`, which none of those
/// paths touches.
@MainActor
@Suite("Sign-up backlog: the dashboard")
struct SignupBacklogDashboardTests {
    private static let course = "SIGNUP 0001"
    /// A second course, so a Canvas item and a Gradescope item in one test are
    /// never paired by `AssignmentDeduplicator` (which only merges within one).
    private static let otherCourse = "SIGNUP 0002"
    static let coursePrefix = "SIGNUP "

    /// One `AppState` over a fresh in-memory ledger, backed by a scratch suite.
    @MainActor
    private struct Harness {
        private(set) var state: AppState
        let store: AssignmentStore
        let defaults: UserDefaults
        private let suite: String

        /// The persisted onboarding and preview flags a launch sees. Always
        /// passed explicitly, even when both are false: the real flags live in
        /// the shared domain, where another suite may be writing them while this
        /// one runs, and the first-launch clause reads them.
        typealias Flags = (complete: Bool, inPreview: Bool)
        /// A phone that has never finished onboarding: where every new student
        /// starts, and where the existing tests live.
        static let midOnboarding: Flags = (complete: false, inPreview: false)

        /// `seed` puts rows on the ledger *before* the `AppState` launches: an
        /// existing install whose previous launch left feed rows behind.
        init(seed: (AssignmentStore) -> Void = { _ in }, flags: Flags = Harness.midOnboarding) throws {
            suite = "lhf.signup-backlog-dashboard.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suite)!
            store = try AssignmentStore(inMemory: true)
            seed(store)
            state = AppState(
                assignmentStore: store,
                signupBacklogDefaults: defaults,
                persistedFlagsForSignupBacklog: flags
            )
        }

        /// A launch with already-feed rows on the ledger, as a convenience.
        init(ledger: [Assignment], flags: Flags = Harness.midOnboarding) throws {
            try self.init(seed: { _ = $0.reconcile(ledger, source: .canvas) }, flags: flags)
        }

        func tearDown() {
            defaults.removePersistentDomain(forName: suite)
        }

        /// The next launch: a new `AppState` over the same ledger and the same
        /// defaults, which is all a relaunch preserves.
        mutating func relaunch(flags: Flags = Harness.midOnboarding) {
            state = AppState(
                assignmentStore: store,
                signupBacklogDefaults: defaults,
                persistedFlagsForSignupBacklog: flags
            )
        }

        /// What `sync()` does with a fetched Canvas feed, minus the network:
        /// reconcile into the ledger, put the result in the pool, rebuild. No
        /// suspension point sits between those steps in the real thing either.
        func syncCanvas(_ fetched: [Assignment], at now: Date = Date()) {
            let result = store.reconcile(fetched, source: .canvas)
            state.canvasItems = result.items.sorted(by: Assignment.isOrderedByDueDate)
            state.rebuildDashboardItemsForTesting(now: now)
        }

        /// The same for `syncGradescope`.
        func syncGradescope(_ fetched: [Assignment], at now: Date = Date()) {
            let result = store.reconcile(fetched, source: .gradescope)
            state.gradescopeItems = result.items
            state.rebuildDashboardItemsForTesting(now: now)
        }

        var backlogStore: SignupBacklogStore { SignupBacklogStore(defaults: defaults) }

        /// Everything the dashboard lists, in any bucket, *including* the
        /// first-launch submission hold. An overdue Canvas item is parked there
        /// instead of in `assignments` whenever Grade Watcher is usable, which
        /// another suite saving Canvas cookies to the Keychain at the same
        /// instant can make true; "withheld by the backlog" must not be confused
        /// with "held for a submission check", and membership here is the same
        /// either way.
        var listedIDs: Set<String> {
            Set((state.assignments + state.laterAssignments + state.assessments
                 + state.awaitingCanvasCheck)
                .filter { $0.course.hasPrefix(SignupBacklogDashboardTests.coursePrefix) }
                .map(\.id))
        }
    }

    /// Items are dated relative to one fixed `now`, so "8 days before sign-up"
    /// means the same thing in the decision and in the assertions.
    private func item(
        _ id: String,
        _ title: String,
        daysFromSignup days: Double,
        from now: Date,
        source: Assignment.Source = .canvas,
        course: String = SignupBacklogDashboardTests.course
    ) -> Assignment {
        Assignment(source: source, sourceID: id, kind: .assignment,
                   course: course, title: title,
                   dueAt: now.addingTimeInterval(days * 86_400), url: nil)
    }

    /// The decision's cutoff, if it is one. Compared with a tolerance rather
    /// than `==`: the stored value is seconds since 1970, and a `Date` built
    /// from `Date()` carries sub-microsecond precision that does not survive
    /// the round trip bit for bit.
    private func expectCutoff(
        _ decision: SignupBacklogStore.Decision,
        isSevenDaysBefore signup: Date,
        sourceLocation: SourceLocation = #_sourceLocation
    ) {
        guard case let .cutoff(date) = decision else {
            Issue.record("expected a cutoff, got \(decision)", sourceLocation: sourceLocation)
            return
        }
        let expected = signup.addingTimeInterval(-7 * 86_400)
        #expect(abs(date.timeIntervalSince(expected)) < 0.001, sourceLocation: sourceLocation)
    }

    // MARK: The headline behaviour

    @Test("a new student's old unfinished work is withheld; recent and upcoming work is not")
    func newStudentFirstSync() throws {
        let h = try Harness()
        defer { h.tearDown() }
        let now = Date()
        let old = item("old-8", "Eight days gone", daysFromSignup: -8, from: now)
        let recent = item("recent-6", "Six days gone", daysFromSignup: -6, from: now)
        let ahead = item("ahead-2", "Due soon", daysFromSignup: 2, from: now)
        // Inside the dashboard window so the term cap can never drop it,
        // whatever week of the term the suite happens to run in.
        let farAhead = item("ahead-5", "Due later", daysFromSignup: 5, from: now)
        #expect(h.backlogStore.decision == .undecided, "nothing is decided before the first feed")

        h.syncCanvas([old, recent, ahead, farAhead], at: now)

        // todo (overdue plus the next two days) and all (what is further out)
        // are both built from what is listed here.
        #expect(h.listedIDs == [recent.id, ahead.id, farAhead.id])
        #expect(!h.listedIDs.contains(old.id), "8 days overdue at sign-up is withheld")
        #expect(h.listedIDs.contains(recent.id), "6 days overdue is ordinary overdue work")

        // The widget snapshot is built from the same arrays. (Not asserted on
        // `recent`: an overdue Canvas item can sit in the submission hold, which
        // the snapshot rightly leaves out.)
        let widgetTitles = h.state.widgetNextDueItems().map(\.title)
        #expect(!widgetTitles.contains("Eight days gone"))
        #expect(widgetTitles.contains("Due soon"))
        #expect(widgetTitles.contains("Due later"))

        // Nothing was deleted: the row is still on the ledger.
        #expect(h.store.allRowsForTesting().contains { $0.id == old.id })
        #expect(h.state.canvasItems.contains { $0.id == old.id })

        #expect(h.state.signupBacklogHiddenCount == 1)
        expectCutoff(h.backlogStore.decision, isSevenDaysBefore: now)
    }

    @Test("Gradescope work is withheld by the same rule, from the same decision")
    func gradescopeIsCovered() throws {
        let h = try Harness()
        defer { h.tearDown() }
        let now = Date()
        let old = item("g-old", "Gradescope old", daysFromSignup: -9, from: now, source: .gradescope)
        let recent = item("g-new", "Gradescope recent", daysFromSignup: -2, from: now, source: .gradescope)

        h.syncGradescope([old, recent], at: now)

        // Gradescope items are never parked in the Canvas submission hold, so
        // this one is exact.
        #expect(h.state.assignments.filter { $0.course == Self.course }.map(\.id) == [recent.id])
        #expect(h.state.signupBacklogHiddenCount == 1)
        expectCutoff(h.backlogStore.decision, isSevenDaysBefore: now)
    }

    @Test("completed work reaches prev however old it is, and is never counted as withheld")
    func completedWorkStillReachesPrev() throws {
        let h = try Harness()
        defer { h.tearDown() }
        let now = Date()
        let done = item("done-30", "Handed in long ago", daysFromSignup: -30, from: now)
        let open = item("open-30", "Never handed in", daysFromSignup: -30, from: now)

        h.syncCanvas([done, open], at: now)
        h.state.markCompleted(done)

        #expect(h.listedIDs.isEmpty, "neither old item is on the todo or all lists")
        #expect(h.state.mergedCoursework.contains { $0.id == done.id })
        #expect(h.state.signupBacklogHiddenCount == 1, "only the unfinished one is withheld")

        // The prev tab is built by the view model from `mergedCoursework`.
        let vm = DashboardViewModel()
        vm.bind(to: h.state)
        let inDone = vm.items.first { $0.id == done.id }
        #expect(inDone?.isCompleted == true)
        #expect(!vm.items.contains { $0.id == open.id }, "the withheld item is nowhere in the view model")
    }

    @Test("a manual-sourced item is never withheld, however old")
    func manualWorkIsNeverWithheld() throws {
        let h = try Harness()
        defer { h.tearDown() }
        let now = Date()
        // `AppState.manualAssignments` cannot be seeded without writing the
        // shared manual-work blob, so a `.manual` row is fed through the same
        // pool every source passes through before the backlog filter. The filter
        // does not care which array an item came from.
        let mine = item("manual-30", "Something I added", daysFromSignup: -30, from: now, source: .manual)
        let feed = item("canvas-30", "Something Canvas listed", daysFromSignup: -30, from: now)

        let result = h.store.reconcile([feed], source: .canvas)
        h.state.canvasItems = result.items + [mine]
        h.state.rebuildDashboardItemsForTesting(now: now)

        #expect(h.listedIDs.contains(mine.id))
        #expect(!h.listedIDs.contains(feed.id))
        #expect(h.state.signupBacklogHiddenCount == 1)
    }

    @Test("an undated item is never withheld")
    func undatedIsNeverWithheld() throws {
        let h = try Harness()
        defer { h.tearDown() }
        let now = Date()
        let undated = Assignment(source: .canvas, sourceID: "undated", kind: .assignment,
                                 course: Self.course, title: "No due date", dueAt: nil, url: nil)

        h.syncCanvas([undated], at: now)

        #expect(h.state.signupBacklogHiddenCount == 0)
        #expect(h.state.canvasItems.contains { $0.id == undated.id })
    }

    // MARK: The way back

    @Test("show brings the withheld work back as ordinary overdue work, hide removes it again")
    func showAndHide() throws {
        let h = try Harness()
        defer { h.tearDown() }
        let now = Date()
        let oldCanvas = item("old-12", "Twelve days gone", daysFromSignup: -12, from: now)
        let recentCanvas = item("recent-2", "Two days gone", daysFromSignup: -2, from: now)
        // A Gradescope pair too: unlike an overdue Canvas item it can never sit
        // in the submission hold, so the widget and `assignments` checks below
        // are exact.
        let oldGradescope = item("g-old-12", "Gradescope twelve days gone",
                                 daysFromSignup: -12, from: now, source: .gradescope,
                                 course: Self.otherCourse)
        let recentGradescope = item("g-recent-2", "Gradescope two days gone",
                                    daysFromSignup: -2, from: now, source: .gradescope,
                                    course: Self.otherCourse)
        h.syncCanvas([oldCanvas, recentCanvas], at: now)
        h.syncGradescope([oldGradescope, recentGradescope], at: now)
        #expect(h.listedIDs == [recentCanvas.id, recentGradescope.id])
        #expect(h.state.signupBacklogRevealed == false)
        #expect(h.state.signupBacklogHiddenCount == 2)

        h.state.setSignupBacklogRevealed(true)
        #expect(h.state.signupBacklogRevealed)
        #expect(h.listedIDs == [oldCanvas.id, recentCanvas.id, oldGradescope.id, recentGradescope.id])
        #expect(h.state.assignments.map(\.id).contains(oldGradescope.id), "shown as ordinary overdue work")
        #expect(h.state.widgetNextDueItems().map(\.title).contains("Gradescope twelve days gone"))
        // The count is of what the rule matches, so the line can still read
        // "showing ..." beside a hide button.
        #expect(h.state.signupBacklogHiddenCount == 2)
        #expect(h.defaults.bool(forKey: SharedDefaults.signupBacklogRevealedKey))

        h.state.setSignupBacklogRevealed(false)
        #expect(h.listedIDs == [recentCanvas.id, recentGradescope.id])
        #expect(!h.state.widgetNextDueItems().map(\.title).contains("Gradescope twelve days gone"))
        #expect(!h.defaults.bool(forKey: SharedDefaults.signupBacklogRevealedKey))
    }

    @Test("the switch survives a relaunch")
    func switchSurvivesRelaunch() throws {
        var h = try Harness()
        defer { h.tearDown() }
        let now = Date()
        h.syncCanvas([item("old", "Old", daysFromSignup: -12, from: now)], at: now)
        h.state.setSignupBacklogRevealed(true)

        h.relaunch()
        #expect(h.state.signupBacklogRevealed)
    }

    @Test("ask is given the same pool as the dashboard, on both paths, and gets the rest back on show")
    func assistantAgreesWithTheDashboard() throws {
        let h = try Harness()
        defer { h.tearDown() }
        let now = Date()
        let old = item("old-10", "Withheld from ask", daysFromSignup: -10, from: now)
        let recent = item("recent-1", "Offered to ask", daysFromSignup: -1, from: now)
        h.syncCanvas([old, recent], at: now)

        // On-device path.
        func ownWork() -> Set<String> {
            Set(h.state.assistantWorkItems()
                .filter { $0.course.hasPrefix(Self.coursePrefix) }
                .map(\.id))
        }
        #expect(ownWork() == [recent.id])
        // Server path: the context document names work by title.
        let document = h.state.assistantContextDocument()
        #expect(document.contains("Offered to ask"))
        #expect(!document.contains("Withheld from ask"))

        h.state.setSignupBacklogRevealed(true)
        #expect(ownWork() == [old.id, recent.id])
        #expect(h.state.assistantContextDocument().contains("Withheld from ask"))
    }

    // MARK: Existing installs: decided at init

    @Test("an existing install updating to this build sees no change at all")
    func existingInstallHidesNothing() throws {
        let now = Date()
        let old = item("old-40", "Very old", daysFromSignup: -40, from: now)
        let older = item("old-9", "Old", daysFromSignup: -9, from: now)
        // The ledger already holds feed rows when this build first launches.
        let h = try Harness(ledger: [old, older])
        defer { h.tearDown() }

        // Decided at launch, before anything has synced: nothing hidden, ever.
        #expect(h.backlogStore.decision == .noCutoff)
        #expect(h.state.signupBacklogHiddenCount == 0)
        #expect(h.listedIDs == [old.id, older.id])

        // The first sync after the update, which also brings a new old item.
        let fresh = item("old-20", "Newly listed, long overdue", daysFromSignup: -20, from: now)
        h.syncCanvas([old, older, fresh], at: now)

        #expect(h.backlogStore.decision == .noCutoff)
        #expect(h.listedIDs == [old.id, older.id, fresh.id])
        #expect(h.state.signupBacklogHiddenCount == 0)
    }

    @Test("an existing install is classified at init, before the first rebuild can read it as a sign-up")
    func existingInstallIsClassifiedBeforeTheFirstRebuild() throws {
        let now = Date()
        let h = try Harness(ledger: [item("old-40", "Very old", daysFromSignup: -40, from: now)])
        defer { h.tearDown() }

        // The pool was seeded from the ledger and `init` has already rebuilt
        // once on it. Had that rebuild run first, it would have found feed items
        // on an undecided install and recorded a sign-up cutoff, hiding the 40
        // day old item. Seeing the sentinel instead is what pins the order.
        #expect(!h.state.canvasItems.isEmpty, "the first rebuild saw feed items")
        #expect(h.backlogStore.decision == .noCutoff)
        #expect(h.listedIDs == ["canvas:old-40"])
    }

    @Test("an install whose ledger holds only hidden completion rows is still an existing install")
    func completionOnlyRowsMakeAnExistingInstall() throws {
        let h = try Harness(seed: { store in
            store.setCompleted(ids: ["canvas:ticked-off-before-this-build"], at: Date())
        })
        defer { h.tearDown() }

        #expect(h.backlogStore.decision == .noCutoff)

        let now = Date()
        h.syncCanvas([item("old", "Old", daysFromSignup: -20, from: now)], at: now)
        #expect(h.listedIDs == ["canvas:old"])
    }

    @Test("a relaunch with an empty ledger leaves a student who has not synced yet undecided")
    func emptyLedgerAtLaunchStaysUndecided() throws {
        let h = try Harness()
        defer { h.tearDown() }

        #expect(h.backlogStore.decision == .undecided)
        h.state.rebuildDashboardItemsForTesting()
        #expect(h.backlogStore.decision == .undecided, "a rebuild with nothing in the pools decides nothing")
    }

    @Test("the existing-install check does not depend on the preview flag: real rows are real")
    func existingInstallCheckIgnoresTheFixtureFlag() throws {
        let h = try Harness()
        defer { h.tearDown() }
        let now = Date()

        // A phone whose persisted preview mode is on when this build installs
        // cannot be built without writing the shared preview flag, so the check
        // is called directly with the per-instance fixture override on.
        h.state.forceFixtureDataForTesting(true)
        h.state.recordSignupBacklogForExistingInstallIfNeeded()
        #expect(h.backlogStore.decision == .undecided, "an empty ledger records nothing, preview or not")

        _ = h.store.reconcile([item("real", "Real work", daysFromSignup: -20, from: now)], source: .canvas)
        h.state.recordSignupBacklogForExistingInstallIfNeeded()
        #expect(h.backlogStore.decision == .noCutoff)
    }

    // MARK: Existing installs with an empty ledger: the first-launch clause

    @Test("an install that had finished onboarding when this build first launched is an existing install, even with an empty ledger")
    func completedOnboardingAtFirstLaunchIsAnExistingInstall() throws {
        // The store fell back to memory, every row aged out, or the feed was
        // empty: the ledger proves nothing, but onboarding was complete before
        // this build ever ran.
        let h = try Harness(flags: (complete: true, inPreview: false))
        defer { h.tearDown() }

        #expect(h.backlogStore.decision == .noCutoff)
        #expect(h.defaults.object(forKey: SharedDefaults.signupBacklogSeenKey) != nil)

        // Its first sync after the update brings a long-overdue backlog, and
        // nothing is withheld.
        let now = Date()
        let old = item("old-30", "Long overdue", daysFromSignup: -30, from: now)
        h.syncCanvas([old], at: now)
        #expect(h.listedIDs == [old.id])
        #expect(h.state.signupBacklogHiddenCount == 0)
    }

    @Test("a relaunch part-way through onboarding stays undecided, and the first items then get a cutoff")
    func midOnboardingRelaunchStaysUndecided() throws {
        var h = try Harness()      // first launch: onboarding not finished
        defer { h.tearDown() }
        #expect(h.backlogStore.decision == .undecided)

        h.relaunch()               // killed on the Gradescope step, say
        #expect(h.backlogStore.decision == .undecided)
        h.relaunch()
        #expect(h.backlogStore.decision == .undecided)

        let now = Date()
        let old = item("old-10", "Ten days gone", daysFromSignup: -10, from: now)
        let recent = item("recent-2", "Two days gone", daysFromSignup: -2, from: now)
        h.syncCanvas([old, recent], at: now)

        expectCutoff(h.backlogStore.decision, isSevenDaysBefore: now)
        #expect(h.listedIDs == [recent.id])
    }

    @Test("an install in preview mode stays undecided, and is a new student when it signs in for real")
    func previewInstallStaysUndecided() throws {
        // Preview marks onboarding complete as well, so completed-and-not-in-
        // preview is what separates a previewing student from an existing one.
        var h = try Harness(flags: (complete: true, inPreview: true))
        defer { h.tearDown() }
        #expect(h.backlogStore.decision == .undecided)

        // The student taps Connect Canvas (`restartOnboarding` clears both
        // flags) and the app is relaunched part-way through signing in.
        h.relaunch(flags: Harness.midOnboarding)
        #expect(h.backlogStore.decision == .undecided)

        let now = Date()
        let old = item("old-10", "Ten days gone", daysFromSignup: -10, from: now)
        h.syncCanvas([old], at: now)
        expectCutoff(h.backlogStore.decision, isSevenDaysBefore: now)
        #expect(h.listedIDs.isEmpty)
    }

    @Test("a new student whose first syncs failed, relaunched after finishing onboarding, still gets a cutoff on the first items")
    func failedSyncWindow() throws {
        var h = try Harness()      // fresh install, onboarding in progress
        defer { h.tearDown() }
        #expect(h.backlogStore.decision == .undecided)

        // Onboarding finishes with an empty ledger: the connect-time sync and
        // the hand-off sync both failed (`sync()` swallows its errors and
        // `connectCanvas` returns once the feed URL is captured), so nothing
        // ever reached a pool. Then the app is relaunched, and the persisted
        // flag now reads "complete".
        h.state.rebuildDashboardItemsForTesting()
        h.relaunch(flags: (complete: true, inPreview: false))
        #expect(h.backlogStore.decision == .undecided,
                "completed onboarding on a later launch is not proof of an existing install")

        // The first successful sync: the whole backlog arrives at once.
        let now = Date()
        let old = item("old-12", "Twelve days gone", daysFromSignup: -12, from: now)
        let recent = item("recent-3", "Three days gone", daysFromSignup: -3, from: now)
        h.syncCanvas([old, recent], at: now)

        expectCutoff(h.backlogStore.decision, isSevenDaysBefore: now)
        #expect(h.listedIDs == [recent.id], "old work is hidden")
        #expect(h.state.signupBacklogHiddenCount == 1)
    }

    @Test("the first-launch clause does not fire on a second launch")
    func clauseDoesNotFireOnASecondLaunch() throws {
        var h = try Harness()      // first launch: onboarding not finished
        defer { h.tearDown() }

        // Every later launch sees onboarding complete and an empty ledger, and
        // none of them may read that as an existing install.
        for launch in 2...4 {
            h.relaunch(flags: (complete: true, inPreview: false))
            #expect(h.backlogStore.decision == .undecided, "launch \(launch)")
        }

        // The marker was written by the first launch, whatever its outcome.
        #expect(h.defaults.object(forKey: SharedDefaults.signupBacklogSeenKey) != nil)
        #expect(h.backlogStore.claimFirstLaunch() == false)
    }

    @Test("the clause and the ledger check are each enough on their own")
    func eitherSignalIsEnough() throws {
        // Ledger rows, onboarding not complete (a reinstall over a restored
        // ledger, say): the ledger alone settles it.
        let now = Date()
        let byLedger = try Harness(
            ledger: [item("old", "Old", daysFromSignup: -20, from: now)],
            flags: Harness.midOnboarding)
        defer { byLedger.tearDown() }
        #expect(byLedger.backlogStore.decision == .noCutoff)

        // Onboarding complete, empty ledger, first launch: the flag alone does.
        let byFlag = try Harness(flags: (complete: true, inPreview: false))
        defer { byFlag.tearDown() }
        #expect(byFlag.backlogStore.decision == .noCutoff)
    }

    // MARK: New students: decided in the rebuild that first sees feed items

    @Test("the cutoff is recorded, and applied, in the same rebuild that first sees feed items")
    func decidedInTheSameRebuildThatFirstSeesFeedItems() throws {
        let h = try Harness()
        defer { h.tearDown() }
        let now = Date()
        let old = item("old-10", "Ten days gone", daysFromSignup: -10, from: now)
        let recent = item("recent-3", "Three days gone", daysFromSignup: -3, from: now)

        // The sync's reconcile and pool assignment, but not yet its rebuild.
        let result = h.store.reconcile([old, recent], source: .canvas)
        h.state.canvasItems = result.items
        #expect(h.backlogStore.decision == .undecided, "nothing decides before a rebuild looks")

        // One rebuild, at the sign-up moment.
        h.state.rebuildDashboardItemsForTesting(now: now)

        expectCutoff(h.backlogStore.decision, isSevenDaysBefore: now)
        #expect(h.listedIDs == [recent.id], "the cutoff was already in force for that rebuild")
        #expect(h.state.signupBacklogHiddenCount == 1)
    }

    @Test("a rebuild with empty pools, or a feed that arrives empty, decides nothing")
    func emptyPoolsDoNotDecide() throws {
        let h = try Harness()
        defer { h.tearDown() }
        let now = Date()

        h.state.rebuildDashboardItemsForTesting(now: now)
        #expect(h.backlogStore.decision == .undecided)

        // A first sync that returns nothing yet (a term that has not posted):
        // the reconcile is a no-op and the pool stays empty.
        h.syncCanvas([], at: now)
        h.syncGradescope([], at: now)
        #expect(h.backlogStore.decision == .undecided)

        // The sign-up moment is when the first items actually arrive, not when
        // the student first connected.
        let later = now.addingTimeInterval(3 * 86_400)
        h.syncCanvas([item("old", "Old", daysFromSignup: -10, from: later)], at: later)
        expectCutoff(h.backlogStore.decision, isSevenDaysBefore: later)
    }

    // MARK: Set once

    @Test("the decision is taken once: later syncs, a reconnect, the other feed and a relaunch cannot move it")
    func decisionIsStable() throws {
        var h = try Harness()
        defer { h.tearDown() }
        let signup = Date()
        let old = item("old", "Old", daysFromSignup: -10, from: signup)
        h.syncCanvas([old], at: signup)
        let decided = h.backlogStore.decision
        expectCutoff(decided, isSevenDaysBefore: signup)

        // A later sync, a month on.
        let later = signup.addingTimeInterval(30 * 86_400)
        h.syncCanvas([old], at: later)
        #expect(h.backlogStore.decision == decided)

        // Disconnect purges the source's rows; reconnecting syncs into an
        // empty ledger, which on its own would look like a new student.
        h.store.purge(source: .canvas)
        h.state.canvasItems = []
        h.state.rebuildDashboardItemsForTesting(now: later)
        h.syncCanvas([old], at: later.addingTimeInterval(86_400))
        #expect(h.backlogStore.decision == decided)

        // Connecting Gradescope afterwards is another first arrival for that
        // feed, and must not move the cutoff either.
        h.syncGradescope([item("g", "Gradescope", daysFromSignup: -9, from: signup, source: .gradescope)],
                         at: later.addingTimeInterval(2 * 86_400))
        #expect(h.backlogStore.decision == decided)

        // And neither does the next launch, over a ledger that now holds rows
        // (which `init` would otherwise read as an existing install).
        h.relaunch()
        #expect(h.backlogStore.decision == decided)
    }

    // MARK: Preview and demo mode

    @Test("preview and demo mode take no decision, hide nothing, and write nothing to the ledger")
    func fixtureModeIsUntouched() throws {
        let h = try Harness()
        defer { h.tearDown() }
        let now = Date()
        h.state.forceFixtureDataForTesting(true)

        // What preview mode does: sample items go straight into memory.
        h.state.canvasItems = SampleData.items(now: now).map(\.assignment)
        h.state.rebuildDashboardItemsForTesting(now: now)
        #expect(h.store.rowCount() == 0, "preview writes nothing to the ledger")
        #expect(h.state.signupBacklogHiddenCount == 0)
        #expect(h.backlogStore.decision == .undecided, "feed items in the pool, but they are fixtures")

        // Even real-looking feed items arriving while fixture data is on take
        // no decision.
        h.syncCanvas([item("old", "Old", daysFromSignup: -20, from: now)], at: now)
        #expect(h.backlogStore.decision == .undecided)
        #expect(h.state.signupBacklogHiddenCount == 0)
        #expect(h.listedIDs.contains("canvas:old"), "nothing is withheld in preview")
    }

    @Test("a student who previewed first is still a new student when they sign in for real")
    func previewThenRealSignIn() throws {
        var h = try Harness()
        defer { h.tearDown() }
        let now = Date()

        // Preview, including the one thing that could leak a sample row onto the
        // ledger: a completion recorded against a sample id.
        h.state.forceFixtureDataForTesting(true)
        h.state.canvasItems = SampleData.items(now: now).map(\.assignment)
        h.state.rebuildDashboardItemsForTesting(now: now)
        let sample = try #require(SampleData.items(now: now).first?.assignment)
        h.store.setCompleted(ids: [sample.id], at: now, prototypes: [sample])
        #expect(h.store.holdsFeedRows(), "the leaked sample row is on the ledger")

        // What `restartOnboarding` does on the way out of preview: fixture mode
        // ends, the samples leave memory, the dashboard rebuilds. That rebuild
        // has empty pools and must decide nothing.
        h.state.forceFixtureDataForTesting(nil)
        h.state.canvasItems = []
        h.state.rebuildDashboardItemsForTesting(now: now)
        #expect(h.backlogStore.decision == .undecided)

        // The app is relaunched before the student signs in: `init` finds a feed
        // row on the ledger, but it is a sample, and is ignored.
        h.relaunch()
        #expect(h.backlogStore.decision == .undecided)

        // Signing in for real.
        let old = item("real-old", "Real old work", daysFromSignup: -10, from: now)
        let recent = item("real-new", "Real recent work", daysFromSignup: -1, from: now)
        h.syncCanvas([old, recent], at: now)

        expectCutoff(h.backlogStore.decision, isSevenDaysBefore: now)
        #expect(h.listedIDs == [recent.id])
    }

    // MARK: Test isolation

    @Test("an AppState that did not opt in takes no decision and hides nothing")
    func anAppStateThatDidNotOptInTakesNoDecision() throws {
        // A ledger that already holds a feed row, so the existing-install check
        // would have something to record, and a sync that would otherwise be a
        // sign-up.
        let store = try AssignmentStore(inMemory: true)
        let now = Date()
        let ancient = item("ancient", "Very old work", daysFromSignup: -45, from: now)
        _ = store.reconcile([item("earlier", "Earlier work", daysFromSignup: -50, from: now)], source: .canvas)
        let state = AppState(assignmentStore: store)

        state.canvasItems = store.reconcile([ancient], source: .canvas).items
        state.rebuildDashboardItemsForTesting(now: now)

        #expect((state.assignments + state.awaitingCanvasCheck).contains { $0.id == ancient.id },
                "a fixture 45 days overdue is still listed")
        #expect(state.signupBacklogHiddenCount == 0)
        #expect(UserDefaults.lhf.object(forKey: SharedDefaults.signupBacklogCutoffKey) == nil)
        #expect(UserDefaults.lhf.object(forKey: SharedDefaults.signupBacklogSeenKey) == nil)
    }

    @Test("nothing in this file wrote the shared domain")
    func neverWritesTheSharedDomain() {
        #expect(UserDefaults.lhf.object(forKey: SharedDefaults.signupBacklogCutoffKey) == nil)
        #expect(UserDefaults.lhf.object(forKey: SharedDefaults.signupBacklogRevealedKey) == nil)
        #expect(UserDefaults.lhf.object(forKey: SharedDefaults.signupBacklogSeenKey) == nil)
    }
}

/// The words on the prev tab's line. Pure, so no view is rendered.
@Suite("Sign-up backlog: the prev tab's line")
struct SignupBacklogCopyTests {
    @Test("hidden: a count and two words, singular and plural alike")
    func hiddenWording() {
        #expect(SignupBacklogCopy.line(count: 1, revealed: false) == "1 older hidden")
        #expect(SignupBacklogCopy.line(count: 2, revealed: false) == "2 older hidden")
        #expect(SignupBacklogCopy.line(count: 14, revealed: false) == "14 older hidden")
    }

    @Test("shown: the line reads as a state, not a count")
    func shownWording() {
        #expect(SignupBacklogCopy.line(count: 1, revealed: true) == "older shown")
        #expect(SignupBacklogCopy.line(count: 5, revealed: true) == "older shown")
    }

    @Test("buttons are lowercase and say what a tap does")
    func buttons() {
        #expect(SignupBacklogCopy.buttonTitle(revealed: false) == "show")
        #expect(SignupBacklogCopy.buttonTitle(revealed: true) == "hide")
    }

    @Test("VoiceOver keeps the full sentence, singular and plural handled")
    func accessibilityWording() {
        #expect(SignupBacklogCopy.accessibilityLabel(revealed: false)
                == "show older assignments from before you joined")
        #expect(SignupBacklogCopy.accessibilityLabel(revealed: true)
                == "hide older assignments from before you joined")
        #expect(SignupBacklogCopy.accessibilityLine(count: 1, revealed: false)
                == "1 older assignment from before you joined is hidden")
        #expect(SignupBacklogCopy.accessibilityLine(count: 14, revealed: false)
                == "14 older assignments from before you joined are hidden")
        #expect(SignupBacklogCopy.accessibilityLine(count: 1, revealed: true)
                == "showing an older assignment from before you joined")
        #expect(SignupBacklogCopy.accessibilityLine(count: 5, revealed: true)
                == "showing older assignments from before you joined")
    }
}
