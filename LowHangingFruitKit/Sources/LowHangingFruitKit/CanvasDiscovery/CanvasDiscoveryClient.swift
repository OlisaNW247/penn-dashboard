import Foundation

public struct CanvasDiscoveryClient: Sendable {
    public enum Error: Swift.Error, Sendable, LocalizedError {
        case http(status: Int, url: URL)
        case notHTTP
        case invalidResponseEncoding
        case noCoursesFound
        case noCalendarFeed

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
            case .noCalendarFeed:
                return "Couldn't find your Canvas calendar feed. Make sure you're fully logged in to Canvas, then try again."
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

    /// Reads the user's personal Canvas iCalendar feed URL from the logged-in
    /// `/calendar` page, so onboarding never has to ask the user to paste it.
    public func discoverCalendarFeedURL() async throws -> URL {
        let html = try await fetchHTML(baseURL.appendingPathComponent("calendar"))
        guard let feed = CanvasCalendarFeedParser.feedURL(from: html) else {
            throw Error.noCalendarFeed
        }
        return feed
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

    /// Public wrapper over the same `/courses` + `/dashboard` scrape `scan`
    /// already uses internally, for callers (`CourseProfileEngine`'s
    /// caller) that need the full enrolled-course list itself rather than
    /// just an id→name lookup table — in particular, courses with zero
    /// calendar/feed presence are otherwise invisible to LHF, and this is
    /// the only source that surfaces them (docs/READINGS_COURSES_PLAN.md
    /// Phase 1.2).
    public func discoverEnrolledCourses() async -> [CanvasCourseDiscoveryParser.Course] {
        // `discoverCourses()` already dedupes by id (it's keyed on id in a
        // dictionary), so this is a direct, order-unspecified projection.
        await discoverCourses().map { CanvasCourseDiscoveryParser.Course(id: $0.key, name: $0.value) }
    }

    /// Fetches and parses a course's Modules page — the one new network
    /// surface Phase 1.3 needs, alongside the syllabus/assignment-group
    /// fetches the grades client already does — so the profile engine can
    /// tell a course that only publishes readings through Modules apart
    /// from one that's genuinely silent. Best-effort like the rest of this
    /// file's HTML scraping: a parse miss yields an empty array (see
    /// `CanvasModulesParser`), but a *fetch* failure (expired session, HTTP
    /// error) still throws, so callers can tell "no session" (→
    /// `.unknownSilent`) apart from "session fine, page just has nothing."
    public func fetchModulesReadings(courseID: String) async throws -> [CanvasModulesParser.Item] {
        let html = try await fetchHTML(baseURL.appendingPathComponent("courses/\(courseID)/modules"))
        return CanvasModulesParser.items(from: html)
    }

    /// `/courses` and `/dashboard` need DIFFERENT parsers: `/courses` lists
    /// past and future enrollments alongside current ones (professors often
    /// never conclude a course), so it goes through `currentEnrollmentLinks`
    /// to keep finished classes out of `canvasCourseIDsByCode` / Grade
    /// Watcher. `/dashboard` only ever shows Canvas's own idea of "active"
    /// courses (that's what the dashboard IS), so the plain, unsectioned
    /// `courseLinks` is correct there and cheaper.
    private func discoverCourses() async -> [String: String] {
        var courses: [String: String] = [:]

        if let html = try? await fetchHTML(baseURL.appendingPathComponent("courses")) {
            for course in CanvasCourseDiscoveryParser.currentEnrollmentLinks(from: html) {
                courses[course.id] = course.name
            }
        }

        if let html = try? await fetchHTML(baseURL.appendingPathComponent("dashboard")) {
            for course in CanvasCourseDiscoveryParser.courseLinks(from: html) {
                courses[course.id] = course.name
            }
        }

        return courses
    }

    private func fetchHTML(_ url: URL) async throws -> String {
        var request = URLRequest(url: url)
        // We attach the session cookie explicitly as a `Cookie` header below,
        // so cookie handling must be off here — leaving it `true` alongside a
        // manual header is undefined behavior (`HTTPCookieStorage.shared` can
        // silently overwrite or duplicate the header). See
        // docs/CANVAS_LOGIN_HARDENING.md item 2c.
        request.httpShouldHandleCookies = false
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

        // Explicit public init: the synthesized memberwise init is only
        // `internal`, which would leave callers outside this module (the UI
        // layer, and CourseProfileEngine's tests) unable to construct one
        // even though the type and its fields are public.
        public init(id: String, name: String) {
            self.id = id
            self.name = name
        }
    }

    /// Restricts course discovery to the CURRENT-enrollment section of
    /// Canvas's classic `/courses` page. That page groups enrollments into
    /// separate tables — `my_courses_table` for current enrollments, plus
    /// `past_enrollments_table`/`future_enrollments_table` (headed "Past
    /// Enrollments"/"Future Enrollments") for terms a professor never
    /// concluded, or hasn't started — and scraping the whole page (the old
    /// behavior) pulls long-finished classes into `canvasCourseIDsByCode`,
    /// polluting Grade Watcher with courses that are over.
    ///
    /// We find the EARLIEST of those past/future markers (by DOM id or
    /// heading text, case-insensitively — Canvas has used both across
    /// redesigns) and only scan the page before it.
    ///
    /// If NO marker is found at all, we fall back to the WHOLE page rather
    /// than an empty result: a future HTML redesign that renames or drops
    /// these markers must degrade to the old too-inclusive behavior — extra
    /// courses to filter elsewhere — never to an empty course list, which
    /// would look indistinguishable from a broken login.
    public static func currentEnrollmentLinks(from html: String) -> [Course] {
        let markers = ["past_enrollments", "Past Enrollments", "future_enrollments", "Future Enrollments"]
        let cutoff = markers
            .compactMap { html.range(of: $0, options: .caseInsensitive) }
            .map(\.lowerBound)
            .min()

        guard let cutoff else { return courseLinks(from: html) }
        return courseLinks(from: String(html[html.startIndex..<cutoff]))
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

public enum CanvasCalendarFeedParser {
    /// Extracts the per-user iCalendar feed URL (…/feeds/calendars/user_<token>.ics)
    /// that Canvas embeds in the `/calendar` page's "Calendar Feed" box.
    public static func feedURL(from html: String) -> URL? {
        let pattern = #"https?://[^"'\s<>]+/feeds/calendars/[^"'\s<>?]+\.ics(?:\?[^"'\s<>]*)?"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return nil
        }
        let nsHTML = html as NSString
        guard let match = regex.firstMatch(in: html, range: NSRange(location: 0, length: nsHTML.length)) else {
            return nil
        }
        let raw = nsHTML.substring(with: match.range)
            .replacingOccurrences(of: "&amp;", with: "&")
        return URL(string: raw)
    }
}

private extension URL {
    func appending(queryItems: [URLQueryItem]) -> URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else { return self }
        components.queryItems = (components.queryItems ?? []) + queryItems
        return components.url ?? self
    }
}
