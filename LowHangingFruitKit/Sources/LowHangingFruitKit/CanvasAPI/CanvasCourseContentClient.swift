import Foundation

/// Fetches the two kinds of course text no existing client returns:
/// assignment **descriptions** (with the student's submission state) and the
/// bodies of a course's **wiki pages**. Syllabi, announcements and modules
/// already have clients (`CanvasSyllabusClient`, `CanvasAnnouncementsClient`,
/// `CanvasModulesClient`); `CourseKnowledgeCollector` uses those for their
/// kinds and this one only for the gap.
///
/// Authenticated the same way the other Canvas clients are: explicit
/// `Cookie` header, `httpShouldHandleCookies = false` (docs/
/// CANVAS_LOGIN_HARDENING.md item 2c), XSSI prefix stripped, a login-page
/// redirect surfaced as `sessionExpired`, pagination guarded to the same
/// HTTPS host — or, when the caller has one, a `CanvasAccessToken` bearer
/// token via `accessToken` (`CanvasAuth.apply` picks whichever is present),
/// good for up to Canvas's 120-day student ceiling instead of the roughly
/// one-day session cookies last; cookies remain the fallback otherwise.
/// Deliberately self-contained rather than sharing code with
/// `CanvasGradesClient` — the same stance that file documents.
public struct CanvasCourseContentClient: Sendable {
    public enum Error: Swift.Error, Sendable, LocalizedError, Equatable {
        /// 401, or Canvas silently redirected to its HTML login page. A 403 is
        /// deliberately NOT this: Canvas answers 403 for "this account may not
        /// see this course's material" (a concluded or restricted course) and
        /// for rate limiting, neither of which means the session is dead.
        /// Reading it as `sessionExpired` let one forbidden course abort the
        /// whole materials sync. It surfaces as `http(403)`, a per-course
        /// error.
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
    private let accessToken: String?

