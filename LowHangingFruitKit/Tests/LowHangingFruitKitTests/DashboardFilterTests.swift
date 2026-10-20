import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

@MainActor
@Suite("Dashboard filtering")
struct DashboardFilterTests {
    private func item(kind: Assignment.Kind, course: String, title: String) -> Assignment {
        Assignment(source: .canvas, sourceID: "\(course)-\(title)", kind: kind,
                   course: course, title: title, dueAt: Date(), url: nil)
    }

    @Test("equal due times keep a deterministic card order")
    func equalDueTimesAreStable() {
        let due = Date(timeIntervalSince1970: 1_800_000_000)
        func dashItem(id: String) -> DashItem {
            DashItem(
                assignment: Assignment(
                    source: .canvas,
                    sourceID: id,
                    kind: .assignment,
                    course: "CIS 1200",
                    title: id,
                    dueAt: due,
                    url: nil
                ),
                dueOverride: nil,
                isCompleted: false,
                completedAt: nil
            )
        }

        let ordered = [dashItem(id: "third"), dashItem(id: "first"), dashItem(id: "second")]
            .sorted(by: DashItem.isOrderedByDueDate)

        #expect(ordered.map(\.assignment.sourceID) == ["first", "second", "third"])
    }

    @Test("course-less holidays are never treated as assessments")
    func holidaysAreNotAssessments() {
        // The exact shape that leaked onto the dashboard before the fix.
        #expect(!AppState.isAssessment(item(kind: .event, course: "(unknown course)",
                                            title: "Rosh Hashanah no exams")))
        #expect(!AppState.isAssessment(item(kind: .other, course: "(unknown course)",
                                            title: "Fall Break — no classes")))
        #expect(!AppState.isAssessment(item(kind: .event, course: "(unknown course)",
                                            title: "Reading Days (no final exams)")))
    }

    @Test("real course assessments still surface")
    func realAssessmentsSurface() {
        #expect(AppState.isAssessment(item(kind: .quiz, course: "CIS 1200", title: "Quiz 2")))
        // An exam professors upload as a calendar event, but that belongs to a course.
        #expect(AppState.isAssessment(item(kind: .event, course: "CIS 1200", title: "Midterm 1")))
        // Plain coursework is not an assessment (it's shown as a regular assignment).
        #expect(!AppState.isAssessment(item(kind: .assignment, course: "CIS 1200", title: "Homework 3")))
    }

    @Test("overdue by more than a week still surfaces (no near/later gap)")
    func farOverdueStillSurfaces() {
        let now = Date()
        let farOverdue = Assignment(source: .canvas, sourceID: "old", kind: .assignment,
                                    course: "CIS 1200", title: "PSet 1",
                                    dueAt: now.addingTimeInterval(-14 * 86_400), url: nil)
        // Near/later must partition the pool completely: an item overdue by two
        // weeks belongs to "near", not to a gap between the two buckets.
        #expect(AppState.isNearOrOverdue(farOverdue, now: now))
        #expect(!AppState.isTooOld(farOverdue, now: now))
    }

    @Test("term cap hides next-term work but never near-term or undated work")
    func termCapBounds() {
        let now = Date()
        func due(_ d: Double) -> Assignment {
            Assignment(source: .canvas, sourceID: "\(d)", kind: .assignment, course: "CIS 1200",
                       title: "HW", dueAt: now.addingTimeInterval(d * 86_400), url: nil)
        }
        let undated = Assignment(source: .canvas, sourceID: "u", kind: .assignment,
                                 course: "CIS 1200", title: "HW", dueAt: nil, url: nil)

        #expect(AppState.withinTermCap(due(3), now: now))       // this week — always safe
        #expect(AppState.withinTermCap(undated, now: now))      // undated — always passes
        #expect(AppState.withinTermCap(due(-5), now: now))      // overdue — always passes
        // A year out is definitively beyond the current term.
        #expect(!AppState.withinTermCap(due(365), now: now))
    }

    @Test("term-tagged items: a future term is capped out, current/past kept")
    func termMembershipCap() {
        func item(term: Term) -> Assignment {
            Assignment(source: .canvas, sourceID: "t\(term.year)", kind: .assignment, course: "CIS 1200",
                       title: "HW", dueAt: Date().addingTimeInterval(3 * 86_400), url: nil, term: term)
        }
        // A far-future term is definitely after the current one → excluded.
        #expect(!AppState.withinTermCap(item(term: Term(year: 2099, season: .fall))))
        // A past term passes the cap (its age is handled by isTooOld / the picker).
        #expect(AppState.withinTermCap(item(term: Term(year: 2000, season: .spring))))
    }

    @Test("expired events: a dated .event expires the moment its due time passes, not at end of day")
    func expiredEventBoundaries() {
        let calendar = Calendar.current
        let now = Date()
        // A class that started minutes ago, same calendar day. Under the old
        // day-granularity rule this stayed OVERDUE until midnight — exactly
        // the "1h late" the owner's device pass caught. It must expire
        // immediately now.
        let minutesAgoSameDay = now.addingTimeInterval(-90 * 60)
        // Symmetric case a moment in the future, same day: still not expired.
        let minutesFromNowSameDay = now.addingTimeInterval(90 * 60)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now)!
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now)!

        func dated(kind: Assignment.Kind, dueAt: Date?) -> Assignment {
            Assignment(source: .canvas, sourceID: "x", kind: kind, course: "CIS 1200",
                       title: "Reading", dueAt: dueAt, url: nil)
        }

        #expect(AppState.isExpired(dated(kind: .event, dueAt: minutesAgoSameDay), now: now))
        #expect(AppState.isExpired(dated(kind: .event, dueAt: yesterday), now: now))
        #expect(!AppState.isExpired(dated(kind: .event, dueAt: minutesFromNowSameDay), now: now))
        #expect(!AppState.isExpired(dated(kind: .event, dueAt: tomorrow), now: now))
        #expect(!AppState.isExpired(dated(kind: .event, dueAt: nil), now: now))
        // A last-week assignment has something to submit, so it's overdue, not expired.
        let lastWeek = calendar.date(byAdding: .day, value: -7, to: now)!
        #expect(!AppState.isExpired(dated(kind: .assignment, dueAt: lastWeek), now: now))
    }

    // Rewritten 2026-10-20 in the merge of the two lines of work. The owner's
    // rule of 2026-10-19 ("an announcement or Ed task disappears at its due
    // time and is never overdue") used to live in `isExpired`; the other line
    // had written it as `isHiddenAnnouncementTask` (which also judges same-day
    // reminders and undated tasks), so the announcement half of `isExpired`
    // was removed and this test asks the one rule that remains. The cases are
    // the same; `isExpired` is now pinned to be the `.event` rule alone.
    @Test("expired announcement finds: a dated .canvasAnnouncement item of any kind is hidden at its due time; real Canvas and Gradescope work and the student's own tasks never are")
    func expiredAnnouncementFindBoundaries() {
        let now = Date()
        func make(_ source: Assignment.Source, kind: Assignment.Kind = .assignment, dueAt: Date?) -> Assignment {
            Assignment(source: source, sourceID: "x", kind: kind, course: "CIS 1200",
                       title: "Submit the form", dueAt: dueAt, url: nil)
        }
        func hidden(_ item: Assignment) -> Bool {
            AppState.isHiddenAnnouncementTask(item, dueAt: item.dueAt, postedAt: nil, now: now)
        }
        let aMinuteAgo = now.addingTimeInterval(-60)
        let anHourFromNow = now.addingTimeInterval(3600)

        #expect(hidden(make(.canvasAnnouncement, dueAt: aMinuteAgo)))
        #expect(hidden(make(.canvasAnnouncement, kind: .quiz, dueAt: aMinuteAgo)))
        #expect(!hidden(make(.canvasAnnouncement, dueAt: anHourFromNow)))
        #expect(!hidden(make(.canvasAnnouncement, dueAt: nil)), "an undated find with no post date is never hidden")
        // Ed finds carry the same source, so they are covered by the same line.
        let ed = Assignment(source: .canvasAnnouncement,
                            sourceID: AnnouncementRecord.edFindSourceID(courseID: "9401", threadID: "55", index: 0),
                            kind: .assignment, course: "CIS 1200", title: "Sign up", dueAt: aMinuteAgo, url: nil)
        #expect(hidden(ed))
        // Everything else with something to hand in keeps its overdue behaviour.
        for source in [Assignment.Source.canvas, .canvasModules, .gradescope, .manual] {
            #expect(!hidden(make(source, dueAt: aMinuteAgo)), "\(source) stays overdue")
            #expect(!AppState.isExpired(make(source, dueAt: aMinuteAgo), now: now), "\(source) stays overdue")
        }
        // `isExpired` is the `.event` rule alone: the announcement half is
        // `isHiddenAnnouncementTask`'s, so the two never both apply.
        #expect(!AppState.isExpired(make(.canvasAnnouncement, dueAt: aMinuteAgo), now: now))
        // And an `.event` that is itself an announcement task (a "bring a
        // form" task, a syllabus exam) is left to the announcement rule too,
        // so exactly one of the two judges it.
        let prepTask = make(.canvasAnnouncement, kind: .event, dueAt: aMinuteAgo)
        #expect(!AppState.isExpired(prepTask, now: now))
        #expect(hidden(prepTask))
    }

    @Test("deselecting a course hides it; everything is selected by default")
    func courseSelection() {
        let state = AppState()
        state.hiddenCourseKeys.forEach { state.setCourse($0, selected: true) }  // clean slate

        #expect(state.isCourseSelected("CIS 1200"))    // default: on
        state.setCourse("CIS 1200", selected: false)
        #expect(!state.isCourseSelected("CIS 1200"))
        #expect(state.isCourseSelected("MATH 1400"))   // unrelated course unaffected
        state.setCourse("CIS 1200", selected: true)
        #expect(state.isCourseSelected("CIS 1200"))
    }

    @Test("deleting a course drops it from the classes list and hides it like a toggle-off; restore undoes both")
    func courseDeletionAndRestore() {
        let state = AppState()
        // Clean slate: undo any deletions/hides a prior run left behind.
        state.deletedCourseCodes().forEach { state.restoreCourse($0) }
        state.hiddenCourseKeys.forEach { state.setCourse($0, selected: true) }

        state.canvasItems = [
            Assignment(source: .canvas, sourceID: "1", kind: .assignment,
                       course: "CIS 1200", title: "HW1", dueAt: Date(), url: nil),
            Assignment(source: .canvas, sourceID: "2", kind: .assignment,
                       course: "MATH 1400", title: "HW1", dueAt: Date(), url: nil),
        ]

        #expect(!state.isCourseDeleted("CIS 1200"))
        #expect(state.visibleCourseCodes().contains("CIS 1200"))

        state.deleteCourse("CIS 1200")

        // Deleted: gone from the classes list, excluded like a hidden course,
        // and listed for restore.
        #expect(state.isCourseDeleted("CIS 1200"))
        #expect(!state.visibleCourseCodes().contains("CIS 1200"))
        #expect(!state.isCourseSelected("CIS 1200"))
        #expect(state.deletedCourseCodes() == ["CIS 1200"])
        // Unrelated course is untouched.
        #expect(state.visibleCourseCodes().contains("MATH 1400"))
        #expect(state.isCourseSelected("MATH 1400"))

        // Persisted: a fresh AppState instance (reading the same UserDefaults)
        // still sees it deleted.
        let reloaded = AppState()
        #expect(reloaded.isCourseDeleted("CIS 1200"))

        state.restoreCourse("CIS 1200")

        #expect(!state.isCourseDeleted("CIS 1200"))
        #expect(state.visibleCourseCodes().contains("CIS 1200"))
        #expect(state.isCourseSelected("CIS 1200"))
        #expect(state.deletedCourseCodes().isEmpty)
    }
}

