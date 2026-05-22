import Foundation

/// Fetches and parses a Canvas iCalendar feed into normalized `Assignment` values.
/// The feed URL is per-user and lives in: Canvas → Calendar → "Calendar Feed".
public struct CanvasICSClient: Sendable {
    public enum Error: Swift.Error, Sendable {
        case http(status: Int)
        case notHTTP
    }

    private let feedURL: URL
    private let session: URLSession

    public init(feedURL: URL, session: URLSession = .shared) {
        self.feedURL = feedURL
        self.session = session
    }

    public func fetchCalendarItems() async throws -> [Assignment] {
        let (data, response) = try await session.data(from: feedURL)
        guard let http = response as? HTTPURLResponse else { throw Error.notHTTP }
        guard (200..<300).contains(http.statusCode) else {
            throw Error.http(status: http.statusCode)
        }
        return Self.calendarItems(from: data)
    }

    public func fetchAssignments() async throws -> [Assignment] {
        try await fetchCalendarItems().filter(\.isAssignment)
    }

    /// Exposed as a pure function so tests don't need the network.
    public static func calendarItems(from icsData: Data) -> [Assignment] {
        ICSParser.parse(icsData).map(Self.normalize)
    }

    public static func assignments(from icsData: Data) -> [Assignment] {
        calendarItems(from: icsData).filter(\.isAssignment)
    }

    static func normalize(_ event: ICSParser.Event) -> Assignment {
        let (title, course) = splitCourse(from: event.summary)
        return Assignment(
            source: .canvas,
            sourceID: event.uid,
            kind: classify(event),
            course: course,
            title: title,
            dueAt: event.dtStart,
            url: event.url,
            submitted: false  // ICS feed doesn't expose submission status
        )
    }

    static func classify(_ event: ICSParser.Event) -> Assignment.Kind {
        if let kind = classifyFromURL(event.url) {
            return kind
        }

        let uid = event.uid.lowercased()
        if uid.contains("assignment") {
            return .assignment
        }
        if uid.contains("quiz") {
            return .quiz
        }
        if uid.contains("discussion") {
            return .discussion
        }
        if uid.contains("calendar") || uid.contains("event") {
            return .event
        }
        return .other
    }

    private static func classifyFromURL(_ url: URL?) -> Assignment.Kind? {
        guard let url else { return nil }

        let path = url.path.lowercased()
        if path.contains("/assignments/") {
            return .assignment
        }
        if path.contains("/quizzes/") {
            return .quiz
        }
        if path.contains("/discussion_topics/") || path.contains("/discussions/") {
            return .discussion
        }
        if path.contains("/calendar_events/") {
            return .event
        }

        return nil
    }

    /// Canvas appends "[Course Name]" to most SUMMARYs; split it off.
    static func splitCourse(from summary: String) -> (title: String, course: String) {
        guard let openIdx = summary.lastIndex(of: "["),
              summary.hasSuffix("]") else {
            return (summary.trimmingCharacters(in: .whitespaces), "(unknown course)")
        }
        let courseStart = summary.index(after: openIdx)
        let courseEnd = summary.index(before: summary.endIndex)
        let course = String(summary[courseStart..<courseEnd]).trimmingCharacters(in: .whitespaces)
        let title = String(summary[..<openIdx]).trimmingCharacters(in: .whitespaces)
        return (title, course)
    }
}
