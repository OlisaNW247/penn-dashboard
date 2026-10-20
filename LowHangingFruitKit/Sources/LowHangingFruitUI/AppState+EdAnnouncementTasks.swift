import Combine
import Foundation
import LowHangingFruitKit

// MARK: – Tasks found in Ed Discussion posts
//
// Canvas announcements have been read for tasks since the Announcement Watcher
// (`syncAnnouncements()`): a post that says "submit the form by Friday" becomes
// a ledger row and, since 2026-10-18, a card on the dashboard. Ed Discussion
// posts are course material of the same kind (an instructor addressing the
// class), and they already sit on the phone: the course-material sync reads Ed
// and keeps announcements, pinned threads and staff posts as `.ed`
// `CourseDocument`s in `courseKnowledge`. Nothing read those for tasks, so a
// class that announced everything on Ed showed an empty dashboard.
//
// This pass reads them, once each, with the same extractors, the same
// informational gate and the same switches as the Canvas path:
//
//  - **Which posts.** Ed announcements and pinned threads that carry text
//    (`EdDocumentHeader.isAnnouncementOrPinned`, `carriesNoText`): exactly the
//    posts the megaphone lists, not every staff post. A plain staff post is
//    course material the filter keeps, usually an answer to a question, and
//    "you can submit by Friday" in a reply is not a task the class was given.
//    Only posts dated within the past 14 days, the window a Canvas post gets
//    (`announcementExtractionWindow`), and a post with no date is skipped: a
//    post that cannot be placed in time cannot be shown to be inside the
//    window. The date is `edPostDate`: the posting day the document's header
//    names (`CourseDocument.shownPostedAt`), else the thread's last *activity*
//    (`updatedAt`), which is what a document synced before the header carried
//    the day still has, and which reads an old thread somebody replied to
//    yesterday as yesterday's. What the window cannot catch, the dashboard's
//    own rules do afterwards: a task whose date has passed, or an undated one
//    a week after its post, is not shown (`isHiddenAnnouncementTask`).
//  - **Which classes.** Ones the student has not hidden or deleted. A post of a
//    hidden class is left unread and picked up when the class is shown again,
//    so nothing of a class the student turned off goes through an extractor.
//  - **Once.** The ids go into `processedAnnouncementIDs`, the same ratchet
//    Canvas posts use (an Ed document id is `ed:…` and a Canvas id is digits,
//    so they cannot meet). That one set is already cleared when Canvas is
//    disconnected and when the extraction repair runs, so Ed needs no clearing
//    of its own.
//  - **The AI assist.** `announcementExtractor(for:courseCode:)` picks the
//    extractor for both paths, so an Ed post goes to the backend under exactly
//    the conditions a Canvas post does: the "ai assist" switch is on, the
//    install is Penn's, a backend is configured, and the on-device gate
//    (`mightContainTask`) says the text could carry a task. Otherwise it is the
//    free on-device heuristic. The request carries the post's title and body
//    (never an author: the pooled copy has none, and the `[image]` markers are
//    stripped), with the class code, the post's id (`ed:{course}:{thread}`) and
//    its date; `docs/PRIVACY.md` says so.
//  - **A failed read waits.** A post whose extraction throws (the backend is
//    unreachable) is left unread, as a Canvas post is, but not retried on the
//    next change to the course material: that change arrives with every sync,
//    and a backend that is down would be asked again each time, spending the
//    student's quota on a request that was just refused. Each such post is
//    retried no sooner than `edTaskRetryInterval` later (persisted, so a
//    relaunch does not reset it). The Canvas loop's limits on the shared quota
//    apply as well, on the same keys: a post that fails three times is given
//    up on (read, no find), and a run in which every extraction failed sets
//    the hour's back-off, during which this pass is skipped.
//  - **A quota refusal ends the run** (`BackendError.quotaExceeded`, the daily
//    cap `ask` shares): every further call would be refused too, and it is
//    not the post's fault, so no post gets a retry clock for it and the rest
//    of the run is not attempted. What was read before it is kept.
//  - **Twins.** An Ed task that restates a task already on the ledger (a
//    Canvas announcement's, or an earlier Ed post's) is dropped before it is
//    written (`droppingAnnouncementTwins`, the same rule the Canvas loop used
//    when it read Ed posts for a day), and the post still counts as read.
//  - **Nothing is written for a class that is gone.** The extractor can take
//    seconds (it is a network call), and Canvas can be disconnected or the
//    class hidden meanwhile. After the await, and again before anything is
//    written, the class is looked up afresh; a post whose class is no longer
//    connected and selected is dropped on the floor, rows and read-ids both.
//    Recording its id would outlive the disconnect that just cleared the
//    ratchet, and the post would never be read again after a reconnect.
//
// Rows are `.canvasAnnouncement` with an `ed-` sourceID (`AnnouncementOrigin`).
// See `AnnouncementRecord.edFindSourceID` for why that and not a new source or
// a new column.
//
// **Deleted Ed posts are not detected, on purpose.** Canvas gives the sync a
// window it can reason about; Ed does not. An Ed read replaces a class's whole
// Ed set with its newest 100 threads, so an older pinned post leaves the
// documents without having been deleted, and a failed read partway through a
// run drops the documents of the classes it had not reached (both recorded in
// CLAUDE.md → Known gaps, in code this file does not own). A post missing from
// `courseKnowledge` is therefore weak evidence of deletion, and acting on it
// would hide real tasks. The wrong fix is to treat absence as deletion anyway
// and flag the rows gone.

