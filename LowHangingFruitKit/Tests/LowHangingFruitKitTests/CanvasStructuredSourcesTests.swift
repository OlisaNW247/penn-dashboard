import Foundation
import Testing
@testable import LowHangingFruitKit

/// All JSON is invented. Dates are pinned; nothing reads the clock.
@Suite("Canvas structured sources: decoders")
struct CanvasStructuredDecoderTests {
    private func data(_ s: String) -> Data { Data(s.utf8) }
    private func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    @Test("planner items decode, including submissions:false and planner_override")
    func planner() {
        let json = """
        while(1);[
          {"plannable_type":"assignment","plannable_id":55,"course_id":7,"html_url":"/courses/7/assignments/55",
           "plannable":{"title":"PSet 3","due_at":"2026-11-10T04:59:00Z"},
           "planner_override":{"marked_complete":true,"dismissed":false},
           "submissions":{"submitted":true,"missing":false,"graded":false}},
          {"plannable_type":"planner_note","plannable_id":"9","course_id":7,
           "plannable":{"title":"Email TA","todo_date":"2026-11-12T17:00:00Z"},
           "planner_override":{"dismissed":true},"submissions":false}
        ]
        """
        let r = CanvasStructuredDecoding.decode(CanvasPlannerItem.self, fromPages: [data(json)])
        #expect(r.dropped == 0)
        #expect(r.elements.count == 2)
        #expect(r.elements[0].plannableID == "55")
        #expect(r.elements[0].courseID == "7")
        #expect(r.elements[0].markedComplete)
        #expect(r.elements[0].submitted == true)
        #expect(r.elements[0].dueAt == date("2026-11-10T04:59:00Z"))
        #expect(r.elements[1].plannableID == "9")
        #expect(r.elements[1].dismissed)
        #expect(r.elements[1].submitted == nil)
        #expect(r.elements[1].todoDate == date("2026-11-12T17:00:00Z"))
    }

    @Test("module items decode at item grain with completion and content details")
    func modules() {
        let json = """
        [{"id":1,"name":"Week 1","state":"started","unlock_at":"2026-09-01T00:00:00Z","position":2,"items":[
          {"id":11,"module_id":1,"type":"Assignment","content_id":55,"title":"PSet 3",
           "completion_requirement":{"type":"must_submit","completed":true},
           "content_details":{"due_at":"2026-11-10T04:59:00Z","unlock_at":"2026-11-01T00:00:00Z","lock_at":"2026-11-20T00:00:00Z","points_possible":10.5}},
          {"id":12,"type":"SubHeader","title":"Readings"},
          {"title":"no id at all","type":"Page"}
        ]}]
        """
        let r = CanvasStructuredDecoding.modules(fromPages: [data(json)])
        #expect(r.elements.count == 1)
        #expect(r.dropped == 1)
        let module = r.elements[0]
        #expect(module.state == "started")
        #expect(module.position == 2)
        let item = module.items[0]
        #expect(item.contentID == "55")
        #expect(item.moduleID == "1")
        #expect(item.completionRequirementType == "must_submit")
        #expect(item.completionCompleted == true)
        #expect(item.pointsPossible == 10.5)
        #expect(item.lockAt == date("2026-11-20T00:00:00Z"))
    }

    @Test("assignments decode all_dates, overrides and publication state")
    func assignments() {
        let json = """
        [{"id":55,"name":"PSet 3","due_at":"2026-11-10T04:59:00Z","only_visible_to_overrides":false,
          "published":true,"workflow_state":"published","submission_types":["online_upload"],
          "all_dates":[{"due_at":"2026-11-10T04:59:00Z","base":true,"title":"Everyone"},
                       {"due_at":"2026-11-12T04:59:00Z","base":false,"title":"Section 401"}],
          "overrides":[{"id":3,"due_at":"2026-11-12T04:59:00Z","title":"Section 401"}]}]
        """
        let r = CanvasStructuredDecoding.decode(CanvasOverrideAssignment.self, fromPages: [data(json)])
        let a = r.elements[0]
        #expect(a.allDates.count == 2)
        #expect(a.allDates[0].base && !a.allDates[1].base)
        #expect(a.overrides[0].id == "3")
        #expect(a.submissionTypes == ["online_upload"])
        #expect(a.isLive)
        #expect(!CanvasOverrideAssignment(id: "1", published: false).isLive)
    }

