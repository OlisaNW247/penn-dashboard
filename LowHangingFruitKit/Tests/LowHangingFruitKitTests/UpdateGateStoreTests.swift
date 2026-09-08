import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// UI-half coverage for the forced-update version gate: `UpdateGateStore`'s
/// fail-open guarantees, its throttle, and per-version banner dismissal. The
/// pure decode/verdict-table half (`AppVersion`, `UpdatePolicy`,
/// `UpdateManifestClient.policy(from:)`, `UpdatePolicyCache`) is already
/// covered by `UpdateGateTests`; this file only exercises the parts that
/// glue those pieces to a real (stubbed) `URLSession` and to `UserDefaults`.
///
/// `UpdateGateStore` is `@MainActor`, so the whole suite is too.
///
/// Every test that touches `UserDefaults` opens its own scratch
/// `UserDefaults(suiteName:)` — both for `UpdatePolicyCache` and for the
/// store's own `defaults:` parameter (banner-dismissal storage) — and tears
/// it down with `removePersistentDomain(forName:)`. This project's tests
/// share `UserDefaults.standard` (which is what `UserDefaults.lhf` resolves
/// to under `swift test`, see `SharedDefaults.isTestRunner`), and a suite
/// that writes the real store breaks whichever suite runs next.
@MainActor
@Suite("Update gate store")
struct UpdateGateStoreTests {

    // MARK: - Scratch defaults

    private func scratchDefaults() -> (UserDefaults, String) {
        let name = "lhf.tests.updateGateStore.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    private func destroy(_ name: String) {
        UserDefaults.standard.removePersistentDomain(forName: name)
    }

    // MARK: - Stubbed networking

    /// Always fails with a generic error, regardless of what's requested —
    /// this suite only needs to prove `refresh()` fails open, never that a
    /// particular response shape decodes (that's `UpdateGateTests`' job via
    /// the pure `UpdateManifestClient.policy(from:)` decoder).
    private final class FailingURLProtocol: URLProtocol {
        struct StubError: Error {}

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            client?.urlProtocol(self, didFailWithError: StubError())
        }

