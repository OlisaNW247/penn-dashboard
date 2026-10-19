import Combine
import Foundation
import LowHangingFruitKit

// The megaphone sheet's "all announcements" list.
//
// The megaphone used to open a list of *tasks* the announcement extractor had
// pulled out of Canvas posts, and hid itself when there were none. The
// extractor is strict, finds expire, and only 14 days were ever fetched, so
// students saw an empty sheet or no button and concluded announcements
// "aren't there". `syncAnnouncements()` now also writes every announcement it
// fetches into `AnnouncementLogStore`, and the sheet lists those under the
// finds.
//
// Ed Discussion announcements and pinned posts are listed too. They are not
// fetched here: Ed is already read into `courseKnowledge` by the course-material
// sync, and this file only reads that (`AnnouncementRecord.edRecords`), merging
// the rows at display time and never into the log file.
//
// Nothing here talks to a server. The log is read from and written to one
// file on the phone, it is cleared when Canvas is disconnected, and nothing
// reads it to build a request (`AnnouncementLogSyncTests` pins that the
// extraction path sees exactly the announcements it saw before the log
// existed).

/// The on-disk log and the read state that goes with it. One optional value
/// rather than two so "the feature is off" is a single check: nil under the
/// test runner, where an `AppState` must not touch the real Application
/// Support directory or the shared defaults domain.
struct AnnouncementLogContext {
    var store: AnnouncementLogStore
    var readState: AnnouncementReadState

    /// The shipping wiring: the real file beside the course-knowledge cache,
    /// and `UserDefaults.lhf` for the seen ids.
    static func live() -> AnnouncementLogContext {
        AnnouncementLogContext(store: .default(), readState: AnnouncementReadState())
    }
}

extension AppState {
    /// What `syncAnnouncements()` calls to get announcements. The shipping
    /// path builds a `CanvasAnnouncementsClient`; a test supplies this
    /// instead so the sync runs end to end with no network and no Canvas
    /// session.
    typealias AnnouncementFetch = @MainActor (_ courseIDs: [String], _ since: Date, _ until: Date) async throws -> [CanvasAnnouncement]

    /// The window `syncAnnouncements()` asks Canvas for: `retention` days back
    /// through one day after `now`. The end is not optional. Canvas defaults
    /// `end_date` to 28 days after `start_date`, which at a 60-day start means
    /// "60 to 32 days ago" and hides every recent post (see the comment in
    /// `syncAnnouncements`). The extra day covers clock skew between the
    /// phone and Canvas, and a post stamped later today in another time zone.
    nonisolated static func announcementFetchWindow(now: Date) -> (since: Date, until: Date) {
        (
            since: now.addingTimeInterval(-AnnouncementLogStore.retention),
            until: now.addingTimeInterval(24 * 60 * 60)
        )
    }

    /// Announcements posted within this long are the only ones the
    /// extraction pipeline (informational gate, heuristic extractor, AI
    /// assist) ever sees. This is the window the watcher always had; the
    /// fetch is wider now (`AnnouncementLogStore.retention`) purely to fill
    /// the log, and widening it must not send one extra announcement to the
    /// backend or create one extra ledger row.
    nonisolated static let announcementExtractionWindow: TimeInterval = 14 * 24 * 60 * 60

    /// The subset of a fetch that goes on to extraction: posted inside
    /// `announcementExtractionWindow` as of `now`. An undated announcement
    /// stays in: the 14-day fetch returned whatever Canvas considered
    /// current, undated or not, and all of it was processed, so dropping it
    /// now would change what extraction sees.
    nonisolated static func announcementsEligibleForExtraction(
        _ fetched: [CanvasAnnouncement],
        now: Date
    ) -> [CanvasAnnouncement] {
        let cutoff = now.addingTimeInterval(-announcementExtractionWindow)
        return fetched.filter { announcement in
            guard let postedAt = announcement.postedAt else { return true }
            return postedAt >= cutoff
        }
    }

