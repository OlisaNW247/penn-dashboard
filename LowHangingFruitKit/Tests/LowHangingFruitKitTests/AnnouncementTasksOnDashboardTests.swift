import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// Tasks found in announcements (Canvas and Ed) as dashboard cards, and what
/// happens to them once their date has passed.
///
/// The rules under test, all from the owner (2026-10-18):
///
///  - every task found in an announcement, submission or preparation, is a card
///    for a class whose "announcements on dashboard" switch is on (the default);
///  - wording that only reports something done stays off the dashboard;
///  - a task whose date has passed and that is not finished is on the
///    dashboard nowhere (not todo, not all, not prev); a finished one stays in
///    prev like any finished work; ordinary Canvas, Gradescope and manual work
///    does not change (the rest of the rules, undated tasks and same-day
///    reminders, are in `AnnouncementTaskRulesTests`);
///  - the same task announced on Canvas and on Ed, or already a Canvas
///    assignment, is one card, and a tick carries to the card that is shown.
///
/// **Hermeticity.** Rows are seeded straight into an in-memory ledger, so
/// there is no network and no sync. Each test's class code is unique to this
/// suite, and every shared preference a test flips (the per-class switches,
/// the extraction-repair version) is put back. The suite is `.serialized` for
/// the same reason the other announcement suites are.
@MainActor
@Suite("Announcement tasks on the dashboard", .serialized)
struct AnnouncementTasksOnDashboardTests {
    private static let hour: TimeInterval = 3600
    private static let day: TimeInterval = 24 * 3600
    private static let extractionVersionKey = "announcementExtractionVersionV1"
    private static let processedKey = "processedAnnouncementIDsV1"

    // MARK: Fixtures

    /// Pins the extraction-repair version so `AppState.init`'s one-time sweep
    /// does not purge the seeded rows, and puts the shared keys back.
    private func withPinnedDefaults(_ body: () throws -> Void) rethrows {
        let defaults = UserDefaults.lhf
        let keys = [Self.extractionVersionKey, Self.processedKey]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.set(2, forKey: Self.extractionVersionKey)
        defaults.removeObject(forKey: Self.processedKey)
        try body()
    }

    /// A Canvas-announcement find.
    private func canvasFind(
        _ id: String, course: String, title: String, kind: Assignment.Kind = .assignment, due: Date?
    ) -> Assignment {
        Assignment(
            source: .canvasAnnouncement,
            sourceID: AnnouncementRecord.findSourceID(announcementID: id, index: 0),
            kind: kind, course: course, title: title, dueAt: due,
            url: URL(string: "https://canvas.upenn.edu/courses/1/discussion_topics/\(id)")
        )
    }

    /// An Ed find.
    private func edFind(
        _ thread: String, course: String, title: String, kind: Assignment.Kind = .assignment, due: Date?
    ) -> Assignment {
        Assignment(
            source: .canvasAnnouncement,
            sourceID: AnnouncementRecord.edFindSourceID(courseID: "9401", threadID: thread, index: 0),
            kind: kind, course: course, title: title, dueAt: due,
            url: URL(string: "https://edstem.org/us/courses/1/discussion/\(thread)")
        )
    }

    private func makeState(_ seed: [Assignment], dueDateEditsDefaults: UserDefaults? = nil) throws -> AppState {
        let store = try AssignmentStore(inMemory: true)
        store.upsert(seed)
        let state = AppState(assignmentStore: store, dueDateEditsDefaults: dueDateEditsDefaults)
        state.forceFixtureDataForTesting(false)
        state.rebuildDashboardItemsForTesting()
        return state
    }

    private func onDashboard(_ state: AppState) -> [Assignment] {
        state.assignments + state.laterAssignments + state.assessments
    }

    private func titlesOnDashboard(_ state: AppState, course: String) -> Set<String> {
        Set(onDashboard(state).filter { $0.course == course }.map(\.title))
    }

    // MARK: Placement

    @Test("a dated submission task and a dated preparation task are both cards, and neither is a megaphone-only find")
    func bothKindsBecomeCards() throws {
        try withPinnedDefaults {
            let course = "ANTASK 9401"
            let due = Date().addingTimeInterval(Self.day)
            let state = try makeState([
                canvasFind("94010001", course: course, title: "Submit the lab report", due: due),
                canvasFind("94010002", course: course, title: "Read chapter 4 before Friday", kind: .event, due: due),
            ])
            #expect(titlesOnDashboard(state, course: course) == ["Submit the lab report", "Read chapter 4 before Friday"])
            #expect(state.announcementFinds.filter { $0.course == course }.isEmpty)
            // The megaphone still lists both, cards or not.
            #expect(state.announcementPageItems.filter { $0.course == course }.count == 2)
        }
    }

