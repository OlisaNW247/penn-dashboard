import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// B15 of `docs/HARDENING_PLAN_2026-10-25.md`: dates that do not depend on
/// settings. Two settings are involved, and both used to leak into stored
/// data: the phone's **calendar system** (Buddhist, Japanese, ...) and its
/// **time zone**.
///
/// The calendar is injected through the `calendar:` parameter every one of
/// these functions already takes (`Calendar.current` is what production
/// passes), so a Buddhist or Japanese calendar here is exactly what a phone
/// set to one would hand them.
@Suite("Dates do not depend on the phone's calendar or zone")
struct CalendarSettingsIndependenceTests {

    private static let newYork = TimeZone(identifier: "America/New_York")!
    private static let tokyo = TimeZone(identifier: "Asia/Tokyo")!
    private static let losAngeles = TimeZone(identifier: "America/Los_Angeles")!

    private static func calendar(_ identifier: Calendar.Identifier, zone: TimeZone = newYork) -> Calendar {
        var calendar = Calendar(identifier: identifier)
        calendar.timeZone = zone
        return calendar
    }

    private static let gregorian = calendar(.gregorian)

    /// Every non-Gregorian system a phone can be set to that numbers its
    /// years differently from the Gregorian ones the rules are written in.
    private static let otherSystems: [Calendar.Identifier] = [
        .buddhist, .japanese, .republicOfChina, .islamicCivil, .persian, .hebrew,
    ]

