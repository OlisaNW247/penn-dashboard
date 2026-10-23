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
// - **Announcements**: Canvas announcements and Ed announcements/pinned posts.
//   Two sets, then one rule over them.
//
//   *The standing set* is every post from the last 7 days plus, for every
//   class, its single newest post however old it is (inside the 60 days the
//   log holds). Without that second half a quiet class vanishes from the sheet:
//   on the owner's phone (2026-10-23) Canvas returned 21 posts in 60 days, 20
//   of them PHYS 0151 and one FNAR 0010 from September 22, so a strict week
//   showed PHYS alone and FNAR not at all. Older posts beyond each class's
//   newest stay in the log (nothing here deletes) and are simply not listed.
//
//   *The keep-check* then takes a post out of the standing set when it is
//   over, and brings an older one back when it still matters, from two facts
//   about the post: its relevance (`AnnouncementRelevance`, the server's one
//   judgment of how long the post as a whole stays worth listing, kept on the
//   phone, `AnnouncementRelevanceStore`) and the state of the finds that came
//   from it (`AnnouncementFindState`: none, some still to do, or all done or
//   past). The rule is `announcementRecordsForSheet`. The state of the finds
//   needs no AI, and it is the case that prompted this: the PHYS post
//   "derivation of discharging process & combined worksheet 6-7 & exam 2
//   review" produced one find, "combined worksheet 6-7", and went on being
//   listed for a week after the student had turned the worksheet in. A post
//   with no stored judgment (read before the judgment existed, a school the
//   server does not serve, offline) can still be removed by that clause, and
//   otherwise falls back to the standing set alone.
//
//   *Ed staff posts* are candidates of a different kind. A TA's "No recitation
//   today + HW 5" or "Practice questions midterm" is a staff post, which the
//   Ed filter keeps as course material but which is mostly answers and notes,
//   so a staff-post row is listed only when its judgment says it still
//   matters: an `event` whose `until` is ahead, or a `task` whose `until` is
//   ahead or with a find still to do. (The Ed pass reads a staff post for
//   that judgment alone and throws its tasks away, so a staff post has no
//   finds of its own and a `task` is judged by its date.) Never by the 7-day window, never as its class's latest post (so
//   they are left out of the standing set altogether, and a staff post can
//   never be picked as a class's latest only to be hidden, leaving the class
//   unrepresented), never as `standing` or `news`, and never without a
//   judgment.
//
// The badge counts exactly these two lists, so it can never count something the
// student cannot find. Everything here is read-only: it neither creates nor
// removes a ledger row, and it leaves the dashboard's own placement and
// visibility rules alone.

/// What the finds of one announcement say about whether the post is still
/// worth listing: nothing was found in it, something found is still to do, or
/// everything found in it is finished or past.
enum AnnouncementFindState: Sendable, Equatable {
    /// No find on the ledger came from this post.
    case none
    /// At least one find from it is still to do.
    case open
    /// Every find from it is finished or past.
    case allDone
}

extension AppState {
    /// How far back the sheet lists announcements.
    nonisolated static let announcementSheetWindowDays = 7

    nonisolated static var announcementSheetWindow: TimeInterval {
        TimeInterval(announcementSheetWindowDays) * 24 * 60 * 60
    }

