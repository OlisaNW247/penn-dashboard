import Foundation

/// Fetches the six structured Canvas endpoints the composed day reads, for a
/// list of courses, with the student's own session (same cookie / optional
/// bearer mechanism and `Link`-header pagination as `CanvasModulesClient`).
///
/// Two endpoints are user-wide (planner items, missing submissions) and are
/// fetched once per run; four are per course (modules, assignments with
/// overrides, discussion topics, pages).
///
/// Rate limits. Canvas throttles per user and reports the bucket in
/// `X-Rate-Limit-Remaining` on every response. This client reads it on each
/// one; when it falls under `rateLimitFloor`, or a 403 says
/// "Rate Limit Exceeded", it stops asking for more and reports
/// `rateLimited` on what it did not finish. The tempting wrong fix is to
/// throw: one hot bucket would then discard five courses of valid data that
/// were already in hand. The bucket belongs to the user, not to the course,
/// so once it runs low every remaining course is skipped, not just the
/// current one.
public struct CanvasStructuredSourcesClient: Sendable {
    public enum Endpoint: String, Sendable, Hashable, Codable {
        case planner, missingSubmissions, modules, assignments, discussionTopics, pages
    }

    public enum Error: Swift.Error, Sendable, Equatable {
        case sessionExpired
        case http(status: Int)
        case notHTTP
        case invalidURL
    }

    /// What one course produced. Each course is independent: a failure in
    /// one never discards another's data.
    public struct CourseResult: Sendable, Equatable {
        public let courseID: String
        public var modules: [CanvasStructuredModule] = []
        public var assignments: [CanvasOverrideAssignment] = []
        public var discussionTopics: [CanvasDiscussionTopic] = []
        public var pages: [CanvasStructuredPage] = []
        /// True when the rate limit stopped this course before every
        /// endpoint finished (the arrays above are then partial).
        public var rateLimited = false
        /// Endpoints that failed for a reason other than the rate limit.
        public var failedEndpoints: [Endpoint] = []
        /// Elements Canvas sent that could not be read.
        public var droppedCount = 0
        /// Endpoints that completed in full (no failure, no early stop).
        public var completedEndpoints: Set<Endpoint> = []

        public init(courseID: String) { self.courseID = courseID }
    }

    public struct RunResult: Sendable, Equatable {
        public var planner: [CanvasPlannerItem] = []
        public var missingSubmissions: [CanvasMissingSubmission] = []
        public var courses: [CourseResult] = []
        public var plannerCompleted = false
        public var missingCompleted = false
        public var rateLimited = false
        /// The session lapsed mid-run; everything after it was skipped.
        public var sessionExpired = false
        public var droppedCount = 0

        public init() {}
    }

    /// One HTTP exchange: the transport seam tests replace.
    public typealias Transport = @Sendable (URL) async throws -> (Data, HTTPURLResponse)

    private let baseURL: URL
    private let transport: Transport
    /// Below this many remaining requests, stop fetching. Tunable.
    public let rateLimitFloor: Double
    private let maxPages = 50

    public init(
        baseURL: URL = URL(string: "https://canvas.upenn.edu")!,
        cookies: [HTTPCookie],
        session: URLSession = .shared,
        accessToken: String? = nil,
        rateLimitFloor: Double = 50
    ) {
        self.baseURL = baseURL
        self.rateLimitFloor = rateLimitFloor
        self.transport = { url in
            var request = URLRequest(url: url)
            request.httpShouldHandleCookies = false
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            CanvasAuth.apply(to: &request, cookies: cookies, accessToken: accessToken)
            let (data, response) = try await session.credentialSafeData(for: request)
            guard let http = response as? HTTPURLResponse else { throw Error.notHTTP }
            return (data, http)
        }
    }

    /// Test seam: the same client over a canned transport.
    init(baseURL: URL, rateLimitFloor: Double = 50, transport: @escaping Transport) {
        self.baseURL = baseURL
        self.rateLimitFloor = rateLimitFloor
        self.transport = transport
    }

    // MARK: - Run

