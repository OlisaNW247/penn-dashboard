import Foundation

/// A Penn academic term. Canvas encodes it in course codes as a `YYYYTT` suffix
/// (e.g. `202620`), where `TT` is `10` = Spring, `20` = Summer, `30` = Fall.
/// Used to scope the dashboard to the current term and to cap the "All" tab so
/// next-term items don't leak in.
public struct Term: Sendable, Hashable, Comparable, Codable {
    public enum Season: Int, Sendable, Hashable, Codable {
        case spring = 10
        case summer = 20
        case fall = 30

        public var name: String {
            switch self {
            case .spring: return "Spring"
            case .summer: return "Summer"
            case .fall:   return "Fall"
            }
        }
    }

    public let year: Int
    public let season: Season

    public init(year: Int, season: Season) {
        self.year = year
        self.season = season
    }

    /// Parses a `YYYYTT` term code (e.g. "202620"). Returns nil when the string
    /// isn't a recognizable term code.
    public init?(code: String) {
        let digits = code.trimmingCharacters(in: .whitespaces)
        guard digits.count == 6, digits.allSatisfy(\.isNumber),
              let year = Int(digits.prefix(4)),
              let seasonRaw = Int(digits.suffix(2)),
              let season = Season(rawValue: seasonRaw)
        else { return nil }
        self.year = year
        self.season = season
    }

    /// The term containing `date`, using Penn's rough season boundaries
    /// (Spring: Jan–May, Summer: Jun–Jul, Fall: Aug–Dec). August maps to fall
    /// because Penn's fall term begins in late August — treating it as summer
    /// would hide early-fall assignments during syllabus week.
    public init(date: Date, calendar: Calendar = .current) {
        let comps = calendar.dateComponents([.year, .month], from: date)
        self.year = comps.year ?? 2000
        switch comps.month ?? 1 {
        case 1...5:  self.season = .spring
        case 6...7:  self.season = .summer
        default:     self.season = .fall
        }
    }

    /// A generous start-of-term date, used to scope the Done tab's "this
    /// semester" history. Deliberately approximate.
    public func startDate(calendar: Calendar = .current) -> Date {
        let monthDay: (month: Int, day: Int)
        switch season {
        case .spring: monthDay = (1, 1)
        case .summer: monthDay = (5, 15)
        case .fall:   monthDay = (8, 1)
        }
        var comps = DateComponents()
        comps.year = year
        comps.month = monthDay.month
        comps.day = monthDay.day
        return calendar.date(from: comps) ?? .distantPast
    }

    /// A generous end-of-term date, used to cap the "All" tab. Deliberately
    /// approximate — it favors not cutting off late-term finals over precision.
    public func endDate(calendar: Calendar = .current) -> Date {
        let monthDay: (month: Int, day: Int)
        switch season {
        case .spring: monthDay = (5, 31)
        case .summer: monthDay = (8, 31)
        case .fall:   monthDay = (12, 31)
        }
        var comps = DateComponents()
        comps.year = year
        comps.month = monthDay.month
        comps.day = monthDay.day
        comps.hour = 23
        comps.minute = 59
        comps.second = 59
        return calendar.date(from: comps) ?? .distantFuture
    }

    /// The `YYYYTT` code this term round-trips through `init?(code:)` as.
    ///
    /// The inverse of the parser, and it exists so a term can be written
    /// somewhere that only takes a string — a defaults key, a diagnostic line,
    /// a test fixture's course descriptor — and read back as the same value.
    /// Building the string by hand at each of those sites is how a `202630`
    /// eventually gets typed as `20263`.
    public var code: String {
        String(format: "%04d%02d", year, season.rawValue)
    }

    /// What a student calls this term: "Spring 2026".
    ///
    /// Deliberately not the `code`. The rollover card has to ask a question the
    /// student can answer without knowing that Penn writes fall as `30`, and
    /// "Archive 47 items from 202610?" is not that question.
    public var displayName: String {
        "\(season.name) \(year)"
    }

    public static func < (lhs: Term, rhs: Term) -> Bool {
        (lhs.year, lhs.season.rawValue) < (rhs.year, rhs.season.rawValue)
    }
}