    @Test("the per-class switch governs cards for Canvas and Ed together, and never the megaphone")
    func classSwitchGovernsBothOrigins() throws {
        try withPinnedDefaults {
            let course = "ANTASK 9402"
            let due = Date().addingTimeInterval(Self.day)
            let state = try makeState([
                canvasFind("94020001", course: course, title: "Submit the lab report", due: due),
                edFind("94020002", course: course, title: "Bring a calculator to the exam", kind: .event, due: due),
            ])
            let original = state.coursePreferences.announcementAssignmentsOnDashboard(course)
            defer { state.setAnnouncementAssignmentsOnDashboard(course, original) }

            state.setAnnouncementAssignmentsOnDashboard(course, true)
            #expect(titlesOnDashboard(state, course: course).count == 2)

            state.setAnnouncementAssignmentsOnDashboard(course, false)
            #expect(titlesOnDashboard(state, course: course).isEmpty)
            #expect(state.announcementPageItems.filter { $0.course == course }.count == 2)
        }
    }

    @Test("wording that only reports something done stays off the dashboard, whatever kind it was stored as")
    func informationalWordingStaysOff() throws {
        try withPinnedDefaults {
            let course = "ANTASK 9403"
            let due = Date().addingTimeInterval(Self.day)
            let state = try makeState([
                canvasFind("94030001", course: course, title: "Quiz grades posted", due: due),
                canvasFind("94030002", course: course, title: "Slides have been posted", kind: .event, due: due),
            ])
            #expect(titlesOnDashboard(state, course: course).isEmpty)
            #expect(state.announcementFinds.filter { $0.course == course }.count == 2)
        }
    }

    @Test("an undated task is placed the way the dashboard places any undated item: under later in all, nowhere in todo")
    func undatedTasksSitInLater() throws {
        try withPinnedDefaults {
            let course = "ANTASK 9404"
            let state = try makeState([
                canvasFind("94040001", course: course, title: "Submit the reflection", due: nil),
                edFind("94040002", course: course, title: "Review the style guide", kind: .event, due: nil),
            ])
            #expect(state.laterAssignments.filter { $0.course == course }.count == 2)
            #expect(state.assignments.filter { $0.course == course }.isEmpty)

            let vm = DashboardViewModel()
            vm.bind(to: state)
            let all = vm.allSections().first { $0.id == "later" }
            #expect(all?.items.filter { $0.assignment.course == course }.count == 2)
            #expect(vm.todoSections().flatMap(\.items).filter { $0.assignment.course == course }.isEmpty)
        }
    }

    @Test("a preparation task is hidden by the class's nothing-to-submit switch; a submission task is not")
    func nothingToSubmitSwitchStillApplies() throws {
        try withPinnedDefaults {
            let course = "ANTASK 9405"
            let due = Date().addingTimeInterval(Self.day)
            let state = try makeState([
                canvasFind("94050001", course: course, title: "Submit the lab report", due: due),
                canvasFind("94050002", course: course, title: "Read chapter 4 before Friday", kind: .event, due: due),
            ])
            let original = state.coursePreferences.nothingToSubmitEnabled(course)
            defer { state.setNothingToSubmitEnabled(course, original) }

            state.setNothingToSubmitEnabled(course, false)
            #expect(titlesOnDashboard(state, course: course) == ["Submit the lab report"])
            state.setNothingToSubmitEnabled(course, true)
            #expect(titlesOnDashboard(state, course: course).count == 2)
        }
    }

    // MARK: Past tasks

    @Test("the rule: dated and in the past, announcement-derived, unmerged, is hidden; nothing else is")
    func pastRule() {
        let now = Date()
        let past = now.addingTimeInterval(-Self.hour)
        let future = now.addingTimeInterval(Self.hour)
        func item(_ source: Assignment.Source, linked: String? = nil) -> Assignment {
            Assignment(source: source, sourceID: "x-1", kind: .assignment, course: "ANTASK 9400",
                       title: "T", dueAt: past, url: nil, linkedID: linked)
        }
        func hidden(_ item: Assignment, due: Date?) -> Bool {
            AppState.isHiddenAnnouncementTask(item, dueAt: due, postedAt: nil, now: now)
        }
        #expect(hidden(item(.canvasAnnouncement), due: past))
        #expect(!hidden(item(.canvasAnnouncement), due: future))
        // No date and no post date: nothing to age it by, so it stays.
        #expect(!hidden(item(.canvasAnnouncement), due: nil))
        #expect(!hidden(item(.canvasAnnouncement, linked: "gradescope:1"), due: past))
        for source in [Assignment.Source.canvas, .gradescope, .manual, .canvasModules, .canvasSuggestion] {
            #expect(!hidden(item(source), due: past))
        }
    }

