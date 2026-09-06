import Foundation

/// Where an answer came from. The on-device answerer attaches one per
/// document it drew on; the ask screen renders them as citation chips so the
/// student can check the claim against Canvas before acting on it.
public struct SourceReference: Codable, Sendable, Hashable, Identifiable {
    public var id: String { "\(course)|\(title)|\(url?.absoluteString ?? "")" }
    public let title: String
    public let course: String
    public let kind: String
    public let url: URL?

    public init(title: String, course: String, kind: String, url: URL?) {
        self.title = title
        self.course = course
        self.kind = kind
        self.url = url
    }

    public init(document: CourseDocument) {
        self.init(title: document.title, course: document.course, kind: document.kind.label, url: document.url)
    }
}
