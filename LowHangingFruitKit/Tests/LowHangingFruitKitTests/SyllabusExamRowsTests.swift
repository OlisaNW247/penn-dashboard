import Foundation
import Testing
@testable import LowHangingFruitKit

/// The ledger rows a syllabus produces: stable ids, one row per exam, the
/// date stored the way every other all-day entry is, and the round trip
/// through the ledger.
///
/// The reference date is fixed (October 18, 2026, New York) and so is every
/// exam date, so the extractor's choice of year cannot move under the tests.
@Suite("Syllabus exam rows")
struct SyllabusExamRowsTests {

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    private static func date(_ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date {
        calendar.date(from: DateComponents(
            year: 2026, month: month, day: day, hour: hour, minute: minute, second: second
        ))!
    }

    private static let now = date(10, 18, 12)
    private static let courses = ["9601": "SYLROW 9601", "9602": "SYLROW 9602"]
    private static let syllabusURL = URL(string: "https://canvas.upenn.edu/courses/9601/assignments/syllabus")

    private func document(
        _ kind: CourseDocument.Kind,
        course: String = "9601",
        sourceID: String = "1",
        text: String,
        url: URL? = SyllabusExamRowsTests.syllabusURL
    ) -> CourseDocument {
        CourseDocument(
            courseID: course, course: "SYLROW \(course)", kind: kind, sourceID: sourceID,
            title: kind.label, url: url, text: text, updatedAt: nil, fetchedAt: Self.now
        )
    }

    private func rows(_ documents: [CourseDocument], courses: [String: String] = SyllabusExamRowsTests.courses) -> [Assignment] {
        SyllabusExamRows.assignments(
            from: documents, courseCodesByID: courses, referenceDate: Self.now, calendar: Self.calendar
        )
    }

    // MARK: The rows

    @Test("each exam a syllabus names becomes a row with a stable id, the class's code, the page's link and nothing to hand in")
    func rowsFromASyllabus() {
        let found = rows([document(.syllabus, text: """
            Course policies go here.
            Midterm 1: Oct 23
            Final Exam: Dec 15
            """)])
        #expect(found.map(\.sourceID) == ["syllabus-9601-midterm-1", "syllabus-9601-final"])
        #expect(found.map(\.title) == ["Midterm 1", "Final Exam"])
        #expect(found.allSatisfy {
            $0.source == .canvasAnnouncement && $0.kind == .event && $0.course == "SYLROW 9601"
                && $0.url == Self.syllabusURL && $0.term == nil && !$0.submitted
        })
        #expect(found.allSatisfy { $0.announcementOrigin == .syllabus && $0.isFoundExam })
    }

    @Test("reading the same material again gives the same rows, in the same order")
    func idempotent() {
        let documents = [
            document(.syllabus, text: "Midterm 1: Oct 23\nFinal Exam: Dec 15"),
            document(.home, sourceID: "home", text: "Midterm 1: Oct 23"),
        ]
        #expect(rows(documents) == rows(documents))
        #expect(rows(documents) == rows(documents.reversed()))
    }

    @Test("an exam with a date and no time is stored at the end of its day; one with a time keeps it")
    func allDayAndTimed() throws {
        let found = rows([document(.syllabus, text: """
            Midterm 1: Oct 23
            Midterm 2: Nov 20, 7 pm
            """)])
        let first = try #require(found.first { $0.title == "Midterm 1" })
        let second = try #require(found.first { $0.title == "Midterm 2" })
        #expect(first.dueAt == Self.date(10, 23, 23, 59, 59))
        #expect(AllDayDueMoment.isEndOfDay(try #require(first.dueAt), calendar: Self.calendar))
        #expect(second.dueAt == Self.date(11, 20, 19, 0))
    }

    @Test("an exam earlier this term is kept, so the dashboard can put it in prev; one from a previous term is not")
    func earlierThisTermAndStale() {
        let found = rows([document(.syllabus, text: """
            Midterm 1: Sep 20
            Midterm 2: Nov 20
            Final Exam: Dec 15, 2025
            """)])
        #expect(found.map(\.title) == ["Midterm 1", "Midterm 2"])
        #expect(found.first?.dueAt == Self.date(9, 20, 23, 59, 59))
    }

    // MARK: One row per exam

    @Test("the same exam in the syllabus and on the home page is one row, and the syllabus's date wins")
    func syllabusBeatsHomePage() throws {
        let found = rows([
            document(.page, sourceID: "p", text: "Midterm 1: Nov 2"),
            document(.home, sourceID: "h", text: "Midterm 1: Oct 30"),
            document(.syllabus, text: "Midterm 1: Oct 23"),
        ])
        let only = try #require(found.first)
        #expect(found.count == 1)
        #expect(only.dueAt == Self.date(10, 23, 23, 59, 59))
    }

    @Test("an exam only the home page names is found there")
    func homePageAlone() {
        let found = rows([
            document(.syllabus, text: "No dates in this one."),
            document(.home, sourceID: "h", text: "Final Exam: Dec 15"),
        ])
        #expect(found.map(\.sourceID) == ["syllabus-9601-final"])
    }

    @Test("one document that names an exam on two different days gives one row, the first")
    func twoDaysForOneExam() {
        let found = rows([document(.syllabus, text: "Midterm 1: Oct 23\nMidterm 1: Oct 24")])
        #expect(found.count == 1)
        #expect(found.first?.dueAt == Self.date(10, 23, 23, 59, 59))
    }

    @Test("a makeup is its own row under its own id, and says so on the card")
    func makeup() throws {
        let found = rows([document(.syllabus, text: """
            Midterm 1: Oct 23
            Makeup Midterm 1: Nov 5
            """)])
        #expect(Set(found.map(\.sourceID)) == ["syllabus-9601-midterm-1", "syllabus-9601-midterm-1-makeup"])
        let makeup = try #require(found.first { $0.sourceID.hasSuffix("makeup") })
        #expect(makeup.title == "Makeup Midterm 1")
        // The title alone is enough to see the same identity again, which is
        // how the dashboard's duplicate check reads these rows.
        #expect(ExamDetection.examIdentity(title: makeup.title, course: makeup.course)?.sourceKey == "midterm-1-makeup")
    }

    @Test("every row's title reads back as the exam its id says it is")
    func titleAndIDAgree() {
        let found = rows([document(.syllabus, text: """
            Midterm: Oct 23
            Midterm 2: Nov 20
            MT3 - Dec 1
            Final Exam: Dec 15
            Exam II: Nov 22
            """)])
        #expect(found.count >= 4)
        for row in found {
            let key = ExamDetection.examIdentity(title: row.title, course: row.course)?.sourceKey
            #expect(row.sourceID == "syllabus-9601-\(key ?? "?")", "\(row.title) is filed as \(row.sourceID)")
        }
    }

    // MARK: Which documents and which classes

    @Test("only the syllabus, the course home page and course pages are read")
    func documentKinds() {
        let text = "Midterm 1: Oct 23"
        for kind in CourseDocument.Kind.allCases {
            let found = rows([document(kind, text: text)])
            let expected = [CourseDocument.Kind.syllabus, .home, .page].contains(kind)
            #expect(found.isEmpty == !expected, "\(kind)")
        }
    }

    @Test("a site the app cannot name a class for is skipped, and two classes keep their own rows")
    func courses() {
        let found = rows([
            document(.syllabus, course: "9601", text: "Midterm 1: Oct 23"),
            document(.syllabus, course: "9602", sourceID: "2", text: "Midterm 1: Oct 24"),
            document(.syllabus, course: "9699", sourceID: "3", text: "Midterm 1: Oct 25"),
        ])
        #expect(found.map(\.sourceID) == ["syllabus-9601-midterm-1", "syllabus-9602-midterm-1"])
        #expect(found.map(\.course) == ["SYLROW 9601", "SYLROW 9602"])
        #expect(rows([document(.syllabus, text: "Midterm 1: Oct 23")], courses: [:]).isEmpty)
    }

    @Test("text that names no exam, or only the false friends, gives no rows")
    func nothingToFind() {
        #expect(rows([document(.syllabus, text: "")]).isEmpty)
        #expect(rows([document(.syllabus, text: """
            Final Project due Dec 10
            Midterm Review Session: Oct 21
            Practice Exam 2: Oct 22
            """)]).isEmpty)
    }

    // MARK: The ledger

    @Test("rows survive the ledger: same id, same origin, same date; a second write adds nothing")
    @MainActor
    func ledgerRoundTrip() throws {
        let store = try AssignmentStore(inMemory: true)
        let found = rows([document(.syllabus, text: "Midterm 1: Oct 23\nFinal Exam: Dec 15")])
        #expect(store.upsert(found, now: Self.now) == 2)

        let stored = store.assignments(source: .canvasAnnouncement, now: Self.now)
        #expect(Set(stored.map(\.id)) == Set(found.map(\.id)))
        #expect(stored.allSatisfy { $0.announcementOrigin == .syllabus && $0.kind == .event })
        #expect(Set(stored.compactMap(\.dueAt)) == Set(found.compactMap(\.dueAt)))
        #expect(stored.first { $0.title == "Midterm 1" }?.url == Self.syllabusURL)

        // The second run finds the same two, so nothing new is created.
        #expect(store.upsert(rows([document(.syllabus, text: "Midterm 1: Oct 23\nFinal Exam: Dec 15")]), now: Self.now) == 0)
        #expect(store.assignments(source: .canvasAnnouncement, now: Self.now).count == 2)
    }

    @Test("a moved date updates the row it belongs to, and a tick on the exam stays")
    @MainActor
    func movedDateKeepsTheRowAndTheTick() throws {
        let store = try AssignmentStore(inMemory: true)
        let original = try #require(rows([document(.syllabus, text: "Midterm 1: Oct 23")]).first)
        store.upsert([original], now: Self.now)
        store.setCompleted(ids: [original.id], at: Self.now)

        let moved = try #require(rows([document(.syllabus, text: "Midterm 1: Oct 30")]).first)
        #expect(moved.id == original.id)
        store.upsert([moved], now: Self.now)

        let stored = store.assignments(source: .canvasAnnouncement, now: Self.now)
        #expect(stored.count == 1)
        #expect(stored.first?.dueAt == Self.date(10, 30, 23, 59, 59))
        #expect(store.completionRecordOrFail().ids.contains(original.id))
    }
}
