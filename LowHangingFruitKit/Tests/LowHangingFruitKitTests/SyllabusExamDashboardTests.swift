import Foundation
import Testing
import UserNotifications
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// Exams the class finds (from the syllabus, or announced) as cards, and the
/// owner's rule that a midterm is never shown twice.
///
///  - the syllabus pass files one row per exam, with a stable id, and a second
///    pass adds nothing;
///  - one card per exam across the Canvas or Gradescope item, the Canvas and Ed
///    announcements and the syllabus, with the feed item first, then an
///    announcement, then the syllabus (so a rescheduled date from an
///    announcement is the one shown);
///  - a finished tick follows the exam onto the card that is shown;
///  - an exam whose date has passed is in prev, and an all-day one is not
///    until its day is over;
///  - neither the "announcements on dashboard" switch nor the "items with
///    nothing to submit" switch hides an exam;
///  - an exam is reminded about the ordinary way and never gets the loud
///    10-minute alert.
///
/// **Hermeticity.** The ledger is in memory, the course material is handed to
/// the state directly, and the pass is driven by the test
/// (`syncSyllabusExams(now:)`); an `AppState` under the test runner starts
/// nothing on its own. Every suite-visible preference a test flips (the
/// per-class switches, the class selection, the Canvas course-id cache) is put
/// back, and every class code and course id is unique to this suite. `now` is
/// a fixed local Sunday, October 18, 2026, noon, passed to both the pass and
/// the rebuild, so nothing depends on the day the tests run.
@MainActor
@Suite("Syllabus exams on the dashboard", .serialized)
struct SyllabusExamDashboardTests {
    private static let extractionVersionKey = "announcementExtractionVersionV1"
    private static let processedKey = "processedAnnouncementIDsV1"

    // MARK: Fixtures

