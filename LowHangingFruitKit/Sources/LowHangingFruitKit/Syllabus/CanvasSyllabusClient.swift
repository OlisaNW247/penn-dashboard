import Foundation

/// Finds a course's syllabus on Canvas, cookie-authenticated the same way
/// `CanvasGradesClient` and `CanvasDiscoveryClient` are.
///
/// Tries the cheap, structured sources first and stops as soon as one yields
/// text with a parseable grading scheme, so the common case is a single extra
/// request against an endpoint the app already talks to:
///
/// 1. the course's `syllabus_body` (one query param on a call we already make)
/// 2. course pages whose title mentions the syllabus
/// 3. course files named like a syllabus (PDF)
///
/// Everything it can't find is covered by the paste/import path in the UI,
/// which is also the only route for a syllabus that lives on a professor's own
/// site. Failure here is normal, not an error state.
public struct CanvasSyllabusClient: Sendable {
    public enum Error: Swift.Error, Sendable, LocalizedError, Equatable {
        case sessionExpired
        case invalidURL
        case notHTTP
        case http(status: Int)

        public var errorDescription: String? {
            switch self {
            case .sessionExpired: return "Your Canvas session expired. Log in to Canvas again to read your syllabus."
            case .invalidURL:     return "Couldn't build a Canvas syllabus request URL."
            case .notHTTP:        return "Canvas did not return a normal web response."
            case let .http(status): return "Canvas returned HTTP \(status) for the syllabus."
            }
        }
    }

    /// PDFs are capped: a syllabus is a few hundred KB, and a course packet
    /// shouldn't be pulled over a phone connection to look for one table.
    private static let maxFileBytes = 8 * 1024 * 1024

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

    /// Every syllabus-ish document found for a course, best source first.
    /// Never throws for "nothing found" — an empty array is a normal answer.
    public func findCandidates(courseID: String) async throws -> [SyllabusCandidate] {
        var candidates: [SyllabusCandidate] = []

        if let body = try? await syllabusBody(courseID: courseID), !body.isEmpty {
            candidates.append(SyllabusCandidate(
                id: "syllabus-body-\(courseID)",
                source: .canvasSyllabusPage,
                name: "Course syllabus page",
                text: body
            ))
        }

        candidates.append(contentsOf: (try? await syllabusPages(courseID: courseID)) ?? [])
        candidates.append(contentsOf: (try? await syllabusFiles(courseID: courseID)) ?? [])

        return candidates.filter { !$0.text.isEmpty }
    }

    // MARK: - Sources

    /// GET /api/v1/courses/:id?include[]=syllabus_body
    private func syllabusBody(courseID: String) async throws -> String {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("api/v1/courses/\(courseID)"),
            resolvingAgainstBaseURL: false
        ) else { throw Error.invalidURL }
        components.queryItems = [URLQueryItem(name: "include[]", value: "syllabus_body")]
        guard let url = components.url else { throw Error.invalidURL }

