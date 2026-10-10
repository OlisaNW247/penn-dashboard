import Foundation
import Testing
@testable import LowHangingFruitKit

/// `Assignment.sourceLinks` is the "open in canvas / open in gradescope" link on
/// an opened card. It is derived at display time from what the ledger already
/// stores, so these tests are pure: no `AppState`, no `UserDefaults`, no store.
@Suite("Source links")
struct SourceLinkTests {

    // MARK: - Helpers

    private func item(
        _ source: Assignment.Source,
        sourceID: String = "event-assignment-1@canvas.upenn.edu",
        kind: Assignment.Kind = .assignment,
        url: String?,
        linkedID: String? = nil
    ) -> Assignment {
        Assignment(
            source: source,
            sourceID: sourceID,
            kind: kind,
            course: "PHYS 151",
            title: "Problem Set 3",
            dueAt: Date(timeIntervalSince1970: 1_800_000_000),
            url: url.flatMap(URL.init(string:)),
            linkedID: linkedID
        )
    }

    private func urls(_ assignment: Assignment) -> [String] {
        assignment.sourceLinks.map(\.url.absoluteString)
    }

    // MARK: - Canvas: rebuilding the assignment page

    @Test("a calendar-shaped URL on a non-Penn host is rebuilt on that host")
    func calendarShapeRebuiltOnItsOwnHost() {
        let a = item(.canvas, url: "https://brown.instructure.com/calendar?include_contexts=course_555&month=10&year=2026#assignment_77")
        #expect(a.sourceLinks == [
            SourceLink(url: URL(string: "https://brown.instructure.com/courses/555/assignments/77")!, label: "open in canvas")
        ])
    }

    @Test("a port on the stored host survives the rebuild")
    func calendarShapeKeepsPort() {
        let a = item(.canvas, url: "https://canvas.example.edu:8443/calendar?include_contexts=course_9&month=10&year=2026#assignment_4")
        #expect(urls(a) == ["https://canvas.example.edu:8443/courses/9/assignments/4"])
    }

    @Test("a direct assignment URL is returned unchanged")
    func directAssignmentUnchanged() {
        let direct = "https://canvas.upenn.edu/courses/1925208/assignments/12345?module_item_id=9"
        #expect(urls(item(.canvas, url: direct)) == [direct])
    }

    @Test("quiz and discussion URLs are returned unchanged, never rewritten to /assignments/")
    func quizAndDiscussionNeverRewritten() {
        let quiz = "https://canvas.upenn.edu/courses/42/quizzes/7"
        let discussion = "https://canvas.upenn.edu/courses/42/discussion_topics/8"
        // Even if a stray assignment fragment rides along, the path already
        // names the object, so it wins.
        let quizWithFragment = "https://canvas.upenn.edu/courses/42/quizzes/7#assignment_99"
        #expect(urls(item(.canvas, kind: .quiz, url: quiz)) == [quiz])
        #expect(urls(item(.canvas, kind: .discussion, url: discussion)) == [discussion])
        #expect(urls(item(.canvas, kind: .quiz, url: quizWithFragment)) == [quizWithFragment])
    }

    @Test("a calendar URL with no assignment fragment falls back to itself")
    func calendarEventFallsBackToItself() {
        let eventURL = "https://canvas.upenn.edu/calendar?event_id=4242&include_contexts=course_5"
        #expect(urls(item(.canvas, kind: .event, url: eventURL)) == [eventURL])
    }

    @Test("a section-override row uses the URL fragment id, never the override UID")
    func overrideRowUsesFragmentID() {
        let a = item(
            .canvas,
            sourceID: "event-assignment-override-99@canvas.upenn.edu",
            url: "https://canvas.upenn.edu/calendar?include_contexts=course_1&month=09&year=2026#assignment_77"
        )
        #expect(urls(a) == ["https://canvas.upenn.edu/courses/1/assignments/77"])
        #expect(!urls(a).contains { $0.contains("99") })
    }

    @Test("an override row with no usable fragment never builds a link from the override id")
    func overrideRowWithoutFragmentFallsBack() {
        let stored = "https://canvas.upenn.edu/calendar?include_contexts=course_1&month=09&year=2026"
        let a = item(.canvas, sourceID: "event-assignment-override-99@canvas.upenn.edu", url: stored)
        #expect(urls(a) == [stored])
    }

    @Test("a sub-assignment fragment is a different id space and is not rebuilt")
    func subAssignmentFragmentNotRebuilt() {
        // The UID here is NOT an override UID, so `canvasAssignmentID`'s
        // unanchored `assignment-(\d+)` fallback would find "assignment-5"
        // inside "sub_assignment-5". The link must not trust it.
        let stored = "https://canvas.upenn.edu/calendar?include_contexts=course_1&month=09&year=2026#sub_assignment_5"
        let a = item(.canvas, sourceID: "event-sub_assignment-5@canvas.upenn.edu", url: stored)
        #expect(urls(a) == [stored])
    }

    @Test("an id that exists only in the ICS UID is not used to build a link")
    func uidOnlyIDIsNotUsed() {
        let stored = "https://canvas.upenn.edu/calendar?include_contexts=course_5&month=09&year=2026"
        let a = item(.canvas, sourceID: "event-assignment-88@canvas.upenn.edu", url: stored)
        #expect(urls(a) == [stored])
    }

    @Test("a module-imported assignment keeps its direct URL; one with no URL has no link")
    func canvasModulesRows() {
        let direct = "https://canvas.upenn.edu/courses/3/assignments/21"
        #expect(urls(item(.canvasModules, sourceID: "module-item-6", kind: .event, url: direct)) == [direct])
        #expect(item(.canvasModules, sourceID: "module-item-7", kind: .event, url: nil).sourceLinks.isEmpty)
    }

    // MARK: - Gradescope

    @Test("a Gradescope row with an href links to it")
    func gradescopeWithHref() {
        let href = "https://www.gradescope.com/courses/123/assignments/456/submissions/789"
        let a = item(.gradescope, sourceID: "course-123-assignment-456", url: href)
        #expect(a.sourceLinks == [SourceLink(url: URL(string: href)!, label: "open in gradescope")])
    }

    @Test("a Gradescope row with no stored URL is rebuilt from its sourceID")
    func gradescopeBuiltFromSourceID() {
        let a = item(.gradescope, sourceID: "course-123-assignment-456", url: nil)
        #expect(a.sourceLinks == [
            SourceLink(url: URL(string: "https://www.gradescope.com/courses/123/assignments/456")!, label: "open in gradescope")
        ])
    }

    @Test("GradescopeClient's course-0 placeholder builds nothing")
    func gradescopePlaceholderCourseBuildsNothing() {
        #expect(item(.gradescope, sourceID: "course-0-assignment-456", url: nil).sourceLinks.isEmpty)
        #expect(item(.gradescope, sourceID: "not-a-gradescope-id", url: nil).sourceLinks.isEmpty)
    }

    // MARK: - Pairs

    @Test("a deduplicated Canvas+Gradescope pair returns Canvas first, then Gradescope")
    func pairedItemReturnsBothInOrder() {
        let a = item(
            .canvas,
            url: "https://canvas.upenn.edu/calendar?include_contexts=course_1&month=09&year=2026#assignment_77",
            linkedID: "gradescope:course-123-assignment-456"
        )
        #expect(a.sourceLinks == [
            SourceLink(url: URL(string: "https://canvas.upenn.edu/courses/1/assignments/77")!, label: "open in canvas"),
            SourceLink(url: URL(string: "https://www.gradescope.com/courses/123/assignments/456")!, label: "open in gradescope"),
        ])
    }

    @Test("the linkedID the deduplicator really writes yields the Gradescope link")
    func mergedAssignmentLinkedIDShape() {
        let canvas = item(.canvas, url: "https://canvas.upenn.edu/courses/1/assignments/77")
        let gradescope = item(.gradescope, sourceID: "course-123-assignment-456", url: "https://www.gradescope.com/courses/123/assignments/456")
        let merged = AssignmentDeduplicator.mergedAssignment(canvas: canvas, gradescope: gradescope)
        #expect(urls(merged) == [
            "https://canvas.upenn.edu/courses/1/assignments/77",
            "https://www.gradescope.com/courses/123/assignments/456",
        ])
    }

    @Test("a pair whose Canvas URL is unusable still offers the Gradescope link")
    func pairWithoutCanvasURL() {
        let a = item(.canvas, url: nil, linkedID: "gradescope:course-123-assignment-456")
        #expect(urls(a) == ["https://www.gradescope.com/courses/123/assignments/456"])
    }

    @Test("a malformed linkedID adds no second link")
    func malformedLinkedIDIgnored() {
        let canvas = "https://canvas.upenn.edu/courses/1/assignments/77"
        #expect(urls(item(.canvas, url: canvas, linkedID: "canvas:course-123-assignment-456")) == [canvas])
        #expect(urls(item(.canvas, url: canvas, linkedID: "gradescope:course-abc-assignment-456")) == [canvas])
        #expect(urls(item(.canvas, url: canvas, linkedID: "gradescope:course-0-assignment-456")) == [canvas])
    }

    // MARK: - Announcements and sources with nothing to open

    @Test("an announcement row links to its stored Canvas URL as-is")
    func announcementRow() {
        let html = "https://canvas.upenn.edu/courses/1/discussion_topics/55"
        let a = item(.canvasAnnouncement, sourceID: "announcement-55", kind: .other, url: html)
        #expect(a.sourceLinks == [SourceLink(url: URL(string: html)!, label: "open in canvas")])
    }

    @Test("manual work, suggestions and URL-less rows have no links")
    func nothingToOpen() {
        #expect(item(.manual, sourceID: "manual-1", url: nil).sourceLinks.isEmpty)
        #expect(item(.canvasSuggestion, sourceID: "suggestion-1", url: nil).sourceLinks.isEmpty)
        #expect(item(.canvas, url: nil).sourceLinks.isEmpty)
        #expect(item(.canvasAnnouncement, sourceID: "announcement-1", kind: .other, url: nil).sourceLinks.isEmpty)
        // Even a stored URL is ignored for the sources that never show one.
        #expect(item(.manual, sourceID: "manual-2", url: "https://example.com/x").sourceLinks.isEmpty)
        #expect(item(.canvasSuggestion, sourceID: "suggestion-2", url: "https://example.com/x").sourceLinks.isEmpty)
    }

    // MARK: - Scheme and host checks

    @Test("an http URL is dropped for every source")
    func httpURLDropped() {
        #expect(item(.canvas, url: "http://canvas.upenn.edu/courses/1/assignments/2").sourceLinks.isEmpty)
        #expect(item(.canvas, url: "http://canvas.upenn.edu/calendar?include_contexts=course_1#assignment_2").sourceLinks.isEmpty)
        #expect(item(.canvasModules, sourceID: "module-item-1", url: "http://canvas.upenn.edu/courses/1/assignments/2").sourceLinks.isEmpty)
        #expect(item(.canvasAnnouncement, sourceID: "announcement-1", url: "http://canvas.upenn.edu/courses/1/discussion_topics/2").sourceLinks.isEmpty)
        #expect(item(.gradescope, sourceID: "course-1-assignment-2", url: "http://www.gradescope.com/courses/1/assignments/2").sourceLinks.isEmpty)
    }

    @Test("non-web schemes and host-less URLs are dropped")
    func nonWebSchemesDropped() {
        #expect(item(.canvas, url: "file:///etc/passwd").sourceLinks.isEmpty)
        #expect(item(.canvas, url: "javascript:alert(1)").sourceLinks.isEmpty)
        #expect(item(.canvasAnnouncement, sourceID: "announcement-1", url: "mailto:a@b.edu").sourceLinks.isEmpty)
        #expect(item(.canvas, url: "/courses/1/assignments/2").sourceLinks.isEmpty)
    }

    @Test("an uppercase HTTPS scheme is still https")
    func uppercaseSchemeAccepted() {
        #expect(!item(.canvas, url: "HTTPS://canvas.upenn.edu/courses/1/assignments/2").sourceLinks.isEmpty)
    }

    // MARK: - Persistence round trip

    @Test("a ledger row's urlString still yields the link after the round trip")
    func storedAssignmentRoundTrip() {
        let original = item(
            .canvas,
            url: "https://canvas.upenn.edu/calendar?include_contexts=course_1&month=09&year=2026#assignment_77",
            linkedID: "gradescope:course-123-assignment-456"
        )
        let row = StoredAssignment.make(from: original, now: Date(timeIntervalSince1970: 1_700_000_000))
        #expect(row.urlString == original.url?.absoluteString)
        #expect(row.assignment.sourceLinks == original.sourceLinks)
        #expect(urls(row.assignment) == [
            "https://canvas.upenn.edu/courses/1/assignments/77",
            "https://www.gradescope.com/courses/123/assignments/456",
        ])
    }

    @Test("a hand-built ledger row with only a urlString yields the link")
    func storedAssignmentFromURLString() {
        let row = StoredAssignment(
            id: "canvas:event-assignment-77@canvas.upenn.edu",
            sourceRaw: "canvas",
            sourceID: "event-assignment-77@canvas.upenn.edu",
            kindRaw: "assignment",
            course: "PHYS 151",
            title: "Problem Set 3",
            dueAt: nil,
            urlString: "https://canvas.upenn.edu/courses/5/assignments/77",
            termYear: nil,
            termSeasonRaw: nil,
            firstSeen: Date(timeIntervalSince1970: 0),
            lastSeenInFeed: Date(timeIntervalSince1970: 0)
        )
        #expect(urls(row.assignment) == ["https://canvas.upenn.edu/courses/5/assignments/77"])
    }

    // MARK: - Course id parsing (moved to the Kit)

    @Test("CanvasCourseURL reads both URL shapes and refuses non-ids")
    func courseIDParsing() {
        #expect(CanvasCourseURL.courseID(from: URL(string: "https://canvas.upenn.edu/courses/1925208/assignments/1")!) == "1925208")
        #expect(CanvasCourseURL.courseID(from: URL(string: "https://canvas.upenn.edu/calendar?include_contexts=course_42&month=07")!) == "42")
        #expect(CanvasCourseURL.courseID(from: URL(string: "https://canvas.upenn.edu/courses/new")!) == nil)
        #expect(CanvasCourseURL.courseID(from: URL(string: "https://canvas.upenn.edu/calendar?include_contexts=user_5")!) == nil)
    }
}