    private static func date(_ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date {
        Calendar.current.date(from: DateComponents(
            year: 2026, month: month, day: day, hour: hour, minute: minute, second: second
        ))!
    }

    private static let now = date(10, 18, 12)

    private func syllabus(_ course: String, id: String, text: String) -> CourseDocument {
        CourseDocument(
            courseID: id, course: course, kind: .syllabus, sourceID: "syllabus", title: "Syllabus",
            url: URL(string: "https://canvas.upenn.edu/courses/\(id)/assignments/syllabus"),
            text: text, updatedAt: nil, fetchedAt: Self.now
        )
    }

    /// A feed item with its Canvas URL, which is also what gives
    /// `canvasCourseIDs()` an id -> code entry for the class.
    ///
    /// `number` is the Canvas assignment id in the URL. Two feed items that
    /// shared one would be read as one assignment's section overrides and
    /// collapsed (`AssignmentDeduplicator.collapseCanvasOverrides`), which is
    /// not what a test of two exams means.
    private func feedItem(
        _ course: String, id: String, number: Int = 1, title: String,
        due: Date?, kind: Assignment.Kind = .assignment
    ) -> Assignment {
        Assignment(
            source: .canvas, sourceID: "event-assignment-\(number)", kind: kind, course: course,
            title: title, dueAt: due,
            url: URL(string: "https://canvas.upenn.edu/courses/\(id)/assignments/\(number)")
        )
    }

    private func canvasAnnouncement(
        _ course: String, _ announcementID: String, title: String, due: Date?, kind: Assignment.Kind = .assignment
    ) -> Assignment {
        Assignment(
            source: .canvasAnnouncement,
            sourceID: AnnouncementRecord.findSourceID(announcementID: announcementID, index: 0),
            kind: kind, course: course, title: title, dueAt: due,
            url: URL(string: "https://canvas.upenn.edu/courses/1/discussion_topics/\(announcementID)")
        )
    }

    private func edAnnouncement(
        _ course: String, courseID: String, thread: String, title: String, due: Date?,
        kind: Assignment.Kind = .assignment
    ) -> Assignment {
        Assignment(
            source: .canvasAnnouncement,
            sourceID: AnnouncementRecord.edFindSourceID(courseID: courseID, threadID: thread, index: 0),
            kind: kind, course: course, title: title, dueAt: due,
            url: URL(string: "https://edstem.org/us/courses/1/discussion/\(thread)")
        )
    }

    /// A state for one class, with the course material and the rows handed to
    /// it, and every shared preference it touches put back afterwards.
    private func withState(
        course: String,
        courseID: String,
        documents: [CourseDocument] = [],
        feed: [Assignment] = [],
        announcements: [Assignment] = [],
        _ body: @MainActor (AppState, AssignmentStore) async throws -> Void
    ) async throws {
        let shared = UserDefaults.lhf
        let keys = [Self.extractionVersionKey, Self.processedKey]
        let saved = keys.map { ($0, shared.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { shared.set(value, forKey: key) } else { shared.removeObject(forKey: key) }
            }
        }
        shared.set(2, forKey: Self.extractionVersionKey)
        shared.removeObject(forKey: Self.processedKey)

        let store = try AssignmentStore(inMemory: true)
        store.upsert(announcements)
        let state = AppState(assignmentStore: store)
        state.forceFixtureDataForTesting(false)
        state.canvasItems = feed + [feedItem(course, id: courseID, number: 99, title: "Seed", due: nil)]
        state.setCourse(course, selected: true)
        defer {
            state.restoreCourse(course)
            state.setCourse(course, selected: true)
            state.coursePreferences.setCanvasCourseID(course, nil)
        }
        state.courseKnowledge = CourseKnowledgeBase(documents: documents)
        state.rebuildDashboardItemsForTesting(now: Self.now)
        try await body(state, store)
    }

    /// Runs the pass and rebuilds at the fixed `now`.
    private func fileExams(_ state: AppState, at now: Date = SyllabusExamDashboardTests.now) async {
        await state.syncSyllabusExams(now: now)
        state.rebuildDashboardItemsForTesting(now: now)
    }

    private func cards(_ state: AppState, _ course: String) -> [Assignment] {
        (state.assignments + state.laterAssignments + state.assessments)
            .filter { $0.course == course && $0.title != "Seed" }
    }

    private func titles(_ state: AppState, _ course: String) -> Set<String> {
        Set(cards(state, course).map(\.title))
    }

    private func syllabusRows(_ store: AssignmentStore) -> [Assignment] {
        store.assignments(source: .canvasAnnouncement).filter { $0.announcementOrigin == .syllabus }
    }

    // MARK: The pass

    @Test("a syllabus's exams become cards: drawn as exams, dated to the end of their day, from the syllabus")
    func passFilesCards() async throws {
        let course = "SYLDASH 9611"
        try await withState(
            course: course, courseID: "9611",
            documents: [syllabus(course, id: "9611", text: "Midterm 1: Oct 23\nFinal Exam: Dec 15")]
        ) { state, store in
            #expect(cards(state, course).isEmpty, "nothing is read until the pass runs")
            await fileExams(state)

            #expect(titles(state, course) == ["Midterm 1", "Final Exam"])
            #expect(Set(syllabusRows(store).map(\.sourceID)) == ["syllabus-9611-midterm-1", "syllabus-9611-final"])
            let midterm = try #require(cards(state, course).first { $0.title == "Midterm 1" })
            #expect(midterm.dueAt == Self.date(10, 23, 23, 59, 59))
            #expect(midterm.kind == .event)

            let vm = DashboardViewModel()
            vm.bind(to: state)
            let item = try #require(vm.items.first { $0.assignment.title == "Midterm 1" })
            #expect(item.isFoundExam)
            #expect(item.examStyleOverride == true)
            #expect(item.caveatText?.contains("from syllabus") == true)
            #expect(item.caveatText?.contains("from announcements") == false)
        }
    }

    @Test("a second pass over the same material adds no row and no card")
    func secondPassAddsNothing() async throws {
        let course = "SYLDASH 9612"
        try await withState(
            course: course, courseID: "9612",
            documents: [syllabus(course, id: "9612", text: "Midterm 1: Oct 23\nFinal Exam: Dec 15")]
        ) { state, store in
            await fileExams(state)
            let before = syllabusRows(store).map(\.id).sorted()
            await fileExams(state)
            await fileExams(state)
            #expect(syllabusRows(store).map(\.id).sorted() == before)
            #expect(before.count == 2)
            #expect(state.announcementItems.filter { $0.course == course }.count == 2)
            #expect(cards(state, course).count == 2)
        }
    }

    @Test("a moved date updates the card instead of adding one")
    func movedDate() async throws {
        let course = "SYLDASH 9613"
        try await withState(
            course: course, courseID: "9613",
            documents: [syllabus(course, id: "9613", text: "Midterm 1: Oct 23")]
        ) { state, store in
            await fileExams(state)
            state.courseKnowledge = CourseKnowledgeBase(documents: [syllabus(course, id: "9613", text: "Midterm 1: Oct 30")])
            await fileExams(state)
            let found = cards(state, course)
            #expect(found.count == 1)
            #expect(found.first?.dueAt == Self.date(10, 30, 23, 59, 59))
            #expect(syllabusRows(store).count == 1)
        }
    }

    @Test("a class the app cannot name, fixture data, and no material each file nothing")
    func guards() async throws {
        let course = "SYLDASH 9614"
        // The document belongs to a site the feed never mentioned.
        try await withState(
            course: course, courseID: "9614",
            documents: [syllabus("OTHER 1", id: "9699", text: "Midterm 1: Oct 23")]
        ) { state, store in
            await fileExams(state)
            #expect(syllabusRows(store).isEmpty)
        }
        try await withState(
            course: course, courseID: "9614",
            documents: [syllabus(course, id: "9614", text: "Midterm 1: Oct 23")]
        ) { state, store in
            state.forceFixtureDataForTesting(true)
            await fileExams(state)
            #expect(syllabusRows(store).isEmpty)
        }
        try await withState(course: course, courseID: "9614") { state, store in
            await fileExams(state)
            #expect(syllabusRows(store).isEmpty)
        }
    }

    @Test("a change to the course material runs a pass by itself once the subscription is installed, and not before")
    func knowledgeChangeTriggersPass() async throws {
        let course = "SYLDASH 9615"
        try await withState(course: course, courseID: "9615") { state, store in
            state.courseKnowledge = CourseKnowledgeBase(documents: [syllabus(course, id: "9615", text: "Midterm 1: Oct 23")])
            #expect(state.syllabusExamPassTask == nil)
            #expect(syllabusRows(store).isEmpty)

            state.observeKnowledgeForSyllabusExams()
            // A date near the real today, so the extractor keeps it whatever day this runs.
            let soon = Calendar.current.date(byAdding: .day, value: 10, to: Date())!
            let parts = Calendar.current.dateComponents([.month, .day], from: soon)
            let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
            let line = "Midterm 1: \(months[parts.month! - 1]) \(parts.day!)"
            state.courseKnowledge = CourseKnowledgeBase(documents: [syllabus(course, id: "9615", text: line)])
            await state.syllabusExamPassTask?.value

            #expect(state.syllabusExamPassTask == nil)
            #expect(syllabusRows(store).map(\.sourceID) == ["syllabus-9615-midterm-1"])
        }
    }

    // MARK: One card per exam

    @Test("a Canvas item for the exam wins over the syllabus's copy, which stays in the ledger")
    func feedWins() async throws {
        let course = "SYLDASH 9621"
        try await withState(
            course: course, courseID: "9621",
            documents: [syllabus(course, id: "9621", text: "Midterm 1: Oct 23")],
            feed: [feedItem(course, id: "9621", title: "Midterm 1", due: Self.date(10, 23, 14))]
        ) { state, store in
            await fileExams(state)
            let found = cards(state, course)
            #expect(found.map(\.title) == ["Midterm 1"])
            #expect(found.first?.source == .canvas)
            #expect(syllabusRows(store).count == 1, "hidden, not deleted: the next sync may need it")
        }
    }

    @Test("an unnumbered exam and the same exam numbered are one card on the same day and two on different days")
    func unnumberedVersusNumbered() async throws {
        let course = "SYLDASH 9622"
        try await withState(
            course: course, courseID: "9622",
            documents: [syllabus(course, id: "9622", text: "Midterm 1: Oct 23")],
            feed: [feedItem(course, id: "9622", title: "Midterm", due: Self.date(10, 23, 14))]
        ) { state, _ in
            await fileExams(state)
            #expect(cards(state, course).map(\.title) == ["Midterm"])
        }
        try await withState(
            course: course, courseID: "9622",
            documents: [syllabus(course, id: "9622", text: "Midterm 1: Oct 30")],
            feed: [feedItem(course, id: "9622", title: "Midterm", due: Self.date(10, 23, 14))]
        ) { state, _ in
            await fileExams(state)
            #expect(titles(state, course) == ["Midterm", "Midterm 1"])
        }
    }

    @Test("Midterm 2 and Exam 2 are one card on the same day; Midterm 1 and Exam 2 never are")
    func midtermVersusExam() async throws {
        let course = "SYLDASH 9623"
        try await withState(
            course: course, courseID: "9623",
            documents: [syllabus(course, id: "9623", text: "Midterm 2: Nov 20")],
            feed: [feedItem(course, id: "9623", title: "Exam 2", due: Self.date(11, 20, 18))]
        ) { state, _ in
            await fileExams(state)
            #expect(cards(state, course).map(\.title) == ["Exam 2"])
        }
        try await withState(
            course: course, courseID: "9623",
            documents: [syllabus(course, id: "9623", text: "Midterm 1: Nov 20")],
            feed: [feedItem(course, id: "9623", title: "Exam 2", due: Self.date(11, 20, 18))]
        ) { state, _ in
            await fileExams(state)
            #expect(titles(state, course) == ["Exam 2", "Midterm 1"])
        }
    }

    @Test("an announced exam beats the syllabus's, and the syllabus's copy is hidden")
    func announcementBeatsSyllabus() async throws {
        let course = "SYLDASH 9624"
        let announced = canvasAnnouncement(course, "96240001", title: "Midterm 1", due: Self.date(10, 23, 14))
        try await withState(
            course: course, courseID: "9624",
            documents: [syllabus(course, id: "9624", text: "Midterm 1: Oct 23")],
            announcements: [announced]
        ) { state, _ in
            await fileExams(state)
            let found = cards(state, course)
            #expect(found.map(\.id) == [announced.id])
            #expect(found.first?.dueAt == Self.date(10, 23, 14))
        }
    }

    @Test("an announcement that says only \"Midterm\" and the syllabus's \"Midterm 1\" are one card when the day agrees")
    func unnumberedAnnouncement() async throws {
        let course = "SYLDASH 9629"
        let announced = canvasAnnouncement(course, "96290001", title: "Midterm", due: Self.date(10, 23, 14))
        try await withState(
            course: course, courseID: "9629",
            documents: [syllabus(course, id: "9629", text: "Midterm 1: Oct 23")],
            announcements: [announced]
        ) { state, _ in
            await fileExams(state)
            #expect(cards(state, course).map(\.id) == [announced.id])
        }
    }

    @Test("a rescheduled exam shows the announcement's date, not the syllabus's")
    func rescheduledDateWins() async throws {
        let course = "SYLDASH 9625"
        let announced = canvasAnnouncement(course, "96250001", title: "Midterm 1", due: Self.date(10, 30, 14))
        try await withState(
            course: course, courseID: "9625",
            documents: [syllabus(course, id: "9625", text: "Midterm 1: Oct 23")],
            announcements: [announced]
        ) { state, store in
            await fileExams(state)
            let found = cards(state, course)
            #expect(found.count == 1)
            #expect(found.first?.id == announced.id)
            #expect(found.first?.dueAt == Self.date(10, 30, 14))
            #expect(syllabusRows(store).count == 1, "the syllabus's row is still the ledger's, only hidden")
        }
    }

    @Test("a reschedule of several weeks is still one exam: the announcement's date, one card")
    func farReschedule() async throws {
        let course = "SYLDASH 9630"
        // Forty-five days: past the 21 the title heuristic tolerates, inside the 60 an exam may move.
        let announced = canvasAnnouncement(course, "96300001", title: "Midterm 1", due: Self.date(12, 7, 14))
        try await withState(
            course: course, courseID: "9630",
            documents: [syllabus(course, id: "9630", text: "Midterm 1: Oct 23")],
            announcements: [announced]
        ) { state, _ in
            await fileExams(state)
            #expect(cards(state, course).map(\.id) == [announced.id])
            #expect(cards(state, course).first?.dueAt == Self.date(12, 7, 14))
        }
    }

    @Test("an announcement that names the exam without a day does not hide the syllabus's dated one")
    func undatedAnnouncementLoses() async throws {
        let course = "SYLDASH 9626"
        let announced = canvasAnnouncement(course, "96260001", title: "Midterm 1", due: nil)
        try await withState(
            course: course, courseID: "9626",
            documents: [syllabus(course, id: "9626", text: "Midterm 1: Oct 23")],
            announcements: [announced]
        ) { state, _ in
            await fileExams(state)
            let found = cards(state, course)
            #expect(found.count == 1)
            #expect(found.first?.announcementOrigin == .syllabus)
            #expect(found.first?.dueAt == Self.date(10, 23, 23, 59, 59))
        }
    }

    @Test("a task about the exam is not the exam: it neither hides the syllabus's midterm nor is hidden by it")
    func taskAboutTheExamIsItsOwnCard() async throws {
        let course = "SYLDASH 9635"
        let reminder = canvasAnnouncement(
            course, "96350001", title: "Bring a calculator to the exam", due: Self.date(10, 23, 8), kind: .event
        )
        try await withState(
            course: course, courseID: "9635",
            documents: [syllabus(course, id: "9635", text: "Midterm 1: Oct 23")],
            announcements: [reminder]
        ) { state, _ in
            await fileExams(state)
            #expect(titles(state, course) == ["Bring a calculator to the exam", "Midterm 1"])
            // And the class's switch still governs the reminder, as it does for every task.
            let original = state.coursePreferences.announcementAssignmentsOnDashboard(course)
            defer { state.setAnnouncementAssignmentsOnDashboard(course, original) }
            state.setAnnouncementAssignmentsOnDashboard(course, false)
            state.rebuildDashboardItemsForTesting(now: Self.now)
            #expect(titles(state, course) == ["Midterm 1"])
        }
    }

    // MARK: A feed exam with no date

    @Test("a Canvas exam with no due date does not hide the syllabus's dated copy: the dated one is the card, and the feed row stays where it is")
    func undatedFeedExamYields() async throws {
        let course = "SYLDASH 9691"
        try await withState(
            course: course, courseID: "9691",
            documents: [syllabus(course, id: "9691", text: "Midterm 1: Oct 23")],
            feed: [feedItem(course, id: "9691", title: "Midterm 1", due: nil)]
        ) { state, store in
            await fileExams(state)
            let found = cards(state, course)
            #expect(found.count == 1)
            #expect(found.first?.announcementOrigin == .syllabus)
            #expect(found.first?.dueAt == Self.date(10, 23, 23, 59, 59))
            // Nothing was written onto the feed row, and nothing was deleted.
            let feed = try #require(state.canvasItems.first { $0.title == "Midterm 1" })
            #expect(feed.dueAt == nil)
            #expect(syllabusRows(store).count == 1)
        }
    }

    @Test("an announced date takes an undated Canvas exam's place the same way, and a dated Canvas exam still wins")
    func announcedDateAlsoReplacesUndatedFeedExam() async throws {
        let course = "SYLDASH 9692"
        let announced = canvasAnnouncement(course, "96920001", title: "Midterm 1", due: Self.date(10, 24, 14))
        try await withState(
            course: course, courseID: "9692",
            documents: [syllabus(course, id: "9692", text: "Midterm 1: Oct 23")],
            feed: [feedItem(course, id: "9692", title: "Midterm 1", due: nil)],
            announcements: [announced]
        ) { state, _ in
            await fileExams(state)
            #expect(cards(state, course).map(\.id) == [announced.id])
        }
        try await withState(
            course: course, courseID: "9692",
            documents: [syllabus(course, id: "9692", text: "Midterm 1: Oct 23")],
            feed: [feedItem(course, id: "9692", title: "Midterm 1", due: Self.date(10, 23, 14))],
            announcements: [announced]
        ) { state, _ in
            await fileExams(state)
            #expect(cards(state, course).map(\.source) == [.canvas], "a dated Canvas exam is the one the class sees")
        }
    }

    @Test("a tick on the undated Canvas exam follows onto the dated card that took its place")
    func tickFollowsDisplacedFeedExam() async throws {
        let course = "SYLDASH 9693"
        try await withState(
            course: course, courseID: "9693",
            documents: [syllabus(course, id: "9693", text: "Midterm 1: Oct 23")],
            feed: [feedItem(course, id: "9693", title: "Midterm 1", due: nil)]
        ) { state, _ in
            let feed = try #require(state.canvasItems.first { $0.title == "Midterm 1" })
            defer { state.markActive(feed) }
            state.markCompleted(feed)
            await fileExams(state)

            let row = try #require(state.announcementItems.first { $0.course == course })
            #expect(state.isCompleted(row))
            #expect(cards(state, course).isEmpty)
        }
    }

    @Test("the student's own task named like the exam is not displaced: only Canvas and Gradescope items are")
    func manualTaskIsNotDisplaced() async throws {
        let course = "SYLDASH 9694"
        try await withState(
            course: course, courseID: "9694",
            documents: [syllabus(course, id: "9694", text: "Midterm 1: Oct 23")]
        ) { state, _ in
            state.gradescopeItems = []
            let own = ManualAssignment(title: "Midterm 1", course: course, dueAt: nil)
            state.addManualAssignment(own)
            defer { state.removeManualAssignment(id: own.id) }
            await fileExams(state)
            #expect(cards(state, course).map(\.source) == [.manual])
        }
    }

    // MARK: A class that goes away during the read

    @Test("Canvas disconnected while the syllabus is being read writes nothing")
    func disconnectDuringTheRead() async throws {
        let course = "SYLDASH 9695"
        try await withState(
            course: course, courseID: "9695",
            documents: [syllabus(course, id: "9695", text: "Midterm 1: Oct 23")]
        ) { state, store in
            state.syllabusExamComputedHookForTesting = { [state] in
                // What `disconnectCanvas` does to the class map.
                state.canvasItems = []
                state.coursePreferences.setCanvasCourseID(course, nil)
            }
            await state.syncSyllabusExams(now: Self.now)
            #expect(syllabusRows(store).isEmpty)
        }
    }

    @Test("the same exam on Canvas, on Ed and in the syllabus is one card, the Canvas announcement")
    func threeSources() async throws {
        let course = "SYLDASH 9627"
        let canvas = canvasAnnouncement(course, "96270001", title: "Midterm 1", due: Self.date(10, 23, 14))
        let ed = edAnnouncement(course, courseID: "9627", thread: "96270002", title: "Midterm 1", due: Self.date(10, 23, 14))
        try await withState(
            course: course, courseID: "9627",
            documents: [syllabus(course, id: "9627", text: "Midterm 1: Oct 23")],
            announcements: [ed, canvas]
        ) { state, _ in
            await fileExams(state)
            #expect(cards(state, course).map(\.id) == [canvas.id])
        }
    }

    @Test("a tick on the exam follows it onto the card that is shown")
    func completionFollows() async throws {
        let course = "SYLDASH 9628"
        try await withState(
            course: course, courseID: "9628",
            documents: [syllabus(course, id: "9628", text: "Midterm 1: Oct 23")]
        ) { state, store in
            await fileExams(state)
            let syllabusCard = try #require(cards(state, course).first)
            state.markCompleted(syllabusCard)
            #expect(state.isCompleted(syllabusCard))

            // The announcement arrives afterwards and becomes the card.
            let announced = canvasAnnouncement(course, "96280001", title: "Midterm 1", due: Self.date(10, 24, 14))
            store.upsert([announced])
            state.applyAnnouncementLedgerChange()
            state.rebuildDashboardItemsForTesting(now: Self.now)

            #expect(state.isCompleted(announced), "the finished exam stays finished on the card that replaced it")
            #expect(cards(state, course).isEmpty, "and a finished exam is not on the dashboard")
        }
    }

    // MARK: Past exams

    @Test("an exam whose date has passed is in prev, marked past; an upcoming one is not")
    func pastExamGoesToPrev() async throws {
        let course = "SYLDASH 9631"
        try await withState(
            course: course, courseID: "9631",
            documents: [syllabus(course, id: "9631", text: "Midterm 1: Sep 20\nMidterm 2: Nov 20")]
        ) { state, _ in
            await fileExams(state)
            #expect(titles(state, course) == ["Midterm 2"])
            #expect(state.lapsedAnnouncementItems.filter { $0.course == course }.map(\.title) == ["Midterm 1"])

            let vm = DashboardViewModel()
            vm.bind(to: state)
            let prev = vm.doneSections(now: Self.now).flatMap(\.items).filter { $0.assignment.course == course }
            #expect(prev.map(\.assignment.title) == ["Midterm 1"])
            #expect(prev.allSatisfy { $0.isPast && !$0.isCompleted })
            #expect(vm.items.filter { $0.assignment.course == course && $0.assignment.title != "Seed" }
                .map(\.assignment.title) == ["Midterm 2"])
        }
    }

