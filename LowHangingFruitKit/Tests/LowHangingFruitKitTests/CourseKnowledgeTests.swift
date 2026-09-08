import Foundation
import Testing
@testable import LowHangingFruitKit

@Suite("Course content API parsing")
struct CourseContentAPITests {
    static let course = CourseSummary(courseID: "1234", code: "CIS 2400", name: "CIS 2400 Intro to Computer Systems", url: URL(string: "https://canvas.upenn.edu/courses/1234"))
    static let base = URL(string: "https://canvas.upenn.edu")!

    @Test("strips the while(1); anti-hijack prefix")
    func stripsPrefix() throws {
        let raw = Data("while(1);[{\"url\": \"a\", \"title\": \"A\"}]".utf8)
        let clean = CourseContentAPI.stripAntiHijackPrefix(raw)
        let decoded = try CourseContentAPI.decoder().decode([CourseContentPage].self, from: clean)
        #expect(decoded.count == 1)
        #expect(decoded[0].title == "A")
        #expect(CourseContentAPI.stripAntiHijackPrefix(Data("[]".utf8)) == Data("[]".utf8))
    }

    @Test("decodes Canvas timestamps with and without fractional seconds")
    func decodesDates() {
        #expect(CourseContentAPI.parseDate("2026-09-10T03:59:59Z") != nil)
        #expect(CourseContentAPI.parseDate("2026-09-10T03:59:59.123Z") != nil)
        #expect(CourseContentAPI.parseDate("not a date") == nil)
    }

