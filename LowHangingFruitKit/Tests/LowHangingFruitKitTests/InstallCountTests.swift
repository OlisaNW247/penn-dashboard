import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

// The anonymous install count (2026-11-22): the school's Canvas host and
// `new` / `existing`, once per install. The rule is pure; the reporter is
// driven against a URLProtocol stub and a scratch defaults suite, never the
// shared domain.

@Suite("Install count rule")
struct InstallCountRuleTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func attempt(
        feature: Bool = true, onboarded: Bool = true, connected: Bool = true,
        fixture: Bool = false, testRunner: Bool = false, reported: Bool = false,
        host: String? = "canvas.upenn.edu", last: Date? = nil
    ) -> Bool {
        InstallCountRule.shouldAttempt(
            featureEnabled: feature, onboardingComplete: onboarded, canvasConnected: connected,
            usingFixtureData: fixture, isTestRunner: testRunner, alreadyReported: reported,
            host: host, lastAttempt: last, now: now)
    }

    @Test("everything allowing it is a yes")
    func allClear() {
        #expect(attempt())
        #expect(attempt(last: now.addingTimeInterval(-7 * 3600)))
    }

    @Test("each blocker alone is a no")
    func blockers() {
        #expect(!attempt(feature: false))
        #expect(!attempt(onboarded: false))
        #expect(!attempt(connected: false))
        #expect(!attempt(fixture: true))
        #expect(!attempt(testRunner: true))
        #expect(!attempt(reported: true))
        #expect(!attempt(host: nil))
    }

    @Test("the retry wait is six hours")
    func wait() {
        #expect(InstallCountRule.retryInterval == 6 * 3600)
        #expect(!attempt(last: now.addingTimeInterval(-(5 * 3600 + 59 * 60))))
        #expect(attempt(last: now.addingTimeInterval(-6 * 3600)))
    }

    @Test("kind is existing only for an install that was onboarded before this build")
    func kind() {
        #expect(InstallCountRule.kind(onboardedBeforeThisBuild: true) == "existing")
        #expect(InstallCountRule.kind(onboardedBeforeThisBuild: false) == "new")
    }

    @Test("a plain hostname passes, anything else is refused")
    func hosts() {
        #expect(InstallCountRule.normalizedHost("canvas.upenn.edu") == "canvas.upenn.edu")
        #expect(InstallCountRule.normalizedHost("Canvas.UPenn.edu ") == "canvas.upenn.edu")
        #expect(InstallCountRule.normalizedHost("https://canvas.upenn.edu") == nil)
        #expect(InstallCountRule.normalizedHost("canvas.upenn.edu/login") == nil)
        #expect(InstallCountRule.normalizedHost("canvas.upenn.edu:443") == nil)
        #expect(InstallCountRule.normalizedHost("localhost") == nil)
        #expect(InstallCountRule.normalizedHost("") == nil)
        #expect(InstallCountRule.normalizedHost(nil) == nil)
        let long = String(repeating: "a", count: 97) + ".edu"
        #expect(long.count == 101)
        #expect(InstallCountRule.normalizedHost(long) == nil)
    }

    @Test("the body is byte for byte the contract")
    func body() {
        let data = InstallCountRule.body(host: "canvas.upenn.edu", kind: "new")
        #expect(String(decoding: data, as: UTF8.self) == #"{"host":"canvas.upenn.edu","kind":"new"}"#)
    }

    @Test("200, 204 and 400 are done; 404, 500 and no status try again")
    func outcomes() {
        #expect(InstallCountRule.outcome(forStatus: 200) == .done)
        #expect(InstallCountRule.outcome(forStatus: 204) == .done)
        #expect(InstallCountRule.outcome(forStatus: 400) == .done)
        #expect(InstallCountRule.outcome(forStatus: 404) == .retryLater)
        #expect(InstallCountRule.outcome(forStatus: 500) == .retryLater)
        #expect(InstallCountRule.outcome(forStatus: nil) == .retryLater)
    }
}

/// Answers every request with a canned status and counts them. Process-wide
/// state, so the suite using it is `.serialized`.
final class InstallStubProtocol: URLProtocol, @unchecked Sendable {
    nonisolated(unsafe) static var status = 200
    nonisolated(unsafe) static var requests: [URLRequest] = []
    nonisolated(unsafe) static var lastBody: Data?

    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        Self.requests.append(request)
        if let body = request.httpBody {
            Self.lastBody = body
        } else if let stream = request.httpBodyStream {
            stream.open()
            var data = Data()
            var buffer = [UInt8](repeating: 0, count: 1024)
            while stream.hasBytesAvailable {
                let n = stream.read(&buffer, maxLength: buffer.count)
                if n <= 0 { break }
                data.append(buffer, count: n)
            }
            stream.close()
            Self.lastBody = data
        }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data())
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