/// The owner's rule (2026-10-19): a task the Announcement Watcher found, in a
/// Canvas announcement or an Ed post, disappears at its due time and is never
/// overdue. These go through a real `AppState` and `DashboardViewModel`, because
/// the rule has to hold in todo, all, the megaphone's finds, the assessments
/// bucket, the widget snapshot and the assistant's pool, and a pure test of
/// the rule (`isHiddenAnnouncementTask` since the 2026-10-20 merge; it was
/// `isExpired`) cannot see a list that forgot to call it.
///
/// **Hermetic setup.** The announcement rows are put on the ledger and read back
/// by a second `AppState` over the same in-memory store, the way a relaunch
/// reads them (`announcementItems` is `private(set)`). The first `AppState` runs
/// the one-time extraction repair on an empty ledger and so claims the version
/// before there is anything for it to purge; seeding the rows before any
/// `AppState` existed would let that repair delete them on a machine that has
/// never run the app. Edits go to a scratch suite, as in `DueDateEditTests`.
///
/// **Two clocks.** The dashboard rebuilds take an explicit `now` a day ahead of
/// the real clock, which is how a Canvas item gets past the first-launch
/// submission hold (`submissionHoldWindow`, five minutes from `launchedAt`) with
/// no network. The functions that read `Date()` themselves
/// (`assistantWorkItems`, `widgetNextDueItems`' inputs) are tested with times
/// relative to the real clock instead.
@MainActor
@Suite("Dashboard filtering: announcement finds expire")
struct AnnouncementFindExpiryTests {
    private static let course = "ANNEXP 0001"