    @Test("follows a same-host Link header and refuses another host")
    func linkHeader() throws {
        let header = "<https://canvas.upenn.edu/api/v1/courses/1/assignments?page=2&per_page=100>; rel=\"next\", <https://canvas.upenn.edu/api/v1/courses/1/assignments?page=1>; rel=\"first\""
        #expect(try CourseContentAPI.nextPageURL(fromLinkHeader: header, sameHostAs: Self.base)?.absoluteString == "https://canvas.upenn.edu/api/v1/courses/1/assignments?page=2&per_page=100")
        #expect(try CourseContentAPI.nextPageURL(fromLinkHeader: "<https://x/y?page=1>; rel=\"first\"", sameHostAs: Self.base) == nil)
        #expect(try CourseContentAPI.nextPageURL(fromLinkHeader: nil, sameHostAs: Self.base) == nil)
        #expect(throws: CanvasCourseContentClient.Error.unsafePaginationURL) {
            try CourseContentAPI.nextPageURL(fromLinkHeader: "<https://evil.example/next>; rel=\"next\"", sameHostAs: Self.base)
        }
    }

    @Test("builds an assignment document with due date, points, submission state, and description")
    func buildsAssignmentDocument() throws {
        let json = """
        while(1);[{
          "id": 555, "name": "PSet 3: caches", "due_at": "2026-09-17T03:59:00Z",
          "html_url": "https://canvas.upenn.edu/courses/1234/assignments/555",
          "points_possible": 100.0, "updated_at": "2026-09-01T12:00:00Z",
          "description": "<p>Implement a <b>direct-mapped</b> cache simulator.</p><ul><li>Part A</li><li>Part B</li></ul>",
          "submission": {"workflow_state": "unsubmitted", "submitted_at": null}
        }]
        """
        let assignments = try CourseContentAPI.decoder().decode([CourseContentAssignment].self, from: CourseContentAPI.stripAntiHijackPrefix(Data(json.utf8)))
        let doc = CourseDocumentBuilder.assignment(from: try #require(assignments.first), course: Self.course)

        #expect(doc.kind == .assignment)
        #expect(doc.id == "assignment:1234:555")
        #expect(doc.course == "CIS 2400")
        #expect(doc.title == "PSet 3: caches")
        #expect(doc.dueAt != nil)
        #expect(doc.pointsPossible == 100)
        #expect(doc.submitted == false)
        #expect(doc.text.contains("Status: not submitted"))
        #expect(doc.text.contains("direct-mapped cache simulator"))
        #expect(doc.text.contains("• Part A"))
        #expect(!doc.text.contains("<"))
    }

    @Test("builds syllabus, announcement, module, and page documents from the existing clients' models")
    func buildsOtherDocuments() throws {
        let candidate = SyllabusCandidate(id: "syllabus_body", source: .canvasSyllabusPage, name: "Syllabus", text: "Late policy\nThree late days.")
        let syllabus = try #require(CourseDocumentBuilder.syllabus(from: candidate, course: Self.course))
        #expect(syllabus.kind == .syllabus)
        #expect(syllabus.text.contains("Three late days."))
        #expect(syllabus.url?.path == "/courses/1234/assignments/syllabus")
        #expect(CourseDocumentBuilder.syllabus(from: SyllabusCandidate(id: "x", source: .pasted, name: "", text: "  "), course: Self.course) == nil)

        let announcement = CourseDocumentBuilder.announcement(
            from: CanvasAnnouncement(id: "9", courseID: "1234", title: "Exam moved", message: "The midterm is now Oct 21.", postedAt: Date(timeIntervalSince1970: 1_800_000_000), url: URL(string: "https://canvas.upenn.edu/courses/1234/discussion_topics/9")),
            course: Self.course
        )
        #expect(announcement.kind == .announcement)
        #expect(announcement.id == "announcement:1234:9")
        #expect(announcement.text.hasPrefix("Posted: "))
        #expect(announcement.text.contains("The midterm is now Oct 21."))

        let items = [
            CanvasModulesClient.ModuleItem(id: "1", title: "Lecture 3 slides", dueAt: nil, typeRaw: "File", moduleName: "Week 2"),
            CanvasModulesClient.ModuleItem(id: "2", title: "Reading: Chapter 2", dueAt: nil, typeRaw: "ExternalUrl", moduleName: "Week 2"),
            CanvasModulesClient.ModuleItem(id: "3", title: "Lecture 5 slides", dueAt: nil, typeRaw: "File", moduleName: "Week 3"),
        ]
        let modules = CourseDocumentBuilder.modules(from: items, course: Self.course)
        #expect(modules.map(\.title) == ["Week 2", "Week 3"])
        #expect(modules[0].text == "• Lecture 3 slides (file)\n• Reading: Chapter 2 (externalurl)")

        let pageJSON = #"{"url": "course-policies", "title": "Course policies", "body": "<p>No laptops in lecture.</p>", "html_url": "https://canvas.upenn.edu/courses/1234/pages/course-policies", "published": true}"#
        let page = try CourseContentAPI.decoder().decode(CourseContentPage.self, from: Data(pageJSON.utf8))
        let pageDoc = CourseDocumentBuilder.page(from: page, course: Self.course)
        #expect(pageDoc.id == "page:1234:course-policies")
        #expect(pageDoc.text == "No laptops in lecture.")
    }
}

@Suite("HTML to text")
struct HTMLTextTests {
    @Test("keeps paragraphs and list items on separate lines and decodes entities")
    func plainText() {
        let html = "<div><h1>Policies</h1><p>Late work &amp; extensions: see below.</p><ul><li>Item&nbsp;one</li><li>Item &#39;two&#39;</li></ul><script>alert(1)</script></div>"
        let text = HTMLText.plainText(from: html)
        #expect(text == "Policies\nLate work & extensions: see below.\n• Item one\n• Item 'two'")
    }

    @Test("decodes numeric entities")
    func numericEntities() {
        #expect(HTMLText.decodeEntities("&#8217;s &#x2014; ok") == "’s — ok")
    }
}

