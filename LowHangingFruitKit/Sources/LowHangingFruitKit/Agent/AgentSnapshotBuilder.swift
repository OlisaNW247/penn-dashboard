import Foundation

/// What the phone uploads to `agent-snapshot` and so the most an agent can
/// ever learn about the student's own state
/// (docs/AGENT_CONNECTION_RESEARCH_2026-11-08.md §7). The field set is closed
/// on purpose: no grade, score, points, name, email or submission content has
/// a field here, and the server refuses a body that carries one. The test
/// suite pins the exact key sets.
///
/// `dueAt` and `url` are always written, as explicit nulls when absent. The
/// server's validator accepts an absent key as well; the stricter reading is
/// what is sent.
public struct AgentSnapshot: Codable, Equatable, Sendable {
    public struct Course: Codable, Equatable, Sendable {
        public var courseID: String
        public var code: String
        public var name: String
        public init(courseID: String, code: String, name: String) {
            self.courseID = courseID; self.code = code; self.name = name
        }
    }

    public struct WorkItem: Codable, Equatable, Sendable {
        public var id: String
        public var course: String
        public var title: String
        public var kind: Assignment.Kind
        public var dueAt: Date?
        public var done: Bool
        public var noSubmission: Bool
        public var url: String?
        public var source: String
        /// Canvas's own ids, so the server can fetch the assignment's
        /// description. Digits only; nil for Gradescope and manual work.
        public var canvasAssignmentID: String?
        public var canvasCourseID: String?
        public init(id: String, course: String, title: String, kind: Assignment.Kind,
                    dueAt: Date?, done: Bool, noSubmission: Bool, url: String?, source: String,
                    canvasAssignmentID: String? = nil, canvasCourseID: String? = nil) {
            self.id = id; self.course = course; self.title = title; self.kind = kind
            self.dueAt = dueAt; self.done = done; self.noSubmission = noSubmission
            self.url = url; self.source = source
            self.canvasAssignmentID = canvasAssignmentID; self.canvasCourseID = canvasCourseID
        }

        enum CodingKeys: String, CodingKey {
            case id, course, title, kind, dueAt, done, noSubmission, url, source
            case canvasAssignmentID, canvasCourseID
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            course = try c.decode(String.self, forKey: .course)
            title = try c.decode(String.self, forKey: .title)
            kind = try c.decodeSyncKind(forKey: .kind)
            dueAt = try c.decodeSyncDateIfPresent(forKey: .dueAt)
            done = try c.decode(Bool.self, forKey: .done)
            noSubmission = try c.decode(Bool.self, forKey: .noSubmission)
            url = try c.decodeIfPresent(String.self, forKey: .url)
            source = try c.decode(String.self, forKey: .source)
            canvasAssignmentID = try? c.decodeIfPresent(String.self, forKey: .canvasAssignmentID)
            canvasCourseID = try? c.decodeIfPresent(String.self, forKey: .canvasCourseID)
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(course, forKey: .course)
            try c.encode(title, forKey: .title)
            try c.encode(kind.rawValue, forKey: .kind)
            try c.encode(dueAt.map(SyncDate.string), forKey: .dueAt)
            try c.encode(done, forKey: .done)
            try c.encode(noSubmission, forKey: .noSubmission)
            try c.encode(url, forKey: .url)
            try c.encode(source, forKey: .source)
            try c.encode(canvasAssignmentID, forKey: .canvasAssignmentID)
            try c.encode(canvasCourseID, forKey: .canvasCourseID)
        }
    }

    public struct ManualItem: Codable, Equatable, Sendable {
        public var id: String
        public var course: String
        public var title: String
        public var dueAt: Date?
        public var repeatsWeekly: Bool
        public init(id: String, course: String, title: String, dueAt: Date?, repeatsWeekly: Bool) {
            self.id = id; self.course = course; self.title = title
            self.dueAt = dueAt; self.repeatsWeekly = repeatsWeekly
        }

        enum CodingKeys: String, CodingKey { case id, course, title, dueAt, repeatsWeekly }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            course = try c.decode(String.self, forKey: .course)
            title = try c.decode(String.self, forKey: .title)
            dueAt = try c.decodeSyncDateIfPresent(forKey: .dueAt)
            repeatsWeekly = try c.decode(Bool.self, forKey: .repeatsWeekly)
        }
        public func encode(to encoder: Encoder) throws {
            var c = encoder.container(keyedBy: CodingKeys.self)
            try c.encode(id, forKey: .id)
            try c.encode(course, forKey: .course)
            try c.encode(title, forKey: .title)
            try c.encode(dueAt.map(SyncDate.string), forKey: .dueAt)
            try c.encode(repeatsWeekly, forKey: .repeatsWeekly)
        }
    }

    public var courses: [Course]
    public var workList: [WorkItem]
    public var manual: [ManualItem]

    public init(courses: [Course], workList: [WorkItem], manual: [ManualItem]) {
        self.courses = courses; self.workList = workList; self.manual = manual
    }

    /// Dates are written by the items themselves (`SyncDate`: UTC, millisecond
    /// ISO 8601 with a `Z`); keys are sorted so the byte size is stable.
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func decoder() -> JSONDecoder { JSONDecoder() }
}

/// Cuts the phone's work list into the snapshot, applying the server's rules
/// first so a body the server would refuse never leaves the phone.
public enum AgentSnapshotBuilder {
    public static let maxCourses = 60
    public static let maxWork = 2000
    public static let maxManual = 500
    public static let maxBytes = 1_000_000
    static let maxTitle = 300
    static let maxCode = 40

