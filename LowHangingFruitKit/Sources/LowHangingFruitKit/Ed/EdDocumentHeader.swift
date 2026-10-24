import Foundation

/// Reads back the one-line header `EdDocumentBuilder.text(for:decision:)`
/// writes at the top of an Ed document: `[ed · pinned] Homework / Hw 3 ·
/// posted 2026-10-12`, then the body on the following lines.
///
/// **Why this exists.** The builder writes the header so a model reading an
/// excerpt knows where it came from, and so the category words reach the
/// keyword index. Everything that *shows* an Ed document to a student, or
/// decides what it is, then needs the other half of that bargain: which
/// reason the header carries (an announcement and a pinned post are
/// something a student asks "latest announcements" about; a plain staff post
/// is not), and the body without the bracketed bookkeeping, which reads as
/// noise in a sentence. This type is that reader. It parses nothing the
/// builder does not write and fetches nothing, so it cannot change what is
/// kept or stored.
///
/// **The two halves must not drift.** The format lives in the builder; the
/// reader repeats the one literal it needs (`[ed · `), and owns the posting
/// token (`postedMarker`, `postedDayString`) that the builder borrows. The wrong fix for a
/// future change of the header is to edit only one side: every Ed document
/// already on a student's phone, and in the pooled copy, keeps the old
/// header until it is re-synced, and a reader that quietly stopped matching
/// would make every Ed post look like it has no reason, with nothing failing.
/// `EdDocumentHeaderTests` round-trips real builder output for each reason
/// the filter can produce, so a change to either side fails there first.
///
/// **The posting date rides in the header, not on the wire.** A pooled
/// `CourseDocument` has one date, `updatedAt`, and for an Ed thread that is
/// the last-activity time (Ed bumps it on every edit, reply and pin) because
/// that is what keeps a freshly pinned old thread ranking as fresh. Shown to
/// a student as "posted", it was wrong: a Monday post listed as Saturday's,
/// and the assistant telling a student the staff "reminded about a quiz" on
/// the day a reply landed. The wire type cannot grow a field without a
/// protocol change, so the day the thread was *created* is written into this
/// line as `· posted 2026-10-12` and read back as `postedAt`. Documents
/// written before the token existed have none; `postedAt` is `nil` for them
/// and the caller falls back to `updatedAt`, which is what they showed
/// before. The wrong fix would be to show `createdAt` everywhere: recency
/// ranking and the 14-day keep window want the activity date.
///
/// The token is a calendar day in US Eastern time with fixed digits, never a relative
/// date and never the clock, because the text of a document is part of what
/// `ask` caches (CLAUDE.md, "a prompt-cache prefix must be byte-stable").
/// Eastern, not UTC and not the device's zone: every school the app signs in
/// to keeps Eastern time (`BackendAssistantResponder.excerptTimeZone`), and
/// the day a student means is the day on their wall clock. In UTC a Monday
/// 9 PM post is already Tuesday, which is the kind of wrong this token exists
/// to remove. A fixed zone keeps the same instant giving the same bytes on
/// every phone.
///
/// Text with no header (an older document, or a body that is not from the
/// builder at all) is not an error: `reason` is `nil` and `body` is the text
/// whole.
public struct EdDocumentHeader: Sendable, Equatable {
    /// The filter's reason for keeping the thread: "announcement", "pinned"
    /// or "staff post". `nil` when the text carries no header.
    public let reason: String?
    /// The category words after the bracket (`Homework / Hw 3`), or `nil`.
    public let category: String?
    /// Everything after the header line, exactly as the builder wrote it. The
    /// whole text when there is no header.
    public let body: String
    /// The day the thread was posted, from the `· posted yyyy-MM-dd` token,
    /// as noon US Eastern of that day (see `postedDay(from:)` for why noon). `nil`
    /// when the header has no token, or one that is not a real date.
    public let postedAt: Date?

    public init(reason: String?, category: String?, body: String, postedAt: Date? = nil) {
        self.reason = reason
        self.category = category
        self.body = body
        self.postedAt = postedAt
    }

