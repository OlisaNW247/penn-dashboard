import Foundation

/// What Canvas says about one file (`GET /api/v1/files/:id`).
public struct CanvasFileMetadata: Decodable, Sendable, Hashable {
    public let id: Int?
    public let displayName: String
    public let contentType: String
    public let size: Int?
    public let url: String?
    public let updatedAt: Date?
    public let lockedForUser: Bool

    enum CodingKeys: String, CodingKey {
        case id, size, url
        case displayName = "display_name"
        case contentType = "content-type"
        case updatedAt = "updated_at"
        case lockedForUser = "locked_for_user"
    }

    public init(id: Int? = nil, displayName: String, contentType: String, size: Int? = nil,
                url: String? = nil, updatedAt: Date? = nil, lockedForUser: Bool = false) {
        self.id = id; self.displayName = displayName; self.contentType = contentType
        self.size = size; self.url = url; self.updatedAt = updatedAt; self.lockedForUser = lockedForUser
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try? c.decode(Int.self, forKey: .id)
        displayName = (try? c.decode(String.self, forKey: .displayName)) ?? ""
        contentType = (try? c.decode(String.self, forKey: .contentType)) ?? ""
        size = try? c.decode(Int.self, forKey: .size)
        url = try? c.decode(String.self, forKey: .url)
        updatedAt = try? c.decode(Date.self, forKey: .updatedAt)
        lockedForUser = (try? c.decode(Bool.self, forKey: .lockedForUser)) ?? false
    }
}

/// Reads PDFs an instructor attached to assignments, with the student's own
/// Canvas login. Authenticated like the other Canvas clients (explicit
/// `Cookie` header or bearer token, `CredentialRedirectGuard` on redirects).
public struct CanvasFilesClient: Sendable {
    public enum Error: Swift.Error, Sendable, Equatable {
        /// 401 or an HTML login page. Canvas also answers 401 for "this course
        /// hides its Files", which this client cannot tell apart without a
        /// second call; the pass stops its run on it, which is the safe side.
        case sessionExpired
        case http(Int)
        case notHTTP
        case invalidJSON
        case tooLarge
    }

    public enum Skip: String, Sendable, Equatable {
        case notPDF, locked, tooLarge, unavailable
    }

    public enum Result: Sendable, Equatable {
        case pdf(CanvasFileMetadata, Data)
        case skipped(Skip)
    }

    public static let maxBytes = 10 * 1024 * 1024

    private let baseURL: URL
    private let cookies: [HTTPCookie]
    private let session: URLSession
    private let accessToken: String?

    public init(baseURL: URL = URL(string: "https://canvas.upenn.edu")!,
                cookies: [HTTPCookie], session: URLSession = .shared, accessToken: String? = nil) {
        self.baseURL = baseURL; self.cookies = cookies; self.session = session; self.accessToken = accessToken
    }

    /// GET /api/v1/files/:id
    public func metadata(fileID: String) async throws -> CanvasFileMetadata {
        var components = URLComponents(url: baseURL.appendingPathComponent("api/v1/files/\(fileID)"), resolvingAgainstBaseURL: false)!
        components.queryItems = nil
        var request = authorized(components.url!)
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.credentialSafeData(for: request)
        let http = try check(response)
        if let type = http.value(forHTTPHeaderField: "Content-Type"), type.localizedCaseInsensitiveContains("text/html") {
            throw Error.sessionExpired
        }
        do {
            return try CourseContentAPI.decoder().decode(CanvasFileMetadata.self, from: CourseContentAPI.stripAntiHijackPrefix(data))
        } catch { throw Error.invalidJSON }
    }

    /// GET /api/v1/users/self: true only on a 200 JSON answer. Tells a
    /// forbidden file (401 on a live session) from a dead session.
    public func sessionIsAlive() async -> Bool {
        var request = authorized(baseURL.appendingPathComponent("api/v1/users/self"))
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        guard let (_, response) = try? await session.credentialSafeData(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200 else { return false }
        if let type = http.value(forHTTPHeaderField: "Content-Type"), type.localizedCaseInsensitiveContains("text/html") {
            return false
        }
        return true
    }

    /// The file's bytes, following redirects (Canvas answers with a signed
    /// storage URL), refused above `maxBytes` by `Content-Length` and again by
    /// bytes actually read.
    public func download(url: URL) async throws -> Data {
        guard url.scheme?.lowercased() == "https" else { throw Error.notHTTP }
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        // Credentials only to Canvas itself; the signed link carries its own
        // verifier and a redirect off Canvas drops them anyway.
        if url.host?.lowercased() == baseURL.host?.lowercased() {
            CanvasAuth.apply(to: &request, cookies: cookies, accessToken: accessToken)
        }
        let delegate = SizeCappedDelegate(maxBytes: Self.maxBytes)
        let data: Data, response: URLResponse
        do {
            (data, response) = try await session.data(for: request, delegate: delegate)
        } catch {
            // The delegate cancels the task the moment the headers say the body
            // is over the cap, so no body is read.
            if delegate.refused { throw Error.tooLarge }
            throw error
        }
        _ = try check(response)
        if response.expectedContentLength > Int64(Self.maxBytes) || data.count > Self.maxBytes { throw Error.tooLarge }
        return data
    }

    /// Metadata, the pdf-only / unlocked / size rules, then the bytes. 403 and
    /// 404 skip that file (a course can hide Files); 401 throws.
    public func pdf(fileID: String) async throws -> Result {
        let meta: CanvasFileMetadata
        do { meta = try await metadata(fileID: fileID) }
        catch Error.http(let status) where status == 403 || status == 404 { return .skipped(.unavailable) }
        guard !meta.lockedForUser else { return .skipped(.locked) }
        guard meta.contentType.lowercased().hasPrefix("application/pdf") else { return .skipped(.notPDF) }
        if let size = meta.size, size > Self.maxBytes { return .skipped(.tooLarge) }
        guard let raw = meta.url, let url = URL(string: raw) else { return .skipped(.unavailable) }
        do { return .pdf(meta, try await download(url: url)) }
        catch Error.tooLarge { return .skipped(.tooLarge) }
        catch Error.http(let status) where status == 403 || status == 404 { return .skipped(.unavailable) }
    }

    private func authorized(_ url: URL) -> URLRequest {
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = false
        CanvasAuth.apply(to: &request, cookies: cookies, accessToken: accessToken)
        return request
    }

    private func check(_ response: URLResponse) throws -> HTTPURLResponse {
        guard let http = response as? HTTPURLResponse else { throw Error.notHTTP }
        if http.statusCode == 401 { throw Error.sessionExpired }
        guard (200..<300).contains(http.statusCode) else { throw Error.http(http.statusCode) }
        return http
    }
}


/// Cancels a download whose response headers declare a body over the cap, and
/// strips credentials from redirects off Canvas (`CredentialRedirectGuard`).
/// The bytes received are still checked by the caller.
final class SizeCappedDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let maxBytes: Int
    private let lock = NSLock()
    private var _refused = false
    private let redirects = CredentialRedirectGuard()

    init(maxBytes: Int) { self.maxBytes = maxBytes }

    var refused: Bool { lock.lock(); defer { lock.unlock() }; return _refused }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        if response.expectedContentLength > Int64(maxBytes) {
            lock.lock(); _refused = true; lock.unlock()
            completionHandler(.cancel)
        } else {
            completionHandler(.allow)
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        redirects.urlSession(session, task: task, willPerformHTTPRedirection: response,
                             newRequest: request, completionHandler: completionHandler)
    }
}