@Suite("Course knowledge base")
struct CourseKnowledgeBaseTests {
    private func doc(_ course: String = "1", kind: CourseDocument.Kind = .page, id: String, text: String, fetchedAt: Date) -> CourseDocument {
        CourseDocument(courseID: course, course: "CIS \(course)", kind: kind, sourceID: id, title: "Doc \(id)", url: nil, text: text, fetchedAt: fetchedAt)
    }

    @Test("merge keeps unchanged documents, replaces changed ones, drops removed ones")
    func merge() {
        let t0 = Date(timeIntervalSince1970: 1_000)
        let t1 = Date(timeIntervalSince1970: 2_000)
        var base = CourseKnowledgeBase(
            courses: [CourseSummary(courseID: "1", code: "CIS 1", name: "CIS 1", url: nil)],
            documents: [
                doc(id: "a", text: "same", fetchedAt: t0),
                doc(id: "b", text: "old", fetchedAt: t0),
                doc(id: "c", text: "gone", fetchedAt: t0),
                doc("2", id: "z", text: "other course", fetchedAt: t0),
            ],
            lastSyncedAt: t0
        )
        base.merge(
            courses: [CourseSummary(courseID: "1", code: "CIS 1", name: "CIS 1 Renamed", url: nil)],
            documents: [doc(id: "a", text: "same", fetchedAt: t1), doc(id: "b", text: "new", fetchedAt: t1)],
            resyncedCourseIDs: ["1"],
            syncedAt: t1
        )
        let byID = Dictionary(uniqueKeysWithValues: base.documents.map { ($0.id, $0) })
        #expect(byID["page:1:a"]?.fetchedAt == t0)     // unchanged: keeps original fetch time
        #expect(byID["page:1:b"]?.text == "new")
        #expect(byID["page:1:b"]?.fetchedAt == t1)
        #expect(byID["page:1:c"] == nil)                // removed from Canvas
        #expect(byID["page:2:z"] != nil)                // other course untouched
        #expect(base.courses.first?.name == "CIS 1 Renamed")
        #expect(base.lastSyncedAt == t1)
    }

    @Test("store round-trips through JSON in a scratch directory")
    func storeRoundTrip() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("lhf-tests-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = CourseKnowledgeStore(directory: directory)
        #expect(store.load().isEmpty)

        let knowledge = CourseKnowledgeBase(
            courses: [CourseSummary(courseID: "1", code: "CIS 1", name: "CIS 1", url: URL(string: "https://canvas.upenn.edu/courses/1"))],
            documents: [doc(id: "a", text: "hello", fetchedAt: Date(timeIntervalSince1970: 5_000))],
            lastSyncedAt: Date(timeIntervalSince1970: 6_000)
        )
        try store.save(knowledge)
        let loaded = store.load()
        #expect(loaded.documents.count == 1)
        #expect(loaded.documents.first?.contentHash == knowledge.documents.first?.contentHash)
        #expect(loaded.lastSyncedAt == knowledge.lastSyncedAt)
        store.clear()
        #expect(store.load().isEmpty)
    }
}

@Suite("Chunking and search")
struct CourseSearchTests {
    @Test("chunker respects paragraph boundaries and word budget")
    func chunks() {
        let paragraph = Array(repeating: "word", count: 100).joined(separator: " ")
        let text = [paragraph, paragraph, paragraph].joined(separator: "\n")
        let chunks = PassageChunker.chunk(text)
        #expect(chunks.count == 3)
        #expect(chunks.allSatisfy { PassageChunker.wordCount($0) <= PassageChunker.maxWords })

        let long = Array(repeating: "Sentence number one is here.", count: 80).joined(separator: " ")
        #expect(PassageChunker.chunk(long).count > 1)
    }

    @Test("tokenizer stems and drops stopwords")
    func tokenizer() {
        #expect(TextTokenizer.tokens("What is the late policy for quizzes?") == ["late", "policy", "quiz"])
        #expect(TextTokenizer.stem("submitting") == "submit")
        #expect(TextTokenizer.stem("classes") == "class")
        #expect(TextTokenizer.stem("exams") == "exam")
        #expect(TextTokenizer.stem("2400") == "2400")
        #expect(TextTokenizer.tokens("pset 3", minLength: 1) == ["pset", "3"])
    }