    @Test("an all-day exam stays on the dashboard all of its day and is put away when the day is over; a timed one when its time passes")
    func allDayLapsesAtTheEndOfItsDay() async throws {
        let course = "SYLDASH 9632"
        try await withState(
            course: course, courseID: "9632",
            documents: [syllabus(course, id: "9632", text: "Midterm 1: Oct 18\nMidterm 2: Oct 18, 9 am")]
        ) { state, _ in
            await fileExams(state)
            // Noon on the day: the morning exam is over, the all-day one is not.
            #expect(titles(state, course) == ["Midterm 1"])
            #expect(state.lapsedAnnouncementItems.filter { $0.course == course }.map(\.title) == ["Midterm 2"])

            state.rebuildDashboardItemsForTesting(now: Self.date(10, 19, 0, 1))
            #expect(cards(state, course).isEmpty)
            #expect(Set(state.lapsedAnnouncementItems.filter { $0.course == course }.map(\.title)) == ["Midterm 1", "Midterm 2"])
        }
    }

    @Test("a Gradescope exam keeps the feed's behaviour: overdue until it is handed in, never put away as past")
    func feedExamIsNotLapsed() async throws {
        let course = "SYLDASH 9633"
        try await withState(
            course: course, courseID: "9633",
            documents: [syllabus(course, id: "9633", text: "Midterm 1: Oct 17")]
        ) { state, _ in
            // Gradescope, not Canvas: an overdue Canvas item is held back on a
            // fresh launch until Grade Watcher has checked it, which is its
            // own rule and not what this is about.
            state.gradescopeItems = [Assignment(
                source: .gradescope, sourceID: "syldash-9633-g1", kind: .assignment, course: course,
                title: "Midterm 1", dueAt: Self.date(10, 17, 14), url: nil
            )]
            await fileExams(state)
            let found = cards(state, course)
            #expect(found.map(\.source) == [.gradescope], "the syllabus's copy is the one that goes")
            #expect(state.lapsedAnnouncementItems.filter { $0.course == course }.isEmpty)
        }
    }

