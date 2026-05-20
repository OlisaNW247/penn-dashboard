import Foundation

/// The unified shape an assignment takes once normalized from any source
/// (Canvas ICS, Canvas web scrape, Gradescope, Ed). Source-agnostic by design.
public struct Assignment: Sendable, Hashable, Identifiable {
    public enum Source: String, Sendable, Codable, Hashable {
        case canvas
        case gradescope
        case ed
    }

    /// Stable identity across sources: (source, sourceID).
    public var id: String { "\(source.rawValue):\(sourceID)" }

    public let source: Source
    public let sourceID: String
    public let course: String
    public let title: String
    public let dueAt: Date?
    public let url: URL?
    public let submitted: Bool

    public init(
        source: Source,
        sourceID: String,
        course: String,
        title: String,
        dueAt: Date?,
        url: URL?,
        submitted: Bool = false
    ) {
        self.source = source
        self.sourceID = sourceID
        self.course = course
        self.title = title
        self.dueAt = dueAt
        self.url = url
        self.submitted = submitted
    }
}
