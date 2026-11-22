import Foundation

/// The date under "Ambassador" in the dashboard header: the month in full and
/// an ordinal day, "November 22nd" (Marco, 2026-11-22). Pure, so the 11th,
/// 12th and 13th (which are not "11st") are pinned by a test. The month comes
/// from a fixed-locale formatter so a phone set to another language still
/// reads the app's own lowercase-free English like the rest of the header.
public enum AmbassadorDateLine {
    public static func text(for date: Date, calendar: Calendar = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = "MMMM"
        let day = calendar.component(.day, from: date)
        return "\(formatter.string(from: date)) \(day)\(suffix(for: day))"
    }

    public static func suffix(for day: Int) -> String {
        if (11...13).contains(day % 100) { return "th" }
        switch day % 10 {
        case 1: return "st"
        case 2: return "nd"
        case 3: return "rd"
        default: return "th"
        }
    }
}
