import Foundation

// The precedence engine: given the facts the server extracted from pooled
// course documents and the student's current ledger, decide what each fact may
// change on screen. Pure: no store, no clock (`now` is passed in and only
// stamped on the result), no `UserDefaults`, no SwiftData. The caller writes
// the result back (`AppliedFactStore.record(_:now:)`) and upserts `newTasks`.
//
// docs/DAY_PLANNER_RESEARCH_2026-11-03.md section 2.3 is the spec. The
// invariant above all of it (CLAUDE.md, "The ledger is the point") is that
// nothing the student did is ever lost, so the output type simply has no way
// to say "complete this" or "delete that": the strongest thing a fact can do
// is hide a row from the todo list and tag it. A wrong fact is then a
// reversible annoyance, never lost work.

// MARK: - Input

/// One ledger row plus the state the rules need and an `Assignment` does not
/// carry (completion and hand edits live in the ledger beside it).
public struct FactItem: Sendable, Hashable {
    public let assignment: Assignment
    /// The student marked it done.
    public let userCompleted: Bool
    /// A due date the student typed in by hand ("edit date"), if any.
    public let editedDueDate: Date?
    /// Canvas no longer lists it (`isGoneFromFeed`).
    public let isGoneFromFeed: Bool
    /// What Canvas itself currently says the due date is. Not necessarily
    /// `assignment.dueAt`, which may already be the student's edit or an
    /// earlier fact's reschedule; the caller supplies the source's own value.
    public let canvasDueAt: Date?
    /// Canvas itself stated this row's date for this student (a section
    /// `all_dates` override). That is Canvas's own statement, so a post that
    /// disagrees with it is listed for review, never applied.
    public let hasStructuredDueDate: Bool

    public init(assignment: Assignment, userCompleted: Bool, editedDueDate: Date?, isGoneFromFeed: Bool, canvasDueAt: Date?, hasStructuredDueDate: Bool = false) {
        self.hasStructuredDueDate = hasStructuredDueDate
        self.assignment = assignment
        self.userCompleted = userCompleted
        self.editedDueDate = editedDueDate
        self.isGoneFromFeed = isGoneFromFeed
        self.canvasDueAt = canvasDueAt
    }

    /// An untouched row: not done, not edited, still in the feed, and its
    /// own `dueAt` is Canvas's.
    public init(_ assignment: Assignment) {
        self.init(assignment: assignment, userCompleted: false, editedDueDate: nil, isGoneFromFeed: false, canvasDueAt: assignment.dueAt)
    }
}

// MARK: - Output

public enum FactRedundantReason: Sendable, Hashable {
    /// Canvas already says what the fact says.
    case appliedByCanvas
    /// A newer fact about the same thing replaced it (the newer fact's seq).
    case supersededBySeq(Int)
    /// The student's own action outranks it (a completion, a hand-edited
    /// date, or rejecting the fact).
    case studentOverride
}

public enum FactReviewReason: Sendable, Hashable {
    /// The extractor itself said "this is in doubt" (`needs_review`).
    case flaggedByExtractor
    /// The target names no item in this course, or more than one.
    case unresolvedTarget
    /// A `medium` confidence cancel: a wrong one hides real work.
    case mediumConfidenceCancel
    /// A reschedule or new task that carries nothing usable (no date, no title).
    case missingDetail
    /// A reschedule that disagrees with the date Canvas itself gave this student.
    case disagreesWithCanvasDate
    /// The fact's Canvas course is not one this phone knows by code.
    case unknownCourse
}

public struct FactEffects: Sendable, Equatable {
    public struct Cancelled: Sendable, Hashable { public let by: String }
    public struct Rescheduled: Sendable, Hashable {
        public let to: Date
        public let from: Date?
        public let by: String
    }
    public struct ScopeChanged: Sendable, Hashable {
        public let note: String
        public let by: String
    }
    public struct Note: Sendable, Hashable {
        public let text: String
        public let by: String
    }

    /// Everything that applies to one existing row. Each slot is independent:
    /// an item can be rescheduled and carry a note.
    public struct ItemEffects: Sendable, Hashable {
        /// Hide from todo and tag in all/prev. Never completes, never deletes.
        public var cancelled: Cancelled?
        public var rescheduled: Rescheduled?
        public var scopeChanged: ScopeChanged?
        public var notes: [Note] = []

        public var isEmpty: Bool {
            cancelled == nil && rescheduled == nil && scopeChanged == nil && notes.isEmpty
        }
    }

    public struct NewTask: Sendable, Hashable {
        public let factID: String
        /// A row to upsert: `source: .canvasAnnouncement`, `sourceID` of the
        /// form `fact-<documentID>-<seq>`. Never `submitted`.
        public let assignment: Assignment
    }

