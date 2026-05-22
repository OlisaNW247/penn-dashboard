import Foundation

public struct GradescopeClient: Sendable {
    public enum Error: Swift.Error, Sendable, LocalizedError {
        case http(status: Int, url: URL)
        case notHTTP
        case invalidResponseEncoding
        case notLoggedIn

        public var errorDescription: String? {
            switch self {
            case let .http(status, url):
                return "Gradescope returned HTTP \(status) for \(url.path)."
            case .notHTTP:
                return "Gradescope did not return a normal web response. Your session may have expired."
            case .invalidResponseEncoding:
                return "Gradescope returned a page the app could not read."
            case .notLoggedIn:
                return "Gradescope needs you to log in again."
            }
        }
    }

    private let baseURL: URL
    private let cookies: [HTTPCookie]
    private let session: URLSession

    public init(
        baseURL: URL = URL(string: "https://www.gradescope.com")!,
        cookies: [HTTPCookie],
        session: URLSession = .shared
    ) {
        self.baseURL = baseURL
        self.cookies = cookies
        self.session = session
    }

    public func fetchAssignments() async throws -> [Assignment] {
        let accountURL = baseURL.appendingPathComponent("account")
        let accountHTML = try await fetchHTML(accountURL)
        guard !GradescopeHTMLParser.isLoginPage(accountHTML) else {
            throw Error.notLoggedIn
        }
        let courses = GradescopeHTMLParser.courseLinks(from: accountHTML, baseURL: baseURL)

        if courses.isEmpty {
            let assignments = GradescopeHTMLParser.assignments(
                from: accountHTML,
                courseName: "Gradescope",
                courseURL: baseURL
            )
            return try await refineCompletionStatus(assignments).sorted(by: Self.byDueDate)
        }

        var assignments: [Assignment] = []
        for course in courses {
            let html = try await fetchHTML(course.url)
            assignments.append(contentsOf: GradescopeHTMLParser.assignments(
                from: html,
                courseName: course.name,
                courseURL: course.url
            ))
        }
        return try await refineCompletionStatus(assignments).sorted(by: Self.byDueDate)
    }

    private func refineCompletionStatus(_ assignments: [Assignment]) async throws -> [Assignment] {
        var refined: [Assignment] = []
        refined.reserveCapacity(assignments.count)

        for assignment in assignments {
            guard !assignment.submitted, let url = assignment.url else {
                refined.append(assignment)
                continue
            }

            do {
                let html = try await fetchHTML(url)
                if GradescopeHTMLParser.isCompletedAssignmentPage(html) {
                    refined.append(assignment.withSubmitted(true))
                } else {
                    refined.append(assignment)
                }
            } catch {
                refined.append(assignment)
            }
        }

        return refined
    }

    private func fetchHTML(_ url: URL) async throws -> String {
        var request = URLRequest(url: url)
        request.httpShouldHandleCookies = true
        request.setValue(
            "Mozilla/5.0 PennDashboard/0.1",
            forHTTPHeaderField: "User-Agent"
        )

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

    private static func byDueDate(_ a: Assignment, _ b: Assignment) -> Bool {
        switch (a.dueAt, b.dueAt) {
        case let (lhs?, rhs?): return lhs < rhs
        case (nil, _):         return false
        case (_, nil):         return true
        }
    }
}

public enum GradescopeHTMLParser {
    public struct CourseLink: Sendable, Hashable {
        public let name: String
        public let url: URL

        public init(name: String, url: URL) {
            self.name = name
            self.url = url
        }
    }

    public static func courseLinks(from html: String, baseURL: URL) -> [CourseLink] {
        let pattern = #"<a\b[^>]*href\s*=\s*["']([^"']*/courses/\d+)/?["'][^>]*>(.*?)</a>"#
        var seen: Set<URL> = []
        return matches(pattern, in: html).compactMap { groups in
            guard groups.count >= 2,
                  let url = URL(string: groups[0], relativeTo: baseURL)?.absoluteURL
            else { return nil }

            let name = cleanText(groups[1])
            guard !name.isEmpty, seen.insert(url).inserted else { return nil }
            return CourseLink(name: name, url: url)
        }
    }

