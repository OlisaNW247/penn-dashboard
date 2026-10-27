import Foundation

/// When a saved Gradescope session is judged dead, and the one persisted fact
/// that follows from it.
///
/// **What this replaces.** Until 2026-10-27 three different things signed a
/// student out of Gradescope: the 24-hour no-expiry cookie rule (an empty
/// cookie set read as "disconnected"), any 401 or 403 from one request, and a
/// keyword match that could fire on an ordinary page. Each was a single
/// observation that could be wrong, and the consequence of being wrong was
/// permanent: `isGradescopeConnected` went false, the coordinator stopped
/// syncing, the rows were hidden. Nothing on the phone can renew a Gradescope
/// session, so a wrong "dead" verdict cannot even heal itself.
///
/// **The rule.** Only one observation counts: a response that is a login form
/// (`GradescopeHTMLParser.isLoginPage`, a password input). And one is not
/// enough. A first sighting is recorded, and the verdict is "needs reauth"
/// only when a second run, at least `minimumSpacing` later, sees a login form
/// again with no accepted fetch in between. Two requests inside one sync, or
/// two syncs a throttle-width apart (`AutoSyncCoordinator.gradescopeMinInterval`
/// is 15 minutes), are one event. Any accepted fetch clears everything, so a
/// good session never carries a stale sighting forward.
///
/// **What the verdict does.** It shows one reconnect line. It does not
/// disconnect Gradescope, hide its rows, or delete its cookies: the student
/// can ignore the line and still read everything the last good sync fetched,
/// and the next accepted fetch (say, after the server's own session comes
/// back) clears it without anyone doing anything.
///
/// Pure, so the rule is tested by passing dates. The persistence beside it
/// (`GradescopeReauthStore`) is a thin read/write of `State`.
public enum GradescopeReauthRule {
    /// How far apart two login-form sightings must be to count as two runs.
    public static let minimumSpacing: TimeInterval = 60 * 60

    /// What one Gradescope run learned about the saved session.
    public enum Outcome: Sendable, Equatable {
        /// A fetch the server accepted: the session is alive.
        case sessionAccepted
        /// A response that was a login form: the server did not know us.
        case loginForm
        /// Anything else: offline, a timeout, a 5xx, a 403, an unreadable
        /// page, an empty cookie set. Says nothing about the session either
        /// way, so it changes nothing.
        case inconclusive
    }

    public struct State: Codable, Sendable, Equatable {
        /// The first login-form sighting not yet followed by an accepted fetch.
        public var firstLoginFormAt: Date?
        /// The saved verdict: two sightings, at least an hour apart.
        public var needsReauth: Bool

        public init(firstLoginFormAt: Date? = nil, needsReauth: Bool = false) {
            self.firstLoginFormAt = firstLoginFormAt
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
        case .loginForm:
            // Already raised: keep the verdict and the original sighting.
            if state.needsReauth { return state }
            guard let first = state.firstLoginFormAt else {
                return State(firstLoginFormAt: now, needsReauth: false)
            }
            // A clock that moved backwards leaves a sighting in the future,
            // which would otherwise make every later gap negative and the
            // verdict unreachable. Start the count again from now.
            if first > now { return State(firstLoginFormAt: now, needsReauth: false) }
            if now.timeIntervalSince(first) >= minimumSpacing {
                return State(firstLoginFormAt: first, needsReauth: true)
            }
            return state
        }
    }
}

/// Persists `GradescopeReauthRule.State` in `UserDefaults.lhf`. The saved
/// verdict is `gradescopeNeedsReauth` (the plan's name for it); the first
/// sighting rides beside it so the "two runs" rule survives a relaunch, which
/// is the common case: the app is closed between runs.
///
/// Preferences tier, not the Keychain: it is a fact about a session, not a
/// credential, and losing it costs one more run to re-reach the verdict. It
/// is deliberately not in `CloudPrefsMirror.mirroredKeys` or
/// `SharedDefaultsMigration.legacyKeys`: a second device has its own
/// Gradescope session and its own verdict.
public enum GradescopeReauthStore {
    public static let needsReauthKey = "gradescopeNeedsReauth"
    public static let firstSightingKey = "gradescopeLoginFormFirstSeenAt"

    public static func load(defaults: UserDefaults = .lhf) -> GradescopeReauthRule.State {
        let first: Date? = (defaults.object(forKey: firstSightingKey) as? Double)
            .map { Date(timeIntervalSince1970: $0) }
        return GradescopeReauthRule.State(
            firstLoginFormAt: first,
            needsReauth: defaults.bool(forKey: needsReauthKey)
        )
    }

    public static func save(_ state: GradescopeReauthRule.State, defaults: UserDefaults = .lhf) {
        defaults.set(state.needsReauth, forKey: needsReauthKey)
        if let first = state.firstLoginFormAt {
            defaults.set(first.timeIntervalSince1970, forKey: firstSightingKey)
        } else {
            defaults.removeObject(forKey: firstSightingKey)
        }
    }

    /// Forgets the verdict and the sighting (an explicit disconnect).
    public static func reset(defaults: UserDefaults = .lhf) {
        save(.clear, defaults: defaults)
    }
}
