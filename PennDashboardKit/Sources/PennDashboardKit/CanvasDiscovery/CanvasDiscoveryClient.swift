import Foundation

public struct CanvasDiscoveryClient: Sendable {
    public enum Error: Swift.Error, Sendable, LocalizedError {
        case http(status: Int, url: URL)
        case notHTTP
        case invalidResponseEncoding
        case noCoursesFound

        public var errorDescription: String? {
            switch self {
            case let .http(status, url):
                return "Canvas returned HTTP \(status) for \(url.path)."
            case .notHTTP:
                return "Canvas did not return a normal web response."
            case .invalidResponseEncoding:
                return "Canvas returned a page the app could not read."
            case .noCoursesFound:
                return "Canvas login worked, but no courses were found to scan."
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

    public func scan(courseIDs: [String: String]) async throws -> [CanvasRequirementSuggestion] {
        let courses = courseIDs.isEmpty ? await discoverCourses() : courseIDs
        guard !courses.isEmpty else { throw Error.noCoursesFound }
        var suggestions: [CanvasRequirementSuggestion] = []

        for (courseID, courseName) in courses {
            if let html = try? await fetchHTML(baseURL.appendingPathComponent("courses/\(courseID)/assignments/syllabus")) {
                suggestions.append(contentsOf: CanvasRequirementScanner.suggestions(
                    from: html,
                    course: courseName,
                    source: .syllabus
                ))
            }

            let announcementURLs = [
                baseURL.appendingPathComponent("courses/\(courseID)/announcements"),
                baseURL.appendingPathComponent("courses/\(courseID)/discussion_topics").appending(queryItems: [
                    URLQueryItem(name: "only_announcements", value: "true")
                ]),
            ]

            for url in announcementURLs {
                guard let html = try? await fetchHTML(url) else { continue }
                suggestions.append(contentsOf: CanvasRequirementScanner.suggestions(
                    from: html,
                    course: courseName,
                    source: .announcement
                ))
            }
        }

        return Array(Set(suggestions)).sorted { lhs, rhs in
            lhs.course.localizedCaseInsensitiveCompare(rhs.course) == .orderedAscending
        }
    }

    private func discoverCourses() async -> [String: String] {
        let urls = [
            baseURL.appendingPathComponent("courses"),
            baseURL.appendingPathComponent("dashboard"),
        ]

        var courses: [String: String] = [:]
        for url in urls {
            guard let html = try? await fetchHTML(url) else { continue }
            for course in CanvasCourseDiscoveryParser.courseLinks(from: html) {
                courses[course.id] = course.name
            }
        }
        return courses
    }

    private func fetchHTML(_ url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = true
        let headerFields = HTTPCookie.requestHeaderFields(with: cookies)
        for (field, value) in headerFields {
            request.setValue(value, forHTTPHeaderField: field)
        }

        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw Error.notHTTP }
        guard (200..<300).contains(http.statusCode) else {
            throw Error.http(status: http.statusCode, url: url)
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw Error.invalidResponseEncoding
        }
        return html
    }
}

public enum CanvasCourseDiscoveryParser {
    public struct Course: Sendable, Hashable {
        public let id: String
        public let name: String
    }

    public static func courseLinks(from html: String) -> [Course] {
        let pattern = #"<a\b[^>]*href\s*=\s*["'][^"']*/courses/(\d+)[^"']*["'][^>]*>(.*?)</a>"#
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return [] }

        let nsHTML = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length))
        var seen: Set<String> = []

        return matches.compactMap { match in
            guard match.numberOfRanges >= 3 else { return nil }
            let id = nsHTML.substring(with: match.range(at: 1))
            let name = cleanText(nsHTML.substring(with: match.range(at: 2)))
            guard !name.isEmpty,
                  !name.localizedCaseInsensitiveContains("all courses"),
                  seen.insert(id).inserted
            else { return nil }
            return Course(id: id, name: name)
        }
    }

    private static func cleanText(_ html: String) -> String {
        html
            .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&nbsp;", with: " ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension URL {
    func appending(queryItems: [URLQueryItem]) -> URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return self }
        components.queryItems = (components.queryItems ?? []) + queryItems
        return components.url ?? self
    }
}
