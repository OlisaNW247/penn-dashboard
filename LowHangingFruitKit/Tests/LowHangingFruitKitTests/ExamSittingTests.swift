import Foundation
import Testing
@testable import LowHangingFruitKit

/// When two mentions of an exam are one sitting, what makes a row "a found
/// exam", and the ids a syllabus exam is filed under.
///
/// Every date here is built with one fixed calendar (New York), so none of it
/// depends on the zone the tests run in.
@Suite("Exam sittings")
struct ExamSittingTests {

    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        return calendar
    }

    private static func date(_ month: Int, _ day: Int, _ hour: Int = 12, _ minute: Int = 0, year: Int = 2026) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute))!
    }

    private func identity(_ title: String, course: String = "CIS 1200") -> ExamIdentity {
        ExamDetection.examIdentity(title: title, course: course)!
    }

    private func same(_ a: String, _ aDue: Date?, _ b: String, _ bDue: Date?) -> Bool {
        ExamDetection.isSameSitting(
            identity(a), due: aDue, identity(b), due: bDue, calendar: Self.calendar
        )
    }

    // MARK: Same identity

    @Test("the same exam on the same day is one sitting")
    func sameIdentitySameDay() {
        #expect(same("Midterm 1", Self.date(10, 23), "Midterm 1", Self.date(10, 23)))
        #expect(same("Final Exam", Self.date(12, 15), "Final", Self.date(12, 15)))
    }

    @Test("a rescheduled exam is still one sitting, within the window")
    func rescheduledWithinWindow() {
        #expect(same("Midterm 1", Self.date(10, 23), "Midterm 1", Self.date(10, 30)))
        // 53 days: Oct 23 to Dec 15, inside the 60.
        #expect(same("Midterm 1", Self.date(10, 23), "Midterm 1", Self.date(12, 15)))
    }

    @Test("last year's exam of the same name is not this year's: the window is what tells a recycled site apart")
    func recycledSiteIsNotTheSameSitting() {
        #expect(!same("Final Exam", Self.date(12, 15, year: 2025), "Final Exam", Self.date(12, 15)))
        // Just outside the window.
        let first = Self.date(10, 1)
        let outside = Self.calendar.date(byAdding: .day, value: ExamDetection.rescheduleWindowDays + 1, to: first)!
        let inside = Self.calendar.date(byAdding: .day, value: ExamDetection.rescheduleWindowDays, to: first)!
        #expect(!same("Midterm 1", first, "Midterm 1", outside))
        #expect(same("Midterm 1", first, "Midterm 1", inside))
    }

    @Test("an undated mention of the same exam names it without moving it")
    func undatedSameIdentity() {
        #expect(same("Midterm 1", nil, "Midterm 1", Self.date(10, 23)))
        #expect(same("Midterm 1", Self.date(10, 23), "Midterm 1", nil))
        #expect(same("Midterm 1", nil, "Midterm 1", nil))
    }

    @Test("spellings agree: MT1, Mid-term 1, Midterm Exam I and 1st Midterm are one exam")
    func spellings() {
        let day = Self.date(10, 23)
        #expect(same("Midterm 1", day, "MT1", day))
        #expect(same("Midterm 1", day, "Mid-term 1", day))
        #expect(same("Midterm 1", day, "Midterm Exam I", day))
        #expect(same("Midterm 1", day, "1st Midterm", day))
    }

    // MARK: Possibly the same: only the dates can say

    @Test("an unnumbered exam and a numbered one are one sitting only when the dates are no more than a day apart")
    func unnumberedVersusNumbered() {
        #expect(same("Midterm", Self.date(10, 23), "Midterm 1", Self.date(10, 23)))
        #expect(same("Midterm", Self.date(10, 23), "Midterm 1", Self.date(10, 24)))
        #expect(same("Midterm 1", Self.date(10, 24), "Midterm", Self.date(10, 23)))
        #expect(!same("Midterm", Self.date(10, 23), "Midterm 1", Self.date(10, 25)))
        // No date on either side: nothing to check, so not the same.
        #expect(!same("Midterm", nil, "Midterm 1", Self.date(10, 23)))
        #expect(!same("Midterm", Self.date(10, 23), "Midterm 1", nil))
        #expect(!same("Midterm", nil, "Midterm 1", nil))
    }

    @Test("Midterm N and Exam N are one sitting only when the dates are no more than a day apart")
    func midtermVersusExam() {
        #expect(same("Midterm 2", Self.date(11, 20), "Exam 2", Self.date(11, 20)))
        #expect(same("Midterm 2", Self.date(11, 20), "Exam 2", Self.date(11, 21)))
        #expect(!same("Midterm 2", Self.date(11, 20), "Exam 2", Self.date(11, 23)))
        #expect(!same("Midterm 2", Self.date(11, 20), "Exam 2", nil))
        // The families that mean the same thing at different schools.
        #expect(same("Prelim 1", Self.date(10, 23), "Midterm 1", Self.date(10, 23)))
        #expect(same("Test 1", Self.date(10, 23), "Midterm 1", Self.date(10, 23)))
    }

    @Test("different numbers are different exams, whatever the dates say")
    func differentNumbers() {
        #expect(!same("Midterm 1", Self.date(10, 23), "Midterm 2", Self.date(10, 23)))
        #expect(!same("Midterm 1", Self.date(10, 23), "Exam 2", Self.date(10, 23)))
        #expect(!same("Exam 1", Self.date(10, 23), "Exam 2", Self.date(10, 24)))
    }

    @Test("a final is only ever another final")
    func finalsStayApart() {
        let day = Self.date(12, 15)
        #expect(!same("Final Exam", day, "Midterm", day))
        #expect(!same("Final Exam", day, "Exam 2", day))
        #expect(same("Final Exam", day, "Final", day))
    }

    @Test("a makeup is never the ordinary sitting, and never another makeup's twin unless it is one")
    func makeupsAreDistinct() {
        let day = Self.date(10, 23)
        #expect(!same("Makeup Midterm 1", day, "Midterm 1", day))
        #expect(!same("Midterm 1", day, "Midterm 1 Makeup", day))
        #expect(same("Makeup Midterm 1", day, "Midterm 1 Makeup", day))
        #expect(!same("Makeup Midterm 1", day, "Retake Midterm 1", day))
    }

    @Test("a day apart is by calendar day, not by 24 hours")
    func calendarDays() {
        // 11:59 PM one night and 12:01 AM the next are two minutes and one day apart.
        #expect(same("Midterm", Self.date(10, 22, 23, 59), "Midterm 1", Self.date(10, 23, 0, 1)))
        // 8 AM the 22nd and 9 PM the 23rd are 37 hours apart and still one day.
        #expect(same("Midterm", Self.date(10, 22, 8), "Midterm 1", Self.date(10, 23, 21)))
        // Two calendar days, even though only 25 hours apart.
        #expect(!same("Midterm", Self.date(10, 22, 23), "Midterm 1", Self.date(10, 24, 0, 30)))
    }

    // MARK: Identity keys

    @Test("the key an exam is filed under carries its kind, number and modifiers, and nothing about its date")
    func sourceKeys() {
        #expect(identity("Midterm 1").sourceKey == "midterm-1")
        #expect(identity("Midterm").sourceKey == "midterm")
        #expect(identity("Final Exam").sourceKey == "final")
        #expect(identity("Exam II").sourceKey == "exam-2")
        #expect(identity("Prelim 3").sourceKey == "prelim-3")
        #expect(identity("Makeup Midterm 1").sourceKey == "midterm-1-makeup")
    }

    @Test("a numbered and an unnumbered midterm never share a key, and neither does a makeup")
    func sourceKeysAreDistinct() {
        let keys = ["Midterm", "Midterm 1", "Midterm 2", "Exam 1", "Makeup Midterm 1", "Makeup Midterm", "Final"]
            .map { identity($0).sourceKey }
        #expect(Set(keys).count == keys.count)
    }

    @Test("the key does not depend on how the course code is spelled")
    func sourceKeyIgnoresCourse() {
        #expect(identity("Midterm 1", course: "PHYS 0151").sourceKey == identity("Midterm 1", course: "phys 151").sourceKey)
    }

    // MARK: All-day marker

    @Test("an all-day exam is stored at 23:59:59 of its day, and only that moment reads as all-day")
    func allDayMoment() {
        let calendar = Self.calendar
        let day = calendar.startOfDay(for: Self.date(10, 23))
        let end = AllDayDueMoment.endOfDay(day, calendar: calendar)
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute, .second], from: end)
        #expect(parts.month == 10 && parts.day == 23 && parts.hour == 23 && parts.minute == 59 && parts.second == 59)
        #expect(AllDayDueMoment.isEndOfDay(end, calendar: calendar))
        // A time somebody typed, or the announcement extractor's own end of day, ends in :00.
        #expect(!AllDayDueMoment.isEndOfDay(Self.date(10, 23, 23, 59), calendar: calendar))
        #expect(!AllDayDueMoment.isEndOfDay(Self.date(10, 23, 14, 0), calendar: calendar))
    }

    // MARK: What a found exam is

    private func row(
        _ source: Assignment.Source, _ sourceID: String, title: String, kind: Assignment.Kind = .assignment
    ) -> Assignment {
        Assignment(source: source, sourceID: sourceID, kind: kind, course: "CIS 1200", title: title, dueAt: nil, url: nil)
    }

    @Test("a syllabus row is a found exam whatever its title; an announcement row is one when its title names an exam")
    func foundExam() {
        #expect(row(.canvasAnnouncement, "syllabus-9601-final", title: "Whatever", kind: .event).isFoundExam)
        #expect(row(.canvasAnnouncement, "announcement-7-0", title: "Midterm 1").isFoundExam)
        #expect(row(.canvasAnnouncement, "ed-9601-33-0", title: "Take the final exam").isFoundExam)
        #expect(!row(.canvasAnnouncement, "announcement-7-1", title: "Submit the lab report").isFoundExam)
        #expect(!row(.canvasAnnouncement, "announcement-7-2", title: "Midterm Review Session").isFoundExam)
        #expect(!row(.canvasAnnouncement, "announcement-7-3", title: "Practice Exam 2").isFoundExam)
    }

    @Test("a task that merely mentions an exam is not an exam: only a title that leads with one is")
    func mentioningIsNotBeing() {
        func announced(_ title: String) -> Bool {
            row(.canvasAnnouncement, "announcement-7-0", title: title).isFoundExam
        }
        #expect(announced("Midterm 1"))
        #expect(announced("Take the final exam"))
        #expect(announced("Please sit the midterm"))
        #expect(announced("In-class midterm"))
        #expect(announced("Makeup Midterm 1"))
        #expect(announced("Second midterm"))
        #expect(announced("Exam 2 (Section 001)"))
        #expect(announced("Midterm 1 on Thursday"))
        #expect(!announced("Bring a calculator to the exam"))
        #expect(!announced("Read chapters 1-5 for the midterm"))
        #expect(!announced("Sign up for an exam room"))
        #expect(!announced("Submit the lab report"))
    }

    @Test("the identity of a leading exam is the exam's, makeup included; a mention gives none")
    func leadingIdentity() {
        func key(_ title: String) -> String? {
            ExamDetection.leadingExamIdentity(title: title, course: "CIS 1200")?.sourceKey
        }
        #expect(key("Take the final exam") == "final")
        #expect(key("Makeup Midterm 1") == "midterm-1-makeup")
        #expect(key("Second midterm") == "midterm-2")
        #expect(key("Bring a calculator to the exam") == nil)
        // The looser question, the one the card's colour asks, still says yes.
        #expect(ExamDetection.examIdentity(title: "Bring a calculator to the exam", course: "CIS 1200") != nil)
    }

    @Test("a feed exam is not a found exam: Canvas lists it and keeps its own rules")
    func feedExamIsNotFound() {
        #expect(!row(.canvas, "event-assignment-1", title: "Midterm 1").isFoundExam)
        #expect(!row(.gradescope, "g1", title: "Midterm 1").isFoundExam)
        #expect(!row(.manual, "m1", title: "Midterm 1").isFoundExam)
        #expect(!row(.canvasModules, "module-item-1", title: "Final Exam", kind: .event).isFoundExam)
    }

    // MARK: Origin

    @Test("a syllabus id reads back as the syllabus, and is no announcement's or Ed post's")
    func origins() {
        func origin(_ id: String) -> AnnouncementOrigin? {
            row(.canvasAnnouncement, id, title: "t").announcementOrigin
        }
        #expect(origin(AnnouncementRecord.syllabusFindSourceID(courseID: "9601", examKey: "midterm-1")) == .syllabus)
        #expect(origin(AnnouncementRecord.edFindSourceID(courseID: "9601", threadID: "33", index: 0)) == .ed)
        #expect(origin(AnnouncementRecord.findSourceID(announcementID: "77", index: 0)) == .canvas)
        #expect(row(.canvas, "syllabus-9601-final", title: "t").announcementOrigin == nil)
    }

    @Test("a syllabus id joins to no announcement post, so nothing can judge it deleted")
    func syllabusIDsJoinToNothing() {
        let id = AnnouncementRecord.syllabusFindSourceID(courseID: "9601", examKey: "midterm-1")
        #expect(id == "syllabus-9601-midterm-1")
        #expect(AnnouncementRecord.announcementID(fromFindSourceID: id) == nil)
        #expect(AnnouncementRecord.edDocumentID(fromFindSourceID: id) == nil)
        #expect(AnnouncementRecord.recordID(fromFindSourceID: id) == nil)
    }
}