    /// The Ed Discussion posts the Announcement Watcher reads, in the one shape
    /// its loop already takes: a `CanvasAnnouncement`.
    ///
    /// **Why a `CanvasAnnouncement` and not a new source type.** The loop in
    /// `syncAnnouncements`, its test seams, `announcementAssignments` and the
    /// ledger rows it mints (`Assignment.Source.canvasAnnouncement`) read
    /// five fields, and an Ed post has all five. A new `Assignment.Source`
    /// would ripple through the ledger, the dedup and the placement code,
    /// which all key on `.canvasAnnouncement`, for a difference nothing
    /// downstream cares about; a second copy of the gate-and-extract loop
    /// would drift from the first. The rejected fixes are both.
    ///
    /// **The id is the document's own id**, `ed:{canvasCourse}:{thread}`, the
    /// same string the "all announcements" list uses for the row
    /// (`AnnouncementRecord.edRecord`). That is what makes the sheet's "task
    /// found" tag join (`announcementID(fromFindSourceID:)` against the row's
    /// id) work for Ed, and the course in it keeps one thread cross-listed to
    /// two Canvas classes from being one dedup key. It cannot collide with a
    /// Canvas id, which is decimal digits.
    ///
    /// **Which posts.** The ones the list already keeps (an announcement or a
    /// pinned post with text in it) plus a staff post, so a TA's "HW3 moved
    /// to Monday" is read. Student, private and question threads are never
    /// documents at all (`EdThreadFilter`), and a document whose header says
    /// anything else, or has no header, is left alone here too: the whitelist
    /// is the second lock, not the only one. Nothing leaves the phone that
    /// the pooled copy has not already put on the server.
    ///
    /// **Header never reaches a gate.** `title` is the thread title and
    /// `message` is `EdDocumentHeader.body`, never the raw `text`: its first
    /// line, `[ed · pinned] Homework / Hw 3 · posted 2026-10-12`, would be
    /// scored by the informational and task gates as if the poster had
    /// written it.
    ///
    /// **Dated or not at all.** The date is the posting day from the header,
    /// else the document's `updatedAt` (Ed's last-activity time, only a
    /// fallback for a document synced before the token existed). Canvas
    /// leaves an undated announcement in the window because its fetch already
    /// was one; an Ed document has no such fetch, so an undated one is
    /// dropped rather than extracted on every sync's say-so. Ed's `url` is the
    /// thread's page, so "open" on a find lands on Ed.
    nonisolated static func edAnnouncementsForExtraction(
        from documents: [CourseDocument]
    ) -> [CanvasAnnouncement] {
        var seen = Set<String>()
        var result: [CanvasAnnouncement] = []
        for document in documents where document.kind == .ed {
            let header = EdDocumentHeader.parse(document.text)
            guard header.isAnnouncementOrPinned || header.isStaffPost,
                  !EdDocumentHeader.carriesNoText(document.text),
                  let postedAt = header.postedAt ?? document.updatedAt,
                  seen.insert(document.id).inserted
            else { continue }
            result.append(CanvasAnnouncement(
                id: document.id,
                courseID: document.courseID,
                title: document.title,
                message: header.body,
                postedAt: postedAt,
                url: document.url
            ))
        }
        return result
    }

    /// Drops an Ed find that restates a find already made, from Canvas this
    /// run or an earlier one. `filteringAnnouncementDuplicates` compares a
    /// find with the dashboard's *coursework*; nothing compared two
    /// announcement finds with each other, because one Canvas post is
    /// extracted once. An Ed post and a Canvas announcement saying the same
    /// thing ("Verbal Assessment #2 sign-ups open") are two posts, so
    /// without this the sheet would list the task twice.
    ///
    /// Candidate by candidate, not as a batch: the pool grows with the
    /// survivors of earlier posts but not of this one, so two genuinely
    /// separate tasks in one post are never collapsed into each other (the
    /// Canvas path never does that either). A pool entry with the
    /// candidate's own id is skipped, so a post re-extracted after the
    /// processed set was lost does not suppress itself. The pool is whatever
    /// the caller has built or stored first, so Canvas, extracted earlier in
    /// the loop, wins over Ed.
    static func droppingAnnouncementTwins(
        _ candidates: [Assignment],
        against pool: [Assignment]
    ) -> [Assignment] {
        candidates.filter { candidate in
            !filteringAnnouncementDuplicates(
                [candidate],
                against: pool.filter { $0.id != candidate.id }
            ).isEmpty
        }
    }

