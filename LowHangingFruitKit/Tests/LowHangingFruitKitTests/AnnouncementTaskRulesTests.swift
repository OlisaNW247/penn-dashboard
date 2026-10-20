import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// The rules for which tasks found in announcements are on the dashboard, from
/// the owner's phone on 2026-10-18 ("none of these previous ones are honestly
/// helpful": a Sept 14 Ed quiz long since taken, a start-of-class reminder, and
/// a prev tab full of both):
///
///  - a same-day "be there" reminder is not a card, and a real deadline for the
///    same day is (the vocabulary is pinned below);
///  - an undated task shows for seven days after its post (found through the
///    announcement log, the Ed document, or when the app first saw the row) and
///    is gone from the eighth;
///  - none of this deletes a ledger row or touches a completion, and none of it
///    touches a feed item.
///
/// (A past task, and the rule that a finished one stays in prev, are in
/// `AnnouncementTasksOnDashboardTests`; the Ed 14-day window is in
/// `EdAnnouncementTaskTests`.)
///
/// **Hermeticity.** Rows are seeded straight into an in-memory ledger, the post
/// dates are handed to the state directly (the announcement log is off under
/// the test runner), and the dashboard is rebuilt at a fixed `now`, so nothing
/// depends on the day the tests run, except the one test that exercises the
/// ledger's own first-seen date, which is relative to the moment it runs.
/// Class codes are unique to this suite and the extraction-repair version is
/// pinned, as in the other announcement suites.
@MainActor
@Suite("Announcement task rules", .serialized)
struct AnnouncementTaskRulesTests {
    private static let hour: TimeInterval = 3600
    private static let day: TimeInterval = 24 * 3600
    private static let extractionVersionKey = "announcementExtractionVersionV1"
    private static let processedKey = "processedAnnouncementIDsV1"

