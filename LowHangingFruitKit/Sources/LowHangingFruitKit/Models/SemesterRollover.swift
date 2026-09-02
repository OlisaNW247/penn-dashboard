import Foundation

/// Detects that the student has crossed a term boundary, and describes what
/// archiving the old term would actually do — as a count they can look at
/// before they agree to it.
///
/// ## Why this is a detector and not a janitor
///
/// The app could notice on 23 August that it is holding four months of Spring
/// work and quietly put it away. It must not. Silently hiding a student's work
/// is the one failure this app cannot have — it is the same failure the whole
/// ledger was built to prevent (`docs/persistence-explained.md` §1), just
/// arriving through the front door instead of through a bad fetch. So this type
/// produces an *offer*: which terms are old, how many items each holds, which
/// classes they belong to. Something else asks the student. Nothing here
/// mutates anything.
///
/// ## Why it takes a census instead of ledger rows
///
/// `detect` is a pure function over `Item`, a small `Sendable` value carrying
/// only the four things the decision needs. `StoredAssignment` is a SwiftData
/// `@Model` whose store is main-actor-isolated, and a rule this load-bearing
/// should be testable by writing down a list of items rather than by standing
/// up a database. `AssignmentStore.rolloverOffer(now:)` is the adapter that
/// builds the census; every judgement about *what the rule is* lives here.
public enum SemesterRollover {

    /// One row's worth of the ledger, reduced to what the rollover decision
    /// actually depends on.
    public struct Item: Sendable, Equatable {
        public let id: String
        public let course: String
        /// The term this item has been *resolved* to — see
        /// `StoredAssignment.effectiveTerm`, which owns the precedence. Nil only
        /// when the row carries no term, no due date and no first-seen date,
        /// which a real row never does.
        public let term: Term?
        /// Whether a previous rollover already put this item away. Archived
        /// items are excluded from a fresh offer, which is what stops the card
        /// coming back to offer the same work a second time.
        public let isArchived: Bool

        public init(id: String, course: String, term: Term?, isArchived: Bool) {
            self.id = id
            self.course = course
            self.term = term
            self.isArchived = isArchived
        }
    }

    /// One past term, and the size of the decision attached to it.
    public struct Candidate: Sendable, Equatable, Identifiable {
        public let term: Term
        /// How many ledger rows would be stamped archived. This is the number
        /// the card shows, and the reason the card is worth showing at all: "put
        /// last semester away" is a shrug, "archive 47 items from Spring 2026"
        /// is a decision.
        public let itemCount: Int
        /// The classes those items belong to, sorted. Shown so a student who
        /// recognises a class they are *still taking* can back out.
        public let courseKeys: [String]

        public var id: String { term.code }

        public init(term: Term, itemCount: Int, courseKeys: [String]) {
            self.term = term
            self.itemCount = itemCount
            self.courseKeys = courseKeys
        }
    }

    /// Everything the card needs to render one offer.
    public struct Offer: Sendable, Equatable {
        /// The term the calendar says we are in now.
        public let currentTerm: Term
        /// Older terms still live on the dashboard, newest first — so a student
        /// who skipped a semester of app use sees Spring before last Fall.
        public let candidates: [Candidate]

        public init(currentTerm: Term, candidates: [Candidate]) {
            self.currentTerm = currentTerm
            self.candidates = candidates
        }

        public var terms: [Term] { candidates.map(\.term) }
        public var totalItemCount: Int { candidates.reduce(0) { $0 + $1.itemCount } }
        public var courseKeys: [String] {
            Array(Set(candidates.flatMap(\.courseKeys))).sorted()
        }

        /// A one-line summary in the student's own vocabulary: "47 items from
        /// Spring 2026", or "47 items from 2 earlier terms" when it spans more
        /// than one. Built here rather than in the view so the count and the
        /// term labels can't drift apart from what `archive` will actually do.
        public var summary: String {
            let noun = totalItemCount == 1 ? "item" : "items"
            switch candidates.count {
            case 0:  return "Nothing to archive"
            case 1:  return "\(totalItemCount) \(noun) from \(candidates[0].term.displayName)"
            default: return "\(totalItemCount) \(noun) from \(candidates.count) earlier terms"
            }
        }
    }

    /// The terms present in `items`, resolved and deduplicated. Exposed because
    /// "which semesters does this ledger span" is a question the Done history
    /// and the diagnostics both want, independently of whether anything is
    /// being offered for archival.
    public static func terms(in items: [Item]) -> Set<Term> {
        Set(items.compactMap(\.term))
    }

    /// Builds the offer, or returns nil when there is nothing to ask about.
    ///
    /// Nil is the answer for eleven months of the year and it matters: the card
    /// renders `EmptyView` on nil, so a `Form` section costs zero pixels rather
    /// than sitting at the top of Profile saying "no, nothing". The three ways
    /// to get nil are all the same fact from different angles — every item the
    /// ledger holds already belongs to the current term, or to a term a previous
    /// rollover already put away, or the ledger is empty.
    ///
    /// **Only strictly-older terms are offered.** A future term (Canvas lists
    /// next semester's shell course as "active" well before it starts) is not a
    /// rollover candidate — `AppState.withinTermCap` already keeps those off the
    /// dashboard, and offering to archive work that hasn't been assigned yet
    /// would be nonsense.
    public static func detect(_ items: [Item], now: Date = Date()) -> Offer? {
        let current = Term(date: now)

        var byTerm: [Term: (count: Int, courses: Set<String>)] = [:]
        for item in items {
            // An already-archived item is settled. Counting it again would make
            // the card reappear after the student had already agreed to it, with
            // a button that archives what is already archived.
            guard !item.isArchived, let term = item.term, term < current else { continue }
            var bucket = byTerm[term] ?? (count: 0, courses: [])
            bucket.count += 1
            bucket.courses.insert(item.course)
            byTerm[term] = bucket
        }
        guard !byTerm.isEmpty else { return nil }

        let candidates = byTerm
            .map { Candidate(term: $0.key, itemCount: $0.value.count,
                             courseKeys: $0.value.courses.sorted()) }
            .sorted { $0.term > $1.term }
        return Offer(currentTerm: current, candidates: candidates)
    }
}
