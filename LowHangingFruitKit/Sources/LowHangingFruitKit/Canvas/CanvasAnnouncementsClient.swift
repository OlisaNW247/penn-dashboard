import Foundation

/// Fetches Canvas course announcements, cookie-authenticated the same way
/// `CanvasGradesClient` and `CanvasDiscoveryClient` are (self-scoped REST API,
/// `SessionCookieStore` cookies — no OAuth available). Decodes into
/// `CanvasAnnouncement`, with HTML `message` bodies already flattened to plain
/// text so callers (list rows, notification bodies) never touch HTML.
///
/// This deliberately mirrors `CanvasGradesClient`'s shape — the error enum,
/// XSSI stripping, session-expiry detection, and same-host-https pagination
/// guard are byte-for-byte the same idea — rather than sharing code with it.
/// The two clients hit different endpoints with unrelated response shapes and
/// are called from different sites; folding them into one "Canvas HTTP core"
/// is a reasonable refactor for another day, but doing it here, unrequested,
/// would mean editing a file this change was scoped to leave alone. Keeping
/// this client self-contained also means it can be read and tested without
/// pulling `CanvasGradesClient`'s grade-shape concerns into the same head-space.
public final class CanvasAnnouncementsClient {
    public enum Error: Swift.Error, Sendable, LocalizedError, Equatable {
        /// 401, or Canvas silently redirected to its HTML login page instead
        /// of erroring — both mean the session cookie lapsed. Kept distinct
        /// and detectable so callers treat it as a normal degraded state
        /// (show the last-known announcements, marked stale) rather than a
        /// hard failure.
        case sessionExpired
        case http(status: Int, url: URL)
        case notHTTP
        case invalidURL
        case decodingFailed(String)

        public var errorDescription: String? {
            switch self {
            case .sessionExpired:
                return "Your Canvas session expired. Log in to Canvas again to refresh announcements."
            case let .http(status, url):
                return "Canvas returned HTTP \(status) for \(url.path)."
            case .notHTTP:
                return "Canvas did not return a normal web response."
            case .invalidURL:
                return "Couldn't build a Canvas announcements request URL."
            case let .decodingFailed(detail):
                return "Canvas returned announcements in an unexpected format (\(detail))."
            }
        }
    }

    private let baseURL: URL
    private let cookies: [HTTPCookie]
    private let session: URLSession

    /// Invoked with any cookies Canvas re-issued on a successfully decoded
    /// response page — see the matching comment on
    /// `CanvasGradesClient.refreshedCookieHandler`; the sliding-session
    /// mechanics are identical here. Deliberately a plain `var`, not
    /// synchronized: this class is not declared `Sendable` (see the note at
    /// the bottom of this file), so callers own keeping use of one instance
    /// single-threaded, the same as any other non-Sendable reference type.
    public var refreshedCookieHandler: (@Sendable ([HTTPCookie]) -> Void)?

    public init(
        baseURL: URL = URL(string: "https://canvas.upenn.edu")!,
        cookies: [HTTPCookie],
        session: URLSession = .shared,
        refreshedCookieHandler: (@Sendable ([HTTPCookie]) -> Void)? = nil
    ) {
        self.baseURL = baseURL
        self.cookies = cookies
        self.session = session
        self.refreshedCookieHandler = refreshedCookieHandler
    }

    // MARK: - Networked fetch

    /// Fetches announcements posted on/after `since` for every course in
    /// `courseIDs`, across as many `context_codes[]` as Canvas needs, and
    /// decodes them into `CanvasAnnouncement`.
    public func fetchAnnouncements(courseIDs: [String], since: Date) async throws -> [CanvasAnnouncement] {
        let pages = try await fetchAllAnnouncementPages(courseIDs: courseIDs, since: since)
        let announcements = try pages.flatMap { try Self.decodeAnnouncements(json: $0.data) }

        // Only surface rotated cookies once every page this fetch touched has
        // decoded successfully (the `flatMap` above didn't throw) — a 2xx
        // response that fails to parse must not contribute cookies, since
        // that's the profile of a subtly broken response, not a trustworthy
        // sliding-session renewal. Mirrors `CanvasGradesClient.fetchSnapshot`.
        if let refreshedCookieHandler {
            var refreshed: [HTTPCookie] = []
            for page in pages {
                refreshed += Self.responseCookies(from: page.response, requestURL: page.url)
            }
            if !refreshed.isEmpty {
                refreshedCookieHandler(refreshed)
            }
        }
        return announcements
    }

