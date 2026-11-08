import Foundation
import Testing
@testable import LowHangingFruitKit

@Suite struct AgentSnapshotBuilderTests {
    private let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    private func work(_ id: String, due: Date? = nil, done: Bool = false, title: String = "HW",
                      url: String? = nil, course: String = "PHYS 0151") -> SyncSnapshot.WorkItem {
        .init(id: id, course: course, title: title, dueAt: due, kind: .assignment,
              source: "canvas", url: url, done: done)
    }

    private func build(_ items: [SyncSnapshot.WorkItem], courses: [AgentSnapshot.Course] = [],
                       manual: [AgentSnapshot.ManualItem] = []) -> AgentSnapshot {
        AgentSnapshotBuilder.build(courses: courses, work: items, noSubmission: { $0 == "ns" }, manual: manual)
    }

    private func object(_ snapshot: AgentSnapshot) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: AgentSnapshot.encoder().encode(snapshot)) as? [String: Any])
    }

    @Test func fieldSetIsClosed() throws {
        let snap = build(
            [work("a", due: t0, url: "https://canvas.upenn.edu/courses/1/assignments/2")],
            courses: [.init(courseID: "12", code: "PHYS 0151", name: "Physics")],
            manual: [.init(id: "m", course: "", title: "Read", dueAt: nil, repeatsWeekly: false)])
        let root = try object(snap)
        #expect(Set(root.keys) == ["courses", "workList", "manual"])
        let course = try #require((root["courses"] as? [[String: Any]])?.first)
        #expect(Set(course.keys) == ["courseID", "code", "name"])
        let item = try #require((root["workList"] as? [[String: Any]])?.first)
        #expect(Set(item.keys) == ["id", "course", "title", "kind", "dueAt", "done", "noSubmission", "url", "source"])
        let manual = try #require((root["manual"] as? [[String: Any]])?.first)
        #expect(Set(manual.keys) == ["id", "course", "title", "dueAt", "repeatsWeekly"])
        // Absent values are explicit nulls.
        #expect(manual["dueAt"] is NSNull)
    }

    @Test func feedURLIsNulledAndItemKept() {
        let feed = "https://canvas.upenn.edu/feeds/calendars/user_abcdefghijkl.ics"
        let snap = build([work("a", url: feed), work("b", url: "http://canvas.upenn.edu/courses/1"),
                          work("c", url: "https://canvas.upenn.edu/courses/1/assignments/2"),
                          work("d", url: "https://canvas.upenn.edu/courses/1/feeds/calendars/x")])
        let byID = Dictionary(uniqueKeysWithValues: snap.workList.map { ($0.id, $0.url) })
        #expect(snap.workList.count == 4)
        #expect(byID["a"] == .some(nil))
        #expect(byID["b"] == .some(nil))
        #expect(byID["c"] == .some("https://canvas.upenn.edu/courses/1/assignments/2"))
        #expect(byID["d"] == .some(nil))
    }

    @Test func noSubmissionComesFromTheClosure() {
        let snap = build([work("ns"), work("other")])
        #expect(snap.workList.first { $0.id == "ns" }?.noSubmission == true)
        #expect(snap.workList.first { $0.id == "other" }?.noSubmission == false)
    }

    @Test func capsLengths() {
        let long = String(repeating: "x", count: 500)
        let snap = build([work("a", title: long, course: long)],
                         courses: [.init(courseID: "1", code: long, name: long)])
        #expect(snap.workList[0].title.count == 300)
        #expect(snap.workList[0].course.count == 40)
        #expect(snap.courses[0].code.count == 40)
        #expect(snap.courses[0].name.count == 200)
    }

    @Test func capsCounts() {
        let courses = (0..<80).map { AgentSnapshot.Course(courseID: "\($0)", code: "C\($0)", name: "n") }
        let items = (0..<2100).map { work("w\($0)") }
        let manual = (0..<600).map { AgentSnapshot.ManualItem(id: "m\($0)", course: "", title: "t", dueAt: nil, repeatsWeekly: false) }
        let snap = build(items, courses: courses, manual: manual)
        #expect(snap.courses.count == 60)
        #expect(snap.workList.count == 2000)
        #expect(snap.manual.count == 500)
    }

    @Test func ordersSoonestThenUndatedThenDone() {
        let snap = build([
            work("done", due: t0, done: true),
            work("undated"),
            work("late", due: t0.addingTimeInterval(100)),
            work("soon", due: t0),
        ])
        #expect(snap.workList.map(\.id) == ["soon", "late", "undated", "done"])
    }

    @Test func capKeepsOpenItemsOverDone() {
        let items = (0..<2000).map { work("d\($0)", due: t0, done: true) } + [work("open")]
        let snap = build(items)
        #expect(snap.workList.first?.id == "open")
        #expect(snap.workList.count == 2000)
    }

    @Test func roundTripsTheServersShape() throws {
        let json = """
        {"courses":[{"courseID":"123","code":"PHYS 0151","name":"Physics"}],
         "workList":[{"id":"a","course":"PHYS 0151","title":"HW 1","kind":"quiz","dueAt":"2026-11-08T17:00:00.000Z",
                      "done":false,"noSubmission":true,"url":null,"source":"canvas"}],
         "manual":[{"id":"m","course":"","title":"Read","dueAt":null,"repeatsWeekly":true}]}
        """
        let snap = try AgentSnapshot.decoder().decode(AgentSnapshot.self, from: Data(json.utf8))
        #expect(snap.workList[0].kind == .quiz)
        #expect(snap.workList[0].dueAt == Date(timeIntervalSince1970: 1_794_157_200))
        #expect(snap.workList[0].url == nil)
        #expect(snap.manual[0].repeatsWeekly)
        let again = try AgentSnapshot.decoder().decode(AgentSnapshot.self, from: AgentSnapshot.encoder().encode(snap))
        #expect(again == snap)
    }

    @Test func datesEncodeWithZ() throws {
        let snap = build([work("a", due: t0)])
        let item = try #require((try object(snap)["workList"] as? [[String: Any]])?.first)
        let due = try #require(item["dueAt"] as? String)
        #expect(due.hasSuffix("Z"))
        #expect(due == "2027-01-15T08:00:00.000Z")
    }

    @Test func byteSizeIsTheEncodedLength() throws {
        let snap = build([work("a")])
        #expect(AgentSnapshotBuilder.byteSize(snap) == (try AgentSnapshot.encoder().encode(snap)).count)
    }
}
