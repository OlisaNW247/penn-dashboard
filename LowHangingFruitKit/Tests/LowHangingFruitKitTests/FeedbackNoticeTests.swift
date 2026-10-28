import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// The manifest's one-time feedback card: the Kit-side sanitizing
/// (`FeedbackNotice`, `UpdatePolicy.feedback`) and `UpdateGateStore`'s
/// handling of it. SwiftUI is not rendered here.
@Suite("Feedback notice decoding")
struct FeedbackNoticeDecodingTests {

    private static let goodURL =
        "https://docs.google.com/forms/d/e/1FAIpQLScZJ4BBXicAOFYSbCkHGcM5kWcDD8OXSSWtkK64kSSUO4WcJQ/viewform"

    private func notice(_ json: String) throws -> FeedbackNotice {
        try JSONDecoder().decode(FeedbackNotice.self, from: Data(json.utf8))
    }

    private func noticeJSON(
        id: String = "2026-10-smoothie",
        title: String? = "how's smooth so far?",
        subtitle: String? = "takes 2 minutes.",
        url: String = FeedbackNoticeDecodingTests.goodURL
    ) -> String {
        var fields = ["\"id\": \"\(id)\"", "\"url\": \"\(url)\""]
        if let title { fields.append("\"title\": \"\(title)\"") }
        if let subtitle { fields.append("\"subtitle\": \"\(subtitle)\"") }
        return "{" + fields.joined(separator: ", ") + "}"
    }

    @Test("a valid notice decodes")
    func valid() throws {
        let decoded = try notice(noticeJSON())
        #expect(decoded.id == "2026-10-smoothie")
        #expect(decoded.title == "how's smooth so far?")
        #expect(decoded.subtitle == "takes 2 minutes.")
        #expect(decoded.url.host == "docs.google.com")
    }

    @Test("forms.gle is allowed too")
    func shortHost() throws {
        let decoded = try notice(noticeJSON(url: "https://forms.gle/abc123"))
        #expect(decoded.url.host == "forms.gle")
    }

    @Test("a bad id fails the whole notice", arguments: [
        "", "has space", "slash/slash", "semi;colon", String(repeating: "a", count: 65),
    ])
    func badID(id: String) {
        #expect(throws: (any Error).self) { try notice(noticeJSON(id: id)) }
    }

    @Test("an id of exactly 64 characters is fine")
    func longestID() throws {
        let id = String(repeating: "a", count: 64)
        #expect(try notice(noticeJSON(id: id)).id == id)
    }

    @Test("a url that is not https on an allowed host fails the whole notice", arguments: [
        "http://docs.google.com/forms/d/e/x/viewform",
        "https://evil.example.com/forms",
        "https://docs.google.com.evil.example.com/x",
        "https://notforms.gle/abc",
        "javascript:alert(1)",
        "not a url",
    ])
    func badURL(url: String) {
        #expect(throws: (any Error).self) { try notice(noticeJSON(url: url)) }
    }

    @Test("a missing or blank title fails the whole notice")
    func missingTitle() {
        #expect(throws: (any Error).self) { try notice(noticeJSON(title: nil)) }
        #expect(throws: (any Error).self) { try notice(noticeJSON(title: "   ")) }
    }

    @Test("a long title and subtitle are capped at 80 characters")
    func capped() throws {
        let long = String(repeating: "x", count: 200)
        let decoded = try notice(noticeJSON(title: long, subtitle: long))
        #expect(decoded.title.count == 80)
        #expect(decoded.subtitle?.count == 80)
    }

    @Test("a blank or missing subtitle becomes nil")
    func blankSubtitle() throws {
        #expect(try notice(noticeJSON(subtitle: "   ")).subtitle == nil)
        #expect(try notice(noticeJSON(subtitle: nil)).subtitle == nil)
    }

    @Test("control characters in the title collapse to single spaces")
    func controlCharacters() throws {
        let decoded = try notice(noticeJSON(title: "how\\u0009\\u000Ais smooth"))
        #expect(decoded.title == "how is smooth")
    }

    // MARK: Inside the update policy

    private func policy(_ feedback: String?) throws -> UpdatePolicy {
        var body = "\"minimumVersion\": \"3.2.1\", \"latestVersion\": \"3.2.1\""
        if let feedback { body += ", \"feedback\": \(feedback)" }
        return try UpdateManifestClient.policy(from: Data("{\(body)}".utf8))
    }

    @Test("a manifest with valid feedback decodes it beside the version fields")
    func policyWithFeedback() throws {
        let decoded = try policy(noticeJSON())
        #expect(decoded.minimumVersion == AppVersion("3.2.1"))
        #expect(decoded.feedback?.id == "2026-10-smoothie")
    }

    @Test("malformed feedback never costs the minimum version")
    func malformedFeedbackKeepsMinimum() throws {
        for bad in [
            noticeJSON(url: "https://evil.example.com/x"),
            noticeJSON(title: nil),
            "\"just a string\"",
            "42",
            "[1, 2]",
            "null",
        ] {
            let decoded = try policy(bad)
            #expect(decoded.minimumVersion == AppVersion("3.2.1"))
            #expect(decoded.feedback == nil)
        }
    }

