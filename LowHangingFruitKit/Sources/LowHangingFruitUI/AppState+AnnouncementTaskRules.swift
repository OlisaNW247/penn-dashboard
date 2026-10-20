import Foundation
import LowHangingFruitKit

// MARK: – Which tasks found in announcements are on the dashboard
//
// A task the Announcement Watcher or the Ed pass found in a post is the app's
// reading of a professor's prose, not a record Canvas keeps. Until 2026-10-18
// the dashboard moved such a task into prev, marked "past", once its date had
// gone by, and an undated one never left at all. On the owner's phone that
// filled todo, all and prev with "Take quiz covering assignments 1 and 2" (an
// Ed post from Sept 14, long since taken) and "Attend the weekly rotation quiz"
// (a start-of-class reminder), and the owner's verdict was "none of these
// previous ones are honestly helpful".
//
// The rules, all visibility rules evaluated at rebuild time:
//
//  1. **Past.** A task whose date has passed, and which the student has not
//     finished, is on the dashboard nowhere: not todo, not all, not prev. A
//     finished one is ordinary finished work and stays in prev. The date is
//     the one the card shows, the student's edit if there is one, so moving a
//     task forward brings it back.
//  2. **Undated tasks age out.** One with no date shows for seven days after
//     its post (`undatedAnnouncementTaskLifetime`), then goes the same way.
//  3. **Same-day reminders are not cards**: "attend ...", "come to ...",
//     "bring ...", "join us ...", "... in class today" due within about 12
//     hours of the post (`AnnouncementClassReminder`). A real deadline for the
//     same day ("HW 3 due tonight") is not touched, and neither is a found
//     exam.
//
// **Nothing is deleted.** These rows are the app's only record of a post the
// extractor will never read again (`processedAnnouncementIDs` has it), and a
// row hidden by a rule comes back the moment the rule stops matching: the
// student moves its date, or a changed rule lets it through. The rules look
// only at unfinished work; a finished task reaches prev through the completed
// pool like any other. The wrong fix is pruning the rows (or flagging them
// `isGoneFromFeed`, which is a statement about the post and not about its
// age). The second wrong fix is parking the stale ones in a quieter list,
// which is what put them in prev in the first place.
//
// The megaphone's found list asks this same rule
// (`foundAnnouncementItems`, `AppState+AnnouncementSheet.swift`), so a task
// hidden here is not listed there either. So does ask's work pool
// (`announcementItemsStillOpen`, since the 2026-10-20 merge, asked of the feed
// date and not the student's edit). The one place that cannot is the widget's
// ledger fallback (`LedgerWidgetReader`), a separate process with no post
// dates: it keeps the dated half of the rule (`dueAt < now`) for announcement
// rows and nothing else.

extension AppState {
    /// How long an undated task found in an announcement stays on the
    /// dashboard after its post: a week. An undated task has no date to pass,
    /// so without this it would leave only by being finished, by its post being
    /// deleted, or by its class being hidden.
    nonisolated static let undatedAnnouncementTaskLifetime: TimeInterval = 7 * 24 * 60 * 60

    /// Where the post dates for one rebuild come from, kept apart from the
    /// rule so the rule stays a pure function of a date.
    struct AnnouncementPostDates: Sendable {
        /// Canvas announcement id -> `posted_at`, from `AnnouncementLog`.
        var canvas: [String: Date] = [:]
        /// Ed document id (`ed:{course}:{thread}`) -> the post's date
        /// (`AppState.edPostDate`).
        var ed: [String: Date] = [:]
        /// Ledger row id -> when the app first saw the row, the fallback for a
        /// post neither of the above still holds.
        var firstSeen: [String: Date] = [:]

        /// The date the post itself gives `item`: the log's for a Canvas post,
        /// the document's for an Ed post. Nil when neither still holds the
        /// post, and for a syllabus exam, which is no post's.
        func postedAt(for item: Assignment) -> Date? {
            if let announcementID = AnnouncementRecord.announcementID(fromFindSourceID: item.sourceID),
               let posted = canvas[announcementID] {
                return posted
            }
            if let documentID = AnnouncementRecord.edDocumentID(fromFindSourceID: item.sourceID),
               let posted = ed[documentID] {
                return posted
            }
            return nil
        }

