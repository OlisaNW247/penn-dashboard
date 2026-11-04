import Foundation

/// The student's say on one fact. Stored as a raw string on the row so a
/// future case does not make an old row unreadable (an unknown raw value
/// reads as `.none`, i.e. "the student has not weighed in").
public enum FactOverride: String, Sendable, Codable, Hashable, CaseIterable {
    case none
    /// The student said "yes, that is right". Applied even where the
    /// engine would hold back (a medium-confidence cancel, a date the
    /// student had edited by hand).
    case confirmed
    /// The student said "no". The fact is never applied again, and a newer
    /// fact does not resurrect it: a rejection is on the fact, not the item.
    case rejected
}

/// An immutable, `Sendable` snapshot of one stored fact: what the precedence
/// engine reads and what the store hands the UI. The SwiftData row
/// (`StoredAppliedFact`) is main-actor-bound and mutable; a snapshot lets the
/// engine run `nonisolated`, off the main actor, on a plain value (the same
/// reason `Assignment` is a struct and `StoredAssignment` is not).
public struct AppliedFact: Sendable, Hashable, Identifiable {
    /// `"<documentID>#<seq>"`. The server's `seq` is globally unique, so it
    /// alone would identify a fact; the document id is prefixed so a fact is
    /// traceable by eye, and so a server rebuilt from scratch (its identity
    /// column restarting at 1) cannot collide with an old row of a different
    /// document. The wrong choice would be a random UUID minted on receipt:
    /// the same fact re-served on a re-read would then insert a second row.
    public let id: String
    public let seq: Int
    public let courseID: String
    public let documentID: String
    public let contentHash: String
    public let type: CourseFactWire.FactType
    public let target: String?
    public let title: String?
    public let dueAt: Date?
    public let kind: CourseFactWire.Kind?
    public let quote: String
    public let confidence: CourseFactWire.Confidence
    public let postedAt: Date?
    public let receivedAt: Date

    /// The ledger `Assignment.id` the fact was applied to; nil when it was
    /// not resolved or not applied.
    public let resolvedItemID: String?
    public let appliedAt: Date?
    /// The `seq` of the newer fact that replaced this one, if any.
    public let supersededBySeq: Int?
    public let studentOverride: FactOverride
    public let overrideAt: Date?

    public init(
        id: String? = nil,
        seq: Int,
        courseID: String,
        documentID: String,
        contentHash: String,
        type: CourseFactWire.FactType,
        target: String? = nil,
        title: String? = nil,
        dueAt: Date? = nil,
        kind: CourseFactWire.Kind? = nil,
        quote: String = "",
        confidence: CourseFactWire.Confidence = .high,
        postedAt: Date? = nil,
        receivedAt: Date = Date.distantPast,
        resolvedItemID: String? = nil,
        appliedAt: Date? = nil,
        supersededBySeq: Int? = nil,
        studentOverride: FactOverride = .none,
        overrideAt: Date? = nil
    ) {
        self.id = id ?? Self.factID(documentID: documentID, seq: seq)
        self.seq = seq
        self.courseID = courseID
        self.documentID = documentID
        self.contentHash = contentHash
        self.type = type
        self.target = target
        self.title = title
        self.dueAt = dueAt
        self.kind = kind
        self.quote = quote
        self.confidence = confidence
        self.postedAt = postedAt
        self.receivedAt = receivedAt
        self.resolvedItemID = resolvedItemID
        self.appliedAt = appliedAt
        self.supersededBySeq = supersededBySeq
        self.studentOverride = studentOverride
        self.overrideAt = overrideAt
    }

    public init(wire: CourseFactWire, receivedAt: Date) {
        self.init(
            seq: wire.seq, courseID: wire.courseID, documentID: wire.documentID,
            contentHash: wire.contentHash, type: wire.type, target: wire.target,
            title: wire.title, dueAt: wire.dueAt, kind: wire.kind, quote: wire.quote,
            confidence: wire.confidence, postedAt: wire.postedAt, receivedAt: receivedAt
        )
    }

    nonisolated public static func factID(documentID: String, seq: Int) -> String {
        "\(documentID)#\(seq)"
    }
}
