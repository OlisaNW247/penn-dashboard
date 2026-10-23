import Foundation
import Testing
@testable import LowHangingFruitKit

/// The ledger rows a class's syllabus produces when the server has already
/// read it (`CourseGradingProfile.examDates`): a dated server exam wins over
/// the phone's own reading of the same exam and keeps its row, a server-only
/// exam becomes a row, and everything the server leaves out is still read on
/// the phone.
///
/// The reference date is fixed (October 18, 2026, New York), as in
/// `SyllabusExamRowsTests`, so the previous-term cut-off cannot move under
/// the tests. Class codes and course ids are unique to this suite.
@Suite("Syllabus exam rows, server dates")
struct SyllabusExamServerRowsTests {

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
    private static let courses = ["9701": "SRVROW 9701", "9702": "SRVROW 9702"]
    private static let syllabusURL = URL(string: "https://canvas.upenn.edu/courses/9701/assignments/syllabus")
    private static let homeURL = URL(string: "https://canvas.upenn.edu/courses/9701")

    private func document(
        _ kind: CourseDocument.Kind = .syllabus,
        course: String = "9701",
        sourceID: String = "1",
        text: String,
        url: URL? = SyllabusExamServerRowsTests.syllabusURL
    ) -> CourseDocument {
        CourseDocument(
            courseID: course, course: "SRVROW \(course)", kind: kind, sourceID: sourceID,
            title: kind.label, url: url, text: text, updatedAt: nil, fetchedAt: Self.now
        )
    }

    private func profile(
        _ course: String = "9701",
        exams: [CourseGradingProfile.ExamDate]
    ) -> CourseGradingProfile {
        CourseGradingProfile(
            courseID: course, weights: [], components: [], extractedAt: Self.now, examDates: exams
        )
    }

    private func exam(_ name: String, _ date: String? = nil, text: String = "") -> CourseGradingProfile.ExamDate {
        CourseGradingProfile.ExamDate(name: name, date: date, text: text)
    }

    private func rows(
        documents: [CourseDocument] = [],
        profiles: [CourseGradingProfile],
        courses: [String: String] = SyllabusExamServerRowsTests.courses
    ) -> [Assignment] {
        SyllabusExamRows.assignments(
            from: documents, profiles: profiles, courseCodesByID: courses,
            referenceDate: Self.now, calendar: Self.calendar
        )
    }

    // MARK: The server's exams become rows

    @Test("a dated exam the server names becomes a row with the same kind of id, title and shape as one read on the phone")
    func serverOnlyExam() throws {
        let found = rows(
            documents: [document(text: "Nothing with a date here.")],
            profiles: [profile(exams: [exam("Midterm 1", "2026-10-23", text: "Midterm 1: Thursday, October 23")])]
        )
        let only = try #require(found.first)
        #expect(found.count == 1)
        #expect(only.sourceID == "syllabus-9701-midterm-1")
        #expect(only.title == "Midterm 1")
        #expect(only.source == .canvasAnnouncement && only.kind == .event && !only.submitted)
        #expect(only.course == "SRVROW 9701")
        #expect(only.dueAt == Self.date(10, 23, 23, 59, 59))
        #expect(only.url == Self.syllabusURL)
        #expect(only.announcementOrigin == .syllabus && only.isFoundExam)
    }

    @Test("the server's profile alone is enough: no course material on the phone yet")
    func profileWithoutDocuments() {
        let found = rows(profiles: [profile(exams: [exam("Final Exam", "2026-12-15")])])
        #expect(found.map(\.sourceID) == ["syllabus-9701-final"])
        #expect(found.first?.url == nil)
    }

    @Test("an undated server entry is ignored; so is one whose date is not a day, and neither displaces a date the phone found")
    func undatedIsIgnored() {
        let onlyUndated = rows(profiles: [profile(exams: [
            exam("Midterm 1"),
            exam("Final Exam", "October 23"),
            exam("Midterm 2", "2026-02-30"),
        ])])
        #expect(onlyUndated.isEmpty)

        let withPhoneReading = rows(
            documents: [document(text: "Midterm 1: Oct 23")],
            profiles: [profile(exams: [exam("Midterm 1")])]
        )
        #expect(withPhoneReading.map(\.sourceID) == ["syllabus-9701-midterm-1"])
        #expect(withPhoneReading.first?.dueAt == Self.date(10, 23, 23, 59, 59))
    }

    // MARK: The server wins

