import Foundation

/// The unified shape a dashboard item takes once normalized from any source
/// (Canvas ICS, Canvas web scrape, Gradescope, Ed). Source-agnostic by design.
public struct Assignment: Sendable, Hashable, Identifiable {
    public enum Source: String, Sendable, Codable, Hashable {
        case canvas
        case gradescope
        case ed
        case manual
        case canvasSuggestion
    }

    /// What kind of thing this calendar entry represents. Canvas's ICS feed
    /// mixes graded assignments with lectures, office hours, etc. — `kind`
    /// lets the UI filter them apart.
    public enum Kind: String, Sendable, Codable, Hashable {
        case assignment
        case quiz
        case discussion
        case event       // lectures, office hours, exam dates without submission
        case other
    }

    /// Stable identity across sources: (source, sourceID).
    public var id: String { "\(source.rawValue):\(sourceID)" }

    public let source: Source
    public let sourceID: String
    public let kind: Kind
    public let course: String
    public let title: String
    public let dueAt: Date?
    public let url: URL?
    public let submitted: Bool

    public var isAssignment: Bool {
        kind == .assignment
    }

    public init(
        source: Source,
        sourceID: String,
        kind: Kind,
        course: String,
        title: String,
        dueAt: Date?,
        url: URL?,
        submitted: Bool = false
    ) {
        self.source = source
        self.sourceID = sourceID
        self.kind = kind
        self.course = course
        self.title = title
        self.dueAt = dueAt
        self.url = url
        self.submitted = submitted
    }
}
