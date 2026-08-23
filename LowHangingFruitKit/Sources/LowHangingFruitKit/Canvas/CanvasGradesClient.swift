import Foundation

/// Fetches Canvas assignment groups + the course weighting flag, cookie-
/// authenticated the same way `CanvasDiscoveryClient` is (self-scoped REST API,
/// `SessionCookieStore` cookies — no OAuth available). Decodes into the models
/// `GradeEngine.compute()` consumes (see docs/grades.md §1, §9).
///
/// **One client, two concerns:** the `include[]=submission` payload also
/// carries `workflow_state` / `submitted_at`, which automatic submission
/// detection needs (docs/grades.md §12) — `CourseGradeSnapshot.submissions`
/// exposes that alongside the grade categories instead of a second client
/// re-fetching the same endpoint.
public struct CanvasGradesClient: Sendable {
    public enum Error: Swift.Error, Sendable, LocalizedError, Equatable {
        /// 401, or Canvas silently redirected to its HTML login page instead
        /// of erroring — both mean the session cookie lapsed. Kept distinct
        /// and detectable so callers treat it as a normal degraded state (show
        /// the last snapshot, marked stale) rather than a hard failure.
        case sessionExpired
        case http(status: Int, url: URL)
        case notHTTP
        case invalidURL
        case decodingFailed(String)

        public var errorDescription: String? {
            switch self {
            case .sessionExpired:
                return "Your Canvas session expired. Log in to Canvas again to refresh grades."
            case let .http(status, url):
                return "Canvas returned HTTP \(status) for \(url.path)."
            case .notHTTP:
                return "Canvas did not return a normal web response."
            case .invalidURL:
                return "Couldn't build a Canvas grades request URL."
            case let .decodingFailed(detail):
                return "Canvas returned grades in an unexpected format (\(detail))."
            }
        }
    }

    private let baseURL: URL
    private let cookies: [HTTPCookie]
    private let session: URLSession

    public init(
        baseURL: URL = URL(string: "https://canvas.upenn.edu")!,
        cookies: [HTTPCookie],
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.cookies = cookies
        self.session = session
    }

    // MARK: - Networked fetch

    /// Fetches everything needed for one course's grade breakdown: paginated
    /// assignment groups (+ assignments + submissions) and the course's
    /// weighting flag / Canvas-computed cross-check score.
    public func fetchSnapshot(courseID: String, now: Date = Date()) async throws -> CourseGradeSnapshot {
        async let groupPages = fetchAllAssignmentGroupPages(courseID: courseID)
        async let coursePage = fetchCourseInfoPage(courseID: courseID)
        let (pages, course) = try await (groupPages, coursePage)
        return try Self.decodeSnapshot(courseID: courseID, courseJSON: course, assignmentGroupPages: pages, now: now)
    }

    /// GET .../assignment_groups?include[]=assignments&include[]=submission&per_page=100,
    /// following the `Link: rel="next"` header until exhausted (large courses).
    private func fetchAllAssignmentGroupPages(courseID: String) async throws -> [Data] {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("api/v1/courses/\(courseID)/assignment_groups"),
            resolvingAgainstBaseURL: false
        ) else { throw Error.invalidURL }
        components.queryItems = [
            URLQueryItem(name: "include[]", value: "assignments"),
            URLQueryItem(name: "include[]", value: "submission"),
            URLQueryItem(name: "per_page", value: "100"),
        ]
        guard let firstURL = components.url else { throw Error.invalidURL }

        var pages: [Data] = []
        var nextURL: URL? = firstURL
        var pagesFetched = 0
        // Safety valve: a well-behaved Canvas instance won't loop, but this
        // keeps a malformed Link header from spinning forever.
        let maxPages = 50

