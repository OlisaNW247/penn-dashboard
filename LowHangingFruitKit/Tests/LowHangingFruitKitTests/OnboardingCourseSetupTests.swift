import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// The per-course onboarding walk: one screen per class, offering whatever
/// `CanvasRequirementScanner` found for it and that class's own reminder
/// settings.
///
/// SwiftUI views aren't rendered by `swift test`, so what these pin down is the
/// step's *seam* — the gate deciding whether it runs, the rule deciding where
/// its suggestions come from, and the writes each decision makes. Those are
/// deliberately factored out of the view into `OnboardingCourseSetup` for
/// exactly this reason: a decision that only exists inside a `.task` closure is
/// a decision nothing can check, and the one that matters most here (preview
/// mode never reaching the network) has already shipped broken once, stranding
/// App Store reviewers at the login wall (commit `c999c38`).
///
/// `AppState` and `CoursePreferencesStore` both persist into the process-wide
/// `UserDefaults.lhf`, so every test here restores what it touched — see the
/// note in `PreviewModeTests`.
@MainActor
@Suite("Onboarding course setup")
struct OnboardingCourseSetupTests {

    // MARK: - The gate

    /// A genuine first run: no flags at all. The step is offered.
    @Test("a first run is offered the per-course step")
    func firstRunIsOffered() {
        withFlags(onboarded: nil, courseSetup: nil) { defaults in
            #expect(OnboardingCourseSetup.needsCourseSetup(in: defaults))
        }
    }

    /// The regression this suite exists for, and the sibling of
    /// `IntroFlowTests.reconnectSkipsIntro`. `restartOnboarding()` clears
    /// `hasCompletedOnboarding` to send a student back to the connect
    /// checklist; it must not hand them the whole walk again on the way to
    /// fixing a login.
    @Test("reconnecting from Settings never replays the per-course walk")
    func reconnectDoesNotReplay() {
        withFlags(onboarded: true, courseSetup: nil) { defaults in
            let state = makeState()

            // Completed the walk at some point.
            OnboardingCourseSetup.markCompleted(in: defaults)
            #expect(!OnboardingCourseSetup.needsCourseSetup(in: defaults))

            // Settings → reconnect. This clears `hasCompletedOnboarding`…
            state.restartOnboarding()
            #expect(state.needsOnboarding)
            // …and must leave the course-setup flag alone. The flag lives
            // outside `AppState` precisely so `restartOnboarding()` cannot
            // reach it even by accident.
            #expect(!OnboardingCourseSetup.needsCourseSetup(in: defaults))
        }
    }

    /// Upgrade path — the sibling of `IntroFlowTests.existingUserIsBackfilled`,
    /// and the place where this step's guarantee is deliberately weaker than
    /// the intro's.
    ///
    /// A student who onboarded before this step shipped has no flag. While they
    /// are simply using the app, the derivation reads `hasCompletedOnboarding`
    /// and correctly says "settled". But `restartOnboarding()` clears that very
    /// flag on the way to the checklist, so on *that* screen the derivation
    /// flips and the step is offered.
    ///
    /// The intro avoids this by latching in `AppState.init` — a write that
    /// happens at launch, before any Settings tap can move the input. This step
    /// has no equivalent hook (`AppState` is owned by another workstream), and
    /// on reflection it does not want one: an existing student with six classes
    /// has never once been asked how each should reach them, and offering it is
    /// a feature. What would be unacceptable is *nagging* — being asked again
    /// on every reconnect, forever.
    ///
    /// So the guarantee is "at most once", and it holds structurally rather
    /// than by a flag check: the offer is the primary button, and **both** ways
    /// out of it write the flag — the walk marks on finish or skip, and the
    /// "Skip for now" link beside it marks before completing onboarding. There
    /// is no third exit, so the offer cannot survive being answered.
    @Test("an upgrading student is offered the step at most once, never repeatedly")
    func upgradingStudentIsOfferedOnce() {
        withFlags(onboarded: true, courseSetup: nil) { defaults in
            // Settled while they're just using the app.
            #expect(!OnboardingCourseSetup.needsCourseSetup(in: defaults))

            // A Settings reconnect puts them on the checklist, where the step
            // is offered — once.
            let state = makeState()
            state.restartOnboarding()
            #expect(OnboardingCourseSetup.needsCourseSetup(in: defaults))

            // Answering it either way settles it permanently. This is the
            // "Skip for now" path: the cheapest possible answer.
            OnboardingCourseSetup.markCompleted(in: defaults)
            #expect(!OnboardingCourseSetup.needsCourseSetup(in: defaults))

            // And no later reconnect can bring it back, which is the part that
            // separates "offered once" from "nagged".
            state.completeOnboarding()
            state.restartOnboarding()
            #expect(!OnboardingCourseSetup.needsCourseSetup(in: defaults))
        }
    }

