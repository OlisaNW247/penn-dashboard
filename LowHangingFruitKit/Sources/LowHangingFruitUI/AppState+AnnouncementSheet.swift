import Foundation
import LowHangingFruitKit

// What the megaphone sheet is allowed to show, and so what its badge may count.
//
// The owner's note on the old sheet was that it should "honestly just be the
// most recent announcements from each class", over "just the past 7 days", with
// the tasks and exams found in them beside it ("Midterm 2 looks great like
// that"), and that old found tasks from September are "not helpful". So the
// sheet has two lists, and this file is the one place that says which rows
// belong in each:
//
// - **Found**: tasks found in Canvas announcements and Ed posts, plus found
//   exams, including the syllabus's. Only what is still ahead of the student:
//   not finished (`announcementPageItems` has already dropped those) and not
//   hidden by the dashboard's own visibility rule (`isHiddenAnnouncementTask`:
//   past, undated and a week past its post, or a same-day "be there"
//   reminder). It is that one rule, applied to the same rows, so nothing the
//   dashboard has put away is listed here and nothing it still shows for being
//   upcoming is missing. (The per-class "announcements on dashboard" and
//   "nothing to submit" switches are not applied: they decide what becomes a
//   dashboard card, and this list is about what the posts said.)
// - **Announcements**: Canvas announcements and Ed announcements/pinned posts
//   posted in the last 7 days. Older ones stay in the log (it still holds 60
//   days, and nothing here deletes) and are simply not listed.
//
// The badge counts exactly these two lists, so it can never count something the
// student cannot find. Everything here is read-only: it neither creates nor
// removes a ledger row, and it leaves the dashboard's own placement and
// visibility rules alone.

extension AppState {
    /// How far back the sheet lists announcements.
    nonisolated static let announcementSheetWindowDays = 7

    nonisolated static var announcementSheetWindow: TimeInterval {
        TimeInterval(announcementSheetWindowDays) * 24 * 60 * 60
    }

    /// The posts the sheet may list: posted (`AnnouncementRecord.sortDate`, so
    /// an undated post counts from when this phone first saw it) no longer ago
    /// than the window, newest first. Exactly seven days ago is in, because
    /// "the past 7 days" read at the second it turns seven is still the past 7
    /// days, and a rule that drops a post a second early is the kind of edge
    /// nobody can see coming. There is no upper bound: a post stamped slightly
    /// ahead by clock skew is today's, not a stranger's.
    nonisolated static func announcementRecordsInSheetWindow(
        _ records: [AnnouncementRecord],
        now: Date
    ) -> [AnnouncementRecord] {
        let cutoff = now.addingTimeInterval(-announcementSheetWindow)
        return records
            .filter { $0.sortDate >= cutoff }
            .sorted(by: AnnouncementRecord.isNewer(_:than:))
    }

    /// The found list: `candidates` (`announcementPageItems`, already limited
    /// to unfinished work in classes the student still has) minus whatever
    /// the dashboard keeps off itself, minus second copies of the same task,
    /// soonest first with the undated last.
    ///
    /// "Hidden" is `isHiddenAnnouncementTask`, the rule the dashboard applies
    /// when it builds todo and all, asked here of `dueAt`, the date the card
    /// shows, so a student who moved a task into the future sees it here again.
    /// A task due this very second is not past yet, and a syllabus exam is
    /// never aged. `postDates` carries what the rule needs to age an undated
    /// task or to spot a same-day reminder (`AppState.announcementPostDates`);
    /// with none it judges by the date alone, as the rule does when no post
    /// holds a date any more. The wrong fix is a second, local notion of
    /// "past": the sheet and the dashboard would drift apart the next time the
    /// dashboard's rule changed, and a task would show in one and not the other.
    ///
    /// Second copies are collapsed the way the dashboard collapses them
    /// (`resolvingAnnouncementDuplicates`, offered in `announcementDedupOrder`):
    /// the syllabus's "Midterm 1" and an announcement saying the same midterm
    /// is on Friday are one sitting, and showing two black exam cards for it
    /// would look like the app finding it twice. The page used to be
    /// deliberately undeduplicated, but it listed plain rows beside the post
    /// they came from; these are cards, which promise one per piece of work.
    /// They are compared only with each other: a find that restates a Canvas
    /// assignment stays here, since this list is about what the announcements
    /// said, and the dashboard is where the assignment itself is.
    static func foundAnnouncementItems(
        _ candidates: [Assignment],
        dueAt: (Assignment) -> Date?,
        postDates: AnnouncementPostDates = AnnouncementPostDates(),
        now: Date
    ) -> [Assignment] {
        let ahead = candidates.filter {
            !isHiddenAnnouncementTask(
                $0, dueAt: dueAt($0), postedAt: postDates.postedAt(for: $0),
                firstSeenAt: postDates.firstSeenAt(for: $0), now: now
            )
        }
        let distinct = resolvingAnnouncementDuplicates(
            announcementDedupOrder(ahead),
            against: []
        ).survivors
        return distinct.sorted { lhs, rhs in
            switch (dueAt(lhs), dueAt(rhs)) {
            case let (lhsDate?, rhsDate?) where lhsDate != rhsDate:
                return lhsDate < rhsDate
            case (nil, .some):
                return false
            case (.some, nil):
                return true
            default:
                return lhs.id < rhs.id
            }
        }
    }