    // MARK: The switches

    @Test("the class's \"announcements on dashboard\" switch hides announced tasks but not exams, found in the syllabus or announced")
    func announcementSwitchSparesExams() async throws {
        let course = "SYLDASH 9641"
        let due = Self.date(10, 21, 14)
        try await withState(
            course: course, courseID: "9641",
            documents: [syllabus(course, id: "9641", text: "Midterm 1: Oct 23")],
            announcements: [
                canvasAnnouncement(course, "96410001", title: "Submit the lab report", due: due),
                canvasAnnouncement(course, "96410002", title: "Final Exam", due: Self.date(10, 30, 14)),
            ]
        ) { state, _ in
            let original = state.coursePreferences.announcementAssignmentsOnDashboard(course)
            defer { state.setAnnouncementAssignmentsOnDashboard(course, original) }
            await fileExams(state)

            state.setAnnouncementAssignmentsOnDashboard(course, true)
            state.rebuildDashboardItemsForTesting(now: Self.now)
            #expect(titles(state, course) == ["Submit the lab report", "Final Exam", "Midterm 1"])

            state.setAnnouncementAssignmentsOnDashboard(course, false)
            state.rebuildDashboardItemsForTesting(now: Self.now)
            #expect(titles(state, course) == ["Final Exam", "Midterm 1"])
        }
    }

