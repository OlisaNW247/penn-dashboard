import Foundation

/// How a request to Ed proves who the student is.
///
/// Which of the two Ed actually wants is not known until the discovery probe
/// (`EdDiscussionProbe`) has been read off a real login, so both are modelled
/// and `EdClient` does not care which it is handed.
public enum EdAuth: Sendable {
    /// The session Ed set in the app's own WebView after the Canvas LTI
    /// launch. Held by the app (never the process-wide cookie jar) and sent
    /// as a plain `Cookie` header.
    case cookies([HTTPCookie])
    /// Ed's `x-token` header, for the day the probe shows the session is a
    /// stored token rather than a cookie.
    case token(String)
}

/// A read-only client for the two Ed Discussion endpoints phase 1 needs.
///
/// Modelled on `CanvasCourseContentClient`'s `fetch`/`decode`: same
/// `httpShouldHandleCookies = false` (the cookies are the app's, not the
/// process jar's, so a stale jar entry can never speak for the student and
/// ours never leak into another request), same "an HTML page on a 2xx means
/// the login page" rule.
public struct EdClient: Sendable {
    public enum Error: Swift.Error, Equatable {
        /// 401/403, or Ed's HTML login page where JSON should be.
        case sessionExpired
        case http(Int)
        case notHTTP
        case invalidJSON(String)
    }

    /// Ed's page-size cap on `/threads`.
    static let maxLimit = 100

    private let apiBase: URL
    private let auth: EdAuth
    private let session: URLSession

    public init(
        apiBase: URL = URL(string: "https://us.edstem.org/api")!,
        auth: EdAuth,
        session: URLSession = .shared
    ) {
        self.apiBase = apiBase
        self.auth = auth
        self.session = session
    }

    /// GET /user: the student's Ed enrolments.
    ///
    /// This one call is the whole "am I signed in" test. It needs no course
    /// id, it is cheap, and it answers with JSON when the session is good and
    /// with 401 (or the HTML login page) when it is not, so the app asks it
    /// first and only then walks the courses it lists.
    public func user() async throws -> EdUserResponse {
        let data = try await fetch(url(path: "user", query: []))
        return try decode(EdUserResponse.self, from: data)
    }

    /// GET /courses/<id>/threads: one page of a course's threads, newest
    /// first by default.
    ///
    /// This is one page and nothing more; the sync reads through
    /// `threadsWithinWindow`, which pages. (Until 2026-10-23 the sync read
    /// only this one page, on the theory that the newest 100 threads cover a
    /// semester of staff posts. They do not on a busy board: a pinned
    /// announcement older than the 100th newest thread was never read, and
    /// because each read replaces a class's whole Ed set, it then vanished
    /// from the phone.) `limit` is clamped to Ed's own cap of 100, since
    /// asking for more is a 400 and a lost sync.
    public func threads(courseID: Int, limit: Int = 100, offset: Int = 0, sort: String = "new") async throws -> EdThreadsResponse {
        let clamped = min(max(limit, 1), Self.maxLimit)
        let url = url(path: "courses/\(courseID)/threads", query: [
            ("limit", String(clamped)),
            ("offset", String(max(offset, 0))),
            ("sort", sort),
        ])
        let data = try await fetch(url)
        return try decode(EdThreadsResponse.self, from: data)
    }

    /// How many pages of `maxLimit` threads `threadsWithinWindow` reads at
    /// most: 300 threads, three requests per class per run.
    ///
    /// Why 3. What the sync wants is announcements, pinned threads and staff
    /// posts, and on a board with more than 300 threads in 120 days (a
    /// question board, where students post all day) those are a small
    /// fraction of what is there, so paging further would download hundreds
    /// of student threads only to throw them away, for a handful of extra
    /// kept posts. The cap also bounds a run: a student with six Ed classes
    /// costs at most 18 thread requests, and it is the same number whether
    /// the board is busy or the window never closes (a clock far in the
    /// past, a board of old threads that Ed keeps sorting first).
    public static let maxWindowPages = 3

