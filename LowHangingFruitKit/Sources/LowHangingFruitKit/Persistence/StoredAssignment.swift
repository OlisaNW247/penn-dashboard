import Foundation
import SwiftData

/// The durable, on-disk record of an assignment the app has ever seen from a
/// feed. This is the ledger row behind `AssignmentStore`: the app is no longer a
/// live view of "whatever the last fetch returned" but a database that fetches
/// *edit*. That's what stops a rolling Canvas feed (or one flaky sync) from
/// making previously-seen assignments — and completed work — disappear.
///
/// Keyed by `id` (`"source:sourceID"`, identical to `Assignment.id`) so a row
/// maps 1:1 to the value-type `Assignment` the rest of the app consumes. The
/// lifecycle fields (`firstSeen` / `lastSeenInFeed` / `isGoneFromFeed`) are the
/// point of the whole thing: an item leaving the feed is *recorded*, never
/// silently dropped.
@Model
public final class StoredAssignment {
    /// `"source:sourceID"` — the same stable identity as `Assignment.id`.
    @Attribute(.unique) public var id: String

    // MARK: Feed-supplied identity & display (refreshed on every sync)
    public var sourceRaw: String
    public var sourceID: String
    public var kindRaw: String
    public var course: String
    public var title: String
    public var dueAt: Date?
    public var urlString: String?
    /// Persisted as the `YYYYTT` term code (see `Term`); nil when unknown.
    public var termYear: Int?
    public var termSeasonRaw: Int?

    // MARK: Lifecycle — the heart of "don't lose things"
    /// First time this item was ever seen in any feed. Never overwritten.
    public var firstSeen: Date
    /// Refreshed to "now" on every sync the item is present in.
    public var lastSeenInFeed: Date
    /// Set true once a sync no longer returns it. The item is retained (visible
    /// until the deliberate aging rule fires), not deleted — a professor moving
    /// or briefly hiding an item, or a partial fetch, must never lose it.
    public var isGoneFromFeed: Bool

    /// When the user ticked this item off (or its cross-platform counterpart).
    /// Mirrors `AppState.completionDates` onto the ledger for one reason: a
    /// finished assignment is what the Done tab exists to remember, so aging
    /// must never reclaim it. Nil means not completed.
    public var completedAt: Date?

    // MARK: Submission / grade truth (persisted, not recomputed from scratch)
    /// Canvas's own submission signal (from Grade Watcher's `workflow_state`),
    /// stored so it survives launches instead of being blank until a live grade
    /// refresh lands. Keyed for the dashboard join via `canvasAssignmentID`.
    public var canvasSubmitted: Bool
    /// Gradescope's scraped submitted status.
    public var gradescopeSubmitted: Bool
    public var scoreEarned: Double?
    public var scoreMax: Double?

    // MARK: Cross-platform pairing (persisted so it survives a later date move)
    /// The `Assignment.id` of a confirmed counterpart on the other platform.
    /// Reserved for persisted-pairing dedup; nil until a pairing is confirmed.
    public var linkedID: String?
    public var pairingConfirmedAt: Date?

    public init(
        id: String,
        sourceRaw: String,
        sourceID: String,
        kindRaw: String,
        course: String,
        title: String,
        dueAt: Date?,
        urlString: String?,
        termYear: Int?,
        termSeasonRaw: Int?,
        firstSeen: Date,
        lastSeenInFeed: Date,
        isGoneFromFeed: Bool = false,
        completedAt: Date? = nil,
        canvasSubmitted: Bool = false,
        gradescopeSubmitted: Bool = false,
        scoreEarned: Double? = nil,
        scoreMax: Double? = nil,
        linkedID: String? = nil,
        pairingConfirmedAt: Date? = nil
    ) {
        self.id = id
        self.sourceRaw = sourceRaw
        self.sourceID = sourceID
        self.kindRaw = kindRaw
        self.course = course
        self.title = title
        self.dueAt = dueAt
        self.urlString = urlString
        self.termYear = termYear
        self.termSeasonRaw = termSeasonRaw
        self.firstSeen = firstSeen
        self.lastSeenInFeed = lastSeenInFeed
        self.isGoneFromFeed = isGoneFromFeed
        self.completedAt = completedAt
        self.canvasSubmitted = canvasSubmitted
        self.gradescopeSubmitted = gradescopeSubmitted
        self.scoreEarned = scoreEarned
        self.scoreMax = scoreMax
        self.linkedID = linkedID
        self.pairingConfirmedAt = pairingConfirmedAt
    }
}