    /// GET .../api/v1/announcements?context_codes[]=course_...&start_date=...&per_page=100,
    /// following the `Link: rel="next"` header until exhausted. Carries each
    /// page's response + URL alongside its body so `fetchAnnouncements` can
    /// parse rotated cookies off of it after a successful decode, without
    /// this method itself knowing anything about cookie rotation.
    private func fetchAllAnnouncementPages(
        courseIDs: [String],
        since: Date
    ) async throws -> [(data: Data, response: HTTPURLResponse, url: URL)] {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("api/v1/announcements"),
            resolvingAgainstBaseURL: false
        ) else { throw Error.invalidURL }

        // Built locally, not cached as static state, for the same reason
        // `CanvasGradesClient.parseDate` builds its formatters locally:
        // `ISO8601DateFormatter` isn't `Sendable`.
        let startDateFormatter = ISO8601DateFormatter()
        startDateFormatter.formatOptions = [.withInternetDateTime]

        var queryItems = courseIDs.map { URLQueryItem(name: "context_codes[]", value: "course_\($0)") }
        queryItems.append(URLQueryItem(name: "start_date", value: startDateFormatter.string(from: since)))
        queryItems.append(URLQueryItem(name: "per_page", value: "100"))
        components.queryItems = queryItems
        guard let firstURL = components.url else { throw Error.invalidURL }

        var pages: [(data: Data, response: HTTPURLResponse, url: URL)] = []
        var nextURL: URL? = firstURL
        var pagesFetched = 0
        // Safety valve: a well-behaved Canvas instance won't loop, but this
        // keeps a malformed Link header from spinning forever.
        let maxPages = 50

        while let url = nextURL {
            pagesFetched += 1
            guard pagesFetched <= maxPages else { break }
            let (data, http) = try await fetchRaw(url)
            pages.append((data, http, url))

            guard let candidate = Self.nextPageURL(fromLinkHeader: http.value(forHTTPHeaderField: "Link")) else {
                nextURL = nil
                continue
            }
            // Security: see `CanvasGradesClient.fetchAllAssignmentGroupPages`'s
            // matching comment — a `Link: rel="next"` header is server-
            // controlled input, and `fetchRaw` unconditionally attaches the
            // stored Canvas session cookies to whatever URL it's given.
            // Refuse to follow an off-host next-page URL rather than leak the
            // session cookie to a third party; this only ever costs the tail
            // of a very large announcements list.
            guard Self.isTrustedNextPageURL(candidate, baseURL: baseURL) else {
                nextURL = nil
                continue
            }
            nextURL = candidate
        }
        return pages
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

    // MARK: - Pure parsing (no network; used directly by tests and by fetchAnnouncements)

    /// Strips Canvas's `while(1);` XSSI-protection prefix some JSON endpoints
    /// prepend, if present. A no-op otherwise.
    ///
    /// Duplicated from `CanvasGradesClient.stripXSSIPrefix` (which is itself
    /// `public`, so this isn't working around an access-level restriction)
    /// rather than called through it, to keep this file's networked/pure
    /// split self-contained — see the type-level doc comment for why the two
    /// clients aren't sharing an HTTP core yet.
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
    /// suffix trick like `canvas.upenn.edu.evil.com` must NOT pass).
    public static func isTrustedNextPageURL(_ url: URL, baseURL: URL) -> Bool {
        guard url.scheme?.lowercased() == "https" else { return false }
        guard let host = url.host, let baseHost = baseURL.host else { return false }
        return host.caseInsensitiveCompare(baseHost) == .orderedSame
    }

