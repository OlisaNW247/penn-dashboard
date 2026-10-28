import Foundation
import Testing
@testable import LowHangingFruitKit

/// P5 of `docs/HARDENING_PLAN_2026-10-25.md`, the Kit half: credentials only
/// ever go to the right host. The clients attach the session cookie (or a
/// bearer token) by hand, so nothing scopes it to a domain for them; these
/// tests watch what actually reaches each host.
///
/// The stub records every request it is asked to load, answers the first with
/// a 302 to another host (building the redirect the way `URLSession` does,
/// with the headers carried over), and answers everything else 200. Its state
/// is static because the system makes the `URLProtocol` instance, so the
/// suite is serialized.
@Suite("Credentials only go to the right host", .serialized)
struct CredentialGuardTests {

    private struct Seen: Sendable {
        let url: URL
        let cookie: String?
        let authorization: String?
        let handlesCookies: Bool
    }

    private final class RecordingStub: URLProtocol, @unchecked Sendable {
        private static let lock = NSLock()
        nonisolated(unsafe) private static var log: [Seen] = []
        nonisolated(unsafe) private static var redirectTarget: URL?
        nonisolated(unsafe) private static var pageBody = "[]"

        static func reset(redirectTo target: URL? = nil, pageBody: String = "[]") {
            lock.lock(); defer { lock.unlock() }
            log = []
            redirectTarget = target
            self.pageBody = pageBody
        }

        static var seen: [Seen] {
            lock.lock(); defer { lock.unlock() }
            return log
        }

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let url = request.url else { return }
            let (target, body, isFirst): (URL?, String, Bool) = {
                Self.lock.lock(); defer { Self.lock.unlock() }
                let first = Self.log.isEmpty
                Self.log.append(Seen(
                    url: url,
                    cookie: request.value(forHTTPHeaderField: "Cookie"),
                    authorization: request.value(forHTTPHeaderField: "Authorization"),
                    handlesCookies: request.httpShouldHandleCookies
                ))
                return (Self.redirectTarget, Self.pageBody, first)
            }()

            if isFirst, let target {
                let redirect = HTTPURLResponse(
                    url: url, statusCode: 302, httpVersion: "HTTP/1.1", headerFields: ["Location": target.absoluteString]
                )!
                // What URLSession's HTTP stack does: the same request, aimed
                // at the new URL, headers and all.
                var next = request
                next.url = target
                client?.urlProtocol(self, wasRedirectedTo: next, redirectResponse: redirect)
                return
            }
            let response = HTTPURLResponse(
                url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"]
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            client?.urlProtocol(self, didLoad: Data(body.utf8))
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private static func session() -> URLSession {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RecordingStub.self]
        return URLSession(configuration: configuration)
    }

    private static func cookie(domain: String) -> HTTPCookie {
        HTTPCookie(properties: [
            .domain: domain, .path: "/", .name: "session", .value: "super-secret", .secure: "TRUE",
        ])!
    }

    private static let canvasCookie = cookie(domain: "canvas.upenn.edu")
    private static let gradescopeCookie = cookie(domain: "www.gradescope.com")
    private static let cdn = URL(string: "https://files.cdn.example.net/blob")!

    // MARK: Redirects

    /// One call per credentialed client, each driven through its own public
    /// entry point. The result is irrelevant (the stub answers `[]`/redirects),
    /// only what reached the wire is.
    enum Client: String, CaseIterable, CustomStringConvertible {
        case modules, grades, announcements, courseContent, syllabus, discovery, gradescope
        var description: String { rawValue }

        var host: String { self == .gradescope ? "www.gradescope.com" : "canvas.upenn.edu" }