        override func stopLoading() {}
    }

    private func failingSession() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [FailingURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    // MARK: - Fixtures

    private static let manifestURL = URL(string: "https://example.com/update-manifest.json")!

    private func version(_ string: String) throws -> AppVersion {
        try #require(AppVersion(string))
    }

    // MARK: - nil manifest URL: inert

    @Test("a nil manifest URL leaves the verdict ok and performs no fetch")
    func nilManifestURLIsInert() async throws {
        let store = UpdateGateStore(
            installedVersion: try version("1.0.0"),
            manifestURL: nil,
            session: failingSession(),
            cache: UpdatePolicyCache(defaults: scratchDefaults().0),
            now: { Date(timeIntervalSince1970: 1_000_000) }
        )
        #expect(store.verdict == .ok)
        await store.refresh()
        #expect(store.verdict == .ok)
    }

    // MARK: - nil installed version: inert

    @Test("a nil installed version leaves the verdict ok")
    func nilInstalledVersionIsInert() async {
        let (defaults, name) = scratchDefaults()
        defer { destroy(name) }
        // Seed a blocking policy the store must NOT apply, since it has no
        // installed version to compare it against.
        let cache = UpdatePolicyCache(defaults: defaults)
        cache.save(
            UpdatePolicy(minimumVersion: AppVersion("99.0.0")),
            at: Date(timeIntervalSince1970: 1_000_000)
        )

        let store = UpdateGateStore(
            installedVersion: nil,
            manifestURL: Self.manifestURL,
            session: failingSession(),
            cache: cache,
            now: { Date(timeIntervalSince1970: 1_000_100) }
        )
        #expect(store.verdict == .ok)
        await store.refresh()
        #expect(store.verdict == .ok)
    }

    // MARK: - Network failure fails open

    @Test("a network failure leaves the verdict ok when nothing was cached")
    func networkFailureFailsOpen() async throws {
        let (defaults, name) = scratchDefaults()
        defer { destroy(name) }

        let store = UpdateGateStore(
            installedVersion: try version("1.0.0"),
            manifestURL: Self.manifestURL,
            session: failingSession(),
            cache: UpdatePolicyCache(defaults: defaults),
            now: { Date(timeIntervalSince1970: 1_000_000) }
        )
        #expect(store.verdict == .ok)
        await store.refresh()
        #expect(store.verdict == .ok)
    }

    // MARK: - The critical one: a network failure must not clear a cached block

    @Test("a network failure does not clear a verdict already established from cache")
    func networkFailureNeverDowngradesACachedBlock() async throws {
        let (defaults, name) = scratchDefaults()
        defer { destroy(name) }

        let cache = UpdatePolicyCache(defaults: defaults)
        cache.save(
            UpdatePolicy(minimumVersion: try version("2.0.0"), message: "please update"),
            at: Date(timeIntervalSince1970: 1_000_000)
        )

        let store = UpdateGateStore(
            installedVersion: try version("1.0.0"),
            manifestURL: Self.manifestURL,
            session: failingSession(),
            cache: cache,
            now: { Date(timeIntervalSince1970: 1_000_100) }
        )
        // Honored synchronously at init, no network needed.
        guard case .updateRequired(let minimum, let message) = store.verdict else {
            Issue.record("expected .updateRequired from the cache alone, got \(store.verdict)")
            return
        }
        #expect(minimum == (try version("2.0.0")))
        #expect(message == "please update")

        // A failing fetch must leave that exactly as it was — this is the
        // one bad outcome fail-open exists to prevent: a network blip must
        // never look like "the block is lifted."
        await store.refresh()
        guard case .updateRequired(let minimumAfter, _) = store.verdict else {
            Issue.record("network failure cleared a cached block: \(store.verdict)")
            return
        }
        #expect(minimumAfter == (try version("2.0.0")))
    }

    // MARK: - Cached policy honored at init, no network at all

    @Test("a cached blocking policy is honored at init with no network")
    func cachedBlockHonoredAtInitWithNoNetwork() async throws {
        let (defaults, name) = scratchDefaults()
        defer { destroy(name) }

        let cache = UpdatePolicyCache(defaults: defaults)
        cache.save(
            UpdatePolicy(minimumVersion: try version("3.0.0")),
            at: Date(timeIntervalSince1970: 1_000_000)
        )

        // `manifestURL: nil` (in addition to a session that would fail
        // anyway) proves this needs no network whatsoever: the constructor
        // itself must resolve the verdict from the cache alone.
        let store = UpdateGateStore(
            installedVersion: try version("1.0.0"),
            manifestURL: nil,
            session: failingSession(),
            cache: cache,
            now: { Date(timeIntervalSince1970: 1_000_100) }
        )
        guard case .updateRequired(let minimum, _) = store.verdict else {
            Issue.record("expected .updateRequired, got \(store.verdict)")
            return
        }
        #expect(minimum == (try version("3.0.0")))
    }

    // MARK: - An updated student is never stranded

    @Test("once the installed version meets a cached policy's minimum, the verdict is ok")
    func updatedInstallIsNeverStranded() async throws {
        let (defaults, name) = scratchDefaults()
        defer { destroy(name) }

        let cache = UpdatePolicyCache(defaults: defaults)
        cache.save(
            UpdatePolicy(minimumVersion: try version("3.0.0")),
            at: Date(timeIntervalSince1970: 1_000_000)
        )

        // Same cached policy as the previous test, but the installed
        // version now meets the floor — the whole point of never caching
        // the *verdict*, only the policy, and recomputing locally every
        // time: once the student actually updates, no network round trip
        // is required to unblock them.
        let store = UpdateGateStore(
            installedVersion: try version("3.0.0"),
            manifestURL: nil,
            session: failingSession(),
            cache: cache,
            now: { Date(timeIntervalSince1970: 1_000_100) }
        )
        #expect(store.verdict == .ok)
    }

    // MARK: - Banner dismissal persists per version

    @Test("banner dismissal persists for the same version and does not suppress a newer one")
    func bannerDismissalPersistsPerVersion() async throws {
        let (cacheDefaults, cacheName) = scratchDefaults()
        let (storeDefaults, storeName) = scratchDefaults()
        defer {
            destroy(cacheName)
            destroy(storeName)
        }

        let cache = UpdatePolicyCache(defaults: cacheDefaults)
        cache.save(
            UpdatePolicy(latestVersion: try version("2.1.0")),
            at: Date(timeIntervalSince1970: 1_000_000)
        )

        let store = UpdateGateStore(
            installedVersion: try version("2.0.0"),
            manifestURL: nil,
            session: failingSession(),
            cache: cache,
            now: { Date(timeIntervalSince1970: 1_000_100) },
            defaults: storeDefaults
        )
        guard case .updateAvailable(let latest) = store.verdict else {
            Issue.record("expected .updateAvailable, got \(store.verdict)")
            return
        }
        #expect(latest == (try version("2.1.0")))
        #expect(!store.isAvailableBannerDismissed)

        store.dismissAvailableBanner()
        #expect(store.isAvailableBannerDismissed)

        // A fresh store reading the same defaults suite (simulating the next
        // launch) should see the dismissal survive...
        let relaunched = UpdateGateStore(
            installedVersion: try version("2.0.0"),
            manifestURL: nil,
            session: failingSession(),
            cache: cache,
            now: { Date(timeIntervalSince1970: 1_000_200) },
            defaults: storeDefaults
        )
        #expect(relaunched.isAvailableBannerDismissed)

        // ...but a newer latest version must not be suppressed by it.
        let newerCache = UpdatePolicyCache(defaults: cacheDefaults)
        newerCache.save(
            UpdatePolicy(latestVersion: try version("2.2.0")),
            at: Date(timeIntervalSince1970: 1_000_300)
        )
        let newerStore = UpdateGateStore(
            installedVersion: try version("2.0.0"),
            manifestURL: nil,
            session: failingSession(),
            cache: newerCache,
            now: { Date(timeIntervalSince1970: 1_000_400) },
            defaults: storeDefaults
        )
        guard case .updateAvailable(let newerLatest) = newerStore.verdict else {
            Issue.record("expected .updateAvailable, got \(newerStore.verdict)")
            return
        }
        #expect(newerLatest == (try version("2.2.0")))
        #expect(!newerStore.isAvailableBannerDismissed)
    }
}
