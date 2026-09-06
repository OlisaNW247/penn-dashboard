import Foundation

/// Fetches the two kinds of course text no existing client returns:
/// assignment **descriptions** (with the student's submission state) and the
/// bodies of a course's **wiki pages**. Syllabi, announcements and modules
/// already have clients (`CanvasSyllabusClient`, `CanvasAnnouncementsClient`,
/// `CanvasModulesClient`); `CourseKnowledgeCollector` uses those for their
/// kinds and this one only for the gap.
///
/// Cookie-authenticated the same way the other Canvas clients are: explicit
/// `Cookie` header, `httpShouldHandleCookies = false` (docs/
/// CANVAS_LOGIN_HARDENING.md item 2c), XSSI prefix stripped, a login-page
/// redirect surfaced as `sessionExpired`, pagination guarded to the same
/// HTTPS host. Deliberately self-contained rather than sharing code with
/// `CanvasGradesClient` — the same stance that file documents.
public struct CanvasCourseContentClient: Sendable {
    public enum Error: Swift.Error, Sendable, LocalizedError, Equatable {
        /// 401/403, or Canvas silently redirected to its HTML login page.
        case sessionExpired
        case http(Int)
        case notHTTP
        case invalidJSON(String)
        case unsafePaginationURL

        public var errorDescription: String? {
            switch self {
            case .sessionExpired: return "Your Canvas session has expired. Reconnect Canvas in Settings."
            case let .http(status): return "Canvas returned HTTP \(status)."
            case .notHTTP: return "Canvas did not return a normal web response."
            case let .invalidJSON(detail): return "Canvas returned data the app could not read: \(detail)"
            case .unsafePaginationURL: return "Canvas pointed pagination at an unexpected host."
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

    /// GET /api/v1/courses/:id/assignments?include[]=submission, every page.
    public func assignments(courseID: String) async throws -> [CourseContentAssignment] {
        let url = api("courses/\(courseID)/assignments", query: [
            ("per_page", "100"),
            ("include[]", "submission"),
            ("order_by", "due_at"),
        ])
        return try await getAllPages(url)
    }

    /// GET /api/v1/courses/:id/pages (listing), then each published page's
    /// body — the listing endpoint never includes bodies. Capped because a
    /// course with two hundred pages is a course packet, not a syllabus.
    public func pages(courseID: String, maxBodies: Int = 40) async throws -> [CourseContentPage] {
        let listURL = api("courses/\(courseID)/pages", query: [
            ("per_page", "100"),
            ("sort", "updated_at"),
            ("order", "desc"),
        ])
        let listing: [CourseContentPage] = try await getAllPages(listURL)
        var pages: [CourseContentPage] = []
        for page in listing.prefix(maxBodies) where page.published != false {
            let slug = page.url.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? page.url
            // One broken page shouldn't sink the rest of the course.
            guard let full: CourseContentPage = try? await getOne(api("courses/\(courseID)/pages/\(slug)")) else { continue }
            pages.append(full)
        }
        return pages
    }

    // MARK: - HTTP

    private func api(_ path: String, query: [(String, String)] = []) -> URL {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/v1/\(path)"), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        }
        return components.url!
    }

    private func getOne<T: Decodable>(_ url: URL) async throws -> T {
        let (data, _) = try await fetch(url)
        return try decode(T.self, from: data)
    }

    private func getAllPages<T: Decodable>(_ url: URL) async throws -> [T] {
        var results: [T] = []
        var next: URL? = url
        var pageCount = 0
        while let pageURL = next, pageCount < 50 {
            pageCount += 1
            let (data, response) = try await fetch(pageURL)
            results.append(contentsOf: try decode([T].self, from: data))
            next = try CourseContentAPI.nextPageURL(fromLinkHeader: response.value(forHTTPHeaderField: "Link"), sameHostAs: baseURL)
        }
        return results
    }

    private func fetch(_ url: URL) async throws -> (Data, HTTPURLResponse) {
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        for (field, value) in HTTPCookie.requestHeaderFields(with: cookies) {
            request.setValue(value, forHTTPHeaderField: field)
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Error.notHTTP }
        if http.statusCode == 401 || http.statusCode == 403 { throw Error.sessionExpired }
        guard (200..<300).contains(http.statusCode) else { throw Error.http(http.statusCode) }
        if let type = http.value(forHTTPHeaderField: "Content-Type"), type.localizedCaseInsensitiveContains("text/html") {
            throw Error.sessionExpired
        }
        return (data, http)
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try CourseContentAPI.decoder().decode(T.self, from: CourseContentAPI.stripAntiHijackPrefix(data))
        } catch {
            throw Error.invalidJSON(String(describing: error))
        }
    }
}

// MARK: - Wire shapes

public struct CourseContentSubmission: Decodable, Sendable, Hashable {
    public let workflowState: String?
    public let submittedAt: Date?

