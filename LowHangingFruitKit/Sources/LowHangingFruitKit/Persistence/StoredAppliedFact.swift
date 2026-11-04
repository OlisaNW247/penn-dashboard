import Foundation
import SwiftData

/// One fact the server extracted from a pooled course document, as this phone
/// received it, plus what this phone did with it and what the student said.
///
/// The facts themselves are course-level and re-fetchable (the server keeps
/// them), but the *student's verdict on them* (`studentOverrideRaw`) and the
/// record of what was applied are not, so this lives in a SwiftData store of
/// its own rather than in a cache file (see `AppliedFactStore` for why not the
/// ledger's schema). Nothing here is personal until the student overrides one,
/// and it never leaves the phone.
///
/// Every property is defaulted, as CloudKit requires of a syncable model and as
/// the other stored types do. Enum-valued fields are stored as raw strings so
/// a case added later never makes an old row undecodable.
@Model
public final class StoredAppliedFact {
    /// `"<documentID>#<seq>"`, see `AppliedFact.id`. The upsert key.
    public var factID: String = ""
    public var seq: Int = 0
    /// Canvas numeric course id.
    public var courseID: String = ""
    public var documentID: String = ""
    public var contentHash: String = ""
    public var typeRaw: String = ""
    public var targetSourceID: String?
    /// The ledger `Assignment.id` it was applied to; nil when unresolved.
    public var resolvedItemID: String?
    public var title: String?
    public var dueAt: Date?
    public var kindRaw: String?
    public var quote: String = ""
    public var confidenceRaw: String = ""
    public var postedAt: Date?
    public var receivedAt: Date = Date.distantPast
    public var appliedAt: Date?
    public var supersededBySeq: Int?
    /// `FactOverride.rawValue`; "none" until the student weighs in.
    public var studentOverrideRaw: String = "none"
    public var overrideAt: Date?

    public init(fact: AppliedFact) {
        self.factID = fact.id
        self.seq = fact.seq
        self.courseID = fact.courseID
        self.documentID = fact.documentID
        self.contentHash = fact.contentHash
        self.typeRaw = fact.type.rawValue
        self.targetSourceID = fact.target
        self.resolvedItemID = fact.resolvedItemID
        self.title = fact.title
        self.dueAt = fact.dueAt
        self.kindRaw = fact.kind?.rawValue
        self.quote = fact.quote
        self.confidenceRaw = fact.confidence.rawValue
        self.postedAt = fact.postedAt
        self.receivedAt = fact.receivedAt
        self.appliedAt = fact.appliedAt
        self.supersededBySeq = fact.supersededBySeq
        self.studentOverrideRaw = fact.studentOverride.rawValue
        self.overrideAt = fact.overrideAt
    }

    /// The immutable snapshot, or nil for a row whose type or confidence this
    /// build cannot name (written by a newer build): skipped, not guessed at.
    var snapshot: AppliedFact? {
        guard let type = CourseFactWire.FactType(rawValue: typeRaw),
              let confidence = CourseFactWire.Confidence(rawValue: confidenceRaw)
        else { return nil }
        return AppliedFact(
            id: factID, seq: seq, courseID: courseID, documentID: documentID,
            contentHash: contentHash, type: type, target: targetSourceID, title: title,
            dueAt: dueAt, kind: kindRaw.flatMap(CourseFactWire.Kind.init(rawValue:)),
            quote: quote, confidence: confidence, postedAt: postedAt, receivedAt: receivedAt,
            resolvedItemID: resolvedItemID, appliedAt: appliedAt, supersededBySeq: supersededBySeq,
            studentOverride: FactOverride(rawValue: studentOverrideRaw) ?? .none,
            overrideAt: overrideAt
        )
    }
}