extension AppState {
    /// The Ed documents worth reading for tasks as of `now`: Ed announcements
    /// and pinned threads, with text, dated within the extraction window
    /// (`edPostDate`; an undated one is skipped). One per document id. Pure.
    nonisolated static func edDocumentsEligibleForTasks(
        _ documents: [CourseDocument],
        now: Date,
        retryAfter: [String: Date] = [:]
    ) -> [CourseDocument] {
        let cutoff = now.addingTimeInterval(-announcementExtractionWindow)
        var seen = Set<String>()
        return documents.filter { document in
            guard document.kind == .ed,
                  let posted = edPostDate(document), posted >= cutoff,
                  retryAfter[document.id].map({ $0 <= now }) ?? true,
                  EdDocumentHeader.parse(document.text).isAnnouncementOrPinned,
                  !EdDocumentHeader.carriesNoText(document.text)
            else { return false }
            return seen.insert(document.id).inserted
        }
    }

    /// The ledger rows an extractor's tasks become for one Ed thread. Pure.
    /// Mirrors `announcementAssignments(from:announcement:courseCode:)`: a
    /// preparation task is an `.event` (nothing to hand in), a submission an
    /// `.assignment`, and the index in the `sourceID` keeps two tasks with the
    /// same title in one post from overwriting each other. `url` is the
    /// thread's own page.
    nonisolated static func edAnnouncementAssignments(
        from extracted: [ExtractedAssignment],
        document: CourseDocument,
        courseCode: String
    ) -> [Assignment] {
        extracted.enumerated().map { index, task in
            Assignment(
                source: .canvasAnnouncement,
                sourceID: AnnouncementRecord.edFindSourceID(
                    courseID: document.courseID, threadID: document.sourceID, index: index
                ),
                kind: task.kind == .preparation ? .event : .assignment,
                course: courseCode,
                title: task.title,
                dueAt: task.dueAt,
                url: document.url,
                term: nil,
                submitted: false
            )
        }
    }

    // MARK: Failed reads wait

    /// How long a post whose extraction failed waits before it is tried again.
    nonisolated static let edTaskRetryInterval: TimeInterval = 6 * 60 * 60
    static let edTaskRetryAfterKey = "edTaskRetryAfterV1"

    /// Document id -> the earliest time it may be read again. Persisted as
    /// seconds since 1970 in `UserDefaults.lhf`.
    static func loadEdTaskRetryAfter() -> [String: Date] {
        let saved = UserDefaults.lhf.dictionary(forKey: edTaskRetryAfterKey) as? [String: Double] ?? [:]
        return saved.mapValues { Date(timeIntervalSince1970: $0) }
    }

    /// Saves `retryAfter` less what has already expired, so the dictionary only
    /// ever holds posts that are actually waiting.
    static func saveEdTaskRetryAfter(_ retryAfter: [String: Date], now: Date) {
        let waiting = retryAfter.filter { $0.value > now }.mapValues(\.timeIntervalSince1970)
        if waiting.isEmpty {
            UserDefaults.lhf.removeObject(forKey: edTaskRetryAfterKey)
        } else {
            UserDefaults.lhf.set(waiting, forKey: edTaskRetryAfterKey)
        }
    }