    public static func assignments(
        from html: String,
        courseName: String,
        courseURL: URL,
        referenceDate: Date = Date()
    ) -> [Assignment] {
        let rows = matches(#"<tr\b[^>]*>(.*?)</tr>"#, in: html).map { $0[0] }
        let candidates = rows.isEmpty ? assignmentWindows(from: html) : rows

        return candidates.compactMap { row in
            parseAssignmentRow(
                row,
                courseName: courseName,
                courseURL: courseURL,
                referenceDate: referenceDate
            )
        }
    }

    public static func isCompletedAssignmentPage(_ html: String) -> Bool {
        isCompletedStatus(in: [cleanText(html)])
    }

    public static func isLoginPage(_ html: String) -> Bool {
        let text = cleanText(html).lowercased()
        return text.contains("log in")
            && text.contains("gradescope")
            && (text.contains("email") || text.contains("password") || text.contains("school credentials"))
    }

    private static func assignmentWindows(from html: String) -> [String] {
        let linkPattern = #"<a\b[^>]*href\s*=\s*["'][^"']*/courses/\d+/assignments/\d+[^"']*["'][^>]*>.*?</a>"#
        guard let regex = try? NSRegularExpression(
            pattern: linkPattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return [html] }

        let nsHTML = html as NSString
        let matches = regex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length))
        guard !matches.isEmpty else { return [html] }

        return matches.enumerated().map { index, match in
            let start = match.range.location
            let end = if index + 1 < matches.count {
                matches[index + 1].range.location
            } else {
                min(nsHTML.length, match.range.upperBound + 1200)
            }
            return nsHTML.substring(with: NSRange(location: start, length: end - start))
        }
    }

