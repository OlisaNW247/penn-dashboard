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
    /// Phase 1 reads exactly one page of `sort=new` and never paginates. What
    /// it wants is staff posts, announcements and pinned threads
    /// (`EdThreadFilter`), and the newest 100 threads of a course cover a
    /// semester of those for any realistic course: staff post far less than
    /// students do, and a pinned thread is by definition recent enough to
    /// have been kept on top. Paging deeper would mostly download student
    /// threads only to throw them away. `limit` is clamped to Ed's own cap of
    /// 100, since asking for more is a 400 and a lost sync.
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