        while let url = nextURL {
            pagesFetched += 1
            guard pagesFetched <= maxPages else { break }
            let (data, http) = try await fetchRaw(url)
            pages.append(data)

            guard let candidate = Self.nextPageURL(fromLinkHeader: http.value(forHTTPHeaderField: "Link")) else {
                nextURL = nil
                continue
            }
            // Security: a `Link: rel="next"` header is server-controlled input.
            // `fetchRaw` unconditionally attaches the stored Canvas session
            // cookies to whatever URL it's given, so a next-page URL pointing
            // off-host would leak the session cookie to a third party. Refuse
            // to follow it — stop pagination rather than fetch a truncated-but-
            // safe result silently; this only ever costs the tail of a very
            // large course's assignment list.
            guard Self.isTrustedNextPageURL(candidate, baseURL: baseURL) else {
                nextURL = nil
                continue
            }
            nextURL = candidate
        }
        return pages
    }

    /// GET .../courses/:id?include[]=total_scores — carries both
    /// `apply_assignment_group_weights` and (per enrollment) `computed_current_score`.
    private func fetchCourseInfoPage(courseID: String) async throws -> Data {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("api/v1/courses/\(courseID)"),
            resolvingAgainstBaseURL: false
        ) else { throw Error.invalidURL }
        components.queryItems = [URLQueryItem(name: "include[]", value: "total_scores")]
        guard let url = components.url else { throw Error.invalidURL }
        let (data, _) = try await fetchRaw(url)
        return data
    }

    private func fetchRaw(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        // See `CanvasDiscoveryClient.fetchHTML`'s matching comment — an
        // explicit `Cookie` header below means this must be `false`
        // (docs/CANVAS_LOGIN_HARDENING.md item 2c).
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (field, value) in HTTPCookie.requestHeaderFields(with: cookies) {
            request.setValue(value, forHTTPHeaderField: field)
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Error.notHTTP }
        if http.statusCode == 401 { throw Error.sessionExpired }
        guard (200..<300).contains(http.statusCode) else {
            throw Error.http(status: http.statusCode, url: url)
        }

        let stripped = Self.stripXSSIPrefix(data)
        if Self.looksLikeHTML(stripped) {
            // Canvas returned 200 but the body is HTML — a silent
            // redirect-to-login rather than the JSON we asked for.
            throw Error.sessionExpired
        }
        return (stripped, http)
    }

    // MARK: - Pure parsing (no network; used directly by tests and by fetchSnapshot)

    /// Strips Canvas's `while(1);` XSSI-protection prefix some JSON endpoints
    /// prepend, if present. A no-op otherwise.
    public static func stripXSSIPrefix(_ data: Data) -> Data {
        let prefix = Data("while(1);".utf8)
        guard data.starts(with: prefix) else { return data }
        return data.dropFirst(prefix.count)
    }

    /// True if the payload looks like an HTML document rather than JSON — the
    /// tell for a silent redirect-to-login when the session cookie lapsed.
    public static func looksLikeHTML(_ data: Data) -> Bool {
        guard let firstNonWhitespace = data.first(where: { ![0x20, 0x09, 0x0A, 0x0D].contains($0) }) else {
            return false
        }
        return firstNonWhitespace == UInt8(ascii: "<")
    }

    /// Whether a candidate `Link: rel="next"` URL is safe to both fetch AND
    /// attach the Canvas session cookies to: must be `https` and share
    /// `baseURL`'s host exactly (case-insensitively — Canvas hosts aren't
    /// case-sensitive, but a subdomain like `evil.canvas.upenn.edu` or a
    /// suffix trick like `canvas.upenn.edu.evil.com` must NOT pass). Public so
    /// the pagination guard above and the test suite exercise the same logic.
    public static func isTrustedNextPageURL(_ url: URL, baseURL: URL) -> Bool {
        guard url.scheme?.lowercased() == "https" else { return false }
        guard let host = url.host, let baseHost = baseURL.host else { return false }
        return host.caseInsensitiveCompare(baseHost) == .orderedSame
    }

    /// Parses a `Link` response header (RFC 5988 style) for the `rel="next"` URL.
    public static func nextPageURL(fromLinkHeader header: String?) -> URL? {
        guard let header else { return nil }
        for part in header.components(separatedBy: ",") {
            let segments = part.components(separatedBy: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard let first = segments.first, first.hasPrefix("<"), first.hasSuffix(">") else { continue }
            let urlString = String(first.dropFirst().dropLast())
            let isNext = segments.dropFirst().contains {
                $0.replacingOccurrences(of: " ", with: "") == "rel=\"next\""
            }
            if isNext, let url = URL(string: urlString) { return url }
        }
        return nil
    }

    /// Decodes raw (possibly XSSI-prefixed) course + assignment-group-page JSON
    /// into the engine's input models, with no network I/O — the seam tests use
    /// so fixtures can stand in for real Canvas responses.
    public static func decodeSnapshot(
        courseID: String,
        courseJSON: Data,
        assignmentGroupPages: [Data],
        now: Date = Date()
    ) throws -> CourseGradeSnapshot {
        let decoder = JSONDecoder()

        let course: CourseInfoDTO
        do {
            course = try decoder.decode(CourseInfoDTO.self, from: stripXSSIPrefix(courseJSON))
        } catch {
            throw Error.decodingFailed("course info: \(error)")
        }

        var groups: [AssignmentGroupDTO] = []
        for (index, page) in assignmentGroupPages.enumerated() {
            do {
                groups += try decoder.decode([AssignmentGroupDTO].self, from: stripXSSIPrefix(page))
            } catch {
                throw Error.decodingFailed("assignment_groups page \(index): \(error)")
            }
        }

        let categories = groups.map(mapCategory)
        let submissions = groups.flatMap { group in
            (group.assignments ?? []).map { mapSubmission(assignmentID: $0.id, dto: $0.submission) }
        }

        return CourseGradeSnapshot(
            courseID: courseID,
            courseUsesWeights: course.applyAssignmentGroupWeights ?? false,
            categories: categories,
            canvasComputedCurrentScore: studentComputedScore(course),
            submissions: submissions,
            fetchedAt: now
        )
    }

    /// `computed_current_score` is a cross-check only (docs/grades.md §1) —
    /// nil when the professor hides totals, which is a normal state, not an
    /// error. Prefers the student's own enrollment row when the course object
    /// carries more than one (e.g. a TA also enrolled as a student).
    private static func studentComputedScore(_ course: CourseInfoDTO) -> Double? {
        let enrollments = course.enrollments ?? []
        if let student = enrollments.first(where: { ($0.type ?? "").localizedCaseInsensitiveContains("student") }) {
            return student.computedCurrentScore?.value
        }
        return enrollments.first?.computedCurrentScore?.value
    }

    private static func mapCategory(_ dto: AssignmentGroupDTO) -> GradeCategory {
        GradeCategory(
            id: String(dto.id),
            name: dto.name,
            weight: dto.groupWeight?.value,
            dropLowest: dto.rules?.dropLowest ?? 0,
            dropHighest: dto.rules?.dropHighest ?? 0,
            neverDropIDs: Set((dto.rules?.neverDrop ?? []).map(\.stringValue)),
            items: (dto.assignments ?? []).map(mapItem)
        )
    }

    private static func mapItem(_ dto: AssignmentDTO) -> GradeItem {
        let score = dto.submission?.score?.value
        return GradeItem(
            id: String(dto.id),
            name: dto.name,
            pointsPossible: dto.pointsPossible?.value ?? 0,
            score: score,
            scoreSource: score != nil ? .canvas : nil,
            isExcused: dto.submission?.excused ?? false,
            omitFromFinalGrade: dto.omitFromFinalGrade ?? false,
            dueAt: parseDate(dto.dueAt)
        )
    }

    private static func mapSubmission(assignmentID: Int, dto: SubmissionDTO?) -> AssignmentSubmissionInfo {
        AssignmentSubmissionInfo(
            assignmentID: String(assignmentID),
            workflowState: CanvasSubmissionState(rawValue: dto?.workflowState ?? "") ?? .unknown,
            submittedAt: parseDate(dto?.submittedAt),
            isMissing: dto?.missing ?? false,
            isLate: dto?.late ?? false
        )
    }

    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        // Built locally (not cached as static state) since ISO8601DateFormatter
        // isn't Sendable and this type needs to stay Sendable itself.
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}