    public static func build(
        courses: [AgentSnapshot.Course],
        work: [SyncSnapshot.WorkItem],
        noSubmission: (String) -> Bool,
        manual: [AgentSnapshot.ManualItem],
        courseIDByCode: (String) -> String? = { _ in nil }
    ) -> AgentSnapshot {
        let outCourses = courses.compactMap { course -> AgentSnapshot.Course? in
            let id = String(course.courseID.prefix(40))
            guard !id.isEmpty, id.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
            let code = clip(course.code, maxCode)
            guard !code.isEmpty else { return nil }
            let name = clip(course.name, 200)
            return .init(courseID: id, code: code, name: name.isEmpty ? code : name)
        }

        let items = work.compactMap { item -> AgentSnapshot.WorkItem? in
            let title = clip(item.title, maxTitle)
            let course = clip(item.course, maxCode)
            let source = clip(item.source, maxCode)
            guard !item.id.isEmpty, item.id.utf16.count <= 200,
                  !title.isEmpty, !course.isEmpty, !source.isEmpty else { return nil }
            var assignmentID: String?
            var courseID: String?
            var link = item.url.flatMap { acceptableLink($0) ? $0 : nil }
            // Only Canvas rows: a Gradescope URL has its own /courses/ and
            // /assignments/ ids, a different id space.
            if item.source == Assignment.Source.canvas.rawValue
                || item.source == Assignment.Source.canvasModules.rawValue {
                if let raw = item.url {
                    assignmentID = digits(Assignment.canvasAssignmentID(inURL: raw))
                    courseID = digits(courseIDFromURL(raw))
                }
                if courseID == nil { courseID = digits(courseIDByCode(item.course)) }
                if let raw = item.url, let a = assignmentID, let c = courseID,
                   let host = URL(string: raw).flatMap({ $0.scheme == "https" ? $0.host : nil }),
                   !raw.lowercased().contains("/feeds/calendars/") {
                    let canonical = "https://\(host)/courses/\(c)/assignments/\(a)"
                    if acceptableLink(canonical) { link = canonical }
                }
            }
            return .init(
                id: item.id, course: course, title: title, kind: item.kind, dueAt: item.dueAt,
                done: item.done, noSubmission: noSubmission(item.id),
                url: link, source: source,
                canvasAssignmentID: assignmentID, canvasCourseID: courseID)
        }
        // Open items first, soonest due first, undated last; then done items
        // the same way. The cap keeps what an agent is most likely asked about.
        let ordered = items.sorted { a, b in
            if a.done != b.done { return !a.done }
            switch (a.dueAt, b.dueAt) {
            case let (x?, y?): return x == y ? a.id < b.id : x < y
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.id < b.id
            }
        }

        let outManual = manual.compactMap { item -> AgentSnapshot.ManualItem? in
            let title = clip(item.title, maxTitle)
            guard !item.id.isEmpty, item.id.utf16.count <= 200, !title.isEmpty else { return nil }
            return .init(id: item.id, course: clip(item.course, maxCode), title: title,
                         dueAt: item.dueAt, repeatsWeekly: item.repeatsWeekly)
        }

        return AgentSnapshot(
            courses: Array(outCourses.prefix(maxCourses)),
            workList: Array(ordered.prefix(maxWork)),
            manual: Array(outManual.prefix(maxManual)))
    }

    /// The encoded length, so the caller can refuse to send over `maxBytes`
    /// (the server's cap is 1,048,576). Zero when encoding fails.
    public static func byteSize(_ snapshot: AgentSnapshot) -> Int {
        (try? AgentSnapshot.encoder().encode(snapshot).count) ?? 0
    }

    /// A Canvas course link or nothing. A Canvas calendar feed URL
    /// (`/feeds/calendars/user_<token>.ics`) is a bearer credential: whoever
    /// holds it reads the student's calendar with no login. So such a URL is
    /// set to nil (the item stays), as is anything the server would refuse
    /// anyway (not https, userinfo, a `user_` token, over 2,000 characters).
    static func acceptableLink(_ raw: String) -> Bool {
        guard raw.utf16.count <= 2000, let url = URL(string: raw), url.scheme == "https" else { return false }
        let lowered = raw.lowercased()
        if lowered.contains("/feeds/calendars/") { return false }
        if lowered.range(of: "user_[a-z0-9]{8,}", options: .regularExpression) != nil { return false }
        guard let parts = URLComponents(string: raw), parts.user == nil, parts.password == nil else { return false }
        return parts.path.contains("/courses/")
    }

    /// `include_contexts=course_<id>` in the query, else `/courses/<id>`.
    static func courseIDFromURL(_ raw: String) -> String? {
        for pattern in [#"include_contexts=course_(\d+)"#, #"/courses/(\d+)"#] {
            if let r = raw.range(of: pattern, options: .regularExpression) {
                return raw[r].split(whereSeparator: { !$0.isNumber }).last.map(String.init)
            }
        }
        return nil
    }

    /// Digits only, at most 20 characters, else nil.
    static func digits(_ text: String?) -> String? {
        guard let text, !text.isEmpty, text.count <= 20,
              text.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return text
    }

    /// The server counts UTF-16 code units; clip on a character boundary
    /// without going over.
    static func clip(_ text: String, _ limit: Int) -> String {
        guard text.utf16.count > limit else { return text }
        var out = ""
        var used = 0
        for ch in text {
            let n = String(ch).utf16.count
            if used + n > limit { break }
            out.append(ch); used += n
        }
        return out
    }
}