    @Test("missing submissions, discussion topics and pages decode (student_todo_at tolerated)")
    func others() {
        let missing = CanvasStructuredDecoding.decode(CanvasMissingSubmission.self, fromPages: [data("""
        [{"id":77,"name":"Lab 2","due_at":"2026-11-01T04:59:00Z","course_id":7,"planner_override":{"marked_complete":false,"dismissed":true}}]
        """)])
        #expect(missing.elements[0].assignmentID == "77")
        #expect(missing.elements[0].plannerDismissed)

        let topics = CanvasStructuredDecoding.decode(CanvasDiscussionTopic.self, fromPages: [data("""
        [{"id":900,"title":"Week 5 post","todo_date":"2026-11-08T05:00:00Z","published":true,
          "assignment":{"id":66,"due_at":"2026-11-09T05:00:00Z"}}, {"id":901,"title":"Chat","assignment":null}]
        """)])
        #expect(topics.elements[0].assignmentID == "66")
        #expect(topics.elements[0].todoDate != nil)
        #expect(topics.elements[1].assignmentID == nil)

        let pages = CanvasStructuredDecoding.decode(CanvasStructuredPage.self, fromPages: [data("""
        [{"url":"week-5-notes","title":"Week 5","todo_date":"2026-11-08T05:00:00Z","published":true},
         {"url":"old-style","title":"Old","student_todo_at":"2026-11-09T05:00:00Z"}]
        """)])
        #expect(pages.elements[0].todoDate != nil)
        #expect(pages.elements[1].todoDate != nil)
    }

    @Test("a page that is not a list is counted, not thrown")
    func notAList() {
        let r = CanvasStructuredDecoding.decode(CanvasPlannerItem.self, fromPages: [data("{\"errors\":[]}")])
        #expect(r.elements.isEmpty)
        #expect(r.dropped == 1)
    }
}

/// Canned transport: path -> responses, recording every URL asked for.
private final class Canned: @unchecked Sendable {
    struct Reply { var status = 200; var body = "[]"; var headers: [String: String] = [:] }
    private let lock = NSLock()
    private var replies: [String: [Reply]] = [:]   // key: path + "?page=N" when present
    private(set) var urls: [URL] = []

    func set(_ key: String, _ list: [Reply]) { lock.lock(); replies[key] = list; lock.unlock() }

    /// Synchronous so the lock is never held across a suspension point.
    private func answer(_ url: URL) -> (Data, HTTPURLResponse) {
        lock.lock(); defer { lock.unlock() }
        urls.append(url)
        let page = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == "page" }?.value
        let key = url.path + (page.map { "?page=\($0)" } ?? "")
        let reply = replies[key]?.first ?? Reply()
        if replies[key]?.count ?? 0 > 1 { replies[key]?.removeFirst() }
        let http = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: nil, headerFields: reply.headers)!
        return (Data(reply.body.utf8), http)
    }

    func transport() -> CanvasStructuredSourcesClient.Transport {
        { [self] url in answer(url) }
    }
    func paths() -> [String] { lock.lock(); defer { lock.unlock() }; return urls.map(\.path) }
}

@Suite("Canvas structured sources: client")
struct CanvasStructuredClientTests {
    private let base = URL(string: "https://canvas.example.edu")!
    private let t0 = ISO8601DateFormatter().date(from: "2026-11-01T00:00:00Z")!
    private let t1 = ISO8601DateFormatter().date(from: "2026-12-01T00:00:00Z")!

    @Test("follows the Link header across two pages and decodes both")
    func pagination() async {
        let canned = Canned()
        canned.set("/api/v1/courses/7/assignments", [.init(
            body: "[{\"id\":1,\"name\":\"A\"}]",
            headers: ["Link": "<https://canvas.example.edu/api/v1/courses/7/assignments?page=2&per_page=100>; rel=\"next\""])])
        canned.set("/api/v1/courses/7/assignments?page=2", [.init(body: "[{\"id\":2,\"name\":\"B\"}]")])
        let client = CanvasStructuredSourcesClient(baseURL: base, transport: canned.transport())
        let run = await client.fetch(courseIDs: ["7"], plannerStart: t0, plannerEnd: t1)
        #expect(run.courses[0].assignments.map(\.id) == ["1", "2"])
        #expect(run.courses[0].completedEndpoints.contains(.assignments))
        #expect(!run.rateLimited)
    }

