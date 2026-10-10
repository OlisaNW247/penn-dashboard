import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// The sign-up backlog through a real `AppState`: the decision taken at the
/// first feed reconcile, and the filter in `rebuildDashboardItems` that applies
/// it. The pure rule and its storage are in `SignupBacklogTests`.
///
/// **How this stays out of the shared domain.** The decision key, once written
/// to `UserDefaults.lhf`, would be read by the `AppState.init` of every suite
/// running alongside this one, and a cutoff would then hide the 45-to-90-day-old
/// fixtures that other suites feed into fresh ledgers on purpose (the
/// shared-defaults trap in CLAUDE.md). So under the test runner an `AppState`
/// takes no decision and hides nothing unless it is handed a scratch suite with
/// `enableSignupBacklogForTesting(defaults:)`; every state in this file is, and
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
/// blob, the onboarding flag), the Keychain, or the course-preferences blob,
/// which is exactly what the seam exists to avoid. The "reconnect" case is
/// `store.purge(source:)` followed by a second ingest, which is what a
/// disconnect-and-reconnect does to the ledger; the decision lives only in
/// `SignupBacklogStore`, which none of those paths touches.
@MainActor
@Suite("Sign-up backlog: the dashboard")
struct SignupBacklogDashboardTests {
    private static let course = "SIGNUP 0001"
    /// A second course, so a Canvas item and a Gradescope item in one test are
    /// never paired by `AssignmentDeduplicator` (which only merges within one).
    private static let otherCourse = "SIGNUP 0002"
    static let coursePrefix = "SIGNUP "

    /// One `AppState` over a fresh in-memory ledger, opted in to a scratch suite.
    @MainActor
    private struct Harness {
        let state: AppState
        let store: AssignmentStore
        let defaults: UserDefaults
        private let suite: String

        init(ledger: [Assignment] = []) throws {
            suite = "lhf.signup-backlog-dashboard.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suite)!
            store = try AssignmentStore(inMemory: true)
            if !ledger.isEmpty { _ = store.reconcile(ledger, source: .canvas) }
            state = AppState(assignmentStore: store)
            state.enableSignupBacklogForTesting(defaults: defaults)
        }

        func tearDown() {
            defaults.removePersistentDomain(forName: suite)
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

        h.state.ingestCanvasFeed([old, recent, ahead, farAhead], now: now)
        h.state.rebuildDashboardItemsForTesting()

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

        h.state.ingestGradescopeFeed([old, recent], now: now)
        h.state.rebuildDashboardItemsForTesting()

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

        h.state.ingestCanvasFeed([done, open], now: now)
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

        h.state.ingestCanvasFeed([feed], now: now)
        h.state.canvasItems.append(mine)
        h.state.rebuildDashboardItemsForTesting()

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

        h.state.ingestCanvasFeed([undated], now: now)
        h.state.rebuildDashboardItemsForTesting()

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
        h.state.ingestCanvasFeed([oldCanvas, recentCanvas], now: now)
        h.state.ingestGradescopeFeed([oldGradescope, recentGradescope], now: now)
        h.state.rebuildDashboardItemsForTesting()
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
        let h = try Harness()
        defer { h.tearDown() }
        let now = Date()
        h.state.ingestCanvasFeed([item("old", "Old", daysFromSignup: -12, from: now)], now: now)
        h.state.setSignupBacklogRevealed(true)

        // A second AppState over the same ledger and the same scratch defaults.
        let relaunched = AppState(assignmentStore: h.store)
        relaunched.enableSignupBacklogForTesting(defaults: h.defaults)
        #expect(relaunched.signupBacklogRevealed)
    }