    @Test("for the same exam the server's date wins over the phone's reading, in the same row")
    func serverWins() throws {
        let phoneOnly = rows(documents: [document(text: "Midterm 1: Oct 23")], profiles: [])
        let withServer = rows(
            documents: [document(text: "Midterm 1: Oct 23")],
            profiles: [profile(exams: [exam("Midterm 1", "2026-10-30")])]
        )
        let before = try #require(phoneOnly.first)
        let after = try #require(withServer.first)
        #expect(withServer.count == 1)
        #expect(after.id == before.id, "the same exam keeps one ledger row")
        #expect(after.sourceID == "syllabus-9701-midterm-1")
        #expect(before.dueAt == Self.date(10, 23, 23, 59, 59))
        #expect(after.dueAt == Self.date(10, 30, 23, 59, 59))
    }

    @Test("the server's spelling of the same exam finds the phone's row: Midterm #1, midterm exam 1 and MT1 are one id")
    func spellingsAgree() {
        for name in ["Midterm #1", "midterm exam 1", "MT1", "First Midterm", "Midterm Exam I"] {
            let found = rows(profiles: [profile(exams: [exam(name, "2026-10-23")])])
            #expect(found.map(\.sourceID) == ["syllabus-9701-midterm-1"], "\(name)")
        }
    }