    /// The records the sheet lists (`nonisolated`: a pure rule that tests and
    /// non-UI callers reach without the main actor, CLAUDE.md's `decidedText`
    /// trap): those of classes that are still selected
    /// (neither hidden nor deleted: `isCourseSelected`, the rule the finds
    /// use), newest first.
    nonisolated static func announcementRecordsForPage(
        _ records: [AnnouncementRecord],
        isCourseSelected: (String) -> Bool
    ) -> [AnnouncementRecord] {
        records
            .filter { isCourseSelected($0.courseCode) }
            .sorted(by: AnnouncementRecord.isNewer(_:than:))
    }

    // MARK: Test seam

    /// Per-instance seam: back this `AppState`'s announcement log with a
    /// scratch directory and scratch defaults. Without it, under the test
    /// runner, `announcementLog` is nil, so no `AppState` ever reads or
    /// writes the real Application Support file or the shared seen-ids key
    /// that every concurrently running suite's `AppState.init` could read
    /// (the shared-defaults trap in CLAUDE.md). Refuses the shared domain.
    func enableAnnouncementLogForTesting(directory: URL, defaults: UserDefaults) {
        precondition(
            defaults !== UserDefaults.lhf,
            "enableAnnouncementLogForTesting needs a scratch UserDefaults suite, not the shared domain"
        )
        announcementLog = AnnouncementLogContext(
            store: AnnouncementLogStore(directory: directory),
            readState: AnnouncementReadState(defaults: defaults)
        )
        loadAnnouncementLog()
    }

    // MARK: Loading and display

    /// Reads the log and the seen ids from disk. Called once from `init`,
    /// before the first rebuild, so the megaphone is right on the first frame.
    func loadAnnouncementLog(now: Date = Date()) {
        guard let log = announcementLog else {
            announcementLogRecords = []
            edAnnouncementRecords = []
            announcementSeenIDs = []
            refreshAnnouncementRecordsOnPage()
            return
        }
        announcementLogRecords = log.store.load(now: now)
        announcementSeenIDs = log.readState.seenIDs
        observeKnowledgeForAnnouncements()
        refreshEdAnnouncementRecords(from: courseKnowledge, now: now)
    }

    // MARK: Ed Discussion rows

    /// Subscribes, once, to `courseKnowledge`, so the list follows a knowledge
    /// sync without a single call being added to the sync. `@Published`
    /// delivers the *new* value (it fires before the property changes), so the
    /// handler reads the value it is given and never `self.courseKnowledge`,
    /// which still holds the old one at that moment. `dropFirst` skips the
    /// current value the subscription replays; `loadAnnouncementLog` has
    /// already used it.
    func observeKnowledgeForAnnouncements() {
        guard announcementKnowledgeSubscription == nil else { return }
        announcementKnowledgeSubscription = $courseKnowledge
            .dropFirst()
            .sink { [weak self] knowledge in
                // `courseKnowledge` is only ever set on the main actor, so
                // this runs there already; the assertion states it.
                MainActor.assumeIsolated {
                    self?.refreshEdAnnouncementRecords(from: knowledge, now: Date())
                }
            }
    }