    public struct Review: Sendable, Hashable {
        public let fact: AppliedFact
        public let reason: FactReviewReason
    }

    public struct Redundant: Sendable, Hashable {
        public let factID: String
        public let reason: FactRedundantReason
    }

    /// Per `Assignment.id`.
    public var items: [String: ItemEffects] = [:]
    public var newTasks: [NewTask] = []
    /// Listed to the student, never applied.
    public var needsReview: [Review] = []
    public var redundant: [Redundant] = []
    /// Ids of the facts that changed something (an item effect or a new task).
    public var applied: Set<String> = []
    /// fact id to the `Assignment.id` its target resolved to, for every fact
    /// that resolved (applied or not).
    public var resolvedItems: [String: String] = [:]
    public var evaluatedAt: Date

    public init(evaluatedAt: Date) { self.evaluatedAt = evaluatedAt }
}

// MARK: - Engine

public enum FactApplication {
    /// Two due dates this close are the same date. Canvas stores seconds,
    /// the model's instant came from prose and was rounded to the minute.
    nonisolated public static let sameDateTolerance: TimeInterval = 60

    /// - Parameters:
    ///   - facts: the facts to consider, any order, any course.
    ///   - items: the current ledger rows with their state.
    ///   - courseCodeByID: Canvas numeric course id to the `Assignment.course`
    ///     code. A fact is resolved only among rows of its own course.
    ///   - documentURLs: source document id to its Canvas URL, so a new task
    ///     can link back to the post. Absent is fine.
    nonisolated public static func evaluate(
        facts: [AppliedFact],
        items: [FactItem],
        courseCodeByID: [String: String],
        documentURLs: [String: URL] = [:],
        now: Date
    ) -> FactEffects {
        var out = FactEffects(evaluatedAt: now)

        // Rule 1a: a fact the student rejected is gone before anything else
        // looks at it, and it is dropped BEFORE supersession so that it can
        // neither apply nor suppress an older fact. (Rejecting a newer fact
        // means "that one is wrong", not "so the older one must be too": the
        // older fact stays eligible. The wrong order would let a rejected
        // reschedule silently retire the earlier, correct one.)
        var live: [AppliedFact] = []
        for fact in facts {
            if fact.studentOverride == .rejected {
                out.redundant.append(.init(factID: fact.id, reason: .studentOverride))
            } else {
                live.append(fact)
            }
        }

        // Rule 3: newest per (target, type) wins. Computed over everything
        // still live, NOT only over what would otherwise apply. The tempting
        // shortcut is to drop the facts rules 1b/2 would discard and then
        // pick the newest of the rest, but then "reschedule to Nov 5" (old)
        // would resurface the moment "reschedule to Nov 8" (new) turned out
        // to agree with Canvas, and the screen would show the stale date.
        var winners: [AppliedFact] = []
        for group in Dictionary(grouping: live, by: supersessionKey).values {
            let ordered = group.sorted(by: isOlder)
            guard let newest = ordered.last else { continue }
            winners.append(newest)
            for older in ordered.dropLast() {
                out.redundant.append(.init(factID: older.id, reason: .supersededBySeq(newest.seq)))
            }
        }
        winners.sort(by: isOlder) // oldest first, so a newer fact overwrites an older one in a slot

        var owner: [String: AppliedFact] = [:] // "<itemID>|<type>" to the fact holding the slot

        for fact in winners {
            let confirmed = fact.studentOverride == .confirmed

            switch fact.type {
            case .needsReview:
                // Never applied, whatever the confidence: the extractor said it
                // is unsure, and a student's "confirm" has nothing to apply.
                out.needsReview.append(.init(fact: fact, reason: .flaggedByExtractor))

            case .newTask:
                applyNewTask(fact, confirmed: confirmed, items: items, courseCodeByID: courseCodeByID, documentURLs: documentURLs, into: &out)

            case .cancel, .reschedule, .scopeChange, .note:
                guard let code = courseCodeByID[fact.courseID] else {
                    out.needsReview.append(.init(fact: fact, reason: .unknownCourse))
                    continue
                }
                // Rule 5: resolve among this course's rows only. An
                // unresolvable pointer is listed for the student, never
                // guessed at; a wrong guess would hide or move someone
                // else's work. (Free-text title search is exactly the
                // tempting wrong fix, and Tier 3 refuses it by design.)
                let courseItems = items.filter { $0.assignment.course == code }
                guard let item = resolveTarget(fact, among: courseItems) else {
                    out.needsReview.append(.init(fact: fact, reason: .unresolvedTarget))
                    continue
                }
                let itemID = item.assignment.id
                out.resolvedItems[fact.id] = itemID

                // Rule 1b: the student wins. Something they did to the row
                // (finished it, typed their own date) is a stronger signal
                // than a sentence in a post, so the fact stands down. Only
                // an explicit "confirm" lifts this.
                if !confirmed, item.userCompleted || item.editedDueDate != nil {
                    out.redundant.append(.init(factID: fact.id, reason: .studentOverride))
                    continue
                }

                // The bench's gate: a medium-confidence cancel is wrong often
                // enough that hiding real work on its say-so is not worth it.
                // High applies; medium waits for the student.
                if fact.type == .cancel, fact.confidence == .medium, !confirmed {
                    out.needsReview.append(.init(fact: fact, reason: .mediumConfidenceCancel))
                    continue
                }

                // Rule 2: Canvas wins over prose where they already agree.
                switch fact.type {
                case .cancel where item.isGoneFromFeed:
                    // Canvas has already dropped it; the post is only a
                    // redundant confirmation. Not applied, so nothing is
                    // hidden twice.
                    out.redundant.append(.init(factID: fact.id, reason: .appliedByCanvas))
                    continue
                case .reschedule:
                    guard let to = fact.dueAt else {
                        out.needsReview.append(.init(fact: fact, reason: .missingDetail))
                        continue
                    }
                    if let canvas = item.canvasDueAt, abs(canvas.timeIntervalSince(to)) <= sameDateTolerance {
                        out.redundant.append(.init(factID: fact.id, reason: .appliedByCanvas))
                        continue
                    }
                    // Canvas's structured date beats prose: a differing post
                    // waits for the student (a confirm lifts it).
                    if item.hasStructuredDueDate, !confirmed {
                        out.needsReview.append(.init(fact: fact, reason: .disagreesWithCanvasDate))
                        continue
                    }
                default:
                    break
                }

                // Rule 4 lives in the types: the only things written here are
                // a hide-and-tag, a displayed date, and text. No completion
                // and no deletion can be expressed in `ItemEffects`.
                let slot = "\(itemID)|\(fact.type.rawValue)\(fact.type == .note ? "|\(fact.id)" : "")"
                if let previous = owner[slot] {
                    // Two winners resolved to one row through different
                    // target spellings; the newer (iterated later) holds it.
                    out.applied.remove(previous.id)
                    out.redundant.append(.init(factID: previous.id, reason: .supersededBySeq(fact.seq)))
                }
                owner[slot] = fact

                var effects = out.items[itemID] ?? FactEffects.ItemEffects()
                switch fact.type {
                case .cancel:
                    effects.cancelled = .init(by: fact.id)
                case .reschedule:
                    effects.rescheduled = .init(to: fact.dueAt ?? now, from: item.canvasDueAt ?? item.assignment.dueAt, by: fact.id)
                case .scopeChange:
                    effects.scopeChanged = .init(note: noteText(fact), by: fact.id)
                case .note:
                    effects.notes.append(.init(text: noteText(fact), by: fact.id))
                default:
                    break
                }
                out.items[itemID] = effects
                out.applied.insert(fact.id)
            }
        }

        out.newTasks.sort { $0.assignment.id < $1.assignment.id }
        out.needsReview.sort { $0.fact.seq < $1.fact.seq }
        out.redundant.sort { $0.factID < $1.factID }
        return out
    }

