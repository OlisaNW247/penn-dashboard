import Foundation

/// Where a `CourseLink` was found in Canvas — the three places
/// `CourseKnowledgeCollector` looks for outbound links, plus the syllabus
/// (announcements are deliberately excluded: see the collector's header
/// comment). Stored as a plain `String` on `CourseLink` itself, rather than
/// this enum, so the wire type (`CourseLinkWire`) doesn't need its own
/// decode of a nested enum — `origin` on the wire is just the raw value.
public enum CourseLinkOrigin: String, Sendable, Hashable {
    case page
    case assignment
    case module
    case syllabus
}

/// One outbound link Canvas content pointed at, gathered so the server can
/// discover and crawl the external course website an instructor linked
/// from a page, an assignment description, a module item, or the syllabus
/// (`backend/PROTOCOL.md`'s `discover-websites`). This is the instructor's
/// own pointer to the site — the app never guesses at a course's site from
/// nothing.
public struct CourseLink: Sendable, Hashable, Codable {
    public let courseID: String
    public let href: String
    public let text: String
    public let origin: String

    public init(courseID: String, href: String, text: String, origin: String) {
        self.courseID = courseID
        self.href = href
        self.text = text
        self.origin = origin
    }

    public init(courseID: String, href: String, text: String, origin: CourseLinkOrigin) {
        self.init(courseID: courseID, href: href, text: text, origin: origin.rawValue)
    }
}