    /// A local time in October 2026.
    private static func date(_ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(year: 2026, month: 10, day: day, hour: hour, minute: minute))!
    }

    // MARK: Fixtures

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

    private func canvasFind(_ id: String, course: String, title: String, due: Date?, kind: Assignment.Kind = .assignment) -> Assignment {
        Assignment(
            source: .canvasAnnouncement,
            sourceID: AnnouncementRecord.findSourceID(announcementID: id, index: 0),
            kind: kind, course: course, title: title, dueAt: due,
            url: URL(string: "https://canvas.upenn.edu/courses/1/discussion_topics/\(id)")
        )
    }

    private func edFind(courseID: String, thread: String, course: String, title: String, due: Date?) -> Assignment {
        Assignment(
            source: .canvasAnnouncement,
            sourceID: AnnouncementRecord.edFindSourceID(courseID: courseID, threadID: thread, index: 0),
            kind: .assignment, course: course, title: title, dueAt: due,
            url: URL(string: "https://edstem.org/us/courses/1/discussion/\(thread)")
        )
    }

    /// The announcement log's record of a Canvas post: the evidence of when it
    /// was posted.
    private func record(_ id: String, course: String, posted: Date) -> AnnouncementRecord {
        AnnouncementRecord(
            id: id, courseID: "1", courseCode: course, title: "post", postedAt: posted,
            url: nil, snippet: "", recordedAt: posted
        )
    }

    /// An Ed post as the pooled document holds it, dated by `updatedAt`.
    private func edDocument(courseID: String, thread: String, course: String, posted: Date) -> CourseDocument {
        CourseDocument(
            courseID: courseID, course: course, kind: .ed, sourceID: thread, title: "post",
            url: nil, text: "[ed · announcement]\nSubmit something.", updatedAt: posted, fetchedAt: posted
        )
    }

    private func makeState(
        _ seed: [Assignment],
        log: [AnnouncementRecord] = [],
        documents: [CourseDocument] = [],
        dueDateEditsDefaults: UserDefaults? = nil
    ) throws -> (AppState, AssignmentStore) {
        let store = try AssignmentStore(inMemory: true)
        store.upsert(seed)
        let state = AppState(assignmentStore: store, dueDateEditsDefaults: dueDateEditsDefaults)
        state.forceFixtureDataForTesting(false)
        state.announcementLogRecords = log
        state.courseKnowledge = CourseKnowledgeBase(documents: documents)
        return (state, store)
    }

    private func onDashboard(_ state: AppState, _ course: String) -> [String] {
        (state.assignments + state.laterAssignments + state.assessments)
            .filter { $0.course == course }.map(\.title)
    }

    private func prev(_ state: AppState, _ course: String, at now: Date) -> [DashItem] {
        let vm = DashboardViewModel()
        vm.bind(to: state)
        return vm.doneSections(now: now).flatMap(\.items).filter { $0.assignment.course == course }
    }

    // MARK: The vocabulary

    @Test("the attendance vocabulary: attend, come to, bring, join us, and 'in class/lecture today'")
    func vocabulary() {
        let reminders = [
            "Attend the weekly rotation quiz",
            "attend lecture",
            "Please attend the review session",
            "Come to class",
            "Come to the guest lecture",
            "Come in for the makeup",
            "Bring a calculator",
            "Bring your laptop to lecture",
            "Please bring your ID",
            "Remember to bring a pencil",
            "Don't forget to bring a pencil",
            "Don\u{2019}t forget to bring a pencil",
            "Join us for the guest talk",
            "Take the quiz in class today",
            "Quiz in lecture today",
        ]
        for title in reminders {
            #expect(AnnouncementClassReminder.isAttendanceInstruction(title), "\"\(title)\" is a reminder")
        }

        let work = [
            "HW 3 due tonight",
            "Submit HW 3 tonight",
            "Complete the reading",
            "Submit the lab report by 5pm",
            "Take the quiz on Canvas",
            // Word boundaries: attendance is not attending, and "come up with" is not "come to".
            "Attendance policy quiz",
            "Come up with a project title",
            "Read chapter 4 before class",
            // Only today: a quiz in class next week is a date to know, not a reminder.
            "Take the quiz in class tomorrow",
            "Review notes and bring questions",
            "Join the Ed discussion",
        ]
        for title in work {
            #expect(!AnnouncementClassReminder.isAttendanceInstruction(title), "\"\(title)\" is work")
        }
    }

    @Test("a reminder is same-day when due within 12 hours of the post or on the post's calendar day, either direction")
    func sameDayWindow() {
        func reminder(posted: Date, due: Date, title: String = "Attend the weekly rotation quiz") -> Bool {
            AnnouncementClassReminder.isSameDayReminder(title: title, dueAt: due, postedAt: posted)
        }
        // Posted 8 a.m., class at 10.
        #expect(reminder(posted: Self.date(14, 8), due: Self.date(14, 10)))
        // The end of the day an extractor defaults to is 16 hours on and still the same day.
        #expect(reminder(posted: Self.date(14, 7), due: Self.date(14, 23, 59)))
        // 11 p.m. for 8 a.m. is the next day, and 9 hours away.
        #expect(reminder(posted: Self.date(14, 23), due: Self.date(15, 8)))
        // Already past when posted (a late post about this morning).
        #expect(reminder(posted: Self.date(14, 10), due: Self.date(14, 8)))
        // The edge: exactly 12 hours counts.
        #expect(reminder(posted: Self.date(14, 20), due: Self.date(15, 8)))

        // Two days out is preparation the student wants to see.
        #expect(!reminder(posted: Self.date(13, 17), due: Self.date(15, 10), title: "Bring a calculator to the exam"))
        // Tomorrow night: neither within 12 hours nor the same day.
        #expect(!reminder(posted: Self.date(14, 8), due: Self.date(15, 23, 59)))
        // A deadline for the same day is not a reminder, whatever the hour.
        #expect(!reminder(posted: Self.date(14, 8), due: Self.date(14, 23, 59), title: "HW 3 due tonight"))
        #expect(!reminder(posted: Self.date(14, 8), due: Self.date(14, 23, 59), title: "Complete HW 3"))
    }

    // MARK: The rule

    @Test("an undated task shows for seven days after its post and is hidden from the eighth day; a dated one is judged by its date")
    func undatedLifetime() {
        let posted = Self.date(1, 9)
        let task = Assignment(source: .canvasAnnouncement, sourceID: "announcement-1-0", kind: .assignment,
                              course: "ANRULE 9800", title: "Submit the reflection", dueAt: nil, url: nil)
        func hidden(after seconds: TimeInterval) -> Bool {
            AppState.isHiddenAnnouncementTask(task, dueAt: nil, postedAt: posted, now: posted.addingTimeInterval(seconds))
        }
        #expect(!hidden(after: 0))
        #expect(!hidden(after: 6 * Self.day))
        #expect(!hidden(after: 7 * Self.day), "the week itself is still shown")
        #expect(hidden(after: 8 * Self.day))
        // No post date to age it by: kept, never guessed at.
        #expect(!AppState.isHiddenAnnouncementTask(task, dueAt: nil, postedAt: nil, now: posted.addingTimeInterval(30 * Self.day)))
        // A date, once given, is what counts: a year-old post with next week's date is live.
        #expect(!AppState.isHiddenAnnouncementTask(task, dueAt: posted.addingTimeInterval(400 * Self.day),
                                                   postedAt: posted, now: posted.addingTimeInterval(390 * Self.day)))
    }

    @Test("without the post's own date the same-day reminder rule keeps the card: first-seen is not the post's time")
    func reminderNeedsThePostsDate() {
        let firstSeen = Self.date(14, 9)
        let task = Assignment(source: .canvasAnnouncement, sourceID: "announcement-3-0", kind: .assignment,
                              course: "ANRULE 9810", title: "Bring a signed permission form",
                              dueAt: Self.date(14, 10), url: nil)
        #expect(!AppState.isHiddenAnnouncementTask(task, dueAt: task.dueAt, postedAt: nil, firstSeenAt: firstSeen, now: firstSeen))
        #expect(AppState.isHiddenAnnouncementTask(task, dueAt: task.dueAt, postedAt: Self.date(14, 8), firstSeenAt: firstSeen, now: firstSeen))
    }

    @Test("a found exam is never a be-there reminder; the same wording on an ordinary task is")
    func examsAreNotReminders() throws {
        let posted = Self.date(14, 8)
        let due = Self.date(14, 10)
        func task(_ title: String) -> Assignment {
            Assignment(source: .canvasAnnouncement, sourceID: "announcement-2-0", kind: .assignment,
                       course: "ANRULE 9801", title: title, dueAt: due, url: nil)
        }
        let exam = task("Midterm 1 in class today")
        #expect(exam.isFoundExam, "the fixture has to be an exam for this to prove anything")
        #expect(!AppState.isHiddenAnnouncementTask(exam, dueAt: due, postedAt: posted, now: posted))
        #expect(AppState.isHiddenAnnouncementTask(task("Quiz in class today"), dueAt: due, postedAt: posted, now: posted))
    }

    @Test("only announcement-derived tasks are judged: a feed item with the same title, date and age is untouched")
    func feedItemsAreUntouched() {
        let posted = Self.date(1, 9)
        let now = posted.addingTimeInterval(30 * Self.day)
        for source in [Assignment.Source.canvas, .gradescope, .manual, .canvasModules, .canvasSuggestion] {
            let undated = Assignment(source: source, sourceID: "x-1", kind: .assignment, course: "ANRULE 9802",
                                     title: "Attend the weekly rotation quiz", dueAt: nil, url: nil)
            let sameDay = Assignment(source: source, sourceID: "x-2", kind: .assignment, course: "ANRULE 9802",
                                     title: "Attend the weekly rotation quiz", dueAt: posted.addingTimeInterval(2 * Self.hour), url: nil)
            #expect(!AppState.isHiddenAnnouncementTask(undated, dueAt: nil, postedAt: posted, now: now))
            #expect(!AppState.isHiddenAnnouncementTask(sameDay, dueAt: sameDay.dueAt, postedAt: posted, now: posted))
        }
    }

    // MARK: Where the post date comes from

    @Test("the post date is the log's for a Canvas post, the document's for an Ed post, the ledger's first-seen as a fallback, and none for a syllabus exam")
    func postDateSources() {
        let canvasRow = Assignment(source: .canvasAnnouncement, sourceID: AnnouncementRecord.findSourceID(announcementID: "55", index: 0),
                                   kind: .assignment, course: "ANRULE 9803", title: "T", dueAt: nil, url: nil)
        let edRow = Assignment(source: .canvasAnnouncement, sourceID: AnnouncementRecord.edFindSourceID(courseID: "9803", threadID: "77", index: 0),
                               kind: .assignment, course: "ANRULE 9803", title: "T", dueAt: nil, url: nil)
        let syllabusRow = Assignment(source: .canvasAnnouncement, sourceID: AnnouncementRecord.syllabusFindSourceID(courseID: "9803", examKey: "midterm-1"),
                                     kind: .event, course: "ANRULE 9803", title: "Midterm 1", dueAt: nil, url: nil)
        let unknownRow = Assignment(source: .canvasAnnouncement, sourceID: AnnouncementRecord.findSourceID(announcementID: "99", index: 0),
                                    kind: .assignment, course: "ANRULE 9803", title: "T", dueAt: nil, url: nil)

        let log = Self.date(2, 9), doc = Self.date(3, 9), ledger = Self.date(4, 9)
        var dates = AppState.AnnouncementPostDates()
        dates.canvas = ["55": log]
        dates.ed = ["ed:9803:77": doc]
        dates.firstSeen = [canvasRow.id: ledger, edRow.id: ledger, syllabusRow.id: ledger, unknownRow.id: ledger]

        #expect(dates.postedAt(for: canvasRow) == log)
        #expect(dates.postedAt(for: edRow) == doc)
        #expect(dates.postedAt(for: unknownRow) == nil, "a post the log no longer holds gives no date")
        #expect(dates.firstSeenAt(for: unknownRow) == ledger, "so the undated rule falls back to when the row was first seen")
        #expect(dates.postedAt(for: syllabusRow) == nil && dates.firstSeenAt(for: syllabusRow) == nil,
                "a syllabus exam is no post's, and is never aged")
    }

    // MARK: On the dashboard

    @Test("same-day reminders are not cards; real deadlines and next-week preparation are; every row stays in the ledger")
    func remindersOnTheDashboard() throws {
        try withPinnedDefaults {
            let course = "ANRULE 9804"
            let posted = Self.date(14, 8)
            let rows = [
                canvasFind("98040001", course: course, title: "Attend the weekly rotation quiz", due: Self.date(14, 10)),
                canvasFind("98040002", course: course, title: "Complete HW 3", due: Self.date(14, 23, 59)),
                canvasFind("98040003", course: course, title: "Bring a calculator to the exam", due: Self.date(16, 10), kind: .event),
                canvasFind("98040004", course: course, title: "Come to class", due: Self.date(14, 23, 59), kind: .event),
            ]
            let (state, store) = try makeState(rows, log: rows.enumerated().map {
                record("9804000\($0.offset + 1)", course: course, posted: posted)
            })
            let before = store.allRowsForTesting().count
            state.rebuildDashboardItemsForTesting(now: Self.date(14, 9))

            #expect(Set(onDashboard(state, course)) == ["Complete HW 3", "Bring a calculator to the exam"])
            #expect(store.allRowsForTesting().count == before, "hidden by a rule, not deleted")
        }
    }

    @Test("an undated task is on the dashboard on day 6 and gone on day 8, in todo/all and in prev; the row stays")
    func undatedOnTheDashboard() throws {
        try withPinnedDefaults {
            let course = "ANRULE 9805"
            let posted = Self.date(1, 9)
            let task = canvasFind("98050001", course: course, title: "Submit the reflection", due: nil)
            let (state, store) = try makeState([task], log: [record("98050001", course: course, posted: posted)])

            state.rebuildDashboardItemsForTesting(now: posted.addingTimeInterval(6 * Self.day))
            #expect(onDashboard(state, course) == ["Submit the reflection"])

            let eighth = posted.addingTimeInterval(8 * Self.day)
            state.rebuildDashboardItemsForTesting(now: eighth)
            #expect(onDashboard(state, course).isEmpty)
            #expect(prev(state, course, at: eighth).isEmpty)
            #expect(store.allRowsForTesting().count == 1)

            // Back the moment the rule stops matching: the student gives it a date.
            let suite = "anrule-edits-\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suite)!
            defer { defaults.removePersistentDomain(forName: suite) }
            let (edited, _) = try makeState([task], log: [record("98050001", course: course, posted: posted)],
                                            dueDateEditsDefaults: defaults)
            edited.setDueDateEdit(eighth.addingTimeInterval(2 * Self.day), for: task)
            edited.rebuildDashboardItemsForTesting(now: eighth)
            #expect(onDashboard(edited, course) == ["Submit the reflection"])
        }
    }

    @Test("without the log, an undated task is aged from when the ledger first saw it")
    func undatedFallsBackToFirstSeen() throws {
        try withPinnedDefaults {
            let course = "ANRULE 9806"
            let task = canvasFind("98060001", course: course, title: "Submit the reflection", due: nil)
            let (state, _) = try makeState([task])   // no log record: first-seen is the upsert, just now
            let base = Date()

            state.rebuildDashboardItemsForTesting(now: base.addingTimeInterval(6 * Self.day))
            #expect(onDashboard(state, course) == ["Submit the reflection"])
            state.rebuildDashboardItemsForTesting(now: base.addingTimeInterval(8 * Self.day))
            #expect(onDashboard(state, course).isEmpty)
        }
    }

    @Test("an undated Ed task is aged from its document's date")
    func undatedEdTask() throws {
        try withPinnedDefaults {
            let course = "ANRULE 9807"
            let posted = Self.date(1, 9)
            let task = edFind(courseID: "9807", thread: "98070001", course: course, title: "Submit the reflection", due: nil)
            let doc = edDocument(courseID: "9807", thread: "98070001", course: course, posted: posted)
            let (state, store) = try makeState([task], documents: [doc])

            state.rebuildDashboardItemsForTesting(now: posted.addingTimeInterval(6 * Self.day))
            #expect(onDashboard(state, course) == ["Submit the reflection"])
            state.rebuildDashboardItemsForTesting(now: posted.addingTimeInterval(8 * Self.day))
            #expect(onDashboard(state, course).isEmpty)
            #expect(store.allRowsForTesting().count == 1)
        }
    }

    @Test("a task the student finished stays in prev however old it is, whether it was undated or a reminder")
    func finishedStaysInPrev() throws {
        try withPinnedDefaults {
            let course = "ANRULE 9808"
            let posted = Self.date(1, 9)
            let undated = canvasFind("98080001", course: course, title: "Submit the reflection", due: nil)
            let reminder = canvasFind("98080002", course: course, title: "Attend the weekly rotation quiz", due: Self.date(1, 11))
            let (state, store) = try makeState([undated, reminder], log: [
                record("98080001", course: course, posted: posted),
                record("98080002", course: course, posted: posted),
            ])
            defer { state.markActive(undated); state.markActive(reminder) }
            state.markCompleted(undated, at: Self.date(3))
            state.markCompleted(reminder, at: Self.date(1, 11))

            let later = posted.addingTimeInterval(30 * Self.day)
            state.rebuildDashboardItemsForTesting(now: later)
            #expect(onDashboard(state, course).isEmpty)
            #expect(Set(prev(state, course, at: Self.date(4)).map(\.assignment.title))
                == ["Submit the reflection", "Attend the weekly rotation quiz"])
            #expect(store.completionRecord().ids.isSuperset(of: [undated.id, reminder.id]))
        }
    }

    @Test("feed items are unchanged: an overdue or undated Gradescope item stays, whatever its title says")
    func feedItemsStayOnTheDashboard() throws {
        try withPinnedDefaults {
            let course = "ANRULE 9809"
            let overdue = Assignment(source: .gradescope, sourceID: "anrule-9809-g1", kind: .assignment, course: course,
                                     title: "Problem set that is overdue", dueAt: Self.date(13, 12), url: nil)
            let undated = Assignment(source: .gradescope, sourceID: "anrule-9809-g2", kind: .assignment, course: course,
                                     title: "Attend the weekly rotation quiz", dueAt: nil, url: nil)
            let (state, _) = try makeState([])
            state.gradescopeItems = [overdue, undated]
            state.rebuildDashboardItemsForTesting(now: Self.date(16, 12))
            #expect(Set(onDashboard(state, course)) == ["Problem set that is overdue", "Attend the weekly rotation quiz"])
        }
    }
}