// MARK: - Submission state (drives automatic submission detection; see docs/grades.md §12)

/// Canvas's `submission.workflow_state`. Exposed so automatic submission
/// detection can drive "submitted" state from the same fetch this client
/// already does for grades (see `AssignmentSubmissionInfo.indicatesSubmitted`).
public enum CanvasSubmissionState: String, Sendable, Codable, Hashable {
    case submitted
    case unsubmitted
    case graded
    case pendingReview = "pending_review"
    /// Any workflow_state Canvas sends that we don't recognize yet, or no
    /// submission object at all (e.g. an ungraded/never-touched assignment).
    case unknown
}

public struct AssignmentSubmissionInfo: Sendable, Hashable, Codable {
    public let assignmentID: String
    public let workflowState: CanvasSubmissionState
    public let submittedAt: Date?
    public let isMissing: Bool
    public let isLate: Bool

    public init(
        assignmentID: String,
        workflowState: CanvasSubmissionState,
        submittedAt: Date?,
        isMissing: Bool,
        isLate: Bool
    ) {
        self.assignmentID = assignmentID
        self.workflowState = workflowState
        self.submittedAt = submittedAt
        self.isMissing = isMissing
        self.isLate = isLate
    }

    /// Whether this submission record indicates the student actually turned the
    /// work in — the signal that drives auto "submitted" state on the dashboard.
    /// Conservative by design: only positive signals flip to submitted, so we
    /// never auto-mark real work incomplete. A professor-entered score on missing
    /// work arrives as `graded` with `isMissing == true` and no `submittedAt`, so
    /// `isMissing` is excluded up front and `graded` counts only when it carries a
    /// real submission timestamp.
    public var indicatesSubmitted: Bool {
        guard !isMissing else { return false }
        if submittedAt != nil { return true }
        return workflowState == .submitted || workflowState == .pendingReview
    }
}

