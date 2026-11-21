import Foundation

/// The student's own registrar section of each Canvas site, read from
/// Canvas rather than from the site's name.
///
/// Why this exists: `ask` learns which of a course's registrar sections is
/// the student's from `CourseSummary.section`, and that used to come only
/// from the site's display name (`CourseCode.parse(name).section`). Penn's
/// SIS-built sites are named "CIS 2400-001 202630 Intro to Computer
/// Systems", so the number is there; but an instructor can rename a site,
/// and some never carry one. On 2026-11-15 the owner asked the tree what
/// time his accounting class was, and his site is "ACCT 1010 (Hail) -
/// Fall 2026": no number, so the server's COURSE STRUCTURE block listed all
/// eight ACCT 1010 lectures at four different times with none marked as
/// his, and the instructor's name narrows it only to two (Hail teaches 001
/// and 002). The site's *sections*, which Canvas lists for the student's
/// own enrollments on `GET /api/v1/courses?include[]=sections`, are named
/// by the registrar whatever the site is called.
///
/// Rules, deliberately conservative because a wrong section is worse than
/// none (the model would then state the wrong time with confidence):
/// - only a section whose name carries *this site's own* course code is
///   read, so a cross-listed twin ("OIDD 1010-002" inside an ACCT site)
///   never lends its number;
/// - the answer is a number only when exactly one distinct number is left;
///   a site where the student holds a lecture and a recitation section
///   (two numbers) gets nothing, as before;
/// - the name's own number always wins where it has one
///   (`AppState.canvasCourseSummaries`), so no site that already worked
///   changes.
///
/// What leaves the phone: the number goes to the server as
/// `CourseSummaryWire.section`, exactly as a number read from a site's name
/// always has. The section names themselves stay on the phone.
public enum CanvasOwnSections {

    /// One course from `/api/v1/courses?include[]=sections`: its id and the
    /// names of the sections the student is enrolled in.
    public struct Course: Equatable, Sendable {
        public let courseID: String
        public let sectionNames: [String]
        public init(courseID: String, sectionNames: [String]) {
            self.courseID = courseID
            self.sectionNames = sectionNames
        }
    }

