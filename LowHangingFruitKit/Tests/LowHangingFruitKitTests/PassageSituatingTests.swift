import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// Step 4 of `docs/TREE_CONTEXT_RESEARCH_2026-11-02.md` Part 3 (2026-11-14):
/// every excerpt label says how old its passage is, in the student's zone, and
/// every passage is indexed under its course, kind, title and date. Nothing
/// here reads the clock or the network.
@Suite("Passage situating: labels and index line")
struct PassageSituatingTests {
    private static let newYork = TimeZone(identifier: "America/New_York")!

    private static func utc(_ iso: String) -> Date {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: iso)!
    }

    private static func eastern(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 12) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = newYork
        var components = DateComponents()
        components.year = year; components.month = month; components.day = day; components.hour = hour
        return calendar.date(from: components)!
    }

    private static let asked = eastern(2026, 11, 2, 13)

    private static func document(
        _ kind: CourseDocument.Kind, title: String = "Notes", text: String = "Zeppelin notes.",
        updatedAt: Date?, course: String = "CIS 2620", id: String = "d"
    ) -> CourseDocument {
        CourseDocument(courseID: "1", course: course, kind: kind, sourceID: id, title: title, url: nil, text: text, updatedAt: updatedAt)
    }

    private static func label(_ document: CourseDocument, askedAt: Date = asked, zone: TimeZone = newYork) -> String? {
        PassageSituating.dateLabel(for: document, askedAt: askedAt, in: zone)
    }

    // MARK: - The label

    @Test("a post from today, yesterday, three days ago and twelve days ago")
    func relativeAges() {
        #expect(Self.label(Self.document(.announcement, updatedAt: Self.eastern(2026, 11, 2, 9))) == "posted 2026-11-02 (today)")
        #expect(Self.label(Self.document(.announcement, updatedAt: Self.eastern(2026, 11, 1, 22))) == "posted 2026-11-01 (yesterday)")
        #expect(Self.label(Self.document(.announcement, updatedAt: Self.eastern(2026, 10, 30, 8))) == "posted 2026-10-30 (3 days ago)")
        #expect(Self.label(Self.document(.announcement, updatedAt: Self.eastern(2026, 10, 21))) == "posted 2026-10-21 (12 days ago)")
    }

    @Test("a syllabus, page, module, assignment, file, website and home page say updated, not posted")
    func updatedKinds() {
        let updated = Self.eastern(2026, 10, 2)
        for kind in [CourseDocument.Kind.syllabus, .page, .module, .assignment, .file, .website, .home] {
            #expect(Self.label(Self.document(kind, updatedAt: updated)) == "updated 2026-10-02 (31 days ago)", "\(kind)")
        }
    }

    @Test("an undated document prints no date at all")
    func undated() {
        #expect(Self.label(Self.document(.syllabus, updatedAt: nil)) == nil)
        #expect(Self.label(Self.document(.announcement, updatedAt: nil)) == nil)
    }

    @Test("the zone matters: 03:00 UTC on the 2nd is yesterday in New York at 20:00 UTC on the 2nd")
    func zoneMatters() {
        let post = Self.document(.ed, updatedAt: Self.utc("2026-11-02T03:00:00Z"))
        let askedAt = Self.utc("2026-11-02T20:00:00Z")
        #expect(Self.label(post, askedAt: askedAt, zone: Self.newYork) == "posted 2026-11-01 (yesterday)")
        #expect(Self.label(post, askedAt: askedAt, zone: .gmt) == "posted 2026-11-02 (today)")
    }

    @Test("the label reaches the excerpt line, between the kind and the title, in the context's zone")
    func labelInExcerptLine() throws {
        let post = Self.document(.announcement, title: "Room change", text: "Zeppelin lecture moves to Moore 216.", updatedAt: Self.eastern(2026, 11, 1, 22))
        let syllabus = Self.document(.syllabus, title: "Course information", text: "Zeppelin policy: late work loses ten percent.", updatedAt: Self.eastern(2026, 10, 2), id: "s")
        let context = AssistantContext(
            courseCodes: ["CIS 2620"], contextDocument: "doc", askedAt: Self.asked, timeZone: Self.newYork,
            knowledge: CourseKnowledgeBase(
                courses: [CourseSummary(courseID: "1", code: "CIS 2620", name: "CIS 2620 Operating Systems", url: nil)],
                documents: [post, syllabus]
            )
        )
        let excerpts = BackendAssistantResponder.retrievedExcerpts(question: "zeppelin", context: context)
        #expect(excerpts.contains("CIS 2620 · announcement · posted 2026-11-01 (yesterday) · \"Room change\": "))
        #expect(excerpts.contains("CIS 2620 · syllabus · updated 2026-10-02 (31 days ago) · \"Course information\": "))
    }

    // MARK: - The index line

    private static func search(_ documents: [CourseDocument]) -> CourseSearch {
        CourseSearch(knowledge: CourseKnowledgeBase(documents: documents), embeddingProvider: SentenceEmbeddingProvider { nil })
    }

    private static let lateBody = "Late work loses ten percent per day, and nothing is accepted after the fifth day."

    @Test("a query naming only the course and the kind finds that course's syllabus, whose body never says so")
    func courseAndKindFindThePassage() throws {
        let cisSyllabus = Self.document(.syllabus, title: "Course information", text: Self.lateBody, updatedAt: nil, course: "CIS 2620", id: "cis-s")
        let mathSyllabus = Self.document(.syllabus, title: "Course information", text: Self.lateBody, updatedAt: nil, course: "MATH 1400", id: "math-s")
        let cisPage = Self.document(.page, title: "Course information", text: Self.lateBody, updatedAt: nil, course: "CIS 2620", id: "cis-p")
        let hits = Self.search([mathSyllabus, cisPage, cisSyllabus]).search("cis 2620 syllabus late policy", limit: 3, perDocument: 1)
        let first = try #require(hits.first)
        #expect(first.document.id == cisSyllabus.id)
    }

    @Test("the stored document is byte-identical after indexing")
    func storedTextUntouched() {
        let original = Self.document(.syllabus, title: "Course information", text: Self.lateBody, updatedAt: Self.eastern(2026, 10, 2))
        let search = Self.search([original])
        let stored = search.knowledge.documents[0]
        #expect(stored.text == original.text)
        #expect(stored.title == original.title)
        #expect(stored.contentHash == original.contentHash)
        #expect(PassageChunker.passages(for: stored).map(\.text) == PassageChunker.passages(for: original).map(\.text))
    }

    @Test("a query of body words still ranks the passage that says them (the situating line adds, it does not replace)")
    func bodyWordQueryStillWorks() throws {
        let late = Self.document(.page, title: "Policies", text: Self.lateBody, updatedAt: nil, id: "late")
        let other = Self.document(.page, title: "Policies", text: "Office hours are held in the lab every Thursday afternoon.", updatedAt: nil, id: "oh")
        let hits = Self.search([other, late]).search("late work percent", limit: 2, perDocument: 1)
        #expect(hits.first?.document.id == late.id)
    }

    @Test("the index line is course, kind, title and an Eastern date when dated; no date when not")
    func indexLineShape() {
        let dated = Self.document(.ed, title: "Room change", updatedAt: Self.eastern(2026, 11, 1, 22))
        #expect(PassageSituating.indexLine(for: dated) == "CIS 2620 ed discussion \"Room change\" 2026-11-01")
        let undated = Self.document(.syllabus, title: "Course information", updatedAt: nil)
        #expect(PassageSituating.indexLine(for: undated) == "CIS 2620 syllabus \"Course information\"")
    }
}
