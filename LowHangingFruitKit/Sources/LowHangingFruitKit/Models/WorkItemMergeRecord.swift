import Foundation

/// Provenance for one merge: which two identities were joined, by which tier,
/// why, and when. Storing both identities whole is what makes the merge
/// reversible: `split()` returns them exactly as they were, so undoing a wrong
/// merge needs no re-derivation from sources that may have changed since.
/// `mergedAt` is injected by the caller; this type never reads a clock.
public struct WorkItemMergeRecord: Sendable, Hashable, Codable {
    public let first: WorkItemIdentity
    public let second: WorkItemIdentity
    public let tier: WorkItemMatcher.Tier
    public let reason: String
    public let mergedAt: Date

    public init(first: WorkItemIdentity, second: WorkItemIdentity, tier: WorkItemMatcher.Tier, reason: String, mergedAt: Date) {
        self.first = first
        self.second = second
        self.tier = tier
        self.reason = reason
        self.mergedAt = mergedAt
    }

    public init(first: WorkItemIdentity, second: WorkItemIdentity, match: WorkItemMatcher.Match, mergedAt: Date) {
        self.init(first: first, second: second, tier: match.tier, reason: match.reason, mergedAt: mergedAt)
    }

    /// The reverse of the merge: the two identities as they went in.
    public func split() -> (WorkItemIdentity, WorkItemIdentity) { (first, second) }

    /// Every alias the merged item answers to.
    public var mergedAliases: Set<WorkItemAlias> { first.aliases.union(second.aliases) }
}