    /// The backfill keys off onboarding specifically — a fresh install with no
    /// keys at all is still a first run and must be offered the step. Without
    /// this the previous test's rule would swallow every new student too.
    @Test("a fresh install with no stored flags is still offered the step")
    func freshInstallIsNotBackfilled() {
        withFlags(onboarded: false, courseSetup: nil) { defaults in
            #expect(OnboardingCourseSetup.needsCourseSetup(in: defaults))
        }
    }

    /// An explicit flag beats the derivation in both directions, so a student
    /// who skipped mid-onboarding (flag written, onboarding not yet finished)
    /// is not re-offered the step on the same screen they just declined it on.
    @Test("skipping mid-onboarding sticks even before onboarding finishes")
    func skipBeforeOnboardingCompletes() {
        withFlags(onboarded: false, courseSetup: nil) { defaults in
            #expect(OnboardingCourseSetup.needsCourseSetup(in: defaults))
            OnboardingCourseSetup.markCompleted(in: defaults)
            #expect(!OnboardingCourseSetup.needsCourseSetup(in: defaults))
        }
    }

    // MARK: - Skipping leaves defaults, not nothing

    /// The load-bearing property of a skip: it must leave every class on
    /// sensible defaults rather than on a half-written record.
    ///
    /// It holds because a skip writes *nothing at all*, and no record is
    /// definitionally the defaults (`CoursePreferences.isDefault`, and the
    /// pruning in `CoursePreferencesStore.commit`). Asserted from both angles —
    /// the store holds no record, *and* the resolved values a skipping student
    /// ends up living with are the ones they'd want: reminders on, lead times
    /// inheriting the global, recurring work on.
    @Test("skipping the walk leaves every class on defaults, not on nothing")
    func skipLeavesDefaults() {
        withCourseState { state, defaults in
            state.canvasItems = [
                assignment(course: "CIS 1210", id: "1"),
                assignment(course: "ECON 1", id: "2"),
            ]
            let courses = state.selectedCourseCodes()
            #expect(courses.count == 2)

            // The skip: mark the step done, touch no preference.
            OnboardingCourseSetup.markCompleted(in: defaults)

            for course in courses {
                // No record was written…
                #expect(state.coursePreferences.byCourseKey[course] == nil)

                // …and the defaults are the ones a student would have chosen.
                let prefs = state.coursePreferences.preferences(for: course)
                #expect(prefs.notificationsEnabled)
                #expect(prefs.nothingToSubmitEnabled)
                // `nil`, not an empty set and not a frozen copy of the global.
                // This is the one that would silently break the global control
                // in Settings if the walk ever seeded values on render.
                #expect(prefs.leadOffsets == nil)
                #expect(
                    prefs.effectiveLeadOffsets(global: LeadOffset.defaults) == LeadOffset.defaults
                )
                #expect(prefs.isSelected)
            }
        }
    }

    /// Looking at a class and leaving it alone is a skip too. The walk binds
    /// every control read-through/write-on-change for this reason: rendering a
    /// screen must not be what commits a preference.
    @Test("a class the student only looks at acquires no record")
    func renderingWritesNothing() {
        withCourseState { state, _ in
            state.canvasItems = [assignment(course: "CIS 1210", id: "1")]
            // Reading everything the walk's controls read.
            let prefs = state.coursePreferences.preferences(for: "CIS 1210")
            _ = prefs.notificationsEnabled
            _ = prefs.nothingToSubmitEnabled
            _ = prefs.leadOffsets
            #expect(state.coursePreferences.byCourseKey["CIS 1210"] == nil)
        }
    }

    // MARK: - What the decisions actually write

    /// Accepting a suggestion turns it into a real `RecurringTask` that
    /// generates dated occurrences — the whole point of the step. The scanner
    /// and `addCanvasSuggestion` have existed since v3; what was missing was
    /// anyone ever reaching them.
    @Test("accepting a suggestion creates the recurring task, with its schedule intact")
    func acceptingCreatesRecurringTask() throws {
        try withCourseState { state, _ in
            let before = state.recurringTasks.count
            let suggestion = CanvasRequirementSuggestion(
                course: "CIS 1210",
                title: "Weekly discussion post",
                weekday: 5,
                hour: 23,
                minute: 59,
                source: .syllabus,
                evidence: "Each week you must post a response by Thursday at 11:59pm"
            )
            state.canvasRequirementSuggestions = [suggestion]

            state.addCanvasSuggestion(suggestion)

            #expect(state.recurringTasks.count == before + 1)
            let task = try #require(state.recurringTasks.last)
            #expect(task.course == "CIS 1210")
            #expect(task.title == "Weekly discussion post")
            // The weekday/time rule survives the hand-off — this is what
            // `upcomingAssignments()` generates occurrences from, so a dropped
            // field here is a task that never comes due.
            #expect(task.weekday == 5)
            #expect(task.hour == 23)
            #expect(task.minute == 59)
            // The origin records that Canvas suggested it rather than the
            // student typing it, and the evidence sentence is kept so the row
            // can still justify itself later in Settings → Tasks.
            #expect(task.origin == .canvasSyllabus)
            #expect(task.evidence == suggestion.evidence)
            // Accepted suggestions leave the pending list.
            #expect(state.canvasRequirementSuggestions.isEmpty)
            // And it actually produces work, rather than a rule that never fires.
            #expect(!task.upcomingAssignments().isEmpty)
        }
    }

    /// Declining one leaves no trace: no task, and the suggestion gone from the
    /// pending list so the next screen doesn't re-offer it.
    @Test("declining a suggestion creates nothing")
    func decliningCreatesNothing() {
        withCourseState { state, _ in
            let before = state.recurringTasks.count
            let suggestion = CanvasRequirementSuggestion(
                course: "CIS 1210",
                title: "Weekly reflection",
                weekday: 1,
                hour: 20,
                minute: 0,
                source: .announcement,
                evidence: "Submit a weekly reflection by Sunday 8pm"
            )
            state.canvasRequirementSuggestions = [suggestion]

            state.dismissCanvasSuggestion(suggestion)

            #expect(state.recurringTasks.count == before)
            #expect(state.canvasRequirementSuggestions.isEmpty)
        }
    }

    /// The per-course notification settings the walk writes, including the one
    /// with a third state. `nil` (inherit) and `[]` (explicitly none) are
    /// different answers to different questions, and the walk offers both — so
    /// they have to round-trip distinctly through the store.
    @Test("the walk's reminder controls write through to CoursePreferences")
    func reminderControlsPersist() {
        withCourseState { state, _ in
            let prefs = state.coursePreferences

            prefs.setNotificationsEnabled("CIS 1210", false)
            #expect(!prefs.notificationsEnabled("CIS 1210"))

            prefs.setNothingToSubmitEnabled("ECON 1", false)
            #expect(!prefs.nothingToSubmitEnabled("ECON 1"))
            // One class's settings never leak into another's.
            #expect(prefs.nothingToSubmitEnabled("CIS 1210"))

            // "Just for this class", seeded from the global.
            prefs.setLeadOffsets("ECON 1", LeadOffset.defaults)
            #expect(prefs.leadOffsets(for: "ECON 1") == LeadOffset.defaults)

            // Deselecting every chip means "no advance reminders for this
            // class" — an empty set, which must NOT be folded back to `nil`, or
            // the student gets handed back the reminders they just turned off.
            prefs.setLeadOffsets("ECON 1", [])
            #expect(prefs.leadOffsets(for: "ECON 1") == [])
            #expect(prefs.effectiveLeadOffsets(for: "ECON 1", global: LeadOffset.defaults) == [])

            // "Use my default" goes back to inheriting, and inheriting tracks
            // the global rather than freezing a copy of it.
            prefs.setLeadOffsets("ECON 1", nil)
            #expect(prefs.leadOffsets(for: "ECON 1") == nil)
            #expect(prefs.effectiveLeadOffsets(for: "ECON 1", global: [.d7]) == [.d7])
        }
    }

    // MARK: - Preview mode

    /// The one that matters most. A reviewer who cannot pass Penn SSO explores
    /// the app with sample data, and this step must not reach for the network
    /// or for a Canvas session they will never have.
    ///
    /// Asserted on the plan rather than by observing traffic, because the plan
    /// is the branch: `.fixtures` is the only case that does not call
    /// `AppState.scanCanvasRequirements`. `isUsingFixtureData` is checked first
    /// and unconditionally, so no combination of the other inputs can route a
    /// demo run into a scan.
    @Test("preview mode never scans, whatever the session looks like")
    func previewNeverScans() {
        #expect(
            OnboardingCourseSetup.suggestionPlan(isUsingFixtureData: true, hasCanvasSession: false)
                == .fixtures
        )
        // Even with cookies lying around from a real login the reviewer's
        // device might have — preview wins.
        #expect(
            OnboardingCourseSetup.suggestionPlan(isUsingFixtureData: true, hasCanvasSession: true)
                == .fixtures
        )
    }

    /// The complement: a real account with a session does scan, or the step
    /// would be decorative for everyone it's actually for.
    @Test("a real account with a Canvas session scans")
    func realAccountScans() {
        #expect(
            OnboardingCourseSetup.suggestionPlan(isUsingFixtureData: false, hasCanvasSession: true)
                == .scan
        )
    }

    /// A student who pasted their calendar feed link instead of logging in
    /// (docs/CANVAS_LOGIN_HARDENING.md item 3b) has no cookies and never will.
    /// They get the walk without the scan — not an error, and not a nag to go
    /// and log in.
    @Test("a feed-link-only student gets the walk without a scan")
    func feedOnlyStudentDoesNotScan() {
        #expect(
            OnboardingCourseSetup.suggestionPlan(isUsingFixtureData: false, hasCanvasSession: false)
                == .noSession
        )
    }

    /// Preview mode must reach this step with classes to walk and suggestions
    /// to show, or the reviewer sees an empty screen — the "two of three tabs
    /// look fine" failure `ProfileTabTests` describes, in a different place.
    @Test("preview mode reaches the step with classes and suggestions")
    func previewHasSomethingToShow() {
        withPreviewMode { state in
            let courses = state.selectedCourseCodes()
            #expect(!courses.isEmpty)

            let suggestions = OnboardingCourseSetup.previewSuggestions(for: courses)
            #expect(!suggestions.isEmpty)
            // Every fixture suggestion belongs to a class the walk will show,
            // or it would be generated and never rendered.
            for suggestion in suggestions {
                #expect(courses.contains(suggestion.course))
                #expect(!suggestion.evidence.isEmpty)
                #expect(!suggestion.title.isEmpty)
            }
            // The demo shows both the "found something" and the "found nothing"
            // outcome, since a syllabus that hasn't been posted is the ordinary
            // week-one case and a demo that only shows the happy path
            // misrepresents the app.
            let coursesWithSuggestions = Set(suggestions.map(\.course))
            #expect(coursesWithSuggestions.count < courses.count)
        }
    }

    /// The fixtures are real `CanvasRequirementSuggestion` values, so a
    /// reviewer who taps "Add it" exercises the same `addCanvasSuggestion` path
    /// a student does — the demo runs the actual code rather than miming it.
    @Test("a reviewer accepting a demo suggestion gets a real recurring task")
    func previewSuggestionsAreAcceptable() throws {
        try withPreviewMode { state in
            let courses = state.selectedCourseCodes()
            let suggestion = try #require(
                OnboardingCourseSetup.previewSuggestions(for: courses).first
            )
            let before = state.recurringTasks.count

            state.addCanvasSuggestion(suggestion)

            #expect(state.recurringTasks.count == before + 1)
            #expect(state.recurringTasks.last?.course == suggestion.course)
        }
    }

    // MARK: - The empty and degraded cases

    /// A class with nothing found renders as a class with nothing found, not as
    /// an error and not as a blank screen. The class list is derived from
    /// calendar-feed items, so a course can be perfectly real here while its
    /// syllabus page is still empty — that is week one, not a failure.
    @Test("a class with zero suggestions is still a class the walk can show")
    func courseWithNoSuggestions() {
        withCourseState { state, _ in
            state.canvasItems = [
                assignment(course: "CIS 1210", id: "1"),
                assignment(course: "MEAM 1010", id: "2"),
            ]
            state.canvasRequirementSuggestions = [
                CanvasRequirementSuggestion(
                    course: "CIS 1210",
                    title: "Weekly discussion post",
                    weekday: 5, hour: 23, minute: 59,
                    source: .syllabus,
                    evidence: "Post weekly by Thursday 11:59pm"
                )
            ]

            // Both classes are walked; only one has anything to offer.
            let courses = state.selectedCourseCodes()
            #expect(courses.contains("CIS 1210"))
            #expect(courses.contains("MEAM 1010"))

            let forEmpty = state.canvasRequirementSuggestions.filter { $0.course == "MEAM 1010" }
            #expect(forEmpty.isEmpty)
            // And it still has settings to offer, so the screen is not a
            // dead end even with nothing found.
            #expect(state.coursePreferences.preferences(for: "MEAM 1010").notificationsEnabled)
        }
    }

    /// A student with no classes at all — week one, before anything has been
    /// posted. The step must not be offered, since a walk through zero classes
    /// is a screen with nothing on it.
    @Test("a student with no classes yet is not offered the walk")
    func noClassesMeansNoWalk() {
        withCourseState { state, _ in
            state.canvasItems = []
            #expect(state.selectedCourseCodes().isEmpty)
        }
    }

    /// The schedule line under each suggestion is what lets a student tell a
    /// good guess from a bad one at a glance, next to the quoted evidence. It
    /// has to name the right day — `weekday` is Foundation's 1-based,
    /// Sunday-first index, and an off-by-one here would quietly mislabel every
    /// suggestion in the app.
    @Test("the schedule line names the weekday the task will actually fire on")
    func scheduleLabelMatchesTheRule() throws {
        let thursday = CanvasRequirementSuggestion(
            course: "CIS 1210", title: "Weekly discussion post",
            weekday: 5, hour: 23, minute: 59,
            source: .syllabus, evidence: "by Thursday at 11:59pm"
        )
        let label = OnboardingCourseSetupPane.scheduleLabel(for: thursday)
        #expect(label.localizedCaseInsensitiveContains("Thursday"))

        let sunday = CanvasRequirementSuggestion(
            course: "ECON 1", title: "Weekly reflection",
            weekday: 1, hour: 20, minute: 0,
            source: .syllabus, evidence: "by Sunday 8pm"
        )
        #expect(
            OnboardingCourseSetupPane.scheduleLabel(for: sunday)
                .localizedCaseInsensitiveContains("Sunday")
        )

        // And the day it names is the day `RecurringTask` actually schedules,
        // which is the only reason the label is worth printing.
        let task = RecurringTask(
            title: thursday.title, course: thursday.course,
            weekday: thursday.weekday, hour: thursday.hour, minute: thursday.minute,
            startDate: Date(), endDate: nil, origin: .canvasSyllabus
        )
        let due = try #require(task.upcomingAssignments().first?.dueAt)
        #expect(Calendar.current.component(.weekday, from: due) == thursday.weekday)
    }

    // MARK: - Helpers

    private func assignment(course: String, id: String) -> Assignment {
        Assignment(source: .canvas, sourceID: id, kind: .assignment,
                   course: course, title: "HW\(id)", dueAt: Date(), url: nil)
    }

    /// Every `AppState` here gets its own in-memory ledger, for the reason
    /// `IntroFlowTests` gives: the default store resolves to the real on-disk
    /// SQLite file on any machine that has actually run the app, and a suite
    /// full of `AppState()` then contends on one file.
    private func makeState() -> AppState {
        AppState(assignmentStore: try? AssignmentStore(inMemory: true))
    }

    /// Runs `body` against a known set of onboarding flags, then puts the real
    /// ones back.
    ///
    /// `UserDefaults.lhf`, never `.standard` — hardcoding the latter is a
    /// mistake this suite's neighbours have already made once, and it fails in
    /// the most confusing possible way: the flags the test sets are simply not
    /// the flags the code reads. `nil` removes a key outright, which is the
    /// state an upgrading user genuinely starts from and is distinct from
    /// `false`.
    private func withFlags(
        onboarded: Bool?,
        courseSetup: Bool?,
        _ body: (UserDefaults) -> Void
    ) {
        let defaults = UserDefaults.lhf
        let keys = [
            OnboardingCourseSetup.onboardingCompletedKey,
            OnboardingCourseSetup.completedKey,
            "isPreviewMode",
        ]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer { restore(saved, in: defaults) }

        defaults.set(false, forKey: "isPreviewMode")
        set(onboarded, forKey: OnboardingCourseSetup.onboardingCompletedKey, in: defaults)
        set(courseSetup, forKey: OnboardingCourseSetup.completedKey, in: defaults)

        body(defaults)
    }

    private func set(_ value: Bool?, forKey key: String, in defaults: UserDefaults) {
        if let value {
            defaults.set(value, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }

    /// A clean slate for per-course state and the step's own flag, restored
    /// afterwards. All of it lives in the process-wide `UserDefaults.lhf`, so
    /// without this a failed assertion would leak a muted class into the
    /// developer's own app and into every later test in the run.
    private func withCourseState(_ body: (AppState, UserDefaults) throws -> Void) rethrows {
        let defaults = UserDefaults.lhf
        let keys = [
            CoursePreferencesStore.storageKey,
            SharedDefaults.hiddenCoursesKey,
            SharedDefaults.deletedCoursesKey,
            SharedDefaults.courseNameOverridesKey,
            OnboardingCourseSetup.completedKey,
            Self.recurringTasksKey,
        ]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer { restore(saved, in: defaults) }
        for key in keys { defaults.removeObject(forKey: key) }

        try body(makeState(), defaults)
    }

    /// Mirrors `PreviewModeTests` and `ProfileTabTests`, including putting the
    /// persisted preview flag back.
    ///
    /// Also restores `recurringTasks`, which those two don't need to: accepting
    /// a demo suggestion writes a real task to `UserDefaults.lhf` like any
    /// other, and leaving one behind would put a phantom weekly reading on the
    /// developer's own dashboard.
    private func withPreviewMode(_ body: (AppState) throws -> Void) rethrows {
        let defaults = UserDefaults.lhf
        let saved = [Self.recurringTasksKey].map { ($0, defaults.object(forKey: $0)) }
        defer { restore(saved, in: defaults) }

        let state = makeState()
        let wasPreview = state.isPreviewMode
        state.enterPreviewMode()
        defer {
            if !wasPreview {
                state.restartOnboarding()
                defaults.set(false, forKey: "isPreviewMode")
            }
        }
        try body(state)
    }

    /// `AppState`'s own key for the recurring-task blob. Private there, so it
    /// is named here rather than reached for — if it ever moves, this is one
    /// line to fix and the failure is a compile-time miss, not a silent leak.
    private static let recurringTasksKey = "recurringTasks"

    private func restore(_ saved: [(String, Any?)], in defaults: UserDefaults) {
        for (key, value) in saved {
            if let value {
                defaults.set(value, forKey: key)
            } else {
                defaults.removeObject(forKey: key)
            }
        }
    }
}