    @MainActor
    private struct Harness {
        let state: AppState
        let store: AssignmentStore
        let defaults: UserDefaults
        let suite: String

        init(finds: [Assignment]) throws {
            suite = "lhf.announcement-expiry.\(UUID().uuidString)"
            defaults = UserDefaults(suiteName: suite)!
            store = try AssignmentStore(inMemory: true)
            _ = AppState(assignmentStore: store, dueDateEditsDefaults: defaults)
            store.upsert(finds)
            state = AppState(assignmentStore: store, dueDateEditsDefaults: defaults)
            state.forceFixtureDataForTesting(false)
        }

        func tearDown() { defaults.removePersistentDomain(forName: suite) }

        func rebuild(at now: Date) { state.rebuildDashboardItemsForTesting(now: now) }
    }

    private func find(_ id: String, _ title: String, due: Date?, kind: Assignment.Kind = .assignment) -> Assignment {
        Assignment(source: .canvasAnnouncement, sourceID: id, kind: kind,
                   course: Self.course, title: title, dueAt: due, url: nil)
    }

    private func ids(_ sections: [DashSection]) -> Set<String> {
        Set(sections.flatMap(\.items).map(\.id))
    }

    @Test("a find due one minute ago is not in todo, all, the megaphone's lists or the widget; the same find due in an hour is")
    func pastDueFindVanishes() throws {
        // "Submit ..." files a find on the main dashboard; wording that reads as
        // information ("slides posted") files it in the megaphone's finds
        // (`announcementDashboardPlacement`; since 2026-10-18 a "Read ..." task
        // is a card too, so it no longer stands for the second kind).
        //
        // The four titles share no words on purpose. The rebuild drops an
        // announcement find that looks like another one
        // (`filteringAnnouncementDuplicates`, whose fuzzy tier compares title
        // overlap when the due dates are close), and "Submit the past
        // reflection" beside "Submit the upcoming reflection", an hour apart,
        // read as twins: the later one was dropped as a copy of the earlier and
        // todo and all came back without it. That was not the expiry rule, and
        // the first version of this test blamed it wrongly.
        let now = Date().addingTimeInterval(86_400)
        let pastMain = find("past-main", "Submit geology field report", due: now.addingTimeInterval(-60))
        let soonMain = find("soon-main", "Upload haiku portfolio", due: now.addingTimeInterval(3600))
        let pastFind = find("past-read", "Slides posted for the Beowulf unit", due: now.addingTimeInterval(-60))
        let soonFind = find("soon-read", "Recording available for thermodynamics", due: now.addingTimeInterval(3600))
        let h = try Harness(finds: [pastMain, soonMain, pastFind, soonFind])
        defer { h.tearDown() }
        try #require(h.state.announcementItems.count == 4, "the seeded rows were read back")
        h.rebuild(at: now)

        let vm = DashboardViewModel()
        vm.bind(to: h.state)
        let todo = ids(vm.todoSections(now: now))
        let all = ids(vm.allSections(now: now))
        #expect(!todo.contains(pastMain.id))
        #expect(!all.contains(pastMain.id))
        #expect(todo.contains(soonMain.id))
        #expect(all.contains(soonMain.id))

        // The megaphone judges its lists at display time: the page keeps the
        // past rows (`AnnouncementSheetTests`), the found list and the badge
        // do not show them.
        let found = Set(h.state.announcementFoundItems(now: now).map(\.id))
        #expect(!found.contains(pastMain.id) && !found.contains(pastFind.id))
        #expect(found.contains(soonMain.id))
        #expect(found.contains(soonFind.id))
        #expect(h.state.announcementBadgeCount(now: now) == found.count, "the badge counts exactly what the sheet shows")
        #expect(found.count == 2)

        // Not overdue anywhere: the overdue section holds neither.
        let overdue = Set(vm.todoSections(now: now).filter { $0.id == "overdue" }.flatMap(\.items).map(\.id))
        #expect(overdue.isDisjoint(with: [pastMain.id, pastFind.id]))

        // The ledger still has every row: this is display only.
        #expect(h.store.assignments(source: .canvasAnnouncement).count == 4)
    }

