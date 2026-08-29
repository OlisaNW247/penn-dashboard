import Foundation

/// Which academic term a date falls in.
///
/// Canvas's calendar feed has no notion of "this semester": it keeps serving a
/// course's events after the course is over, so a finished class's leftovers
/// stay in the feed indefinitely. The app therefore decides scope itself, from
/// the academic calendar rather than from a rolling "how long ago was this due"
/// window — a rolling window can't tell June's leftovers from September's work.
///
/// Boundaries sit deliberately earlier than Penn's first day of classes, so
/// syllabus-week work posted before the term officially opens still counts as
/// current, while anything from the term before does not.
public struct AcademicTerm: Sendable, Hashable {
    public enum Season: String, Sendable, Hashable, CaseIterable {
        case spring, summer, fall

        /// The (month, day) the term is treated as starting on.
        var boundary: (month: Int, day: Int) {
            switch self {
            case .spring: return (1, 1)     // after the winter break; fall is done
            case .summer: return (5, 20)    // spring grades are in
            case .fall:   return (8, 15)    // ahead of NSO / first day of classes
            }
        }
    }

    public let season: Season
    public let year: Int

    /// First moment of the term. Nothing due before this belongs on the
    /// dashboard.
    public let start: Date

    public init(season: Season, year: Int, start: Date) {
        self.season = season
        self.year = year
        self.start = start
    }

    /// The term `date` falls in — the latest term boundary at or before it.
    public static func current(on date: Date = Date(), calendar: Calendar = .current) -> AcademicTerm {
        let year = calendar.component(.year, from: date)
        // Newest first: the first boundary that has already passed is the term
        // we're in. January dates fall through to the previous year's fall only
        // if a calendar disagrees about year boundaries.
        let candidates: [(season: Season, year: Int)] = [
            (.fall, year), (.summer, year), (.spring, year), (.fall, year - 1),
        ]
        for candidate in candidates {
            guard let start = startDate(season: candidate.season, year: candidate.year, calendar: calendar),
                  start <= date
            else { continue }
            return AcademicTerm(season: candidate.season, year: candidate.year, start: start)
        }
        // Unreachable on a Gregorian calendar. Degrade to "nothing is out of
        // scope" rather than hiding a student's real work.
        return AcademicTerm(season: .spring, year: year, start: .distantPast)
    }

    static func startDate(season: Season, year: Int, calendar: Calendar) -> Date? {
        var components = DateComponents()
        components.year = year
        components.month = season.boundary.month
        components.day = season.boundary.day
        components.hour = 0
        components.minute = 0
        components.second = 0
        return calendar.date(from: components)
    }
}
