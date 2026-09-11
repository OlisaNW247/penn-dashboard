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

/// One registrar component of a course's Canvas footprint — a lecture, lab,
/// or recitation section — as the server resolves it from the catalog and
/// the course's own section list. This is a different, coarser thing than
/// `ClassMeeting`: a `ClassMeeting` is one weekly time slot, while a
/// `CatalogComponent` is the section-level unit Grade Watcher's exclusion
/// rule (`GradeSiteExclusion`) cares about — "is *this whole Canvas site* a
/// zero-credit or pass/fail piece of the course" — so it carries `credits`
/// and the section ids it covers rather than a schedule.
public struct CatalogComponent: Sendable, Hashable, Codable {
    /// Penn's short label for the component type — "LEC", "LAB", "REC" —
    /// the same vocabulary `ClassMeeting.activity` uses, and for the same
    /// reason kept as a raw string rather than a closed `enum`: an
    /// unrecognized future registrar code should still decode.
    public let activity: String
    /// Course units this component is worth, when the registrar publishes
    /// it separately from the course's overall credits — PHYS 0151's lab is
    /// 0 CU even though the course as a whole is 1.5. `nil`, not `0`, means
    /// "the server doesn't know," so `GradeSiteExclusion` never mistakes an
    /// absent value for an actual zero-credit component.
    public let credits: Double?
    /// Registrar section identifiers this component covers, shaped like
    /// `ClassMeeting.sectionID` ("PHYS-0151-151") so `component(forSectionID:)`
    /// can be looked up with the exact string
    /// `DocumentComponent.siteIdentityComponent(for:in:)` already builds from
    /// `catalogCode` + "-" + `CourseSummary.section`.
    public let sectionIDs: [String]

    public init(activity: String, credits: Double? = nil, sectionIDs: [String] = []) {
        self.activity = activity
        self.credits = credits
        self.sectionIDs = sectionIDs
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
    /// This course's Canvas-site-relevant components — one per lecture/lab/
    /// recitation section the registrar lists — synced so
    /// `GradeSiteExclusion` can tell a zero-credit or pass/fail Canvas site
    /// apart from the site that actually carries the grade. Decodes with
    /// `decodeIfPresent` for the same reason `meetings` and `credits` do:
    /// this field is newer than either of them, and a knowledge-base file a
    /// student's device already has on disk predates it.
    public let components: [CatalogComponent]

    public init(
        courseID: String,
        catalogCode: String,
        title: String,
        credits: Double? = nil,
        meetings: [ClassMeeting] = [],
        components: [CatalogComponent] = []
    ) {
        self.courseID = courseID
        self.catalogCode = catalogCode
        self.title = title
        self.credits = credits
        self.meetings = meetings
        self.components = components
    }

    private enum CodingKeys: String, CodingKey {
        case courseID, catalogCode, title, credits, meetings, components
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        courseID = try container.decode(String.self, forKey: .courseID)
        catalogCode = try container.decode(String.self, forKey: .catalogCode)
        title = try container.decode(String.self, forKey: .title)
        credits = try container.decodeIfPresent(Double.self, forKey: .credits)
        meetings = try container.decodeIfPresent([ClassMeeting].self, forKey: .meetings) ?? []
        components = try container.decodeIfPresent([CatalogComponent].self, forKey: .components) ?? []
    }

    /// The component whose `sectionIDs` names this section, or `nil` when
    /// the server hasn't resolved one (an older catalog sync, or a section
    /// the registrar's own component list doesn't cover). Exact match, not
    /// a suffix match like `DocumentComponent.siteIdentityComponent`'s
    /// `ClassMeeting` lookup — `sectionIDs` is expected to hold the full
    /// registrar id, not a bare section token, so callers build the same
    /// full string (`catalogCode` + "-" + section) before calling this.
    public func component(forSectionID sectionID: String) -> CatalogComponent? {
        components.first { $0.sectionIDs.contains(sectionID) }
    }
}
