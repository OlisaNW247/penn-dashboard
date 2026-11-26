import Foundation
import Testing
@testable import LowHangingFruitKit

@Suite("Assignment attachment planner")
struct AssignmentAttachmentPlannerTests {
    private static let now = Date(timeIntervalSince1970: 1_800_000_000)
    private static let day: TimeInterval = 86_400
    private static let host = "canvas.upenn.edu"

    private func assignment(_ id: String, course: String = "1", due: Date?, files: [String],
                            host: String = AssignmentAttachmentPlannerTests.host,
                            updated: Date? = AssignmentAttachmentPlannerTests.now.addingTimeInterval(-86_400)) -> CourseDocument {
        let lines = files.map { "Problem set: https://\(host)/courses/\(course)/files/\($0)/download?wrap=1" }
        return CourseDocument(
            courseID: course, course: "CIS 1", kind: .assignment, sourceID: id, title: "A\(id)",
            url: URL(string: "https://\(Self.host)/courses/\(course)/assignments/\(id)"),
            text: "Due: x\nDo it.\n" + lines.joined(separator: "\n"), updatedAt: updated, dueAt: due)
    }

    private func plan(_ docs: [CourseDocument], attempts: [String: AssignmentAttachmentAttempt] = [:], limit: Int = 20) -> [String] {
        AssignmentAttachmentPlanner.plan(documents: docs, now: Self.now, attempts: attempts, limit: limit).map(\.fileID)
    }

    @Test("nil due, future, and just-past (under 7 days) qualify; a semester-old one does not")
    func dueWindow() {
        let n = Self.now
        let docs = [
            assignment("1", due: nil, files: ["11"]),
            assignment("2", due: n.addingTimeInterval(3 * Self.day), files: ["12"]),
            assignment("3", due: n.addingTimeInterval(-6 * Self.day), files: ["13"]),
            assignment("4", due: n.addingTimeInterval(-8 * Self.day), files: ["14"]),
            assignment("5", due: n.addingTimeInterval(-120 * Self.day), files: ["15"]),
        ]
        #expect(Set(plan(docs)) == ["11", "12", "13"])
    }

    @Test("exactly seven days ago still qualifies")
    func boundary() {
        let d = assignment("1", due: Self.now.addingTimeInterval(-7 * Self.day), files: ["11"])
        #expect(plan([d]) == ["11"])
    }

    @Test("only assignment documents are read")
    func kindsOnly() {
        let page = CourseDocument(courseID: "1", course: "C", kind: .page, sourceID: "p",
                                  title: "p", url: URL(string: "https://canvas.upenn.edu/courses/1/pages/p"),
                                  text: "x: https://canvas.upenn.edu/courses/1/files/77", updatedAt: Self.now, dueAt: nil)
        #expect(plan([page]).isEmpty)
    }

    @Test("only same-host files with digits are taken; folders and other hosts are not")
    func parsing() {
        let doc = CourseDocument(
            courseID: "1", course: "C", kind: .assignment, sourceID: "a", title: "a",
            url: URL(string: "https://canvas.upenn.edu/courses/1/assignments/a"),
            text: """
            A: https://canvas.upenn.edu/courses/1/files/101?wrap=1
            B: https://canvas.upenn.edu/files/102/download
            C: https://canvas.upenn.edu/courses/1/files/folder/x
            D: https://other.example.com/courses/1/files/103
            E: https://canvas.upenn.edu/courses/1/pages/files-101
            F: https://canvas.upenn.edu/courses/1/files/101
            """, updatedAt: Self.now, dueAt: nil)
        #expect(plan([doc]) == ["101", "102"])
    }

    @Test("an id already held as a file document is skipped, by source id or by url")
    func alreadyHeld() {
        let held1 = CourseDocument(courseID: "1", course: "C", kind: .file, sourceID: "11", title: "t",
                                   url: nil, text: String(repeating: "x", count: 60))
        let held2 = CourseDocument(courseID: "1", course: "C", kind: .file, sourceID: "zzz", title: "t",
                                   url: URL(string: "https://canvas.upenn.edu/courses/1/files/12"),
                                   text: String(repeating: "x", count: 60))
        let a = assignment("1", due: nil, files: ["11", "12", "13"])
        #expect(plan([a, held1, held2]) == ["13"])
    }

    @Test("an attempt inside 24 hours blocks; an older one does not")
    func attempts() {
        let a = assignment("1", due: nil, files: ["11", "12"])
        let attempts = [
            "11": AssignmentAttachmentAttempt(date: Self.now.addingTimeInterval(-23 * 3600), kind: .failed),
            "12": AssignmentAttachmentAttempt(date: Self.now.addingTimeInterval(-25 * 3600), kind: .failed),
        ]
        #expect(plan([a], attempts: attempts) == ["12"])
    }

