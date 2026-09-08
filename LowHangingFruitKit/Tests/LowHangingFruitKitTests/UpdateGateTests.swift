import Foundation
import Testing
@testable import LowHangingFruitKit

/// Pure-half coverage for the forced-update version gate: `AppVersion`
/// parsing/ordering, `UpdatePolicy`'s decode-time sanitization (the security
/// boundary — see the doc comment on `UpdatePolicy`), the verdict table, and
/// `UpdatePolicyCache`'s round-trip and expiry. No UI, no networking beyond
/// the pure `UpdateManifestClient.policy(from:)` decoder.
@Suite("Update gate")
struct UpdateGateTests {

    // MARK: - AppVersion parsing

    @Test("valid dotted forms parse", arguments: [
        ("2", [2]),
        ("2.0", [2, 0]),
        ("2.0.0", [2, 0, 0]),
        ("2.0.0.1", [2, 0, 0, 1]),
        ("0", [0]),
        ("10.20.30", [10, 20, 30]),
    ])
    func validVersionsParse(input: String, expectedComponents: [Int]) {
        let version = AppVersion(input)
        #expect(version != nil)
        #expect(version?.description == expectedComponents.map(String.init).joined(separator: "."))
    }

    @Test("invalid strings fail to parse", arguments: [
        "", "abc", "2.x", "-1.0", "2..0", ".", "2.", ".2", "2. 0", "2,0",
    ])
    func invalidVersionsFailToParse(input: String) {
        #expect(AppVersion(input) == nil)
    }

    @Test("whitespace-padded input is trimmed before parsing")
    func whitespaceIsTrimmed() {
        #expect(AppVersion("  2.0.0  ") == AppVersion("2.0.0"))
        #expect(AppVersion("\t2.1\n") != nil)
        #expect(AppVersion("   ") == nil)
    }

    // MARK: - AppVersion comparison

    @Test("missing trailing components are treated as zero for equality")
    func shortFormsEqualPaddedForms() {
        #expect(AppVersion("2.0") == AppVersion("2.0.0"))
        #expect(AppVersion("2") == AppVersion("2.0.0.0"))
        #expect(AppVersion("2.0.0") != AppVersion("2.0.1"))
    }

    @Test("component-wise ordering, not string ordering")
    func componentWiseOrdering() throws {
        let a = try #require(AppVersion("2.0.0"))
        let b = try #require(AppVersion("2.0.1"))
        #expect(a < b)

        // String comparison would say "2.10.0" < "2.9.0" because "1" < "9"
        // lexicographically. Numeric component comparison must not.
        let tenDotZero = try #require(AppVersion("2.10.0"))
        let nineDotZero = try #require(AppVersion("2.9.0"))
        #expect(tenDotZero > nineDotZero)
        #expect(!(tenDotZero < nineDotZero))
    }

    @Test("bundle convenience reads CFBundleShortVersionString")
    func bundleConvenienceReadsInfoPlist() {
        // The test bundle carries no CFBundleShortVersionString, so this must
        // resolve to nil rather than crash or fabricate a version.
        #expect(AppVersion(bundle: Bundle.module) == nil)
    }

    // MARK: - Verdict table