    /// The posts the sheet may list, newest first: every post within the
    /// window (`AnnouncementRecord.sortDate`, so an undated post counts from
    /// when this phone first saw it), plus each class's single newest post
    /// even when it is older than the window.
    ///
    /// Exactly seven days ago is in, because "the past 7 days" read at the
    /// second it turns seven is still the past 7 days, and a rule that drops a
    /// post a second early is the kind of edge nobody can see coming. There is
    /// no upper bound: a post stamped slightly ahead by clock skew is today's,
    /// not a stranger's.
    ///
    /// The newest post of a class is chosen with `AnnouncementRecord.isNewer`,
    /// the order the list is shown in, and classes are told apart by
    /// `announcementCourseIdentity` and not by the raw string: an Ed row can
    /// carry `PHYS 151` where the Canvas log has the descriptor's `PHYS 0151`,
    /// and two spellings of one class must not each earn a "newest" post. A
    /// class whose newest post is already inside the window adds nothing, and
    /// no post is listed twice.
    ///
    /// **Ed staff posts are not in this set**, neither by the window nor as a
    /// class's latest (`AnnouncementRecord.isStaffPost`; they have their own
    /// rule in `announcementRecordsForSheet`). Counting one as a class's latest
    /// would pick it, find it has no judgment, and drop it, leaving the class
    /// without the announcement that should have represented it.
    ///
    /// The wrong fix is widening the window (to 14 or 30 days): a class that
    /// posts daily would flood the sheet while a class that posted once a
    /// month would still be missing, and the sheet's job is "where does each
    /// class stand", not "how far back can we go".
    nonisolated static func announcementRecordsInSheetWindow(
        _ allRecords: [AnnouncementRecord],
        now: Date
    ) -> [AnnouncementRecord] {
        let records = allRecords.filter { !$0.isStaffPost }
        let cutoff = now.addingTimeInterval(-announcementSheetWindow)
        // Each distinct course string is parsed once: a log of 60 days can hold
        // hundreds of rows for a handful of classes.
        var identities: [String: String] = [:]
        var newestByClass: [String: Int] = [:]
        for (index, record) in records.enumerated() {
            let identity: String
            if let known = identities[record.courseCode] {
                identity = known
            } else {
                identity = announcementCourseIdentity(record.courseCode)
                identities[record.courseCode] = identity
            }
            if let held = newestByClass[identity],
               !AnnouncementRecord.isNewer(record, than: records[held]) {
                continue
            }
            newestByClass[identity] = index
        }
        let newestOfAClass = Set(newestByClass.values)
        return records.enumerated()
            .filter { $0.element.sortDate >= cutoff || newestOfAClass.contains($0.offset) }
            .map(\.element)
            .sorted(by: AnnouncementRecord.isNewer(_:than:))
    }

    /// The posts the sheet lists: the standing set (`announcementRecordsInSheetWindow`)
    /// minus the posts that are over, plus the older posts that still matter,
    /// newest first. `relevance` and `findState` answer for one record; both
    /// may say "nothing known" (`nil`, `.none`).
    ///
    /// A post in the standing set is shown **unless it is over**:
    /// - it is an `event` whose `until` has passed; or
    /// - every find from it is finished or past (`.allDone`), unless the post
    ///   is `standing` (a resource that outlives its tasks) or an `event` whose
    ///   `until` is still ahead (the happening is still to come, whatever was
    ///   asked of the student for it); or
    /// - it is a `task` whose `until` has passed and no find from it is still
    ///   to do.
    ///
    /// A post **not** in the standing set is shown only if it **still
    /// matters**: it is `standing`; or an `event` whose `until` is not yet
    /// past; or a `task` with a find still to do. A `news` post, and a post
    /// with no judgment, never comes back: those are what the 7-day window
    /// exists to let go of.
    ///
    /// `until` equal to `now` is not past: the same edge the window takes, and
    /// the one a task due this very second takes in `isHiddenAnnouncementTask`.
    /// An `event` or `task` with no `until` is not over by date (nothing says
    /// when), and an `event` with none gets no exemption from the all-done
    /// clause (nothing says it is still ahead).
    ///
    /// An Ed **staff post** is outside both halves above: it is shown only if
    /// it is an `event` whose `until` is not yet past, or a `task` whose `until`
    /// is not yet past or with a find still to do
    /// (`announcementStaffPostMatters`), and otherwise not at all.
    ///
    /// With no judgment stored, only the all-done clause can take a post out,
    /// so the rule degrades to the standing set plus finished-work removal and
    /// never to something worse than the sheet before this rule existed. The
    /// wrong version is deciding "no judgment" means "over": a school or an
    /// offline phone would then lose its whole list.
    ///
    /// Pure and `nonisolated`, like the window it builds on, so tests call it
    /// with plain closures (CLAUDE.md's `decidedText` trap).
    nonisolated static func announcementRecordsForSheet(
        _ records: [AnnouncementRecord],
        now: Date,
        relevance: (AnnouncementRecord) -> AnnouncementRelevance?,
        findState: (AnnouncementRecord) -> AnnouncementFindState
    ) -> [AnnouncementRecord] {
        let standing = announcementRecordsInSheetWindow(records, now: now)
        let standingKeys = Set(standing.map(AnnouncementReadState.key(for:)))
        return records
            .filter { record in
                let judged = relevance(record)
                let state = findState(record)
                if record.isStaffPost {
                    return announcementStaffPostMatters(judged, findState: state, now: now)
                }
                if standingKeys.contains(AnnouncementReadState.key(for: record)) {
                    return !announcementIsOver(judged, findState: state, now: now)
                }
                return announcementStillMatters(judged, findState: state, now: now)
            }
            .sorted(by: AnnouncementRecord.isNewer(_:than:))
    }

