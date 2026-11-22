import Foundation

/// The rules for the one anonymous count each install sends: the school's
/// Canvas host and whether the install is new. Pure on purpose: no clock, no
/// defaults and no network, so the truth table is a test and the reporter
/// (`InstallCountReporter`, UI target) is only plumbing.
///
/// Why it exists: Apple reports no downloads by school, and the owner wants
/// to know how many students have set Smooth up at each one. What leaves the
/// phone is exactly two words, the host and `new` / `existing`. No id, no
/// name, no version, no account.
public enum InstallCountRule {
    /// How long to wait after a failed attempt (an older server's 404, a 5xx,
    /// no network). Foreground launches are frequent, and a server that is
    /// down should not be asked on every one of them.
    public static let retryInterval: TimeInterval = 6 * 60 * 60

    public enum Outcome: Equatable, Sendable {
        /// Counted, or refused for good: never ask again.
        case done
        /// Try again after `retryInterval`.
        case retryLater
    }

    /// "existing" for an install that had finished onboarding before this
    /// build first ran (an update), "new" for everyone else. The caller
    /// records the fact once, at the first launch of a build with this code;
    /// asking later would call a fresh sign-up "existing".
    public static func kind(onboardedBeforeThisBuild: Bool) -> String {
        onboardedBeforeThisBuild ? "existing" : "new"
    }

    /// A plain DNS hostname, lowercased and trimmed, or nil. 4 to 100
    /// characters, only `a-z 0-9 . -`: no scheme, port, path or userinfo can
    /// survive, so nothing but a host is ever sent. One trailing dot (the
    /// fully-qualified spelling) is dropped; after that the host must match
    /// the Worker's own rule, `^[a-z0-9-]+(\.[a-z0-9-]+)+$`, label by label.
    /// A looser rule here sent hosts the Worker answers 400, and a 400 is
    /// `.done`, so that install was never counted (3.5.0 test pass, R-L3).
    public static func normalizedHost(_ host: String?) -> String? {
        guard let host else { return nil }
        var value = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        if value.hasSuffix(".") { value.removeLast() }
        guard (4...100).contains(value.count) else { return nil }
        let allowed = Set("abcdefghijklmnopqrstuvwxyz0123456789-")
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2,
              labels.allSatisfy({ !$0.isEmpty && $0.allSatisfy { allowed.contains($0) } })
        else { return nil }
        return value
    }

    /// True only when everything allows it. Each blocker alone makes it false.
    public static func shouldAttempt(
        featureEnabled: Bool,
        onboardingComplete: Bool,
        canvasConnected: Bool,
        usingFixtureData: Bool,
        isTestRunner: Bool,
        alreadyReported: Bool,
        host: String?,
        lastAttempt: Date?,
        now: Date
    ) -> Bool {
        guard featureEnabled, onboardingComplete, canvasConnected,
              !usingFixtureData, !isTestRunner, !alreadyReported,
              host != nil else { return false }
        // A stamp in the future (a clock that was once set ahead) is no
        // evidence of a recent try; honouring it would block the count until
        // real time passed it, which for a year-2100 clock is never (R-L2).
        if let lastAttempt, lastAttempt <= now,
           now.timeIntervalSince(lastAttempt) < retryInterval { return false }
        return true
    }

    /// 2xx is counted and 400 is the server refusing this host's shape for
    /// good; retrying either is pointless. Anything else, and a missing status
    /// (a network error), is tried again later.
    public static func outcome(forStatus status: Int?) -> Outcome {
        guard let status else { return .retryLater }
        if (200..<300).contains(status) || status == 400 { return .done }
        return .retryLater
    }

    /// `{"host":"...","kind":"..."}`, written by hand so the key order and
    /// the escaping are stable (a dictionary through `JSONSerialization` makes
    /// no promise about order). Safe because the host has already passed
    /// `normalizedHost` (no quote, backslash or control character can be in
    /// it) and the kind is one of two fixed words.
    public static func body(host: String, kind: String) -> Data {
        Data("{\"host\":\"\(host)\",\"kind\":\"\(kind)\"}".utf8)
    }
}
