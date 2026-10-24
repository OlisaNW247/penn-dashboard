import Foundation
import LowHangingFruitKit

// MARK: – Two small pieces of state the judgment backfill needs
//
// The backfill itself is `AppState+RelevanceBackfill.swift`; the why is there.
// These are the two things it has to remember across launches.

/// Whether this install has ever seen the server return a relevance judgment.
///
/// **Why it exists.** `extract-announcement` answers with an optional
/// per-post `relevance` (`AnnouncementRelevance`), and the phone reads each
/// post for tasks exactly once (the `processedAnnouncementIDsV1` ratchet). The
/// app shipped to phones before the server that judges was deployed, and that
/// order costs a post its only read: an old server answers with the tasks and
/// no judgment, the post is marked processed anyway, and it is never asked
/// again, so it never gets a judgment. The phone cannot tell "this server
/// does not judge" from "the model declined this one post" on a single
/// answer, but it can tell across answers: the first time any response carries
/// a usable `relevance`, the server judges, and from then on a missing
/// judgment is a gap worth filling (`AppState.backfillRelevance`). Until then
/// the two things that exist only to get a judgment (reading Ed staff posts,
/// and the backfill) must not spend a call: they would spend the student's
/// shared ask quota (`RelevanceReadBudget`) on an answer that cannot contain
/// what they are asking for.
///
/// Set once, never cleared: it describes the server, not the student, so
/// disconnecting Canvas leaves it alone. Preferences tier, like the budget.
/// Under the test runner an `AppState` gets a memory-only flag, so no test can
/// reach the shared defaults domain; a test that wants the stored form builds
/// one over a scratch suite (`AppState.serverJudgesRelevance`).
final class ServerJudgesRelevance {
    static let key = "serverJudgesRelevanceV1"

    private let defaults: UserDefaults?
    /// The answer when there is no defaults to keep it in.
    private var memory = false

    /// - Parameter defaults: where the flag persists; nil keeps it in this
    ///   object only.
    init(defaults: UserDefaults?) {
        self.defaults = defaults
    }

    var isSet: Bool {
        defaults?.bool(forKey: Self.key) ?? memory
    }

    /// Records that a response carried a usable judgment. Idempotent, and
    /// writes nothing once set (it is called after every judged answer).
    func markSeen() {
        guard !isSet else { return }
        if let defaults {
            defaults.set(true, forKey: Self.key)
        } else {
            memory = true
        }
    }
}

/// What the backfill has already asked about and should leave alone: a post it
/// asked about today that failed, and a post the server answered with no
/// judgment at all.
///
/// - **A failure waits for the next UTC day**, per post. The budget
///   (`RelevanceReadBudget`) already bounds the day's calls, but without a
///   stamp it would also bound them to the *same* failing post, newest first:
///   a post the backend cannot read would take every one of the day's six
///   calls on every run and starve the posts behind it. The wrong fix is
///   refunding a failed call to the budget: a failed call can still have been
///   counted by the server.
/// - **An empty answer is final.** The server read the post and judged
///   nothing. The post is already processed, so nothing else would ever stop
///   the backfill from asking again, once a day, forever, for the same
///   non-answer. It is remembered as judged-empty and not asked again.
///
/// One small dictionary in the preferences tier, pruned on every write: a
/// failure stamp is dead after its day, and an empty marker is dead once its
/// post has left the 14-day extraction window, so a month is generous. Under
/// the test runner it is memory-only, like the budget.
final class RelevanceBackfillLedger {
    static let key = "relevanceBackfillV1"
    /// How long an empty marker is kept. The backfill only looks at posts
    /// inside the 14-day extraction window, so after this nothing could
    /// consult it.
    static let emptyRetentionDays = 30

    private struct State {
        /// Post key -> the UTC day its last backfill call failed.
        var failed: [String: Int] = [:]
        /// Post key -> the UTC day the server answered it with no judgment.
        var empty: [String: Int] = [:]
    }

    private let defaults: UserDefaults?
    private var memory = State()

    init(defaults: UserDefaults?) {
        self.defaults = defaults
    }

    private var state: State {
        get {
            guard let defaults else { return memory }
            let saved = defaults.dictionary(forKey: Self.key) as? [String: [String: Int]]
            return State(failed: saved?["failed"] ?? [:], empty: saved?["empty"] ?? [:])
        }
        set {
            guard let defaults else { memory = newValue; return }
            if newValue.failed.isEmpty && newValue.empty.isEmpty {
                defaults.removeObject(forKey: Self.key)
            } else {
                defaults.set(["failed": newValue.failed, "empty": newValue.empty], forKey: Self.key)
            }
        }
    }

    /// Whether the backfill should leave `key` alone as of `date`: it was
    /// answered with nothing, or its call failed earlier on this UTC day.
    func shouldSkip(_ key: String, on date: Date) -> Bool {
        let current = state
        if current.empty[key] != nil { return true }
        return current.failed[key] == RelevanceReadBudget.utcDay(of: date)
    }

    func recordFailure(_ key: String, on date: Date) {
        var current = state
        current.failed[key] = RelevanceReadBudget.utcDay(of: date)
        state = pruned(current, on: date)
    }

    func recordEmpty(_ key: String, on date: Date) {
        var current = state
        current.empty[key] = RelevanceReadBudget.utcDay(of: date)
        state = pruned(current, on: date)
    }

    private func pruned(_ value: State, on date: Date) -> State {
        let today = RelevanceReadBudget.utcDay(of: date)
        var next = value
        next.failed = next.failed.filter { $0.value >= today }
        next.empty = next.empty.filter { $0.value > today - Self.emptyRetentionDays }
        return next
    }
}

/// One post the backfill may ask the server about, in the shape both passes
/// can build: where its judgment is stored, what to send, and whether it is
/// still wanted once the call returns.
struct RelevanceBackfillCandidate {
    /// The read-state key of the post (`AnnouncementReadState.recordKey` for a
    /// Canvas post, `.edKey` for an Ed one): where the judgment is stored, and
    /// what the ledger remembers it by.
    let key: String
    let source: AnnouncementSourceText
    /// The post in the Canvas-shaped value the extractor choice
    /// (`AppState.announcementExtractor`) takes. For a Canvas post it is the
    /// post itself.
    let standIn: CanvasAnnouncement
    /// Asked again after the network call, like the passes do: a class the
    /// student disconnected or hid meanwhile must not get a judgment written.
    let isStillWanted: @MainActor () -> Bool
}

/// What one backfill run did, for the sync summaries. Counts only.
struct RelevanceBackfillOutcome {
    /// Calls sent (each one spent a unit of the budget).
    var asked = 0
    /// Judgments stored from a call.
    var judged = 0
    /// Informational posts judged `news` on the phone, no call.
    var localNews = 0
    var failed = 0
    /// Posts left for later because today's budget was spent.
    var heldBack = 0

    var didWork: Bool { asked > 0 || localNews > 0 }

    /// The tail of a sync summary line, empty when nothing happened.
    var summary: String {
        guard didWork || heldBack > 0 else { return "" }
        return " \u{00B7} backfill asked \(asked) judged \(judged) news \(localNews) failed \(failed) held back \(heldBack)"
    }
}