    @Test("a no-text outcome backs off seven days, a failure one day")
    func noTextBackoff() {
        let a = assignment("1", due: nil, files: ["11", "12", "13"])
        let n = Self.now
        let attempts = [
            "11": AssignmentAttachmentAttempt(date: n.addingTimeInterval(-3 * Self.day), kind: .noText),
            "12": AssignmentAttachmentAttempt(date: n.addingTimeInterval(-8 * Self.day), kind: .noText),
            "13": AssignmentAttachmentAttempt(date: n.addingTimeInterval(-3 * Self.day), kind: .failed),
        ]
        #expect(plan([a], attempts: attempts) == ["12", "13"])
    }

    @Test("an attempt stored as a plain number reads as failed; the new format round-trips")
    func attemptStorage() {
        let legacy = AssignmentAttachmentAttempt.decode(1_700_000_000.0)
        #expect(legacy?.kind == .failed)
        #expect(legacy?.date == Date(timeIntervalSince1970: 1_700_000_000))
        let a = AssignmentAttachmentAttempt(date: Date(timeIntervalSince1970: 5), kind: .noText)
        #expect(AssignmentAttachmentAttempt.decode(a.encoded) == a)
        #expect(AssignmentAttachmentAttempt.decode("junk") == nil)
    }

    @Test("an undated assignment needs an updatedAt within 60 days")
    func undatedFreshness() {
        let n = Self.now
        let fresh = assignment("1", due: nil, files: ["11"], updated: n.addingTimeInterval(-59 * Self.day))
        let stale = assignment("2", due: nil, files: ["12"], updated: n.addingTimeInterval(-61 * Self.day))
        let unknown = assignment("3", due: nil, files: ["13"], updated: nil)
        let datedStale = assignment("4", due: n.addingTimeInterval(Self.day), files: ["14"], updated: n.addingTimeInterval(-300 * Self.day))
        #expect(Set(plan([fresh, stale, unknown, datedStale])) == ["11", "14"])
    }

    @Test("only this course's files and bare /files/ paths; users, groups and other courses are out")
    func pathShapes() {
        let doc = CourseDocument(
            courseID: "1", course: "C", kind: .assignment, sourceID: "a", title: "a",
            url: URL(string: "https://canvas.upenn.edu/courses/1/assignments/a"),
            text: """
            A: https://canvas.upenn.edu/courses/1/files/201
            B: https://canvas.upenn.edu/courses/2/files/202
            C: https://canvas.upenn.edu/users/5/files/203
            D: https://canvas.upenn.edu/groups/5/files/204
            E: https://canvas.upenn.edu/files/205/download
            F: https://canvas.upenn.edu/courses/1/modules/files/206
            """, updatedAt: Self.now, dueAt: nil)
        #expect(plan([doc]) == ["201", "205"])
    }

    @Test("at most the limit, soonest-due assignment first, undated last")
    func limitAndOrder() {
        let n = Self.now
        let late = assignment("late", due: n.addingTimeInterval(9 * Self.day), files: ["3"])
        let soon = assignment("soon", due: n.addingTimeInterval(1 * Self.day), files: ["1", "2"])
        let none = assignment("none", due: nil, files: ["4"])
        #expect(plan([late, none, soon]) == ["1", "2", "3", "4"])
        #expect(plan([late, none, soon], limit: 3) == ["1", "2", "3"])
        let many = assignment("m", due: nil, files: (100..<140).map(String.init))
        #expect(plan([many]).count == 20)
    }

    @Test("a file linked from two assignments is planned once, under the sooner")
    func sharedFile() {
        let a = assignment("a", due: Self.now.addingTimeInterval(Self.day), files: ["9"])
        let b = assignment("b", due: Self.now.addingTimeInterval(2 * Self.day), files: ["9"])
        let out = AssignmentAttachmentPlanner.plan(documents: [b, a], now: Self.now, attempts: [:])
        #expect(out.count == 1)
        #expect(out[0].assignmentSourceID == "a")
        #expect(out[0].courseID == "1")
    }

    @Test("a document with no url has no host, so no ids")
    func noHost() {
        let d = CourseDocument(courseID: "1", course: "C", kind: .assignment, sourceID: "a", title: "a",
                               url: nil, text: "x: https://canvas.upenn.edu/files/5", updatedAt: Self.now)
        #expect(plan([d]).isEmpty)
    }
}
