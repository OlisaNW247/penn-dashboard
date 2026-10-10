import Foundation

/// The "don't open on a wall of old overdue work" rule for a student's very
/// first dashboard.
///
/// A student who signs up in week 9 connects Canvas and gets, in one sync,
/// every assignment the semester has ever listed. The ones due weeks ago are
/// almost never owed: they were turned in on paper, waived, or were never
/// really tracked in Canvas, and a first screen made of red "overdue" cards is
/// the worst possible introduction. The rule: **an unfinished feed item that
/// was due more than a week before the moment of sign-up is not shown.**
/// Anything overdue by less than a week at sign-up, and everything after it,
/// behaves exactly as it always did.
///
/// **This is a display rule, never a data rule.** Nothing is deleted and
/// nothing on the ledger is touched: `AssignmentStore.reconcile`, `isVisible`
/// and `activeAssignments` know nothing about it, and must not. The ledger's
/// own tests reconcile 45-to-90-day-old items into a fresh store and expect
/// them back, and they are right to; hiding is `AppState`'s presentation
/// filter (one place, `rebuildDashboardItems`) plus the two readers that
/// cannot call it (the widget's ledger fallback and the assistant's pool).
/// The student can always bring the items back (`SignupBacklogStore
/// .isRevealed`, surfaced at the foot of the prev tab).
///
/// **The cutoff is decided once and never moves** (`SignupBacklogStore`). If it
/// tracked "now" it would be a rolling 7-day window that quietly eats real
/// overdue work the week after it was due; the only moment that matters is
/// sign-up. Reconnecting Canvas, restarting onboarding or rolling the
/// semester over must not move it either, for the same reason.
public struct SignupBacklog: Equatable, Sendable {
    /// How far before sign-up an unfinished item may have been due and still
    /// be shown. A named constant because three places (the decision, the
    /// copy, the tests) must agree on it.
    public static let window: TimeInterval = 7 * 24 * 60 * 60

    /// The cutoff for a student who signed up at `moment`.
    public static func cutoff(forSignupAt moment: Date) -> Date {
        moment.addingTimeInterval(-window)
    }

    /// Items due strictly before this are hidden. An item due *exactly* at the
    /// cutoff is exactly seven days overdue at sign-up, not "more than" seven,
    /// so it stays.
    public let cutoff: Date

    public init(cutoff: Date) {
        self.cutoff = cutoff
    }

    public init(signupAt moment: Date) {
        self.cutoff = Self.cutoff(forSignupAt: moment)
    }

    /// The four sources a feed delivers. `.manual` (which includes recurring
    /// tasks) is the student's own work and is never hidden; `.canvasSuggestion`
    /// is an offer to add something, not an assignment.
    public static func isFeedSource(_ source: Assignment.Source) -> Bool {
        switch source {
        case .canvas, .canvasModules, .gradescope, .canvasAnnouncement:
            return true
        case .manual, .canvasSuggestion:
            return false
        }
    }

    /// The rule. `isFinished` is the caller's notion of finished (ticked off,
    /// turned in, auto-filed as nothing-to-submit): finished work is history,
    /// and history is never hidden. Undated items are never hidden, since there
    /// is nothing to measure them against.
    public func hides(_ assignment: Assignment, isFinished: Bool) -> Bool {
        hides(source: assignment.source, dueAt: assignment.dueAt, isFinished: isFinished)
    }

    /// The same rule over the three facts it needs, so a reader that holds a
    /// ledger row rather than an `Assignment` (the widget) applies the very same
    /// predicate instead of a copy of it.
    public func hides(source: Assignment.Source, dueAt: Date?, isFinished: Bool) -> Bool {
        guard Self.isFeedSource(source), !isFinished, let dueAt else { return false }
        return dueAt < cutoff
    }
}

