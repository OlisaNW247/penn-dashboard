import Foundation
import LowHangingFruitKit

// MARK: – Giving an already-read post its relevance judgment
//
// The server judges how long each announcement stays worth listing
// (`AnnouncementRelevance`), and the phone asks for that judgment in the same
// call that reads the post for tasks. It reads a post for tasks **once**
// (`processedAnnouncementIDsV1`). Two things found on a real phone follow from
// that, and this file is the fix for both.
//
//  1. **Posts read before judgments existed never got one.** They are
//     processed, so nothing asks about them again, and the megaphone decides
//     them the old way (the plain 7-day rule) for as long as they live.
//  2. **The server that judges was not deployed yet.** A post read in that
//     window got the tasks and no judgment, and was marked processed anyway:
//     its one read was wasted. Every Ed staff post read in that window was
//     pure waste, because a staff post is read for its judgment and for
//     nothing else.
//
// **The flag.** The phone cannot know whether the server judges until it has
// seen it do so, so `ServerJudgesRelevance` is set the first time any response
// carries a usable judgment. Until then there is no backfill, and the Ed pass
// does not read staff posts at all. Announcements, pinned posts and Canvas
// posts are read for tasks exactly as before: they were always worth reading.
//
// **The backfill.** Once the flag is set, a post that is already processed,
// inside the 14-day extraction window, still has text and has no stored
// judgment gets one relevance-only call through `extractWithRelevance`.
// The judgment is stored and the assignments in the answer are **discarded**:
// the post was already read for its tasks, and filing them again would put a
// second row on the ledger for a thing the student has seen. An informational
// post (`isLikelyInformational`) is `news` on the phone with no call, as at
// the first read. Newest-posted first, because the newest are the ones still
// on the sheet.
//
// **The quota.** Each call is a unit of the same per-student daily quota as
// ask, so backfill calls and staff-post reads share one UTC-day count
// (`RelevanceReadBudget`, six). A failure stamps the post so it is not asked
// again that day, and an answer with no judgment marks it judged-empty so it
// cannot burn the budget every day (`RelevanceBackfillLedger`). The extraction
// back-off applies as well: while the server is failing, nothing is asked.
//
// **The wrong fixes.** Clearing `processedAnnouncementIDs` so the main loops
// read everything again would re-file every task the student has already seen
// and finished, and re-send the whole 14-day backlog at once. Asking before
// the flag is set (or filing the Ed staff reads before it) spends the shared
// quota for an answer that cannot contain a judgment, and still marks the post
// processed, which is the waste this exists to undo.
//
// Canvas posts are backfilled from the announcements the sync has already
// fetched in the same run (no new request); Ed posts from the `.ed` documents
// already in `courseKnowledge`. Nothing here needs the network except the
// extractor call itself.

extension AppState {
    // MARK: Candidates

    /// The Canvas posts the backfill may ask about, from this run's fetch.
    /// Processed before this run (`readThisRun` are posts the main loop has
    /// just sent, which were asked a moment ago), inside the extraction
    /// window, mapped to a selected class, and with a body.
    func canvasRelevanceBackfillCandidates(
        fetched: [CanvasAnnouncement],
        courseCodesByID: [String: String],
        readThisRun: Set<String>,
        now: Date
    ) -> [RelevanceBackfillCandidate] {
        Self.announcementsEligibleForExtraction(fetched, now: now).compactMap { announcement in
            guard processedAnnouncementIDs.contains(announcement.id),
                  !readThisRun.contains(announcement.id),
                  let courseCode = courseCodesByID[announcement.courseID],
                  !announcement.message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            else { return nil }
            return RelevanceBackfillCandidate(
                key: AnnouncementReadState.recordKey(announcement.id),
                source: AnnouncementSourceText(
                    announcementID: announcement.id,
                    courseCode: courseCode,
                    title: announcement.title,
                    body: announcement.message,
                    postedAt: announcement.postedAt
                ),
                standIn: announcement,
                isStillWanted: { [weak self] in
                    guard let self, !self.isUsingFixtureData else { return false }
                    return self.selectedCanvasCourseIDs()[announcement.courseID] == courseCode
                }
            )
        }
    }