    @Test("a past announcement task is on the dashboard nowhere: not todo, not all, not prev; ordinary work is untouched, and the ledger keeps the row")
    func pastTasksDropOff() throws {
        try withPinnedDefaults {
            let course = "ANTASK 9406"
            let now = Date()
            let past = now.addingTimeInterval(-2 * Self.hour)
            let future = now.addingTimeInterval(Self.day)
            let gradescopeOverdue = Assignment(
                source: .gradescope, sourceID: "antask-9406-g1", kind: .assignment, course: course,
                title: "Problem set that is overdue", dueAt: past, url: nil
            )
            let state = try makeState([
                canvasFind("94060001", course: course, title: "Submit the lab report", due: past),
                edFind("94060002", course: course, title: "Bring a calculator to the exam", kind: .event, due: past),
                canvasFind("94060003", course: course, title: "Upload the cartography memo", due: future),
            ])
            state.gradescopeItems = [gradescopeOverdue]
            state.rebuildDashboardItemsForTesting(now: now)

            #expect(titlesOnDashboard(state, course: course) == ["Upload the cartography memo", "Problem set that is overdue"])

            let vm = DashboardViewModel()
            vm.bind(to: state)
            let mine: (DashItem) -> Bool = { $0.assignment.course == course }
            #expect(vm.items.filter(mine).count == 2)
            let todoTitles = Set(vm.todoSections().flatMap(\.items).filter(mine).map(\.assignment.title))
            let allTitles = Set(vm.allSections().flatMap(\.items).filter(mine).map(\.assignment.title))
            for gone in ["Submit the lab report", "Bring a calculator to the exam"] {
                #expect(!todoTitles.contains(gone) && !allTitles.contains(gone))
            }
            // The Gradescope item is still overdue in todo.
            #expect(todoTitles.contains("Problem set that is overdue"))

            // Not in prev either: it was never finished.
            #expect(vm.doneSections(now: now).flatMap(\.items).filter(mine).isEmpty)
            #expect(vm.weeklyProgress(now: now).done == 0)

            // Hidden by a rule, not deleted.
            let rows = try #require(state.assignmentStore).assignments(source: .canvasAnnouncement)
            #expect(rows.filter { $0.course == course }.count == 3)
        }
    }

    @Test("a task drops off when its time passes, and an expired non-announcement event still just vanishes")
    func boundaryAndOrdinaryEvents() throws {
        try withPinnedDefaults {
            let course = "ANTASK 9407"
            let now = Date()
            let due = now.addingTimeInterval(Self.hour)
            let calendarEvent = Assignment(
                source: .canvasModules, sourceID: "antask-9407-m1", kind: .event, course: course,
                title: "Lecture reading", dueAt: due, url: nil
            )
            let state = try makeState([
                canvasFind("94070001", course: course, title: "Submit the lab report", due: due),
            ])
            state.rebuildDashboardItemsForTesting(now: now)
            #expect(titlesOnDashboard(state, course: course) == ["Submit the lab report"])

            state.rebuildDashboardItemsForTesting(now: due.addingTimeInterval(60))
            #expect(titlesOnDashboard(state, course: course).isEmpty)

            // The feed's own event rule is unchanged: gone at its time, listed nowhere.
            #expect(AppState.isExpiredEvent(calendarEvent, now: due.addingTimeInterval(60)))
            #expect(!AppState.isHiddenAnnouncementTask(calendarEvent, dueAt: due, postedAt: nil, now: due.addingTimeInterval(60)))
        }
    }

    @Test("a past task the student finishes is ordinary finished work: it is in prev, and 'down this week'")
    func finishingAPastTask() throws {
        try withPinnedDefaults {
            let course = "ANTASK 9408"
            let past = Date().addingTimeInterval(-2 * Self.hour)
            let task = canvasFind("94080001", course: course, title: "Submit the lab report", due: past)
            let state = try makeState([task])
            defer { state.markActive(task) }

            let vm = DashboardViewModel()
            vm.bind(to: state)
            #expect(vm.doneSections().flatMap(\.items).filter { $0.assignment.course == course }.isEmpty)

            // Finished (say, on a device that had it still live, then synced).
            state.markCompleted(task)
            vm.reload()
            let prev = vm.doneSections().flatMap(\.items).filter { $0.assignment.course == course }
            #expect(prev.map(\.assignment.title) == ["Submit the lab report"])
            #expect(prev.allSatisfy { $0.isCompleted && $0.completedAt != nil })
            #expect(vm.weeklyProgress().done >= 1)
            #expect(titlesOnDashboard(state, course: course).isEmpty)
        }
    }

