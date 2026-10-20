import Foundation

// MARK: – Exams the app finds, and when two finds are one exam
//
// An exam reaches the dashboard by three roads: Canvas or Gradescope lists it
// (a feed item), an instructor announces it (a task the Announcement Watcher
// extracts, from Canvas or Ed), or the syllabus names it next to a date
// (`SyllabusExamRows`). The owner's rule is that the class finds it either
// way and it is never shown twice. This file is the pure half of that rule:
// what counts as a *found* exam, and when two mentions are one sitting.
// `AppState.resolvingAnnouncementDuplicates` applies it; nothing here knows
// about the dashboard.

extension ExamIdentity {
    /// The identity as a string that is safe inside a ledger `sourceID`:
    /// `midterm-1`, `final`, `midterm-1-makeup`. Kind, then the number if
    /// there is one, then the modifiers in a fixed order. The course is left
    /// out on purpose (the caller already scopes by it), and so is the date,
    /// so the same exam keeps the same key when it moves.
    ///
    /// Unambiguous because the three parts cannot be confused for one
    /// another: kinds and modifiers are words, the number is digits, and no
    /// modifier is also a kind.
    public var sourceKey: String {
        var parts = [kind.rawValue]
        if let ordinal { parts.append(String(ordinal)) }
        parts.append(contentsOf: modifiers.sorted())
        return parts.joined(separator: "-")
    }
}

extension Assignment {
    /// True for a row the app found rather than one Canvas or Gradescope
    /// lists: an exam out of the syllabus, or a task found in an announcement
    /// whose title is an exam (`ExamDetection.leadingExamIdentity`).
    ///
    /// This is the one question the dashboard asks to treat an exam as an
    /// exam: it shows for every visible class whatever the "announcements on
    /// dashboard" and "items with nothing to submit" switches say, it is drawn
    /// as an exam card even when its title is terse, and it never gets the loud
    /// 10-minute alert. A feed exam is deliberately not one: Canvas knows its
    /// submission state and its link, and it keeps all of its existing rules.
    ///
    /// A syllabus row is an exam by construction. An announcement row is one
    /// only when its title *leads with* the exam ("Midterm 1", "Take the final
    /// exam"), and not when the title merely mentions one ("Bring a calculator
    /// to the exam", "Read chapters 1-5 for the midterm"). The second kind is
    /// an ordinary task that happens to be about an exam, and it keeps
    /// answering to the class's "announcements on dashboard" and "nothing to
    /// submit" switches like every other task; calling it an exam would have a
    /// student who turned announcement tasks off still reading them.
    public var isFoundExam: Bool {
        guard source == .canvasAnnouncement else { return false }
        return announcementOrigin == .syllabus
            || ExamDetection.leadingExamIdentity(title: title, course: course) != nil
    }
}

extension ExamDetection {

    /// The identity of the exam `title` is *about*, or nil when it names none
    /// or only mentions one on the way to saying something else.
    ///
    /// A title is about the exam when the exam is the first thing it says:
    /// nothing comes before the exam's name except the words an extractor
    /// leaves on the front of a task ("Take the", "Please sit the", "In-class")
    /// and which sitting it is ("Makeup"). "Midterm 1", "Take the final exam"
    /// and "Exam 2 (Section 001)" are about an exam; "Bring a calculator to the
    /// exam" and "Read chapters 1-5 for the midterm" are about a calculator and
    /// some reading. `examIdentity(title:course:)` finds both, because it asks
    /// whether an exam is named, and that is the right question for a card's
    /// colour. It is the wrong one for deciding that a task *is* an exam, which
    /// switches off the class's switches for it and hides every other card the
    /// same exam can match, and a calculator reminder must not hide the
    /// midterm it is a reminder for.
    ///
    /// The wrong fix is a longer list of such sentences to refuse; the right
    /// question is where the exam sits in the title.
    public static func leadingExamIdentity(title: String, course: String) -> ExamIdentity? {
        guard let mention = mentions(in: title, contextWindow: nil).first else { return nil }
        let before = title[..<mention.range.lowerBound]
            .lowercased()
            .split { !$0.isLetter && !$0.isNumber }
            .map(String.init)
        guard before.allSatisfy(leadingFiller.contains) else { return nil }
        return ExamIdentity(
            course: normalizedCourse(course),
            kind: mention.kind,
            ordinal: mention.ordinal,
            modifiers: mention.modifiers
        )
    }

    /// What may stand in front of an exam's name without making the title about
    /// something else. Directives an extractor keeps from the sentence, the
    /// words that fill them out, and the modifier words (which
    /// `ExamIdentity.modifiers` carries separately).
    private static let leadingFiller: Set<String> = [
        "take", "taking", "sit", "sitting", "attend", "attending", "complete", "write", "do", "please",
        "the", "a", "an", "your", "our", "this", "in", "class", "inclass",
        "makeup", "make", "up", "retake", "re", "alternate", "alternative",
    ]