    /// Fetches everything for `courseIDs`. Never throws: every failure is
    /// recorded on the result.
    public func fetch(courseIDs: [String], plannerStart: Date, plannerEnd: Date) async -> RunResult {
        var result = RunResult()
        var state = Budget()

        // User-wide endpoints first.
        let plannerQuery = [
            URLQueryItem(name: "start_date", value: Self.iso8601(plannerStart)),
            URLQueryItem(name: "end_date", value: Self.iso8601(plannerEnd)),
            URLQueryItem(name: "per_page", value: "100"),
        ]
        switch await pages(path: "api/v1/planner/items", query: plannerQuery, state: &state) {
        case let .done(pages, complete):
            let decoded = CanvasStructuredDecoding.decode(CanvasPlannerItem.self, fromPages: pages)
            result.planner = decoded.elements
            result.droppedCount += decoded.dropped
            result.plannerCompleted = complete
        case .failed:
            break
        }

        if !state.stopped {
            let missingQuery = [
                URLQueryItem(name: "include[]", value: "planner_overrides"),
                URLQueryItem(name: "include[]", value: "course"),
                URLQueryItem(name: "per_page", value: "100"),
            ]
            if case let .done(pages, complete) = await self.pages(path: "api/v1/users/self/missing_submissions", query: missingQuery, state: &state) {
                let decoded = CanvasStructuredDecoding.decode(CanvasMissingSubmission.self, fromPages: pages)
                result.missingSubmissions = decoded.elements
                result.droppedCount += decoded.dropped
                result.missingCompleted = complete
            }
        }

        for courseID in courseIDs {
            var course = CourseResult(courseID: courseID)
            if state.stopped {
                // Skipped, not failed: the caller must not read "no
                // assignments" from an empty array.
                course.rateLimited = state.rateLimited
                result.courses.append(course)
                continue
            }
            await fetchCourse(&course, state: &state)
            result.droppedCount += course.droppedCount
            result.courses.append(course)
        }

        result.rateLimited = state.rateLimited
        result.sessionExpired = state.sessionExpired
        return result
    }

    private func fetchCourse(_ course: inout CourseResult, state: inout Budget) async {
        let base = "api/v1/courses/\(course.courseID)"
        let perPage = URLQueryItem(name: "per_page", value: "100")

        func run<T: Decodable & Sendable>(
            _ endpoint: Endpoint, _ path: String, _ query: [URLQueryItem], _ type: T.Type,
            into keyPath: WritableKeyPath<CourseResult, [T]>
        ) async {
            guard !state.stopped else { course.rateLimited = state.rateLimited; return }
            switch await pages(path: path, query: query, state: &state) {
            case let .done(pages, complete):
                let decoded = CanvasStructuredDecoding.decode(T.self, fromPages: pages)
                course[keyPath: keyPath] = decoded.elements
                course.droppedCount += decoded.dropped
                if complete { course.completedEndpoints.insert(endpoint) }
                if state.rateLimited { course.rateLimited = true }
            case .failed:
                if state.rateLimited { course.rateLimited = true } else { course.failedEndpoints.append(endpoint) }
            }
        }

        // Modules need the lossy per-item decoder with its dropped tally.
        if state.stopped {
            course.rateLimited = state.rateLimited
            return
        }
        switch await pages(path: "\(base)/modules", query: [
            URLQueryItem(name: "include[]", value: "items"),
            URLQueryItem(name: "include[]", value: "content_details"),
            perPage,
        ], state: &state) {
        case let .done(pages, complete):
            let decoded = CanvasStructuredDecoding.modules(fromPages: pages)
            course.modules = decoded.elements
            course.droppedCount += decoded.dropped
            if complete { course.completedEndpoints.insert(.modules) }
            if state.rateLimited { course.rateLimited = true }
        case .failed:
            if state.rateLimited { course.rateLimited = true } else { course.failedEndpoints.append(.modules) }
        }

        await run(.assignments, "\(base)/assignments", [
            URLQueryItem(name: "include[]", value: "all_dates"),
            URLQueryItem(name: "include[]", value: "overrides"),
            perPage,
        ], CanvasOverrideAssignment.self, into: \.assignments)
        await run(.discussionTopics, "\(base)/discussion_topics", [perPage], CanvasDiscussionTopic.self, into: \.discussionTopics)
        await run(.pages, "\(base)/pages", [perPage], CanvasStructuredPage.self, into: \.pages)
    }

