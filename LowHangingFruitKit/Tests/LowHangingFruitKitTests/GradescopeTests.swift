import Foundation
import Testing
@testable import LowHangingFruitKit

@Suite("Gradescope scraping", .serialized)
struct GradescopeTests {

    private final class StubURLProtocol: URLProtocol, @unchecked Sendable {
        nonisolated(unsafe) static var handler: ((URLRequest) throws -> (Int, String))?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            do {
                guard let handler = Self.handler else {
                    throw URLError(.badServerResponse)
                }
                let (status, body) = try handler(request)
                let response = HTTPURLResponse(
                    url: request.url!,
                    statusCode: status,
                    httpVersion: "HTTP/1.1",
                    headerFields: ["Content-Type": "text/html; charset=utf-8"]
                )!
                client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
                client?.urlProtocol(self, didLoad: Data(body.utf8))
                client?.urlProtocolDidFinishLoading(self)
            } catch {
                client?.urlProtocol(self, didFailWithError: error)
            }
        }

        override func stopLoading() {}
    }

    private func stubSession(
        _ handler: @escaping (URLRequest) throws -> (Int, String)
    ) -> URLSession {
        StubURLProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [StubURLProtocol.self]
        return URLSession(configuration: configuration)
    }

    @Test("a 403 is never login-form evidence, and a login form is")
    func onlyALoginFormIsEvidence() {
        let url = URL(string: "https://www.gradescope.com/account")!
        #expect(GradescopeClient.Error.notLoggedIn.sawLoginForm)
        #expect(!GradescopeClient.Error.http(status: 401, url: url).sawLoginForm)
        #expect(!GradescopeClient.Error.http(status: 403, url: url).sawLoginForm)
        #expect(!GradescopeClient.Error.http(status: 500, url: url).sawLoginForm)
        #expect(!GradescopeClient.Error.notHTTP.sawLoginForm)
        #expect(!GradescopeClient.Error.invalidResponseEncoding.sawLoginForm)
    }

    @Test("a rate-limited 403 on the account page throws without being login-form evidence")
    func bare403IsNotEvidence() async throws {
        let session = stubSession { _ in (403, "Forbidden") }
        defer { StubURLProtocol.handler = nil }
        let client = GradescopeClient(cookies: [], session: session)

        do {
            _ = try await client.fetchAssignments()
            Issue.record("expected the 403 to throw")
        } catch let error as GradescopeClient.Error {
            #expect(!error.sawLoginForm)
        }
    }

    @Test("a page that merely talks about logging in is not mistaken for the login form")
    func keywordPageIsNotALoginForm() async throws {
        // Every word the old keyword match looked for, and no password field.
        let account = """
        <html><body>
          <p>Log in to Gradescope with your school credentials, email, or password.</p>
          <div class="courseList">
            <div class="courseList--term">Fall 2026</div>
            <div class="courseList--coursesForTerm">
              <a class="courseBox" href="/courses/123">CIS 5050</a>
            </div>
          </div>
        </body></html>
        """
        let course = """
        <table><tr>
          <td><a href="/courses/123/assignments/456">Log in to Gradescope: email setup</a></td>
          <td>Sep 30, 2026 11:59 PM</td>
          <td>Submitted</td>
        </tr></table>
        """
        let session = stubSession { request in
            switch request.url?.path {
            case "/account": (200, account)
            case "/courses/123": (200, course)
            default: (404, "missing")
            }
        }
        defer { StubURLProtocol.handler = nil }
        let client = GradescopeClient(cookies: [], session: session)

        let assignments = try await client.fetchAssignments()
        #expect(assignments.count == 1)
    }

    @Test("only authentication responses require a Gradescope reconnect")
    func reconnectClassification() {
        let url = URL(string: "https://www.gradescope.com/account")!
        #expect(GradescopeClient.Error.notLoggedIn.requiresReauthentication)
        #expect(GradescopeClient.Error.http(status: 401, url: url).requiresReauthentication)
        #expect(GradescopeClient.Error.http(status: 403, url: url).requiresReauthentication)
        #expect(!GradescopeClient.Error.http(status: 500, url: url).requiresReauthentication)
        #expect(!GradescopeClient.Error.notHTTP.requiresReauthentication)
        #expect(!GradescopeClient.Error.invalidResponseEncoding.requiresReauthentication)
    }

    @Test("a login page reached after the account request still expires the session")
    func courseLoginPageRequiresReconnect() async throws {
        let account = """
        <div class="courseList">
          <div class="courseList--term">Fall 2026</div>
          <div class="courseList--coursesForTerm">
            <a class="courseBox" href="/courses/123">CIS 5050</a>
          </div>
        </div>
        """
        let login = "<html><h1>Log in to Gradescope</h1><label>Password</label><input type='password'></html>"
        let session = stubSession { request in
            request.url?.path == "/account" ? (200, account) : (200, login)
        }
        defer { StubURLProtocol.handler = nil }
        let client = GradescopeClient(cookies: [], session: session)

        do {
            _ = try await client.fetchAssignments()
            Issue.record("expected the course-page login redirect to require reauthentication")
        } catch let error as GradescopeClient.Error {
            #expect(error.requiresReauthentication)
            if case .notLoggedIn = error {} else {
                Issue.record("expected notLoggedIn, got \(error)")
            }
        }
    }

    @Test(
        "assignment-detail authentication failures propagate instead of being swallowed",
        arguments: [401, 403]
    )
    func detailAuthenticationFailurePropagates(status: Int) async throws {
        let account = """
        <div class="courseList">
          <div class="courseList--term">Fall 2026</div>
          <div class="courseList--coursesForTerm">
            <a class="courseBox" href="/courses/123">CIS 5050</a>
          </div>
        </div>
        """
        let course = """
        <table><tr>
          <td><a href="/courses/123/assignments/456">Homework 1</a></td>
          <td>Sep 30, 2026 11:59 PM</td>
          <td>Not Submitted</td>
        </tr></table>
        """
        let session = stubSession { request in
            switch request.url?.path {
            case "/account": (200, account)
            case "/courses/123": (200, course)
            case "/courses/123/assignments/456": (status, "unauthorized")
            default: (404, "missing")
            }
        }
        defer { StubURLProtocol.handler = nil }
        let client = GradescopeClient(cookies: [], session: session)

        do {
            _ = try await client.fetchAssignments()
            Issue.record("expected the detail-page \(status) to require reauthentication")
        } catch let error as GradescopeClient.Error {
            #expect(error.requiresReauthentication)
            if case let .http(actualStatus, url) = error {
                #expect(actualStatus == status)
                #expect(url.path == "/courses/123/assignments/456")
            } else {
                Issue.record("expected HTTP 401, got \(error)")
            }
        }
    }
    // MARK: - An unreadable detail page is not a "not submitted"

    private static let fallAccount = """
    <div class="courseList">
      <div class="courseList--term">Fall 2026</div>
      <div class="courseList--coursesForTerm">
        <a class="courseBox" href="/courses/123">CIS 5050</a>
      </div>
    </div>
    """

    /// Two rows the list does not mark submitted, plus one it does.
    private static let fallCourse = """
    <table>
      <tr>
        <td><a href="/courses/123/assignments/456">Homework 1</a></td>
        <td>Sep 30, 2026 11:59 PM</td>
        <td>Not Submitted</td>
      </tr>
      <tr>
        <td><a href="/courses/123/assignments/457">Homework 2</a></td>
        <td>Oct 7, 2026 11:59 PM</td>
        <td>Not Submitted</td>
      </tr>
      <tr>
        <td><a href="/courses/123/assignments/458">Homework 3</a></td>
        <td>Oct 14, 2026 11:59 PM</td>
        <td>Submitted</td>
      </tr>
    </table>
    """

    private static let hw1ID = "gradescope:course-123-assignment-456"
    private static let hw2ID = "gradescope:course-123-assignment-457"

    @Test("a detail page that cannot be read leaves the row not-submitted but marks it unverified")
    func unreadableDetailPageIsReportedUnverified() async throws {
        let session = stubSession { request in
            switch request.url?.path {
            case "/account": (200, Self.fallAccount)
            case "/courses/123": (200, Self.fallCourse)
            case "/courses/123/assignments/456": (500, "boom")
            case "/courses/123/assignments/457": (200, "<main>Homework 2 Not Submitted</main>")
            default: (404, "missing")
            }
        }
        defer { StubURLProtocol.handler = nil }
        let client = GradescopeClient(cookies: [], session: session)

        let report = try await client.fetchAssignmentsReport()

        // Only the row whose own detail request failed is unverified. Homework
        // 2's page loaded and showed no completion: an explicit negative.
        // Homework 3 was read as submitted from the list and never fetched.
        #expect(report.unverifiedAssignmentIDs == [Self.hw1ID])
        let byID = Dictionary(uniqueKeysWithValues: report.assignments.map { ($0.id, $0) })
        #expect(byID[Self.hw1ID]?.submitted == false)
        #expect(byID[Self.hw2ID]?.submitted == false)
        #expect(byID["gradescope:course-123-assignment-458"]?.submitted == true)
        #expect(report.assignments.count == 3)
    }

    @Test("fetchAssignments still returns the same assignments the report carries")
    func fetchAssignmentsMatchesReport() async throws {
        let session = stubSession { request in
            switch request.url?.path {
            case "/account": (200, Self.fallAccount)
            case "/courses/123": (200, Self.fallCourse)
            case "/courses/123/assignments/456": (500, "boom")
            case "/courses/123/assignments/457": (200, "<main>Homework 2 Not Submitted</main>")
            default: (404, "missing")
            }
        }
        defer { StubURLProtocol.handler = nil }
        let client = GradescopeClient(cookies: [], session: session)

        let plain = try await client.fetchAssignments()
        let report = try await client.fetchAssignmentsReport()
        #expect(plain == report.assignments)
    }

    @Test("a detail page that loads and shows completion is submitted and verified; one that loads without it stays verified-not-submitted")
    func readableDetailPagesAreVerified() async throws {
        let session = stubSession { request in
            switch request.url?.path {
            case "/account": (200, Self.fallAccount)
            case "/courses/123": (200, Self.fallCourse)
            case "/courses/123/assignments/456": (200, "<main>Submission History Submitted</main>")
            case "/courses/123/assignments/457": (200, "<main>Homework 2 No Submission</main>")
            default: (404, "missing")
            }
        }
        defer { StubURLProtocol.handler = nil }
        let client = GradescopeClient(cookies: [], session: session)

        let report = try await client.fetchAssignmentsReport()
        #expect(report.unverifiedAssignmentIDs.isEmpty)
        let byID = Dictionary(uniqueKeysWithValues: report.assignments.map { ($0.id, $0) })
        #expect(byID[Self.hw1ID]?.submitted == true)
        #expect(byID[Self.hw2ID]?.submitted == false)
    }

    @Test("a login page served for a detail request still requires reauthentication")
    func detailLoginPageStillThrows() async throws {
        let login = "<html><h1>Log in to Gradescope</h1><label>Password</label><input type='password'></html>"
        let session = stubSession { request in
            switch request.url?.path {
            case "/account": (200, Self.fallAccount)
            case "/courses/123": (200, Self.fallCourse)
            case "/courses/123/assignments/456": (200, login)
            default: (200, "<main>Not Submitted</main>")
            }
        }
        defer { StubURLProtocol.handler = nil }
        let client = GradescopeClient(cookies: [], session: session)

        do {
            _ = try await client.fetchAssignmentsReport()
            Issue.record("expected the detail-page login redirect to require reauthentication")
        } catch let error as GradescopeClient.Error {
            #expect(error.requiresReauthentication)
        }
    }

    private static func gradescopeRow(
        sourceID: String = "course-123-assignment-456",
        course: String = "CIS 5050",
        submitted: Bool
    ) -> Assignment {
        Assignment(
            source: .gradescope, sourceID: sourceID, kind: .assignment,
            course: course, title: "Homework 1", dueAt: nil, url: nil,
            submitted: submitted
        )
    }

    @Test("an unverified row that was submitted before stays submitted")
    func unverifiedKeepsPreviousSubmitted() {
        let previous = [Self.gradescopeRow(submitted: true)]
        let fetched = [Self.gradescopeRow(submitted: false)]
        let result = GradescopeClient.preservingUnverifiedSubmissions(
            fetched: fetched, unverifiedIDs: [Self.hw1ID], previous: previous
        )
        #expect(result.map(\.submitted) == [true])
        #expect(result.map(\.id) == [Self.hw1ID])
    }

    @Test("a verified-not-submitted row goes back to not submitted even if it was submitted before")
    func verifiedNegativeStillOverrides() {
        let previous = [Self.gradescopeRow(submitted: true)]
        let fetched = [Self.gradescopeRow(submitted: false)]
        let result = GradescopeClient.preservingUnverifiedSubmissions(
            fetched: fetched, unverifiedIDs: [], previous: previous
        )
        #expect(result.map(\.submitted) == [false])
        // An unverified id for some other row changes nothing for this one.
        let other = GradescopeClient.preservingUnverifiedSubmissions(
            fetched: fetched, unverifiedIDs: [Self.hw2ID], previous: previous
        )
        #expect(other.map(\.submitted) == [false])
    }

    @Test("an unverified row that was not submitted before stays not submitted")
    func unverifiedWithoutPreviousSubmissionStaysFalse() {
        let result = GradescopeClient.preservingUnverifiedSubmissions(
            fetched: [Self.gradescopeRow(submitted: false)],
            unverifiedIDs: [Self.hw1ID],
            previous: [Self.gradescopeRow(submitted: false)]
        )
        #expect(result.map(\.submitted) == [false])
    }

    @Test("a new unverified row with no previous copy is returned unchanged")
    func unverifiedNewRowUnchanged() {
        let fetched = [Self.gradescopeRow(submitted: false)]
        let result = GradescopeClient.preservingUnverifiedSubmissions(
            fetched: fetched, unverifiedIDs: [Self.hw1ID], previous: []
        )
        #expect(result == fetched)
    }

    @Test("rows match by id across the course-label normalization the app applies")
    func matchesAcrossCourseRelabel() {
        // `AppState.normalizingCourse` rewrites `course` ("CIS 5050 Software
        // Systems" -> "CIS 5050") but never `source` or `sourceID`, which are
        // all `Assignment.id` is built from.
        let previous = [Self.gradescopeRow(course: "CIS 5050", submitted: true)]
        let fetched = [Self.gradescopeRow(course: "CIS 5050 Software Systems", submitted: false)]
        let result = GradescopeClient.preservingUnverifiedSubmissions(
            fetched: fetched, unverifiedIDs: [Self.hw1ID], previous: previous
        )
        #expect(result.map(\.submitted) == [true])
        #expect(result.first?.course == "CIS 5050 Software Systems")
    }

    @Test("only the unverified, previously submitted rows change; the rest of the list is untouched and in order")
    func onlyMatchingRowsChange() {
        let a = Self.gradescopeRow(sourceID: "course-123-assignment-1", submitted: false)
        let b = Self.gradescopeRow(sourceID: "course-123-assignment-2", submitted: false)
        let c = Self.gradescopeRow(sourceID: "course-123-assignment-3", submitted: true)
        let previous = [
            Self.gradescopeRow(sourceID: "course-123-assignment-1", submitted: true),
            Self.gradescopeRow(sourceID: "course-123-assignment-2", submitted: true),
            Self.gradescopeRow(sourceID: "course-123-assignment-3", submitted: false),
        ]
        let result = GradescopeClient.preservingUnverifiedSubmissions(
            fetched: [a, b, c],
            unverifiedIDs: ["gradescope:course-123-assignment-1"],
            previous: previous
        )
        #expect(result.map(\.sourceID) == [a.sourceID, b.sourceID, c.sourceID])
        #expect(result.map(\.submitted) == [true, false, true])
    }

    @Test("discovers course links from account page")
    func discoversCourses() throws {
        let html = """
        <main>
          <a class="courseBox" href="/courses/12345">CIS 5050 Software Systems</a>
          <a class="courseBox" href="https://www.gradescope.com/courses/67890">ENM 5100</a>
          <a href="/courses/12345">CIS 5050 Software Systems</a>
        </main>
        """

        let courses = GradescopeHTMLParser.courseLinks(
            from: html,
            baseURL: URL(string: "https://www.gradescope.com")!
        )

        #expect(courses.count == 2)
        #expect(courses[0].name == "CIS 5050 Software Systems")
        #expect(courses[0].url.absoluteString == "https://www.gradescope.com/courses/12345")
        #expect(courses[1].name == "ENM 5100")
    }

    @Test("keeps only the current term's courses")
    func keepsOnlyCurrentTermCourses() throws {
        let html = """
        <div class="courseList">
          <div class="courseList--term">Spring 2026</div>
          <div class="courseList--coursesForTerm">
            <a class="courseBox" href="/courses/111">CIS 5500 Databases</a>
            <a class="courseBox" href="/courses/222">CIS 5050 Software Systems</a>
          </div>
          <div class="courseList--term">Fall 2025</div>
          <div class="courseList--coursesForTerm">
            <a class="courseBox" href="/courses/333">CIS 4000 Senior Design</a>
          </div>
          <div class="courseList--term">Spring 2025</div>
          <div class="courseList--coursesForTerm">
            <a class="courseBox" href="/courses/444">CIS 1200 Programming</a>
          </div>
        </div>
        """

        let now = try #require(Self.utcDate(year: 2026, month: 5, day: 21, hour: 12, minute: 0))
        let result = GradescopeHTMLParser.currentTermCourses(
            from: html,
            baseURL: URL(string: "https://www.gradescope.com")!,
            now: now
        )

        #expect(result.courses.count == 2)
        #expect(result.isFallback == false)
        let ids = Set(result.courses.map(\.url.absoluteString))
        #expect(ids.contains("https://www.gradescope.com/courses/111"))
        #expect(ids.contains("https://www.gradescope.com/courses/222"))
        #expect(!ids.contains("https://www.gradescope.com/courses/333"))
        #expect(!ids.contains("https://www.gradescope.com/courses/444"))
    }

    @Test("falls back to the most recent term within the grace window after its own window ends")
    func fallsBackToMostRecentTermWithinGraceWindow() throws {
        let html = """
        <div class="courseList">
          <div class="courseList--term">Fall 2025</div>
          <div class="courseList--coursesForTerm">
            <a class="courseBox" href="/courses/333">CIS 4000 Senior Design</a>
          </div>
          <div class="courseList--term">Spring 2025</div>
          <div class="courseList--coursesForTerm">
            <a class="courseBox" href="/courses/444">CIS 1200 Programming</a>
          </div>
        </div>
        """

        // Jan 10, 2026 — no group's window covers this date (Fall 2025's window
        // ends Dec 31, 2025; Spring 2025's ended long before that), but it's
        // still within the 21-day grace window past Fall 2025's window ending,
        // so the newest dated group (Fall 2025) wins as a fallback.
        let now = try #require(Self.utcDate(year: 2026, month: 1, day: 10, hour: 12, minute: 0))
        let result = GradescopeHTMLParser.currentTermCourses(
            from: html,
            baseURL: URL(string: "https://www.gradescope.com")!,
            now: now
        )

        #expect(result.courses.count == 1)
        #expect(result.courses.first?.url.absoluteString == "https://www.gradescope.com/courses/333")
        #expect(result.isFallback == true)
    }

    @Test("does not fall back once well past the grace window, even with a lone stale term")
    func doesNotFallBackOutsideGraceWindow() throws {
        let html = """
        <div class="courseList">
          <div class="courseList--term">Spring 2026</div>
          <div class="courseList--coursesForTerm">
            <a class="courseBox" href="/courses/111">CIS 5500 Databases</a>
          </div>
        </div>
        """

        // July 25, 2026 — Spring 2026's window ends Jun 30, and its 21-day
        // grace period expires Jul 21; no group's window covers Jul 25 either.
        // The completed Spring 2026 group must NOT be surfaced this late.
        let now = try #require(Self.utcDate(year: 2026, month: 7, day: 25, hour: 12, minute: 0))
        let result = GradescopeHTMLParser.currentTermCourses(
            from: html,
            baseURL: URL(string: "https://www.gradescope.com")!,
            now: now
        )

        #expect(result.courses.isEmpty)
        #expect(result.isFallback == false)
    }

    @Test("falls back within the grace window right after a lone term's window ends")
    func fallsBackWithinGraceWindowForNewTerm() throws {
        let html = """
        <div class="courseList">
          <div class="courseList--term">Spring 2026</div>
          <div class="courseList--coursesForTerm">
            <a class="courseBox" href="/courses/111">CIS 5500 Databases</a>
          </div>
        </div>
        """

        // July 5, 2026 — Spring 2026's window ends Jun 30, and this is only 5
        // days past that, well within the 21-day grace window, so the only
        // dated group (Spring 2026) is used as a fallback. Assignments from
        // it should have undated ones dropped (isFallback == true).
        let now = try #require(Self.utcDate(year: 2026, month: 7, day: 5, hour: 12, minute: 0))
        let result = GradescopeHTMLParser.currentTermCourses(
            from: html,
            baseURL: URL(string: "https://www.gradescope.com")!,
            now: now
        )

        #expect(result.courses.count == 1)
        #expect(result.courses.first?.url.absoluteString == "https://www.gradescope.com/courses/111")
        #expect(result.isFallback == true)
    }

    @Test("keeps an active Winter term for quarter-system schools")
    func keepsActiveWinterTermForQuarterSchools() throws {
        // The key regression test: a quarter school's "Winter 2026" heading
        // has no equivalent under the old single-current-term logic (which
        // could only ever compute spring/summer/fall from today's month), so
        // it would vanish entirely past the old grace window. Winter 2026's
        // window (Dec 1, 2025 – Mar 31, 2026) covers Feb 15, 2026.
        let html = """
        <div class="courseList">
          <div class="courseList--term">Winter 2026</div>
          <div class="courseList--coursesForTerm">
            <a class="courseBox" href="/courses/111">CIS 5500 Databases</a>
          </div>
        </div>
        """

        let now = try #require(Self.utcDate(year: 2026, month: 2, day: 15, hour: 12, minute: 0))
        let result = GradescopeHTMLParser.currentTermCourses(
            from: html,
            baseURL: URL(string: "https://www.gradescope.com")!,
            now: now
        )

        #expect(result.courses.count == 1)
        #expect(result.courses.first?.url.absoluteString == "https://www.gradescope.com/courses/111")
        #expect(result.isFallback == false)
    }

    @Test("keeps both Winter and Spring terms when both are active in February")
    func keepsBothWinterAndSpringInFebruary() throws {
        // Some students (or the same account across different schools' data)
        // can have both a quarter school's Winter heading and a semester
        // school's Spring heading; both windows cover Feb 15, so both should
        // be kept rather than the app picking just one.
        let html = """
        <div class="courseList">
          <div class="courseList--term">Winter 2026</div>
          <div class="courseList--coursesForTerm">
            <a class="courseBox" href="/courses/111">CIS 5500 Databases</a>
          </div>
          <div class="courseList--term">Spring 2026</div>
          <div class="courseList--coursesForTerm">
            <a class="courseBox" href="/courses/222">CIS 5050 Software Systems</a>
          </div>
        </div>
        """

        let now = try #require(Self.utcDate(year: 2026, month: 2, day: 15, hour: 12, minute: 0))
        let result = GradescopeHTMLParser.currentTermCourses(
            from: html,
            baseURL: URL(string: "https://www.gradescope.com")!,
            now: now
        )

        #expect(result.courses.count == 2)
        #expect(result.isFallback == false)
        let ids = Set(result.courses.map(\.url.absoluteString))
        #expect(ids.contains("https://www.gradescope.com/courses/111"))
        #expect(ids.contains("https://www.gradescope.com/courses/222"))
    }

    @Test("keeps an early-starting Fall term for semester schools")
    func keepsEarlyStartingFallTerm() throws {
        // Many semester schools start Fall in mid-to-late August; Fall
        // YYYY's window starts Aug 1 to cover that lead-in.
        let html = """
        <div class="courseList">
          <div class="courseList--term">Fall 2026</div>
          <div class="courseList--coursesForTerm">
            <a class="courseBox" href="/courses/333">CIS 4000 Senior Design</a>
          </div>
        </div>
        """

        let now = try #require(Self.utcDate(year: 2026, month: 8, day: 20, hour: 12, minute: 0))
        let result = GradescopeHTMLParser.currentTermCourses(
            from: html,
            baseURL: URL(string: "https://www.gradescope.com")!,
            now: now
        )

        #expect(result.courses.count == 1)
        #expect(result.courses.first?.url.absoluteString == "https://www.gradescope.com/courses/333")
        #expect(result.isFallback == false)
    }

    @Test("keeps both Summer and Spring terms when both are active in May")
    func keepsBothSummerAndSpringInMay() throws {
        // A mid-May summer session can start while Spring finals are still
        // wrapping up; both windows cover May 15, so both should be kept.
        let html = """
        <div class="courseList">
          <div class="courseList--term">Summer 2026</div>
          <div class="courseList--coursesForTerm">
            <a class="courseBox" href="/courses/555">CIS 5960 Summer Seminar</a>
          </div>
          <div class="courseList--term">Spring 2026</div>
          <div class="courseList--coursesForTerm">
            <a class="courseBox" href="/courses/222">CIS 5050 Software Systems</a>
          </div>
        </div>
        """

        let now = try #require(Self.utcDate(year: 2026, month: 5, day: 15, hour: 12, minute: 0))
        let result = GradescopeHTMLParser.currentTermCourses(
            from: html,
            baseURL: URL(string: "https://www.gradescope.com")!,
            now: now
        )

        #expect(result.courses.count == 2)
        #expect(result.isFallback == false)
        let ids = Set(result.courses.map(\.url.absoluteString))
        #expect(ids.contains("https://www.gradescope.com/courses/555"))
        #expect(ids.contains("https://www.gradescope.com/courses/222"))
    }

    @Test("Winter term window reaches back into the prior December")
    func winterWindowReachesBackIntoDecember() throws {
        // "Winter 2027" enrollment/orientation can begin in December 2026 —
        // the window starts Dec 1 of the prior year to cover that lead-in.
        let html = """
        <div class="courseList">
          <div class="courseList--term">Winter 2027</div>
          <div class="courseList--coursesForTerm">
            <a class="courseBox" href="/courses/666">CIS 6100 Advanced Topics</a>
          </div>
        </div>
        """

        let now = try #require(Self.utcDate(year: 2026, month: 12, day: 10, hour: 12, minute: 0))
        let result = GradescopeHTMLParser.currentTermCourses(
            from: html,
            baseURL: URL(string: "https://www.gradescope.com")!,
            now: now
        )

        #expect(result.courses.count == 1)
        #expect(result.courses.first?.url.absoluteString == "https://www.gradescope.com/courses/666")
        #expect(result.isFallback == false)
    }

    @Test("falls back to all courses when there are no term headings")
    func fallsBackWhenNoTermHeadings() throws {
        let html = """
        <main>
          <a class="courseBox" href="/courses/111">CIS 5500 Databases</a>
          <a class="courseBox" href="/courses/222">CIS 5050 Software Systems</a>
        </main>
        """

        let result = GradescopeHTMLParser.currentTermCourses(
            from: html,
            baseURL: URL(string: "https://www.gradescope.com")!
        )

        #expect(result.courses.count == 2)
        // No term grouping at all is not a "fallback" in the stale-term sense —
        // there's nothing to distrust it against, so undated assignments are
        // left alone.
        #expect(result.isFallback == false)
    }

    @Test("fallback courses drop undated assignments; current-term courses keep them")
    func filterFallbackAssignmentsDropsUndated() throws {
        let dated = Assignment(
            source: .gradescope,
            sourceID: "course-1-assignment-1",
            kind: .assignment,
            course: "CIS 5500",
            title: "Homework 1",
            dueAt: Date(),
            url: nil,
            submitted: false
        )
        let undated = Assignment(
            source: .gradescope,
            sourceID: "course-1-assignment-2",
            kind: .assignment,
            course: "CIS 5500",
            title: "Quiz 1",
            dueAt: nil,
            url: nil,
            submitted: false
        )

        let fallbackFiltered = GradescopeHTMLParser.filterFallbackAssignments([dated, undated], isFallback: true)
        #expect(fallbackFiltered.map(\.sourceID) == ["course-1-assignment-1"])

        let currentTermFiltered = GradescopeHTMLParser.filterFallbackAssignments([dated, undated], isFallback: false)
        #expect(Set(currentTermFiltered.map(\.sourceID)) == ["course-1-assignment-1", "course-1-assignment-2"])
    }

    @Test("parses assignments from a course table")
    func parsesAssignments() throws {
        let html = """
        <table>
          <tr>
            <th>Name</th><th>Status</th><th>Released</th><th>Due</th>
          </tr>
          <tr>
            <td><a href="/courses/12345/assignments/444">Homework 4 &amp; writeup</a></td>
            <td>Not Submitted</td>
            <td>May 1 at 12:00 PM</td>
            <td>May 24 at 11:59 PM</td>
          </tr>
          <tr>
            <td><a href="/courses/12345/assignments/555">Project Checkpoint</a></td>
            <td>Submitted</td>
            <td>May 5 at 12:00 PM</td>
            <td>June 2, 2026 at 11:59 PM</td>
          </tr>
          <tr>
            <td><a href="/courses/12345/assignments/666">Quiz Retake</a></td>
            <td>Graded</td>
            <td>May 8 at 12:00 PM</td>
            <td>June 4, 2026 at 11:59 PM</td>
          </tr>
          <tr>
            <td><a href="/courses/12345/assignments/777">Optional Practice</a></td>
            <td>Ungraded</td>
            <td>May 8 at 12:00 PM</td>
            <td>June 6, 2026 at 11:59 PM</td>
          </tr>
        </table>
        """

        let reference = try #require(Self.utcDate(year: 2026, month: 5, day: 21, hour: 12, minute: 0))
        let assignments = GradescopeHTMLParser.assignments(
            from: html,
            courseName: "CIS 5050 Software Systems",
            courseURL: URL(string: "https://www.gradescope.com/courses/12345")!,
            referenceDate: reference
        )

        #expect(assignments.count == 4)

        let hw = try #require(assignments.first { $0.sourceID == "course-12345-assignment-444" })
        #expect(hw.source == .gradescope)
        #expect(hw.kind == .assignment)
        #expect(hw.course == "CIS 5050 Software Systems")
        #expect(hw.title == "Homework 4 & writeup")
        #expect(hw.url?.absoluteString == "https://www.gradescope.com/courses/12345/assignments/444")
        #expect(hw.submitted == false)

        let checkpoint = try #require(assignments.first { $0.sourceID == "course-12345-assignment-555" })
        #expect(checkpoint.submitted == true)
        #expect(checkpoint.dueAt != nil)

        let graded = try #require(assignments.first { $0.sourceID == "course-12345-assignment-666" })
        #expect(graded.submitted == true)

        let ungraded = try #require(assignments.first { $0.sourceID == "course-12345-assignment-777" })
        #expect(ungraded.submitted == false)
    }

    @Test("parses due date and time from non-table Gradescope markup")
    func parsesDueDateFromSummaryMarkup() throws {
        let html = """
        <section>
          <a href="/courses/12345/assignments/888">Written Homework</a>
          <span>Due Date: May 24, 2026, 11:59 PM</span>
          <span>Status: Not Submitted</span>
        </section>
        """

        let assignments = GradescopeHTMLParser.assignments(
            from: html,
            courseName: "CIS 5050 Software Systems",
            courseURL: URL(string: "https://www.gradescope.com/courses/12345")!
        )

        let assignment = try #require(assignments.first)
        let due = try #require(assignment.dueAt)
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)

        #expect(components.year == 2026)
        #expect(components.month == 5)
        #expect(components.day == 24)
        #expect(components.hour == 23)
        #expect(components.minute == 59)
        #expect(assignment.submitted == false)
    }

    @Test("parses separate card assignments with datetime attributes")
    func parsesCardAssignmentsWithDatetimeAttributes() throws {
        let html = """
        <div class="assignment">
          <a href="/courses/12345/assignments/888">Written Homework</a>
          <time datetime="2026-05-24T23:59:00-04:00">Due May 24 at 11:59 PM EDT</time>
          <span>Status: Not Submitted</span>
        </div>
        <div class="assignment">
          <a href="/courses/12345/assignments/999">Project Demo</a>
          <span data-due-date="2026-06-02T17:30:00-04:00">Due Jun 2 at 5:30 PM EDT</span>
          <span>Status: Submitted</span>
        </div>
        """

        let assignments = GradescopeHTMLParser.assignments(
            from: html,
            courseName: "CIS 5050 Software Systems",
            courseURL: URL(string: "https://www.gradescope.com/courses/12345")!
        )

        #expect(assignments.count == 2)

        let homework = try #require(assignments.first { $0.sourceID == "course-12345-assignment-888" })
        let homeworkDue = try #require(homework.dueAt)
        var easternCalendar = Calendar(identifier: .gregorian)
        easternCalendar.timeZone = TimeZone(identifier: "America/New_York")!
        let homeworkComponents = easternCalendar.dateComponents([.year, .month, .day, .hour, .minute], from: homeworkDue)
        #expect(homeworkComponents.year == 2026)
        #expect(homeworkComponents.month == 5)
        #expect(homeworkComponents.day == 24)

        let demo = try #require(assignments.first { $0.sourceID == "course-12345-assignment-999" })
        let demoDue = try #require(demo.dueAt)
        let demoComponents = easternCalendar.dateComponents([.year, .month, .day, .hour, .minute], from: demoDue)
        #expect(demoComponents.year == 2026)
        #expect(demoComponents.month == 6)
        #expect(demoComponents.day == 2)
        #expect(demo.submitted == true)
    }

    @Test("yearless date far in the future resolves to last year")
    func yearlessFutureResolvesToLastYear() throws {
        let reference = try #require(Self.utcDate(year: 2026, month: 5, day: 21, hour: 12, minute: 0))
        let due = try #require(GradescopeHTMLParser.parseDate("Oct 15 at 11:59 PM", referenceDate: reference))
        let year = Calendar.current.component(.year, from: due)
        #expect(year == 2025)
    }

    @Test("yearless near-future date keeps the current year")
    func yearlessNearFutureKeepsCurrentYear() throws {
        let reference = try #require(Self.utcDate(year: 2026, month: 5, day: 21, hour: 12, minute: 0))
        let due = try #require(GradescopeHTMLParser.parseDate("Jun 5 at 11:59 PM", referenceDate: reference))
        let year = Calendar.current.component(.year, from: due)
        #expect(year == 2026)
    }

    @Test("yearless January date near year-end rolls into next year")
    func yearlessJanuaryRollsToNextYear() throws {
        let reference = try #require(Self.utcDate(year: 2026, month: 12, day: 20, hour: 12, minute: 0))
        let due = try #require(GradescopeHTMLParser.parseDate("Jan 5 at 11:59 PM", referenceDate: reference))
        let year = Calendar.current.component(.year, from: due)
        #expect(year == 2027)
    }

    @Test("explicit year in the string is always respected")
    func explicitYearRespected() throws {
        let reference = try #require(Self.utcDate(year: 2026, month: 5, day: 21, hour: 12, minute: 0))
        let due = try #require(GradescopeHTMLParser.parseDate("Oct 15, 2024 at 11:59 PM", referenceDate: reference))
        let year = Calendar.current.component(.year, from: due)
        #expect(year == 2024)
    }

    @Test("detects completed assignment detail pages")
    func detectsCompletedAssignmentDetailPages() {
        let submittedHTML = """
        <main>
          <h1>Homework 4</h1>
          <a href="/courses/12345/assignments/444/submissions/999">View Submission</a>
          <button>Resubmit</button>
        </main>
        """
        let scoredHTML = """
        <main>
          <h1>Project Demo</h1>
          <div>Score: 10 / 10</div>
        </main>
        """
        let missingHTML = """
        <main>
          <h1>Optional Practice</h1>
          <p>No submissions yet</p>
          <button>Submit Assignment</button>
        </main>
        """

        #expect(GradescopeHTMLParser.isCompletedAssignmentPage(submittedHTML))
        #expect(GradescopeHTMLParser.isCompletedAssignmentPage(scoredHTML))
        #expect(!GradescopeHTMLParser.isCompletedAssignmentPage(missingHTML))
    }

    // MARK: - The detail pass does not let the assignment's own name vote

    /// One course with one assignment whose row says "Open" (no keyword), so
    /// the row reads not submitted and `refineCompletionStatus` goes to the
    /// detail page.
    private func fetchedSubmitted(title: String, detailPage: String) async throws -> Bool {
        let account = """
        <div class="courseList">
          <div class="courseList--term">Fall 2026</div>
          <div class="courseList--coursesForTerm">
            <a class="courseBox" href="/courses/123">CIS 5050</a>
          </div>
        </div>
        """
        let course = """
        <table><tr>
          <td><a href="/courses/123/assignments/456">\(title)</a></td>
          <td>Sep 30, 2026 11:59 PM</td>
          <td>Open</td>
        </tr></table>
        """
        let session = stubSession { request in
            switch request.url?.path {
            case "/account": (200, account)
            case "/courses/123": (200, course)
            case "/courses/123/assignments/456": (200, detailPage)
            default: (404, "missing")
            }
        }
        defer { StubURLProtocol.handler = nil }
        let client = GradescopeClient(cookies: [], session: session)
        let assignments = try await client.fetchAssignments()
        return try #require(assignments.first).submitted
    }

    @Test("a detail page whose only keyword is the assignment's own name does not flip the row to submitted")
    func detailPassIgnoresTitleKeyword() async throws {
        let page = """
        <html><head><title>Graded Problem Set 3</title></head>
        <body><h1>Graded Problem Set 3</h1></body></html>
        """
        #expect(try await fetchedSubmitted(title: "Graded Problem Set 3", detailPage: page) == false)
    }

    @Test("a detail page with a real Submitted status still marks the row submitted")
    func detailPassStillReadsRealStatus() async throws {
        let page = """
        <html><head><title>Graded Problem Set 3</title></head>
        <body><h1>Graded Problem Set 3</h1><p>Status: Submitted</p></body></html>
        """
        #expect(try await fetchedSubmitted(title: "Graded Problem Set 3", detailPage: page) == true)
    }

    @Test("a negative word in the name does not hide a genuinely submitted detail page")
    func detailPassNegativeWordTitle() async throws {
        let page = """
        <html><head><title>Missing Data Lab | Gradescope</title></head>
        <body><h1>Missing Data Lab</h1><p>Submitted at Oct 5, 2026 at 11:12 PM</p></body></html>
        """
        #expect(try await fetchedSubmitted(title: "Missing Data Lab", detailPage: page) == true)
    }

    // MARK: - Score extraction (docs/grades.md §4, CP5)

    @Test("extracts earned/max from a labelled score string")
    func extractsLabelledScore() {
        let values = GradescopeHTMLParser.scoreValues(in: ["Score: 87.5 / 100"])
        #expect(values?.earned == 87.5)
        #expect(values?.max == 100)
    }

    @Test("extracts earned/max from a bare score cell")
    func extractsBareScoreCell() {
        let values = GradescopeHTMLParser.scoreValues(in: ["10.0 / 10.0"])
        #expect(values?.earned == 10.0)
        #expect(values?.max == 10.0)
    }

    @Test("extracts a decimal score")
    func extractsDecimalScore() {
        let values = GradescopeHTMLParser.scoreValues(in: ["Grade: 92.75 / 100"])
        #expect(values?.earned == 92.75)
        #expect(values?.max == 100)
    }

    @Test("extracts a genuine zero score, not confused with ungraded")
    func extractsZeroScore() {
        let values = GradescopeHTMLParser.scoreValues(in: ["0 / 100"])
        #expect(values?.earned == 0)
        #expect(values?.max == 100)
    }

    @Test("returns nil for an ungraded cell")
    func returnsNilForUngraded() {
        #expect(GradescopeHTMLParser.scoreValues(in: ["Ungraded"]) == nil)
        #expect(GradescopeHTMLParser.scoreValues(in: ["Not Submitted"]) == nil)
        #expect(GradescopeHTMLParser.scoreValues(in: ["Submitted"]) == nil)
    }

    @Test("tolerates weird whitespace around the slash")
    func toleratesWeirdWhitespace() {
        let values = GradescopeHTMLParser.scoreValues(in: ["  87.5   /   100  "])
        #expect(values?.earned == 87.5)
        #expect(values?.max == 100)

        let labelled = GradescopeHTMLParser.scoreValues(in: ["Score:    9  /  10   pts"])
        #expect(labelled?.earned == 9)
        #expect(labelled?.max == 10)
    }

    @Test("a due-date-shaped cell never false-positives as a score")
    func dueDateCellIsNotAScore() {
        #expect(GradescopeHTMLParser.scoreValues(in: ["5/24/2026"]) == nil)
        #expect(GradescopeHTMLParser.scoreValues(in: ["Due May 24 at 11:59 PM"]) == nil)
    }

    @Test("parses assignment rows with a graded score into scoreEarned/scoreMax")
    func parsesScoreIntoAssignment() throws {
        let html = """
        <table>
          <tr>
            <th>Name</th><th>Status</th><th>Grade</th><th>Due</th>
          </tr>
          <tr>
            <td><a href="/courses/12345/assignments/111">Homework 3</a></td>
            <td>Graded</td>
            <td>87.5 / 100</td>
            <td>May 24 at 11:59 PM</td>
          </tr>
          <tr>
            <td><a href="/courses/12345/assignments/222">Homework 4</a></td>
            <td>Not Submitted</td>
            <td></td>
            <td>June 1 at 11:59 PM</td>
          </tr>
        </table>
        """

        let assignments = GradescopeHTMLParser.assignments(
            from: html,
            courseName: "CIS 5050 Software Systems",
            courseURL: URL(string: "https://www.gradescope.com/courses/12345")!
        )

        let graded = try #require(assignments.first { $0.sourceID == "course-12345-assignment-111" })
        #expect(graded.scoreEarned == 87.5)
        #expect(graded.scoreMax == 100)
        #expect(graded.submitted == true)

        let ungraded = try #require(assignments.first { $0.sourceID == "course-12345-assignment-222" })
        #expect(ungraded.scoreEarned == nil)
        #expect(ungraded.scoreMax == nil)
    }

    @Test("detects Gradescope login pages")
    func detectsLoginPages() {
        let html = """
        <main>
          <h1>Log in to Gradescope</h1>
          <label>Email</label>
          <input type="email" name="session[email]">
          <label>Password</label>
          <input type="password" name="session[password]">
        </main>
        """

        #expect(GradescopeHTMLParser.isLoginPage(html))
    }

    private static func utcDate(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(
            timeZone: TimeZone(identifier: "UTC"),
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        ))
    }
}
