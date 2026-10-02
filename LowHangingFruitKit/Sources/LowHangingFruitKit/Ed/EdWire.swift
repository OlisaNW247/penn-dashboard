import Foundation

/// Wire models for the slice of Ed Discussion's (undocumented, community-
/// reverse-engineered) JSON API that LHF reads: `GET /api/user` for the
/// student's enrolments and `GET /api/courses/<id>/threads` for a course's
/// posts. Only the fields the ingest pipeline actually uses are declared;
/// everything else Ed sends (vote counts, view counts, flags, ...) is ignored
/// by `Decodable`, so a field Ed adds tomorrow cannot break a decode.
///
/// **Why every optional is `decodeIfPresent` and the `Bool`s default to
/// false.** This API is not a published contract. Ed has changed which fields
/// appear on a thread depending on type and role before, and a hard `decode`
/// of a field that is merely absent would throw away a whole page of
/// threads over one missing flag. A missing flag is read as the *safe*
/// value: not pinned, not endorsed, and *private* when `is_private` is
/// missing, which is why the filter in `EdThreadFilter` treats unknown as
/// "do not keep".
///
/// **Why explicit `CodingKeys` and no `.convertFromSnakeCase`.** The
/// strategy would silently rename `user_id` to `userId` rather than the
/// `userID` this codebase spells, and it also rewrites keys inside any
/// nested payload we later decode with the same decoder. Spelling each key
/// out is a few lines and cannot drift.

public struct EdUserResponse: Decodable, Sendable {
    public let courses: [EdEnrollment]

    public init(courses: [EdEnrollment]) {
        self.courses = courses
    }
}

/// One entry of `/api/user`'s `courses` array: the course plus the
/// student's role in it. `role` is optional because Ed omits it for some
/// archived enrolments; the app never needs it to *read* threads, only to
/// choose which courses to look at.
public struct EdEnrollment: Decodable, Sendable {
    public let course: EdCourse
    public let role: EdRole?

    public init(course: EdCourse, role: EdRole? = nil) {
        self.course = course
        self.role = role
    }
}

public struct EdCourse: Decodable, Sendable, Equatable {
    public let id: Int
    /// Ed's course code, as the instructor typed it ("CIS 2400", "CIS2400",
    /// sometimes with a section: "CIS 2400-001"). Not a stable key; see
    /// `EdCourseMatcher` for how it is compared with Canvas's.
    public let code: String
    public let name: String
    /// Ed's `year` and `session` are free-text strings ("2026", "Fall").
    public let year: String?
    public let session: String?
    public let status: String?

    public init(id: Int, code: String, name: String, year: String? = nil, session: String? = nil, status: String? = nil) {
        self.id = id
        self.code = code
        self.name = name
        self.year = year
        self.session = session
        self.status = status
    }

    private enum CodingKeys: String, CodingKey {
        case id, code, name, year, session, status
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        code = try c.decode(String.self, forKey: .code)
        name = try c.decode(String.self, forKey: .name)
        year = try c.decodeIfPresent(String.self, forKey: .year)
        session = try c.decodeIfPresent(String.self, forKey: .session)
        status = try c.decodeIfPresent(String.self, forKey: .status)
    }
}

public struct EdRole: Decodable, Sendable, Equatable {
    public let role: String

    public init(role: String) {
        self.role = role
    }
}

public struct EdThreadsResponse: Decodable, Sendable {
    public let threads: [EdThread]
    /// The authors of `threads`, side-loaded by Ed. This is the only place the
    /// threads endpoint says who is staff, which is why the filter needs it.
    /// Absent is read as empty, i.e. every author unknown, which the filter
    /// treats as a student and drops (announcements and pinned posts are
    /// still kept, since neither depends on the author).
    public let users: [EdThreadUser]

    public init(threads: [EdThread], users: [EdThreadUser] = []) {
        self.threads = threads
        self.users = users
    }

    private enum CodingKeys: String, CodingKey {
        case threads, users
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        threads = try c.decode([EdThread].self, forKey: .threads)
        users = try c.decodeIfPresent([EdThreadUser].self, forKey: .users) ?? []
    }
}