        func run(session: URLSession, accessToken: String?) async {
            let cookies = [self == .gradescope ? CredentialGuardTests.gradescopeCookie : CredentialGuardTests.canvasCookie]
            switch self {
            case .modules:
                _ = try? await CanvasModulesClient(cookies: cookies, session: session, accessToken: accessToken)
                    .fetchModuleItems(courseID: "1")
            case .grades:
                _ = try? await CanvasGradesClient(cookies: cookies, session: session, accessToken: accessToken)
                    .fetchSnapshot(courseID: "1")
            case .announcements:
                _ = try? await CanvasAnnouncementsClient(cookies: cookies, session: session, accessToken: accessToken)
                    .fetchAnnouncements(courseIDs: ["1"], since: Date(timeIntervalSince1970: 1_700_000_000))
            case .courseContent:
                _ = try? await CanvasCourseContentClient(cookies: cookies, session: session, accessToken: accessToken)
                    .assignments(courseID: "1")
            case .syllabus:
                _ = try? await CanvasSyllabusClient(cookies: cookies, session: session, accessToken: accessToken)
                    .findCandidates(courseID: "1")
            case .discovery:
                _ = try? await CanvasDiscoveryClient(cookies: cookies, session: session)
                    .discoverCalendarFeedURL()
            case .gradescope:
                _ = try? await GradescopeClient(cookies: cookies, session: session).fetchAssignments()
            }
        }

        var supportsBearer: Bool { self != .discovery && self != .gradescope }
    }

    @Test("without the guard, a redirect would carry the cookie to another host (the harness is not vacuous)")
    func harnessReproducesTheLeak() async throws {
        RecordingStub.reset(redirectTo: Self.cdn)
        defer { RecordingStub.reset() }
        var request = URLRequest(url: URL(string: "https://canvas.upenn.edu/files/1/download")!)
        request.httpShouldHandleCookies = false
        request.setValue("session=super-secret", forHTTPHeaderField: "Cookie")
        _ = try await Self.session().data(for: request)   // the plain call, no delegate

        let seen = RecordingStub.seen
        #expect(seen.count == 2)
        #expect(seen.last?.url.host == "files.cdn.example.net")
        #expect(seen.last?.cookie == "session=super-secret")
    }

    @Test("a redirect to another host goes out without the session cookie, for every client", arguments: Client.allCases)
    func redirectDropsTheCookie(client: Client) async {
        RecordingStub.reset(redirectTo: Self.cdn)
        defer { RecordingStub.reset() }
        await client.run(session: Self.session(), accessToken: nil)

        let seen = RecordingStub.seen
        #expect(seen.count >= 2, "\(client): the stub never redirected")
        #expect(seen.first?.url.host == client.host)
        #expect(seen.first?.cookie?.contains("super-secret") == true, "\(client): the first request must carry the cookie")
        for hop in seen where hop.url.host == "files.cdn.example.net" {
            #expect(hop.cookie == nil, "\(client): the cookie reached \(hop.url)")
            #expect(hop.authorization == nil, "\(client): a credential reached \(hop.url)")
        }
    }

    @Test("a redirect to another host goes out without the bearer token, for every client that uses one",
          arguments: Client.allCases.filter(\.supportsBearer))
    func redirectDropsTheBearerToken(client: Client) async {
        RecordingStub.reset(redirectTo: Self.cdn)
        defer { RecordingStub.reset() }
        await client.run(session: Self.session(), accessToken: "tok-secret")

        let seen = RecordingStub.seen
        #expect(seen.count >= 2, "\(client): the stub never redirected")
        #expect(seen.first?.authorization == "Bearer tok-secret", "\(client): the first request must carry the token")
        for hop in seen where hop.url.host == "files.cdn.example.net" {
            #expect(hop.authorization == nil, "\(client): the token reached \(hop.url)")
            #expect(hop.cookie == nil)
        }
    }

    @Test("a redirect that stays on the same HTTPS origin keeps its credentials")
    func sameOriginRedirectKeepsCredentials() async throws {
        RecordingStub.reset(redirectTo: URL(string: "https://canvas.upenn.edu/api/v1/courses/1/modules?page=2")!)
        defer { RecordingStub.reset() }
        await Client.modules.run(session: Self.session(), accessToken: nil)

        let seen = RecordingStub.seen
        #expect(seen.count >= 2)
        #expect(seen.allSatisfy { $0.url.host == "canvas.upenn.edu" })
        #expect(seen.allSatisfy { $0.cookie?.contains("super-secret") == true })
    }