    /// What opens every builder header; the reason follows it, closed by `]`.
    private static let opening = "[ed · "
    private static let closing: Character = "]"
    /// What introduces the posting date at the end of the header line. The
    /// builder writes a space before it; the reader accepts it at the start
    /// of the text after the bracket too, for a thread with no category.
    static let postedMarker = "· posted "

    /// The one calendar the posting day is written and read in: Gregorian in
    /// the fixed zone `America/New_York`, never `Calendar.current`.
    private static var postingCalendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York") ?? TimeZone(secondsFromGMT: -5 * 3600) ?? .gmt
        return calendar
    }

    /// `2026-10-12`: the US Eastern calendar day of `date`, digits only. Built from
    /// calendar components and hand-padded integers, so no formatter, locale
    /// or region setting (nor a `String(format:)` width mismatch on `Int`)
    /// can change a byte of it.
    public static func postedDayString(_ date: Date) -> String {
        let parts = postingCalendar.dateComponents([.year, .month, .day], from: date)
        func padded(_ value: Int?, _ width: Int) -> String {
            let digits = String(max(value ?? 0, 0))
            return String(repeating: "0", count: max(width - digits.count, 0)) + digits
        }
        return "\(padded(parts.year, 4))-\(padded(parts.month, 2))-\(padded(parts.day, 2))"
    }

    /// The date `postedDayString` wrote, or `nil` for anything else: wrong
    /// length, non-digits, or a day that does not exist (`2026-02-31`, which
    /// `Calendar` would otherwise quietly roll into March).
    ///
    /// Returns **noon** Eastern of the day, not midnight. The day is all the
    /// header knows, and the readers format it in the device's or Eastern
    /// zone: noon survives a reader a few hours either side of New York
    /// (midnight would slip to the previous evening in any zone west of it),
    /// where a post from Oct 12 would otherwise print as Oct 11.
    static func postedDay(from string: String) -> Date? {
        let pieces = string.split(separator: "-", omittingEmptySubsequences: false)
        guard string.utf8.count == 10, pieces.count == 3,
              pieces[0].count == 4, pieces[1].count == 2, pieces[2].count == 2,
              string.allSatisfy({ $0 == "-" || ($0.isASCII && $0.isNumber) }),
              let year = Int(pieces[0]), let month = Int(pieces[1]), let day = Int(pieces[2])
        else { return nil }
        let calendar = postingCalendar
        guard let date = calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) else {
            return nil
        }
        let back = calendar.dateComponents([.year, .month, .day], from: date)
        guard back.year == year, back.month == month, back.day == day else { return nil }
        return date
    }

    /// A staff announcement: the thread's type is "announcement".
    public var isAnnouncement: Bool { reason == "announcement" }

    /// A pinned thread (only course staff can pin).
    public var isPinned: Bool { reason == "pinned" }

    /// The two reasons worth listing under "latest announcements". A plain
    /// "staff post" is deliberately not one: it is a staff-authored
    /// non-question that the filter keeps as course material, not something
    /// the staff addressed to the class as news.
    public var isAnnouncementOrPinned: Bool { isAnnouncement || isPinned }

    /// A staff-authored non-question post, which `EdThreadFilter` files under
    /// the reason "staff post" (not "staff": that is only the word the text
    /// uses where provenance matters). Not listed as news: the megaphone sheet
    /// lists its row only while the post's relevance judgment says it still
    /// matters (`AnnouncementRecord.isStaffPost`). The Announcement Watcher's
    /// Ed pass (`syncEdAnnouncementTasks`) reads it, but for that judgment
    /// alone and never for tasks, because a staff post is usually an answer
    /// and "you can submit by Friday" in a reply is not a task the class was
    /// given.
    public var isStaffPost: Bool { reason == "staff post" }

    public static func parse(_ text: String) -> EdDocumentHeader {
        let lineEnd = text.firstIndex(of: "\n") ?? text.endIndex
        let firstLine = text[..<lineEnd]
        guard let opened = firstLine.range(of: opening, options: .anchored),
              let closed = firstLine[opened.upperBound...].firstIndex(of: closing)
        else {
            return EdDocumentHeader(reason: nil, category: nil, body: text)
        }
        let reason = firstLine[opened.upperBound..<closed].trimmingCharacters(in: .whitespaces)
        guard !reason.isEmpty else {
            return EdDocumentHeader(reason: nil, category: nil, body: text)
        }
        var category = firstLine[firstLine.index(after: closed)...].trimmingCharacters(in: .whitespaces)
        // The posting token is the last thing on the line. Only a token whose
        // date is real is taken off the category; anything else is left where
        // it was, so a header that is not the builder's parses as it always did.
        var postedAt: Date?
        if let marker = category.range(of: postedMarker, options: .backwards),
           marker.lowerBound == category.startIndex || category[category.index(before: marker.lowerBound)] == " ",
           let day = postedDay(from: String(category[marker.upperBound...])) {
            postedAt = day
            category = category[..<marker.lowerBound].trimmingCharacters(in: .whitespaces)
        }
        let body = lineEnd == text.endIndex ? "" : String(text[text.index(after: lineEnd)...])
        return EdDocumentHeader(reason: reason, category: category.isEmpty ? nil : category, body: body, postedAt: postedAt)
    }

    /// True when `text`, once its header is set aside, holds nothing a reader
    /// could use: no body at all, or only the `[image]` placeholders
    /// `EdDocumentText` writes where Ed had a picture. Such a post matches a
    /// search on its title and category words alone and then gives the model
    /// (or the student) nothing to read, so `ask` leaves it out of the
    /// excerpts it picks. The test is "no letter or digit left once the
    /// placeholders are removed", so the bullet or quote marker the converter
    /// puts before an image (`- [image]`, `> [image]`) does not count as text.
    public static func carriesNoText(_ text: String) -> Bool {
        let remaining = parse(text).body.replacingOccurrences(of: "[image]", with: "")
        return !remaining.contains { $0.isLetter || $0.isNumber }
    }
}

