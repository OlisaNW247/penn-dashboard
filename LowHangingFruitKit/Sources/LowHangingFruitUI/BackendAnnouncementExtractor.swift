import Foundation
import LowHangingFruitKit

/// Replaces `ClaudeAnnouncementExtractor`: same job — turning an
/// announcement Canvas's own heuristic parser (`HeuristicAnnouncementExtractor`)
/// couldn't make sense of into candidate assignments — but calling LHF's own
/// `extract-announcement` backend function (`backend/PROTOCOL.md`) instead
/// of Anthropic directly, so there is no student-managed API key involved
/// and no per-call cost to the student's own account. The request still
/// carries only what the previous version sent: the announcement's course
/// code, title, body and posted date, plus the caller's notion of "now" —
/// never a Canvas credential, never anything about the rest of the
/// student's classes.
///
/// Counted against the same daily/monthly quota `ask` shares
/// (`backend/PROTOCOL.md`'s "Quota" section) — nothing here decides *when*
/// to call this, that policy still belongs to whatever syncs announcements,
/// not to the extractor itself, exactly as `ClaudeAnnouncementExtractor`'s
/// own header said.
struct BackendAnnouncementExtractor: AnnouncementAssignmentExtractor {
    let client: BackendClient

    func extract(from announcement: AnnouncementSourceText, now: Date) async throws -> [ExtractedAssignment] {
        let request = ExtractAnnouncementRequest(
            announcementID: announcement.announcementID,
            courseCode: announcement.courseCode,
            title: announcement.title,
            message: announcement.body,
            postedAt: announcement.postedAt,
            now: now
        )
        let response = try await client.extractAnnouncement(request)
        // `taskKind` is `ExtractedAssignmentWire`'s resolved `ExtractedTaskKind`
        // (`.kind` is the raw string the server actually sent, kept on the
        // wire type for whatever fallback decoding it does with an
        // unrecognized value — see that property's own doc comment) — reading
        // through `taskKind` here keeps this extractor agnostic to how that
        // resolution happens.
        return response.assignments.map {
            ExtractedAssignment(title: $0.title, dueAt: $0.dueAt, kind: $0.taskKind)
        }
    }
}
