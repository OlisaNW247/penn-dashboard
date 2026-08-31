import Foundation
import Testing
@testable import LowHangingFruitKit

/// Fixture-based decoding tests for `CanvasAnnouncementsClient` — no network
/// calls. Every test drives either `CanvasAnnouncementsClient.decodeAnnouncements`
/// (the pure, network-free seam the networked `fetchAnnouncements` also
/// calls) or `plainText(fromHTML:)` directly, with realistic Canvas JSON.
/// Mirrors the fixture-string idiom `CanvasGradesClientTests` uses — no
/// URLProtocol, no mocks.
@Suite("Canvas announcements client")
struct CanvasAnnouncementsClientTests {

    private func data(_ json: String) -> Data { Data(json.utf8) }

    private func iso(_ string: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)!
    }

    private func isoFractional(_ string: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: string)!
    }

    // MARK: - Two realistic announcements

    private static let twoAnnouncementsJSON = """
    [
      {
        "id": 5001,
        "context_code": "course_12345",
        "title": "Midterm info",
        "message": "<p>The midterm is on <strong>Friday</strong>.</p><p>Bring a calculator &amp; two pencils.</p>",
        "posted_at": "2026-02-01T12:30:00.123Z",
        "html_url": "https://canvas.upenn.edu/courses/12345/discussion_topics/5001"
      },
      {
        "id": 5002,
        "context_code": "course_67890",
        "title": "Office hours moved",
        "message": "Office hours moved to<br>Thursday 3-5pm.",
        "posted_at": "2026-02-02T09:00:00Z",
        "html_url": "https://canvas.upenn.edu/courses/67890/discussion_topics/5002"
      }
    ]
    """

    @Test("two realistic announcements decode with plain-text messages and parsed dates (with and without fractional seconds)")
    func decodesTwoAnnouncements() throws {
        let announcements = try CanvasAnnouncementsClient.decodeAnnouncements(json: data(Self.twoAnnouncementsJSON))
        #expect(announcements.count == 2)

        let first = try #require(announcements.first { $0.id == "5001" })
        #expect(first.courseID == "12345")
        #expect(first.title == "Midterm info")
        #expect(first.message == "The midterm is on Friday.\nBring a calculator & two pencils.")
        #expect(first.postedAt == isoFractional("2026-02-01T12:30:00.123Z"))
        #expect(first.url?.absoluteString == "https://canvas.upenn.edu/courses/12345/discussion_topics/5001")

        let second = try #require(announcements.first { $0.id == "5002" })
        #expect(second.courseID == "67890")
        #expect(second.title == "Office hours moved")
        #expect(second.message == "Office hours moved to\nThursday 3-5pm.")
        #expect(second.postedAt == iso("2026-02-02T09:00:00Z"))
    }

    // MARK: - XSSI prefix

    @Test("XSSI-prefixed announcements payload decodes after stripping while(1);")
    func decodesXSSIPrefixedPayload() throws {
        let prefixed = "while(1);" + Self.twoAnnouncementsJSON
        let announcements = try CanvasAnnouncementsClient.decodeAnnouncements(json: data(prefixed))
        #expect(announcements.count == 2)
    }

    // MARK: - Missing context_code is skipped, not fatal

    private static let missingContextCodeJSON = """
    [
      {"id": 7001, "title": "No context", "message": "<p>Hi</p>", "posted_at": "2026-01-01T00:00:00Z", "html_url": "https://canvas.upenn.edu/x"},
      {"id": 7002, "context_code": "course_222", "title": "Has context", "message": "<p>Bye</p>", "posted_at": "2026-01-02T00:00:00Z", "html_url": "https://canvas.upenn.edu/y"}
    ]
    """

    @Test("an element with no context_code is skipped; the rest of the page survives")
    func skipsElementMissingContextCode() throws {
        let announcements = try CanvasAnnouncementsClient.decodeAnnouncements(json: data(Self.missingContextCodeJSON))
        #expect(announcements.count == 1)
        #expect(announcements.first?.id == "7002")
        #expect(announcements.first?.courseID == "222")
    }

    // MARK: - One structurally malformed element doesn't sink the batch

    private static let oneMalformedElementJSON = """
    [
      "unexpectedly a bare string, not an object",
      {"id": 9002, "context_code": "course_444", "title": "Survives", "message": "<p>ok</p>", "posted_at": "2026-01-04T00:00:00Z", "html_url": "https://canvas.upenn.edu/w"}
    ]
    """

    @Test("one structurally malformed array element (not a JSON object at all) is dropped without sinking the rest of the page")
    func oneMalformedElementDoesNotSinkBatch() throws {
        let announcements = try CanvasAnnouncementsClient.decodeAnnouncements(json: data(Self.oneMalformedElementJSON))
        #expect(announcements.count == 1)
        #expect(announcements.first?.id == "9002")
    }

    // MARK: - Garbage JSON is a distinct, catchable error, not a crash

    @Test("garbage JSON throws the .decodingFailed case, never crashes")
    func garbageJSONThrowsDecodingFailed() {
        #expect(throws: CanvasAnnouncementsClient.Error.self) {
            _ = try CanvasAnnouncementsClient.decodeAnnouncements(json: data("not json at all"))
        }
        do {
            _ = try CanvasAnnouncementsClient.decodeAnnouncements(json: data("not json at all"))
            Issue.record("expected decodeAnnouncements to throw on garbage JSON")
        } catch let error as CanvasAnnouncementsClient.Error {
            guard case .decodingFailed = error else {
                Issue.record("expected .decodingFailed, got \(error)")
                return
            }
        } catch {
            Issue.record("expected a CanvasAnnouncementsClient.Error, got \(error)")
        }
    }

    // MARK: - Null message

    private static let nullMessageJSON = """
    [{"id": 8001, "context_code": "course_333", "title": "No body", "message": null, "posted_at": "2026-01-03T00:00:00Z", "html_url": "https://canvas.upenn.edu/z"}]
    """

    @Test("null message decodes to an empty string, not a crash")
    func nullMessageYieldsEmptyString() throws {
        let announcements = try CanvasAnnouncementsClient.decodeAnnouncements(json: data(Self.nullMessageJSON))
        #expect(announcements.count == 1)
        #expect(announcements.first?.message == "")
    }

    // MARK: - plainText(fromHTML:)

    @Test("plainText strips arbitrary tags that carry no useful text content")
    func plainTextStripsTags() {
        let html = "<div><strong>Bold</strong> and <a href=\"https://example.com\">a link</a>.</div>"
        let text = CanvasAnnouncementsClient.plainText(fromHTML: html)
        #expect(!text.contains("<"))
        #expect(!text.contains(">"))
        #expect(text.contains("Bold and a link."))
    }

    @Test("plainText turns <br> and </p> into newlines")
    func plainTextNewlinesFromBrAndClosingP() {
        let html = "<p>Line one</p><p>Line two<br>Line three</p>"
        let text = CanvasAnnouncementsClient.plainText(fromHTML: html)
        #expect(text == "Line one\nLine two\nLine three")
    }

    @Test("plainText decodes the common HTML entities, with &amp; decoded last")
    func plainTextDecodesEntities() {
        let html = "Tom &amp; Jerry &lt;3 &quot;friends&quot; &#39;forever&#39;&nbsp;ok"
        let text = CanvasAnnouncementsClient.plainText(fromHTML: html)
        #expect(text == "Tom & Jerry <3 \"friends\" 'forever' ok")
    }

    @Test("plainText collapses runs of 3+ newlines to a single blank line and trims the ends")
    func plainTextCollapsesNewlines() {
        let html = "<p>A</p><p></p><p></p><p>B</p>"
        let text = CanvasAnnouncementsClient.plainText(fromHTML: html)
        #expect(text == "A\n\nB")
    }

    @Test("plainText of an empty string is an empty string")
    func plainTextEmptyInputIsEmptyOutput() {
        #expect(CanvasAnnouncementsClient.plainText(fromHTML: "") == "")
    }
}