    @Test("a task finished before its date passed is completed work in prev afterwards")
    func finishedTaskStaysInPrev() throws {
        try withPinnedDefaults {
            let course = "ANTASK 9409"
            let due = Date().addingTimeInterval(Self.hour)
            let task = canvasFind("94090001", course: course, title: "Submit the lab report", due: due)
            let state = try makeState([task])
            defer { state.markActive(task) }
            state.markCompleted(task)

            state.rebuildDashboardItemsForTesting(now: due.addingTimeInterval(Self.hour))
            let vm = DashboardViewModel()
            vm.bind(to: state)
            let prev = vm.doneSections(now: due.addingTimeInterval(Self.hour)).flatMap(\.items)
                .filter { $0.assignment.course == course }
            #expect(prev.count == 1 && prev[0].isCompleted)
        }
    }

    @Test("the student's edited date decides: moving a past task forward brings it back, moving a future one back puts it away")
    func editedDateDecides() throws {
        try withPinnedDefaults {
            let suite = "antask-edits-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }

            let course = "ANTASK 9410"
            let now = Date()
            let past = canvasFind("94100001", course: course, title: "Submit the lab report", due: now.addingTimeInterval(-2 * Self.hour))
            let future = canvasFind("94100002", course: course, title: "Upload the cartography memo", due: now.addingTimeInterval(Self.day))
            let state = try makeState([past, future], dueDateEditsDefaults: defaults)

            #expect(titlesOnDashboard(state, course: course) == ["Upload the cartography memo"])

            state.setDueDateEdit(now.addingTimeInterval(Self.day), for: past)
            state.setDueDateEdit(now.addingTimeInterval(-Self.hour), for: future)
            state.rebuildDashboardItemsForTesting(now: now)

            #expect(titlesOnDashboard(state, course: course) == ["Submit the lab report"])
        }
    }

    // MARK: Duplicates across Canvas, Ed and the feed

    @Test("the same task announced on Canvas and on Ed is one card, the Canvas one, whichever order the ledger returns them")
    func canvasAndEdTwinsAreOneCard() throws {
        try withPinnedDefaults {
            let course = "ANTASK 9411"
            let due = Date().addingTimeInterval(Self.day)
            let canvas = canvasFind("94110001", course: course, title: "Submit Problem Set 3", due: due)
            let ed = edFind("94110002", course: course, title: "Submit Problem Set 3", due: due)

            for seed in [[canvas, ed], [ed, canvas]] {
                let state = try makeState(seed)
                let cards = onDashboard(state).filter { $0.course == course }
                #expect(cards.count == 1)
                #expect(cards.first?.announcementOrigin == .canvas)
            }
        }
    }

    @Test("differently worded copies of one task still collapse, in either direction")
    func differentWordingStillCollapses() {
        let due = Date(timeIntervalSince1970: 1_800_000_000)
        let a = Assignment(source: .canvasAnnouncement, sourceID: "announcement-1-0", kind: .assignment,
                           course: "ANTASK 9412", title: "Submit PS3", dueAt: due, url: nil)
        let b = Assignment(source: .canvasAnnouncement, sourceID: AnnouncementRecord.edFindSourceID(courseID: "1", threadID: "2", index: 0),
                           kind: .assignment, course: "ANTASK 9412", title: "PS3", dueAt: due, url: nil)
        let forward = AppState.resolvingAnnouncementDuplicates([a, b], against: [])
        let backward = AppState.resolvingAnnouncementDuplicates([b, a], against: [])
        #expect(forward.survivors.count == 1 && backward.survivors.count == 1)
        #expect(forward.absorbed.count == 1 && backward.absorbed.count == 1)
    }

    @Test("two different tasks are never merged")
    func differentTasksStayApart() throws {
        try withPinnedDefaults {
            let course = "ANTASK 9413"
            let due = Date().addingTimeInterval(Self.day)
            let state = try makeState([
                canvasFind("94130001", course: course, title: "Submit the lab report", due: due),
                edFind("94130002", course: course, title: "Bring a calculator to the exam", kind: .event, due: due),
            ])
            #expect(titlesOnDashboard(state, course: course).count == 2)
        }
    }

