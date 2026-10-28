import Foundation

/// The announcement tasks that are a same-day reminder to show up, and not
/// work: "Attend the weekly rotation quiz", "Bring a calculator", "Come to
/// class", "Join us for the guest talk", "Take the quiz in class today".
///
/// **Why this exists.** A professor who posts at 8 a.m. that "we have the
/// rotation quiz in class today" has told the class where to be in a few hours,
/// and the extractors, honestly, read it as a task: it names a verb, a day and
/// (for the quiz) an assessment. It is never wrong about what the post said.
/// It is wrong about what the student needs: by the time it reaches a card the
/// student is in the room, and a card that says "Attend ..." and then sits in
/// todo, and later in prev, is exactly the clutter the owner asked to be rid of
/// on 2026-10-18 ("none of these previous ones are honestly helpful"). A
/// *deadline* for the same day ("HW 3 due tonight") is the opposite case and
/// must stay: it is work the student can still fail to do.
///
/// So the rule has two halves that both have to hold, and neither alone is
/// enough:
///
///  - the **title** is an instruction to be somewhere or bring something
///    (`isAttendanceInstruction`), and
///  - the task is **due the same day as the post**, within about 12 hours of it
///    or on the same calendar day (`isSameDayReminder`).
///
/// The wrong fix is the vocabulary alone: "Bring a calculator to Thursday's
/// exam", posted on Monday, is preparation the student wants to see until
/// Thursday. The other wrong fix is the time alone: that would put away
/// "Submit the lab report by tonight" along with the reminders. Pure: no clock,
/// no ledger, no network. Where it is applied (a visibility rule at rebuild
/// time, never a deletion) is `AppState.isHiddenAnnouncementTask`.
public enum AnnouncementClassReminder {
    /// "About 12 hours" (the owner's figure): a post at 8 p.m. for an 8 a.m.
    /// class the next morning is the same reminder as one posted at 8 a.m. for
    /// 10 a.m., and a calendar-day test alone would call the first one a
    /// different day.
    public static let sameDayWindow: TimeInterval = 12 * 60 * 60

    /// Instructions to be somewhere or to bring something, as a task title
    /// *opens*. The titles are the extractors' short imperative phrases, so the
    /// verb leads. The lead-ins are only the courtesies those phrases carry
    /// ("Please bring ...", "Remember to bring ..."). `attend` is followed by a
    /// word boundary, so "attendance policy" is not an instruction to attend,
    /// and `come to` is a phrase, so "Come up with a project title" is not
    /// "come to". `.?` stands for the apostrophe in "don't", straight or
    /// curly, so the pattern needs no `\u{2019}` escape (a raw string would
    /// pass that through literally and the pattern would silently fail to
    /// compile; CLAUDE.md, Traps).
    private static let leadingInstruction =
        "^\\s*(?:please\\s+|remember\\s+to\\s+|don.?t\\s+forget\\s+to\\s+)?(?:attend|come\\s+(?:to|in)|bring|join\\s+us)\\b"

    /// "in class today" / "in lecture today", wherever it falls in the title:
    /// "Take the quiz in class today" is a reminder to be in class, not a
    /// piece of work to hand in.
    private static let inClassToday = "\\bin\\s+(?:class|lecture)\\s+today\\b"

    /// True when `title` tells the student to be somewhere or bring something:
    /// "attend ...", "come to ...", "bring ...", "join us ...", or "... in
    /// class/lecture today".
    public static func isAttendanceInstruction(_ title: String) -> Bool {
        matches(leadingInstruction, in: title) || matches(inClassToday, in: title)
    }

    /// True when `title` is an attendance instruction **and** the task falls
    /// due within `sameDayWindow` of `postedAt` or on the same calendar day.
    /// Either distance counts, in either direction: a post at 7 a.m. for a task
    /// stamped 11:59 p.m. (the end of the day an extractor defaults to) is 17
    /// hours away and still the same day; a post at 11 p.m. for 8 a.m. is the
    /// next day and 9 hours away.
    public static func isSameDayReminder(
        title: String,
        dueAt: Date,
        postedAt: Date,
        calendar: Calendar = .current
    ) -> Bool {
        guard isAttendanceInstruction(title) else { return false }
        if abs(dueAt.timeIntervalSince(postedAt)) <= sameDayWindow { return true }
        return calendar.isDate(dueAt, inSameDayAs: postedAt)
    }

    private static func matches(_ pattern: String, in text: String) -> Bool {
        RegexCache.contains(pattern, in: text, options: [.caseInsensitive])
    }
}
