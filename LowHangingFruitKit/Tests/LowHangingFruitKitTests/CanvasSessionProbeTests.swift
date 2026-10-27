import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// `CanvasSessionProbe` replaced Grade Watcher's "a course said 401, so
/// delete the saved Canvas cookies". The rule that reads the answer is pure
/// and tested as a table; the request is tested against a local
/// `URLProtocol` stub (nothing here touches Canvas), including the two
/// properties that make it safe to run on a live session: it carries the
/// cookies and no bearer token, and it never follows a redirect.
@Suite("Canvas session probe", .serialized)
struct CanvasSessionProbeTests {

    private let aliveBody = Data(#"{"id":1234,"name":"Sample Student"}"#.utf8)
    private let loginURL = URL(string: "https://canvas.upenn.edu/login/saml")!
    private let apiURL = URL(string: "https://canvas.upenn.edu/api/v1/users/self")!

    // MARK: Pure rule

    @Test("200 with a JSON object is alive, with or without Canvas's while(1); prefix")
    func aliveOnJSONObject() {
        #expect(CanvasSessionProbe.verdict(statusCode: 200, finalURL: apiURL, body: aliveBody) == .alive)
        let prefixed = Data("while(1);".utf8) + aliveBody
        #expect(CanvasSessionProbe.verdict(statusCode: 200, finalURL: apiURL, body: prefixed) == .alive)
    }

    @Test("401 is dead whatever the body says, because users/self cannot mean \"not allowed\"")
    func deadOn401() {
        let notAllowed = Data(#"{"status":"unauthorized","errors":[{"message":"user not authorized to perform that action"}]}"#.utf8)
        #expect(CanvasSessionProbe.verdict(statusCode: 401, finalURL: apiURL, body: notAllowed) == .dead)
        #expect(CanvasSessionProbe.verdict(statusCode: 401, finalURL: apiURL, body: Data()) == .dead)
    }

    @Test("a redirect to, or a page at, a login URL is dead")
    func deadOnLoginPage() {
        #expect(CanvasSessionProbe.verdict(statusCode: 302, finalURL: loginURL, body: Data()) == .dead)
        #expect(CanvasSessionProbe.verdict(statusCode: 200, finalURL: loginURL, body: Data("<html>sign in</html>".utf8)) == .dead)
        let idp = URL(string: "https://idp.pennkey.upenn.edu/idp/profile/SAML2/Redirect/SSO")!
        #expect(CanvasSessionProbe.verdict(statusCode: 302, finalURL: idp, body: Data()) == .dead)
        let cas = URL(string: "https://secure.its.example.edu/cas/login?service=x")!
        #expect(CanvasSessionProbe.verdict(statusCode: 303, finalURL: cas, body: Data()) == .dead)
    }

    @Test("anything else is unknown: error statuses, HTML on a non-login page, a non-object body, a redirect elsewhere")
    func unknownOtherwise() {
        for status in [403, 404, 429, 500, 502, 503] {
            #expect(CanvasSessionProbe.verdict(statusCode: status, finalURL: apiURL, body: aliveBody) == .unknown, "status \(status)")
        }
        let html = Data("<html><body>Canvas is down for maintenance</body></html>".utf8)
        #expect(CanvasSessionProbe.verdict(statusCode: 200, finalURL: apiURL, body: html) == .unknown)
        #expect(CanvasSessionProbe.verdict(statusCode: 200, finalURL: apiURL, body: Data("[1,2]".utf8)) == .unknown)
        #expect(CanvasSessionProbe.verdict(statusCode: 200, finalURL: apiURL, body: Data()) == .unknown)
        // A vanity-domain hop is a redirect, but not a login: it must not read as a dead session.
        let vanity = URL(string: "https://upenn.instructure.com/api/v1/users/self")!
        #expect(CanvasSessionProbe.verdict(statusCode: 301, finalURL: vanity, body: Data()) == .unknown)
        #expect(CanvasSessionProbe.verdict(statusCode: 200, finalURL: nil, body: html) == .unknown)
    }

    // MARK: The request

    private struct Reply {
        var status: Int
        var headers: [String: String] = [:]
        var body: Data = Data()
        var error: URLError?
    }

    private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var handler: ((URLRequest) -> Reply)?
        nonisolated(unsafe) static var requests: [URLRequest] = []

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            Self.requests.append(request)
            guard let reply = Self.handler?(request) else {
                client?.urlProtocol(self, didFailWithError: URLError(.badServerResponse))
                return
            }
            if let error = reply.error {
                client?.urlProtocol(self, didFailWithError: error)
                return
            }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: reply.status,
                httpVersion: "HTTP/1.1", headerFields: reply.headers
            )!
            if (300..<400).contains(reply.status), let location = reply.headers["Location"],
               let target = URL(string: location, relativeTo: request.url) {
                var next = URLRequest(url: target.absoluteURL)
                next.httpMethod = "GET"
                // Announce the redirect, then deliver the 3xx itself as well, as a
                // real server's reply would arrive: a client that declines to follow
                // (the probe's delegate) keeps this response, and one that follows
                // simply stops this load. Returning here instead hangs the decline.
                client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: response)
            }
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: reply.body)
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func probe(
        cookies: [HTTPCookie] = [sessionCookie],
        _ handler: @escaping (URLRequest) -> Reply
    ) async -> CanvasSessionProbe.Verdict {
        StubURLProtocol.handler = handler
        StubURLProtocol.requests = []
        defer { StubURLProtocol.handler = nil }
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return await CanvasSessionProbe.probe(
            baseURL: URL(string: "https://canvas.upenn.edu")!,
            cookies: cookies,
            session: URLSession(configuration: configuration)
        )
    }

    private static let sessionCookie = HTTPCookie(properties: [
        .name: "canvas_session", .value: "sample-session-value",
        .domain: "canvas.upenn.edu", .path: "/", .secure: "TRUE",
    ])!

    @Test("a live session answers 200 JSON: alive, and the request carried the cookies and no bearer token")
    func aliveRequestShape() async {
        let verdict = await probe { _ in Reply(status: 200, body: aliveBody) }
        #expect(verdict == .alive)
        let sent = StubURLProtocol.requests.first
        #expect(sent?.url?.path == "/api/v1/users/self")
        #expect(sent?.httpMethod == "GET")
        #expect(sent?.value(forHTTPHeaderField: "Cookie")?.contains("canvas_session=sample-session-value") == true)
        #expect(sent?.value(forHTTPHeaderField: "Authorization") == nil)
        #expect(sent?.httpShouldHandleCookies == false)
    }

    @Test("a 401 is dead")
    func dead401() async {
        let verdict = await probe { _ in Reply(status: 401, body: Data(#"{"status":"unauthorized"}"#.utf8)) }
        #expect(verdict == .dead)
    }

    @Test("a redirect to the login page is dead, and the redirect is never followed")
    func redirectNotFollowed() async {
        let verdict = await probe { _ in
            Reply(status: 302, headers: ["Location": "https://canvas.upenn.edu/login/saml"])
        }
        #expect(verdict == .dead)
        // One request only: the cookies went to canvas.upenn.edu and nowhere else.
        #expect(StubURLProtocol.requests.count == 1)
    }

    @Test("a relative Location is resolved against the probe URL before it is judged")
    func relativeLocation() async {
        let verdict = await probe { _ in Reply(status: 302, headers: ["Location": "/login"]) }
        #expect(verdict == .dead)
    }

    @Test("a server error, an unrelated redirect and a dropped connection are all unknown")
    func unknownRequests() async {
        #expect(await probe { _ in Reply(status: 503) } == .unknown)
        #expect(await probe { _ in Reply(status: 302, headers: ["Location": "https://elsewhere.example.com/maintenance"]) } == .unknown)
        #expect(await probe { _ in Reply(status: 0, error: URLError(.notConnectedToInternet)) } == .unknown)
    }

    // MARK: The view no longer deletes

    @Test("Grade Watcher's refresh never removes the saved Canvas cookies, and asks the probe instead")
    func viewDoesNotDeleteCookies() throws {
        let file = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/LowHangingFruitUI/GradeWatcherView.swift")
        guard FileManager.default.fileExists(atPath: file.path) else { return }
        let source = try String(contentsOf: file, encoding: .utf8)
        // Strip comments so the explanation of what used to be here can say its name.
        let code = source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        #expect(!code.contains("SessionCookieStore.remove"))
        #expect(code.contains("CanvasSessionProbe.probe"))
    }
}