/// Where the sign-up decision lives: two keys in a `UserDefaults`.
///
/// It is a display preference, so by `CLAUDE.md`'s storage tiers it belongs in
/// App Group defaults (cheap to lose, meaningless off-device), not in the
/// SwiftData ledger, which never deletes and has no business holding a
/// per-install UI decision. It is also not mirrored to iCloud: a second device
/// makes its own decision against its own ledger.
///
/// The `UserDefaults` is injected. Production uses `UserDefaults.lhf`; tests
/// use a scratch suite, because a decision written to the shared domain would
/// be read by every `AppState` in every concurrently running suite (the
/// shared-defaults trap in `CLAUDE.md`).
public struct SignupBacklogStore {
    /// What the store knows about the sign-up decision.
    public enum Decision: Equatable, Sendable {
        /// No real feed has reconciled yet. Nothing is hidden.
        case undecided
        /// Decided that nothing is ever hidden on this install: it already
        /// held feed rows when this feature arrived (an existing install
        /// updating), so a cutoff would change what they see.
        case noCutoff
        /// Decided at a genuine first sign-up: hide unfinished feed work due
        /// before this moment.
        case cutoff(Date)
    }

    /// What `.noCutoff` is stored as. An epoch cutoff hides nothing real (no
    /// assignment is due in 1970), so a reader that forgot the sentinel and
    /// treated the value as a date would still do the safe thing.
    static let noCutoffValue: Double = 0

    public let defaults: UserDefaults

    public init(defaults: UserDefaults) {
        self.defaults = defaults
    }

    /// The stored decision. A value that is not a finite positive number reads
    /// as `.noCutoff` rather than `.undecided`: a damaged value must lean
    /// toward showing everything, and `.undecided` would let the next sync
    /// overwrite it with a fresh decision.
    public var decision: Decision {
        guard let raw = defaults.object(forKey: SharedDefaults.signupBacklogCutoffKey) else {
            return .undecided
        }
        guard let seconds = (raw as? NSNumber)?.doubleValue,
              seconds.isFinite, seconds > Self.noCutoffValue
        else { return .noCutoff }
        return .cutoff(Date(timeIntervalSince1970: seconds))
    }

    /// Takes the decision if, and only if, none has been taken: the first call
    /// on an install writes, every later call returns what was written.
    ///
    /// `ledgerHoldsFeedRows` is evaluated lazily, only on the one call that
    /// decides, and must describe the ledger *before* the reconcile that
    /// triggered it inserts the fetched rows (otherwise every install would
    /// look like an existing one).
    @discardableResult
    public func decideIfNeeded(
        ledgerHoldsFeedRows: @autoclosure () -> Bool,
        now: Date
    ) -> Decision {
        let existing = decision
        guard existing == .undecided else { return existing }
        if ledgerHoldsFeedRows() {
            defaults.set(Self.noCutoffValue, forKey: SharedDefaults.signupBacklogCutoffKey)
            return .noCutoff
        }
        let cutoff = SignupBacklog.cutoff(forSignupAt: now)
        defaults.set(cutoff.timeIntervalSince1970, forKey: SharedDefaults.signupBacklogCutoffKey)
        return .cutoff(cutoff)
    }

    /// The student's "show them" switch, persisted beside the cutoff.
    public var isRevealed: Bool {
        get { defaults.bool(forKey: SharedDefaults.signupBacklogRevealedKey) }
        nonmutating set { defaults.set(newValue, forKey: SharedDefaults.signupBacklogRevealedKey) }
    }

    /// The rule as decided, whatever the switch says; nil when nothing is
    /// ever hidden (undecided, or an existing install). This is what counts
    /// the hidden items.
    public var decidedBacklog: SignupBacklog? {
        if case let .cutoff(date) = decision { return SignupBacklog(cutoff: date) }
        return nil
    }

    /// The rule that is in force right now: `decidedBacklog`, unless the
    /// student has chosen to see everything. This is what the filters apply.
    public var activeBacklog: SignupBacklog? {
        isRevealed ? nil : decidedBacklog
    }
}