    // MARK: Class filter

    /// Whether a row of class `course` survives the sheet's class filter
    /// (`filter`, a class key as the dashboard's class menu hands it out, or
    /// nil for all classes). Compared by course identity and not byte for byte:
    /// an announcement row can carry the raw Canvas descriptor where the menu
    /// holds the cleaned code, and `PHYS 0151` is `PHYS 151`
    /// (`announcementCoursesMatch`, which the duplicate checks use for the same
    /// reason). The dashboard's own filter compares `course` exactly because
    /// its rows all come through one cleaned pool; this list does not.
    static func announcementSheetCourseMatches(_ course: String, filter: String?) -> Bool {
        guard let filter else { return true }
        return announcementCoursesMatch(course, filter)
    }

    /// The found cards of class `course` (all of them for nil). The sheet's
    /// class filter narrows both lists through these two functions, so a test
    /// of them is a test of what the sheet draws.
    static func announcementSheetNarrowed(_ cards: [DashItem], toCourse course: String?) -> [DashItem] {
        cards.filter { announcementSheetCourseMatches($0.assignment.course, filter: course) }
    }

    /// The posts of class `course` (all of them for nil), order kept.
    static func announcementSheetNarrowed(
        _ records: [AnnouncementRecord],
        toCourse course: String?
    ) -> [AnnouncementRecord] {
        records.filter { announcementSheetCourseMatches($0.courseCode, filter: course) }
    }

    // MARK: What the sheet and the badge read

    /// The found list as of `now`. Computed when asked, not at rebuild, so a
    /// task whose time passes while the app sits open leaves the list at the
    /// next look instead of at the next sync.
    func announcementFoundItems(now: Date = Date()) -> [Assignment] {
        let candidates = announcementPageItems
        return Self.foundAnnouncementItems(
            candidates,
            dueAt: { self.effectiveDueDate(for: $0) },
            postDates: announcementPostDates(for: candidates),
            now: now
        )
    }

    /// The found list as the dashboard's own cards, with the student's edited
    /// date and the "nothing to submit" fact, built the way
    /// `DashboardViewModel.reload` builds its items, so the card in the sheet
    /// and the card on the dashboard cannot disagree about a row.
    func announcementFoundCards(now: Date = Date()) -> [DashItem] {
        announcementFoundItems(now: now).map { assignment in
            DashItem(
                assignment: assignment,
                dueOverride: editedDueDate(for: assignment),
                isCompleted: false,
                completedAt: nil,
                requiresNoSubmission: requiresNoSubmission(assignment)
            )
        }
    }

    /// The posts the sheet lists as of `now`: `announcementRecordsOnPage`
    /// (Canvas log and Ed rows, classes still selected) within the 7-day window.
    func announcementSheetRecords(now: Date = Date()) -> [AnnouncementRecord] {
        Self.announcementRecordsInSheetWindow(announcementRecordsOnPage, now: now)
    }
}