// MARK: - Mapping to/from the value-type Assignment

extension StoredAssignment {
    /// Rebuild the value-type the rest of the app consumes. `submitted` reflects
    /// the row's own source (Gradescope carries a real flag; Canvas's ICS
    /// `submitted` is always false and its truth flows via the separate
    /// `submittedCanvasAssignmentIDs` side-channel, so it isn't folded in here).
    public var assignment: Assignment {
        let source = Assignment.Source(rawValue: sourceRaw) ?? .canvas
        let term: Term? = {
            guard let termYear, let termSeasonRaw,
                  let season = Term.Season(rawValue: termSeasonRaw) else { return nil }
            return Term(year: termYear, season: season)
        }()
        return Assignment(
            source: source,
            sourceID: sourceID,
            kind: Assignment.Kind(rawValue: kindRaw) ?? .other,
            course: course,
            title: title,
            dueAt: dueAt,
            url: urlString.flatMap(URL.init(string:)),
            term: term,
            submitted: source == .gradescope ? gradescopeSubmitted : false,
            scoreEarned: scoreEarned,
            scoreMax: scoreMax,
            linkedID: linkedID
        )
    }

    /// Work the student actually finished — ticked off, or reported turned in by
    /// either platform. The ledger treats this as archive material: it is exempt
    /// from aging, because losing a completed assignment silently rewrites the
    /// student's own record of what they did.
    var isFinished: Bool {
        completedAt != nil || canvasSubmitted || gradescopeSubmitted
    }

    /// The Canvas assignment id this row joins to Grade Watcher's submission
    /// side-channel on — the same derivation the value type uses, so the two
    /// can't drift apart.
    var canvasAssignmentID: String? { assignment.canvasAssignmentID }

    /// Copies the feed-supplied fields of `assignment` onto this row, preserving
    /// everything the ledger owns (`firstSeen`, submission flags, pairing). Used
    /// on the upsert path when an item is seen again.
    func refresh(from assignment: Assignment, now: Date) {
        sourceRaw = assignment.source.rawValue
        sourceID = assignment.sourceID
        kindRaw = assignment.kind.rawValue
        course = assignment.course
        title = assignment.title
        dueAt = assignment.dueAt
        urlString = assignment.url?.absoluteString
        termYear = assignment.term?.year
        termSeasonRaw = assignment.term?.season.rawValue
        lastSeenInFeed = now
        isGoneFromFeed = false
        // Gradescope's submitted flag rides along with its feed items; fold it in
        // so a scraped completion is retained.
        if assignment.source == .gradescope {
            gradescopeSubmitted = assignment.submitted
        }
        if let earned = assignment.scoreEarned { scoreEarned = earned }
        if let max = assignment.scoreMax { scoreMax = max }
    }

    /// A fresh ledger row for a never-before-seen assignment.
    static func make(from assignment: Assignment, now: Date) -> StoredAssignment {
        StoredAssignment(
            id: assignment.id,
            sourceRaw: assignment.source.rawValue,
            sourceID: assignment.sourceID,
            kindRaw: assignment.kind.rawValue,
            course: assignment.course,
            title: assignment.title,
            dueAt: assignment.dueAt,
            urlString: assignment.url?.absoluteString,
            termYear: assignment.term?.year,
            termSeasonRaw: assignment.term?.season.rawValue,
            firstSeen: now,
            lastSeenInFeed: now,
            gradescopeSubmitted: assignment.source == .gradescope ? assignment.submitted : false,
            scoreEarned: assignment.scoreEarned,
            scoreMax: assignment.scoreMax,
            linkedID: assignment.linkedID
        )
    }
}