    @Test("an off-host next link is not followed")
    func offHost() async {
        let canned = Canned()
        canned.set("/api/v1/courses/7/pages", [.init(
            body: "[{\"url\":\"a\"}]", headers: ["Link": "<https://evil.example/next>; rel=\"next\""])])
        let run = await CanvasStructuredSourcesClient(baseURL: base, transport: canned.transport())
            .fetch(courseIDs: ["7"], plannerStart: t0, plannerEnd: t1)
        #expect(run.courses[0].pages.count == 1)
        #expect(!run.courses[0].completedEndpoints.contains(.pages))
        #expect(!canned.paths().contains("/next"))
    }

    @Test("a low X-Rate-Limit-Remaining keeps the page, stops the rest, and marks every course")
    func lowBucket() async {
        let canned = Canned()
        // The first course's modules response drains the bucket.
        canned.set("/api/v1/courses/7/modules", [.init(
            body: "[{\"id\":1,\"name\":\"W1\",\"items\":[]}]", headers: ["X-Rate-Limit-Remaining": "12.5"])])
        let client = CanvasStructuredSourcesClient(baseURL: base, transport: canned.transport())
        let run = await client.fetch(courseIDs: ["7", "8"], plannerStart: t0, plannerEnd: t1)
        #expect(run.rateLimited)
        #expect(run.courses[0].modules.count == 1)       // kept
        #expect(run.courses[0].rateLimited)
        #expect(run.courses[0].assignments.isEmpty)
        #expect(run.courses[1].rateLimited)              // skipped, flagged
        let paths = canned.paths()
        #expect(!paths.contains("/api/v1/courses/7/assignments"))
        #expect(!paths.contains { $0.contains("/courses/8/") })
    }

    @Test("a healthy bucket does not stop anything")
    func healthyBucket() async {
        let canned = Canned()
        canned.set("/api/v1/courses/7/modules", [.init(headers: ["X-Rate-Limit-Remaining": "600"])])
        let run = await CanvasStructuredSourcesClient(baseURL: base, transport: canned.transport())
            .fetch(courseIDs: ["7", "8"], plannerStart: t0, plannerEnd: t1)
        #expect(!run.rateLimited)
        #expect(canned.paths().contains("/api/v1/courses/8/pages"))
    }

    @Test("a 403 Rate Limit Exceeded does not throw and keeps earlier courses")
    func rate403() async {
        let canned = Canned()
        canned.set("/api/v1/courses/7/assignments", [.init(body: "[{\"id\":1}]")])
        canned.set("/api/v1/courses/8/modules", [.init(status: 403, body: "403 Forbidden (Rate Limit Exceeded)")])
        let run = await CanvasStructuredSourcesClient(baseURL: base, transport: canned.transport())
            .fetch(courseIDs: ["7", "8", "9"], plannerStart: t0, plannerEnd: t1)
        #expect(run.rateLimited)
        #expect(run.courses[0].assignments.count == 1)
        #expect(!run.courses[0].rateLimited)
        #expect(run.courses[1].rateLimited)
        #expect(run.courses[2].rateLimited)
    }

    @Test("a plain 403 or 500 on one endpoint fails that endpoint only")
    func isolatedFailure() async {
        let canned = Canned()
        canned.set("/api/v1/courses/7/discussion_topics", [.init(status: 500, body: "{}")])
        canned.set("/api/v1/courses/7/pages", [.init(body: "[{\"url\":\"p\"}]")])
        let run = await CanvasStructuredSourcesClient(baseURL: base, transport: canned.transport())
            .fetch(courseIDs: ["7"], plannerStart: t0, plannerEnd: t1)
        #expect(run.courses[0].failedEndpoints == [.discussionTopics])
        #expect(run.courses[0].pages.count == 1)
        #expect(!run.rateLimited)
    }

    @Test("an HTML login page marks the session expired and stops")
    func expired() async {
        let canned = Canned()
        canned.set("/api/v1/planner/items", [.init(body: "<html>login</html>")])
        let run = await CanvasStructuredSourcesClient(baseURL: base, transport: canned.transport())
            .fetch(courseIDs: ["7"], plannerStart: t0, plannerEnd: t1)
        #expect(run.sessionExpired)
        #expect(!canned.paths().contains { $0.contains("/courses/7/") })
    }

