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
        /// No feed items have arrived on this install yet. Nothing is hidden.
        case undecided
        /// Decided that nothing is ever hidden on this install: its ledger
        /// already held feed rows when this feature arrived (an existing
        /// install updating), so a cutoff would change what they see.
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

    /// True exactly once per install: on the first call, which writes a marker
    /// and returns true; every later call returns false. Called on every launch
    /// of a build that has this feature, so "true" means *this is the first
    /// launch of such a build on this install*, and it is written whatever that
    /// launch goes on to decide.
    ///
    /// What it is for: "onboarding was already complete" is proof that an
    /// install pre-dates the feature only at that one moment. A fresh install's
    /// first launch has onboarding incomplete, so it can never match; but a new
    /// student who finishes onboarding before any feed item has arrived (the
    /// connect-time and hand-off syncs both failed or came back empty) would
    /// match on their next launch, if that clause were allowed to run every
    /// time, and be recorded as an existing install while the whole backlog
    /// was still waiting to arrive.
    public func claimFirstLaunch() -> Bool {
        guard defaults.object(forKey: SharedDefaults.signupBacklogSeenKey) == nil else { return false }
        defaults.set(true, forKey: SharedDefaults.signupBacklogSeenKey)
        return true
    }

    /// Records "this is an install that pre-dates the feature: hide nothing,
    /// ever", if and only if no decision has been taken and either
    /// `preDatesFeature` (the caller has proof from outside the ledger, see
    /// `claimFirstLaunch`) or the ledger already holds feed rows. A no-op once
    /// decided, and with neither (that is a student who has not synced yet, who
    /// stays undecided).
    ///
    /// `ledgerHoldsFeedRows` is evaluated lazily, only while undecided and only
    /// if `preDatesFeature` did not already settle it, so the scan of the ledger
    /// is paid on the launches that need it and never after. It must describe
    /// the ledger as the previous launch left it, before anything in this
    /// launch has reconciled a feed into it.
    @discardableResult
    public func recordExistingInstallIfUndecided(
        preDatesFeature: Bool = false,
        ledgerHoldsFeedRows: @autoclosure () -> Bool
    ) -> Decision {
        let existing = decision
        guard existing == .undecided, preDatesFeature || ledgerHoldsFeedRows() else { return existing }
        defaults.set(Self.noCutoffValue, forKey: SharedDefaults.signupBacklogCutoffKey)
        return .noCutoff
    }

    /// Records the sign-up moment, if and only if no decision has been taken:
    /// the first call on an install writes `moment - 7 days`, every later call
    /// returns what was written. This is the moment a genuinely new student's
    /// first feed items arrive.
    @discardableResult
    public func recordSignupIfUndecided(at moment: Date) -> Decision {
        let existing = decision
        guard existing == .undecided else { return existing }
        let cutoff = SignupBacklog.cutoff(forSignupAt: moment)
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
