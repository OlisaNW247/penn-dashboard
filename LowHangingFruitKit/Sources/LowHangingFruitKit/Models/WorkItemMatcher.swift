import Foundation

/// Decides whether two `WorkItemIdentity` values are one piece of work, and
/// says why. Three tiers, strongest first; the first that fires wins.
///
/// Tier 1 (deterministic): a shared alias in the same id space.
/// Tier 2 (title and date): normalised titles equal or one a safe prefix of
///   the other, due dates within `titleDueWindow` (or both undated).
/// Tier 3 (model target): a fact's `target` resolved ONLY against a supplied
///   candidate index, never free text. See `resolve(target:among:)`.
///
/// **The hard rule sits above all three.** Two items whose Canvas assignment
/// ids are both known and differ are two assignments, whatever a title or a
/// model says ("Lab 3" id 111 and "Lab 3 Report" id 222 are a 0.667 title
/// match and two separate deliverables). It is checked first and returned as
/// `.refused`, distinct from `.noMatch`, so a caller can tell "unrelated"
/// from "provably different". The wrong fix is loosening a title threshold,
/// which moves every path for a problem that only exists when ids are known.
public enum WorkItemMatcher {
    public enum Tier: String, Sendable, Codable, Hashable {
        case deterministic
        case titleAndDate
        case modelTarget
    }

    public struct Match: Sendable, Hashable, Codable {
        public let tier: Tier
        public let reason: String
    }

    public enum Outcome: Sendable, Hashable {
        case merge(Match)
        /// Provably different (conflicting Canvas assignment ids).
        case refused(String)
        case noMatch
    }

    // MARK: Tunables (one place)

    /// How far apart two due dates may be for a title match. 48 h, wider than
    /// the deduplicator's 26 h fuzzy window, because here the titles must be
    /// equal or a prefix (far stricter than Jaccard 0.6) and Gradescope and
    /// Canvas routinely disagree by a day when one stores 23:59 local and the
    /// other midnight UTC.
    public static let titleDueWindow: TimeInterval = 48 * 3600

    /// Words in the tail of a prefix match that make the longer title a
    /// different deliverable ("Lab 3" vs "Lab 3 Report"). Any one refuses.
    static let distinguishingTailWords: Set<String> = [
        "report", "reports", "writeup", "solution", "solutions", "grade", "grades",
        "regrade", "part", "parts", "pt", "review", "prep", "practice", "retake",
        "makeup", "extension", "resubmission", "reflection", "survey", "response",
        "quiz", "exam", "midterm", "final", "test", "hw", "lab", "project",
        "assignment", "essay", "paper", "reading", "discussion", "draft", "presentation",
    ]

    // MARK: Pairwise

    public static func match(_ a: WorkItemIdentity, _ b: WorkItemIdentity) -> Outcome {
        if canvasIDsConflict(a, b) {
            return .refused("different Canvas assignment ids")
        }
        if let shared = a.canonicalAliases.intersection(b.canonicalAliases).sorted(by: { $0.stableString < $1.stableString }).first {
            return .merge(Match(tier: .deterministic, reason: "shared alias \(shared.stableString)"))
        }
        if let reason = titleAndDateReason(a, b) {
            return .merge(Match(tier: .titleAndDate, reason: reason))
        }
        return .noMatch
    }

    /// True when both items name exactly one Canvas assignment each and they
    /// differ. An item that names several is contradicting itself and gives
    /// no opinion; nil on either side is "no opinion", never a conflict.
    public static func canvasIDsConflict(_ a: WorkItemIdentity, _ b: WorkItemIdentity) -> Bool {
        let idsA = a.canvasAssignmentIDs, idsB = b.canvasAssignmentIDs
        guard idsA.count == 1, idsB.count == 1 else { return false }
        return idsA != idsB
    }

    // MARK: Tier 2