        let data = try await fetch(url)
        let dto = try? JSONDecoder().decode(CourseSyllabusDTO.self, from: data)
        guard let html = dto?.syllabusBody, !html.isEmpty else { return "" }
        return SyllabusTextExtractor.text(fromHTML: html)
    }

    /// GET /api/v1/courses/:id/pages?search_term=syllabus, then the body of
    /// each hit (the list endpoint doesn't include page bodies).
    private func syllabusPages(courseID: String) async throws -> [SyllabusCandidate] {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("api/v1/courses/\(courseID)/pages"),
            resolvingAgainstBaseURL: false
        ) else { throw Error.invalidURL }
        components.queryItems = [
            URLQueryItem(name: "search_term", value: "syllabus"),
            URLQueryItem(name: "per_page", value: "10"),
        ]
        guard let url = components.url else { throw Error.invalidURL }

        let data = try await fetch(url)
        guard let pages = try? JSONDecoder().decode([CoursePageDTO].self, from: data) else { return [] }

        var candidates: [SyllabusCandidate] = []
        for page in pages.prefix(3) {
            guard let slug = page.url else { continue }
            let bodyURL = baseURL.appendingPathComponent("api/v1/courses/\(courseID)/pages/\(slug)")
            guard let bodyData = try? await fetch(bodyURL),
                  let full = try? JSONDecoder().decode(CoursePageDTO.self, from: bodyData),
                  let html = full.body, !html.isEmpty
            else { continue }
            candidates.append(SyllabusCandidate(
                id: "page-\(slug)",
                source: .canvasPage,
                name: page.title ?? "Course page",
                text: SyllabusTextExtractor.text(fromHTML: html)
            ))
        }
        return candidates
    }

    /// GET /api/v1/courses/:id/files?search_term=syllabus → download the PDFs.
    private func syllabusFiles(courseID: String) async throws -> [SyllabusCandidate] {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("api/v1/courses/\(courseID)/files"),
            resolvingAgainstBaseURL: false
        ) else { throw Error.invalidURL }
        components.queryItems = [
            URLQueryItem(name: "search_term", value: "syllabus"),
            URLQueryItem(name: "per_page", value: "10"),
        ]
        guard let url = components.url else { throw Error.invalidURL }

        let data = try await fetch(url)
        guard let files = try? JSONDecoder().decode([CourseFileDTO].self, from: data) else { return [] }

        var candidates: [SyllabusCandidate] = []
        for file in files.prefix(3) {
            guard let urlString = file.url, let fileURL = URL(string: urlString) else { continue }
            guard Self.isTrustedFileURL(fileURL, baseURL: baseURL) else { continue }
            guard (file.size ?? 0) <= Self.maxFileBytes else { continue }
            guard let bytes = try? await fetch(fileURL), let text = SyllabusTextExtractor.text(fromPDF: bytes) else { continue }
            candidates.append(SyllabusCandidate(
                id: "file-\(file.id ?? 0)",
                source: .canvasFile,
                name: file.displayName ?? file.filename ?? "Syllabus file",
                text: text
            ))
        }
        return candidates
    }

    // MARK: - Transport

    /// Canvas file URLs are pre-signed and may point at an S3-style host, so
    /// unlike the grades client's pagination guard this can't demand an exact
    /// host match. It does demand HTTPS, and it only sends the session cookies
    /// to Canvas's own host — a download URL that redirects to a CDN gets the
    /// request without our credentials attached.
    static func isTrustedFileURL(_ url: URL, baseURL: URL) -> Bool {
        url.scheme?.lowercased() == "https"
    }

    private func shouldAttachCookies(to url: URL) -> Bool {
        guard let host = url.host?.lowercased(), let baseHost = baseURL.host?.lowercased() else { return false }
        return host == baseHost
    }

    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = true
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        if shouldAttachCookies(to: url) {
            for (field, value) in HTTPCookie.requestHeaderFields(with: cookies) {
                request.setValue(value, forHTTPHeaderField: field)
            }
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Error.notHTTP }
        if http.statusCode == 401 { throw Error.sessionExpired }
        guard (200..<300).contains(http.statusCode) else { throw Error.http(status: http.statusCode) }

        let stripped = CanvasGradesClient.stripXSSIPrefix(data)
        // A JSON endpoint answering with HTML is Canvas's silent
        // redirect-to-login. (PDF bytes never start with '<'.)
        if CanvasGradesClient.looksLikeHTML(stripped), url.path.contains("/api/v1/") {
            throw Error.sessionExpired
        }
        return stripped
    }
}

// MARK: - Wire DTOs

private struct CourseSyllabusDTO: Decodable {
    let syllabusBody: String?
    enum CodingKeys: String, CodingKey { case syllabusBody = "syllabus_body" }
}

private struct CoursePageDTO: Decodable {
    let url: String?
    let title: String?
    let body: String?
}

private struct CourseFileDTO: Decodable {
    let id: Int?
    let url: String?
    let filename: String?
    let displayName: String?
    let size: Int?
    enum CodingKeys: String, CodingKey {
        case id, url, filename, size
        case displayName = "display_name"
    }
}