// MARK: - Output: everything GradeEngine.compute() needs for one course

/// One course's fetched-and-decoded grade inputs, ready to hand to
/// `GradeEngine.compute(_:)` (plus the submission-state side channel above).
public struct CourseGradeSnapshot: Sendable, Hashable, Codable {
    public let courseID: String
    public let courseUsesWeights: Bool
    public let categories: [GradeCategory]
    /// Canvas's own `computed_current_score` — a cross-check only, nil when
    /// the professor hides totals (a normal state, not an error).
    public let canvasComputedCurrentScore: Double?
    public let submissions: [AssignmentSubmissionInfo]
    public let fetchedAt: Date

    public init(
        courseID: String,
        courseUsesWeights: Bool,
        categories: [GradeCategory],
        canvasComputedCurrentScore: Double?,
        submissions: [AssignmentSubmissionInfo],
        fetchedAt: Date
    ) {
        self.courseID = courseID
        self.courseUsesWeights = courseUsesWeights
        self.categories = categories
        self.canvasComputedCurrentScore = canvasComputedCurrentScore
        self.submissions = submissions
        self.fetchedAt = fetchedAt
    }
}

// MARK: - Wire DTOs (private — decode Canvas JSON, tolerant of garbage numeric fields)

private struct CourseInfoDTO: Decodable {
    let applyAssignmentGroupWeights: Bool?
    let enrollments: [EnrollmentDTO]?

    enum CodingKeys: String, CodingKey {
        case applyAssignmentGroupWeights = "apply_assignment_group_weights"
        case enrollments
    }

    struct EnrollmentDTO: Decodable {
        let type: String?
        let computedCurrentScore: FlexibleDouble?
        enum CodingKeys: String, CodingKey {
            case type
            case computedCurrentScore = "computed_current_score"
        }
    }
}

private struct AssignmentGroupDTO: Decodable {
    let id: Int
    let name: String
    /// Canvas's `group_weight` — present but garbage when the course isn't in
    /// weighted mode (docs/grades.md §1), so this is decoded leniently and the
    /// engine is only ever told to use it via the course-level flag.
    let groupWeight: FlexibleDouble?
    let rules: RulesDTO?
    let assignments: [AssignmentDTO]?

    enum CodingKeys: String, CodingKey {
        case id, name
        case groupWeight = "group_weight"
        case rules, assignments
    }

    struct RulesDTO: Decodable {
        let dropLowest: Int?
        let dropHighest: Int?
        let neverDrop: [FlexibleID]?
        enum CodingKeys: String, CodingKey {
            case dropLowest = "drop_lowest"
            case dropHighest = "drop_highest"
            case neverDrop = "never_drop"
        }
    }
}

private struct AssignmentDTO: Decodable {
    let id: Int
    let name: String
    let pointsPossible: FlexibleDouble?
    let omitFromFinalGrade: Bool?
    let dueAt: String?
    let submission: SubmissionDTO?

    enum CodingKeys: String, CodingKey {
        case id, name
        case pointsPossible = "points_possible"
        case omitFromFinalGrade = "omit_from_final_grade"
        case dueAt = "due_at"
        case submission
    }
}

private struct SubmissionDTO: Decodable {
    let score: FlexibleDouble?
    let excused: Bool?
    let workflowState: String?
    let missing: Bool?
    let late: Bool?
    let submittedAt: String?

    enum CodingKeys: String, CodingKey {
        case score, excused
        case workflowState = "workflow_state"
        case missing, late
        case submittedAt = "submitted_at"
    }
}

/// Some Canvas payloads carry garbage in numeric fields when a feature doesn't
/// apply to that course (e.g. `group_weight` in points mode has been observed
/// as a stray string or plain `null`). Decoding tolerates that instead of
/// failing the entire assignment_groups page over one cosmetic field.
private struct FlexibleDouble: Decodable {
    let value: Double?

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            value = nil
        } else if let doubleValue = try? container.decode(Double.self) {
            value = doubleValue
        } else if let stringValue = try? container.decode(String.self) {
            value = Double(stringValue)
        } else {
            value = nil
        }
    }
}

/// Canvas assignment ids are normally numbers, but `rules.never_drop` entries
/// tolerate strings too on some instances — decode either.
private struct FlexibleID: Decodable {
    let stringValue: String

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let intValue = try? container.decode(Int.self) {
            stringValue = String(intValue)
        } else if let raw = try? container.decode(String.self) {
            stringValue = raw
        } else {
            stringValue = ""
        }
    }
}