public struct EdThreadUser: Decodable, Sendable, Equatable {
    public let id: Int
    /// Decoded for completeness only. Nothing downstream may put an author's
    /// name into pooled course material; see `EdThreadFilter`.
    public let name: String?
    /// Ed's per-course role for this user: "admin", "staff", "student", ...
    public let courseRole: String?

    public init(id: Int, name: String? = nil, courseRole: String? = nil) {
        self.id = id
        self.name = name
        self.courseRole = courseRole
    }

    private enum CodingKeys: String, CodingKey {
        case id, name
        case courseRole = "course_role"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        courseRole = try c.decodeIfPresent(String.self, forKey: .courseRole)
    }
}

public struct EdThread: Decodable, Sendable, Equatable {
    public let id: Int
    /// The author's Ed user id. Ed can omit it on anonymous posts, so a
    /// missing or null `user_id` decodes as `0`, an id that is never in the
    /// `users` array: an unknown author, which the filter treats as a
    /// student. A sentinel rather than an optional so the type stays a plain
    /// `Int` for callers; the failure it guards against is one anonymous
    /// thread throwing away the other 99 on its page.
    public let userID: Int
    public let courseID: Int
    /// "post", "question" or "announcement".
    public let type: String
    public let title: String
    /// Ed's XML document (see `EdDocumentText`). The authoritative body.
    public let document: String?
    /// Older HTML-ish rendering of the same body; only a fallback.
    public let content: String?
    public let category: String?
    public let subcategory: String?
    public let isPinned: Bool
    public let isPrivate: Bool
    public let isEndorsed: Bool
    public let isAnonymous: Bool
    public let createdAt: Date
    public let updatedAt: Date?
    public let number: Int?
    public let replyCount: Int?

    public init(
        id: Int,
        userID: Int = 0,
        courseID: Int = 0,
        type: String = "post",
        title: String = "",
        document: String? = nil,
        content: String? = nil,
        category: String? = nil,
        subcategory: String? = nil,
        isPinned: Bool = false,
        isPrivate: Bool = false,
        isEndorsed: Bool = false,
        isAnonymous: Bool = false,
        createdAt: Date = Date(timeIntervalSince1970: 0),
        updatedAt: Date? = nil,
        number: Int? = nil,
        replyCount: Int? = nil
    ) {
        self.id = id
        self.userID = userID
        self.courseID = courseID
        self.type = type
        self.title = title
        self.document = document
        self.content = content
        self.category = category
        self.subcategory = subcategory
        self.isPinned = isPinned
        self.isPrivate = isPrivate
        self.isEndorsed = isEndorsed
        self.isAnonymous = isAnonymous
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.number = number
        self.replyCount = replyCount
    }

    private enum CodingKeys: String, CodingKey {
        case id
        case userID = "user_id"
        case courseID = "course_id"
        case type, title, document, content, category, subcategory
        case isPinned = "is_pinned"
        case isPrivate = "is_private"
        case isEndorsed = "is_endorsed"
        case isAnonymous = "is_anonymous"
        case createdAt = "created_at"
        case updatedAt = "updated_at"
        case number
        case replyCount = "reply_count"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(Int.self, forKey: .id)
        userID = try c.decodeIfPresent(Int.self, forKey: .userID) ?? 0
        courseID = try c.decode(Int.self, forKey: .courseID)
        type = try c.decode(String.self, forKey: .type)
        title = try c.decode(String.self, forKey: .title)
        document = try c.decodeIfPresent(String.self, forKey: .document)
        content = try c.decodeIfPresent(String.self, forKey: .content)
        category = try c.decodeIfPresent(String.self, forKey: .category)
        subcategory = try c.decodeIfPresent(String.self, forKey: .subcategory)
        isPinned = try c.decodeIfPresent(Bool.self, forKey: .isPinned) ?? false
        // The one flag whose safe default is `true`: `isPrivate` is the first
        // thing `EdThreadFilter.decide` checks, and a thread that arrived
        // without the flag must read as private so it is dropped, never
        // uploaded on the strength of being pinned or staff-written. Ed
        // sends the flag today; this is for the day it doesn't.
        isPrivate = try c.decodeIfPresent(Bool.self, forKey: .isPrivate) ?? true
        isEndorsed = try c.decodeIfPresent(Bool.self, forKey: .isEndorsed) ?? false
        isAnonymous = try c.decodeIfPresent(Bool.self, forKey: .isAnonymous) ?? false
        createdAt = try c.decode(Date.self, forKey: .createdAt)
        updatedAt = try c.decodeIfPresent(Date.self, forKey: .updatedAt)
        number = try c.decodeIfPresent(Int.self, forKey: .number)
        replyCount = try c.decodeIfPresent(Int.self, forKey: .replyCount)
    }
}

