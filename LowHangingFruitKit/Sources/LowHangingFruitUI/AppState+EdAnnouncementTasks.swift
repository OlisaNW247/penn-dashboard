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
//    Only posts with a last-activity date in the past 14 days, the window a
//    Canvas post gets (`announcementExtractionWindow`).
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
//    free on-device heuristic. The text sent is what the pooled copy already
//    holds (the header line and body, no author), and `docs/PRIVACY.md` says
//    so.
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
    /// and pinned threads, with text, active within the extraction window. One
    /// per document id. Pure.
    nonisolated static func edDocumentsEligibleForTasks(
        _ documents: [CourseDocument],
        now: Date
    ) -> [CourseDocument] {
        let cutoff = now.addingTimeInterval(-announcementExtractionWindow)
        var seen = Set<String>()
        return documents.filter { document in
            guard document.kind == .ed,
                  let active = document.updatedAt, active >= cutoff,
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

    // MARK: The pass

    /// Reads every eligible, unread Ed post once and files what it finds.
    /// Never throws; a post whose extraction fails (the AI path, offline) is
    /// left unread for the next pass, like a Canvas post.
    ///
    /// Called by `scheduleEdAnnouncementTaskPass()` after the course knowledge
    /// changes, and directly by tests.
    func syncEdAnnouncementTasks(now: Date = Date()) async {
        guard FeatureFlags.edDiscussion, !isUsingFixtureData, let store = assignmentStore else { return }

        let eligible = Self.edDocumentsEligibleForTasks(courseKnowledge.documents, now: now)
            .filter { !processedAnnouncementIDs.contains($0.id) }
        guard !eligible.isEmpty else { return }

        // The code the class's cards are filed under: the Canvas site's code
        // as the feed knows it, so the per-class switch, the class filter and
        // the duplicate check all see one class. A site the map does not know
        // is left unread, like the Canvas path's unmapped-course branch, and
        // that is also what keeps a disconnected install quiet: disconnecting
        // empties the map (and purges these rows and the read ids), while the
        // posts themselves can outlive it in the course-material cache, and
        // without a Canvas account behind it nothing should turn them back
        // into cards. The document's own `course` is not a fallback for that
        // reason.
        let codesByID = canvasCourseIDs()

        var collected: [Assignment] = []
        var processed: [String] = []
        for document in eligible {
            guard let courseCode = codesByID[document.courseID], isCourseSelected(courseCode) else { continue }

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
                processed.append(document.id)
                continue
            }

            let source = AnnouncementSourceText(
                announcementID: document.id,
                courseCode: courseCode,
                title: title,
                body: body,
                postedAt: document.updatedAt
            )
            // The extractor choice (and its test seam) takes a Canvas-shaped
            // value; this is the post in that shape, for that call only.
            let standIn = CanvasAnnouncement(
                id: document.id,
                courseID: document.courseID,
                title: title,
                message: body,
                postedAt: document.updatedAt,
                url: document.url
            )
            let extractor = announcementExtractor(for: standIn, courseCode: courseCode)

            let extracted: [ExtractedAssignment]
            do {
                extracted = try await extractor.extract(from: source, now: now)
            } catch {
                continue
            }
            collected.append(contentsOf: Self.edAnnouncementAssignments(
                from: extracted, document: document, courseCode: courseCode
            ))
            processed.append(document.id)
        }

        if !collected.isEmpty {
            store.upsert(collected, now: now)
        }
        recordProcessedAnnouncementIDs(processed)
        if !collected.isEmpty || !processed.isEmpty {
            applyAnnouncementLedgerChange()
        }
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