    /// The "unless it is over" half of `announcementRecordsForSheet`, for a post
    /// in the standing set.
    nonisolated static func announcementIsOver(
        _ judged: AnnouncementRelevance?,
        findState: AnnouncementFindState,
        now: Date
    ) -> Bool {
        if let judged, judged.kind == .event, let until = judged.until, until < now {
            return true
        }
        if findState == .allDone {
            var outlivesItsTasks = false
            switch judged?.kind {
            case .standing:
                outlivesItsTasks = true
            case .event:
                if let until = judged?.until { outlivesItsTasks = until >= now }
            case .task, .news, nil:
                break
            }
            if !outlivesItsTasks { return true }
        }
        if let judged, judged.kind == .task, let until = judged.until, until < now, findState != .open {
            return true
        }
        return false
    }

    /// The "only if it still matters" half of `announcementRecordsForSheet`, for
    /// a post older than the window that is not its class's newest.
    nonisolated static func announcementStillMatters(
        _ judged: AnnouncementRelevance?,
        findState: AnnouncementFindState,
        now: Date
    ) -> Bool {
        switch judged?.kind {
        case .standing:
            return true
        case .event:
            if let until = judged?.until { return until >= now }
            return false
        case .task:
            return findState == .open
        case .news, nil:
            return false
        }
    }

    /// Whether an Ed staff post is worth listing: an `event` whose `until` is
    /// not past, or a `task` whose `until` is not past or with a find still to
    /// do. `standing` is not enough (a staff post is rarely a resource the class
    /// was pointed to, and listing them all is the Ed board), `news` is never
    /// enough, and a post with no judgment is not listed: nothing says it
    /// matters.
    ///
    /// The date clause for a `task` is what makes a staff post listable at all:
    /// the Ed pass reads a staff post for its judgment only and discards its
    /// tasks, so no find ever comes from one and "a find is still open" alone
    /// would never be true. The find clause stays for a row that has some
    /// (a ledger written by another build). A task with no `until` and no open
    /// find is not listed: nothing says when it ends, and an undated staff post
    /// is the Ed board again.
    nonisolated static func announcementStaffPostMatters(
        _ judged: AnnouncementRelevance?,
        findState: AnnouncementFindState,
        now: Date
    ) -> Bool {
        switch judged?.kind {
        case .event:
            if let until = judged?.until { return until >= now }
            return false
        case .task:
            if let until = judged?.until, until >= now { return true }
            return findState == .open
        case .standing, .news, nil:
            return false
        }
    }