extension CourseDocument {
    /// The date to call this document's "posted" date wherever one is shown
    /// to a student or to the model: for an Ed document the day in its header
    /// token (`EdDocumentHeader.postedAt`), otherwise (no token, or any other
    /// kind) `updatedAt`, which for Canvas announcements already is the
    /// posting time.
    ///
    /// Display only. Recency ranking (`CourseSearch`) and the Ed keep window
    /// stay on `updatedAt`, because "a TA pinned this today" is exactly
    /// what should make an old thread rank as fresh.
    public var shownPostedAt: Date? {
        if kind == .ed, let posted = EdDocumentHeader.parse(text).postedAt { return posted }
        return updatedAt
    }
}

/// What the on-device answerer and the `ask` excerpt picker need to know about
/// a search hit that came from an Ed Discussion post. Both read the passage
/// through `EdDocumentHeader`, so the two stay in step with the builder.
extension SearchHit {
    /// An Ed passage with nothing to read once the header is set aside: no
    /// body at all, or only `[image]` placeholders (`EdDocumentHeader
    /// .carriesNoText`). Always `false` for any other kind of document.
    public var isTextlessEdPost: Bool {
        document.kind == .ed && EdDocumentHeader.carriesNoText(passage.text)
    }

    /// This hit with an Ed passage's header line removed, for showing to a
    /// student or handing to a model as grounding. The first passage of an Ed
    /// document opens with `[ed · pinned] Homework / Hw 3`; later passages
    /// and every other kind of document have no such line and come back
    /// unchanged. Identity (`passage.id`, the document, the score and the
    /// component) is kept, so nothing that keys on the hit notices.
    public var withoutEdHeader: SearchHit {
        guard document.kind == .ed else { return self }
        let body = EdDocumentHeader.parse(passage.text).body
        guard body != passage.text else { return self }
        return SearchHit(
            passage: Passage(documentID: passage.documentID, ordinal: passage.ordinal, text: body),
            document: document, score: score, component: component
        )
    }
}