    /// Parses whatever `Set-Cookie` headers `response` carries into
    /// `HTTPCookie`s scoped to `requestURL`, kept separate from the actual
    /// network call so it's directly unit-testable. Empty (never crashes)
    /// when the response has no `Set-Cookie` header.
    static func responseCookies(from response: HTTPURLResponse, requestURL: URL) -> [HTTPCookie] {
        let headers = response.allHeaderFields.reduce(into: [String: String]()) { result, pair in
            guard let key = pair.key as? String, let value = pair.value as? String else { return }
            result[key] = value
        }
        return HTTPCookie.cookies(withResponseHeaderFields: headers, for: requestURL)
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

    /// Decodes one raw (possibly XSSI-prefixed) `/api/v1/announcements` page
    /// into `CanvasAnnouncement`s, with no network I/O — the seam tests use
    /// so fixtures can stand in for real Canvas responses.
    ///
    /// Canvas announcements are discussion topics; an element with no
    /// `context_code` (or one that isn't a `course_<digits>` code) can't be
    /// attributed to a course and is skipped rather than failing the page —
    /// Canvas is known to omit fields freely, and a course-less announcement
    /// here is far more likely to be an account-level or group announcement
    /// this client has no use for than a sign anything is actually broken.
    /// Decoding each element through `LenientAnnouncementElement` below means
    /// one genuinely malformed entry (not the shape of a JSON object at all)
    /// drops silently instead of throwing away the whole page.
    public static func decodeAnnouncements(json: Data) throws -> [CanvasAnnouncement] {
        let stripped = stripXSSIPrefix(json)
        let decoder = JSONDecoder()

        let elements: [LenientAnnouncementElement]
        do {
            elements = try decoder.decode([LenientAnnouncementElement].self, from: stripped)
        } catch {
            throw Error.decodingFailed("announcements: \(error)")
        }

        return elements.compactMap(\.dto).compactMap(map(dto:))
    }

    private static func map(dto: AnnouncementDTO) -> CanvasAnnouncement? {
        guard let id = dto.id else { return nil }
        guard let contextCode = dto.contextCode, let courseID = courseID(fromContextCode: contextCode) else {
            return nil
        }
        return CanvasAnnouncement(
            id: String(id),
            courseID: courseID,
            title: dto.title ?? "",
            message: plainText(fromHTML: dto.message ?? ""),
            postedAt: parseDate(dto.postedAt),
            url: dto.htmlURL.flatMap { URL(string: $0) }
        )
    }

    /// Pulls the digits out of a Canvas `context_code` like `"course_12345"`.
    /// Returns nil for any other shape (`"group_1"`, `"user_1"`, malformed) —
    /// this client only ever wants course-scoped announcements, and a
    /// courseID nothing downstream (selection, dedup, `CoursePreferences`)
    /// can key on is worse than silently dropping the entry.
    static func courseID(fromContextCode contextCode: String) -> String? {
        guard contextCode.hasPrefix("course_") else { return nil }
        let digits = contextCode.dropFirst("course_".count)
        guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
        return String(digits)
    }

    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        // Built locally (not cached as static state) since ISO8601DateFormatter
        // isn't Sendable — mirrors `CanvasGradesClient.parseDate` exactly.
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }

    // MARK: - HTML -> plain text

    /// Deterministic, Foundation-only HTML-to-plain-text for an announcement
    /// `message` body. Deliberately NOT `NSAttributedString`'s
    /// `.documentType: .html` importer: that importer is main-thread/WebKit-
    /// entangled (it can hang or crash off the main thread and isn't
    /// available at all in some non-UI test/CLI contexts), which is a bad fit
    /// for a pure, `async`-callable Kit function with no UI dependency. This
    /// is intentionally not a general HTML parser — Canvas's rich-text editor
    /// only ever emits a small, well-known set of block tags and entities for
    /// a plain announcement body, and that's all this handles.
    public static func plainText(fromHTML html: String) -> String {
        guard !html.isEmpty else { return "" }

        var text = html

        // Block-level boundaries become newlines before the generic tag-strip
        // below erases the tags outright — otherwise "<p>A</p><p>B</p>" would
        // collapse straight to "AB" with no separator at all.
        text = Self.newlineTagRegex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: "\n"
        )