    /// Where each post's finds stand, by the post's read-state key
    /// (`AnnouncementReadState.key(for:)`): `finds` is every find on the ledger,
    /// finished ones included, and `isDone` says whether one is finished or
    /// past. A post any of whose finds is not done is `.open`, whatever the
    /// rest say; a post whose finds are all done is `.allDone`; a post with no
    /// entry has none. A find whose `sourceID` is not a Canvas or an Ed find
    /// (the syllabus's exams, which no post carries) belongs to no post and is
    /// skipped.
    nonisolated static func announcementFindStates(
        _ finds: [Assignment],
        isDone: (Assignment) -> Bool
    ) -> [String: AnnouncementFindState] {
        var states: [String: AnnouncementFindState] = [:]
        for find in finds {
            guard let key = announcementPostKey(forFindSourceID: find.sourceID) else { continue }
            if isDone(find) {
                if states[key] == nil { states[key] = .allDone }
            } else {
                states[key] = .open
            }
        }
        return states
    }

    /// The read-state key of the post a find came from: `recordKey` of the
    /// Canvas announcement id, or `edKey` of the Ed document id (the `id` of the
    /// Ed row the sheet lists), nil for any other `sourceID`.
    nonisolated static func announcementPostKey(forFindSourceID sourceID: String) -> String? {
        if let id = AnnouncementRecord.announcementID(fromFindSourceID: sourceID) {
            return AnnouncementReadState.recordKey(id)
        }
        if let documentID = AnnouncementRecord.edDocumentID(fromFindSourceID: sourceID) {
            return AnnouncementReadState.edKey(documentID)
        }
        return nil
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

    /// Where each post's finds stand as of `now` (`announcementFindStates`),
    /// over every find on the ledger and not only the page's, because the page
    /// has already dropped the finished ones and "all done" is exactly what
    /// has to be told apart from "nothing found".
    ///
    /// A find is done when the student finished it (`isCompleted`), when its
    /// real twin is finished (`announcementFindsWithFinishedTwinIDs`, the set
    /// the last rebuild computed, so the sheet and the dashboard agree what a
    /// twin is: the owner's "combined worksheet 6-7" find is done once Canvas's
    /// `CombinedWorksheets6-7` is turned in), or when the dashboard's own rule
    /// puts it away as past (`isHiddenAnnouncementTask`, asked the way
    /// `announcementFoundItems` asks it, of the date the card shows).
    func announcementFindStates(now: Date = Date()) -> [String: AnnouncementFindState] {
        let finds = announcementItems
        guard !finds.isEmpty else { return [:] }
        let postDates = announcementPostDates(for: finds)
        return Self.announcementFindStates(finds) { find in
            isCompleted(find)
                || announcementFindsWithFinishedTwinIDs.contains(find.id)
                || Self.isHiddenAnnouncementTask(
                    find, dueAt: effectiveDueDate(for: find), postedAt: postDates.postedAt(for: find),
                    firstSeenAt: postDates.firstSeenAt(for: find), now: now
                )
        }
    }

    /// The posts the sheet lists as of `now`: `announcementRecordsOnPage`
    /// (Canvas log and Ed rows, classes still selected) through the keep-check
    /// (`announcementRecordsForSheet`: the 7-day window plus each class's
    /// newest post, less what is over, plus what still matters). The badge
    /// counts these same records (`announcementBadgeCount`), so it follows the
    /// rule without a rule of its own.
    func announcementSheetRecords(now: Date = Date()) -> [AnnouncementRecord] {
        // The badge asks this on every refresh; with no posts there is nothing
        // to judge, so the finds are not walked for nothing.
        guard !announcementRecordsOnPage.isEmpty else { return [] }
        let states = announcementFindStates(now: now)
        return Self.announcementRecordsForSheet(
            announcementRecordsOnPage,
            now: now,
            relevance: { announcementRelevance[AnnouncementReadState.key(for: $0)] },
            findState: { states[AnnouncementReadState.key(for: $0)] ?? .none }
        )
    }
}
