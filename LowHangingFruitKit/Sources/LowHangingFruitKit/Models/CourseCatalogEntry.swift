import Foundation

/// One scheduled meeting of a course section — a lecture, lab, recitation,
/// or similar — as Penn's course catalog records it (registrar data, not
/// anything Canvas exposes directly). The only consumer today is
/// `HeuristicAnnouncementExtractor`, which uses a course's meetings to turn
/// "before class on Thursday" into an actual clock time instead of falling
/// back to a vague end-of-day guess.
public struct ClassMeeting: Codable, Sendable, Hashable {
    /// The registrar's section identifier this meeting belongs to. Not used
    /// for anything on-device yet, but kept because a course with both a
    /// lecture and a lab section needs a way to tell "this meeting is the
    /// lecture's" from "this meeting is the lab's" beyond just `activity`,
    /// once cross-listed or multi-section courses are in play.
    public let sectionID: String
    /// Penn's own short label for the meeting type — "LEC", "LAB", "REC",
    /// "SEM". Kept as the server's raw string rather than a closed `enum`:
    /// a registrar activity code the client doesn't recognize yet should
    /// still decode and simply lose out on "LEC preferred" tie-breaking,
    /// not fail the whole catalog entry.
    public let activity: String
    /// `Calendar` convention: 1 = Sunday … 7 = Saturday. Stored in the same
    /// numbering `Calendar.component(.weekday, from:)` produces so
    /// `HeuristicAnnouncementExtractor` can compare the two directly with no
    /// translation step to get wrong.
    public let weekday: Int
    /// Minutes after midnight the meeting starts.
    public let startMinutes: Int
    /// Minutes after midnight the meeting ends.
    public let endMinutes: Int

    public init(sectionID: String, activity: String, weekday: Int, startMinutes: Int, endMinutes: Int) {
        self.sectionID = sectionID
        self.activity = activity
        self.weekday = weekday
        self.startMinutes = startMinutes
        self.endMinutes = endMinutes
    }
}

/// One course from Penn's course catalog, synced down from the backend
/// (`backend/PROTOCOL.md`'s sync manifest) so the on-device announcement
/// extractor can resolve "before class" phrasing without ever talking to
/// Canvas or the registrar itself.
///
/// `credits` and `meetings` decode with `decodeIfPresent` rather than
/// through the ordinary `Codable` synthesis a struct like this would
/// otherwise get for free: this type also lives inside `CourseKnowledgeBase`,
/// which is persisted to disk, and a future server rev that adds a catalog
/// field the client doesn't send yet (or a client rev that reads a catalog
/// entry written by an older client that never populated `meetings`) must
/// not fail to decode the whole entry — that would look like "the catalog
/// sync silently stopped working" rather than what it is, a single optional
/// field being absent.
public struct CourseCatalogEntry: Codable, Sendable, Hashable, Identifiable {
    /// The Canvas course id — the same value as `CourseSummary.courseID` —
    /// doubling as `Identifiable`'s `id` so this type drops straight into a
    /// SwiftUI `List` and so `CourseKnowledgeBase.mergeCatalog` has an
    /// unambiguous upsert key.
    public var id: String { courseID }

    public let courseID: String
    /// The registrar's own course code spelling, e.g. "PHYS-151" — not
    /// necessarily identical to Canvas's "PHYS 151" (`CourseCode.parse`'s
    /// output), which is exactly why `CourseKnowledgeBase.catalogEntry(
    /// forCourseCode:)` normalizes both before comparing.
    public let catalogCode: String
    public let title: String
    public let credits: Double?
    public let meetings: [ClassMeeting]

    public init(
        courseID: String,
        catalogCode: String,
        title: String,
        credits: Double? = nil,
        meetings: [ClassMeeting] = []
    ) {
        self.courseID = courseID
        self.catalogCode = catalogCode
        self.title = title
        self.credits = credits
        self.meetings = meetings
    }

    private enum CodingKeys: String, CodingKey {
        case courseID, catalogCode, title, credits, meetings
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        courseID = try container.decode(String.self, forKey: .courseID)
        catalogCode = try container.decode(String.self, forKey: .catalogCode)
        title = try container.decode(String.self, forKey: .title)
        credits = try container.decodeIfPresent(Double.self, forKey: .credits)
        meetings = try container.decodeIfPresent([ClassMeeting].self, forKey: .meetings) ?? []
    }
}
