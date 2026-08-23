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
        /// Stringified `content_id` — the id of the underlying Page/Assignment/
        /// Quiz/Discussion this module item points at, as opposed to `id` (the
        /// module-item wrapper's own id). Nil when Canvas omits it. This is the
        /// join key against the Planner API's `plannable.id` (see
        /// `PlannerDatedItem` / `overlayDates` below) — module items themselves
        /// carry no student-to-do date, only their underlying content does.
        public let contentID: String?
        /// The parent module's `name`, nil when absent. Captured because it's
        /// free on this same payload and is a likely future fallback for dating
        /// items the planner overlay still can't place (not used for that yet).
        public let moduleName: String?

        public init(
            id: String,
            title: String,
            dueAt: Date?,
            typeRaw: String,
            contentID: String? = nil,
            moduleName: String? = nil
        ) {
            self.id = id
            self.title = title
            self.dueAt = dueAt
            self.typeRaw = typeRaw
            self.contentID = contentID
            self.moduleName = moduleName
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

    /// GET /api/v1/planner/items?start_date=...&end_date=...&per_page=100,
    /// following `Link: rel="next"` until exhausted, then decoding every page
    /// and keeping only entries for `courseID`. This is the source for the
    /// "student to-do" dates Canvas's own dashboard shows on Pages/Files —
    /// content types that have no `due_at` of their own (see `overlayDates`
    /// below for why `fetchModuleItems` alone can't surface those dates).
    public func fetchPlannerDates(courseID: String, start: Date, end: Date) async throws -> [PlannerDatedItem] {
        let pages = try await fetchAllPlannerPages(start: start, end: end)
        return Self.plannerDatedItems(fromPages: pages, courseID: courseID)
    }

    /// GET .../planner/items?start_date=...&end_date=...&per_page=100,
    /// following the `Link: rel="next"` header until exhausted — mirrors
    /// `fetchAllModulePages` / `CanvasGradesClient.fetchAllAssignmentGroupPages`.
    private func fetchAllPlannerPages(start: Date, end: Date) async throws -> [Data] {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("api/v1/planner/items"),
            resolvingAgainstBaseURL: false
        ) else { throw Error.invalidURL }
        components.queryItems = [
            URLQueryItem(name: "start_date", value: Self.iso8601(start)),
            URLQueryItem(name: "end_date", value: Self.iso8601(end)),
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
            // Security: see the matching comment in `fetchAllModulePages` —
            // a `Link: rel="next"` header is server-controlled input, and
            // `fetchRaw` unconditionally attaches the stored Canvas session
            // cookies to whatever URL it's given.
            guard CanvasGradesClient.isTrustedNextPageURL(candidate, baseURL: baseURL) else {
                nextURL = nil
                continue
            }
            nextURL = candidate
        }
        return pages
    }

    /// UTC ISO8601 (no fractional seconds) — Canvas's `start_date`/`end_date`
    /// query params want this shape; built locally per call for the same
    /// not-Sendable-as-static-state reason as `parseDate` below.
    private static func iso8601(_ date: Date) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(identifier: "UTC")
        return formatter.string(from: date)
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
            // Canvas returns `content_details` — the ONLY carrier of an
            // item's due_at — solely when explicitly requested. Without this
            // second include, every imported reading arrived undated and
            // sank to the bottom of the list (observed on device: all 55 of
            // a real course's readings, dateless).
            URLQueryItem(name: "include[]", value: "content_details"),
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
                        typeRaw: item.type,
                        contentID: item.contentID.map(String.init),
                        moduleName: module.name
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

    /// Decodes raw (possibly XSSI-prefixed) planner-items JSON into flat
    /// `PlannerDatedItem`s, with no network I/O — same seam convention as
    /// `moduleItems(fromPages:)`. Keeps only entries belonging to `courseID`
    /// (stringified `course_id` comparison — planner items span every course
    /// plus personal-note items with no course at all, and this client only
    /// ever wants one course's worth) and only entries whose `plannable_date`
    /// actually parses. Never throws: a malformed entry or page just
    /// contributes nothing, since a missing planner date degrades a reading
    /// back to undated rather than failing the whole import.
    public static func plannerDatedItems(fromPages pages: [Data], courseID: String) -> [PlannerDatedItem] {
        let decoder = JSONDecoder()
        var items: [PlannerDatedItem] = []
        for page in pages {
            let stripped = CanvasGradesClient.stripXSSIPrefix(page)
            guard let entries = try? decoder.decode([PlannerItemDTO].self, from: stripped) else { continue }
            for entry in entries {
                guard let entryCourseID = entry.courseID, String(entryCourseID) == courseID else { continue }
                guard let date = parseDate(entry.plannableDate) else { continue }
                guard let plannableID = entry.plannable?.id else { continue }
                items.append(PlannerDatedItem(
                    plannableType: entry.plannableType,
                    plannableID: String(plannableID),
                    plannedAt: date
                ))
            }
        }
        return items
    }

    /// Canvas module-item `type` → planner `plannable_type`. Only the content
    /// kinds that can actually appear as dateless module items (per field
    /// evidence: Pages) plus the other kinds the planner API names, so a join
    /// is possible for those too if Canvas ever omits their own due_at.
    /// Anything else (File, ExternalUrl, SubHeader, ...) has no planner
    /// analogue and simply misses the lookup below.
    private static func plannableType(forModuleItemType typeRaw: String) -> String? {
        switch typeRaw {
        case "Page": return "wiki_page"
        case "Assignment": return "assignment"
        case "Quiz": return "quiz"
        case "Discussion": return "discussion_topic"
        default: return nil
        }
    }

    /// Overlays planner-derived dates onto module items that have no
    /// `due_at` of their own — the fix for the field evidence that a real
    /// course's 55 module readings (Pages, which structurally can't carry
    /// due_at) all imported dateless even though Canvas's own dashboard shows
    /// them with times, because those times come from the planner API's
    /// per-student "to-do" dates, not from the modules API at all. Join key
    /// is (normalized plannable type, underlying content id) — an item with
    /// no `contentID`, or whose type has no planner analogue, or that finds
    /// no match, is returned unchanged (still undated, which is correct: it
    /// lands in the dashboard's later "undated" bucket same as before).
    public static func overlayDates(_ items: [ModuleItem], planner: [PlannerDatedItem]) -> [ModuleItem] {
        var lookup: [String: Date] = [:]
        for entry in planner {
            lookup["\(entry.plannableType):\(entry.plannableID)"] = entry.plannedAt
        }
        return items.map { item in
            guard item.dueAt == nil, let contentID = item.contentID else { return item }
            guard let mappedType = plannableType(forModuleItemType: item.typeRaw) else { return item }
            guard let planned = lookup["\(mappedType):\(contentID)"] else { return item }
            return ModuleItem(
                id: item.id,
                title: item.title,
                dueAt: planned,
                typeRaw: item.typeRaw,
                contentID: item.contentID,
                moduleName: item.moduleName
            )
        }
    }
}