    // MARK: new_task

    nonisolated private static func applyNewTask(
        _ fact: AppliedFact,
        confirmed: Bool,
        items: [FactItem],
        courseCodeByID: [String: String],
        documentURLs: [String: URL],
        into out: inout FactEffects
    ) {
        guard let code = courseCodeByID[fact.courseID] else {
            out.needsReview.append(.init(fact: fact, reason: .unknownCourse))
            return
        }
        guard let title = fact.title?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty else {
            out.needsReview.append(.init(fact: fact, reason: .missingDetail))
            return
        }
        let sourceID = taskSourceID(documentID: fact.documentID, seq: fact.seq)

        // Rule 2 for new work: if the course already lists this thing, Canvas
        // wins and the post adds nothing. Compared through the matcher's
        // title-and-date tier so "HW 3" and "Homework 3" collide. The row
        // this very fact produced last time is excluded by sourceID, or the
        // second evaluation would call its own output a duplicate and the
        // task would vanish from the list.
        if !confirmed {
            let identity = WorkItemIdentity(ref: "fact:\(fact.id)", aliases: [.fact(fact.id)], title: title, dueAt: fact.dueAt, course: code)
            let duplicate = items.contains { item in
                guard item.assignment.course == code, !item.isGoneFromFeed, item.assignment.sourceID != sourceID else { return false }
                if case .merge = WorkItemMatcher.match(identity, WorkItemIdentity.from(item.assignment)) { return true }
                return false
            }
            if duplicate {
                out.redundant.append(.init(factID: fact.id, reason: .appliedByCanvas))
                return
            }
        }

        // `preparation` and an unstated kind are not something to hand in, so
        // they are `.other`: `.assignment` would make them count as
        // submittable work and show up under "items with nothing to submit"
        // filters the wrong way round.
        let kind: Assignment.Kind
        switch fact.kind {
        case .submission: kind = .assignment
        case .event: kind = .event
        case .preparation, .none: kind = .other
        }
        let row = Assignment(
            source: .canvasAnnouncement,
            sourceID: sourceID,
            kind: kind,
            course: code,
            title: title,
            dueAt: fact.dueAt,
            url: documentURLs[fact.documentID]
        )
        out.newTasks.append(.init(factID: fact.id, assignment: row))
        out.applied.insert(fact.id)
        out.resolvedItems[fact.id] = row.id
    }

