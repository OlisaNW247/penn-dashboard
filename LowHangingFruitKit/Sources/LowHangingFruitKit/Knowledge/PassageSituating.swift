import Foundation

/// Where a passage sits in time and in the course, written once and used twice:
/// as the label the phone puts on every excerpt it sends (`BackendAssistantResponder`),
/// and as the situating terms the BM25 index adds to every passage of a document
/// (`CourseSearch`). Step 4 of `docs/TREE_CONTEXT_RESEARCH_2026-11-02.md` Part 3.
///
/// Why: a post and a syllabus that disagree can only be resolved by "newer wins"
/// if the model can see both ages, and the old label gave a month and day with
/// no year and no distance from now ("posted Oct 3"), and nothing at all for a
/// syllabus. Why the index half: a query like "cis 2620 syllabus late policy"
/// shares no word with a passage whose body says only "late work loses ten
/// percent", so the passage was findable only through the 12-term title hint.
/// This is Contextual Retrieval without a model: the situating text is built
/// from fields the document already has, indexed, never stored.
///
/// Everything here reads `askedAt` or a document's own dates, never the clock,
/// and an `en_US_POSIX` Gregorian calendar, so the same inputs give the same
/// bytes (the excerpts sit after the prompt-cache breakpoint, but tests and
/// traces still depend on determinism).
public enum PassageSituating {
    /// `ed` and `announcement` are dated by when they were posted; every other
    /// kind carries an edit time, which is not news. A "newer wins" rule
    /// compares the two, so the word differs.
    public static func isPostedKind(_ kind: CourseDocument.Kind) -> Bool {
        kind == .ed || kind == .announcement
    }

    /// `2026-11-01` for `date` in `timeZone`.
    public static func absoluteDay(_ date: Date, in timeZone: TimeZone) -> String {
        let calendar = Self.calendar(in: timeZone)
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        func pad(_ value: Int, _ width: Int) -> String {
            let text = String(value)
            return String(repeating: "0", count: max(0, width - text.count)) + text
        }
        return "\(pad(parts.year ?? 0, 4))-\(pad(parts.month ?? 0, 2))-\(pad(parts.day ?? 0, 2))"
    }

    /// Whole local days from `date`'s day to `askedAt`'s day, in `timeZone`
    /// (positive: `date` is in the past).
    public static func ageInDays(of date: Date, askedAt: Date, in timeZone: TimeZone) -> Int {
        let calendar = Self.calendar(in: timeZone)
        let from = calendar.startOfDay(for: date)
        let to = calendar.startOfDay(for: askedAt)
        return calendar.dateComponents([.day], from: from, to: to).day ?? 0
    }

    /// `today`, `yesterday`, `3 days ago`; a future date (a clock-skewed
    /// document) reads `tomorrow` or `in 3 days`.
    public static func relativeAge(of date: Date, askedAt: Date, in timeZone: TimeZone) -> String {
        let days = ageInDays(of: date, askedAt: askedAt, in: timeZone)
        if days == 0 { return "today" }
        if days == 1 { return "yesterday" }
        if days == -1 { return "tomorrow" }
        if days > 1 { return "\(days) days ago" }
        return "in \(-days) days"
    }

    /// `2026-11-01 (yesterday)`.
    public static func dayWithAge(_ date: Date, askedAt: Date, in timeZone: TimeZone) -> String {
        "\(absoluteDay(date, in: timeZone)) (\(relativeAge(of: date, askedAt: askedAt, in: timeZone)))"
    }

    /// `posted 2026-11-01 (yesterday)` for an Ed post or announcement,
    /// `updated 2026-10-14 (31 days ago)` for any other kind, `nil` for a
    /// document with no date at all (no made-up date).
    ///
    /// The date is `shownPostedAt`, which for an Ed post is the posting day in
    /// its header and not the thread's last activity (a reply must not make a
    /// September post read as October's).
    public static func dateLabel(for document: CourseDocument, askedAt: Date, in timeZone: TimeZone) -> String? {
        guard let date = document.shownPostedAt else { return nil }
        let word = isPostedKind(document.kind) ? "posted" : "updated"
        return "\(word) \(dayWithAge(date, askedAt: askedAt, in: timeZone))"
    }

    /// The fixed zone the index uses for the absolute date, because the index
    /// is built without a question. Penn and every other supported school keep
    /// Eastern time, and a one-day slip in an indexed digit string costs
    /// nothing (the label the model reads uses the student's own zone).
    static let indexTimeZone = TimeZone(identifier: "America/New_York") ?? .gmt

    /// `<course code> <kind word> "<title>" <absolute date if dated>`, the one
    /// situating line indexed with every passage of `document`. Course and kind
    /// come first because `BM25Index` keeps only the first dozen distinct
    /// words of it, and those two are the ones a title cannot supply.
    public static func indexLine(for document: CourseDocument) -> String {
        var parts = [document.course, document.kind.label, "\"\(document.title)\""]
        if let date = document.shownPostedAt { parts.append(absoluteDay(date, in: indexTimeZone)) }
        return parts.joined(separator: " ")
    }

    private static func calendar(in timeZone: TimeZone) -> Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.locale = Locale(identifier: "en_US_POSIX")
        calendar.timeZone = timeZone
        return calendar
    }
}
