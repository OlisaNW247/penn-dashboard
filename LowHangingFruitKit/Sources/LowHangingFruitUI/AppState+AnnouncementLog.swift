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
    typealias AnnouncementFetch = @MainActor (_ courseIDs: [String], _ since: Date) async throws -> [CanvasAnnouncement]

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
            announcementSeenIDs = []
            refreshAnnouncementRecordsOnPage()
            return
        }
        announcementLogRecords = log.store.load(now: now)
        announcementSeenIDs = log.readState.seenIDs
        refreshAnnouncementRecordsOnPage()
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
            next = Self.announcementRecordsForPage(
                announcementLogRecords,
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
                .union(kept.map { AnnouncementReadState.recordKey($0.id) })
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
        if let log = announcementLog {
            log.readState.markAllSeen(announcementPageItems, records: announcementRecordsOnPage)
            announcementSeenIDs = log.readState.seenIDs
        } else {
            announcementSeenIDs = Set(announcementPageItems.map(\.id))
                .union(announcementRecordsOnPage.map { AnnouncementReadState.recordKey($0.id) })
        }
        return newIDs
    }

    // MARK: Clearing

    /// Forgets the log: the file, the in-memory copy, and the seen ids that
    /// pointed at it. Canvas-derived text, so it goes when Canvas is
    /// disconnected (`disconnectCanvas`) and with the rest of the on-device
    /// course cache (`clearCourseKnowledge`).
    func clearAnnouncementLog() {
        announcementLog?.store.clear()
        announcementLog?.readState.forgetRecords()
        announcementLogRecords = []
        announcementRecordsOnPage = []
        announcementSeenIDs = announcementSeenIDs.filter { !AnnouncementReadState.isRecordKey($0) }
    }
}