    enum CodingKeys: String, CodingKey {
        case workflowState = "workflow_state"
        case submittedAt = "submitted_at"
    }

    public init(workflowState: String?, submittedAt: Date?) {
        self.workflowState = workflowState
        self.submittedAt = submittedAt
    }

    public var isSubmitted: Bool {
        if submittedAt != nil { return true }
        switch workflowState {
        case "submitted", "graded", "pending_review": return true
        default: return false
        }
    }
}

public struct CourseContentAssignment: Decodable, Sendable, Hashable {
    public let id: Int
    public let name: String
    public let description: String?
    public let dueAt: Date?
    public let htmlURL: URL?
    public let pointsPossible: Double?
    public let updatedAt: Date?
    public let submission: CourseContentSubmission?

    enum CodingKeys: String, CodingKey {
        case id, name, description, submission
        case dueAt = "due_at"
        case htmlURL = "html_url"
        case pointsPossible = "points_possible"
        case updatedAt = "updated_at"
    }
}

public struct CourseContentPage: Decodable, Sendable, Hashable {
    public let url: String
    public let title: String
    public let body: String?
    public let htmlURL: URL?
    public let updatedAt: Date?
    public let published: Bool?

    enum CodingKeys: String, CodingKey {
        case url, title, body, published
        case htmlURL = "html_url"
        case updatedAt = "updated_at"
    }
}

/// The quirks of Canvas's JSON API when called with a browser session.
public enum CourseContentAPI {
    /// Canvas prefixes JSON with `while(1);` to defeat JSON hijacking.
    public static func stripAntiHijackPrefix(_ data: Data) -> Data {
        let prefix = Array("while(1);".utf8)
        guard data.count >= prefix.count, Array(data.prefix(prefix.count)) == prefix else { return data }
        return data.dropFirst(prefix.count)
    }

    /// Accepts Canvas's ISO-8601 timestamps with or without fractional
    /// seconds. Built per call because formatters aren't Sendable.
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            if let date = parseDate(raw) { return date }
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unrecognized date \(raw)")
        }
        return decoder
    }

    public static func parseDate(_ raw: String) -> Date? {
        let withFraction = ISO8601DateFormatter()
        withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = withFraction.date(from: raw) { return date }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    /// The `rel="next"` URL from a `Link` header, refused unless it stays on
    /// the same HTTPS host — session cookies must never follow a redirect
    /// elsewhere.
    public static func nextPageURL(fromLinkHeader header: String?, sameHostAs base: URL) throws -> URL? {
        guard let header else { return nil }
        for part in header.split(separator: ",") {
            let pieces = part.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
            guard pieces.count >= 2,
                  pieces.dropFirst().contains(where: { $0.replacingOccurrences(of: " ", with: "") == "rel=\"next\"" }),
                  pieces[0].hasPrefix("<"), pieces[0].hasSuffix(">"),
                  let url = URL(string: String(pieces[0].dropFirst().dropLast()))
            else { continue }
            guard url.scheme?.lowercased() == "https", url.host?.lowercased() == base.host?.lowercased() else {
                throw CanvasCourseContentClient.Error.unsafePaginationURL
            }
            return url
        }
        return nil
    }
}

/// Pure mapping from Canvas objects (this client's and the existing clients')
/// to `CourseDocument`s. Kept apart from the network so it can be tested
/// against fixtures.
public enum CourseDocumentBuilder {
    public static func assignment(from assignment: CourseContentAssignment, course: CourseSummary, now: Date = Date()) -> CourseDocument {
        var lines: [String] = []
        if let due = assignment.dueAt {
            lines.append("Due: \(DateText.long(due))")
        } else {
            lines.append("Due: no due date")
        }
        if let points = assignment.pointsPossible {
            lines.append("Points: \(DateText.trimmed(points))")
        }
        if let submission = assignment.submission {
            lines.append(submission.isSubmitted ? "Status: submitted" : "Status: not submitted")
        }
        let description = HTMLText.plainText(from: assignment.description ?? "")
        if !description.isEmpty { lines.append(description) }

        return CourseDocument(
            courseID: course.courseID,
            course: course.code,
            kind: .assignment,
            sourceID: String(assignment.id),
            title: assignment.name,
            url: assignment.htmlURL,
            text: lines.joined(separator: "\n"),
            updatedAt: assignment.updatedAt,
            fetchedAt: now,
            dueAt: assignment.dueAt,
            pointsPossible: assignment.pointsPossible,
            submitted: assignment.submission?.isSubmitted
        )
    }