    @Test("the class's \"items with nothing to submit\" switch hides readings but not exams")
    func nothingToSubmitSwitchSparesExams() async throws {
        let course = "SYLDASH 9642"
        let due = Self.date(10, 21, 14)
        try await withState(
            course: course, courseID: "9642",
            documents: [syllabus(course, id: "9642", text: "Midterm 1: Oct 23")],
            announcements: [
                canvasAnnouncement(course, "96420001", title: "Read chapter 4 before Friday", due: due, kind: .event),
                canvasAnnouncement(course, "96420002", title: "Submit the lab report", due: due),
            ]
        ) { state, _ in
            let original = state.coursePreferences.nothingToSubmitEnabled(course)
            defer { state.setNothingToSubmitEnabled(course, original) }
            await fileExams(state)

            state.setNothingToSubmitEnabled(course, true)
            state.rebuildDashboardItemsForTesting(now: Self.now)
            #expect(titles(state, course) == ["Read chapter 4 before Friday", "Submit the lab report", "Midterm 1"])

            state.setNothingToSubmitEnabled(course, false)
            state.rebuildDashboardItemsForTesting(now: Self.now)
            #expect(titles(state, course) == ["Submit the lab report", "Midterm 1"])
        }
    }

    @Test("a past exam in prev is not hidden by the nothing-to-submit switch either")
    func pastExamSparedToo() async throws {
        let course = "SYLDASH 9643"
        try await withState(
            course: course, courseID: "9643",
            documents: [syllabus(course, id: "9643", text: "Midterm 1: Sep 20")]
        ) { state, _ in
            let original = state.coursePreferences.nothingToSubmitEnabled(course)
            defer { state.setNothingToSubmitEnabled(course, original) }
            state.setNothingToSubmitEnabled(course, false)
            await fileExams(state)
            #expect(state.lapsedAnnouncementItems.filter { $0.course == course }.map(\.title) == ["Midterm 1"])
        }
    }