    @Test("an Ed task that is already a Canvas assignment is not a second card, and a tick on it follows onto the assignment")
    func edTaskDuplicatingAFeedItem() throws {
        try withPinnedDefaults {
            let course = "ANTASK 9414"
            let due = Date().addingTimeInterval(Self.day)
            let ed = edFind("94140001", course: course, title: "Take Quiz 2", due: nil)
            let state = try makeState([ed])
            defer { state.markActive(ed) }
            // Alone, the Ed task is a card; the student ticks it off.
            #expect(titlesOnDashboard(state, course: course) == ["Take Quiz 2"])
            state.markCompleted(ed)

            // Later Canvas lists the real quiz.
            let quiz = Assignment(source: .canvas, sourceID: "antask-9414-q2", kind: .quiz, course: course,
                                  title: "Quiz 2", dueAt: due, url: nil)
            defer { state.markActive(quiz) }
            state.canvasItems = [quiz]
            state.rebuildDashboardItemsForTesting()

            #expect(state.mergedCoursework.filter { $0.course == course }.map(\.source) == [.canvas])
            #expect(state.isCompleted(quiz))
        }
    }

    @Test("a tick on the hidden twin follows onto the shown one")
    func tickFollowsSurvivingTwin() throws {
        try withPinnedDefaults {
            let course = "ANTASK 9415"
            let due = Date().addingTimeInterval(Self.day)
            let ed = edFind("94150002", course: course, title: "Submit Problem Set 3", due: due)
            let state = try makeState([ed])
            defer { state.markActive(ed) }
            state.markCompleted(ed)

            // The Canvas copy is extracted afterwards and wins the tie.
            let canvas = canvasFind("94150001", course: course, title: "Submit Problem Set 3", due: due)
            defer { state.markActive(canvas) }
            let store = try #require(state.assignmentStore)
            store.upsert([canvas])
            state.applyAnnouncementLedgerChange()

            #expect(state.isCompleted(canvas))
            #expect(onDashboard(state).filter { $0.course == course }.isEmpty)
        }
    }

    @Test("dedup order: dated before undated, Canvas before Ed, then by id, whatever order they arrive in")
    func dedupOrder() {
        func item(_ sourceID: String, due: Date?) -> Assignment {
            Assignment(source: .canvasAnnouncement, sourceID: sourceID, kind: .assignment, course: "ANTASK 9416",
                       title: "T", dueAt: due, url: nil)
        }
        let due = Date(timeIntervalSince1970: 1_800_000_000)
        let canvasDated = item("announcement-2-0", due: due)
        let edDated = item(AnnouncementRecord.edFindSourceID(courseID: "1", threadID: "1", index: 0), due: due)
        let canvasUndated = item("announcement-1-0", due: nil)
        let edUndated = item(AnnouncementRecord.edFindSourceID(courseID: "1", threadID: "2", index: 0), due: nil)
        let expected = [canvasDated.id, edDated.id, canvasUndated.id, edUndated.id]

        for input in [[edUndated, canvasUndated, edDated, canvasDated], [canvasDated, edUndated, edDated, canvasUndated]] {
            #expect(AppState.announcementDedupOrder(input).map(\.id) == expected)
        }
    }

    // MARK: Card wording and links

    @Test("an Ed task says where it came from and links to Ed")
    func edCardWording() {
        let ed = Assignment(
            source: .canvasAnnouncement,
            sourceID: AnnouncementRecord.edFindSourceID(courseID: "1", threadID: "2", index: 0),
            kind: .event, course: "ANTASK 9417", title: "Thing", dueAt: nil,
            url: URL(string: "https://edstem.org/us/courses/1/discussion/2")
        )
        let canvas = Assignment(
            source: .canvasAnnouncement, sourceID: "announcement-2-0", kind: .event, course: "ANTASK 9417",
            title: "Thing", dueAt: nil, url: URL(string: "https://canvas.upenn.edu/courses/1/discussion_topics/2")
        )
        let edCard = DashItem(assignment: ed, dueOverride: nil, isCompleted: false, completedAt: nil)
        let canvasCard = DashItem(assignment: canvas, dueOverride: nil, isCompleted: false, completedAt: nil)
        #expect(edCard.caveatText == "nothing to submit \u{00B7} from ed")
        #expect(canvasCard.caveatText == "nothing to submit \u{00B7} from announcements")
        #expect(ed.sourceLinks.map(\.label) == ["open in ed"])
        #expect(canvas.sourceLinks.map(\.label) == ["open in canvas"])
    }
}
