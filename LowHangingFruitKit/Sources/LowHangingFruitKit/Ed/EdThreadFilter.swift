import Foundation

public struct EdThreadDecision: Sendable, Equatable {
    public let keep: Bool
    /// A short, fixed phrase. Doubles as the label in the document header
    /// (`EdDocumentBuilder`), so the kept reasons are written to read well
    /// there: "announcement", "pinned", "staff post".
    public let reason: String

    public init(keep: Bool, reason: String) {
        self.keep = keep
        self.reason = reason
    }
}

/// Decides which Ed threads may become pooled course material.
///
/// **The privacy stance, and why the rule is "staff, not question".** Course
/// materials are pooled server-side: one copy per Canvas course, shared by
/// every classmate. A thread a *student* wrote therefore must never leave
/// the phone: it is another student's words, written for a class forum, not
/// for an index their classmates query. The same goes for private threads
/// (a student's question to staff) and for questions generally, which are
/// student-authored even when a staff member later answers them. What is
/// kept is what the course staff addressed to the whole class: announcements,
/// pinned posts (only staff can pin), and staff-authored non-question posts.
///
/// Authors are never named. A kept thread's text carries no author name or id,
/// only the word "staff" where provenance matters;
/// `EdThreadUser.name` is decoded for completeness and used nowhere.
///
/// Unknown is dropped: an author missing from the `users` array, a missing
/// role, a type Ed adds next year. The cost of a wrongly dropped thread is a
/// missing answer; the cost of a wrongly kept one is a student's words in a
/// shared index.
public enum EdThreadFilter {
    public static let staffRoles: Set<String> = ["admin", "staff", "instructor", "ta", "tutor", "mentor"]

    public static func decide(_ thread: EdThread, authorRole: String?) -> EdThreadDecision {
        // Private beats everything, announcements included: a private
        // thread is addressed to one person, whatever its type field says.
        if thread.isPrivate {
            return EdThreadDecision(keep: false, reason: "private")
        }
        let type = thread.type.lowercased()
        if type == "announcement" {
            return EdThreadDecision(keep: true, reason: "announcement")
        }
        if thread.isPinned {
            return EdThreadDecision(keep: true, reason: "pinned")
        }
        if let role = authorRole?.lowercased(), staffRoles.contains(role), type != "question" {
            return EdThreadDecision(keep: true, reason: "staff post")
        }
        return EdThreadDecision(keep: false, reason: "student or question")
    }

    /// The threads of a page that pass `decide`, each with its decision, in
    /// the order Ed returned them. Roles come from the response's own
    /// `users` array, keyed by user id.
    public static func keptThreads(_ response: EdThreadsResponse) -> [(thread: EdThread, decision: EdThreadDecision)] {
        var roles: [Int: String] = [:]
        for user in response.users {
            if let role = user.courseRole { roles[user.id] = role }
        }
        var kept: [(thread: EdThread, decision: EdThreadDecision)] = []
        for thread in response.threads {
            let decision = decide(thread, authorRole: roles[thread.userID])
            if decision.keep { kept.append((thread: thread, decision: decision)) }
        }
        return kept
    }
}