    // MARK: The pass

    /// The class code a post's cards would be filed under *now*, or nil when
    /// its class is not connected or not selected. Looked up afresh each time
    /// it is asked, on purpose: it is the answer to "is this still wanted",
    /// and a code captured before an `await` is the answer to a question that
    /// may have changed.
    private func edTaskCourseCode(for document: CourseDocument) -> String? {
        guard let code = canvasCourseIDs()[document.courseID], isCourseSelected(code) else { return nil }
        return code
    }

    /// Reads every eligible, unread Ed post once and files what it finds.
    /// Never throws; a post whose extraction fails (the AI path, offline) is
    /// left unread, and tried again no sooner than `edTaskRetryInterval`.
    ///
    /// Called by `scheduleEdAnnouncementTaskPass()` after the course knowledge
    /// changes, and directly by tests.
    func syncEdAnnouncementTasks(now: Date = Date()) async {
        guard FeatureFlags.edDiscussion else { return noteEdTaskSkip("ed off", at: now) }
        guard !isUsingFixtureData else { return noteEdTaskSkip("fixture", at: now) }
        guard let store = assignmentStore else { return noteEdTaskSkip("no store", at: now) }

        var retryAfter = Self.loadEdTaskRetryAfter()
        let eligible = Self.edDocumentsEligibleForTasks(
            courseKnowledge.documents, now: now, retryAfter: retryAfter
        )
        .filter { !processedAnnouncementIDs.contains($0.id) }
        guard !eligible.isEmpty else {
            let edDocuments = courseKnowledge.documents.filter { $0.kind == .ed }.count
            return noteEdTaskSkip("nothing eligible \u{00B7} ed documents \(edDocuments)", at: now)
        }

        // THE QUOTA IS SHARED WITH ASK, and with the Canvas loop, so the Canvas
        // loop's two limits apply here too (see the comment in
        // `syncAnnouncements`): while a back-off is set the run is skipped, and
        // a post whose extraction fails three times (non-quota) is given up on,
        // marked read with no find. They sit beside this pass's own six-hour
        // wait per failed post, which still governs a post under the cap. The
        // keys are the Canvas loop's: a post id here is `ed:…` and a Canvas id
        // is digits, so the counters cannot meet, and one back-off for one
        // shared quota is the point.
        let defaults = UserDefaults.lhf
        if let until = defaults.object(forKey: Self.announcementExtractionBackoffUntilKey) as? Double {
            if now.timeIntervalSince1970 < until {
                return noteEdTaskSkip(
                    "extraction backoff until \(Self.backoffClockStamp(Date(timeIntervalSince1970: until)))",
                    at: now
                )
            }
            defaults.removeObject(forKey: Self.announcementExtractionBackoffUntilKey)
        }
        var attempts = defaults.dictionary(forKey: Self.announcementExtractionAttemptsKey) as? [String: Int] ?? [:]

        // Only for `lastEdTaskSyncSummary`: how many reads failed, and the
        // kind (never the text) of the first failure.
        var extractionErrors = 0
        var firstError: String?
        var gaveUpCount = 0
        // Backend-or-injected extractions started and failed (not quota); the
        // heuristic cannot throw and is not counted. All-failed starts the
        // back-off.
        var attemptedExtractions = 0
        var failedExtractions = 0
        var quotaRefused = false
        // What each post produced, kept apart from the ledger until the whole
        // loop is done: every iteration awaits, so any of them can be the one
        // during which Canvas is disconnected, and the rows of the posts read
        // before it are as unwanted as its own. The class code is the Canvas
        // site's code as the feed knows it, so the per-class switch, the class
        // filter and the duplicate check all see one class. A site the map does
        // not know is left unread, like the Canvas path's unmapped-course
        // branch, and that is also what keeps a disconnected install quiet:
        // disconnecting empties the map (and purges these rows and the read
        // ids), while the posts themselves can outlive it in the course-material
        // cache. The document's own `course` is not a fallback for that reason.
        var results: [(document: CourseDocument, courseCode: String, rows: [Assignment])] = []
        for document in eligible {
            guard let courseCode = edTaskCourseCode(for: document) else { continue }

            let header = EdDocumentHeader.parse(document.text)
            // The `[image]` markers `EdDocumentText` leaves where Ed had a
            // picture are noise to an extractor, and to the model if it
            // goes there.
            let body = header.body.replacingOccurrences(of: "[image]", with: " ")
            let title = document.title.trimmingCharacters(in: .whitespacesAndNewlines)

            // The same gate as the Canvas path, for the same reason: a post
            // that only reports something done ("grades posted") has nothing
            // to extract on either backend. Still a completed parse.
            if HeuristicAnnouncementExtractor.isLikelyInformational(title: title, body: body) {
                results.append((document, courseCode, []))
                continue
            }

            let source = AnnouncementSourceText(
                announcementID: document.id,
                courseCode: courseCode,
                title: title,
                body: body,
                postedAt: Self.edPostDate(document)
            )
            // The extractor choice (and its test seam) takes a Canvas-shaped
            // value; this is the post in that shape, for that call only.
            let standIn = CanvasAnnouncement(
                id: document.id,
                courseID: document.courseID,
                title: title,
                message: body,
                postedAt: Self.edPostDate(document),
                url: document.url
            )
            let extractor = announcementExtractor(for: standIn, courseCode: courseCode)

            let extracted: [ExtractedAssignment]
            let countsTowardBackoff = !(extractor is HeuristicAnnouncementExtractor)
            if countsTowardBackoff { attemptedExtractions += 1 }
            do {
                extracted = try await extractor.extract(from: source, now: now)
            } catch {
                extractionErrors += 1
                if firstError == nil {
                    firstError = Self.extractorErrorKindForSummary(
                        error, decodingDetail: BackendDiagnostics.lastDecodingFailure
                    )
                }
                if let backendError = error as? BackendError, case .quotaExceeded = backendError {
                    // Not this post's fault, and every further call would be
                    // refused too: end the run, and touch no retry clock. The
                    // posts read before this one are kept below.
                    quotaRefused = true
                    break
                }
                if countsTowardBackoff { failedExtractions += 1 }
                let failures = (attempts[document.id] ?? 0) + 1
                if failures >= Self.announcementExtractionMaxAttempts {
                    // Given up on: read, no find. The class is checked again
                    // before this is committed, like any other result.
                    retryAfter[document.id] = nil
                    gaveUpCount += 1
                    results.append((document, courseCode, []))
                } else {
                    attempts[document.id] = failures
                    // Left unread, and left alone for a while: see the header.
                    retryAfter[document.id] = now.addingTimeInterval(Self.edTaskRetryInterval)
                }
                continue
            }
            // The await was a network call. Is the class still wanted?
            guard edTaskCourseCode(for: document) == courseCode else { continue }
            retryAfter[document.id] = nil
            results.append((document, courseCode, Self.edAnnouncementAssignments(
                from: extracted, document: document, courseCode: courseCode
            )))
        }
        Self.saveEdTaskRetryAfter(retryAfter, now: now)

        // Once more, for everything: a later await can have invalidated an
        // earlier result.
        guard !isUsingFixtureData else { return noteEdTaskSkip("fixture", at: now) }
        let wanted = results.filter { edTaskCourseCode(for: $0.document) == $0.courseCode }
        let processed = wanted.map(\.document.id)

        // Twins, post by post in the order read: each post's tasks are checked
        // against the announcement rows already on the ledger (Canvas's, and
        // earlier Ed posts') and the survivors of the posts before it in this
        // run, but not against each other, so two separate tasks in one post
        // are never collapsed into one. The dropped post is still processed.
        var collected: [Assignment] = []
        for result in wanted {
            // (The helper leaves syllabus exam rows out of the pool: an Ed post
            // that moves an exam must not be dropped as a twin of the
            // syllabus's date.)
            collected += Self.droppingAnnouncementTwins(result.rows, against: announcementItems + collected)
        }

        if !collected.isEmpty {
            store.upsert(collected, now: now)
        }
        recordProcessedAnnouncementIDs(processed)
        // A processed id (found, found nothing, informational, or given up on)
        // has no use for a counter.
        for id in processed { attempts.removeValue(forKey: id) }
        if attempts.isEmpty {
            defaults.removeObject(forKey: Self.announcementExtractionAttemptsKey)
        } else {
            defaults.set(attempts, forKey: Self.announcementExtractionAttemptsKey)
        }
        if !quotaRefused, attemptedExtractions > 0, failedExtractions == attemptedExtractions {
            defaults.set(
                now.addingTimeInterval(Self.announcementExtractionBackoff).timeIntervalSince1970,
                forKey: Self.announcementExtractionBackoffUntilKey
            )
        }
        if !collected.isEmpty || !processed.isEmpty {
            applyAnnouncementLedgerChange()
        }
        noteEdTaskSync(
            "eligible \(eligible.count) \u{00B7} finds \(collected.count) \u{00B7} errors \(extractionErrors)"
                + " \u{00B7} processed \(processed.count)"
                + (firstError.map { " \u{00B7} first error: \($0)" } ?? "")
                + (gaveUpCount > 0 ? " \u{00B7} gave up \(gaveUpCount)" : ""),
            at: now
        )
    }

