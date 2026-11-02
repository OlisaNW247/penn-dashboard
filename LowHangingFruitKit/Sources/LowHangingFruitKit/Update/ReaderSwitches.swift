import Foundation

/// The update manifest's optional `readers` object: one remote switch per
/// reader that reads a third-party service the owners have no written
/// permission for. Today that is McGraw Hill alone:
///
/// ```json
/// { "minimumVersion": "3.4.0", "latestVersion": "3.4.0",
///   "readers": { "mcgrawHill": true } }
/// ```
///
/// **Why it exists (owners' decision, 2026-11-02).** McGraw Hill's terms of
/// use appear to bar "robots, scrapers and automatic devices" without written
/// permission (`reports/McGraw Hill access for Smooth.md`). Olisa read that
/// and decided to build the reader anyway, on condition that the risk stays
/// controllable: if McGraw Hill objects, every phone must be switchable off
/// from GitHub's web UI on a phone, with no release and no App Review. The
/// manifest is the one file every shipped build already fetches, and GitHub's
/// web UI can edit it (`CLAUDE.md` → Update gate).
///
/// **Off unless on, the opposite of the update floor on purpose.** The floor
/// fails *open*: a broken fetch must never invent a wall. This switch fails
/// *closed*: a missing key, a missing object, `"true"` as a string, `1`,
/// `null`, an object that is not an object, an unknown reader name, a fetch
/// that never succeeded on a fresh install — every one of them means off.
/// Only the JSON boolean literal `true` under the reader's own key turns a
/// reader on. The reasoning is the asymmetry of the two mistakes: a reader
/// wrongly off costs one class's done-state until the next good fetch; a
/// reader wrongly on is the thing the owners promised McGraw Hill it could
/// stop.
///
/// **It never costs the floor.** `UpdatePolicy` decodes this object with
/// `try?`, exactly as it does `feedback`, and this type itself never throws
/// from a well-formed container: a bad value is read as off, not as a
/// decoding error, so `minimumVersion` is decoded whatever shape `readers`
/// has. Builds that predate this key ignore it (Codable skips unknown keys).
public struct ReaderSwitches: Codable, Sendable, Equatable {
    /// McGraw Hill Connect (and, later, ALEKS). True only when the manifest
    /// carried `"mcgrawHill": true`.
    public let mcgrawHill: Bool

    public init(mcgrawHill: Bool = false) {
        self.mcgrawHill = mcgrawHill
    }

    /// Every reader off: what a missing object, a failed fetch and a cache
    /// that is too old all mean.
    public static let allOff = ReaderSwitches()

    private enum CodingKeys: String, CodingKey {
        case mcgrawHill
    }

    public init(from decoder: Decoder) throws {
        // `try?` on the container: `"readers": "on"` or `"readers": [true]`
        // is a malformed object, and a malformed object is all off, never a
        // thrown error that a careless caller could let reach the policy.
        guard let container = try? decoder.container(keyedBy: CodingKeys.self) else {
            mcgrawHill = false
            return
        }
        // `Bool.self` only: JSONDecoder does not coerce `"true"` or `1` into
        // a Bool, so those throw here and `try?` reads them as off. A JSON
        // `null` decodes as nil through `decodeIfPresent`, also off.
        mcgrawHill = (try? container.decodeIfPresent(Bool.self, forKey: .mcgrawHill)) == true
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(mcgrawHill, forKey: .mcgrawHill)
    }
}

