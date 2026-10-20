import Foundation
import Testing
@testable import LowHangingFruitKit

/// `SyllabusExamExtractor`: lines that name an exam next to a date.
///
/// Weekday facts the cases lean on (checked against a calendar, not assumed):
/// October 23, 2025 is a Thursday; October 23, 2026 is a Friday.
@Suite("Syllabus exam extraction")
struct SyllabusExamExtractorTests {

    private static let newYork = TimeZone(identifier: "America/New_York")!

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = newYork
        return calendar
    }

    /// Local (New York) wall-clock time.
    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    /// A fall 2025 reference: early October, inside the term.
    private static let fall2025 = date(2025, 10, 1)

    private func extract(_ text: String, ref: Date = SyllabusExamExtractorTests.fall2025) -> [ExamCandidate] {
        SyllabusExamExtractor.extract(text: text, referenceDate: ref, calendar: Self.calendar)
    }

    private func only(_ text: String, ref: Date = SyllabusExamExtractorTests.fall2025) throws -> ExamCandidate {
        let found = extract(text, ref: ref)
        try #require(found.count == 1, "expected exactly one exam in \"\(text)\", got \(found)")
        return found[0]
    }

    // MARK: - The formats

    @Test("Midterm 1: Thursday, October 23")
    func nameColonWeekdayDate() throws {
        let exam = try only("Midterm 1: Thursday, October 23")
        #expect(exam.name == "Midterm 1")
        #expect(exam.date == Self.date(2025, 10, 23))
        #expect(!exam.hasTime)
        #expect(exam.sourceLine == "Midterm 1: Thursday, October 23")
    }

    @Test("Oct 23 \u{2013} Midterm (en dash, date first)")
    func dateFirstWithEnDash() throws {
        let exam = try only("Oct 23 \u{2013} Midterm")
        #expect(exam.name == "Midterm")
        #expect(exam.date == Self.date(2025, 10, 23))
        #expect(!exam.hasTime)
    }

    @Test("10/23 Midterm 1")
    func numericDateFirst() throws {
        let exam = try only("10/23 Midterm 1")
        #expect(exam.name == "Midterm 1")
        #expect(exam.date == Self.date(2025, 10, 23))
    }

    @Test("Final Exam \u{2014} December 15, 9:00 am (em dash, with a time)")
    func finalWithTime() throws {
        let exam = try only("Final Exam \u{2014} December 15, 9:00 am")
        #expect(exam.name == "Final Exam")
        #expect(exam.date == Self.date(2025, 12, 15, 9, 0))
        #expect(exam.hasTime)
    }

    @Test("Exam 2 (Nov. 20)")
    func parenthesisedDate() throws {
        let exam = try only("Exam 2 (Nov. 20)")
        #expect(exam.name == "Exam 2")
        #expect(exam.date == Self.date(2025, 11, 20))
    }

    @Test("table rows, flattened with pipes or with spaces")
    func tableRows() throws {
        let piped = try only("Week 8 | 10/21 | Midterm")
        #expect(piped.name == "Midterm")
        #expect(piped.date == Self.date(2025, 10, 21))

        let spaced = try only("Week 8 10/21 Midterm")
        #expect(spaced.date == Self.date(2025, 10, 21))
        #expect(!spaced.hasTime)

        // The same row, through the real HTML flattening.
        let html = "<table><tr><td>Week 7</td><td>10/14</td><td>Lecture</td></tr>"
            + "<tr><td>Week 8</td><td>10/21</td><td>Midterm</td></tr></table>"
        let flattened = try only(HTMLText.plainText(from: html))
        #expect(flattened.date == Self.date(2025, 10, 21))
    }

    @Test("an exam named in a sentence of prose")
    func prose() throws {
        let exam = try only("The midterm exam will be held in class on Thursday, October 23. Bring a pencil.")
        #expect(exam.name == "Midterm exam")
        #expect(exam.date == Self.date(2025, 10, 23))
    }

    @Test("several exams, one per line, in the order the syllabus lists them")
    func severalLines() {
        let text = """
        Course schedule
        Midterm 1: Thursday, October 23
        Homework 5 due Oct 30
        Midterm 2: Thursday, November 20
        Final Exam \u{2014} December 15, 9:00 am
        """
        let found = extract(text)
        #expect(found.map(\.name) == ["Midterm 1", "Midterm 2", "Final Exam"])
        #expect(found.map(\.hasTime) == [false, false, true])
        #expect(found[1].date == Self.date(2025, 11, 20))
    }

    @Test("two exams on one line pair with the date beside them")
    func twoExamsOneLine() {
        let semicolon = extract("Midterm 1: Oct 23; Midterm 2: Nov 20")
        #expect(semicolon.map(\.name) == ["Midterm 1", "Midterm 2"])
        #expect(semicolon.map(\.date) == [Self.date(2025, 10, 23), Self.date(2025, 11, 20)])

        let comma = extract("Oct 23 - Midterm 1, Nov 20 - Midterm 2")
        #expect(comma.map(\.name) == ["Midterm 1", "Midterm 2"])
        #expect(comma.map(\.date) == [Self.date(2025, 10, 23), Self.date(2025, 11, 20)])

        // With no way to tell which date goes with which exam, nothing is
        // better than a guess.
        #expect(extract("Midterm 1 and Midterm 2 are on Oct 23 and Nov 20").isEmpty)
    }

    @Test("the same exam listed twice is one candidate, and the timed copy wins")
    func duplicateWithinSyllabus() throws {
        let text = """
        Final Exam: December 15
        Week 15 | 12/15 | Final Exam, 9:00 am
        """
        let exam = try only(text)
        #expect(exam.hasTime)
        #expect(exam.date == Self.date(2025, 12, 15, 9, 0))
    }

    // MARK: - Years

    @Test("the year is the occurrence nearest the reference date")
    func yearNearestReference() throws {
        // Early in the fall term: December is this year.
        #expect(try only("Final Exam: December 15", ref: Self.date(2026, 8, 20)).date == Self.date(2026, 12, 15))
        // Five weeks into a term, an exam that already happened is still this
        // year's, not next September's.
        #expect(try only("Midterm 1: Sept 11", ref: Self.date(2026, 10, 18)).date == Self.date(2026, 9, 11))
    }

    @Test("across New Year the next January beats the last one")
    func yearAcrossTermBoundary() throws {
        // Winter break reading a spring syllabus.
        #expect(try only("Midterm: Jan 25", ref: Self.date(2026, 12, 28)).date == Self.date(2027, 1, 25))
        // January reading the fall final that just happened: December of the
        // year that just ended, not the one that is eleven months away.
        #expect(try only("Final Exam: December 15", ref: Self.date(2027, 1, 10)).date == Self.date(2026, 12, 15))
        // A spring term.
        #expect(try only("Midterm: March 5", ref: Self.date(2027, 1, 20)).date == Self.date(2027, 3, 5))
    }

    @Test("a date long past is a previous term's and is dropped, not moved forward")
    func stalenessWindow() throws {
        // Summer: last December is 177 days back, outside the window, so the
        // coming December is the only live reading.
        #expect(try only("Final Exam: Dec 15", ref: Self.date(2026, 6, 10)).date == Self.date(2026, 12, 15))
        // An explicit year in the past is simply stale.
        #expect(extract("Midterm 1: October 23, 2024").isEmpty)
        // An explicit current year is trusted even when it is not the nearest.
        #expect(try only("Final Exam: December 15, 2026", ref: Self.date(2026, 10, 18)).date == Self.date(2026, 12, 15))
    }

    @Test("a weekday that only fits last year marks a recycled syllabus")
    func recycledSyllabus() throws {
        let reference2026 = Self.date(2026, 10, 18)
        // October 23, 2025 was a Thursday. In 2026 it is a Friday, so this line
        // was written a year ago and the instructor never wrote a 2026 date.
        #expect(extract("Midterm 1: Thursday, October 23", ref: reference2026).isEmpty)
        // The same line with the right weekday for 2026 is read normally.
        #expect(try only("Midterm 1: Friday, October 23", ref: reference2026).date == Self.date(2026, 10, 23))
        // A weekday no year agrees with is a typo, not a stale page: ignored.
        #expect(try only("Midterm 1: Wednesday, October 23", ref: reference2026).date == Self.date(2026, 10, 23))
        // A weekday after the date counts the same.
        #expect(try only("Midterm 1: Oct 23 (Fri)", ref: reference2026).date == Self.date(2026, 10, 23))
    }

    @Test("a date that does not exist is skipped")
    func impossibleDates() {
        #expect(extract("Midterm: February 30").isEmpty)
        #expect(extract("Midterm: 13/40").isEmpty)
    }

    // MARK: - Times

    @Test("clock times, and no time when none is stated")
    func clockTimes() throws {
        #expect(try only("Midterm 1: October 23, 7 pm").date == Self.date(2025, 10, 23, 19, 0))
        #expect(try only("Exam 2: 11/20 6:30 PM").date == Self.date(2025, 11, 20, 18, 30))
        #expect(try only("Midterm 1 7pm Oct 23").date == Self.date(2025, 10, 23, 19, 0))
        #expect(try only("Midterm: Oct 23 at noon").date == Self.date(2025, 10, 23, 12, 0))
        #expect(try only("Final: Dec 15 14:30").date == Self.date(2025, 12, 15, 14, 30))
        #expect(try only("Final Exam: Dec 15, 12 a.m.").date == Self.date(2025, 12, 15, 0, 0))
        #expect(try only("Final Exam: Dec 15, 12 pm").date == Self.date(2025, 12, 15, 12, 0))
    }

    @Test("a time range starts at its start, with the meridiem inferred")
    func timeRanges() throws {
        #expect(try only("Final Exam Dec 15 6-8 pm").date == Self.date(2025, 12, 15, 18, 0))
        #expect(try only("Final Exam Dec 15 6\u{2013}8 pm").date == Self.date(2025, 12, 15, 18, 0))
        #expect(try only("Midterm Oct 23 9:00 am - 10:20 am").date == Self.date(2025, 10, 23, 9, 0))
        #expect(try only("Midterm Oct 23 11-1 pm").date == Self.date(2025, 10, 23, 11, 0))
        #expect(try only("Midterm Oct 23 12-2 pm").date == Self.date(2025, 10, 23, 12, 0))
    }

    @Test("digits that belong to the date or the exam number are never an hour")
    func noInventedTimes() throws {
        for line in [
            "Midterm 1: Oct 23",
            "Midterm 2: 10/23",
            "Exam 3 (Nov 20)",
            "Oct 7 - Midterm 1",
            // 6:00 with no am/pm could be either end of the day.
            "Exam 2: Nov 20 6:00",
        ] {
            #expect(try !only(line).hasTime, "\(line) states no time")
        }
        // The date's own digits are masked before the time search, so the 9 pm
        // after "Oct 7 -" is the hour, not the 7.
        #expect(try only("Midterm Oct 7 - 9 pm").date == Self.date(2025, 10, 7, 21, 0))
    }

    @Test("an explicit time zone overrides the calendar's")
    func injectedTimeZone() throws {
        let utc = TimeZone(identifier: "UTC")!
        let found = SyllabusExamExtractor.extract(
            text: "Midterm 1: Oct 23, 7 pm",
            referenceDate: Self.fall2025,
            calendar: Self.calendar,
            timeZone: utc
        )
        var utcCalendar = Calendar(identifier: .gregorian)
        utcCalendar.timeZone = utc
        let expected = utcCalendar.date(from: DateComponents(year: 2025, month: 10, day: 23, hour: 19))!
        #expect(found.first?.date == expected)
        #expect(found.first?.date != Self.date(2025, 10, 23, 19, 0))
    }

    // MARK: - What is skipped

    @Test("lines with no exam are skipped")
    func noExam() {
        #expect(extract("Homework 5 due Oct 30").isEmpty)
        #expect(extract("Quiz 3: Oct 23").isEmpty)
        #expect(extract("Lecture 12 \u{2013} Oct 23").isEmpty)
        #expect(extract("Project proposal due 10/23").isEmpty)
    }

    @Test("lines with no date are skipped")
    func noDate() {
        #expect(extract("Midterm 1: date to be announced").isEmpty)
        #expect(extract("Final Exam: during finals week").isEmpty)
        #expect(extract("There will be two midterms and a final exam.").isEmpty)
    }

    @Test("grading-weight lines are ignored")
    func weightLines() {
        #expect(extract("Midterm 25%").isEmpty)
        #expect(extract("Midterm 1 \u{2014} 20% of grade").isEmpty)
        #expect(extract("Midterm 1/3 of the grade").isEmpty)
        #expect(extract("Exam 2 worth 1/4 of your grade").isEmpty)
        #expect(extract("Midterm 1/2 pts").isEmpty)
        #expect(extract("Midterms (2 x 15%), Final Exam (30%)").isEmpty)
    }

    @Test("a weight beside a real date does not hide the date")
    func weightWithDate() throws {
        let exam = try only("Midterm 1 | Oct 23 | 20%")
        #expect(exam.date == Self.date(2025, 10, 23))
    }

    @Test("practice, review and results lines are not exams")
    func notTheExam() {
        #expect(extract("Practice midterm: Oct 20").isEmpty)
        #expect(extract("Midterm review session: Oct 21").isEmpty)
        #expect(extract("Review session for Midterm 1 \u{2013} Oct 21").isEmpty)
        #expect(extract("Midterm solutions will be posted Oct 25").isEmpty)
        #expect(extract("Final project due Dec 10").isEmpty)
        #expect(extract("Final Exam Review: Dec 12").isEmpty)
    }

    @Test("a review session later in the line does not cancel the exam")
    func reviewElsewhereInTheLine() throws {
        let exam = try only("Midterm 1: Thursday, October 23, in class (a review session is held the week before)")
        #expect(exam.date == Self.date(2025, 10, 23))
    }

    @Test("a plural with no number is a category, not an exam")
    func pluralCategory() {
        #expect(extract("Midterms: Oct 23 and Nov 20").isEmpty)
        #expect(extract("Exams are closed book (Oct 23)").isEmpty)
    }

    @Test("a sentence break does not split an abbreviated month")
    func abbreviatedMonthSurvivesSentenceSplit() throws {
        let exam = try only("Exam 2 will be on Nov. 20. It covers chapters 5\u{2013}8.")
        #expect(exam.date == Self.date(2025, 11, 20))
    }

    @Test("non-breaking spaces and exotic dashes are ordinary")
    func unicodeSpacingAndDashes() throws {
        #expect(try only("Midterm\u{00A0}1:\u{00A0}Oct\u{00A0}23").date == Self.date(2025, 10, 23))
        #expect(try only("Oct 23 \u{2212} Midterm").date == Self.date(2025, 10, 23))
        #expect(try only("Oct 23 \u{2014} Midterm 1").name == "Midterm 1")
        #expect(try only("Final Exam \u{2013} Dec 15 \u{2013} 6\u{2013}8 pm").date == Self.date(2025, 12, 15, 18, 0))
    }

    @Test("empty and whitespace-only input")
    func emptyInput() {
        #expect(extract("").isEmpty)
        #expect(extract("   \n\n  ").isEmpty)
    }

    @Test("every month spelling the announcement extractor knows is understood here")
    func monthTableAgreesWithAnnouncementExtractor() throws {
        // The month table is duplicated on purpose (the original is private to
        // another file); this keeps the two from drifting.
        let spellings: [(String, Int)] = [
            ("Jan", 1), ("January", 1), ("Feb", 2), ("February", 2), ("Mar", 3), ("March", 3),
            ("Apr", 4), ("April", 4), ("May", 5), ("Jun", 6), ("June", 6), ("Jul", 7), ("July", 7),
            ("Aug", 8), ("August", 8), ("Sep", 9), ("Sept", 9), ("September", 9),
            ("Oct", 10), ("October", 10), ("Nov", 11), ("November", 11), ("Dec", 12), ("December", 12),
        ]
        for (name, month) in spellings {
            let reference = Self.date(2026, month, 1)
            let ours = try only("Midterm: \(name) 5", ref: reference)
            let theirs = HeuristicAnnouncementExtractor.explicitDate(
                in: "\(name) 5", now: reference, calendar: Self.calendar
            )
            #expect(Self.calendar.component(.month, from: ours.date) == month, "\(name)")
            #expect(theirs.map { Self.calendar.component(.month, from: $0) } == month, "\(name)")
        }
    }
}