        // Whatever tags remain (opening tags, `<a href=...>`, `<strong>`,
        // etc.) carry no useful text content once stripped.
        text = Self.tagStripRegex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: ""
        )

        // Common entities only — not a general HTML entity decoder. `&amp;`
        // is decoded LAST so a message that literally typed out "&lt;" (which
        // Canvas would have escaped to "&amp;lt;") round-trips back to the
        // author's literal "&lt;" instead of over-decoding to "<".
        let entities: [(String, String)] = [
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&quot;", "\""),
            ("&#39;", "'"),
            ("&nbsp;", " "),
            ("&amp;", "&"),
        ]
        for (entity, replacement) in entities {
            text = text.replacingOccurrences(of: entity, with: replacement)
        }

        // Collapse runs of 3+ newlines (stacked block tags, e.g. an empty
        // "<p></p>" between paragraphs) down to a single blank line.
        text = Self.collapseNewlinesRegex.stringByReplacingMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text),
            withTemplate: "\n\n"
        )

        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // These three patterns are fixed string literals known to compile, so
    // `try!` here can't fail at runtime; kept as `static let` (unlike the
    // date formatters above) because `NSRegularExpression` — unlike
    // `ISO8601DateFormatter` — is documented as thread-safe/immutable once
    // built, so there's no Sendable hazard in reusing one instance.
    private static let newlineTagRegex = try! NSRegularExpression(
        pattern: "<br\\s*/?>|</p\\s*>|</div\\s*>|</li\\s*>",
        options: [.caseInsensitive]
    )
    private static let tagStripRegex = try! NSRegularExpression(pattern: "<[^>]+>", options: [])
    private static let collapseNewlinesRegex = try! NSRegularExpression(pattern: "\\n{3,}", options: [])
}

// MARK: - Output model

/// One Canvas announcement, decoded and ready for the dashboard — `message`
/// is already plain text (see `CanvasAnnouncementsClient.plainText`), never
/// the raw HTML Canvas sent.
public struct CanvasAnnouncement: Sendable, Equatable {
    public let id: String
    public let courseID: String
    public let title: String
    public let message: String
    public let postedAt: Date?
    public let url: URL?

    public init(
        id: String,
        courseID: String,
        title: String,
        message: String,
        postedAt: Date?,
        url: URL?
    ) {
        self.id = id
        self.courseID = courseID
        self.title = title
        self.message = message
        self.postedAt = postedAt
        self.url = url
    }
}

// MARK: - Wire DTOs (private — decode Canvas JSON, tolerant of garbage/missing fields)

/// Every field optional on purpose: Canvas is known to omit fields freely
/// (see the type-level doc comment on `decodeAnnouncements`), and the only
/// thing this DTO needs to reject outright is an array element that isn't a
/// JSON object at all — which `LenientAnnouncementElement` below catches per
/// element instead of failing the whole page.
private struct AnnouncementDTO: Decodable {
    let id: Int?
    let contextCode: String?
    let title: String?
    let message: String?
    let postedAt: String?
    let htmlURL: String?

    enum CodingKeys: String, CodingKey {
        case id
        case contextCode = "context_code"
        case title
        case message
        case postedAt = "posted_at"
        case htmlURL = "html_url"
    }
}

/// Decodes one array element as `AnnouncementDTO`, swallowing the error and
/// producing `nil` instead of propagating it. Plain `[AnnouncementDTO]`
/// decoding stops at the first element that doesn't decode (e.g. a stray
/// non-object entry in the array) and fails the whole page; wrapping each
/// element in this type means one bad entry drops out silently instead of
/// sinking every announcement Canvas sent alongside it.
private struct LenientAnnouncementElement: Decodable {
    let dto: AnnouncementDTO?

    init(from decoder: Decoder) throws {
        dto = try? AnnouncementDTO(from: decoder)
    }
}