/// The one decoder every Ed response goes through.
public enum EdJSON {
    /// A decoder whose date strategy accepts the shapes Ed actually sends.
    ///
    /// Ed is an Australian company and its timestamps carry a UTC offset
    /// (`2026-03-05T14:21:55.123456+11:00`), often with fractional seconds
    /// that run to microseconds, and sometimes without them. Foundation's
    /// built-in `.iso8601` strategy accepts neither fractional seconds nor
    /// (reliably) the longer ones, and a single thread whose date fails
    /// would throw away its whole page. So this parses by hand-normalizing
    /// first (truncate the fraction to milliseconds, make a colon-less
    /// offset `+1100` into `+11:00`, accept a space for the `T`) and then
    /// asks `ISO8601DateFormatter`, with fractional seconds first and
    /// without as the fallback.
    ///
    /// The formatters are created per call, not cached: `ISO8601DateFormatter`
    /// is not `Sendable`, the strategy closure is `@Sendable`, and a page is
    /// at most a hundred threads, so the allocation does not matter.
    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let raw = try container.decode(String.self)
            guard let date = parseDate(raw) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "Unrecognized Ed timestamp: \(raw)"
                )
            }
            return date
        }
        return decoder
    }

    /// Exposed (rather than private) so the tests can pin the formats
    /// without building a whole JSON body for each.
    public static func parseDate(_ raw: String) -> Date? {
        var text = raw.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return nil }

        if let space = text.firstIndex(of: " "), text.contains(":") {
            text.replaceSubrange(space...space, with: "T")
        }

        // Split off the zone designator: "Z" or a trailing +hh:mm / +hhmm /
        // +hh, found by scanning back from the end for the sign.
        var zone = ""
        if text.hasSuffix("Z") || text.hasSuffix("z") {
            zone = "Z"
            text.removeLast()
        } else if let signIndex = text.lastIndex(where: { $0 == "+" || $0 == "-" }),
                  text.distance(from: text.startIndex, to: signIndex) > 10 {
            let sign = String(text[signIndex])
            let rawOffset = String(text[text.index(after: signIndex)...])
            text = String(text[..<signIndex])
            let digits = rawOffset.filter { $0 != ":" }
            guard digits.count == 2 || digits.count == 4, digits.allSatisfy(\.isNumber) else { return nil }
            let hours = String(digits.prefix(2))
            let minutes = digits.count == 4 ? String(digits.suffix(2)) : "00"
            zone = sign + hours + ":" + minutes
        } else {
            // No zone at all: treat as UTC rather than guessing a local one.
            zone = "Z"
        }

        // Split the fraction off and cut it to three digits.
        let fraction: String?
        if let dot = text.firstIndex(of: ".") {
            let digits = text[text.index(after: dot)...]
            guard !digits.isEmpty, digits.allSatisfy(\.isNumber) else { return nil }
            fraction = String(digits.prefix(3)).padding(toLength: 3, withPad: "0", startingAt: 0)
            text = String(text[..<dot])
        } else {
            fraction = nil
        }

        if let fraction {
            let formatter = ISO8601DateFormatter()
            formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
            if let date = formatter.date(from: text + "." + fraction + zone) { return date }
        }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: text + zone)
    }
}
