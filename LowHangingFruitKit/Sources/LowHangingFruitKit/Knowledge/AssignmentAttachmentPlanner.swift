import Foundation

/// What happened the last time the phone asked Canvas about a file. A file
/// with no text to give (a scan, a non-PDF, too large, locked) will not grow
/// text tomorrow, so it waits a week; anything else retries after a day.
public struct AssignmentAttachmentAttempt: Sendable, Hashable {
    public enum Kind: String, Sendable { case failed, noText, pooled }
    public let date: Date
    public let kind: Kind
    public init(date: Date, kind: Kind) { self.date = date; self.kind = kind }

    /// Stored as `["t": seconds, "k": kind]`; a plain number (the first
    /// format, a bare date) reads as `failed`.
    public var encoded: [String: Any] { ["t": date.timeIntervalSince1970, "k": kind.rawValue] }

    public static func decode(_ raw: Any?) -> AssignmentAttachmentAttempt? {
        if let seconds = raw as? Double { return .init(date: Date(timeIntervalSince1970: seconds), kind: .failed) }
        if let dict = raw as? [String: Any], let t = dict["t"] as? Double {
            return .init(date: Date(timeIntervalSince1970: t), kind: Kind(rawValue: dict["k"] as? String ?? "") ?? .failed)
        }
        return nil
    }
}

/// One Canvas file the phone should fetch this run, and the assignment whose
/// description linked it.
public struct AssignmentAttachmentFetch: Sendable, Hashable {
    public let fileID: String
    public let courseID: String
    /// The assignment document's `sourceID`.
    public let assignmentSourceID: String
    public let dueAt: Date?
}

/// Decides which PDFs linked from assignment descriptions are worth fetching
/// now. Pure: no store, no clock, no network.
///
/// The ids come from the `"<link text>: <href>"` lines
/// `CourseDocumentBuilder.assignment(from:)` appends for same-host `/files/`
/// links (2026-11-10), so a document pooled before that change has none and
/// simply plans nothing until its next revision.
///
/// The due-date window is the guard against a recycled site: an assignment
/// due a semester ago links last year's problem set, which is neither the
/// student's nor worth the pooled quota. Open work and work due in the last
/// week qualify.
public enum AssignmentAttachmentPlanner {
    public static let maxPerRun = 20
    public static let dueLookback: TimeInterval = 7 * 86_400
    public static let retryInterval: TimeInterval = 24 * 3_600
    public static let noTextRetryInterval: TimeInterval = 7 * 86_400
    /// An undated assignment qualifies only if Canvas changed it this recently:
    /// a recycled site's undated items carry last year's `updatedAt`.
    public static let undatedFreshness: TimeInterval = 60 * 86_400

    public static func plan(
        documents: [CourseDocument],
        now: Date,
        attempts: [String: AssignmentAttachmentAttempt],
        limit: Int = maxPerRun
    ) -> [AssignmentAttachmentFetch] {
        let cutoff = now.addingTimeInterval(-dueLookback)

        // Ids the pool or this phone already holds as a `file` document.
        var held = Set<String>()
        for doc in documents where doc.kind == .file {
            held.insert(doc.sourceID)
            if let id = fileID(inURL: doc.url?.absoluteString) { held.insert(id) }
        }

        let candidates = documents
            .filter { doc in
                guard doc.kind == .assignment else { return false }
                if let due = doc.dueAt { return due >= cutoff }
                guard let updated = doc.updatedAt else { return false }
                return now.timeIntervalSince(updated) <= undatedFreshness
            }
            .sorted { lhs, rhs in
                switch (lhs.dueAt, rhs.dueAt) {
                case let (l?, r?): return l != r ? l < r : lhs.id < rhs.id
                case (_?, nil): return true
                case (nil, _?): return false
                case (nil, nil): return lhs.id < rhs.id
                }
            }

        var out: [AssignmentAttachmentFetch] = []
        var chosen = Set<String>()
        for doc in candidates {
            for id in fileIDs(inText: doc.text, host: doc.url?.host, courseID: doc.courseID) {
                guard out.count < limit else { return out }
                guard !held.contains(id), !chosen.contains(id) else { continue }
                if let last = attempts[id],
                   now.timeIntervalSince(last.date) < (last.kind == .noText ? noTextRetryInterval : retryInterval) { continue }
                chosen.insert(id)
                out.append(AssignmentAttachmentFetch(
                    fileID: id, courseID: doc.courseID,
                    assignmentSourceID: doc.sourceID, dueAt: doc.dueAt
                ))
            }
        }
        return out
    }

    /// File ids in `text`'s absolute https URLs on `host` whose path is
    /// `/courses/<this course>/files/<digits>` or a bare `/files/<digits>`
    /// (a folder link has no digits there; `/users/N/files`, `/groups/N/files`
    /// and another course's files are not this course's material), in order of
    /// first appearance. No host, no ids.
    static func fileIDs(inText text: String, host: String?, courseID: String) -> [String] {
        guard let host = host?.lowercased(), !host.isEmpty else { return [] }
        var seen = Set<String>()
        var ids: [String] = []
        for match in urlPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let hostRange = Range(match.range(at: 1), in: text),
                  let idRange = Range(match.range(at: 3), in: text),
                  text[hostRange].lowercased() == host else { continue }
            if let courseRange = Range(match.range(at: 2), in: text), String(text[courseRange]) != courseID { continue }
            let id = String(text[idRange])
            if seen.insert(id).inserted { ids.append(id) }
        }
        return ids
    }

    static func fileID(inURL url: String?) -> String? {
        guard let url else { return nil }
        guard let m = anyFilesPattern.firstMatch(in: url, range: NSRange(url.startIndex..., in: url)),
              let r = Range(m.range(at: 1), in: url) else { return nil }
        return String(url[r])
    }

    private static let urlPattern = try! NSRegularExpression(
        pattern: #"https://([^/\s?#]+)/(?:courses/(\d+)/)?files/(\d+)(?![\d])"#
    )
    private static let anyFilesPattern = try! NSRegularExpression(pattern: #"/files/(\d+)"#)
}
