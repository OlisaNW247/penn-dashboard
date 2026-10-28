import Foundation

public extension Calendar {
    /// `calendar` itself when it is Gregorian, otherwise the Gregorian
    /// calendar in the same time zone (and with the same locale and week
    /// rules), so a phone set to a Buddhist, Japanese, Hebrew or Islamic
    /// calendar computes the same terms, rollover dates and syllabus dates as
    /// every other phone.
    ///
    /// **Why this exists.** Every date rule in this app is written in
    /// Gregorian years: a Canvas term code says `202610` for spring 2026, a
    /// syllabus says "October 22, 2026", the server sends exam days as
    /// `2026-10-22`. `Calendar.current` follows the phone's *settings*, and on
    /// a Buddhist-calendar phone (Thailand's default) the same instant is year
    /// 2569, on a Japanese-calendar phone it is year 8. `Term(date:)` then
    /// produced "Spring 2569", which matches no term code, so semester
    /// rollover archived against terms nothing carried; and a syllabus's
    /// "2026" was read as the year 2026 *of the Buddhist era*, 1483 CE, and
    /// dropped as stale. Nothing crashed. The class just came out with no
    /// exams and the wrong semester.
    ///
    /// **The wrong fix** is to replace `Calendar.current` with a bare
    /// `Calendar(identifier: .gregorian)` at each call site: that also throws
    /// away the time zone, and "the end of the day" would stop meaning the
    /// student's day. Only the calendar *system* is a setting that must not
    /// leak in. The time zone, which really is where the student is, is kept.
    ///
    /// A Gregorian input is returned unchanged, so every caller (and test)
    /// that already passes one sees no difference.
    static func gregorian(matching calendar: Calendar) -> Calendar {
        guard calendar.identifier != .gregorian else { return calendar }
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        gregorian.locale = calendar.locale
        gregorian.firstWeekday = calendar.firstWeekday
        gregorian.minimumDaysInFirstWeek = calendar.minimumDaysInFirstWeek
        return gregorian
    }
}