        /// When the app first saw the row, for an undated task whose post no
        /// longer gives a date. Nil for a syllabus exam, which is never aged.
        /// It is later than the post, never earlier, so aging by it errs
        /// towards keeping a card a little longer; it is therefore good enough
        /// for the seven-day lifetime and not good enough for the same-day
        /// reminder rule, which compares the post's time with the task's.
        func firstSeenAt(for item: Assignment) -> Date? {
            item.announcementOrigin == .syllabus ? nil : firstSeen[item.id]
        }
    }

    /// Whether a task found in an announcement is kept off the dashboard as of
    /// `now`. `dueAt` is passed in, not read off the item, so the caller can
    /// supply the student's edited date (`effectiveDueDate(for:)`), the one the
    /// card shows. `postedAt` is the post's own date, nil when no post holds
    /// one any more; `firstSeenAt` is the ledger's date for the row, used only
    /// to age an undated task when `postedAt` is nil. With neither, the rules
    /// that need a date are off rather than guessing.
    ///
    /// The same-day reminder rule uses `postedAt` alone, on purpose. It
    /// compares the post's time with the task's, and when the app first saw the
    /// row is not the post's time: "Bring a signed permission form", due an
    /// hour after a sync that found it, is a task to see, not a same-day
    /// reminder to be somewhere. Without the post's date the rule keeps the
    /// card.
    ///
    /// Only announcement-derived items are judged. A Canvas or Gradescope
    /// assignment that is past due is overdue until the student turns it in,
    /// an `.event` from the feed expires by `isExpired`, and manual work
    /// is the student's own; none is touched. A card merged with a Gradescope
    /// twin (`linkedID`) stands for a real, tracked assignment and is left
    /// alone too.
    nonisolated static func isHiddenAnnouncementTask(
        _ item: Assignment,
        dueAt: Date?,
        postedAt: Date?,
        firstSeenAt: Date? = nil,
        now: Date,
        calendar: Calendar = .current
    ) -> Bool {
        guard item.source == .canvasAnnouncement, item.linkedID == nil else { return false }

        if let dueAt {
            if dueAt < now { return true }
            // A found exam is never a "be there" reminder: "Midterm in class
            // today" is the exam card, and the loudest card there is.
            if !item.isFoundExam,
               let postedAt,
               AnnouncementClassReminder.isSameDayReminder(
                   title: item.title, dueAt: dueAt, postedAt: postedAt, calendar: calendar
               ) {
                return true
            }
            return false
        }

        guard let aged = postedAt ?? firstSeenAt else { return false }
        return now > aged.addingTimeInterval(undatedAnnouncementTaskLifetime)
    }

    /// The date an Ed post counts as posted: the posting day its header names
    /// (`CourseDocument.shownPostedAt`, the `· posted yyyy-MM-dd` token the
    /// builder writes since 2026-10-19), else the document's `updatedAt`, nil
    /// when it has neither.
    ///
    /// **`updatedAt` alone was the thread's last activity, not its creation**
    /// (`EdIngestion.documents` stores `updatedAt ?? createdAt`, and
    /// `CourseDocument` is a wire type with no field for the creation date), so
    /// an old thread somebody replied to yesterday read as posted yesterday;
    /// this comment used to wish for the real creation date, and the header
    /// token is that date. It remains the fallback for a document synced
    /// before the token existed, which reads as before until the thread is
    /// fetched again. The pass, its 14-day window and the seven-day lifetime
    /// all use this one function so they cannot disagree. The posting day is
    /// noon US Eastern on the day, so it is a day-sized estimate, not the
    /// minute.
    nonisolated static func edPostDate(_ document: CourseDocument) -> Date? {
        document.shownPostedAt
    }

    /// The post dates `items` can be aged by, gathered for one rebuild. Cheap
    /// when there is nothing to age: each source is read only if some item
    /// needs it.
    func announcementPostDates(for items: [Assignment]) -> AnnouncementPostDates {
        var dates = AnnouncementPostDates()
        guard !items.isEmpty else { return dates }

        for record in announcementLogRecords {
            if let posted = record.postedAt { dates.canvas[record.id] = posted }
        }
        if items.contains(where: { $0.announcementOrigin == .ed }) {
            for document in courseKnowledge.documents where document.kind == .ed {
                if let posted = Self.edPostDate(document) { dates.ed[document.id] = posted }
            }
        }
        // The ledger is read only for a row no post date was found for.
        if items.contains(where: { dates.postedAt(for: $0) == nil && $0.announcementOrigin != .syllabus }) {
            dates.firstSeen = assignmentStore?.firstSeenDates(source: .canvasAnnouncement) ?? [:]
        }
        return dates
    }
}