    /// Recomputes the Ed rows from `knowledge` and the list from them. Off
    /// entirely when the announcement log is (the test-runner default), so an
    /// `AppState` that did not opt in lists nothing and writes nothing.
    func refreshEdAnnouncementRecords(from knowledge: CourseKnowledgeBase, now: Date) {
        let next = announcementLog == nil
            ? []
            : AnnouncementRecord.edRecords(from: knowledge.documents, now: now)
        if next != edAnnouncementRecords { edAnnouncementRecords = next }
        seedEdAnnouncementsIfNeeded()
        refreshAnnouncementRecordsOnPage()
    }

    /// The first time Ed rows exist on this install, they count as already
    /// seen, so the badge does not jump to the whole backlog the day they
    /// first appear. Tracked by its own flag (`edSeeded`), not by the Canvas
    /// log's first fill: an install that filled its Canvas log long ago must
    /// still get this once. Set only when there is something to mark, so a
    /// class whose Ed posts arrive in a later sync is seeded then and not at
    /// launch with nothing to see. Later Ed rows are unread.
    private func seedEdAnnouncementsIfNeeded() {
        guard let log = announcementLog,
              !isUsingFixtureData,
              !edAnnouncementRecords.isEmpty,
              !log.readState.edSeeded
        else { return }
        // A plain union, not `markSeen(_:keepingOnly:)`: this can run at
        // launch, before the first rebuild has loaded the finds, and pruning
        // to "what is on the page" then would forget finds already seen.
        log.readState.markSeen(Set(edAnnouncementRecords.map(AnnouncementReadState.key(for:))))
        log.readState.markEdSeeded()
        announcementSeenIDs = log.readState.seenIDs
    }

    /// The seen-set key of every row that could still be listed: all of
    /// `canvas` (the stored log, hidden classes included) and all Ed rows.
    /// This is what bounds the persisted set.
    private func knownAnnouncementKeys(canvas: [AnnouncementRecord]) -> Set<String> {
        Set((canvas + edAnnouncementRecords).map(AnnouncementReadState.key(for:)))
    }

    /// Recomputes the sheet's list from the stored records and the current
    /// class selection. Runs on every dashboard rebuild (hiding or deleting a
    /// class goes through one) and after every log write. Empty in preview
    /// and demo mode: there is no real Canvas behind it, and a developer's
    /// real log must not appear in a screenshot of sample data.
    func refreshAnnouncementRecordsOnPage() {
        let next: [AnnouncementRecord]
        if isUsingFixtureData {
            next = []
        } else {
            // Canvas log and Ed rows are merged here, at display time, and
            // only here: the log file stays Canvas-only.
            next = Self.announcementRecordsForPage(
                announcementLogRecords + edAnnouncementRecords,
                isCourseSelected: { self.isCourseSelected($0) }
            )
        }
        // Only when it changed: this runs on every dashboard rebuild, which a
        // completion toggle triggers, and republishing an unchanged array
        // would redraw every view observing `AppState` for nothing.
        if next != announcementRecordsOnPage { announcementRecordsOnPage = next }
    }

    // MARK: Recording

