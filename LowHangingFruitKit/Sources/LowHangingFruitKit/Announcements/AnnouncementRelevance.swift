import Foundation

/// How long one announcement, as a whole, stays worth listing on the
/// megaphone sheet, as `extract-announcement` judges it (`backend/PROTOCOL.md`,
/// "`extract-announcement`"). One judgment per post: the phone stores it beside
/// the announcement log's read state and never asks again
/// (`AnnouncementRelevanceStore`).
///
/// It is the model's reading of the post, not a date the student set, so it
/// only ever *removes* a post from the standing list, or brings an old one
/// back, by the rule in `AppState+AnnouncementSheet.swift`. It never creates,
/// edits or deletes a ledger row, and it is not the task list: a post can be
/// `news` and still have yielded a task, and a post can be `standing` and have
/// yielded none.
public struct AnnouncementRelevance: Codable, Sendable, Equatable {
    public enum Kind: String, Codable, Sendable, Equatable, CaseIterable {
        /// About a dated happening (an exam, a review session, a room change).
        /// `until` is when it is over.
        case event
        /// Mainly about work to do. `until` is the latest due date it names.
        case task
        /// A resource or policy useful for the rest of the term (a formula
        /// sheet, an office-hours schedule). No `until`.
        case standing
        /// An FYI that stops mattering within days. No `until`.
        case news
    }

    public let kind: Kind
    /// Nil when the server sent none or sent one this client cannot read.
    /// The server may send one for any kind; the rule only reads it for
    /// `event` and `task`.
    public let until: Date?

    public init(kind: Kind, until: Date? = nil) {
        self.kind = kind
        self.until = until
    }

    /// Reads the two strings the server sends, or nil when `kind` is not
    /// exactly one of the four known values. A `kind` this client cannot place
    /// is no judgment at all, not a guess at which one was meant: the sheet
    /// treats "no relevance" as "decide the old way", which is safe, and a
    /// guessed kind could hide a post that matters. An `until` that does not
    /// parse is dropped on its own and the kind survives, as on the server
    /// (`parseRelevance`).
    ///
    /// `until` is accepted in two shapes (`parseUntil`): ISO 8601 with a `Z`
    /// or a numeric offset, with or without fractional seconds; or a bare
    /// calendar date, which means the end of that day on this phone. Anything
    /// else is dropped. `timeZone` is the zone a bare date is read in; the app
    /// always passes the device's, a test passes its own.
    public init?(wireKind: String?, wireUntil: String?, timeZone: TimeZone = .current) {
        guard let wireKind, let kind = Kind(rawValue: wireKind) else { return nil }
        self.kind = kind
        self.until = wireUntil.flatMap { Self.parseUntil($0, timeZone: timeZone) }
    }

    /// An `until` string as an instant, or nil.
    ///
    /// - **A date-time with an offset** (`2026-10-30T23:59:00-04:00`,
    ///   `...Z`, fractional seconds allowed) is that instant
    ///   (`BackendJSON.parseDate`, the acceptance every other date on this
    ///   wire uses).
    /// - **A bare date** (`2026-10-26`) is the **end** of that day,
    ///   23:59:59, in `timeZone`. The model will often write one for an exam
    ///   or a session ("the exam is Oct 26"), and the day is all it knew. The
    ///   end of the day, not the start: at midnight the post would read as
    ///   over from the first minute of the very day it is about, hiding the
    ///   exam announcement on exam day. The device's zone, not UTC or Eastern:
    ///   "Oct 26" means the student's own calendar day, and in UTC an evening
    ///   exam would end the day before it happens. A day that does not exist
    ///   (`2026-02-31`), which `Calendar` would quietly roll into March, is
    ///   dropped.
    /// - **A date-time with no offset** (`2026-10-26T14:00:00`) is dropped:
    ///   it is a different instant on every phone, and nothing says whose
    ///   clock it was written on. Giving it a zone would be a guess where the
    ///   bare date has a defensible reading, so it keeps no `until`.
    static func parseUntil(_ raw: String, timeZone: TimeZone) -> Date? {
        if let instant = BackendJSON.parseDate(raw) { return instant }
        return endOfDay(raw, in: timeZone)
    }

    private static func endOfDay(_ raw: String, in timeZone: TimeZone) -> Date? {
        let pieces = raw.split(separator: "-", omittingEmptySubsequences: false)
        guard raw.utf8.count == 10, pieces.count == 3,
              pieces[0].count == 4, pieces[1].count == 2, pieces[2].count == 2,
              raw.allSatisfy({ $0 == "-" || ($0.isASCII && $0.isNumber) }),
              let year = Int(pieces[0]), let month = Int(pieces[1]), let day = Int(pieces[2])
        else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        guard let date = calendar.date(
            from: DateComponents(year: year, month: month, day: day, hour: 23, minute: 59, second: 59)
        ) else { return nil }
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        guard back.year == year, back.month == month, back.day == day else { return nil }
        return date
    }
}

/// An announcement's extraction: the tasks found in it, and the relevance
/// judgment when the extractor made one. The heuristic extractor, and any
/// extractor written before relevance existed, returns no relevance.
public struct AnnouncementExtraction: Sendable, Equatable {
    public let assignments: [ExtractedAssignment]
    public let relevance: AnnouncementRelevance?

    public init(assignments: [ExtractedAssignment], relevance: AnnouncementRelevance? = nil) {
        self.assignments = assignments
        self.relevance = relevance
    }

    /// What `extract-announcement` answered, as the sync consumes it.
    /// `taskKind` is `ExtractedAssignmentWire`'s resolved `ExtractedTaskKind`
    /// (`.kind` is the raw string the server actually sent, kept on the wire
    /// type for whatever fallback decoding it does with an unrecognized
    /// value), so reading through it keeps this mapping agnostic to how that
    /// resolution happens.
    public init(response: ExtractAnnouncementResponse) {
        self.init(
            assignments: response.assignments.map {
                ExtractedAssignment(title: $0.title, dueAt: $0.dueAt, kind: $0.taskKind)
            },
            relevance: response.relevance
        )
    }
}