    @Test("a manifest without the key decodes as before")
    func policyWithoutFeedback() throws {
        let decoded = try policy(nil)
        #expect(decoded.minimumVersion == AppVersion("3.2.1"))
        #expect(decoded.feedback == nil)
    }

    @Test("the cache round-trips feedback")
    func cacheRoundTrip() throws {
        let name = "lhf.tests.feedbackNotice.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { UserDefaults.standard.removePersistentDomain(forName: name) }

        let saved = FeedbackNotice(
            id: "abc", title: "hi", subtitle: nil,
            url: try #require(URL(string: "https://forms.gle/abc"))
        )
        let cache = UpdatePolicyCache(defaults: defaults)
        let at = Date(timeIntervalSince1970: 1_000_000)
        cache.save(UpdatePolicy(minimumVersion: AppVersion("3.2.1"), feedback: saved), at: at)

        let loaded = try #require(cache.load(now: at.addingTimeInterval(60)))
        #expect(loaded.feedback == saved)
        #expect(loaded.minimumVersion == AppVersion("3.2.1"))
    }
}

@MainActor
@Suite("Feedback notice store")
struct FeedbackNoticeStoreTests {

    private func scratchDefaults() -> (UserDefaults, String) {
        let name = "lhf.tests.feedbackStore.\(UUID().uuidString)"
        return (UserDefaults(suiteName: name)!, name)
    }

    private func destroy(_ name: String) {
        UserDefaults.standard.removePersistentDomain(forName: name)
    }

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

    private static let manifestURL = URL(string: "https://example.com/update-manifest.json")!
    private static let savedAt = Date(timeIntervalSince1970: 1_000_000)

    private func notice(_ id: String) -> FeedbackNotice {
        FeedbackNotice(
            id: id, title: "how's smooth so far?", subtitle: "takes 2 minutes.",
            url: URL(string: "https://forms.gle/abc")!
        )
    }

    private func makeStore(
        defaults: UserDefaults,
        policy: UpdatePolicy?,
        installed: String = "1.0.0"
    ) -> UpdateGateStore {
        let cache = UpdatePolicyCache(defaults: defaults)
        if let policy { cache.save(policy, at: Self.savedAt) }
        return UpdateGateStore(
            installedVersion: AppVersion(installed),
            manifestURL: Self.manifestURL,
            session: failingSession(),
            cache: cache,
            now: { Self.savedAt.addingTimeInterval(100) },
            defaults: defaults,
            clearNotifications: {}
        )
    }

    @Test("the notice comes from the cached policy at init")
    func fromCache() {
        let (defaults, name) = scratchDefaults()
        defer { destroy(name) }
        let store = makeStore(defaults: defaults, policy: UpdatePolicy(feedback: notice("a")))
        #expect(store.feedbackNotice == notice("a"))
        #expect(store.visibleFeedbackNotice == notice("a"))
    }

    @Test("no cached policy means no notice")
    func nothingCached() {
        let (defaults, name) = scratchDefaults()
        defer { destroy(name) }
        let store = makeStore(defaults: defaults, policy: nil)
        #expect(store.feedbackNotice == nil)
        #expect(store.visibleFeedbackNotice == nil)
    }

    @Test("visible until handled, then never again, even for a fresh store")
    func handledSticks() {
        let (defaults, name) = scratchDefaults()
        defer { destroy(name) }
        let policy = UpdatePolicy(feedback: notice("a"))
        let first = makeStore(defaults: defaults, policy: policy)
        #expect(first.visibleFeedbackNotice != nil)
        first.markFeedbackNoticeHandled()
        #expect(first.visibleFeedbackNotice == nil)

        let second = makeStore(defaults: defaults, policy: policy)
        #expect(second.feedbackNotice != nil)
        #expect(second.visibleFeedbackNotice == nil)
    }

    @Test("a different id is visible again")
    func newIDShowsAgain() {
        let (defaults, name) = scratchDefaults()
        defer { destroy(name) }
        let first = makeStore(defaults: defaults, policy: UpdatePolicy(feedback: notice("a")))
        first.markFeedbackNoticeHandled()

        let second = makeStore(defaults: defaults, policy: UpdatePolicy(feedback: notice("b")))
        #expect(second.visibleFeedbackNotice == notice("b"))
    }

    @Test("hidden while the update wall is up")
    func hiddenBehindTheWall() {
        let (defaults, name) = scratchDefaults()
        defer { destroy(name) }
        let policy = UpdatePolicy(minimumVersion: AppVersion("2.0.0"), feedback: notice("a"))
        let store = makeStore(defaults: defaults, policy: policy)
        guard case .updateRequired = store.verdict else {
            Issue.record("expected the wall")
            return
        }
        #expect(store.feedbackNotice != nil)
        #expect(store.visibleFeedbackNotice == nil)
    }

    @Test("a failed fetch keeps the previous notice")
    func failedFetchKeepsNotice() async {
        let (defaults, name) = scratchDefaults()
        defer { destroy(name) }
        let store = makeStore(defaults: defaults, policy: UpdatePolicy(feedback: notice("a")))
        await store.refresh()
        #expect(store.feedbackNotice == notice("a"))
        #expect(store.visibleFeedbackNotice == notice("a"))
    }
}