    @Test("sanitizing: other host, other port and a downgrade to http lose credentials; the same origin does not")
    func sanitizedRule() {
        func request(_ url: String) -> URLRequest {
            var request = URLRequest(url: URL(string: url)!)
            request.setValue("session=x", forHTTPHeaderField: "Cookie")
            request.setValue("Bearer y", forHTTPHeaderField: "authorization")   // header names are case-insensitive
            request.setValue("Basic z", forHTTPHeaderField: "Proxy-Authorization")
            request.setValue("keep", forHTTPHeaderField: "X-Other")
            request.httpShouldHandleCookies = true
            return request
        }
        let origin = URL(string: "https://canvas.upenn.edu/files/1")!

        let same = CredentialRedirectGuard.sanitized(request("https://CANVAS.upenn.edu/files/2"), redirectedFrom: origin)
        #expect(same.value(forHTTPHeaderField: "Cookie") == "session=x")
        #expect(same.value(forHTTPHeaderField: "Authorization") == "Bearer y")

        for target in ["https://files.cdn.example.net/x", "https://canvas.upenn.edu:8443/x", "http://canvas.upenn.edu/x",
                       "https://canvas.upenn.edu.evil.example/x"] {
            let stripped = CredentialRedirectGuard.sanitized(request(target), redirectedFrom: origin)
            #expect(stripped.value(forHTTPHeaderField: "Cookie") == nil, "\(target)")
            #expect(stripped.value(forHTTPHeaderField: "Authorization") == nil, "\(target)")
            #expect(stripped.value(forHTTPHeaderField: "Proxy-Authorization") == nil, "\(target)")
            #expect(stripped.value(forHTTPHeaderField: "X-Other") == "keep", "\(target)")
            #expect(!stripped.httpShouldHandleCookies, "\(target)")
        }
        // No known origin to compare with: nothing to prove it is safe.
        #expect(CredentialRedirectGuard.sanitized(request("https://canvas.upenn.edu/x"), redirectedFrom: nil)
            .value(forHTTPHeaderField: "Cookie") == nil)
    }

    // MARK: Syllabus cookie handling

    @Test("the syllabus client no longer lets URLSession add cookies of its own")
    func syllabusClientDoesNotHandleCookies() async {
        RecordingStub.reset()
        defer { RecordingStub.reset() }
        await Client.syllabus.run(session: Self.session(), accessToken: nil)
        let seen = RecordingStub.seen
        #expect(!seen.isEmpty)
        #expect(seen.allSatisfy { !$0.handlesCookies })
    }

    // MARK: Host pins