    /// How far apart two mentions of the *same* exam may be dated and still be
    /// one sitting. This is what lets a rescheduled midterm (the syllabus says
    /// Oct 23, an announcement says Oct 30) stay one card while a recycled
    /// Canvas site's last-year "Final Exam" does not swallow this year's: a
    /// reschedule moves an exam by days or a few weeks, a recycled site by a
    /// year. Two months is far above the first and far below the second.
    ///
    /// The wrong version is no bound at all, which is what "same identity, so
    /// same exam" says: the old term's row would then hide the new one's.
    public static let rescheduleWindowDays = 60

    /// Whether two mentions in the same course are one sitting.
    ///
    /// The caller has already established that the course is the same (it
    /// does that with `CourseCode`, which understands more spellings than the
    /// normalised string inside `ExamIdentity`), so the course is not
    /// compared here.
    ///
    /// - **Makeups are never the ordinary sitting.** Different modifiers, never
    ///   the same, whatever the dates say.
    /// - **Same kind, same number** ("Midterm 1" and "Midterm 1"): the same
    ///   exam, wherever the dates fall inside `rescheduleWindowDays`, and
    ///   whether or not either has a date. An undated mention names the exam
    ///   but cannot move it.
    /// - **Anything else is "possibly the same", and only dates can say.**
    ///   "Midterm" and "Midterm 1", "Midterm 2" and "Exam 2", "Test 1" and
    ///   "Midterm 1" are one sitting only when both are dated and the days are
    ///   no more than one apart. Matching on the words alone would also fold an
    ///   unnumbered "Midterm" into both "Midterm 1" and "Midterm 2" of a course
    ///   that has two. Two different numbers are never the same, and a final
    ///   is only ever another final.
    ///
    /// "No more than one day" is by calendar day, not by 24 hours: a feed
    /// item at 11:59 PM and a syllabus date (stored at the end of that same day
    /// by `SyllabusExamRows`) agree, and so do an announcement's 11:59 PM and
    /// a class-time feed entry the day before or after.
    public static func isSameSitting(
        _ lhs: ExamIdentity, due lhsDue: Date?,
        _ rhs: ExamIdentity, due rhsDue: Date?,
        calendar: Calendar = .current
    ) -> Bool {
        guard lhs.modifiers == rhs.modifiers else { return false }

        let gap = dayGap(lhsDue, rhsDue, calendar: calendar)

        if lhs.kind == rhs.kind, lhs.ordinal == rhs.ordinal {
            guard let gap else { return true }
            return gap <= rescheduleWindowDays
        }

        guard let gap, gap <= 1 else { return false }
        if let left = lhs.ordinal, let right = rhs.ordinal, left != right { return false }
        return (lhs.kind == .final) == (rhs.kind == .final)
    }

    /// The whole days between two dates' calendar days, never negative. Nil
    /// when either date is missing.
    private static func dayGap(_ lhs: Date?, _ rhs: Date?, calendar: Calendar) -> Int? {
        guard let lhs, let rhs else { return nil }
        let days = calendar.dateComponents(
            [.day], from: calendar.startOfDay(for: lhs), to: calendar.startOfDay(for: rhs)
        ).day
        return days.map(abs)
    }
}

/// The moment an exam with a date and no time is stored at, and the test for
/// it.
///
/// A date-only entry is "due by the end of that calendar day" everywhere else
/// in the app: Canvas's all-day events are read as 23:59:59 local
/// (`ICSParser.parseDate`) and the announcement extractor files a bare date at
/// 23:59. A syllabus exam with no time follows the same convention rather than
/// inventing a representation of its own, which is what makes it behave like
/// the all-day feed events already do: it sorts and counts down to the end of
/// its day, it is still "today" all day, and it moves to prev when the day is
/// over and not at midnight in the morning of the exam.
///
/// The wrong version is the extractor's own value, the *start* of the day:
/// the exam would read as already past, and lapse into prev, at 12:00 AM on the
/// morning of the exam.
public enum AllDayDueMoment {
    /// 23:59:59 on the day `day` falls on, in `calendar`.
    public static func endOfDay(_ day: Date, calendar: Calendar = .current) -> Date {
        calendar.date(bySettingHour: 23, minute: 59, second: 59, of: day) ?? day
    }

    /// Whether `date` is exactly that moment. The seconds are what make this a
    /// marker and not a guess: a time a person types, and the announcement
    /// extractor's own end-of-day, both land on :00, so :59 is only ever an
    /// all-day entry (Canvas's, or a syllabus exam's).
    public static func isEndOfDay(_ date: Date, calendar: Calendar = .current) -> Bool {
        let parts = calendar.dateComponents([.hour, .minute, .second], from: date)
        return parts.hour == 23 && parts.minute == 59 && parts.second == 59
    }
}