    @Test("below minimum is required, with the message attached")
    func belowMinimumIsRequired() {
        let policy = UpdatePolicy(
            minimumVersion: AppVersion("2.0.0"),
            latestVersion: AppVersion("2.1.0"),
            message: "Please update."
        )
        let verdict = policy.verdict(forInstalled: try! #require(AppVersion("1.9.0")))
        guard case .updateRequired(let minimum, let message) = verdict else {
            Issue.record("expected .updateRequired, got \(verdict)")
            return
        }
        #expect(minimum == AppVersion("2.0.0"))
        #expect(message == "Please update.")
    }

    @Test("between minimum and latest is available, not required")
    func betweenMinimumAndLatestIsAvailable() {
        let policy = UpdatePolicy(
            minimumVersion: AppVersion("2.0.0"),
            latestVersion: AppVersion("2.1.0")
        )
        let verdict = policy.verdict(forInstalled: try! #require(AppVersion("2.0.5")))
        #expect(verdict == .updateAvailable(latest: try! #require(AppVersion("2.1.0"))))
    }

    @Test("at or above latest is ok")
    func atOrAboveLatestIsOk() {
        let policy = UpdatePolicy(
            minimumVersion: AppVersion("2.0.0"),
            latestVersion: AppVersion("2.1.0")
        )
        #expect(policy.verdict(forInstalled: try! #require(AppVersion("2.1.0"))) == .ok)
        #expect(policy.verdict(forInstalled: try! #require(AppVersion("2.5.0"))) == .ok)
    }

    @Test("an empty policy is always ok")
    func emptyPolicyIsAlwaysOk() {
        let policy = UpdatePolicy()
        #expect(policy.verdict(forInstalled: try! #require(AppVersion("0.0.1"))) == .ok)
        #expect(policy.verdict(forInstalled: try! #require(AppVersion("99.0.0"))) == .ok)
    }

    @Test("a nil minimumVersion can never produce updateRequired")
    func nilMinimumNeverBlocks() {
        let policy = UpdatePolicy(minimumVersion: nil, latestVersion: AppVersion("50.0.0"))
        let verdict = policy.verdict(forInstalled: try! #require(AppVersion("0.0.1")))
        if case .updateRequired = verdict {
            Issue.record("nil minimumVersion produced .updateRequired")
        }
    }

    // MARK: - appStoreURL allowlist

    @Test("allowed app store URL forms survive decoding", arguments: [
        "https://apps.apple.com/us/app/id123456789",
        "https://itunes.apple.com/us/app/id123456789",
        "itms-apps://itunes.apple.com/app/id123456789",
    ])
    func allowedURLsSurvive(urlString: String) throws {
        let json = #"{"appStoreURL": "\#(urlString)"}"#
        let policy = try UpdateManifestClient.policy(from: Data(json.utf8))
        #expect(policy.appStoreURL?.absoluteString == urlString)
    }

    @Test("disallowed app store URL forms are dropped, and the rest of the policy still decodes", arguments: [
        "https://evil.example.com/app/id123456789",
        "http://apps.apple.com/us/app/id123456789",
        "javascript:alert(1)",
        "not a url at all \u{0} \u{1}",
        "data:text/html,<script>alert(1)</script>",
        // The scheme alone is not evidence: a custom scheme can be claimed by
        // any installed app, so `itms-apps` gets the same host check as https.
        "itms-apps://evil.example.com/app/id123456789",
    ])
    func disallowedURLsAreDroppedButRestSurvives(urlString: String) throws {
        let payload: [String: String] = [
            "minimumVersion": "2.0.0",
            "message": "Update required.",
            "appStoreURL": urlString,
        ]
        let data = try JSONEncoder().encode(payload)
        let policy = try UpdateManifestClient.policy(from: data)

        #expect(policy.appStoreURL == nil)
        #expect(policy.minimumVersion == AppVersion("2.0.0"))
        #expect(policy.message == "Update required.")
    }

    @Test("missing appStoreURL decodes as nil without error")
    func missingURLDecodesAsNil() throws {
        let policy = try UpdateManifestClient.policy(from: Data("{}".utf8))
        #expect(policy.appStoreURL == nil)
        #expect(policy.minimumVersion == nil)
        #expect(policy.latestVersion == nil)
        #expect(policy.message == nil)
    }

    // MARK: - Message sanitization

    @Test("message is trimmed and capped at 300 characters")
    func messageIsCapped() throws {
        let longMessage = String(repeating: "a", count: 500)
        let json: [String: String] = ["message": "  \(longMessage)  "]
        let data = try JSONEncoder().encode(json)
        let policy = try UpdateManifestClient.policy(from: data)

        #expect(policy.message?.count == 300)
        #expect(policy.message == String(repeating: "a", count: 300))
    }

    @Test("control characters and newlines collapse to single spaces")
    func controlCharactersCollapse() throws {
        let raw = "Line one\nLine\ttwo\r\nLine\u{0007}three"
        let json: [String: String] = ["message": raw]
        let data = try JSONEncoder().encode(json)
        let policy = try UpdateManifestClient.policy(from: data)

        #expect(policy.message == "Line one Line two Line three")
    }

    @Test("a message that is only whitespace/control characters decodes to nil")
    func blankMessageBecomesNil() throws {
        let json: [String: String] = ["message": "   \n\t  "]
        let data = try JSONEncoder().encode(json)
        let policy = try UpdateManifestClient.policy(from: data)
        #expect(policy.message == nil)
    }

    // MARK: - Malformed JSON

    @Test("malformed JSON throws rather than producing a partial policy")
    func malformedJSONThrows() {
        let data = Data("{ this is not json".utf8)
        #expect(throws: (any Error).self) {
            try UpdateManifestClient.policy(from: data)
        }
    }

    @Test("truncated JSON throws")
    func truncatedJSONThrows() {
        let data = Data(#"{"minimumVersion": "2.0.0""#.utf8)
        #expect(throws: (any Error).self) {
            try UpdateManifestClient.policy(from: data)
        }
    }

    @Test("a full manifest decodes every field")
    func fullManifestDecodes() throws {
        let json = """
        {
          "minimumVersion": "2.0.0",
          "latestVersion": "2.1.0",
          "message": "This version can no longer read Canvas.",
          "appStoreURL": "https://apps.apple.com/app/id0000000000"
        }
        """
        let policy = try UpdateManifestClient.policy(from: Data(json.utf8))
        #expect(policy.minimumVersion == AppVersion("2.0.0"))
        #expect(policy.latestVersion == AppVersion("2.1.0"))
        #expect(policy.message == "This version can no longer read Canvas.")
        #expect(policy.appStoreURL?.absoluteString == "https://apps.apple.com/app/id0000000000")
    }

    @Test("an unparseable version string decodes to nil, not a thrown error")
    func unparseableVersionBecomesNil() throws {
        let json: [String: String] = ["minimumVersion": "not-a-version", "message": "hello"]
        let data = try JSONEncoder().encode(json)
        let policy = try UpdateManifestClient.policy(from: data)
        #expect(policy.minimumVersion == nil)
        #expect(policy.message == "hello")
    }

    // MARK: - UpdatePolicyCache

    /// A throwaway App Group–suite-shaped domain. Never `.standard` — this
    /// project's tests share `UserDefaults.standard`, and leaked state fails
    /// the *next* suite, not this one. `removePersistentDomain` is called on
    /// `.standard` because domains are addressed by name, not by which
    /// `UserDefaults` instance created them (see `CoursePreferencesTests`).
    private func scratchDefaults() -> (UserDefaults, String) {
        let name = "lhf.tests.updateGate.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    private func destroy(_ name: String) {
        UserDefaults.standard.removePersistentDomain(forName: name)
    }

    @Test("cache round-trips a saved policy")
    func cacheRoundTrips() {
        let (defaults, name) = scratchDefaults()
        defer { destroy(name) }
        let cache = UpdatePolicyCache(defaults: defaults)

        let policy = UpdatePolicy(
            minimumVersion: AppVersion("2.0.0"),
            latestVersion: AppVersion("2.1.0"),
            message: "hello",
            appStoreURL: URL(string: "https://apps.apple.com/app/id123")
        )
        cache.save(policy, at: Date(timeIntervalSince1970: 1_000_000))
        let loaded = cache.load(now: Date(timeIntervalSince1970: 1_000_100))
        #expect(loaded == policy)
    }

    @Test("a policy stored 31 days ago is too old to trust")
    func staleCacheIsRejected() {
        let (defaults, name) = scratchDefaults()
        defer { destroy(name) }
        let cache = UpdatePolicyCache(defaults: defaults)

        let savedAt = Date(timeIntervalSince1970: 1_000_000)
        cache.save(UpdatePolicy(message: "old"), at: savedAt)

        let thirtyOneDaysLater = savedAt.addingTimeInterval(31 * 24 * 60 * 60)
        #expect(cache.load(now: thirtyOneDaysLater) == nil)
    }

    @Test("a policy stored 29 days ago is still trusted")
    func freshEnoughCacheLoads() {
        let (defaults, name) = scratchDefaults()
        defer { destroy(name) }
        let cache = UpdatePolicyCache(defaults: defaults)

        let savedAt = Date(timeIntervalSince1970: 1_000_000)
        let policy = UpdatePolicy(message: "still good")
        cache.save(policy, at: savedAt)

        let twentyNineDaysLater = savedAt.addingTimeInterval(29 * 24 * 60 * 60)
        #expect(cache.load(now: twentyNineDaysLater) == policy)
    }

    @Test("load returns nil when nothing has been cached")
    func absentCacheIsNil() {
        let (defaults, name) = scratchDefaults()
        defer { destroy(name) }
        let cache = UpdatePolicyCache(defaults: defaults)
        #expect(cache.load() == nil)
    }

    @Test("clear removes a saved policy")
    func clearRemovesPolicy() {
        let (defaults, name) = scratchDefaults()
        defer { destroy(name) }
        let cache = UpdatePolicyCache(defaults: defaults)

        cache.save(UpdatePolicy(message: "to be cleared"), at: Date())
        cache.clear()
        #expect(cache.load() == nil)
    }
}