    // MARK: What the last run says about itself

    /// Records what the last `syncEdAnnouncementTasks` did that read posts
    /// (see `lastEdTaskSyncSummary`): the time, then `detail`, which the
    /// caller builds from counts and fixed words only. The pass runs after
    /// every change to the course material and nearly every run has nothing
    /// to read, so those runs go through `noteEdTaskSkip` and keep the last
    /// real line behind them instead of burying it.
    private func noteEdTaskSync(_ detail: String, at now: Date) {
        let summary = "\(Self.diagnosticStamp(now)) \u{00B7} \(detail)"
        lastEdTaskSyncSummary = summary
        UserDefaults.lhf.set(summary, forKey: Self.lastEdTaskSyncSummaryKey)
    }

    /// A run that stopped before reading anything. Same carrying-forward rule
    /// as the course-material sync's skips (`courseKnowledgeSkipSummary`).
    ///
    /// **Debug builds only.** The pass runs after every change to the course
    /// material and nearly every run lands here, and each call would publish
    /// and persist a string that differs from the last only by its timestamp,
    /// invalidating every view observing `AppState` for a line that only the
    /// DEBUG diagnostics rows ever show. A real run (`noteEdTaskSync`) is rare
    /// and is written in every build.
    private func noteEdTaskSkip(_ reason: String, at now: Date) {
        #if DEBUG
        let summary = Self.courseKnowledgeSkipSummary(previous: lastEdTaskSyncSummary, at: now, reason: reason)
        lastEdTaskSyncSummary = summary
        UserDefaults.lhf.set(summary, forKey: Self.lastEdTaskSyncSummaryKey)
        #endif
    }

