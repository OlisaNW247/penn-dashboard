import Foundation
import LowHangingFruitKit

/// The PDFs an instructor linked from an assignment's description, pooled
/// like the rest of the course material (2026-11-10, blind). Runs at the end
/// of a successful `refreshCourseKnowledge`, after its uploads, in the
/// foreground only: never from the background wake. Every failure is silent;
/// the one summary line holds counts and words, never a title or a URL.
extension AppState {
    nonisolated static let attachmentAttemptsKey = "attachmentAttemptsV1"
    nonisolated static let lastAttachmentSyncSummaryKey = "lastAttachmentSyncSummaryV1"
    nonisolated static let attachmentBudget: TimeInterval = 60
    nonisolated static let attachmentAttemptRetention: TimeInterval = 7 * 86_400

    func attachmentPass(cookies: [HTTPCookie]) async {
        // Foreground only, the way `deviceSyncPass` and `agentSnapshotPass`
        // are kept out of the background wake (`renewalContext`): iOS gives a
        // wake about 30 s, and `refreshCourseKnowledge` is reachable from it
        // through `refreshCanvasGrades`.
        guard renewalContext != .background,
              !isUsingFixtureData, !cookies.isEmpty,
              canvasInstallation.id == CanvasInstallation.penn.id,
              let backend = BackendServices.client else { return }

        let now = Date()
        var attempts = Self.loadAttachmentAttempts(now: now)
        let plan = AssignmentAttachmentPlanner.plan(
            documents: courseKnowledge.documents, now: now, attempts: attempts)
        guard !plan.isEmpty else {
            Self.recordAttachmentSummary(AssignmentAttachmentRunner.Outcome().summary)
            Self.saveAttachmentAttempts(attempts, now: now)
            return
        }

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        let client = CanvasFilesClient(
            baseURL: canvasBaseURL, cookies: cookies,
            session: URLSession(configuration: configuration),
            accessToken: canvasAccessTokenBearer)
        let courses = courseKnowledge.courses
        let baseURL = canvasBaseURL

        // Network and PDF work run in a nonisolated async function, so off
        // the main actor.
        let outcome = await AssignmentAttachmentRunner.run(
            plan: plan, client: client, courses: courses, baseURL: baseURL,
            now: now, budget: Self.attachmentBudget)

        for record in outcome.attempted {
            attempts[record.id] = AssignmentAttachmentAttempt(date: now, kind: record.kind)
        }
        Self.saveAttachmentAttempts(attempts, now: now)
        guard !outcome.documents.isEmpty else {
            Self.recordAttachmentSummary(outcome.summary)
            return
        }

        // Same save path the collector uses. `merge` with no resynced course
        // only adds or replaces these documents.
        var knowledge = courseKnowledge
        knowledge.merge(courses: [], documents: outcome.documents, resyncedCourseIDs: [],
                        syncedAt: knowledge.lastSyncedAt ?? now)
        // A failed save leaves the published value alone: the next pass will
        // fetch the files again (the attempts are 24 h), and the summary says so.
        do {
            try CourseKnowledgeStore.default().save(knowledge)
        } catch {
            var failed = outcome
            failed.firstFailure = failed.firstFailure ?? "save"
            Self.recordAttachmentSummary(failed.summary)
            return
        }
        courseKnowledge = knowledge
        Self.recordAttachmentSummary(outcome.summary)

        // Same upload the collector's documents take. No complete-set report:
        // this pass knows nothing about a course's other documents.
        var added = CourseKnowledgeBase.empty
        added.documents = outcome.documents
        let request = SyncPlanner.uploads(local: added, serverManifest: [], fullyFetched: [])
        for batch in SyncPlanner.uploadBatches(request, maxDocuments: 200) {
            guard (try? await backend.syncUpload(batch)) != nil else { return }
        }
    }

    nonisolated static func loadAttachmentAttempts(now: Date) -> [String: AssignmentAttachmentAttempt] {
        guard let raw = UserDefaults.lhf.dictionary(forKey: attachmentAttemptsKey) else { return [:] }
        return raw.compactMapValues { value in
            guard let attempt = AssignmentAttachmentAttempt.decode(value),
                  now.timeIntervalSince(attempt.date) <= attachmentAttemptRetention else { return nil }
            return attempt
        }
    }

    nonisolated static func saveAttachmentAttempts(_ attempts: [String: AssignmentAttachmentAttempt], now: Date) {
        let kept = attempts.filter { now.timeIntervalSince($0.value.date) <= attachmentAttemptRetention }
        UserDefaults.lhf.set(kept.mapValues(\.encoded), forKey: attachmentAttemptsKey)
    }

    nonisolated static func recordAttachmentSummary(_ line: String) {
        UserDefaults.lhf.set(line, forKey: lastAttachmentSyncSummaryKey)
    }
}