    @Test("an exam shows even where the class's readings are switched off and the title is one the assessment rule does not know")
    func excludedContentSparesExams() async throws {
        let course = "SYLDASH 9644"
        // The decisions are one JSON blob in the shared domain
        // (`CourseContentDashboardTests` documents the race), so it is backed up
        // and put back exactly as it was.
        let decisionsKey = "courseContentDecisionsV1"
        let saved = UserDefaults.lhf.data(forKey: decisionsKey)
        defer {
            if let saved { UserDefaults.lhf.set(saved, forKey: decisionsKey) }
            else { UserDefaults.lhf.removeObject(forKey: decisionsKey) }
        }
        try await withState(
            course: course, courseID: "9644",
            documents: [syllabus(course, id: "9644", text: "Test 2: Oct 23")],
            announcements: [canvasAnnouncement(course, "96440001", title: "Read chapter 4 before Friday", due: Self.date(10, 21, 14), kind: .event)]
        ) { state, _ in
            state.setCourseContentIncluded(course, false)
            await fileExams(state)
            #expect(titles(state, course) == ["Test 2"], "the reading is off with the class's readings; the exam is not")
        }
    }

    @Test("a hidden class shows no exam, and shows it again the moment it is turned back on")
    func hiddenClass() async throws {
        let course = "SYLDASH 9645"
        try await withState(
            course: course, courseID: "9645",
            documents: [syllabus(course, id: "9645", text: "Midterm 1: Oct 23")]
        ) { state, _ in
            await fileExams(state)
            #expect(titles(state, course) == ["Midterm 1"])

            state.setCourse(course, selected: false)
            state.rebuildDashboardItemsForTesting(now: Self.now)
            #expect(cards(state, course).isEmpty)
            #expect(state.lapsedAnnouncementItems.filter { $0.course == course }.isEmpty)

            state.setCourse(course, selected: true)
            state.rebuildDashboardItemsForTesting(now: Self.now)
            #expect(titles(state, course) == ["Midterm 1"])
        }
    }