    public static func page(from page: CourseContentPage, course: CourseSummary, now: Date = Date()) -> CourseDocument {
        CourseDocument(
            courseID: course.courseID,
            course: course.code,
            kind: .page,
            sourceID: page.url,
            title: page.title,
            url: page.htmlURL,
            text: HTMLText.plainText(from: page.body ?? ""),
            updatedAt: page.updatedAt,
            fetchedAt: now
        )
    }

    /// A syllabus candidate `CanvasSyllabusClient` found — the whole text,
    /// prose included. This is the piece `SyllabusParser` throws away and
    /// the one ask needs most.
    public static func syllabus(from candidate: SyllabusCandidate, course: CourseSummary, now: Date = Date()) -> CourseDocument? {
        let text = candidate.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        let url: URL? = candidate.source == .canvasSyllabusPage
            ? course.url?.appendingPathComponent("assignments/syllabus")
            : nil
        return CourseDocument(
            courseID: course.courseID,
            course: course.code,
            kind: .syllabus,
            sourceID: candidate.id,
            title: candidate.name.isEmpty ? "\(course.code) syllabus" : candidate.name,
            url: url,
            text: text,
            fetchedAt: now
        )
    }

    /// An announcement from `CanvasAnnouncementsClient`, whose `message` is
    /// already plain text.
    public static func announcement(from announcement: CanvasAnnouncement, course: CourseSummary, now: Date = Date()) -> CourseDocument {
        var lines: [String] = []
        if let posted = announcement.postedAt {
            lines.append("Posted: \(DateText.long(posted))")
        }
        let message = announcement.message.trimmingCharacters(in: .whitespacesAndNewlines)
        if !message.isEmpty { lines.append(message) }
        return CourseDocument(
            courseID: course.courseID,
            course: course.code,
            kind: .announcement,
            sourceID: announcement.id,
            title: announcement.title,
            url: announcement.url,
            text: lines.joined(separator: "\n"),
            updatedAt: announcement.postedAt,
            fetchedAt: now
        )
    }

    /// `CanvasModulesClient` returns a flat item list; one document per module
    /// (grouped by `moduleName`) reads the way the Modules page does.
    public static func modules(from items: [CanvasModulesClient.ModuleItem], course: CourseSummary, now: Date = Date()) -> [CourseDocument] {
        var order: [String] = []
        var grouped: [String: [CanvasModulesClient.ModuleItem]] = [:]
        for item in items {
            let name = item.moduleName ?? "Modules"
            if grouped[name] == nil { order.append(name) }
            grouped[name, default: []].append(item)
        }
        return order.map { name in
            let lines = (grouped[name] ?? []).map { item -> String in
                let due = item.dueAt.map { " · due \(DateText.short($0))" } ?? ""
                return "• \(item.title) (\(item.typeRaw.lowercased()))\(due)"
            }
            return CourseDocument(
                courseID: course.courseID,
                course: course.code,
                kind: .module,
                sourceID: ContentHash.fnv1a(name),
                title: name,
                url: course.url?.appendingPathComponent("modules"),
                text: lines.joined(separator: "\n"),
                fetchedAt: now
            )
        }
    }
}

/// Date/number rendering shared by the builder and the answerer. Formatters
/// are built per call: they aren't Sendable, so they can't be static lets.
public enum DateText {
    public static func long(_ date: Date, calendar: Calendar = .current) -> String {
        formatter(calendar, format: "EEE, MMM d 'at' h:mm a").string(from: date)
    }

    public static func short(_ date: Date, calendar: Calendar = .current) -> String {
        formatter(calendar, format: "EEE MMM d, h:mm a").string(from: date)
    }

    public static func dayOnly(_ date: Date, calendar: Calendar = .current) -> String {
        formatter(calendar, format: "EEEE, MMM d").string(from: date)
    }

    public static func trimmed(_ value: Double) -> String {
        value.rounded() == value ? String(Int(value)) : String(value)
    }

    private static func formatter(_ calendar: Calendar, format: String) -> DateFormatter {
        let formatter = DateFormatter()
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.locale = calendar.locale ?? Locale(identifier: "en_US")
        formatter.dateFormat = format
        return formatter
    }
}
