import Foundation
import LowHangingFruitKit

// What the megaphone sheet shows, and so what its badge may count. This file is
// the one place that says which rows belong where:
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
// - **Announcements**: every Canvas announcement and Ed post the phone keeps
//   (`announcementSheetRecords`), newest first, with no window and no
//   staff-post hiding. Owner's call, 2026-11-07, after seeing a nearly empty
//   sheet: list everything, and let the todo / prev split
//   (`announcementSheetSplit`) say which posts still apply.
//
// The badge counts unread finds plus unread posts in **todo** only
// (`announcementBadgeRecords`), through the same split the view draws, so it
// can never count something the student cannot find and does not read "99+"
// because 60 days of history became visible. Everything here is read-only: it
// neither creates nor removes a ledger row, and it leaves the dashboard's own
// placement and visibility rules alone.

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

/// The sheet's two views, switched by the same capsule switch the dashboard
/// uses for todo · all · prev (`SmoothSegmentPicker`). Owner's call,
/// 2026-11-06: the sheet learns the dashboard's controls instead of its own;
/// 2026-11-07: and uses the dashboard's own words, todo and prev.
enum AnnouncementSheetView: String, CaseIterable, Identifiable {
    case todo
    case prev

    var id: String { rawValue }

    var label: String {
        switch self {
        case .todo: return "todo"
        case .prev: return "prev"
        }
    }
}

extension AppState {
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

    /// A predicate for "does a row of this class survive the selection", with
    /// the selected classes turned into course identities once and each row's
    /// course string parsed once: a log of 60 days holds hundreds of rows for a
    /// handful of classes, and this runs on every redraw.
    ///
    /// Compared by course identity (`announcementCourseIdentity`) and not byte
    /// for byte: an announcement row can carry the raw Canvas descriptor where
    /// the bubble holds the cleaned code, and `PHYS 0151` is `PHYS 151`
    /// (`announcementCoursesMatch`, which the duplicate checks use for the same
    /// reason). The dashboard's own filter compares `course` exactly because
    /// its rows all come through one cleaned pool; this list does not. An empty
    /// selection keeps everything.
    nonisolated private static func announcementSheetCourseFilter(
        _ selection: Set<String>
    ) -> (String) -> Bool {
        guard !selection.isEmpty else { return { _ in true } }
        let wanted = Set(selection.map(announcementCourseIdentity))
        var identities: [String: String] = [:]
        return { course in
            if let known = identities[course] { return wanted.contains(known) }
            let identity = announcementCourseIdentity(course)
            identities[course] = identity
            return wanted.contains(identity)
        }
    }

    /// Whether a row of class `course` survives the sheet's class selection
    /// (empty: all of them).
    nonisolated static func announcementSheetCourseMatches(_ course: String, selection: Set<String>) -> Bool {
        announcementSheetCourseFilter(selection)(course)
    }

    /// The same for one class or none (`filter`, nil for all classes). Kept for
    /// callers that think in one class; it is the selection of one.
    nonisolated static func announcementSheetCourseMatches(_ course: String, filter: String?) -> Bool {
        announcementSheetCourseMatches(course, selection: filter.map { [$0] } ?? [])
    }

    /// The found cards of the selected classes (all of them for an empty
    /// selection), order kept. The sheet's class filter narrows both lists
    /// through these functions, so a test of them is a test of what the sheet
    /// draws.
    nonisolated static func announcementSheetNarrowed(_ cards: [DashItem], toCourses selection: Set<String>) -> [DashItem] {
        let keeps = announcementSheetCourseFilter(selection)
        return cards.filter { keeps($0.assignment.course) }
    }

    /// The posts of the selected classes (all of them for an empty selection),
    /// order kept.
    nonisolated static func announcementSheetNarrowed(
        _ records: [AnnouncementRecord],
        toCourses selection: Set<String>
    ) -> [AnnouncementRecord] {
        let keeps = announcementSheetCourseFilter(selection)
        return records.filter { keeps($0.courseCode) }
    }

    nonisolated static func announcementSheetNarrowed(_ cards: [DashItem], toCourse course: String?) -> [DashItem] {
        announcementSheetNarrowed(cards, toCourses: course.map { [$0] } ?? [])
    }

    nonisolated static func announcementSheetNarrowed(
        _ records: [AnnouncementRecord],
        toCourse course: String?
    ) -> [AnnouncementRecord] {
        announcementSheetNarrowed(records, toCourses: course.map { [$0] } ?? [])
    }

    // MARK: The sheet's two views

