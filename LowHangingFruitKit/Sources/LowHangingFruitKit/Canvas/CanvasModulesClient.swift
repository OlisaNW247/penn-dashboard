import Foundation

/// Fetches a course's Modules-page items via Canvas's JSON API, cookie-
/// authenticated the same way `CanvasGradesClient` is (self-scoped REST API,
/// `SessionCookieStore` cookies — no OAuth available). This exists because the
/// HTML scrape (`CanvasModulesParser`) returned 0 items against real Penn
/// markup; the JSON API is the robust source for a course's readings (see
/// docs/READINGS_COURSES_PLAN.md). The HTML parser stays in place as a
/// fallback — this client doesn't replace it, just adds a path that works.
public struct CanvasModulesClient: Sendable {
    public enum Error: Swift.Error, Sendable, LocalizedError, Equatable {
        /// 401, or Canvas silently redirected to its HTML login page instead
        /// of erroring — both mean the session cookie lapsed.
        case sessionExpired
        case http(status: Int, url: URL)
        case notHTTP
        case invalidURL

        public var errorDescription: String? {
            switch self {
            case .sessionExpired:
                return "Your Canvas session expired. Log in to Canvas again to refresh modules."
            case let .http(status, url):
                return "Canvas returned HTTP \(status) for \(url.path)."
            case .notHTTP:
                return "Canvas did not return a normal web response."
            case .invalidURL:
                return "Couldn't build a Canvas modules request URL."
            }
        }
    }

    /// One item on a course's Modules page — a reading, assignment link,
    /// page, file, quiz, etc. `typeRaw` is Canvas's own `type` string
    /// ("Assignment", "Page", "File", "ExternalUrl", "Quiz", "Discussion", …)
    /// passed through uninterpreted; callers that care about a specific kind
    /// switch on it themselves rather than this client narrowing it early.
    public struct ModuleItem: Sendable, Hashable {
        public let id: String
        public let title: String
        public let dueAt: Date?
        public let typeRaw: String

        public init(id: String, title: String, dueAt: Date?, typeRaw: String) {
            self.id = id
            self.title = title
            self.dueAt = dueAt
            self.typeRaw = typeRaw
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

    /// GET .../courses/:id/modules?include[]=items&per_page=100, following the
    /// `Link: rel="next"` header until exhausted, then decoding every page.
    public func fetchModuleItems(courseID: String) async throws -> [ModuleItem] {
        let pages = try await fetchAllModulePages(courseID: courseID)
        return Self.moduleItems(fromPages: pages)
    }

    /// GET .../courses/:id/modules?include[]=items&per_page=100, following the
    /// `Link: rel="next"` header until exhausted (large courses) — mirrors
    /// `CanvasGradesClient.fetchAllAssignmentGroupPages` exactly.
    private func fetchAllModulePages(courseID: String) async throws -> [Data] {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("api/v1/courses/\(courseID)/modules"),
            resolvingAgainstBaseURL: false
        ) else { throw Error.invalidURL }
        components.queryItems = [
            URLQueryItem(name: "include[]", value: "items"),
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

            guard let candidate = CanvasGradesClient.nextPageURL(fromLinkHeader: http.value(forHTTPHeaderField: "Link")) else {
                nextURL = nil
                continue
            }
            // Security: a `Link: rel="next"` header is server-controlled input.
            // `fetchRaw` unconditionally attaches the stored Canvas session
            // cookies to whatever URL it's given, so a next-page URL pointing
            // off-host would leak the session cookie to a third party. Refuse
            // to follow it — stop pagination rather than fetch a truncated-but-
            // safe result silently.
            guard CanvasGradesClient.isTrustedNextPageURL(candidate, baseURL: baseURL) else {
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

        let stripped = CanvasGradesClient.stripXSSIPrefix(data)
        if CanvasGradesClient.looksLikeHTML(stripped) {
            // Canvas returned 200 but the body is HTML — a silent
            // redirect-to-login rather than the JSON we asked for.
            throw Error.sessionExpired
        }
        return (stripped, http)
    }

    // MARK: - Pure parsing (no network; used directly by tests and by fetchModuleItems)

    /// Decodes raw (possibly XSSI-prefixed) modules-page JSON into flat
    /// `ModuleItem`s, with no network I/O — the seam tests use so fixtures can
    /// stand in for real Canvas responses. Never throws: a malformed page
    /// contributes no items rather than failing every other page in the
    /// batch, since one bad page here is cosmetic (a missing reading, not a
    /// wrong grade) unlike `CanvasGradesClient.decodeSnapshot`.
    public static func moduleItems(fromPages pages: [Data]) -> [ModuleItem] {
        let decoder = JSONDecoder()
        var items: [ModuleItem] = []
        for page in pages {
            let stripped = CanvasGradesClient.stripXSSIPrefix(page)
            guard let modules = try? decoder.decode([ModuleDTO].self, from: stripped) else { continue }
            for module in modules {
                for item in module.items ?? [] where item.type != "SubHeader" {
                    items.append(ModuleItem(
                        id: String(item.id),
                        title: item.title,
                        dueAt: parseDate(item.contentDetails?.dueAt),
                        typeRaw: item.type
                    ))
                }
            }
        }
        return items
    }

    private static func parseDate(_ raw: String?) -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        // Built locally (not cached as static state) since ISO8601DateFormatter
        // isn't Sendable and this type needs to stay Sendable itself — matches
        // `CanvasGradesClient.parseDate`'s convention.
        let fractional = ISO8601DateFormatter()
        fractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = fractional.date(from: raw) { return date }

        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: raw)
    }
}

// MARK: - Wire DTOs (private — decode Canvas JSON)

private struct ModuleDTO: Decodable {
    let items: [ModuleItemDTO]?
}

private struct ModuleItemDTO: Decodable {
    let id: Int
    let title: String
    let type: String
    let contentDetails: ContentDetailsDTO?

    enum CodingKeys: String, CodingKey {
        case id, title, type
        case contentDetails = "content_details"
    }

    struct ContentDetailsDTO: Decodable {
        let dueAt: String?
        enum CodingKeys: String, CodingKey {
            case dueAt = "due_at"
        }
    }
}
