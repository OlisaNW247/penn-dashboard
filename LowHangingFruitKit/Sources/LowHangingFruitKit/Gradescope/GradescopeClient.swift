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
        let result = GradescopeHTMLParser.currentTermCourses(from: accountHTML, baseURL: baseURL)

        if result.courses.isEmpty {
            let assignments = GradescopeHTMLParser.assignments(
                from: accountHTML,
                courseName: "Gradescope",
                courseURL: baseURL
            )
            return try await refineCompletionStatus(assignments).sorted(by: Self.byDueDate)
        }

        var assignments: [Assignment] = []
        for course in result.courses {
            let html = try await fetchHTML(course.url)
            let courseAssignments = GradescopeHTMLParser.assignments(
                from: html,
                courseName: course.name,
                courseURL: course.url
            )
            assignments.append(contentsOf: GradescopeHTMLParser.filterFallbackAssignments(
                courseAssignments,
                isFallback: result.isFallback
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
        // See `CanvasDiscoveryClient.fetchHTML`'s matching comment — an
        // explicit `Cookie` header below means this must be `false`
        // (docs/CANVAS_LOGIN_HARDENING.md item 2c).
        request.httpShouldHandleCookies = false
        request.setValue(
            "Mozilla/5.0 LowHangingFruit/0.1",
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

            let name = shortCourseName(from: groups[1])
            guard !name.isEmpty, seen.insert(url).inserted else { return nil }
            return CourseLink(name: name, url: url)
        }
    }

    /// Gradescope course cards bundle the short code, full title, and an
    /// "N assignments" count. Prefer the short code (e.g. "CIS 2400").
    private static func shortCourseName(from inner: String) -> String {
        if let short = matches(#"(?i)courseBox--shortname[^>]*>(.*?)<"#, in: inner).first?.first {
            let s = cleanText(short)
            if !s.isEmpty { return s }
        }
        // Fallback: drop a trailing "N assignment(s)" from the combined text.
        return cleanText(inner)
            .replacingOccurrences(of: #"(?i)\s*\d+\s+assignments?$"#, with: "", options: .regularExpression)
    }

    /// The outcome of resolving which courses belong to "now". `isFallback` is
    /// true whenever `courses` were NOT matched to today's term by an exact
    /// label match — i.e. they were recovered via the grace-window fallback
    /// (most-recent dated term, or the first unlabeled group). Fallback courses
    /// are frequently finished classes whose assignments were published
    /// without a due date, so callers should treat their undated assignments
    /// with suspicion (see `filterFallbackAssignments`).
    public struct CurrentTermResult: Sendable {
        public let courses: [CourseLink]
        public let isFallback: Bool

        public init(courses: [CourseLink], isFallback: Bool) {
            self.courses = courses
            self.isFallback = isFallback
        }
    }

    /// How long after a dated group's season window ends the fallback below is
    /// still trusted. A prior term's finals (or its Gradescope postings) can
    /// spill a few weeks past its own window before the next term's heading
    /// shows up — the grace window keeps that legitimate spillover working.
    /// Beyond it, a lack of any group whose window covers "now" means the
    /// student simply has no courses right now (e.g. a break between terms),
    /// and falling back would resurface a finished class's stale backlog
    /// instead.
    private static let fallbackGraceWindow: TimeInterval = 21 * 86_400

    /// Courses belonging to the current term(s) only. Gradescope groups the
    /// account page's courses under term headings ("Spring 2026", "Fall 2025",
    /// "Winter 2026", …); past terms are finished classes whose stale,
    /// often-undated assignments would otherwise clog the dashboard.
    ///
    /// Unlike a single "the current term", each season+year label is given a
    /// generous *validity window* (see `GradescopeTerm.window`) wide enough to
    /// cover both semester and quarter systems, plus enrollment lead-in. Any
    /// dated group whose window contains `now` is kept — deliberately not
    /// exclusive, since a quarter school's "Winter 2026" and a semester
    /// school's "Spring 2026" can both be genuinely active in February, and a
    /// student can simultaneously have both a wrapping-up "Spring 2026" and a
    /// starting "Summer 2026" in June. None of this is treated as a fallback:
    /// it's a normal, confident match.
    ///
    /// If no group's window contains `now`, this falls back to the single
    /// newest dated group (or, failing that, the first listed group) — but
    /// only within `fallbackGraceWindow` of that group's window *ending*.
    /// Outside that window, an unmatched date returns no courses at all: the
    /// student has no active courses, and picking a completed term's group
    /// would resurface its old, often undated assignments. The returned
    /// `CurrentTermResult.isFallback` flag tells callers whether the courses
    /// came from this fallback path, so they can filter out undated
    /// assignments from stale-looking courses.
    public static func currentTermCourses(
        from html: String,
        baseURL: URL,
        now: Date = Date()
    ) -> CurrentTermResult {
        let groups = coursesByTerm(from: html, baseURL: baseURL)
        guard !groups.isEmpty else {
            return CurrentTermResult(courses: courseLinks(from: html, baseURL: baseURL), isFallback: false)
        }

        let datedGroups = groups.compactMap { group -> (term: GradescopeTerm, courses: [CourseLink])? in
            guard let term = GradescopeTerm(label: group.term) else { return nil }
            return (term, group.courses)
        }

        // Keep every dated group whose season window covers `now` — this can
        // be more than one group at once (see doc comment above).
        let activeCourses = datedGroups
            .filter { $0.term.window.contains(now) }
            .flatMap(\.courses)
        if !activeCourses.isEmpty {
            return CurrentTermResult(courses: dedupedByURL(activeCourses), isFallback: false)
        }

        // No group's window covers `now` — fall back to the most recent term
        // we can identify, but only within the grace window of its own
        // window ending (covers "term just ended, next term's heading isn't
        // up yet" spillover).
        if let newest = datedGroups.max(by: { $0.term < $1.term }) {
            guard now < newest.term.window.upperBound.addingTimeInterval(fallbackGraceWindow) else {
                return CurrentTermResult(courses: [], isFallback: false)
            }
            return CurrentTermResult(courses: dedupedByURL(newest.courses), isFallback: true)
        }

        // …or, if no term label could be parsed at all, the first listed
        // group (Gradescope lists the newest term first). There's no dated
        // group to distrust this against, so it isn't treated as a fallback.
        return CurrentTermResult(courses: dedupedByURL(groups.first?.courses ?? []), isFallback: false)
    }

    /// Drops assignments with no due date when they came from a fallback term
    /// match (see `currentTermCourses`). A finished class's assignments that
    /// were published without a due date are exactly the stale junk that
    /// otherwise gets stuck in the dashboard's undated section forever; dated
    /// assignments from the same course are left alone since the existing
    /// stale-due-date filtering downstream already handles those. A no-op
    /// when `isFallback` is false.
    public static func filterFallbackAssignments(_ assignments: [Assignment], isFallback: Bool) -> [Assignment] {
        guard isFallback else { return assignments }
        return assignments.filter { $0.dueAt != nil }
    }

    private static func coursesByTerm(
        from html: String,
        baseURL: URL
    ) -> [(term: String, courses: [CourseLink])] {
        let headingPattern = #"<[^>]*\bclass\s*=\s*["'][^"']*courseList--term[^"']*["'][^>]*>(.*?)</[^>]+>"#
        guard let regex = try? NSRegularExpression(
            pattern: headingPattern,
            options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return [] }

        let nsHTML = html as NSString
        let headings = regex.matches(in: html, range: NSRange(location: 0, length: nsHTML.length))
        guard !headings.isEmpty else { return [] }

        return headings.enumerated().compactMap { index, heading in
            let label = cleanText(nsHTML.substring(with: heading.range(at: 1)))
            let segmentStart = heading.range.upperBound
            let segmentEnd = index + 1 < headings.count
                ? headings[index + 1].range.location
                : nsHTML.length
            let segment = nsHTML.substring(with: NSRange(
                location: segmentStart,
                length: segmentEnd - segmentStart
            ))
            let courses = courseLinks(from: segment, baseURL: baseURL)
            return courses.isEmpty ? nil : (label, courses)
        }
    }

    private static func dedupedByURL(_ courses: [CourseLink]) -> [CourseLink] {
        var seen: Set<URL> = []
        return courses.filter { seen.insert($0.url).inserted }
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
            "yyyy-MM-dd HH:mm:ss Z",
            "yyyy-MM-dd HH:mm:ssZ",
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
        let course = courseID(from: courseURL)
        var assignmentID: String?
        var title: String?
        var url: URL?

        // Submitted assignments link their name to the submission page.
        let linkPattern = #"<a\b[^>]*href\s*=\s*["']([^"']*/courses/(\d+)/assignments/(\d+)[^"']*)["'][^>]*>(.*?)</a>"#
        if let link = matches(linkPattern, in: row).first, link.count >= 4 {
            assignmentID = link[2]
            url = URL(string: link[0], relativeTo: courseURL)?.absoluteURL
            let linkTitle = cleanText(link[3])
            if !linkTitle.isEmpty { title = linkTitle }
        }

        // Unsubmitted assignments render the name as a "submit" button carrying
        // data-assignment-id / data-assignment-title and no href — so recover
        // the id and name from those attributes instead.
        if assignmentID == nil,
           let id = matches(#"(?i)\bdata-assignment-id\s*=\s*["'](\d+)["']"#, in: row).first?.first {
            assignmentID = id
        }
        if title == nil || title?.isEmpty == true {
            if let t = matches(#"(?i)\bdata-assignment-title\s*=\s*["']([^"']+)["']"#, in: row).first?.first {
                title = cleanText(t)
            } else if let th = matches(#"<th\b[^>]*>(.*?)</th>"#, in: row).first?.first {
                title = cleanText(th)
            }
        }

        guard let assignmentID, let title, !title.isEmpty else { return nil }

        if url == nil, let course {
            url = URL(string: "https://www.gradescope.com/courses/\(course)/assignments/\(assignmentID)")
        }

        let cells = matches(#"<t[dh]\b[^>]*>(.*?)</t[dh]>"#, in: row).map { cleanText($0[0]) }
        let dueAt = dueDate(from: row, cells: cells, referenceDate: referenceDate)
        let submitted = isCompletedStatus(in: cells) || isCompletedStatus(in: [cleanText(row)])
        let score = scoreValues(in: cells + [cleanText(row)])

        return Assignment(
            source: .gradescope,
            sourceID: "course-\(course ?? "0")-assignment-\(assignmentID)",
            kind: .assignment,
            course: courseName,
            title: title,
            dueAt: dueAt,
            url: url,
            submitted: submitted,
            scoreEarned: score?.earned,
            scoreMax: score?.max
        )
    }

    /// Extracts the earned/max numbers from a Gradescope score string (e.g.
    /// "87.5 / 100", "Score: 0 / 100") without changing what `isCompletedStatus`
    /// already treats as "submitted" — this is purely additive parsing over the
    /// same cell/row text it already scans. Nil when no score fraction is
    /// present (ungraded, "Not Submitted", etc.).
    ///
    /// Tries two shapes, most specific first:
    /// 1. A cell that IS the score, nothing else (Gradescope's dedicated Grade
    ///    column typically renders exactly `"10.0 / 10.0"`, optionally with a
    ///    trailing "pts"/"points" unit) — this can't collide with a due-date
    ///    cell, which always carries more text (a month name, "at", "AM/PM"…).
    /// 2. A "score"/"grade"-labelled fraction anywhere in the text, mirroring
    ///    the keyword-gated fallback `isCompletedStatus` already uses to detect
    ///    a score is present, just capturing the numbers this time.
    static func scoreValues(in texts: [String]) -> (earned: Double, max: Double)? {
        for text in texts {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let groups = matches(bareScorePattern, in: trimmed).first,
               groups.count >= 2,
               let earned = Double(groups[0]),
               let max = Double(groups[1]) {
                return (earned, max)
            }
        }
        for text in texts {
            if let groups = matches(labelledScorePattern, in: text).first,
               groups.count >= 2,
               let earned = Double(groups[0]),
               let max = Double(groups[1]) {
                return (earned, max)
            }
        }
        return nil
    }

    private static let bareScorePattern =
        #"^(\d+(?:\.\d+)?)\s*/\s*(\d+(?:\.\d+)?)\s*(?:points?|pts?)?$"#
    private static let labelledScorePattern =
        #"(?i)\b(?:score|grade)\b\s*:?\s*.{0,40}?(\d+(?:\.\d+)?)\s*/\s*(\d+(?:\.\d+)?)\b"#

    /// The numeric course id from a `…/courses/<id>` URL.
    private static func courseID(from url: URL) -> String? {
        let parts = url.pathComponents
        guard let i = parts.firstIndex(of: "courses"), parts.indices.contains(i + 1) else { return nil }
        let id = parts[i + 1]
        return (!id.isEmpty && id.allSatisfy(\.isNumber)) ? id : nil
    }

    private static func dueDate(from row: String, cells: [String], referenceDate: Date) -> Date? {
        // Gradescope tags the real due date with a dedicated <time> element
        // (`submissionTimeChart--dueDate`); prefer its machine-readable datetime
        // over the release date or the noisy cell text.
        if let raw = matches(#"(?i)submissionTimeChart--dueDate[^>]*\bdatetime\s*=\s*["']([^"']+)["']"#, in: row).first?.first,
           let due = parseDate(raw, referenceDate: referenceDate) {
            return due
        }

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

    /// Picks the year for a date string that didn't include one. Resolves to the
    /// occurrence within (reference - 12 months, reference + grace]: a yearless
    /// date far in the future is almost always last year's (a stale leftover),
    /// while a yearless date near a year boundary rolls into next year.
    private static func normalizeYear(for date: Date, referenceDate: Date) -> Date? {
        let calendar = Calendar(identifier: .gregorian)
        let referenceYear = calendar.component(.year, from: referenceDate)
        var components = calendar.dateComponents([.month, .day, .hour, .minute, .second], from: date)

        // Allow a small future grace so genuinely near-term due dates keep the
        // current year, but treat anything further ahead as last year's.
        let futureGrace: TimeInterval = 45 * 86_400
        let upperBound = referenceDate.addingTimeInterval(futureGrace)

        components.year = referenceYear
        guard let candidate = calendar.date(from: components),
              let lowerBound = calendar.date(byAdding: .year, value: -1, to: upperBound)
        else { return nil }

        if candidate > upperBound {
            components.year = referenceYear - 1
        } else if candidate <= lowerBound {
            components.year = referenceYear + 1
        }
        return calendar.date(from: components)
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

/// An academic term, used to keep only the current term(s)' Gradescope
/// courses. Seasons here describe a Gradescope term *label* ("Winter 2026"),
/// not a fixed calendar quarter — see `window` for how a label maps to the
/// span of real-world dates it should be considered "current" for.
private struct GradescopeTerm: Comparable, Equatable {
    enum Season: Int { case winter = 0, spring = 1, summer = 2, fall = 3 }

    let year: Int
    let season: Season

    init?(label: String) {
        let lower = label.lowercased()
        guard let yearRange = lower.range(of: #"\b(19|20)\d{2}\b"#, options: .regularExpression),
              let parsedYear = Int(lower[yearRange])
        else { return nil }

        if lower.contains("spring") { season = .spring }
        else if lower.contains("summer") { season = .summer }
        else if lower.contains("fall") || lower.contains("autumn") { season = .fall }
        else if lower.contains("winter") { season = .winter }
        else { return nil }

        year = parsedYear
    }

    /// The span of real-world dates this term label should be treated as
    /// "current" for. Deliberately wide and overlapping between adjacent
    /// seasons: Gradescope's term labels are used by both semester schools
    /// (two long terms plus an optional summer session) and quarter schools
    /// (four roughly-equal terms), and a label alone doesn't say which system
    /// produced it. Each window is sized to cover the corresponding season on
    /// *either* calendar, plus a lead-in for early enrollment/orientation:
    ///
    /// - Winter YYYY: Dec 1 (YYYY-1) – Mar 31 YYYY (quarter Jan–Mar; winter
    ///   session Dec–Jan)
    /// - Spring YYYY: Jan 1 – Jun 30 YYYY (semester Jan–May; quarter Mar–Jun)
    /// - Summer YYYY: May 1 – Aug 31 YYYY
    /// - Fall YYYY: Aug 1 – Dec 31 YYYY (semester mid-Aug start; quarter
    ///   late-Sep start)
    ///
    /// The result is that several labels can be simultaneously "current" —
    /// e.g. a quarter school's "Winter 2026" and a semester school's "Spring
    /// 2026" both cover February — which is intentional: `currentTermCourses`
    /// keeps every group whose window contains `now`, not just one.
    var window: ClosedRange<Date> {
        let calendar = Calendar(identifier: .gregorian)
        func day(_ year: Int, _ month: Int, _ day: Int, endOfDay: Bool = false) -> Date {
            var components = DateComponents(year: year, month: month, day: day)
            if endOfDay {
                components.hour = 23
                components.minute = 59
                components.second = 59
            }
            return calendar.date(from: components) ?? (endOfDay ? .distantFuture : .distantPast)
        }

        switch season {
        case .winter:
            return day(year - 1, 12, 1) ... day(year, 3, 31, endOfDay: true)
        case .spring:
            return day(year, 1, 1) ... day(year, 6, 30, endOfDay: true)
        case .summer:
            return day(year, 5, 1) ... day(year, 8, 31, endOfDay: true)
        case .fall:
            return day(year, 8, 1) ... day(year, 12, 31, endOfDay: true)
        }
    }

    static func < (lhs: GradescopeTerm, rhs: GradescopeTerm) -> Bool {
        (lhs.year, lhs.season.rawValue) < (rhs.year, rhs.season.rawValue)
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
            term: term,
            submitted: submitted,
            scoreEarned: scoreEarned,
            scoreMax: scoreMax
        )
    }
}