    // MARK: - Paging with a shared budget

    /// Mutable per-run state: whether the rate limit or an expired session
    /// has told us to stop.
    private struct Budget {
        var rateLimited = false
        var sessionExpired = false
        var stopped: Bool { rateLimited || sessionExpired }
    }

    private enum PagesOutcome {
        /// `complete` is false when pagination stopped early (low bucket,
        /// untrusted next link, page cap): the data is real but partial.
        case done([Data], complete: Bool)
        case failed
    }

    private func pages(path: String, query: [URLQueryItem], state: inout Budget) async -> PagesOutcome {
        guard var components = URLComponents(url: baseURL.appendingPathComponent(path), resolvingAgainstBaseURL: false) else {
            return .failed
        }
        components.queryItems = query
        guard let first = components.url else { return .failed }

        var collected: [Data] = []
        var next: URL? = first
        var fetched = 0
        var complete = true
        while let url = next {
            fetched += 1
            guard fetched <= maxPages else { complete = false; break }
            let data: Data
            let http: HTTPURLResponse
            do {
                (data, http) = try await transport(url)
            } catch Error.sessionExpired {
                state.sessionExpired = true
                return collected.isEmpty ? .failed : .done(collected, complete: false)
            } catch {
                return collected.isEmpty ? .failed : .done(collected, complete: false)
            }

            if http.statusCode == 401 {
                state.sessionExpired = true
                return collected.isEmpty ? .failed : .done(collected, complete: false)
            }
            if http.statusCode == 403, Self.isRateLimitBody(data) {
                state.rateLimited = true
                return collected.isEmpty ? .failed : .done(collected, complete: false)
            }
            guard (200..<300).contains(http.statusCode) else {
                return collected.isEmpty ? .failed : .done(collected, complete: false)
            }
            let stripped = CanvasGradesClient.stripXSSIPrefix(data)
            if CanvasGradesClient.looksLikeHTML(stripped) {
                // 200 with a login page: the session lapsed.
                state.sessionExpired = true
                return collected.isEmpty ? .failed : .done(collected, complete: false)
            }
            collected.append(stripped)

            if let remaining = Self.remaining(in: http), remaining < rateLimitFloor {
                // This page is valid and kept; just stop asking for more.
                state.rateLimited = true
                complete = Self.nextLink(http, baseURL: baseURL) == nil
                break
            }
            if let candidate = CanvasGradesClient.nextPageURL(fromLinkHeader: http.value(forHTTPHeaderField: "Link")) {
                // Server-controlled input that would receive the session
                // cookie: same-host https only (see CanvasModulesClient).
                guard CanvasGradesClient.isTrustedNextPageURL(candidate, baseURL: baseURL) else {
                    complete = false
                    break
                }
                next = candidate
            } else {
                next = nil
            }
        }
        return .done(collected, complete: complete)
    }

    private static func nextLink(_ http: HTTPURLResponse, baseURL: URL) -> URL? {
        guard let url = CanvasGradesClient.nextPageURL(fromLinkHeader: http.value(forHTTPHeaderField: "Link")),
              CanvasGradesClient.isTrustedNextPageURL(url, baseURL: baseURL) else { return nil }
        return url
    }

    static func remaining(in http: HTTPURLResponse) -> Double? {
        guard let raw = http.value(forHTTPHeaderField: "X-Rate-Limit-Remaining") else { return nil }
        return Double(raw.trimmingCharacters(in: .whitespaces))
    }

    static func isRateLimitBody(_ data: Data) -> Bool {
        String(decoding: data.prefix(2000), as: UTF8.self).lowercased().contains("rate limit exceeded")
    }

    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
    }
}