/// The last-known `readers` switches, from the last manifest this install
/// fetched successfully, kept in `UserDefaults.lhf` (the preferences tier: a
/// fact about a remote file, cheap to lose, meaningless off the phone, never
/// mirrored to iCloud).
///
/// **Why not `UpdatePolicyCache`.** That cache serves the floor, which fails
/// open and trusts a policy for thirty days, and it is only written by a
/// fetch that decodes. This store has the opposite job and its own rules:
///
/// - `record(_:at:)` is called on every successful manifest fetch, with
///   whatever the manifest said, **including no `readers` object at all**,
///   which records all off. So removing the key from `lhf-update.json`, or
///   setting it to `false`, switches a phone off on its next successful
///   fetch (at launch, and on returning to the foreground, at most hourly:
///   `UpdateGateStore.throttleInterval`).
/// - `load(now:)` returns all off when nothing was ever recorded (a fresh
///   install whose first fetch failed), when the stored blob does not decode,
///   or when the last successful fetch is older than `maximumTrustedAge`.
///   An install that cannot reach GitHub for a week stops reading McGraw
///   Hill rather than trusting a week-old "on".
///
/// The known window: a phone that read "on", went offline and comes back
/// keeps reading on its cached "on" until its next successful fetch, which
/// the gate makes at launch and on foreground. One sync can run on the old
/// value. That is the price of not making the reader wait for the network
/// before every run, and it is bounded by `maximumTrustedAge`.
public struct ReaderSwitchStore: Sendable {
    private static let switchesKey = "lhf.readerSwitchesV1"
    private static let fetchedAtKey = "lhf.readerSwitchesFetchedAtV1"

    /// Seven days. Long enough that a weekend offline does not flicker a
    /// reader off and on; short enough that a phone which has stopped
    /// hearing from the manifest stops reading a service the owners may have
    /// switched off.
    public static let maximumTrustedAge: TimeInterval = 60 * 60 * 24 * 7

    // `nonisolated(unsafe)` for the reason `UpdatePolicyCache` gives:
    // `UserDefaults` is documented thread-safe but not declared `Sendable`.
    nonisolated(unsafe) private let defaults: UserDefaults

    public init(defaults: UserDefaults = .lhf) {
        self.defaults = defaults
    }

    /// Records what a successful manifest fetch said. `nil` (no `readers`
    /// object, or one `UpdatePolicy` could not decode) is recorded as all
    /// off, deliberately: the manifest was read and it did not say on.
    public func record(_ switches: ReaderSwitches?, at date: Date) {
        let value = switches ?? .allOff
        guard let data = try? JSONEncoder().encode(value) else {
            clear()
            return
        }
        defaults.set(data, forKey: Self.switchesKey)
        defaults.set(date.timeIntervalSince1970, forKey: Self.fetchedAtKey)
    }

    /// The switches to obey right now. Never throws, never nil: anything
    /// short of a recent, decodable record is all off.
    public func load(now: Date = Date()) -> ReaderSwitches {
        guard let data = defaults.data(forKey: Self.switchesKey),
              let fetchedAt = defaults.object(forKey: Self.fetchedAtKey) as? Double else {
            return .allOff
        }
        let age = now.timeIntervalSince1970 - fetchedAt
        // A record from the future (a clock that moved backwards) is not
        // trusted either: it would otherwise stay "fresh" for as long as the
        // clock stays wrong.
        guard age >= 0, age <= Self.maximumTrustedAge else { return .allOff }
        return (try? JSONDecoder().decode(ReaderSwitches.self, from: data)) ?? .allOff
    }

    public func clear() {
        defaults.removeObject(forKey: Self.switchesKey)
        defaults.removeObject(forKey: Self.fetchedAtKey)
    }
}

/// Whether a reader may run, from everything that can say no. Pure, so the
/// rule is one function a test can table out.
///
/// All four must agree:
/// 1. **Compiled in** (`FeatureFlags.mcgrawHillReader`): the release's own
///    hard off.
/// 2. **The manifest says on** (`ReaderSwitchStore.load`), or a DEBUG build
///    was launched with `-LHFForceMcGrawHillReader` (`debugForced`), which
///    replaces only this half so a developer's phone can run the reader
///    while the live switch stays off for everyone else. A Release build
///    always passes `false` for it.
/// 3. **Not preview or demo data**: App Review's only way in must never
///    touch McGraw Hill.
/// 4. Nothing else. There is no Penn gate: Ed is Penn-only because its
///    output is pooled on the server by Canvas course id; McGraw Hill data is
///    never pooled, so any school may read its own.
public enum ReaderGate {
    public static func mcgrawHill(
        compiledIn: Bool,
        switches: ReaderSwitches,
        debugForced: Bool,
        isUsingFixtureData: Bool
    ) -> Bool {
        guard compiledIn, !isUsingFixtureData else { return false }
        return switches.mcgrawHill || debugForced
    }
}