    /// GET /courses/<id>/threads, paged newest first until the ingestion
    /// window closes: the union of the pages read, in the order Ed returned
    /// them.
    ///
    /// **Stops, checked after each page, in this order:**
    /// 1. the page is short (fewer than `maxLimit` threads, an empty page
    ///    included): the board has no more;
    /// 2. the page's oldest thread, by last activity (`updatedAt`, else
    ///    `createdAt`, the same value `EdIngestion.documents` ages by), is
    ///    older than `now - maxAge`: everything on later pages is older
    ///    still, so none of it can become a document;
    /// 3. `pageLimit` pages have been read (default `maxWindowPages`).
    ///
    /// Offsets go 0, 100, 200. That `sort=new` runs in the same order as
    /// last activity is assumed, not verified: if Ed sorts by creation, a
    /// long-ago thread revived by a reply could sit on a page this rule
    /// stops before. That costs the same missed post the one-page read
    /// always had, no more.
    ///
    /// **An error on any page throws, and the pages already read are
    /// discarded.** The caller replaces a class's whole Ed set with what
    /// this returns, so handing back a partial union would erase the posts
    /// on the pages not reached; a throw makes the coordinator keep the
    /// stored set instead. A thread that moves between pages while paging
    /// (a reply bumps it up the list between two requests) can come back
    /// twice, so a repeated thread id keeps its first copy; the side-loaded
    /// `users` are merged the same way, by user id.
    public func threadsWithinWindow(
        courseID: Int,
        maxAge: TimeInterval = EdIngestion.defaultMaxAge,
        now: Date = Date(),
        pageLimit: Int = EdClient.maxWindowPages
    ) async throws -> EdThreadsResponse {
        let cutoff = now.addingTimeInterval(-maxAge)
        let pages = max(pageLimit, 1)
        var collected: [EdThread] = []
        var users: [EdThreadUser] = []
        var seenThreads = Set<Int>()
        var seenUsers = Set<Int>()
        for page in 0..<pages {
            let response = try await self.threads(
                courseID: courseID, limit: Self.maxLimit, offset: page * Self.maxLimit, sort: "new"
            )
            for thread in response.threads where seenThreads.insert(thread.id).inserted {
                collected.append(thread)
            }
            for user in response.users where seenUsers.insert(user.id).inserted {
                users.append(user)
            }
            if response.threads.count < Self.maxLimit { break }
            let oldest = response.threads.map { $0.updatedAt ?? $0.createdAt }.min()
            if let oldest, oldest < cutoff { break }
        }
        return EdThreadsResponse(threads: collected, users: users)
    }

    /// Adds the headers that carry the student's identity. Pure and
    /// nonisolated so a test can pin exactly what leaves the phone without a
    /// network.
    public static func apply(_ auth: EdAuth, to request: inout URLRequest) {
        request.httpShouldHandleCookies = false
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        switch auth {
        case .cookies(let cookies):
            for (name, value) in HTTPCookie.requestHeaderFields(with: cookies) {
                request.setValue(value, forHTTPHeaderField: name)
            }
        case .token(let token):
            request.setValue(token, forHTTPHeaderField: "x-token")
        }
    }

    // MARK: - HTTP

    private func url(path: String, query: [(String, String)]) -> URL {
        var components = URLComponents(url: apiBase.appendingPathComponent(path), resolvingAgainstBaseURL: false)!
        if !query.isEmpty {
            components.queryItems = query.map { URLQueryItem(name: $0.0, value: $0.1) }
        }
        return components.url!
    }

    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        Self.apply(auth, to: &request)
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Error.notHTTP }
        if http.statusCode == 401 || http.statusCode == 403 { throw Error.sessionExpired }
        guard (200..<300).contains(http.statusCode) else { throw Error.http(http.statusCode) }
        if let type = http.value(forHTTPHeaderField: "Content-Type"), type.localizedCaseInsensitiveContains("text/html") {
            throw Error.sessionExpired
        }
        return data
    }

    private func decode<T: Decodable>(_ type: T.Type, from data: Data) throws -> T {
        do {
            return try EdJSON.decoder().decode(T.self, from: data)
        } catch {
            throw Error.invalidJSON(String(describing: error))
        }
    }
}