    @Test("ask is given the same pool as the dashboard, on both paths, and gets the rest back on show")
    func assistantAgreesWithTheDashboard() throws {
        let h = try Harness()
        defer { h.tearDown() }
        let now = Date()
        let old = item("old-10", "Withheld from ask", daysFromSignup: -10, from: now)
        let recent = item("recent-1", "Offered to ask", daysFromSignup: -1, from: now)
        h.state.ingestCanvasFeed([old, recent], now: now)
        h.state.rebuildDashboardItemsForTesting()

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

    // MARK: Who the decision applies to

    @Test("an existing install updating to this build sees no change at all")
    func existingInstallHidesNothing() throws {
        let now = Date()
        let old = item("old-40", "Very old", daysFromSignup: -40, from: now)
        let older = item("old-9", "Old", daysFromSignup: -9, from: now)
        // The ledger already holds feed rows when this build first syncs.
        let h = try Harness(ledger: [old, older])
        defer { h.tearDown() }

        // Before any sync: undecided, so nothing is hidden.
        #expect(h.state.signupBacklogHiddenCount == 0)
        #expect(h.listedIDs == [old.id, older.id])

        h.state.ingestCanvasFeed([old, older], now: now)
        h.state.rebuildDashboardItemsForTesting()

        #expect(h.backlogStore.decision == .noCutoff)
        #expect(h.listedIDs == [old.id, older.id])
        #expect(h.state.signupBacklogHiddenCount == 0)
    }

    @Test("an install whose ledger holds only hidden completion rows is still an existing install")
    func completionOnlyRowsMakeAnExistingInstall() throws {
        let h = try Harness()
        defer { h.tearDown() }
        let now = Date()
        h.store.setCompleted(ids: ["canvas:ticked-off-before-this-build"], at: now)

        h.state.ingestCanvasFeed([item("old", "Old", daysFromSignup: -20, from: now)], now: now)

        #expect(h.backlogStore.decision == .noCutoff)
    }

    @Test("the decision is taken once: later syncs, a reconnect and the other feed cannot move it")
    func decisionIsStable() throws {
        let h = try Harness()
        defer { h.tearDown() }
        let signup = Date()
        let old = item("old", "Old", daysFromSignup: -10, from: signup)
        h.state.ingestCanvasFeed([old], now: signup)
        let decided = h.backlogStore.decision
        expectCutoff(decided, isSevenDaysBefore: signup)

        // A later sync, a month on.
        let later = signup.addingTimeInterval(30 * 86_400)
        h.state.ingestCanvasFeed([old], now: later)
        #expect(h.backlogStore.decision == decided)

        // Disconnect purges the source's rows; reconnecting syncs into an
        // empty ledger, which on its own would look like a new student.
        h.store.purge(source: .canvas)
        h.state.ingestCanvasFeed([old], now: later.addingTimeInterval(86_400))
        #expect(h.backlogStore.decision == decided)

        // Connecting Gradescope afterwards is another first arrival for that
        // feed, and must not move the cutoff either.
        h.state.ingestGradescopeFeed([], now: later.addingTimeInterval(2 * 86_400))
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
        h.state.rebuildDashboardItemsForTesting()
        #expect(h.store.rowCount() == 0, "preview writes nothing to the ledger")
        #expect(h.state.signupBacklogHiddenCount == 0)

        // Even a reconcile that arrives while fixture data is on takes no decision.
        h.state.ingestCanvasFeed([item("old", "Old", daysFromSignup: -20, from: now)], now: now)
        #expect(h.backlogStore.decision == .undecided)
        h.state.rebuildDashboardItemsForTesting()
        #expect(h.state.signupBacklogHiddenCount == 0)
        #expect(h.listedIDs.contains("canvas:old"), "nothing is withheld in preview")
    }

    @Test("a student who previewed first is still a new student when they sign in for real")
    func previewThenRealSignIn() throws {
        let h = try Harness()
        defer { h.tearDown() }
        let now = Date()

        // Preview, including the one thing that could leak a sample row onto the
        // ledger: a completion recorded against a sample id.
        h.state.forceFixtureDataForTesting(true)
        h.state.canvasItems = SampleData.items(now: now).map(\.assignment)
        h.state.rebuildDashboardItemsForTesting()
        let sample = try #require(SampleData.items(now: now).first?.assignment)
        h.store.setCompleted(ids: [sample.id], at: now, prototypes: [sample])
        #expect(h.store.holdsFeedRows(), "the leaked sample row is on the ledger")

        // Signing in for real: preview ends, the samples leave memory.
        h.state.forceFixtureDataForTesting(nil)
        h.state.canvasItems = []
        let old = item("real-old", "Real old work", daysFromSignup: -10, from: now)
        let recent = item("real-new", "Real recent work", daysFromSignup: -1, from: now)
        h.state.ingestCanvasFeed([old, recent], now: now)
        h.state.rebuildDashboardItemsForTesting()

        expectCutoff(h.backlogStore.decision, isSevenDaysBefore: now)
        #expect(h.listedIDs == [recent.id])
    }

    // MARK: Test isolation

    @Test("an AppState that did not opt in takes no decision and hides nothing")
    func anAppStateThatDidNotOptInTakesNoDecision() throws {
        let state = AppState(assignmentStore: try AssignmentStore(inMemory: true))
        let now = Date()
        let ancient = item("ancient", "Very old work", daysFromSignup: -45, from: now)

        state.ingestCanvasFeed([ancient], now: now)
        state.rebuildDashboardItemsForTesting()

        #expect((state.assignments + state.awaitingCanvasCheck).contains { $0.id == ancient.id },
                "a fixture 45 days overdue is still listed")
        #expect(state.signupBacklogHiddenCount == 0)
        #expect(UserDefaults.lhf.object(forKey: SharedDefaults.signupBacklogCutoffKey) == nil)
    }

    @Test("nothing in this file wrote the shared domain")
    func neverWritesTheSharedDomain() {
        #expect(UserDefaults.lhf.object(forKey: SharedDefaults.signupBacklogCutoffKey) == nil)
        #expect(UserDefaults.lhf.object(forKey: SharedDefaults.signupBacklogRevealedKey) == nil)
    }
}

/// The words on the prev tab's line. Pure, so no view is rendered.
@Suite("Sign-up backlog: the prev tab's line")
struct SignupBacklogCopyTests {
    @Test("hidden: singular and plural")
    func hiddenWording() {
        #expect(SignupBacklogCopy.line(count: 1, revealed: false)
                == "1 older assignment from before you joined is hidden")
        #expect(SignupBacklogCopy.line(count: 2, revealed: false)
                == "2 older assignments from before you joined are hidden")
        #expect(SignupBacklogCopy.line(count: 14, revealed: false)
                == "14 older assignments from before you joined are hidden")
    }

    @Test("shown: the line reads as a state, not a count")
    func shownWording() {
        #expect(SignupBacklogCopy.line(count: 5, revealed: true)
                == "showing older assignments from before you joined")
        #expect(SignupBacklogCopy.line(count: 1, revealed: true)
                == "showing an older assignment from before you joined")
    }

    @Test("buttons are lowercase and say what a tap does")
    func buttons() {
        #expect(SignupBacklogCopy.buttonTitle(revealed: false) == "show")
        #expect(SignupBacklogCopy.buttonTitle(revealed: true) == "hide")
        #expect(SignupBacklogCopy.accessibilityLabel(revealed: false)
                == "show older assignments from before you joined")
        #expect(SignupBacklogCopy.accessibilityLabel(revealed: true)
                == "hide older assignments from before you joined")
    }
}