    /// Decodes one page of the courses list. Lenient: a course whose id is
    /// missing is skipped, a missing `sections` array reads as none, and an
    /// id sent as a number or a string both work (Canvas sends numbers
    /// unless asked for string ids). A body that is not a JSON array is
    /// `nil`, which the caller treats as a failed read.
    public static func parse(_ data: Data) -> [Course]? {
        guard let array = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return nil }
        return array.compactMap { element -> Course? in
            guard let object = element as? [String: Any], let id = idString(object["id"]) else { return nil }
            let sections = (object["sections"] as? [Any] ?? []).compactMap { entry -> String? in
                guard let name = (entry as? [String: Any])?["name"] as? String else { return nil }
                let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
                return trimmed.isEmpty ? nil : trimmed
            }
            return Course(courseID: id, sectionNames: sections)
        }
    }

    /// One HTTP exchange: the seam tests replace.
    public typealias Transport = @Sendable (URL) async throws -> (Data, HTTPURLResponse)

    /// Reads every page of the student's active courses with their own
    /// sections, using the student's Canvas session. `nil` on any failure
    /// (a sign-out, a non-200, a body that is not a list), so the caller
    /// keeps what it last knew rather than forgetting every number.
    public static func fetch(
        baseURL: URL,
        cookies: [HTTPCookie],
        session: URLSession = .shared
    ) async -> [Course]? {
        await fetch(baseURL: baseURL) { url in
            var request = URLRequest(url: url)
            request.httpShouldHandleCookies = false
            request.setValue("application/json", forHTTPHeaderField: "Accept")
            CanvasAuth.apply(to: &request, cookies: cookies, accessToken: nil)
            let (data, response) = try await session.credentialSafeData(for: request)
            guard let http = response as? HTTPURLResponse else { throw URLError(.badServerResponse) }
            return (data, http)
        }
    }

    /// The same read over any transport. At most 10 pages of 100.
    public static func fetch(baseURL: URL, transport: Transport) async -> [Course]? {
        guard var components = URLComponents(
            url: baseURL.appendingPathComponent("api/v1/courses"),
            resolvingAgainstBaseURL: false
        ) else { return nil }
        components.queryItems = [
            URLQueryItem(name: "include[]", value: "sections"),
            URLQueryItem(name: "enrollment_state", value: "active"),
            URLQueryItem(name: "per_page", value: "100"),
        ]
        var next = components.url
        var courses: [Course] = []
        var pages = 0
        while let url = next, pages < 10 {
            pages += 1
            guard let (data, http) = try? await transport(url), http.statusCode == 200,
                  let page = parse(data) else { return nil }
            courses += page
            next = CanvasGradesClient.nextPageURL(fromLinkHeader: http.value(forHTTPHeaderField: "Link"))
                .flatMap { CanvasGradesClient.isTrustedNextPageURL($0, baseURL: baseURL) ? $0 : nil }
        }
        return courses
    }

    /// The student's section number for a site whose course code is
    /// `courseCode` ("ACCT 1010"), or `nil` when the names do not settle it.
    public static func sectionNumber(courseCode: String, sectionNames: [String]) -> String? {
        guard let regex = sectionRegex(for: courseCode) else { return nil }
        var numbers: [String] = []
        for name in sectionNames {
            let text = name.replacingOccurrences(of: "_", with: "-") as NSString
            for match in regex.matches(in: text as String, range: NSRange(location: 0, length: text.length)) {
                let section = text.substring(with: match.range(at: 1)).uppercased()
                if !numbers.contains(section) { numbers.append(section) }
            }
        }
        return numbers.count == 1 ? numbers[0] : nil
    }

    /// A pattern for *this* course's code followed by a section number: the
    /// department, then the course number (leading zeros optional, so Penn's
    /// old "PHYS 151" meets "PHYS 0151"), then the section, each separated by
    /// a space, a dash or nothing.
    ///
    /// Built from the code rather than a general "letters, digits, digits"
    /// shape, because Penn's real section names have no word break before the
    /// department: read off Olisa's phone on 2026-11-16, they are
    /// "8:30amACCT1010-001-Fall2026" and "12:00pmLGST1010-002-Fall2026", the
    /// meeting time glued to the code. The first version's general pattern
    /// began with `\b` and matched neither; dropping the `\b` from a general
    /// pattern would read "MACCT" out of "amACCT". Searching for the site's
    /// own department and number also keeps a cross-listed twin ("OIDD
    /// 1010-004") from lending its number, and the trailing `\b` keeps a term
    /// code ("ACCT 1010 2026C") from being read as section 202.
    static func sectionRegex(for courseCode: String) -> NSRegularExpression? {
        let upper = courseCode.uppercased() as NSString
        guard let match = codeRegex.firstMatch(in: upper as String, range: NSRange(location: 0, length: upper.length))
        else { return nil }
        let dept = upper.substring(with: match.range(at: 1))
        let trimmed = String(upper.substring(with: match.range(at: 2)).drop(while: { $0 == "0" }))
        let number = trimmed.isEmpty ? "0" : trimmed
        let pattern = NSRegularExpression.escapedPattern(for: dept) + "[ -]?0*"
            + NSRegularExpression.escapedPattern(for: number) + #"[ -]?(\d{3}[A-Z]?)\b"#
        return try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive])
    }

    private static let codeRegex = try! NSRegularExpression(pattern: #"\b([A-Z]{2,5})[ -]?(\d{3,4}[A-Z]?)\b"#)

    private static func idString(_ value: Any?) -> String? {
        if let string = value as? String, !string.isEmpty { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return nil
    }
}
