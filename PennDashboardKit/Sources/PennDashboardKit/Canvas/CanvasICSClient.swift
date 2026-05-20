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

    public func fetchAssignments() async throws -> [Assignment] {
        let (data, response) = try await session.data(from: feedURL)
        guard let http = response as? HTTPURLResponse else { throw Error.notHTTP }
        guard (200..<300).contains(http.statusCode) else {
            throw Error.http(status: http.statusCode)
        }
        return Self.assignments(from: data)
    }

    /// Exposed as a pure function so tests don't need the network.
    public static func assignments(from icsData: Data) -> [Assignment] {
        ICSParser.parse(icsData).map(Self.normalize)
    }

    static func normalize(_ event: ICSParser.Event) -> Assignment {
        let (title, course) = splitCourse(from: event.summary)
        return Assignment(
            source: .canvas,
            sourceID: event.uid,
            course: course,
            title: title,
            dueAt: event.dtStart,
            url: event.url,
            submitted: false  // ICS feed doesn't expose submission status
        )
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