    @Test("an exam only the server found is added; an exam only the phone found is kept; the phone's come first")
    func union() {
        let found = rows(
            documents: [document(text: "Midterm 1: Oct 23\nMidterm 2: Nov 20")],
            profiles: [profile(exams: [exam("Midterm 2", "2026-11-19"), exam("Final Exam", "2026-12-15")])]
        )
        #expect(found.map(\.sourceID) == ["syllabus-9701-midterm-1", "syllabus-9701-midterm-2", "syllabus-9701-final"])
        #expect(found.map(\.dueAt) == [
            Self.date(10, 23, 23, 59, 59), Self.date(11, 19, 23, 59, 59), Self.date(12, 15, 23, 59, 59),
        ])
    }

    @Test("a class the server has nothing for is read on the phone exactly as before")
    func otherClassUnchanged() {
        let found = rows(
            documents: [
                document(course: "9701", text: "Midterm 1: Oct 23"),
                document(course: "9702", sourceID: "2", text: "Midterm 1: Oct 24"),
            ],
            profiles: [profile("9701", exams: [exam("Midterm 1", "2026-10-30")])]
        )
        #expect(found.map(\.sourceID) == ["syllabus-9701-midterm-1", "syllabus-9702-midterm-1"])
        #expect(found.map(\.dueAt) == [Self.date(10, 30, 23, 59, 59), Self.date(10, 24, 23, 59, 59)])
    }

    @Test("a makeup is its own exam under its own id, whichever reading names it")
    func makeup() throws {
        let found = rows(profiles: [profile(exams: [
            exam("Midterm 1", "2026-10-23"),
            exam("Makeup Midterm 1", "2026-11-05"),
        ])])
        #expect(found.map(\.sourceID) == ["syllabus-9701-midterm-1", "syllabus-9701-midterm-1-makeup"])
        #expect(found.map(\.title) == ["Midterm 1", "Makeup Midterm 1"])
    }

    // MARK: When the phone and the server disagree, or agree on the day

    // October 18, 2026 is a Sunday: October 22 and November 19 are Thursdays,
    // October 23, October 30 and November 20 are Fridays.

    @Test("the server's day with the phone's time: when both agree on the day, the time the syllabus stated is kept")
    func samedayKeepsThePhonesTime() throws {
        let found = rows(
            documents: [document(text: "Midterm 2: Nov 20, 7 pm")],
            profiles: [profile(exams: [exam("Midterm Exam 2", "2026-11-20")])]
        )
        let only = try #require(found.first)
        #expect(found.count == 1)
        #expect(only.dueAt == Self.date(11, 20, 19, 0))
        // The row is still the server's: its title, and the same id.
        #expect(only.title == "Midterm Exam 2")
        #expect(only.sourceID == "syllabus-9701-midterm-2")
    }

    @Test("when both agree on the day and the phone found no time, the exam is all-day, as before")
    func samedayWithoutATime() {
        let found = rows(
            documents: [document(text: "Midterm 1: Oct 23")],
            profiles: [profile(exams: [exam("Midterm 1", "2026-10-23")])]
        )
        #expect(found.first?.dueAt == Self.date(10, 23, 23, 59, 59))
    }

    @Test("a phone reading whose weekday fits its date stands against a server date on another day")
    func weekdayConfirmedPhoneWins() throws {
        let found = rows(
            documents: [document(text: "Midterm 1: Thursday, October 22")],
            profiles: [profile(exams: [exam("Midterm Exam 1", "2026-10-30")])]
        )
        let only = try #require(found.first)
        #expect(found.count == 1)
        #expect(only.dueAt == Self.date(10, 22, 23, 59, 59))
        // The whole row is the phone's, not the server's with a different day.
        #expect(only.title == "Midterm 1")
        #expect(only.sourceID == "syllabus-9701-midterm-1")
    }

    @Test("a confirmed phone reading keeps its time when it stands")
    func weekdayConfirmedPhoneWinsWithATime() {
        let found = rows(
            documents: [document(text: "Midterm 1: Thursday, October 22, 7 pm")],
            profiles: [profile(exams: [exam("Midterm 1", "2026-10-30")])]
        )
        #expect(found.first?.dueAt == Self.date(10, 22, 19, 0))
    }

    @Test("a phone reading with no weekday, or a weekday that fits no year, loses to the server's date")
    func unconfirmedPhoneLoses() {
        // Nothing written beside the date.
        let bare = rows(
            documents: [document(text: "Midterm 1: Oct 22")],
            profiles: [profile(exams: [exam("Midterm 1", "2026-10-30")])]
        )
        #expect(bare.first?.dueAt == Self.date(10, 30, 23, 59, 59))
        // October 22 is a Thursday in 2026 and a Wednesday and Friday the years
        // either side; Monday fits none, so it is a typo and confirms nothing.
        let typo = rows(
            documents: [document(text: "Midterm 1: Monday, October 22")],
            profiles: [profile(exams: [exam("Midterm 1", "2026-10-30")])]
        )
        #expect(typo.first?.dueAt == Self.date(10, 30, 23, 59, 59))
    }

    @Test("the weekday protects only the exam it was written beside")
    func confirmationIsPerExam() throws {
        let found = rows(
            documents: [document(text: "Midterm 1: Thursday, October 22\nMidterm 2: Nov 19")],
            profiles: [profile(exams: [exam("Midterm 1", "2026-10-30"), exam("Midterm 2", "2026-11-26")])]
        )
        #expect(found.map(\.sourceID) == ["syllabus-9701-midterm-1", "syllabus-9701-midterm-2"])
        #expect(found.map(\.dueAt) == [Self.date(10, 22, 23, 59, 59), Self.date(11, 26, 23, 59, 59)])
    }

    @Test("a weekday-confirmed phone reading never stops the server adding an exam the phone did not read")
    func confirmedReadingDoesNotBlockOthers() {
        let found = rows(
            documents: [document(text: "Midterm 1: Thursday, October 22")],
            profiles: [profile(exams: [exam("Midterm 1", "2026-10-30"), exam("Final Exam", "2026-12-15")])]
        )
        #expect(found.map(\.sourceID) == ["syllabus-9701-midterm-1", "syllabus-9701-final"])
        #expect(found.map(\.dueAt) == [Self.date(10, 22, 23, 59, 59), Self.date(12, 15, 23, 59, 59)])
    }

    // MARK: Which entries are exams

    @Test("the card is named for the exam, not for everything the server wrote after it")
    func titleIsTheExam() throws {
        let found = rows(profiles: [profile(exams: [
            exam("Midterm Exam 1 (chapters 1-5, in class)", "2026-10-23"),
            exam("final exam", "2026-12-15"),
        ])])
        #expect(found.map(\.title) == ["Midterm Exam 1", "Final exam"])
        #expect(found.map(\.sourceID) == ["syllabus-9701-midterm-1", "syllabus-9701-final"])
    }

    @Test("every server row's title reads back as the exam its id says it is")
    func titleAndIDAgree() {
        let found = rows(profiles: [profile(exams: [
            exam("Midterm", "2026-10-23"),
            exam("Midterm 2", "2026-11-20"),
            exam("MT3", "2026-12-01"),
            exam("Final Exam", "2026-12-15"),
            exam("Exam II", "2026-11-22"),
            exam("Alternative Midterm 2", "2026-11-25"),
            exam("Retake Final Exam", "2026-12-20"),
        ])])
        #expect(found.count == 7)
        for row in found {
            let key = ExamDetection.examIdentity(title: row.title, course: row.course)?.sourceKey
            #expect(row.sourceID == "syllabus-9701-\(key ?? "?")", "\(row.title) is filed as \(row.sourceID)")
        }
    }

    @Test("an entry that is not one exam is not filed: a quiz, a project, a category, two exams in one name")
    func notAnExam() {
        let found = rows(profiles: [profile(exams: [
            exam("Quiz 3", "2026-10-23"),
            exam("Final Project", "2026-12-10"),
            exam("Midterm Review Session", "2026-10-21"),
            exam("Practice Exam 2", "2026-10-22"),
            exam("Midterms", "2026-10-23"),
            exam("Midterm 1 and Midterm 2", "2026-10-23"),
            exam("", "2026-10-23"),
        ])])
        #expect(found.isEmpty)
    }

    @Test("an exam listed twice gives one row, the first; so does a second dated entry for it")
    func duplicateEntries() {
        let found = rows(profiles: [profile(exams: [
            exam("Midterm 1", "2026-10-23"),
            exam("Midterm 1", "2026-10-24"),
            exam("Midterm Exam 1", "2026-10-25"),
        ])])
        #expect(found.count == 1)
        #expect(found.first?.dueAt == Self.date(10, 23, 23, 59, 59))
    }

    // MARK: Dates and classes

    @Test("an exam earlier this term is kept for prev; one from a previous term is not")
    func staleServerDate() {
        let found = rows(profiles: [profile(exams: [
            exam("Midterm 1", "2026-09-20"),
            exam("Midterm 2", "2026-11-20"),
            exam("Final Exam", "2025-12-15"),
        ])])
        #expect(found.map(\.title) == ["Midterm 1", "Midterm 2"])
    }

    @Test("a profile for a site the app cannot name a class for files nothing, and two classes keep their own rows")
    func courseScoping() {
        let found = rows(profiles: [
            profile("9702", exams: [exam("Midterm 1", "2026-10-24")]),
            profile("9701", exams: [exam("Midterm 1", "2026-10-23")]),
            profile("9799", exams: [exam("Midterm 1", "2026-10-25")]),
        ])
        #expect(found.map(\.sourceID) == ["syllabus-9701-midterm-1", "syllabus-9702-midterm-1"])
        #expect(found.map(\.course) == ["SRVROW 9701", "SRVROW 9702"])
        #expect(rows(profiles: [profile(exams: [exam("Midterm 1", "2026-10-23")])], courses: [:]).isEmpty)
    }

    @Test("the same profiles in any order give the same rows")
    func deterministic() {
        let profiles = [
            profile("9701", exams: [exam("Midterm 1", "2026-10-23"), exam("Final Exam", "2026-12-15")]),
            profile("9702", exams: [exam("Midterm 1", "2026-10-24")]),
        ]
        let documents = [document(text: "Midterm 2: Nov 20")]
        #expect(rows(documents: documents, profiles: profiles) == rows(documents: documents, profiles: profiles.reversed()))
    }

    @Test("a server row links to the class's syllabus, else its home page; none when the phone holds neither")
    func link() {
        let both = rows(
            documents: [
                document(.home, sourceID: "h", text: "x", url: Self.homeURL),
                document(.syllabus, text: "x"),
            ],
            profiles: [profile(exams: [exam("Midterm 1", "2026-10-23")])]
        )
        #expect(both.first?.url == Self.syllabusURL)
        let homeOnly = rows(
            documents: [document(.home, sourceID: "h", text: "x", url: Self.homeURL)],
            profiles: [profile(exams: [exam("Midterm 1", "2026-10-23")])]
        )
        #expect(homeOnly.first?.url == Self.homeURL)
        let neither = rows(
            documents: [document(.syllabus, text: "x", url: nil)],
            profiles: [profile(exams: [exam("Midterm 1", "2026-10-23")])]
        )
        #expect(neither.first?.url == nil)
    }

    @Test("no profiles gives exactly the rows the phone's reading gave before this existed")
    func noProfilesIsTheOldBehaviour() {
        let documents = [
            document(text: "Midterm 1: Oct 23\nMidterm 2: Nov 20, 7 pm\nFinal Exam: Dec 15"),
            document(.home, sourceID: "h", text: "Midterm 1: Oct 30"),
        ]
        let old = SyllabusExamRows.assignments(
            from: documents, courseCodesByID: Self.courses, referenceDate: Self.now, calendar: Self.calendar
        )
        #expect(rows(documents: documents, profiles: []) == old)
        #expect(rows(documents: documents, profiles: [profile(exams: [])]) == old)
        #expect(old.count == 3)
    }

    // MARK: The ledger

    @Test("an exam already filed from the phone's reading is updated in place by the server's, never filed twice, and its tick stays")
    @MainActor
    func updatesInPlaceInTheLedger() throws {
        let store = try AssignmentStore(inMemory: true)
        let phone = try #require(rows(documents: [document(text: "Midterm 1: Oct 23")], profiles: []).first)
        #expect(store.upsert([phone], now: Self.now) == 1)
        store.setCompleted(ids: [phone.id], at: Self.now)

        let server = rows(
            documents: [document(text: "Midterm 1: Oct 23")],
            profiles: [profile(exams: [exam("Midterm 1", "2026-10-30"), exam("Final Exam", "2026-12-15")])]
        )
        #expect(server.map(\.sourceID) == ["syllabus-9701-midterm-1", "syllabus-9701-final"])
        // One of the two is new; the Midterm is the row that was already there.
        #expect(store.upsert(server, now: Self.now) == 1)

        let stored = store.assignments(source: .canvasAnnouncement, now: Self.now)
        #expect(stored.count == 2)
        #expect(stored.first { $0.id == phone.id }?.dueAt == Self.date(10, 30, 23, 59, 59))
        #expect(store.completionRecord().ids.contains(phone.id))

        // And a third reading, the same, adds nothing.
        #expect(store.upsert(server, now: Self.now) == 0)
    }
}