    /// Splits the sheet's posts into **todo** and **prev**. A post is todo
    /// when any of these holds, else prev:
    ///
    /// 1. a find from this post is still open (`findStates`, keyed the way
    ///    `announcementFindStates` keys them, `AnnouncementReadState.key(for:)`);
    /// 2. a fact the server read out of this document is still live: not
    ///    rejected by the student, of type `new_task`, `reschedule`, `cancel`
    ///    or `scope_change`, and with no date or a date not yet past;
    /// 3. the post's stored judgment (`relevance`, the server's
    ///    `AnnouncementRelevance`, keyed like `findStates`) is an `event` or a
    ///    `task` whose `until` is absent or not yet past;
    /// 4. the post is newer than `graceWindow` (`sortDate`).
    ///
    /// The owner's words (2026-11-07): "prev being either from way before or
    /// unapplicable", sorted "based on text". The sheet lists every post the
    /// phone keeps (`announcementSheetRecords`) and this is the only thing
    /// that decides which view a post is in. There is no window any more: the
    /// old 7-day window existed because the sheet was one list and had to
    /// drop something; a sheet with a prev view has no reason to drop what the
    /// phone holds, only to sort it. On 2026-11-07 the newest Canvas post was
    /// 11 days old, the window kept two posts, and 45 Ed posts were hidden.
    ///
    /// Why 3 days of grace (4): it only has to cover the gap between a post
    /// appearing and the student seeing it, before the model has read it. At
    /// 7 days a week of office-hour notes sat in todo. The model's document
    /// verdict (ROADMAP -> Next) replaces (4) when it exists. The wrong fix is
    /// a longer window: it hides history instead of sorting it, and a
    /// date-only split would put a still-open "bring X on Nov 20" post into
    /// prev the day it turned a few days old.
    ///
    /// An Ed staff post is treated like any other post here.
    ///
    /// Both lists keep the order of `records`, which is newest first.
    ///
    /// Id shapes, checked against the code: a fact's `documentID` is the
    /// `CourseDocument.id`, `"<kind>:<courseID>:<sourceID>"`. An Ed record's id
    /// is that same string (`ed:<course>:<thread>`); a Canvas record's id is the
    /// bare announcement id (the document's `sourceID`), so its document id is
    /// `"announcement:" + courseID + ":" + id`.
    nonisolated static func announcementSheetSplit(
        records: [AnnouncementRecord],
        facts: [AppliedFact],
        findStates: [String: AnnouncementFindState],
        relevance: (AnnouncementRecord) -> AnnouncementRelevance?,
        now: Date,
        graceWindow: TimeInterval = 3 * 86_400
    ) -> (todo: [AnnouncementRecord], prev: [AnnouncementRecord]) {
        var liveDocuments = Set<String>()
        for fact in facts where fact.studentOverride != .rejected {
            switch fact.type {
            case .newTask, .reschedule, .cancel, .scopeChange:
                if let due = fact.dueAt, due < now { continue }
                liveDocuments.insert(fact.documentID)
            case .note, .needsReview:
                continue
            }
        }
        var todo: [AnnouncementRecord] = []
        var prev: [AnnouncementRecord] = []
        for record in records {
            let documentID = record.isEd ? record.id : "announcement:\(record.courseID):\(record.id)"
            var judgedLive = false
            if let judged = relevance(record), judged.kind == .event || judged.kind == .task {
                judgedLive = judged.until.map { $0 >= now } ?? true
            }
            let isTodo = findStates[AnnouncementReadState.key(for: record)] == .open
                || liveDocuments.contains(documentID)
                || judgedLive
                || record.sortDate > now.addingTimeInterval(-graceWindow)
            if isTodo { todo.append(record) } else { prev.append(record) }
        }
        return (todo, prev)
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

    /// The posts the sheet lists as of `now`: all of `announcementRecordsOnPage`
    /// (Canvas log and Ed rows, classes still selected), newest first, with no
    /// window and no staff-post hiding. Which view a post is in is
    /// `announcementSheetSplit`'s business alone.
    func announcementSheetRecords(now: Date = Date()) -> [AnnouncementRecord] {
        announcementRecordsOnPage.sorted(by: AnnouncementRecord.isNewer(_:than:))
    }

    /// The sheet's todo and prev lists as of `now`, the one split the view
    /// draws and the badge counts.
    func announcementSheetSplit(now: Date = Date()) -> (todo: [AnnouncementRecord], prev: [AnnouncementRecord]) {
        let records = announcementSheetRecords(now: now)
        guard !records.isEmpty else { return ([], []) }
        return Self.announcementSheetSplit(
            records: records,
            facts: currentAppliedFacts(),
            findStates: announcementFindStates(now: now),
            relevance: { announcementRelevance[AnnouncementReadState.key(for: $0)] },
            now: now
        )
    }

    /// The posts the megaphone badge counts: todo only. History being visible
    /// (60 days of it) must not push the badge to "99+".
    func announcementBadgeRecords(now: Date = Date()) -> [AnnouncementRecord] {
        announcementSheetSplit(now: now).todo
    }
}