    static func parseDate(_ raw: String, referenceDate: Date = Date()) -> Date? {
        let cleaned = cleanText(raw)
            .replacingOccurrences(of: #"(?i)\b(due|late due|deadline|released?|date)\b:?"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\bEST|EDT|UTC|PST|PDT|CST|CDT|MST|MDT\b"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)\s+at\s+"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"(?i)(\d)(am|pm)\b"#, with: "$1 $2", options: .regularExpression)
            .replacingOccurrences(of: #","#, with: ", ")
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty,
              !cleaned.localizedCaseInsensitiveContains("no due")
        else { return nil }

        let formatsWithYear = [
            "yyyy-MM-dd'T'HH:mm:ssXXXXX",
            "yyyy-MM-dd'T'HH:mm:ss.SSSXXXXX",
            "yyyy-MM-dd'T'HH:mm:ssZ",
            "yyyy-MM-dd'T'HH:mm:ss.SSSZ",
            "MMM d, yyyy h:mm a",
            "MMM d, yyyy, h:mm a",
            "MMMM d, yyyy h:mm a",
            "MMMM d, yyyy, h:mm a",
            "E, MMM d, yyyy h:mm a",
            "E, MMM d, yyyy, h:mm a",
            "M/d/yyyy h:mm a",
            "M/d/yy h:mm a",
            "yyyy-MM-dd h:mm a",
            "yyyy-MM-dd HH:mm",
        ]

        if let date = parse(cleaned, formats: formatsWithYear) {
            return date
        }

        let formatsWithoutYear = [
            "MMM d h:mm a",
            "MMM d, h:mm a",
            "MMMM d h:mm a",
            "MMMM d, h:mm a",
            "E, MMM d h:mm a",
            "E, MMM d, h:mm a",
            "M/d h:mm a",
        ]

        if let date = parse(cleaned, formats: formatsWithoutYear) {
            return normalizeYear(for: date, referenceDate: referenceDate)
        }

        return nil
    }

    private static func parseAssignmentRow(
        _ row: String,
        courseName: String,
        courseURL: URL,
        referenceDate: Date
    ) -> Assignment? {
        let linkPattern = #"<a\b[^>]*href\s*=\s*["']([^"']*/courses/(\d+)/assignments/(\d+)[^"']*)["'][^>]*>(.*?)</a>"#
        guard let link = matches(linkPattern, in: row).first,
              link.count >= 4,
              let url = URL(string: link[0], relativeTo: courseURL)?.absoluteURL
        else { return nil }

        let title = cleanText(link[3])
        guard !title.isEmpty else { return nil }

        let cells = matches(#"<t[dh]\b[^>]*>(.*?)</t[dh]>"#, in: row).map { cleanText($0[0]) }
        let dueAt = dueDate(from: row, cells: cells, referenceDate: referenceDate)
        let submitted = isCompletedStatus(in: cells) || isCompletedStatus(in: [cleanText(row)])

        return Assignment(
            source: .gradescope,
            sourceID: "course-\(link[1])-assignment-\(link[2])",
            kind: .assignment,
            course: courseName,
            title: title,
            dueAt: dueAt,
            url: url,
            submitted: submitted
        )
    }

    private static func dueDate(from row: String, cells: [String], referenceDate: Date) -> Date? {
        if let due = cells.reversed().compactMap({ parseDate($0, referenceDate: referenceDate) }).first {
            return due
        }

        let attributes = [
            #"(?i)\bdatetime\s*=\s*["']([^"']+)["']"#,
            #"(?i)\bdata-due-date\s*=\s*["']([^"']+)["']"#,
            #"(?i)\bdata-deadline\s*=\s*["']([^"']+)["']"#,
            #"(?i)\btitle\s*=\s*["']([^"']*(?:due|deadline)[^"']*)["']"#,
            #"(?i)\baria-label\s*=\s*["']([^"']*(?:due|deadline)[^"']*)["']"#,
        ]

        for pattern in attributes {
            for groups in matches(pattern, in: row) {
                guard let candidate = groups.first,
                      let due = parseDate(candidate, referenceDate: referenceDate)
                else { continue }
                return due
            }
        }

        let text = cleanText(row)
        let patterns = [
            #"(?i)\bdue date:?\s*(.+?)(?:\s+(?:status|submitted|graded|released|late due)\b|$)"#,
            #"(?i)\bdue:?\s*(.+?)(?:\s+(?:status|submitted|graded|released|late due)\b|$)"#,
            #"(?i)\bdeadline:?\s*(.+?)(?:\s+(?:status|submitted|graded|released|late due)\b|$)"#,
        ]

        for pattern in patterns {
            for groups in matches(pattern, in: text) {
                guard let candidate = groups.first,
                      let due = parseDate(trimDateCandidate(candidate), referenceDate: referenceDate)
                else { continue }
                return due
            }
        }

        return nil
    }

    private static func trimDateCandidate(_ raw: String) -> String {
        raw
            .replacingOccurrences(
                of: #"(?i)\s+(?:status|submitted|not submitted|graded|ungraded|released|late due|points?|score)\b.*$"#,
                with: "",
                options: .regularExpression
            )
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func isCompletedStatus(in texts: [String]) -> Bool {
        texts.contains { text in
            let normalized = text
                .lowercased()
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)

            let negativePatterns = [
                "not submitted",
                "unsubmitted",
                "not graded",
                "ungraded",
                "no submission",
                "no submissions",
                "missing",
            ]
            if negativePatterns.contains(where: normalized.contains) {
                return false
            }

            let positivePatterns = [
                "view submission",
                "download submission",
                "submission history",
                "submission uploaded",
                "your submission",
                "submitted at",
                "submitted on",
                "submission time",
                "submitted",
                "resubmitted",
                "resubmit",
                "graded",
                "uploaded",
            ]
            if positivePatterns.contains(where: normalized.contains) {
                return true
            }

            return normalized.range(
                of: #"\b(score|grade)\b.{0,40}\b\d+(?:\.\d+)?\s*/\s*\d+(?:\.\d+)?\b"#,
                options: .regularExpression
            ) != nil
        }
    }

    private static func parse(_ raw: String, formats: [String]) -> Date? {
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone.current
            formatter.dateFormat = format
            if let date = formatter.date(from: raw) {
                return date
            }
        }
        return nil
    }

    private static func normalizeYear(for date: Date, referenceDate: Date) -> Date? {
        let calendar = Calendar(identifier: .gregorian)
        let referenceYear = calendar.component(.year, from: referenceDate)
        var components = calendar.dateComponents([.month, .day, .hour, .minute, .second], from: date)
        components.year = referenceYear

        guard let sameYear = calendar.date(from: components) else { return nil }
        if sameYear.timeIntervalSince(referenceDate) < -15552000 {
            components.year = referenceYear + 1
            return calendar.date(from: components)
        }
        return sameYear
    }

    private static func matches(_ pattern: String, in text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(
            pattern: pattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return [] }

        let nsText = text as NSString
        let range = NSRange(location: 0, length: nsText.length)
        return regex.matches(in: text, range: range).map { match in
            (1..<match.numberOfRanges).compactMap { index in
                let range = match.range(at: index)
                guard range.location != NSNotFound else { return nil }
                return nsText.substring(with: range)
            }
        }
    }

    private static func cleanText(_ html: String) -> String {
        html
            .replacingOccurrences(of: #"<script\b[^>]*>.*?</script>"#, with: " ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"<style\b[^>]*>.*?</style>"#, with: " ", options: [.regularExpression, .caseInsensitive])
            .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
            .htmlDecoded()
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

private extension String {
    func htmlDecoded() -> String {
        var text = self
        let entities = [
            "&amp;": "&",
            "&lt;": "<",
            "&gt;": ">",
            "&quot;": "\"",
            "&#39;": "'",
            "&apos;": "'",
            "&nbsp;": " ",
        ]
        for (entity, value) in entities {
            text = text.replacingOccurrences(of: entity, with: value)
        }
        return text
    }
}

private extension Assignment {
    func withSubmitted(_ submitted: Bool) -> Assignment {
        Assignment(
            source: source,
            sourceID: sourceID,
            kind: kind,
            course: course,
            title: title,
            dueAt: dueAt,
            url: url,
            submitted: submitted
        )
    }
}