/// One planner-API entry, reduced to what the overlay needs: the kind of
/// content it's about, the underlying content's id (`plannable.id` — the
/// same id a module item's `content_id` points at), and the unified date
/// Canvas's own dashboard displays for it (`plannable_date`).
public struct PlannerDatedItem: Sendable, Hashable {
    public let plannableType: String
    public let plannableID: String
    public let plannedAt: Date

    public init(plannableType: String, plannableID: String, plannedAt: Date) {
        self.plannableType = plannableType
        self.plannableID = plannableID
        self.plannedAt = plannedAt
    }
}

// MARK: - Wire DTOs (private — decode Canvas JSON)

private struct ModuleDTO: Decodable {
    let name: String?
    let items: [ModuleItemDTO]?
}

private struct ModuleItemDTO: Decodable {
    let id: Int
    let title: String
    let type: String
    let contentID: Int?
    let contentDetails: ContentDetailsDTO?

    enum CodingKeys: String, CodingKey {
        case id, title, type
        case contentID = "content_id"
        case contentDetails = "content_details"
    }

    struct ContentDetailsDTO: Decodable {
        let dueAt: String?
        enum CodingKeys: String, CodingKey {
            case dueAt = "due_at"
        }
    }
}

/// One `/api/v1/planner/items` entry. `courseID` is absent for course-less
/// plannables (e.g. `planner_note`), which is why it's optional rather than
/// defaulted to some sentinel — those entries simply never match any
/// course's filter in `plannerDatedItems(fromPages:courseID:)`.
private struct PlannerItemDTO: Decodable {
    let courseID: Int?
    let plannableType: String
    let plannableDate: String?
    let plannable: PlannableDTO?

    enum CodingKeys: String, CodingKey {
        case courseID = "course_id"
        case plannableType = "plannable_type"
        case plannableDate = "plannable_date"
        case plannable
    }

    struct PlannableDTO: Decodable {
        let id: Int?
    }
}
