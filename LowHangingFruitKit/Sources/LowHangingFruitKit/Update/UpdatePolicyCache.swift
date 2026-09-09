import Foundation

/// Persists the last **successfully fetched** `UpdatePolicy` so the version
/// gate still has an answer offline or on a launch where the manifest fetch
/// fails — a plane-mode student shouldn't lose the gate entirely just because
/// there's no network to re-confirm it.
///
/// Storage tier 2 (`docs/persistence-explained.md`): App Group `UserDefaults`,
/// reached only through `UserDefaults.lhf`, never `.standard` — this is a
/// preference-shaped cache, cheap to lose and meaningless off-device, not a
/// student record, so it belongs nowhere near the SwiftData ledger.
public struct UpdatePolicyCache: Sendable {
    private static let policyKey = "lhf.updatePolicy"
    private static let fetchedAtKey = "lhf.updatePolicyFetchedAt"

    /// The ceiling on how old a cached policy is allowed to be before `load`
    /// refuses it and returns `nil`.
    ///
    /// **Why this exists.** Without a ceiling, a policy fetched once and then
    /// never refreshed is trusted forever. Picture the failure this project
    /// keeps getting bitten by in a new shape: a maintainer publishes a
    /// `minimumVersion` that's wrong — too high, or paired with a broken
    /// `appStoreURL` — and then the hosting for the manifest goes down (the
    /// domain lapses, the file 404s, whatever). Every install that already
    /// cached the bad policy is now blocked, permanently, with no way for the
    /// maintainer to push a fix, because the one channel that could correct
    /// it is the same file that's unreachable. Thirty days is deliberately
    /// generous — long enough that a normal offline stretch (a trip, a slow
    /// week) never falsely un-caches a legitimate `minimumVersion` — but it's
    /// not forever, so a bad policy self-expires instead of being a
    /// permanent, unrecoverable lockout. This matters more here than almost
    /// anywhere else in the app: the ledger's whole design is "nothing the
    /// student did is ever lost," and a version gate that can wedge itself
    /// shut would trap the student's only copy of their own work behind a
    /// screen with no way through.
    public static let maximumTrustedAge: TimeInterval = 60 * 60 * 24 * 30

    // `nonisolated(unsafe)` for the same reason `UserDefaults.lhf` itself
    // needs it (see `SharedDefaults.swift`): `UserDefaults` isn't `Sendable`
    // by declaration, but it is documented as thread-safe, which is exactly
    // what every other reachable-from-any-isolation defaults reference in
    // this codebase already relies on.
    nonisolated(unsafe) private let defaults: UserDefaults

    public init(defaults: UserDefaults = .lhf) {
        self.defaults = defaults
    }

    public func save(_ policy: UpdatePolicy, at date: Date) {
        guard let data = try? JSONEncoder().encode(policy) else { return }
        defaults.set(data, forKey: Self.policyKey)
        defaults.set(date.timeIntervalSince1970, forKey: Self.fetchedAtKey)
    }

    /// Returns the cached policy, or `nil` when nothing is cached, the cached
    /// blob no longer decodes, or the cache is older than
    /// `maximumTrustedAge` relative to `now`.
    public func load(now: Date = Date()) -> UpdatePolicy? {
        guard let data = defaults.data(forKey: Self.policyKey) else { return nil }
        // `object(forKey:)` returning nil (never saved) reads as 0 through
        // `double(forKey:)`, which is indistinguishable from "saved at the
        // Unix epoch" — but that's fine here, since a saved-at-epoch cache
        // is always older than `maximumTrustedAge` from any `now` in this
        // app's lifetime and so is correctly rejected either way.
        let fetchedAt = defaults.double(forKey: Self.fetchedAtKey)
        let age = now.timeIntervalSince1970 - fetchedAt
        guard age <= Self.maximumTrustedAge else { return nil }

        return try? JSONDecoder().decode(UpdatePolicy.self, from: data)
    }

    public func clear() {
        defaults.removeObject(forKey: Self.policyKey)
        defaults.removeObject(forKey: Self.fetchedAtKey)
    }
}