    /// Writes everything one fetch returned into the log. Called by
    /// `syncAnnouncements()` before any extraction gate, so a post the
    /// informational gate would discard, or one too old for extraction, is
    /// still listed.
    ///
    /// **The first fill is not "new".** When the log has never been filled on
    /// this install (no file, or an unreadable one) every record in this
    /// fetch is marked seen, so the badge does not jump to dozens the day the
    /// feature arrives, or after a reconnect. Anything that arrives later is
    /// unread. The file's existence is the "filled once" flag: an empty first
    /// fill still writes it. The wrong version is a separate persisted flag,
    /// which can disagree with the file (a flag set, the file gone, the badge
    /// silently never counting again).
    ///
    /// A failed write changes nothing, in memory either: a log that cannot be
    /// saved would otherwise look "unfilled" on every sync and mark every
    /// new post seen.
    func recordFetchedAnnouncements(
        _ fetched: [CanvasAnnouncement],
        courseCodesByID: [String: String],
        now: Date
    ) {
        guard let log = announcementLog else { return }

        let incoming: [AnnouncementRecord] = fetched.compactMap { announcement in
            // A course the id -> code map does not know yet has no code to
            // list it under; the next sync gets another chance, as the
            // extraction loop's own unmapped-course branch does.
            guard let code = courseCodesByID[announcement.courseID] else { return nil }
            return AnnouncementRecord(announcement: announcement, courseCode: code, recordedAt: now)
        }

        let previous = log.store.loadIfPresent(now: now)
        let merged = AnnouncementLogStore.merged(existing: previous ?? [], incoming: incoming, now: now)

        let kept: [AnnouncementRecord]
        if let previous, previous == merged {
            kept = previous
        } else {
            guard let written = try? log.store.save(merged, now: now) else { return }
            kept = written
        }

        if previous == nil {
            let incomingKeys = Set(incoming.map { AnnouncementReadState.recordKey($0.id) })
            let pageKeys = Set(announcementPageItems.map(\.id))
                .union(knownAnnouncementKeys(canvas: kept))
            log.readState.markSeen(incomingKeys, keepingOnly: pageKeys)
        }
        announcementSeenIDs = log.readState.seenIDs
        announcementLogRecords = kept
        refreshAnnouncementRecordsOnPage()
    }

    // MARK: Megaphone

    /// The megaphone's badge: unread finds plus unread records.
    var unreadAnnouncementCount: Int {
        AnnouncementReadState.unreadCount(
            finds: announcementPageItems,
            records: announcementRecordsOnPage,
            seen: announcementSeenIDs
        )
    }

    /// Whether the dashboard shows the megaphone at all.
    var showsAnnouncementsButton: Bool {
        AnnouncementReadState.megaphoneVisible(
            finds: announcementPageItems,
            records: announcementRecordsOnPage
        )
    }

    /// Called when the sheet opens. Returns the ids that were unread at that
    /// moment (a find's `Assignment.id`, a record's `recordKey`) so rows can
    /// still say NEW after opening has marked everything seen.
    func openAnnouncementsSheet() -> Set<String> {
        let newIDs = AnnouncementReadState.newIDs(
            finds: announcementPageItems,
            records: announcementRecordsOnPage,
            seen: announcementSeenIDs
        )
        // Rows of a hidden class are not on the page but are still known, so
        // their already-seen state survives the class being shown again.
        let known = knownAnnouncementKeys(canvas: announcementLogRecords)
        if let log = announcementLog {
            log.readState.markAllSeen(announcementPageItems, records: announcementRecordsOnPage, keeping: known)
            announcementSeenIDs = log.readState.seenIDs
        } else {
            announcementSeenIDs = Set(announcementPageItems.map(\.id))
                .union(announcementRecordsOnPage.map(AnnouncementReadState.key(for:)))
                .union(announcementSeenIDs.intersection(known))
        }
        return newIDs
    }

    // MARK: Clearing

    /// Forgets the log: the file, the in-memory copy, and the seen ids that
    /// pointed at it. Canvas-derived text, so it goes when Canvas is
    /// disconnected (`disconnectCanvas`) and with the rest of the on-device
    /// course cache (`clearCourseKnowledge`).
    ///
    /// Ed rows are derived from the course knowledge, which this does not
    /// touch, so they stay listed; their seen state is forgotten with the
    /// rest and re-seeded straight away, so clearing the log does not make
    /// every Ed post unread.
    func clearAnnouncementLog() {
        announcementLog?.store.clear()
        announcementLog?.readState.forgetRecords()
        announcementLogRecords = []
        announcementSeenIDs = announcementSeenIDs.filter {
            !AnnouncementReadState.isRecordKey($0) && !AnnouncementReadState.isEdKey($0)
        }
        seedEdAnnouncementsIfNeeded()
        refreshAnnouncementRecordsOnPage()
    }
}
