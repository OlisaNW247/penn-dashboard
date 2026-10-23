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
/// **Anonymous posts never leave the phone** (`docs/PRIVACY.md` promises it;
/// enforced here since 2026-10-23, before which the filter never read
/// `isAnonymous`). Anonymity is the author's request that the class not know
/// who wrote the post, and a pooled copy is read by every classmate, so an
/// anonymous post is dropped even when it is an announcement or staff pinned
/// it: the rule is "the author asked not to be identified", not "a student
/// wrote it". Staff who post anonymously get the same answer. The check sits
/// after "private" and before "announcement" because the announcement and
/// pinned rules are the two that keep a thread whatever its author is.
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

    /// The rules, first match wins:
    /// 1. private: dropped ("private");
    /// 2. anonymous: dropped ("anonymous");
    /// 3. an announcement: kept ("announcement");
    /// 4. pinned: kept ("pinned");
    /// 5. a non-question by a staff role: kept ("staff post");
    /// 6. everything else: dropped ("student or question").
    ///
    /// `EdThread.isAnonymous` decodes a missing `is_anonymous` as `false`
    /// (`EdWire.swift`), unlike `isPrivate`, which defaults to `true`. That
    /// is deliberate and not a hole to close here: Ed sends the field on
    /// every real thread, so "missing" only happens in a hand-built fixture.
    /// The cost of reading an absent flag as anonymous would be dropping
    /// every announcement the day Ed renamed the field, which fails loud
    /// (no Ed documents at all) where the other default would fail quiet.
    public static func decide(_ thread: EdThread, authorRole: String?) -> EdThreadDecision {
        // Private beats everything, announcements included: a private
        // thread is addressed to one person, whatever its type field says.
        if thread.isPrivate {
            return EdThreadDecision(keep: false, reason: "private")
        }
        if thread.isAnonymous {
            return EdThreadDecision(keep: false, reason: "anonymous")
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