    public init(
        baseURL: URL = URL(string: "https://canvas.upenn.edu")!,
        cookies: [HTTPCookie],
        session: URLSession = .shared,
        accessToken: String? = nil
    ) {
        self.baseURL = baseURL
        self.cookies = cookies
        self.session = session
        self.accessToken = accessToken
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

    /// How many page bodies one course may have read per sync, the front page
    /// included. It was 40 (the 40 most recently edited pages), which left
    /// most of a real course's pages unread. The server puts no cap on
    /// documents per course (`backend/supabase/functions/sync/index.ts` caps
    /// only one upload call at 200 documents, which the client already
    /// batches around), so this is a bound on Canvas requests, not on what
    /// the server accepts.
    public static let defaultMaxPageBodies = 120

    /// GET /api/v1/courses/:id/pages (listing), then the bodies of the pages
    /// worth reading, up to `maxBodies` — the listing endpoint never includes
    /// bodies. Capped because a course with five hundred pages is a course
    /// packet, not a syllabus.
    ///
    /// Which bodies, in order:
    /// 1. the course front page (`GET .../front_page`; a 404 means the course
    ///    has none, which is not an error). It leads because it is where an
    ///    instructor puts office hours and policies. It is returned apart
    ///    from `pages` so it can become a `.home` document, and it is not
    ///    also returned as a page.
    /// 2. every page in `priorityPageURLs` (the pages the course's modules
    ///    link to), in the order given. A module-linked page is the one the
    ///    instructor told students to read, and recency ordering alone left
    ///    it unread whenever it was not among the newest.
    /// 3. the rest of the listing, most recently updated first.
    ///
    /// `storedUpdatedAt` maps a page slug to the `updatedAt` of the document
    /// the caller already holds for it. A selected page whose listing
    /// `updated_at` matches is not fetched again (`unchangedPageURLs`): the
    /// caller reuses its stored document. Reused pages still count against
    /// `maxBodies`, so the set of pages a course holds does not creep upward
    /// across syncs.
    ///
    /// A body that fails for any reason other than "not found" is recorded in
    /// `failures`, not skipped silently: the caller must not treat a course
    /// with a missing page as fully read, or the merge would drop that page
    /// and the upload would tell the server it is gone. Not found is a page
    /// deleted between the listing and the fetch, which really is gone.
    public func pages(
        courseID: String,
        maxBodies: Int = CanvasCourseContentClient.defaultMaxPageBodies,
        priorityPageURLs: [String] = [],
        storedUpdatedAt: [String: Date] = [:]
    ) async throws -> CourseContentPageSet {
        let listURL = api("courses/\(courseID)/pages", query: [
            ("per_page", "100"),
            ("sort", "updated_at"),
            ("order", "desc"),
        ])
        let listing: [CourseContentPage] = try await getAllPages(listURL)
        var failures: [String] = []

        var frontPage: CourseContentPage?
        do {
            let candidate: CourseContentPage = try await getOne(api("courses/\(courseID)/front_page"))
            if candidate.published != false { frontPage = candidate }
        } catch Error.http(404) {
            // No front page is set for this course.
        } catch {
            failures.append("front page: \(error.localizedDescription)")
        }

        // Unpublished pages are never read, whichever list names them. The
        // front page is seeded as "seen" so it is read once, as the home
        // document, and not again as a page.
        var seen = Set(listing.filter { $0.published == false }.map(\.url))
        if let frontPage { seen.insert(frontPage.url) }
        var ordered: [String] = []
        for slug in priorityPageURLs + listing.map(\.url) {
            if seen.insert(slug).inserted { ordered.append(slug) }
        }

        let budget = max(maxBodies - (frontPage == nil ? 0 : 1), 0)
        let listed = Dictionary(listing.map { ($0.url, $0) }, uniquingKeysWith: { first, _ in first })
        var pages: [CourseContentPage] = []
        var unchanged: [String] = []
        for slug in ordered.prefix(budget) {
            if let stored = storedUpdatedAt[slug], let current = listed[slug]?.updatedAt,
               abs(stored.timeIntervalSince(current)) < 1 {
                unchanged.append(slug)
                continue
            }
            let encoded = slug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? slug
            do {
                pages.append(try await getOne(api("courses/\(courseID)/pages/\(encoded)")))
            } catch Error.http(404) {
                continue
            } catch Error.sessionExpired {
                // Every further body would fail the same way; stop asking.
                failures.append("page \(slug): \(Error.sessionExpired.localizedDescription)")
                break
            } catch {
                failures.append("page \(slug): \(error.localizedDescription)")
            }
        }
        return CourseContentPageSet(frontPage: frontPage, pages: pages, unchangedPageURLs: unchanged, failures: failures)
    }

    /// GET /api/v1/courses/:id/tabs — the course navigation menu, every
    /// page. `include[]=external` asks Canvas to also report LTI tools that
    /// would otherwise come back with no `html_url` at all. This is the only
    /// endpoint that lists a tool placed in course navigation but never
    /// linked from inside a module — see `CanvasCourseTab`'s doc comment for
    /// why `CourseKnowledgeCollector`'s existing module scan misses it.
    public func tabs(courseID: String) async throws -> [CanvasCourseTab] {
        let url = api("courses/\(courseID)/tabs", query: [
            ("include[]", "external"),
            ("per_page", "100"),
        ])
        return try await getAllPages(url)
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
        CanvasAuth.apply(to: &request, cookies: cookies, accessToken: accessToken)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Error.notHTTP }
        // Only 401 means the session is dead. 403 falls through to `http(403)`
        // below; see `Error.sessionExpired`.
        if http.statusCode == 401 { throw Error.sessionExpired }
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

/// What `CanvasCourseContentClient.pages` found for one course.
public struct CourseContentPageSet: Sendable {
    /// The course front page with its body, when the course has a published
    /// one. Not repeated in `pages`.
    public let frontPage: CourseContentPage?
    /// Pages whose body was fetched this run.
    public let pages: [CourseContentPage]
    /// Slugs of pages that were selected but not fetched because the
    /// caller's stored copy is still current; the caller keeps that
    /// document.
    public let unchangedPageURLs: [String]
    /// One line per body that could not be read for a reason other than "not
    /// found". Non-empty means the course was not read in full.
    public let failures: [String]

    public init(frontPage: CourseContentPage?, pages: [CourseContentPage], unchangedPageURLs: [String], failures: [String]) {
        self.frontPage = frontPage
        self.pages = pages
        self.unchangedPageURLs = unchangedPageURLs
        self.failures = failures
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

    /// The course front page as a `.home` document. The backend accepts the
    /// kind (`backend/supabase/functions/_shared/manifest.ts`'s
    /// `DOCUMENT_KINDS`) and `extract-profile` reads it ahead of ordinary
    /// pages. The slug is the `sourceID`, so a course that moves its front
    /// page to another page replaces this document rather than editing it.
    public static func home(from page: CourseContentPage, course: CourseSummary, now: Date = Date()) -> CourseDocument {
        CourseDocument(
            courseID: course.courseID,
            course: course.code,
            kind: .home,
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

    // MARK: - Outbound links (course-website discovery)

    /// Every `<a href>` in a wiki page's body, tagged `origin: .page`. The
    /// server decides which (if any) point at an external course website;
    /// this only surfaces what Canvas's own content already links to.
    public static func links(from page: CourseContentPage, course: CourseSummary) -> [CourseLink] {
        HTMLText.links(in: page.body ?? "").map {
            CourseLink(courseID: course.courseID, href: $0.href, text: $0.text, origin: .page)
        }
    }

    /// Every `<a href>` in an assignment's description, tagged
    /// `origin: .assignment`.
    public static func links(from assignment: CourseContentAssignment, course: CourseSummary) -> [CourseLink] {
        HTMLText.links(in: assignment.description ?? "").map {
            CourseLink(courseID: course.courseID, href: $0.href, text: $0.text, origin: .assignment)
        }
    }

    /// One `CourseLink` per module item that carries an `externalURL`
    /// (`typeRaw == "ExternalUrl"`), tagged `origin: .module`. Unlike the
    /// page/assignment variants this doesn't run `HTMLText.links(in:)` —
    /// Canvas already hands back a structured URL for these, not HTML to
    /// scrape — so the item's own `title` is the link text.
    public static func links(from items: [CanvasModulesClient.ModuleItem], course: CourseSummary) -> [CourseLink] {
        items.compactMap { item in
            guard let externalURL = item.externalURL else { return nil }
            return CourseLink(courseID: course.courseID, href: externalURL.absoluteString, text: item.title, origin: .module)
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
