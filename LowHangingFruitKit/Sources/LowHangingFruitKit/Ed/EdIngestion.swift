import Foundation

/// Turns one page of Ed threads into pooled `CourseDocument`s.
///
/// The privacy stance lives in `EdThreadFilter` and is only restated here:
/// a document is built for a *kept* thread and for nothing else, so a student's
/// post, a private thread, or a question never becomes one. `CourseDocument`
/// has no author field at all, and `EdDocumentBuilder.text` never writes one
/// into the text, so even a kept thread cannot carry its author out.
public enum EdIngestion {
    /// How far back a thread may have last moved and still be worth pooling:
    /// about a semester. An older announcement is last term's policy, and
    /// ranking it beside this term's would mislead ask.
    public static let defaultMaxAge: TimeInterval = 120 * 86_400

    /// The thread's page in Ed's web app, the link ask cites. Always the
    /// `us` region host; the numbers are Ed's course and thread ids.
    public static func threadURL(edCourseID: Int, threadID: Int) -> URL {
        URL(string: "https://edstem.org/us/courses/\(edCourseID)/discussion/\(threadID)")!
    }

    /// One `.ed` document per kept, recent thread, newest first.
    ///
    /// Recency is `updatedAt` when Ed sends one and `createdAt` otherwise,
    /// the same value stored as the document's `updatedAt`. The course fields
    /// are copied from the Canvas `course` exactly as
    /// `CourseDocumentBuilder.announcement` does, because pooling is keyed on
    /// the Canvas course id, not Ed's.
    public static func documents(
        course: CourseSummary,
        edCourseID: Int,
        response: EdThreadsResponse,
        now: Date,
        maxAge: TimeInterval = defaultMaxAge
    ) -> [CourseDocument] {
        let cutoff = now.addingTimeInterval(-maxAge)
        var documents: [CourseDocument] = []
        for (thread, decision) in EdThreadFilter.keptThreads(response) {
            let moved = thread.updatedAt ?? thread.createdAt
            if moved < cutoff { continue }
            documents.append(CourseDocument(
                courseID: course.courseID,
                course: course.code,
                kind: .ed,
                sourceID: EdDocumentBuilder.sourceID(for: thread),
                title: EdDocumentBuilder.title(for: thread),
                url: threadURL(edCourseID: edCourseID, threadID: thread.id),
                text: EdDocumentBuilder.text(for: thread, decision: decision),
                updatedAt: moved,
                fetchedAt: now
            ))
        }
        // Stable for equal dates: `sorted` is not guaranteed stable, so tie-break on id.
        return documents.sorted { lhs, rhs in
            let l = lhs.updatedAt ?? .distantPast
            let r = rhs.updatedAt ?? .distantPast
            return l != r ? l > r : lhs.sourceID < rhs.sourceID
        }
    }
}