    @Test("requests carry the includes the design needs")
    func queries() async {
        let canned = Canned()
        _ = await CanvasStructuredSourcesClient(baseURL: base, transport: canned.transport())
            .fetch(courseIDs: ["7"], plannerStart: t0, plannerEnd: t1)
        let all = canned.urls.map(\.absoluteString).joined(separator: "\n")
        #expect(all.contains("include%5B%5D=all_dates") || all.contains("include[]=all_dates"))
        #expect(all.contains("planner_overrides"))
        #expect(all.contains("content_details"))
        #expect(all.contains("start_date=2026-11-01T00:00:00Z") || all.contains("start_date=2026-11-01T00%3A00%3A00Z"))
    }
}

@Suite("Canvas structured sources: conversion")
struct CanvasStructuredReconcilerTests {
    private let base = URL(string: "https://canvas.example.edu")!
    private let course = CourseSummary(courseID: "7", code: "PHYS 0151", name: "Physics", url: nil)
    private func date(_ s: String) -> Date { ISO8601DateFormatter().date(from: s)! }

    private func run(_ build: (inout CanvasStructuredSourcesClient.CourseResult, inout CanvasStructuredSourcesClient.RunResult) -> Void) -> CanvasStructuredSignals {
        var result = CanvasStructuredSourcesClient.RunResult()
        var c = CanvasStructuredSourcesClient.CourseResult(courseID: "7")
        build(&c, &result)
        result.courses = [c]
        return CanvasStructuredSourcesReconciler.signals(from: result, courses: [course], baseURL: base)
    }

    @Test("a module Assignment row joins a feed row by canvasAssignmentID (ICS fragment form)")
    func sameIDAsFeed() throws {
        let feedURL = URL(string: "https://canvas.example.edu/calendar?include_contexts=course_7&month=11&year=2026#assignment_55")!
        let feed = Assignment(source: .canvas, sourceID: "event-assignment-override-3", kind: .assignment,
                              course: "PHYS 0151", title: "PSet 3 (Section 401) [PHYS 0151]", dueAt: nil, url: feedURL)
        let signals = run { c, _ in
            c.modules = [.init(id: "1", name: "W1", items: [
                .init(id: "11", type: "Assignment", contentID: "55", title: "PSet 3", dueAt: date("2026-11-10T04:59:00Z"))])]
        }
        let row = try #require(signals.rows.first).assignment
        #expect(feed.canvasAssignmentID == "55")
        #expect(row.canvasAssignmentID == feed.canvasAssignmentID)
        #expect(row.sourceID == "module-item-11")
        #expect(row.source == .canvasModules)
    }

    @Test("Quiz and Discussion module items never claim an assignment id they do not have")
    func quizDiscussionIDs() {
        let signals = run { c, _ in
            c.discussionTopics = [.init(id: "900", assignmentID: "66")]
            c.modules = [.init(id: "1", name: "W1", items: [
                .init(id: "21", type: "Quiz", contentID: "55", title: "Quiz 1", completionCompleted: true, dueAt: date("2026-11-10T04:59:00Z")),
                .init(id: "22", type: "Discussion", contentID: "900", title: "Post", completionCompleted: true, dueAt: date("2026-11-11T04:59:00Z")),
            ])]
        }
        let quiz = signals.rows.first { $0.sourceID == "module-item-21" }!.assignment
        let disc = signals.rows.first { $0.sourceID == "module-item-22" }!.assignment
        #expect(quiz.canvasAssignmentID == nil)          // 55 is a quiz id, not an assignment id
        #expect(disc.canvasAssignmentID == "66")         // resolved through the topic's nested assignment
        #expect(signals.completions.contains { $0.ref == .source("module-item-21") && $0.reason == .moduleRequirement })
        #expect(signals.completions.contains { $0.ref == .assignment("66") })
    }

    @Test("completed module requirement is a completion; undated module items make no row")
    func completionAndUndated() {
        let signals = run { c, _ in
            c.modules = [.init(id: "1", name: "W1", items: [
                .init(id: "11", type: "Assignment", contentID: "55", title: "Done", completionCompleted: true),
                .init(id: "12", type: "Assignment", contentID: "56", title: "Open", completionCompleted: false),
                .init(id: "13", type: "Page", title: "Reading"),
            ])]
        }
        #expect(signals.completions.map(\.ref) == [.assignment("55")])
        #expect(signals.rows.isEmpty)
    }