    @Test("a past-due find titled like an exam does not slip through the assessments bucket, but a real Canvas quiz that is overdue still shows")
    func pastDueExamTitledFindVanishes() throws {
        let now = Date().addingTimeInterval(86_400)
        let pastQuiz = find("past-quiz", "Quiz 5 take-home, submit online", due: now.addingTimeInterval(-60))
        let h = try Harness(finds: [pastQuiz])
        defer { h.tearDown() }
        try #require(h.state.announcementItems.count == 1)
        let realQuiz = Assignment(source: .canvas, sourceID: "real-quiz", kind: .quiz, course: Self.course,
                                  title: "Quiz 4", dueAt: now.addingTimeInterval(-60), url: nil)
        h.state.canvasItems = h.store.reconcile([realQuiz], source: .canvas).items
        h.rebuild(at: now)

        #expect(AppState.isAssessment(pastQuiz), "premise: this title lands in the assessments bucket")
        #expect(!h.state.assessments.map(\.id).contains(pastQuiz.id))
        #expect(h.state.assessments.map(\.id).contains(realQuiz.id))
        #expect(!h.state.widgetNextDueItems().contains { $0.title == pastQuiz.title })
    }

    @Test("a real Canvas assignment due one minute ago is still overdue in todo")
    func realCanvasWorkStaysOverdue() throws {
        let now = Date().addingTimeInterval(86_400)
        let pastFind = find("past", "Submit geology field report", due: now.addingTimeInterval(-60))
        let h = try Harness(finds: [pastFind])
        defer { h.tearDown() }
        let late = Assignment(source: .canvas, sourceID: "late", kind: .assignment, course: Self.course,
                              title: "Problem Set 4", dueAt: now.addingTimeInterval(-60), url: nil)
        h.state.canvasItems = h.store.reconcile([late], source: .canvas).items
        h.rebuild(at: now)

        let vm = DashboardViewModel()
        vm.bind(to: h.state)
        let overdue = Set(vm.todoSections(now: now).filter { $0.id == "overdue" }.flatMap(\.items).map(\.id))
        #expect(overdue.contains(late.id))
        #expect(!overdue.contains(pastFind.id))
    }

