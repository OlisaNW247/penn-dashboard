import Foundation

/// The registrar's weekly schedule for one asked day, as a sentence the phone
/// computes (`docs/TREE_CONTEXT_RESEARCH_2026-11-02.md`, Part 3 step 5).
///
/// **Why the phone writes it.** On 2026-11-02 the model was handed a sections
/// sentence for the whole week and had to find Monday in it while an Ed post
/// said there were no lectures. Code can decide which meetings fall on the
/// asked weekday, so the model is given only that, labelled as the registrar's
/// and sitting beside the newest posts, with the authority rule after both
/// (`BackendAssistantResponder.meetingAuthorityRule`). The wrong fix is to
/// state a verdict ("the class meets") here: the schedule is a default that a
/// post can override, and only the model reads the post.
///
/// **Pure.** Minutes become clock text by arithmetic, never through a `Date`
/// or a formatter, so no locale or zone can change a digit. The weekday name
/// is taken from a `Calendar` in the student's zone but spelled from a fixed
/// table, so the words are the same on every machine.
public enum WeeklyScheduleLine {
    /// One course the line may speak about.
    public struct Entry: Sendable, Equatable {
        public let code: String
        public let meetings: [ClassMeeting]
        /// The registrar section tokens ("001") of the Canvas sites the
        /// student is enrolled in for this code. Empty when unknown.
        public let studentSections: Set<String>

        public init(code: String, meetings: [ClassMeeting], studentSections: Set<String>) {
            self.code = code
            self.meetings = meetings
            self.studentSections = studentSections
        }
    }

    static let weekdayNames = ["", "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"]

    private static let activityWords: [String: String] = [
        "LEC": "lecture", "REC": "recitation", "LAB": "lab", "SEM": "seminar", "STU": "studio",
    ]

    /// The last dash-separated token of a registrar section id
    /// ("PHYS-0151-151" -> "151"), uppercased for comparison.
    static func sectionToken(_ sectionID: String) -> String {
        (sectionID.split(separator: "-").last.map(String.init) ?? sectionID).uppercased()
    }

    /// `10:15–11:44 AM`, or `11:00 AM–12:15 PM` when the two ends differ in
    /// meridiem. Out-of-range minutes wrap around midnight.
    static func timeRange(startMinutes: Int, endMinutes: Int) -> String {
        func parts(_ minutes: Int) -> (clock: String, meridiem: String) {
            let m = ((minutes % 1440) + 1440) % 1440
            let hour24 = m / 60
            let minute = m % 60
            let hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12
            return ("\(hour12):\(minute < 10 ? "0" : "")\(minute)", hour24 < 12 ? "AM" : "PM")
        }
        let start = parts(startMinutes)
        let end = parts(endMinutes)
        if start.meridiem == end.meridiem { return "\(start.clock)–\(end.clock) \(end.meridiem)" }
        return "\(start.clock) \(start.meridiem)–\(end.clock) \(end.meridiem)"
    }

    /// The entries for the courses a question is about: every course of
    /// `courseIDs` (grouped by display code, since a lecture and a lab site
    /// share one), or every course when `courseIDs` is nil. A course the
    /// catalog has nothing for is left out.
    public static func entries(knowledge: CourseKnowledgeBase, courseIDs: Set<String>?) -> [Entry] {
        var sectionsByCode: [String: Set<String>] = [:]
        var codes: [String] = []
        var seenCodes = Set<String>()
        for course in knowledge.courses {
            if let courseIDs, !courseIDs.contains(course.courseID) { continue }
            let key = CourseMatcher.normalize(course.code)
            if seenCodes.insert(key).inserted { codes.append(course.code) }
            if let section = course.section, !section.isEmpty {
                sectionsByCode[key, default: []].insert(section.uppercased())
            }
        }
        return codes.sorted().compactMap { code -> Entry? in
            guard let catalog = knowledge.catalogEntry(forCourseCode: code), !catalog.meetings.isEmpty else { return nil }
            return Entry(
                code: code,
                meetings: catalog.meetings,
                studentSections: sectionsByCode[CourseMatcher.normalize(code)] ?? []
            )
        }
    }

    /// The `Weekly schedule (registrar): ...` lines for one day, one per
    /// course; empty when there are no entries. `scoped` says the student
    /// named a course: then a course with no meeting that day gets its own
    /// "no meeting" line, which is the answer to the question. Unscoped, the
    /// courses with nothing that day stay silent and one line says so.
    public static func lines(
        entries: [Entry], day: Date, dayString: String?, timeZone: TimeZone, scoped: Bool
    ) -> [String] {
        guard !entries.isEmpty else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        calendar.locale = Locale(identifier: "en_US_POSIX")
        let weekday = calendar.component(.weekday, from: day)
        let name = weekdayNames.indices.contains(weekday) ? weekdayNames[weekday] : ""
        let abbreviation = String(name.prefix(3))
        let dateText: String
        if let dayString {
            dateText = dayString
        } else {
            let c = calendar.dateComponents([.year, .month, .day], from: day)
            func pad(_ n: Int?, _ width: Int) -> String {
                let s = String(n ?? 0)
                return String(repeating: "0", count: max(0, width - s.count)) + s
            }
            dateText = "\(pad(c.year, 4))-\(pad(c.month, 2))-\(pad(c.day, 2))"
        }
        let prefix = "Weekly schedule (registrar): "
        var out: [String] = []
        for entry in entries {
            // The student's own section(s) when the catalog lists them, so a
            // classmate's recitation is not offered as theirs; every section
            // otherwise, marked by nothing.
            let ownTokens = entry.studentSections
            let hasOwn = !ownTokens.isEmpty && entry.meetings.contains { ownTokens.contains(sectionToken($0.sectionID)) }
            let scope = hasOwn ? entry.meetings.filter { ownTokens.contains(sectionToken($0.sectionID)) } : entry.meetings
            let today = scope.filter { $0.weekday == weekday }.sorted { lhs, rhs in
                if lhs.startMinutes != rhs.startMinutes { return lhs.startMinutes < rhs.startMinutes }
                return lhs.sectionID < rhs.sectionID
            }
            if today.isEmpty {
                if scoped { out.append("\(prefix)no \(entry.code) meeting on \(name) \(dateText).") }
                continue
            }
            let parts = today.enumerated().map { index, meeting -> String in
                let word = activityWords[meeting.activity.uppercased()] ?? meeting.activity.lowercased()
                let token = sectionToken(meeting.sectionID)
                let own = hasOwn ? ", the student's section" : ""
                let lead = index == 0 ? "\(entry.code) " : ""
                let clock = timeRange(startMinutes: meeting.startMinutes, endMinutes: meeting.endMinutes)
                // TODO(room): print the meeting's room here once ClassMeeting carries one.
                return "\(lead)\(word) \(abbreviation) \(clock) (section \(token)\(own))"
            }
            out.append("\(prefix)\(parts.joined(separator: "; ")).")
        }
        if out.isEmpty && !scoped {
            out.append("\(prefix)no course has a meeting on \(name) \(dateText).")
        }
        return out
    }
}