    @Test("planner: marked_complete completes, dismissed hides, nothing deletes, notes become rows")
    func planner() {
        let signals = run { _, r in
            r.planner = [
                .init(plannableType: "assignment", plannableID: "55", courseID: "7", markedComplete: true),
                .init(plannableType: "assignment", plannableID: "56", courseID: "7", dismissed: true),
                .init(plannableType: "planner_note", plannableID: "9", title: "Email TA",
                      todoDate: date("2026-11-12T17:00:00Z"), courseID: "7", dismissed: true),
                .init(plannableType: "assignment", plannableID: "57", courseID: "999", markedComplete: true),
            ]
        }
        #expect(signals.completions.map(\.ref) == [.assignment("55")])
        #expect(signals.dismissals.map(\.ref) == [.assignment("56"), .source("planner-note-9")])
        // The dismissed note is still a row: hiding is the applier's call, deleting is nobody's.
        let note = signals.rows.first { $0.sourceID == "planner-note-9" }
        #expect(note?.title == "Email TA")
        #expect(note?.dueAt == date("2026-11-12T17:00:00Z"))
        // Round-trips as Codable data.
        let data = try? JSONEncoder().encode(signals)
        #expect(data.flatMap { try? JSONDecoder().decode(CanvasStructuredSignals.self, from: $0) } == signals)
    }

    @Test("all_dates picks the student's section date over the base")
    func sectionDate() {
        let signals = run { c, _ in
            c.assignments = [
                .init(id: "55", allDates: [
                    .init(dueAt: date("2026-11-10T04:59:00Z"), base: true),
                    .init(dueAt: date("2026-11-12T04:59:00Z"), base: false, title: "Section 401")]),
                .init(id: "56", allDates: [.init(dueAt: date("2026-11-10T04:59:00Z"), base: true)]),
                .init(id: "57", allDates: [.init(dueAt: date("2026-11-12T04:59:00Z"), base: false)], published: false),
                .init(id: "58", allDates: [
                    .init(dueAt: date("2026-11-20T04:59:00Z"), base: false),
                    .init(dueAt: date("2026-11-15T04:59:00Z"), base: false)]),
            ]
        }
        #expect(signals.dueDateCorrections.map(\.assignmentID) == ["55", "58"])
        #expect(signals.dueDateCorrections[0].dueAt == date("2026-11-12T04:59:00Z"))
        #expect(signals.dueDateCorrections[1].dueAt == date("2026-11-15T04:59:00Z"))
    }

    @Test("missing submissions become missing signals by assignment id")
    func missing() {
        let signals = run { _, r in
            r.missingSubmissions = [
                .init(assignmentID: "77", courseID: "7", name: "Lab 2", dueAt: date("2026-11-01T04:59:00Z")),
                .init(assignmentID: "78", courseID: "999", name: "Elsewhere"),
            ]
        }
        #expect(signals.missing.map(\.assignmentID) == ["77"])
    }

    @Test("discussion and page to-do rows carry discussion_ and page_ prefixes")
    func prefixes() {
        let signals = run { c, _ in
            c.discussionTopics = [
                .init(id: "900", title: "Week 5", todoDate: date("2026-11-08T05:00:00Z")),
                .init(id: "901", title: "Graded", assignmentID: "66", assignmentDueAt: date("2026-11-09T05:00:00Z")),
                .init(id: "902", title: "No date"),
                .init(id: "903", title: "Draft", todoDate: date("2026-11-08T05:00:00Z"), published: false),
            ]
            c.pages = [
                .init(url: "week-5-notes", title: "Week 5", todoDate: date("2026-11-08T05:00:00Z")),
                .init(url: "plain", title: "Plain"),
            ]
        }
        #expect(signals.rows.map(\.sourceID).sorted() == ["discussion_900", "discussion_901", "page_week-5-notes"])
        let graded = signals.rows.first { $0.sourceID == "discussion_901" }!.assignment
        #expect(graded.canvasAssignmentID == "66")
        #expect(graded.kind == .discussion)
    }
}