    // MARK: Triggering

    /// Subscribes, once, to `courseKnowledge`, so Ed posts are read after a
    /// sync lands without a call being added to the sync (whose Ed half is not
    /// ours to change). The same pattern the megaphone's Ed rows use
    /// (`observeKnowledgeForAnnouncements`): `@Published` fires before the
    /// value changes, which is why the handler schedules a task that runs
    /// afterwards instead of reading the value itself.
    func observeKnowledgeForEdTasks() {
        guard edTaskKnowledgeSubscription == nil else { return }
        edTaskKnowledgeSubscription = $courseKnowledge
            .dropFirst()
            .sink { [weak self] _ in
                // `courseKnowledge` is only ever set on the main actor.
                MainActor.assumeIsolated {
                    self?.scheduleEdAnnouncementTaskPass()
                }
            }
    }

    /// Runs the pass on the main actor, one at a time. A change that arrives
    /// while a pass is running (a second sync landing, the manifest's
    /// downloads and then the Ed merge are two assignments) sets a flag, and
    /// the run goes round again when it finishes, so the last knowledge is
    /// always the one read. Each pass is cheap when nothing is new: it filters
    /// by the processed ids before doing anything.
    func scheduleEdAnnouncementTaskPass() {
        guard FeatureFlags.edDiscussion else { return }
        if edTaskPassTask != nil {
            edTaskPassNeedsRerun = true
            return
        }
        edTaskPassTask = Task { @MainActor [weak self] in
            guard let self else { return }
            repeat {
                self.edTaskPassNeedsRerun = false
                await self.syncEdAnnouncementTasks()
            } while self.edTaskPassNeedsRerun
            self.edTaskPassTask = nil
        }
    }
}