@Suite("Install count reporter", .serialized)
@MainActor
struct InstallCountReporterTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func make() -> (InstallCountReporter, UserDefaults, String) {
        let name = "lhf.installcount.test.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defaults.removePersistentDomain(forName: name)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [InstallStubProtocol.self]
        InstallStubProtocol.requests = []
        InstallStubProtocol.lastBody = nil
        let reporter = InstallCountReporter(
            baseURL: URL(string: "https://example.test")!,
            session: URLSession(configuration: config),
            defaults: defaults)
        return (reporter, defaults, name)
    }

    private func report(_ reporter: InstallCountReporter, at date: Date? = nil,
                        feature: Bool = true, fixture: Bool = false) async {
        await reporter.reportIfDue(
            featureEnabled: feature, onboardingComplete: true, canvasConnected: true,
            usingFixtureData: fixture, isTestRunner: false,
            host: "canvas.upenn.edu", now: date ?? now)
    }

    @Test("a 200 marks it reported and a second call sends nothing")
    func counted() async throws {
        let (reporter, defaults, name) = make()
        defer { defaults.removePersistentDomain(forName: name) }
        InstallStubProtocol.status = 200
        reporter.recordFirstLaunch(onboardingComplete: false)
        await report(reporter)
        #expect(InstallStubProtocol.requests.count == 1)
        #expect(defaults.bool(forKey: InstallCountReporter.reportedKey))
        await report(reporter, at: now.addingTimeInterval(7 * 3600))
        #expect(InstallStubProtocol.requests.count == 1)

        let request = try #require(InstallStubProtocol.requests.first)
        #expect(request.httpMethod == "POST")
        #expect(request.url?.path.hasSuffix("/api/install") == true)
        let body = try #require(InstallStubProtocol.lastBody)
        #expect(String(decoding: body, as: UTF8.self) == #"{"host":"canvas.upenn.edu","kind":"new"}"#)
        let names = (request.allHTTPHeaderFields ?? [:]).keys.map { $0.lowercased() }
        #expect(names.contains("content-type"))
        #expect(!names.contains("authorization"))
        #expect(!names.contains { $0.hasPrefix("x-") })
    }

    @Test("an install that was onboarded before this build says existing")
    func existing() async throws {
        let (reporter, defaults, name) = make()
        defer { defaults.removePersistentDomain(forName: name) }
        InstallStubProtocol.status = 200
        reporter.recordFirstLaunch(onboardingComplete: true)
        // Set once: a later launch with onboarding complete cannot change it.
        reporter.recordFirstLaunch(onboardingComplete: false)
        await report(reporter)
        let body = try #require(InstallStubProtocol.lastBody)
        #expect(String(decoding: body, as: UTF8.self) == #"{"host":"canvas.upenn.edu","kind":"existing"}"#)
    }

    @Test("a 404 leaves it unset, records the attempt, and waits six hours")
    func retry() async {
        let (reporter, defaults, name) = make()
        defer { defaults.removePersistentDomain(forName: name) }
        InstallStubProtocol.status = 404
        await report(reporter)
        #expect(InstallStubProtocol.requests.count == 1)
        #expect(!defaults.bool(forKey: InstallCountReporter.reportedKey))
        #expect(defaults.object(forKey: InstallCountReporter.lastAttemptKey) as? Date == now)
        await report(reporter, at: now.addingTimeInterval(5 * 3600))
        #expect(InstallStubProtocol.requests.count == 1)
        await report(reporter, at: now.addingTimeInterval(6 * 3600))
        #expect(InstallStubProtocol.requests.count == 2)
    }

    @Test("a 400 is final")
    func refused() async {
        let (reporter, defaults, name) = make()
        defer { defaults.removePersistentDomain(forName: name) }
        InstallStubProtocol.status = 400
        await report(reporter)
        #expect(defaults.bool(forKey: InstallCountReporter.reportedKey))
    }

    @Test("fixture data or the flag off sends nothing")
    func blocked() async {
        let (reporter, defaults, name) = make()
        defer { defaults.removePersistentDomain(forName: name) }
        InstallStubProtocol.status = 200
        await report(reporter, fixture: true)
        await report(reporter, feature: false)
        #expect(InstallStubProtocol.requests.isEmpty)
        #expect(defaults.object(forKey: InstallCountReporter.lastAttemptKey) == nil)
    }
}

@Suite("Install count wiring")
struct InstallCountWiringTests {
    private func source(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/LowHangingFruitUI/\(path)")
        try #require(FileManager.default.fileExists(atPath: url.path), "\(url.path) is not there")
        return try String(contentsOf: url, encoding: .utf8)
    }

    @Test("the background refresh never mentions the reporter; the root view does")
    func foregroundOnly() throws {
        #expect(!(try source("BackgroundRefresh.swift").contains("InstallCountReporter")))
        let root = try source("RootView.swift")
        #expect(root.contains("InstallCountReporter.shared"))
        #expect(root.contains("guard !isWalled else { return }"))
    }
}