    @Test("a completed find due yesterday is still in prev, and an unfinished one that passed is not there or anywhere")
    func completedFindStaysInPrev() throws {
        let now = Date().addingTimeInterval(86_400)
        // Disjoint titles, so the twin check cannot drop one of them
        // (`pastDueFindVanishes` explains).
        let done = find("done", "Submit sonnet anthology", due: now.addingTimeInterval(-86_400))
        let neverDone = find("never", "Upload ceramics sketchbook", due: now.addingTimeInterval(-86_400))
        let h = try Harness(finds: [done, neverDone])
        defer { h.tearDown() }
        try #require(h.state.announcementItems.count == 2)
        h.state.markCompleted(done, at: now.addingTimeInterval(-3600))
        h.rebuild(at: now)

        let vm = DashboardViewModel()
        vm.bind(to: h.state)
        // Control: two days earlier, before either was due, the unfinished one
        // is on the dashboard. Without this its absence below could just as
        // well mean it never made it past the rebuild.
        let earlier = now.addingTimeInterval(-2 * 86_400)
        h.rebuild(at: earlier)
        vm.reload()
        #expect(ids(vm.allSections(now: earlier)).contains(neverDone.id), "premise: visible before it is due")
        h.rebuild(at: now)
        vm.reload()
        #expect(ids(vm.doneSections(now: now)).contains(done.id))
        #expect(!ids(vm.doneSections(now: now)).contains(neverDone.id), "an unfinished find never reaches prev")
        #expect(!ids(vm.todoSections(now: now)).contains(done.id))
        #expect(!ids(vm.todoSections(now: now)).contains(neverDone.id))
        #expect(!ids(vm.allSections(now: now)).contains(neverDone.id))
        #expect(h.store.assignments(source: .canvasAnnouncement).count == 2, "nothing was deleted")
    }