    @Test("search finds the syllabus passage about late work and filters by course")
    func search() throws {
        let cis = CourseDocument(courseID: "1", course: "CIS 2400", kind: .syllabus, sourceID: "syllabus", title: "CIS 2400 syllabus", url: nil,
                                 text: "Late policy\nYou have three late days. Late work after that loses 10% per day.\nGrading\nHomework 50%, exams 50%.")
        let econ = CourseDocument(courseID: "2", course: "ECON 1", kind: .syllabus, sourceID: "syllabus", title: "ECON 1 syllabus", url: nil,
                                  text: "Late policy\nProblem sets are not accepted late. The lowest score is dropped.")
        let announcement = CourseDocument(courseID: "1", course: "CIS 2400", kind: .announcement, sourceID: "9", title: "Recitation moved", url: nil,
                                          text: "Recitation moves to Thursday this week because of the career fair.")
        let search = CourseSearch(knowledge: CourseKnowledgeBase(documents: [cis, econ, announcement]))

        let hits = search.search("what is the late policy", limit: 3)
        #expect(!hits.isEmpty)
        #expect(hits.allSatisfy { $0.document.kind == .syllabus })

        let econOnly = search.search("late policy", courseID: "2")
        #expect(econOnly.count == 1)
        #expect(econOnly.first?.document.course == "ECON 1")

        let recitation = try #require(search.search("when is recitation this week").first)
        #expect(recitation.document.id == announcement.id)

        #expect(search.search("quantum chromodynamics").isEmpty)
    }

    @Test("preferredComponent ranks the matching component's passage first without hiding the other")
    func preferredComponentBoost() {
        // PHYS 0151 is one Canvas site holding a lecture and a lab, each with
        // its own syllabus, both mentioning "late work" — exactly the setup
        // that used to send a "what's the late policy for the class"
        // question to the lab passage purely on keyword overlap.
        let lecture = CourseDocument(courseID: "1", course: "PHYS 0151", kind: .syllabus, sourceID: "lecture-syllabus", title: "PHYS 0151 Lecture Syllabus", url: nil,
                                     text: "This is the lecture syllabus. Homework and exams are described here. Late work is only accepted with a documented excuse from the instructor.")
        let lab = CourseDocument(courseID: "1", course: "PHYS 0151", kind: .syllabus, sourceID: "lab-syllabus", title: "PHYS 0151 Lab Syllabus", url: nil,
                                 text: "This is the lab syllabus. Late work loses ten percent per day, no exceptions.")
        let search = CourseSearch(knowledge: CourseKnowledgeBase(documents: [lecture, lab]))

        // No preference: identical to calling without the parameter at all —
        // today's ordering, untouched.
        let unnamed = search.search("late work policy")
        let explicitNil = search.search("late work policy", preferredComponent: nil)
        #expect(unnamed.map(\.document.id) == explicitNil.map(\.document.id))

        let classQuery = "class late policy"
        let classHits = search.search(classQuery, preferredComponent: DocumentComponent.mentioned(in: classQuery))
        #expect(classHits.first?.document.id == lecture.id)
        #expect(classHits.first?.component == .lecture)

        let labQuery = "lab late policy"
        let labHits = search.search(labQuery, preferredComponent: DocumentComponent.mentioned(in: labQuery))
        #expect(labHits.first?.document.id == lab.id)
        #expect(labHits.first?.component == .lab)

        // Neither passage is hidden — the non-preferred one still surfaces,
        // just outranked and labelled.
        #expect(classHits.contains { $0.document.id == lab.id })
        #expect(labHits.contains { $0.document.id == lecture.id })
    }
}