    /// Local New York wall-clock time.
    private static func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        gregorian.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }

    // MARK: The helper

    @Test("a Gregorian calendar passes through unchanged and another keeps only its zone and week rules")
    func helperKeepsTheZone() {
        let gregorian = Self.calendar(.gregorian, zone: Self.tokyo)
        #expect(Calendar.gregorian(matching: gregorian) == gregorian)

        var buddhist = Self.calendar(.buddhist, zone: Self.tokyo)
        buddhist.firstWeekday = 2
        buddhist.minimumDaysInFirstWeek = 4
        let normalized = Calendar.gregorian(matching: buddhist)
        #expect(normalized.identifier == .gregorian)
        #expect(normalized.timeZone == Self.tokyo)
        #expect(normalized.firstWeekday == 2)
        #expect(normalized.minimumDaysInFirstWeek == 4)
    }

    // MARK: Terms

    @Test("a term is the same Gregorian term whatever calendar system the phone uses")
    func termsIgnoreTheCalendarSystem() {
        let dates = [
            Self.date(2026, 1, 15), Self.date(2026, 5, 31), Self.date(2026, 6, 20),
            Self.date(2026, 8, 30), Self.date(2026, 12, 31, 23), Self.date(2027, 2, 3),
        ]
        for identifier in Self.otherSystems {
            let other = Self.calendar(identifier)
            for date in dates {
                let expected = Term(date: date, calendar: Self.gregorian)
                let term = Term(date: date, calendar: other)
                #expect(term == expected, "\(identifier) read \(date) as \(term.displayName)")
                #expect(term.startDate(calendar: other) == expected.startDate(calendar: Self.gregorian), "\(identifier) start")
                #expect(term.endDate(calendar: other) == expected.endDate(calendar: Self.gregorian), "\(identifier) end")
            }
        }
    }

    @Test("a Buddhist-calendar phone reads fall 2026 as the term code 202630, not a year 2569 nothing carries")
    func buddhistPhoneMatchesTermCodes() {
        let buddhist = Self.calendar(.buddhist)
        let term = Term(date: Self.date(2026, 10, 27), calendar: buddhist)
        #expect(term.code == "202630")
        #expect(term == Term(code: "202630"))
        #expect(term.displayName == "Fall 2026")
        // The scoped dates land in the real semester, not 543 years off.
        #expect(Self.gregorian.component(.year, from: term.startDate(calendar: buddhist)) == 2026)
        #expect(Self.gregorian.component(.year, from: term.endDate(calendar: buddhist)) == 2026)
    }

    @Test("a term's start and end keep the caller's time zone")
    func termBoundariesKeepTheZone() {
        let term = Term(year: 2026, season: .fall)
        for zone in [Self.newYork, Self.tokyo] {
            let japanese = Self.calendar(.japanese, zone: zone)
            let expected = Self.calendar(.gregorian, zone: zone)
            #expect(term.startDate(calendar: japanese) == term.startDate(calendar: expected))
            #expect(term.endDate(calendar: japanese) == term.endDate(calendar: expected))
        }
        #expect(term.startDate(calendar: Self.calendar(.japanese, zone: Self.tokyo))
            != term.startDate(calendar: Self.calendar(.japanese, zone: Self.newYork)))
    }

    // MARK: Syllabus dates

    private static let reference = date(2026, 10, 1)
    private static let syllabus = """
        Midterm Exam: Friday, October 23, 2026 at 6:00 pm
        Final Exam: December 15
        Quiz 3: 11/05/2026
        """

    @Test("a syllabus's exams are read the same on any calendar system")
    func extractorIgnoresTheCalendarSystem() {
        let expected = SyllabusExamExtractor.extract(
            text: Self.syllabus, referenceDate: Self.reference, calendar: Self.gregorian
        )
        // The Gregorian read has to find them, or the comparison proves nothing.
        #expect(expected.count >= 2)
        #expect(expected.contains { $0.date == Self.date(2026, 10, 23, 18) })
        for identifier in Self.otherSystems {
            let found = SyllabusExamExtractor.extract(
                text: Self.syllabus, referenceDate: Self.reference, calendar: Self.calendar(identifier)
            )
            #expect(found == expected, "\(identifier)")
        }
    }

    @Test("the server's exam days land on the same moment on any calendar system")
    func examDayIgnoresTheCalendarSystem() throws {
        let exam = CourseGradingProfile.ExamDate(name: "Midterm 1", date: "2026-10-23")
        let expected = try #require(exam.day(in: Self.gregorian))
        #expect(expected == Self.date(2026, 10, 23, 0))
        for identifier in Self.otherSystems {
            #expect(exam.day(in: Self.calendar(identifier)) == expected, "\(identifier)")
        }
    }

    @Test("the exam rows a syllabus produces are the same on any calendar system")
    func examRowsIgnoreTheCalendarSystem() {
        let document = CourseDocument(
            courseID: "1", course: "CIS 1110", kind: .syllabus, sourceID: "1", title: "Syllabus",
            url: nil, text: Self.syllabus, fetchedAt: Self.reference
        )
        let profile = CourseGradingProfile(
            courseID: "1", weights: [], components: [], extractedAt: Self.reference,
            examDates: [CourseGradingProfile.ExamDate(name: "Final Exam", date: "2026-12-15")]
        )
        func rows(_ calendar: Calendar) -> [Assignment] {
            SyllabusExamRows.assignments(
                from: [document], profiles: [profile], courseCodesByID: ["1": "CIS 1110"],
                referenceDate: Self.reference, calendar: calendar
            )
        }
        let expected = rows(Self.gregorian)
        #expect(!expected.isEmpty)
        #expect(expected.allSatisfy { $0.dueAt != nil })
        for identifier in Self.otherSystems {
            #expect(rows(Self.calendar(identifier)) == expected, "\(identifier)")
        }
    }

    // MARK: Recurring occurrences

    private func task() -> RecurringTask {
        RecurringTask(
            id: UUID(uuidString: "11111111-2222-3333-4444-555555555555")!,
            title: "Weekly reading", course: "CIS 1110",
            weekday: 3, hour: 21, minute: 0,
            startDate: Date(timeIntervalSince1970: 1_700_000_000), endDate: nil, origin: .manual
        )
    }

    /// Mid-October 2026, so ten weeks cross the US fall-back on November 1.
    private static let now = Date(timeIntervalSince1970: 1_792_000_000)

    private func occurrences(in calendar: Calendar) -> [Assignment] {
        task().upcomingAssignments(from: Self.now, weeksAhead: 10, calendar: calendar)
    }

    /// The occurrences keyed by the local calendar date they fall on, which is
    /// what a student means by "Tuesday the 27th".
    private func byLocalDate(_ assignments: [Assignment], in calendar: Calendar) -> [String: String] {
        var result: [String: String] = [:]
        for assignment in assignments {
            let parts = calendar.dateComponents([.year, .month, .day], from: assignment.dueAt!)
            result[String(format: "%04d-%02d-%02d", parts.year!, parts.month!, parts.day!)] = assignment.sourceID
        }
        return result
    }

    @Test("the same Tuesday has the same id in every time zone, so a trip home does not orphan ticks")
    func occurrenceIDsSurviveATimeZoneChange() {
        let zones = [Self.newYork, Self.tokyo, Self.losAngeles]
        let maps = zones.map { zone -> [String: String] in
            let calendar = Self.calendar(.gregorian, zone: zone)
            return byLocalDate(occurrences(in: calendar), in: calendar)
        }
        for map in maps { #expect(map.count >= 9) }
        let shared = Set(maps[0].keys).intersection(maps[1].keys).intersection(maps[2].keys)
        #expect(shared.count >= 8)
        for date in shared {
            #expect(maps[0][date] == maps[1][date], "New York vs Tokyo on \(date)")
            #expect(maps[0][date] == maps[2][date], "New York vs Los Angeles on \(date)")
        }
    }

    @Test("in Eastern time the id is byte for byte the one earlier builds wrote, so existing ticks survive")
    func easternIDsAreUnchanged() {
        let calendar = Self.calendar(.gregorian, zone: Self.newYork)
        let generated = occurrences(in: calendar)
        #expect(generated.count >= 9)
        for assignment in generated {
            let legacy = "\(task().id.uuidString)-\(Int(assignment.dueAt!.timeIntervalSince1970))"
            #expect(assignment.sourceID == legacy)
        }
    }

    @Test("an id is still recognised as an occurrence of its task, in any zone")
    func occurrenceIDsStillParse() {
        for zone in [Self.newYork, Self.tokyo] {
            for assignment in occurrences(in: Self.calendar(.gregorian, zone: zone)) {
                #expect(RecurringTask.occurrenceTaskID(fromSourceID: assignment.sourceID) == task().id)
                #expect(RecurringTask.isOccurrence(assignment))
            }
        }
    }

    @Test("a phone on a Buddhist or Japanese calendar generates the same occurrences")
    func occurrencesIgnoreTheCalendarSystem() {
        let expected = occurrences(in: Self.gregorian)
        #expect(expected.count >= 9)
        for identifier in [Calendar.Identifier.buddhist, .japanese, .republicOfChina] {
            let found = occurrences(in: Self.calendar(identifier))
            #expect(found.map(\.sourceID) == expected.map(\.sourceID), "\(identifier)")
            #expect(found.map(\.dueAt) == expected.map(\.dueAt), "\(identifier)")
        }
    }
}