    /// The Ed posts the backfill may ask about, from the documents already on
    /// the phone: announcements, pinned threads and staff posts, processed
    /// before this run, inside the window, with text, of a class that is still
    /// connected and selected. (Eligibility is the main pass's own rule,
    /// `edDocumentsEligibleForTasks`, minus its retry clock, which is for
    /// posts not yet read.)
    func edRelevanceBackfillCandidates(readThisRun: Set<String>, now: Date) -> [RelevanceBackfillCandidate] {
        Self.edDocumentsEligibleForTasks(courseKnowledge.documents, now: now).compactMap { document in
            guard processedAnnouncementIDs.contains(document.id),
                  !readThisRun.contains(document.id),
                  let courseCode = edTaskCourseCode(for: document)
            else { return nil }
            let text = Self.edReadText(for: document, courseCode: courseCode)
            return RelevanceBackfillCandidate(
                key: AnnouncementReadState.edKey(document.id),
                source: text.source,
                standIn: text.standIn,
                isStillWanted: { [weak self] in
                    guard let self, !self.isUsingFixtureData else { return false }
                    return self.edTaskCourseCode(for: document) == courseCode
                }
            )
        }
    }

    // MARK: The run

    /// Asks the server for the judgment of each candidate that has none, as far
    /// as today's budget goes, and stores what comes back. Never throws; never
    /// writes the ledger.
    ///
    /// Does nothing until the server is known to judge
    /// (`serverJudgesRelevance`), without the announcement log (nowhere to put
    /// a judgment, so every call would be wasted and asked again), or while the
    /// extraction back-off is set.
    func backfillRelevance(_ candidates: [RelevanceBackfillCandidate], now: Date) async -> RelevanceBackfillOutcome {
        var outcome = RelevanceBackfillOutcome()
        guard serverJudgesRelevance.isSet, announcementLog != nil, !candidates.isEmpty else { return outcome }
        if let until = UserDefaults.lhf.object(forKey: Self.announcementExtractionBackoffUntilKey) as? Double,
           now.timeIntervalSince1970 < until {
            return outcome
        }

        // Newest posted first (an undated post last, ties by id), so the
        // budget goes to the posts still on the sheet.
        let pending = candidates
            .filter { announcementRelevance[$0.key] == nil }
            .sorted { lhs, rhs in
                let l = lhs.standIn.postedAt ?? .distantPast
                let r = rhs.standIn.postedAt ?? .distantPast
                if l != r { return l > r }
                return lhs.key.compare(rhs.key, options: .numeric) == .orderedDescending
            }

        var judgments: [String: AnnouncementRelevance] = [:]
        for candidate in pending {
            if relevanceBackfillLedger.shouldSkip(candidate.key, on: now) { continue }

            // News by construction, as at the first read: no call, no budget.
            if HeuristicAnnouncementExtractor.isLikelyInformational(
                title: candidate.source.title, body: candidate.source.body
            ) {
                judgments[candidate.key] = AnnouncementRelevance(kind: .news)
                outcome.localNews += 1
                continue
            }

            // The free on-device heuristic never judges, and costs nothing:
            // this is the extractor the main loop would pick (the AI assist is
            // off, the install is not Penn's, or the text cannot carry a task),
            // and for it there is nothing to ask.
            let extractor = announcementExtractor(for: candidate.standIn, courseCode: candidate.source.courseCode)
            if extractor is HeuristicAnnouncementExtractor { continue }

            guard relevanceReadBudget.remaining(on: now) > 0 else {
                outcome.heldBack += 1
                continue
            }
            relevanceReadBudget.recordCall(on: now)
            outcome.asked += 1
            do {
                let extraction = try await extractor.extractWithRelevance(from: candidate.source, now: now)
                guard candidate.isStillWanted() else { continue }
                // The answer's assignments are dropped on purpose (see the
                // header): only the judgment is kept.
                if let relevance = extraction.relevance {
                    serverJudgesRelevance.markSeen()
                    judgments[candidate.key] = relevance
                    outcome.judged += 1
                } else {
                    relevanceBackfillLedger.recordEmpty(candidate.key, on: now)
                }
            } catch {
                if let backendError = error as? BackendError, case .quotaExceeded = backendError {
                    // Every further call would be refused too, and it is not
                    // this post's fault: stamp nothing and stop.
                    break
                }
                relevanceBackfillLedger.recordFailure(candidate.key, on: now)
                outcome.failed += 1
            }
        }
        recordAnnouncementRelevance(judgments)
        return outcome
    }
}