    static func titleAndDateReason(_ a: WorkItemIdentity, _ b: WorkItemIdentity) -> String? {
        let ta = comparableTokens(a.title), tb = comparableTokens(b.title)
        guard !ta.isEmpty, !tb.isEmpty else { return nil }

        switch (a.dueAt, b.dueAt) {
        case let (x?, y?):
            guard abs(x.timeIntervalSince(y)) <= titleDueWindow else { return nil }
        case (nil, nil):
            break
        default:
            // One dated, one not: nothing to corroborate the title with.
            return nil
        }

        if ta == tb { return "equal titles, dates agree" }
        let (short, long) = ta.count <= tb.count ? (ta, tb) : (tb, ta)
        guard long.starts(with: short), short.contains(where: { Int($0) != nil }) else { return nil }
        let tail = long.dropFirst(short.count)
        guard !tail.contains(where: { Int($0) != nil || distinguishingTailWords.contains($0) }) else { return nil }
        return "title prefix, dates agree"
    }

    private static let numberWords: [String: String] = [
        "one": "1", "two": "2", "three": "3", "four": "4", "five": "5", "six": "6",
        "seven": "7", "eight": "8", "nine": "9", "ten": "10", "eleven": "11",
        "twelve": "12", "thirteen": "13", "fourteen": "14", "fifteen": "15",
    ]
    /// Unambiguous romans. "i", "v", "x" are also words/letters, so they only
    /// count right after a noun that takes a number.
    private static let romans: [String: String] = [
        "ii": "2", "iii": "3", "iv": "4", "vi": "6", "vii": "7", "viii": "8", "ix": "9",
    ]
    private static let ambiguousRomans: [String: String] = ["i": "1", "v": "5", "x": "10"]
    private static let numberedNouns: Set<String> = [
        "hw", "lab", "quiz", "exam", "midterm", "project", "assignment", "chapter",
        "ch", "week", "part", "reading", "milestone", "test", "essay", "paper",
    ]

    /// `AssignmentDeduplicator.normalize` (case, punctuation, whitespace,
    /// hw/homework, "03" == "3") plus number words and romans, minus a
    /// leading or trailing course code ("CIS 1210 HW 3", "HW 3 [CIS 1210]").
    static func comparableTokens(_ title: String) -> [String] {
        var tokens: [String] = []
        for token in AssignmentDeduplicator.normalize(title) {
            if let n = numberWords[token] ?? romans[token] {
                tokens.append(n)
            } else if let n = ambiguousRomans[token], let last = tokens.last, numberedNouns.contains(last) {
                tokens.append(n)
            } else {
                tokens.append(token)
            }
        }
        // A course code is 2-5 letters then 3-4 digits. Work nouns are never
        // codes, and stripping must leave something behind.
        func isCode(_ letters: String, _ digits: String) -> Bool {
            letters.count >= 2 && letters.count <= 5 && letters.allSatisfy(\.isLetter)
                && !numberedNouns.contains(letters)
                && digits.count >= 3 && digits.count <= 4 && digits.allSatisfy(\.isNumber)
        }
        if tokens.count > 2, isCode(tokens[0], tokens[1]) { tokens.removeFirst(2) }
        if tokens.count > 2, isCode(tokens[tokens.count - 2], tokens[tokens.count - 1]) { tokens.removeLast(2) }
        return tokens
    }

    // MARK: Tier 3

    /// Resolves a model-supplied `target` against a fixed candidate index.
    /// The target must name a candidate exactly: its `ref`, or the stable
    /// string of one of its aliases. Free text is never searched, and a
    /// target that names more than one candidate (or none) resolves to nil
    /// rather than the first: an ambiguous pointer is a pointer at nothing.
    /// The Canvas "Quiz 3" that the instructor calls "Quiz 2 for Chap. 22"
    /// is the case this exists for: no title rule can join them, but a fact
    /// whose target is that item's ref can.
    public static func resolve(target: String, among candidates: [WorkItemIdentity]) -> WorkItemIdentity? {
        let alias = WorkItemAlias(stableString: target)?.canonical
        let hits = candidates.filter { candidate in
            candidate.ref == target || (alias.map { candidate.canonicalAliases.contains($0) } ?? false)
        }
        return hits.count == 1 ? hits[0] : nil
    }

    /// Tier 3 as a pairwise result: `fact` merges onto whichever candidate its
    /// target names, unless the hard rule forbids it.
    public static func match(factTarget target: String, fact: WorkItemIdentity, among candidates: [WorkItemIdentity]) -> Outcome {
        guard let hit = resolve(target: target, among: candidates) else { return .noMatch }
        if canvasIDsConflict(fact, hit) { return .refused("different Canvas assignment ids") }
        return .merge(Match(tier: .modelTarget, reason: "fact target \(target)"))
    }
}