    // MARK: Placement and order

    @Test("a syllabus row is always a card, even where its words would read as information; an announcement's are not")
    func syllabusRowsAreAlwaysCards() {
        func row(_ sourceID: String) -> Assignment {
            Assignment(source: .canvasAnnouncement, sourceID: sourceID, kind: .event, course: "SYLDASH 9681",
                       title: "Quiz grades posted", dueAt: nil, url: nil)
        }
        #expect(AppState.announcementDashboardPlacement(for: row("syllabus-9681-midterm-1")) == .main)
        #expect(AppState.announcementDashboardPlacement(for: row("announcement-96810001-0")) == .find)
    }

    @Test("the duplicate check meets every announcement before the syllabus, whatever the ids sort like, and a dated syllabus row before an undated announcement")
    func dedupOrder() {
        func row(_ sourceID: String, due: Date?) -> Assignment {
            Assignment(source: .canvasAnnouncement, sourceID: sourceID, kind: .assignment, course: "SYLDASH 9682",
                       title: "Midterm 1", dueAt: due, url: nil)
        }
        let day = Self.date(10, 23, 14)
        let syllabusRow = row("syllabus-9682-midterm-1", due: day)
        // A legacy-shaped id that sorts after "syllabus-": only the rule, and not the
        // alphabet, can put the announcement first.
        let late = row("zzz-legacy-0", due: day)
        let ed = row("ed-9682-33-0", due: day)
        let undated = row("announcement-96820001-0", due: nil)

        let ordered = AppState.announcementDedupOrder([syllabusRow, undated, late, ed]).map(\.sourceID)
        #expect(ordered == ["zzz-legacy-0", "ed-9682-33-0", "syllabus-9682-midterm-1", "announcement-96820001-0"])
    }