    /// The ledger `sourceID` of the task a fact created. Prefixed `fact-` and
    /// not `announcement-`/`ed-`/`syllabus-`, so no existing parser mistakes it
    /// for one of those finds, while it stays a `.canvasAnnouncement` row and
    /// so keeps every rule written for announcement-derived rows (hidden
    /// tasks, the NEW tag, "delete if the extraction was wrong"). Stable per
    /// (document, seq): re-serving the same fact upserts the same row.
    nonisolated public static func taskSourceID(documentID: String, seq: Int) -> String {
        "fact-\(documentID)-\(seq)"
    }

    // MARK: Helpers

    nonisolated private static func noteText(_ fact: AppliedFact) -> String {
        let title = fact.title?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return title.isEmpty ? fact.quote : title
    }

    /// Oldest first: by when it was said, then by `seq`. A fact with no
    /// `postedAt` sorts as oldest of all, so a dated fact beats an undated one
    /// and ties fall back to extraction order, then to fact id.
    nonisolated private static func isOlder(_ a: AppliedFact, _ b: AppliedFact) -> Bool {
        let pa = a.postedAt ?? .distantPast, pb = b.postedAt ?? .distantPast
        if pa != pb { return pa < pb }
        if a.seq != b.seq { return a.seq < b.seq }
        // An exact tie (cross-listed sites can repeat a seq) is broken by id,
        // or the winner would follow Dictionary iteration order.
        return a.id < b.id
    }

    /// What "the same statement, said again" means per type. A target-less
    /// targeted fact, and a `new_task`, need a different key: grouping every
    /// target-less cancel together would let one retire the rest, and two
    /// tasks with no target are not the same task.
    nonisolated private static func supersessionKey(_ fact: AppliedFact) -> String {
        switch fact.type {
        case .newTask:
            let title = AssignmentDeduplicator.normalize(fact.title ?? "").joined(separator: " ")
            return "\(fact.courseID)|new_task|\(title)"
        case .note:
            // Notes are separate remarks, not revisions of one: one per
            // document per target.
            return "\(fact.courseID)|note|\(fact.target ?? "")|\(fact.documentID)"
        case .needsReview:
            return "\(fact.courseID)|needs_review|\(fact.id)"
        case .cancel, .reschedule, .scopeChange:
            guard let target = fact.target, !target.isEmpty else {
                return "\(fact.courseID)|\(fact.type.rawValue)|untargeted|\(fact.id)"
            }
            return "\(fact.courseID)|\(fact.type.rawValue)|\(target)"
        }
    }

    /// Server targets are an assignment's Canvas `sourceID` (digits) or
    /// `module:<hash of module name>`. The first is translated to the alias
    /// the matcher indexes; the second names a module DOCUMENT, not a module
    /// item, so no ledger row carries it and it resolves to nothing (listed
    /// for review, which is the honest outcome).
    nonisolated private static func resolveTarget(_ fact: AppliedFact, among courseItems: [FactItem]) -> FactItem? {
        guard let raw = fact.target, !raw.isEmpty else { return nil }
        let translated = raw.allSatisfy({ $0.isASCII && $0.isNumber }) ? WorkItemAlias.canvasAssignment(raw).stableString : raw
        let candidates = courseItems.map { WorkItemIdentity.from($0.assignment) }
        guard let hit = WorkItemMatcher.resolve(target: translated, among: candidates) else { return nil }
        // The hard rule: a fact naming one Canvas assignment never lands on
        // a row known to be a different one.
        let factIdentity = WorkItemIdentity(
            ref: "fact:\(fact.id)",
            aliases: WorkItemAlias(stableString: translated).map { [$0] } ?? [],
            title: fact.title ?? "", dueAt: fact.dueAt
        )
        guard case .merge = WorkItemMatcher.match(factTarget: translated, fact: factIdentity, among: candidates) else { return nil }
        return courseItems.first { $0.assignment.id == hit.ref }
    }
}
