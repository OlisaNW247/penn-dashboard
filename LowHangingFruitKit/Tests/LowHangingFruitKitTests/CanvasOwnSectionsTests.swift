import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// The student's own section, read from Canvas for a site whose name has no
/// number (the owner's "ACCT 1010 (Hail) - Fall 2026", 2026-11-15). All JSON
/// and section names are invented in the shapes Canvas documents.
@Suite("Canvas own sections")
struct CanvasOwnSectionsTests {
    private func data(_ s: String) -> Data { Data(s.utf8) }

    @Test("the courses list decodes ids as numbers or strings and keeps section names")
    func decodes() {
        let page = CanvasOwnSections.parse(data("""
        [{"id": 1946774, "name": "ACCT 1010 (Hail) - Fall 2026",
          "sections": [{"id": 1, "name": "ACCT 1010-002 2026C", "enrollment_role": "StudentEnrollment"}]},
         {"id": "1936566", "sections": []},
         {"id": 7},
         {"name": "no id"}]
        """))
        #expect(page == [
            .init(courseID: "1946774", sectionNames: ["ACCT 1010-002 2026C"]),
            .init(courseID: "1936566", sectionNames: []),
            .init(courseID: "7", sectionNames: []),
        ])
        #expect(CanvasOwnSections.parse(data("{\"errors\": []}")) == nil)
    }

    @Test("a section named for this course gives its number, in each separator shape",
          arguments: ["ACCT 1010-002 2026C", "ACCT 1010 002", "ACCT-1010-002", "ACCT1010002 2026C", "acct 1010-002"])
    func readsNumber(name: String) {
        #expect(CanvasOwnSections.sectionNumber(courseCode: "ACCT 1010", sectionNames: [name]) == "002")
    }

    @Test("a term code after the course number is never read as a section")
    func termIsNotASection() {
        #expect(CanvasOwnSections.sectionNumber(courseCode: "ACCT 1010", sectionNames: ["ACCT 1010 2026C"]) == nil)
        #expect(CanvasOwnSections.sectionNumber(courseCode: "ACCT 1010", sectionNames: ["ACCT 1010 (Hail) - Fall 2026"]) == nil)
    }

    @Test("a cross-listed twin's number is not this course's")
    func crossListIgnored() {
        #expect(CanvasOwnSections.sectionNumber(courseCode: "ACCT 1010", sectionNames: ["OIDD 1010-004"]) == nil)
        #expect(CanvasOwnSections.sectionNumber(
            courseCode: "ACCT 1010", sectionNames: ["OIDD 1010-004", "ACCT 1010-002"]) == "002")
    }

    @Test("two different numbers settle nothing; the same number twice is one")
    func ambiguity() {
        #expect(CanvasOwnSections.sectionNumber(
            courseCode: "PHYS 0151", sectionNames: ["PHYS 0151-001", "PHYS 0151-201"]) == nil)
        #expect(CanvasOwnSections.sectionNumber(
            courseCode: "PHYS 0151", sectionNames: ["PHYS 0151-001 2026C", "PHYS 0151-001"]) == "001")
    }

    @Test("Penn's old three-digit number meets the four-digit code")
    func leadingZero() {
        #expect(CanvasOwnSections.sectionNumber(courseCode: "PHYS 0151", sectionNames: ["PHYS 151-401"]) == "401")
    }

    @Test("the read asks for active courses with sections and follows a same-host next page")
    func fetchPages() async {
        let base = URL(string: "https://canvas.example.edu")!
        let requested = Locked<[URL]>([])
        let courses = await CanvasOwnSections.fetch(baseURL: base) { url in
            requested.mutate { $0.append(url) }
            let first = requested.value.count == 1
            let link = first ? "<https://canvas.example.edu/api/v1/courses?page=2>; rel=\"next\"" : ""
            let http = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: ["Link": link])!
            let body = first
                ? "[{\"id\": 1, \"sections\": [{\"name\": \"ACCT 1010-002\"}]}]"
                : "[{\"id\": 2, \"sections\": []}]"
            return (Data(body.utf8), http)
        }
        #expect(courses?.map(\.courseID) == ["1", "2"])
        let first = requested.value.first?.absoluteString ?? ""
        #expect(first.contains("api/v1/courses"))
        #expect(first.contains("include%5B%5D=sections") || first.contains("include[]=sections"))
        #expect(first.contains("enrollment_state=active"))
    }

    @Test("a failed read is nil, so the caller keeps what it knew")
    func fetchFails() async {
        let base = URL(string: "https://canvas.example.edu")!
        let courses = await CanvasOwnSections.fetch(baseURL: base) { url in
            (Data("<html>login</html>".utf8), HTTPURLResponse(url: url, statusCode: 401, httpVersion: nil, headerFields: nil)!)
        }
        #expect(courses == nil)
    }
}

/// A tiny lock for the transport closure's call log.
private final class Locked<T>: @unchecked Sendable {
    private var stored: T
    private let lock = NSLock()
    init(_ value: T) { stored = value }
    var value: T { lock.withLock { stored } }
    func mutate(_ body: (inout T) -> Void) { lock.withLock { body(&stored) } }
}

/// `canvasCourseSummaries` uses the Canvas-read number only when the site's
/// name has none. Process-wide defaults: backed up and restored.
@MainActor
@Suite("Canvas own sections reach the course summary", .serialized)
struct CanvasOwnSectionsSummaryTests {
    private static let enrolledKey = "enrolledCanvasCoursesV1"
    private static let ownKey = "canvasOwnSectionByCourseIDV1"
    private static let acctID = "1946774"
    private static let cisID = "1936566"

    private func withRestoredDefaults(_ body: () -> Void) {
        let defaults = UserDefaults.lhf
        let keys = [Self.enrolledKey, Self.ownKey, CoursePreferencesStore.storageKey]
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        defaults.removeObject(forKey: CoursePreferencesStore.storageKey)
        defaults.set([
            Self.acctID: "ACCT 1010 (Hail) - Fall 2026",
            Self.cisID: "CIS 2400-001 202630 Intro to Computer Systems",
        ], forKey: Self.enrolledKey)
        let prefs = CoursePreferencesStore()
        prefs.setCanvasCourseID("ACCT 1010", Self.acctID)
        prefs.setCanvasCourseID("CIS 2400", Self.cisID)
        body()
    }

    @Test("a site with no number in its name takes the number read from Canvas")
    func fillsMissingNumber() {
        withRestoredDefaults {
            UserDefaults.lhf.set([Self.acctID: "002"], forKey: Self.ownKey)
            let state = AppState(assignmentStore: try? AssignmentStore(inMemory: true))
            let acct = state.canvasCourseSummaries().first { $0.courseID == Self.acctID }
            #expect(acct?.section == "002")
        }
    }

    @Test("the name's own number wins over the Canvas read, and no read changes nothing")
    func nameWins() {
        withRestoredDefaults {
            UserDefaults.lhf.set([Self.cisID: "009"], forKey: Self.ownKey)
            let state = AppState(assignmentStore: try? AssignmentStore(inMemory: true))
            let summaries = state.canvasCourseSummaries()
            #expect(summaries.first { $0.courseID == Self.cisID }?.section == "001")
            #expect(summaries.first { $0.courseID == Self.acctID }?.section == nil)
        }
    }
}
