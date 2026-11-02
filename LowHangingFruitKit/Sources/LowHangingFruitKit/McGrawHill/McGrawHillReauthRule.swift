import Foundation

/// When a saved McGraw Hill session is judged dead, and the one persisted
/// fact that follows from it. Modelled on `GradescopeReauthRule`, whose
/// history is the reason for every line here: until 2026-10-27 single
/// observations (a cookie's age, one 401, a keyword) signed students out of
/// Gradescope for good, and nothing on the phone could undo it.
///
/// **The rule.** Only one observation counts: a response that is McGraw
/// Hill's real sign-in page (how the client recognises one waits on recon,
/// `docs/mcgraw-hill/RECON.md`). A first sighting is recorded; the verdict
/// "needs reauth" is reached only when a second run, at least
/// `minimumSpacing` later, sees the sign-in page again with no accepted fetch
/// in between. Any accepted fetch clears everything.
///
/// **What the verdict does, and never does.** It may show one reconnect
/// line. It never disconnects McGraw Hill, never hides its enrichments, never
/// deletes its cookies, and never touches Canvas: McGraw Hill is an
/// enrichment of Canvas rows, and a McGraw Hill failure must never cost the
/// student anything Canvas already shows.
///
/// A separate type from Gradescope's, with its own store keys, on purpose:
/// two services, two sessions, two verdicts. A shared rule would let one
/// service's sighting count toward the other's.
public enum McGrawHillReauthRule {
    /// How far apart two sign-in-page sightings must be to count as two runs.
    /// The reader is throttled to the 15-minute cadence the rest of the sync
    /// uses, so two sightings an hour apart are at least four runs.
    public static let minimumSpacing: TimeInterval = 60 * 60

    public enum Outcome: Sendable, Equatable {
        /// McGraw Hill accepted the session (a token minted, a list read).
        case sessionAccepted
        /// McGraw Hill answered with its real sign-in page.
        case loginPage
        /// Anything else: offline, a timeout, a 5xx, a 401 or 403 on one
        /// request, an unreadable body, an empty cookie set, the kill switch
        /// turning the reader off mid-run. Says nothing about the session.
        case inconclusive
    }

    public struct State: Codable, Sendable, Equatable {
        public var firstLoginPageAt: Date?
        public var needsReauth: Bool

        public init(firstLoginPageAt: Date? = nil, needsReauth: Bool = false) {
            self.firstLoginPageAt = firstLoginPageAt
            self.needsReauth = needsReauth
        }

        public static let clear = State()
    }

    public static func advance(_ state: State, after outcome: Outcome, now: Date) -> State {
        switch outcome {
        case .sessionAccepted:
            return .clear
        case .inconclusive:
            return state
        case .loginPage:
            if state.needsReauth { return state }
            guard let first = state.firstLoginPageAt else {
                return State(firstLoginPageAt: now, needsReauth: false)
            }
            // A clock that moved backwards would leave the sighting in the
            // future and the verdict unreachable; count again from now.
            if first > now { return State(firstLoginPageAt: now, needsReauth: false) }
            if now.timeIntervalSince(first) >= minimumSpacing {
                return State(firstLoginPageAt: first, needsReauth: true)
            }
            return state
        }
    }
}

/// Persists `McGrawHillReauthRule.State` in `UserDefaults.lhf`, the
/// preferences tier: a fact about a session, not a credential. Not mirrored
/// to iCloud and not a legacy key, for `GradescopeReauthStore`'s reasons.
public enum McGrawHillReauthStore {
    public static let needsReauthKey = "mcgrawHillNeedsReauthV1"
    public static let firstSightingKey = "mcgrawHillLoginPageFirstSeenAtV1"

    public static func load(defaults: UserDefaults = .lhf) -> McGrawHillReauthRule.State {
        let first: Date? = (defaults.object(forKey: firstSightingKey) as? Double)
            .map { Date(timeIntervalSince1970: $0) }
        return McGrawHillReauthRule.State(
            firstLoginPageAt: first,
            needsReauth: defaults.bool(forKey: needsReauthKey)
        )
    }

    public static func save(_ state: McGrawHillReauthRule.State, defaults: UserDefaults = .lhf) {
        defaults.set(state.needsReauth, forKey: needsReauthKey)
        if let first = state.firstLoginPageAt {
            defaults.set(first.timeIntervalSince1970, forKey: firstSightingKey)
        } else {
            defaults.removeObject(forKey: firstSightingKey)
        }
    }

    /// Forgets the verdict and the sighting (a disconnect, or Canvas going).
    public static func reset(defaults: UserDefaults = .lhf) {
        save(.clear, defaults: defaults)
    }
}