    @Test("ask's pools drop a past-due unfinished find but keep a completed one and an upcoming one")
    func askPoolsFollowTheRule() throws {
        let now = Date()
        let past = find("past", "Submit geology field report", due: now.addingTimeInterval(-60))
        let soon = find("soon", "Upload haiku portfolio", due: now.addingTimeInterval(3600))
        let done = find("done", "Submit sonnet anthology", due: now.addingTimeInterval(-86_400))
        let h = try Harness(finds: [past, soon, done])
        defer { h.tearDown() }
        try #require(h.state.announcementItems.count == 3)
        // `allCourseCodes()` is built from the Canvas, Gradescope and module
        // pools only, so the context document has no section for a class that
        // exists only as announcement finds; a Canvas row puts the class in.
        let anchor = Assignment(source: .canvas, sourceID: "anchor", kind: .assignment, course: Self.course,
                                title: "Anchor homework", dueAt: now.addingTimeInterval(7 * 86_400), url: nil)
        h.state.canvasItems = h.store.reconcile([anchor], source: .canvas).items
        h.state.markCompleted(done, at: now.addingTimeInterval(-3600))

        let open = Set(h.state.announcementItemsStillOpen(now: now).map(\.id))
        #expect(open == [soon.id, done.id])

        let work = Set(h.state.assistantWorkItems().map(\.id))
        #expect(!work.contains(past.id))
        #expect(work.contains(soon.id))
        let document = h.state.assistantContextDocument()
        #expect(document.contains("Upload haiku portfolio"), "premise: the document does list this class's work")
        #expect(!document.contains("Submit geology field report"))
    }
}