    @Test("Gradescope never requests a page that is not on Gradescope, and the scrape still finishes")
    func gradescopeSkipsOffHostLinks() async throws {
        let account = """
        <div class="courseList">
          <div class="courseList--term">Fall 2026</div>
          <div class="courseList--coursesForTerm">
            <a class="courseBox" href="https://evil.example.com/courses/9">Evil 101</a>
            <a class="courseBox" href="/courses/123">CIS 5050</a>
          </div>
        </div>
        """
        // Both assignment rows are for the good course; the second one's link
        // is absolute and names another host.
        let course = """
        <table>
          <tr><td><a href="/courses/123/assignments/456">Homework 1</a></td><td>Sep 30, 2026 11:59 PM</td><td>Not Submitted</td></tr>
          <tr><td><a href="https://evil.example.com/courses/123/assignments/789">Homework 2</a></td><td>Oct 7, 2026 11:59 PM</td><td>Not Submitted</td></tr>
        </table>
        """
        RecordingStub.reset(pageBody: "")
        defer { RecordingStub.reset() }
        // Page bodies by path: a stub that answers the same body everywhere
        // cannot serve three different pages, so route through a second stub.
        final class RoutedStub: URLProtocol, @unchecked Sendable {
            nonisolated(unsafe) static var bodies: [String: String] = [:]
            nonisolated(unsafe) static var requested: [URL] = []
            override class func canInit(with request: URLRequest) -> Bool { true }
            override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
            override func startLoading() {
                let url = request.url!
                Self.requested.append(url)
                let body = Self.bodies[url.path] ?? "<html></html>"
                let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: "HTTP/1.1", headerFields: nil)!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(body.utf8))
                client?.urlProtocolDidFinishLoading(self)
            }
            override func stopLoading() {}
        }
        RoutedStub.bodies = ["/account": account, "/courses/123": course]
        RoutedStub.requested = []
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [RoutedStub.self]

        let found = try await GradescopeClient(cookies: [Self.gradescopeCookie], session: URLSession(configuration: configuration))
            .fetchAssignmentsReport()

        #expect(RoutedStub.requested.allSatisfy { $0.host == "www.gradescope.com" }, "requested \(RoutedStub.requested)")
        #expect(RoutedStub.requested.contains { $0.path == "/courses/123" })
        // The good row survives; the off-host one is read as unverified, not
        // as a reason to fail the scrape or to sign the student out.
        #expect(found.assignments.contains { $0.title == "Homework 1" })
    }

    @Test("an off-host Gradescope URL is refused without being a reconnect prompt")
    func untrustedURLIsNotAReauthentication() {
        let error = GradescopeClient.Error.untrustedURL(URL(string: "https://evil.example.com/")!)
        #expect(!error.requiresReauthentication)
        #expect(error.errorDescription?.isEmpty == false)
    }

    @Test("Gradescope and discovery send no request at all when their base URL is not HTTPS")
    func plainHTTPBaseSendsNothing() async {
        RecordingStub.reset()
        defer { RecordingStub.reset() }
        let session = Self.session()
        do {
            _ = try await GradescopeClient(
                baseURL: URL(string: "http://www.gradescope.com")!, cookies: [Self.gradescopeCookie], session: session
            ).fetchAssignments()
            Issue.record("expected the plain-http base to be refused")
        } catch {
            #expect(!((error as? GradescopeClient.Error)?.requiresReauthentication ?? false))
        }
        _ = try? await CanvasDiscoveryClient(
            baseURL: URL(string: "http://canvas.upenn.edu")!, cookies: [Self.canvasCookie], session: session
        ).discoverCalendarFeedURL()
        #expect(RecordingStub.seen.isEmpty, "requests went out: \(RecordingStub.seen.map(\.url))")
    }

    @Test("origin comparison: same host and port over HTTPS only, case-insensitively")
    func originRule() {
        let base = URL(string: "https://canvas.upenn.edu")!
        #expect(CredentialOrigin.isSameOrigin(URL(string: "https://canvas.upenn.edu/a/b?c=d")!, as: base))
        #expect(CredentialOrigin.isSameOrigin(URL(string: "HTTPS://Canvas.UPenn.edu:443/x")!, as: base))
        #expect(!CredentialOrigin.isSameOrigin(URL(string: "http://canvas.upenn.edu/x")!, as: base))
        #expect(!CredentialOrigin.isSameOrigin(URL(string: "https://canvas.upenn.edu:8443/x")!, as: base))
        #expect(!CredentialOrigin.isSameOrigin(URL(string: "https://evil.canvas.upenn.edu/x")!, as: base))
        #expect(!CredentialOrigin.isSameOrigin(URL(string: "https://canvas.upenn.edu.evil.example/x")!, as: base))
        #expect(!CredentialOrigin.isSameOrigin(URL(string: "file:///etc/passwd")!, as: base))
        // Only the candidate's scheme has to be HTTPS; the base is the host it is compared to.
        #expect(CredentialOrigin.isSameOrigin(URL(string: "https://canvas.upenn.edu/x")!, as: URL(string: "http://canvas.upenn.edu")!))
    }
}