    // MARK: Where they are not

    @Test("the megaphone lists an announced exam and leaves the syllabus's out: it was found in no announcement")
    func megaphone() async throws {
        let course = "SYLDASH 9651"
        let announced = canvasAnnouncement(course, "96510001", title: "Final Exam", due: Self.date(10, 30, 14))
        try await withState(
            course: course, courseID: "9651",
            documents: [syllabus(course, id: "9651", text: "Midterm 1: Oct 23")],
            announcements: [announced]
        ) { state, _ in
            await fileExams(state)
            #expect(titles(state, course) == ["Midterm 1", "Final Exam"])
            #expect(state.announcementPageItems.filter { $0.course == course }.map(\.id) == [announced.id])
            #expect(state.announcementFinds.filter { $0.course == course }.isEmpty)
        }
    }

    // MARK: Reminders

    @Test("an exam is reminded about the ordinary way and never gets the loud 10-minute alert; unsubmitted work and a Canvas exam still do")
    func remindersButNoLoudAlert() async throws {
        let course = "SYLDASH 9661"
        let announcedExam = canvasAnnouncement(course, "96610001", title: "Midterm 2", due: Self.date(10, 28, 14))
        let task = canvasAnnouncement(course, "96610002", title: "Submit the lab report", due: Self.date(10, 21, 14))
        try await withState(
            course: course, courseID: "9661",
            documents: [syllabus(course, id: "9661", text: "Midterm 1: Oct 23")],
            feed: [feedItem(course, id: "9661", number: 5, title: "Quiz 3", due: Self.date(10, 22, 14))],
            announcements: [announcedExam, task]
        ) { state, _ in
            await fileExams(state)
            let vm = DashboardViewModel()
            vm.bind(to: state)
            let items = vm.items.filter { $0.assignment.course == course && $0.assignment.title != "Seed" }
            let syllabusExam = try #require(items.first { $0.assignment.title == "Midterm 1" })
            #expect(items.count == 4)

            let name = "lhf.tests.\(UUID().uuidString)"
            let defaults = try #require(UserDefaults(suiteName: name))
            defer { UserDefaults.standard.removePersistentDomain(forName: name) }
            let scheduler = NotificationScheduler(defaults: defaults)
            let prefs = CoursePreferencesStore(defaults: defaults)
            let requests = scheduler.plannedRequests(from: items, now: Self.now, preferences: prefs)

            func has(_ prefix: String, _ item: DashItem) -> Bool {
                requests.contains { $0.identifier.hasPrefix("\(prefix):\(item.id):") }
            }
            let announced = try #require(items.first { $0.assignment.title == "Midterm 2" })
            let submit = try #require(items.first { $0.assignment.title == "Submit the lab report" })
            let quiz = try #require(items.first { $0.assignment.title == "Quiz 3" })

            // Exams: the ordinary lead-time reminders, no loud alert.
            for exam in [syllabusExam, announced] {
                #expect(has("due", exam), "\(exam.assignment.title) is reminded about")
                #expect(!has("loud", exam), "\(exam.assignment.title) gets no loud alert")
            }
            // The rest is as it was.
            #expect(has("loud", submit))
            #expect(has("loud", quiz))
            // The syllabus exam is the kind the loud alert already leaves out; the
            // announced one is the kind it needed a rule for.
            #expect(syllabusExam.showsNothingToSubmit)
            #expect(!announced.showsNothingToSubmit)
        }
    }

    // MARK: How the card is drawn

    @Test("a found exam is an exam card whatever its title says; a feed item is left to its title")
    func cardStyle() async throws {
        let course = "SYLDASH 9671"
        try await withState(
            course: course, courseID: "9671",
            documents: [syllabus(course, id: "9671", text: "Test 2: Oct 23")],
            feed: [
                feedItem(course, id: "9671", number: 1, title: "Midterm 1", due: Self.date(10, 25, 14)),
                feedItem(course, id: "9671", number: 2, title: "Problem set 4", due: Self.date(10, 25, 14)),
            ]
        ) { state, _ in
            await fileExams(state)
            let vm = DashboardViewModel()
            vm.bind(to: state)
            @MainActor func item(_ title: String) -> DashItem? {
                vm.items.first { $0.assignment.course == course && $0.assignment.title == title }
            }
            let found = try #require(item("Test 2"))
            let feedExam = try #require(item("Midterm 1"))
            let homework = try #require(item("Problem set 4"))
            #expect(found.examStyleOverride == true)
            #expect(feedExam.examStyleOverride == nil, "a feed exam keeps the title to decide, as before")
            #expect(homework.examStyleOverride == nil)
            #expect(homework.caveatText == nil)
        }
    }
}
