import Foundation
import Testing
@testable import LowHangingFruitKit

/// Covers the pure Kit layer of Ed Discussion ingestion: wire decoding, the
/// XML-to-text converter, the keep/drop filter, the Ed-to-Canvas course
/// matcher and the document builder. All JSON and XML is inline, written to
/// match what Ed's API is documented to send (including the quirks the models
/// exist to absorb: a missing `role`, a null `document`, a missing
/// `is_pinned`, microsecond timestamps with a `+10:00` offset). Nothing here
/// touches the network or WebKit.

private func instant(_ iso: String) throws -> Date {
    try #require(ISO8601DateFormatter().date(from: iso))
}

private func thread(
    _ id: Int,
    user: Int = 1,
    type: String = "post",
    pinned: Bool = false,
    isPrivate: Bool = false,
    document: String? = nil,
    content: String? = nil,
    category: String? = nil,
    subcategory: String? = nil,
    title: String = "T"
) -> EdThread {
    EdThread(
        id: id, userID: user, courseID: 101, type: type, title: title, document: document,
        content: content, category: category, subcategory: subcategory,
        isPinned: pinned, isPrivate: isPrivate
    )
}

@Suite("Ed wire decoding")
struct EdWireTests {
    @Test("decodes /api/user, tolerating a missing role and ignoring unknown fields")
    func decodesUserBody() throws {
        let json = #"""
        {"user":{"id":1,"name":"Sam"},
         "courses":[
           {"course":{"id":101,"code":"CIS 2400","name":"Machine Organization","year":"2026","session":"Fall","status":"active","created_at":"2026-03-05T14:21:55.123456+10:00"},
            "role":{"role":"student"}},
           {"course":{"id":102,"code":"MATH 1400","name":"Calculus"}}
         ]}
        """#
        let response = try EdJSON.decoder().decode(EdUserResponse.self, from: Data(json.utf8))
        #expect(response.courses.count == 2)
        #expect(response.courses[0].course.id == 101)
        #expect(response.courses[0].course.session == "Fall")
        #expect(response.courses[0].role?.role == "student")
        #expect(response.courses[1].role == nil)
        #expect(response.courses[1].course.year == nil)
        #expect(response.courses[1].course.status == nil)
    }

    @Test("decodes threads: absent is_pinned is false, null document is nil, microsecond +10:00 date parses")
    func decodesThreadsBody() throws {
        let json = #"""
        {"threads":[{"id":900,"user_id":7,"course_id":101,"type":"announcement","title":"Welcome",
                     "document":null,"content":"<p>hi</p>","category":"General","subcategory":"",
                     "is_private":false,"created_at":"2026-03-05T14:21:55.123456+10:00",
                     "updated_at":null,"number":3,"reply_count":0,"vote_count":5,"extra":{"a":1}}],
         "users":[{"id":7,"name":"Dr X","course_role":"admin"},{"id":8}]}
        """#
        let response = try EdJSON.decoder().decode(EdThreadsResponse.self, from: Data(json.utf8))
        let t = try #require(response.threads.first)
        #expect(t.id == 900)
        #expect(t.userID == 7)
        #expect(t.courseID == 101)
        #expect(t.isPinned == false)
        #expect(t.isEndorsed == false)
        #expect(t.isAnonymous == false)
        #expect(t.document == nil)
        #expect(t.content == "<p>hi</p>")
        #expect(t.updatedAt == nil)
        #expect(t.number == 3)
        let expected = try instant("2026-03-05T04:21:55Z").timeIntervalSince1970 + 0.123
        #expect(abs(t.createdAt.timeIntervalSince1970 - expected) < 0.001)
        #expect(response.users.count == 2)
        #expect(response.users[0].courseRole == "admin")
        #expect(response.users[1].courseRole == nil)
    }

    @Test("a missing user_id (anonymous thread) decodes as 0 instead of failing the page")
    func missingUserID() throws {
        let json = #"""
        {"threads":[{"id":1,"course_id":101,"type":"post","title":"x","created_at":"2026-03-05T14:21:55Z"}]}
        """#
        let response = try EdJSON.decoder().decode(EdThreadsResponse.self, from: Data(json.utf8))
        #expect(response.threads[0].userID == 0)
        #expect(response.users.isEmpty)
    }

    @Test("timestamp shapes: Z, offsets with and without colon, fractions of any length, space separator")
    func dateShapes() throws {
        let base = try instant("2026-03-05T04:21:55Z")
        let sameInstant = [
            "2026-03-05T04:21:55Z",
            "2026-03-05T14:21:55+10:00",
            "2026-03-05T14:21:55+1000",
            "2026-03-05T14:21:55+10",
            "2026-03-04T23:21:55-05:00",
            "2026-03-05 14:21:55+10:00",
        ]
        for text in sameInstant {
            let parsed = try #require(EdJSON.parseDate(text), "\(text)")
            #expect(parsed == base, "\(text)")
        }
        let fractional = try #require(EdJSON.parseDate("2026-03-05T14:21:55.5+10:00"))
        #expect(abs(fractional.timeIntervalSince(base) - 0.5) < 0.001)
        let micro = try #require(EdJSON.parseDate("2026-03-05T14:21:55.123456+10:00"))
        #expect(abs(micro.timeIntervalSince(base) - 0.123) < 0.001)
        #expect(EdJSON.parseDate("yesterday") == nil)
        #expect(EdJSON.parseDate("") == nil)
    }

    @Test("an unparseable timestamp fails the decode rather than inventing a date")
    func badDateThrows() {
        let json = #"""
        {"threads":[{"id":1,"user_id":2,"course_id":101,"type":"post","title":"x","created_at":"soon"}]}
        """#
        #expect(throws: DecodingError.self) {
            try EdJSON.decoder().decode(EdThreadsResponse.self, from: Data(json.utf8))
        }
    }
}

@Suite("Ed document text")
struct EdDocumentTextTests {
    @Test("heading, paragraph, bold, entity, links, lists, callout and snippet render as Markdown-ish text")
    func representativeDocument() {
        let xml = "<document version=\"2.0\">"
            + "<heading level=\"2\">Midterm info</heading>"
            + "<paragraph>The exam is <bold>Friday</bold> &amp; covers weeks 1-5. "
            + "See <link href=\"https://example.com/s\">the sheet</link> or "
            + "<link href=\"https://example.com/x\">https://example.com/x</link>.</paragraph>"
            + "<list style=\"bullet\"><list-item><paragraph>Bring a pencil</paragraph></list-item>"
            + "<list-item><paragraph>Bring ID</paragraph></list-item></list>"
            + "<list style=\"number\"><list-item><paragraph>one</paragraph></list-item>"
            + "<list-item><paragraph>two</paragraph></list-item></list>"
            + "<callout type=\"info\"><paragraph>Room changed</paragraph></callout>"
            + "<snippet language=\"python\">print(1)\nprint(2)</snippet>"
            + "</document>"
        let expected = """
        ## Midterm info
        The exam is Friday & covers weeks 1-5. See the sheet (https://example.com/s) or https://example.com/x.
        - Bring a pencil
        - Bring ID
        1. one
        2. two
        > Room changed
        ```python
        print(1)
        print(2)
        ```
        """
        #expect(EdDocumentText.plainText(fromDocument: xml) == expected)
    }

    @Test("break is a newline, image is [image], pre is fenced, math is kept verbatim")
    func smallElements() {
        let xml = "<document><paragraph>a<break/>b</paragraph><image src=\"https://x/y.png\"/>"
            + "<pre>x = 1</pre><paragraph>Solve <math>x^2 = 4</math> now</paragraph></document>"
        #expect(EdDocumentText.plainText(fromDocument: xml) == "a\nb\n[image]\n```\nx = 1\n```\nSolve x^2 = 4 now")
    }

    @Test("pretty-printed whitespace between tags does not leak into the text")
    func prettyPrinted() {
        let xml = """
        <document version="2.0">
          <paragraph>one</paragraph>
          <list style="bullet">
            <list-item><paragraph>two</paragraph></list-item>
          </list>
        </document>
        """
        #expect(EdDocumentText.plainText(fromDocument: xml) == "one\n- two")
    }

    @Test("three or more newlines collapse to one blank line")
    func collapsesBlankLines() {
        let xml = "<document><paragraph>a</paragraph><break/><break/><break/><paragraph>b</paragraph></document>"
        #expect(EdDocumentText.plainText(fromDocument: xml) == "a\n\nb")
    }

    @Test("malformed XML degrades to tag-stripped text, never an empty string")
    func malformedDocument() {
        let unclosed = EdDocumentText.plainText(fromDocument: "<document><paragraph>Hello <bold>world</paragraph> Tom &amp; Jerry")
        #expect(unclosed.contains("Hello world"))
        #expect(unclosed.contains("Tom & Jerry"))

        // A bare ampersand is not legal XML but is exactly what a student or
        // an instructor types.
        #expect(EdDocumentText.plainText(fromDocument: "<document><paragraph>Q&A hours</paragraph></document>") == "Q&A hours")

        // Not markup at all.
        #expect(EdDocumentText.plainText(fromDocument: "just words") == "just words")
    }

    @Test("an empty document is the empty string")
    func emptyDocument() {
        #expect(EdDocumentText.plainText(fromDocument: "") == "")
        #expect(EdDocumentText.plainText(fromDocument: "<document version=\"2.0\"></document>") == "")
    }

    @Test("strippingTags turns block tags into line breaks and decodes entities")
    func strippingTags() {
        #expect(EdDocumentText.strippingTags("<p>Hello&nbsp;there</p><p>a &lt; b &#38; c</p>") == "Hello there\n\na < b & c")
        #expect(EdDocumentText.strippingTags("1 < 2 and 3 > 2") == "1 < 2 and 3 > 2")
    }
}

@Suite("Ed thread filter")
struct EdThreadFilterTests {
    @Test("a private announcement is dropped: private beats everything")
    func privateDropped() {
        let d = EdThreadFilter.decide(thread(1, type: "announcement", isPrivate: true), authorRole: "admin")
        #expect(d == EdThreadDecision(keep: false, reason: "private"))
    }

    @Test("announcements are kept whoever wrote them")
    func announcementKept() {
        let d = EdThreadFilter.decide(thread(1, type: "announcement"), authorRole: nil)
        #expect(d == EdThreadDecision(keep: true, reason: "announcement"))
    }

    @Test("a pinned student post is kept: only staff can pin")
    func pinnedKept() {
        let d = EdThreadFilter.decide(thread(1, pinned: true), authorRole: "student")
        #expect(d == EdThreadDecision(keep: true, reason: "pinned"))
    }

    @Test("a staff post is kept, in any case, for every staff role")
    func staffPostKept() {
        for role in ["admin", "Staff", "INSTRUCTOR", "ta", "tutor", "mentor"] {
            let d = EdThreadFilter.decide(thread(1), authorRole: role)
            #expect(d == EdThreadDecision(keep: true, reason: "staff post"), "\(role)")
        }
    }

    @Test("a staff question is dropped")
    func staffQuestionDropped() {
        let d = EdThreadFilter.decide(thread(1, type: "question"), authorRole: "staff")
        #expect(d == EdThreadDecision(keep: false, reason: "student or question"))
    }

    @Test("a student post is dropped, and an unknown author is treated as a student")
    func studentAndUnknownDropped() {
        let drop = EdThreadDecision(keep: false, reason: "student or question")
        #expect(EdThreadFilter.decide(thread(1), authorRole: "student") == drop)
        #expect(EdThreadFilter.decide(thread(1), authorRole: nil) == drop)
        #expect(EdThreadFilter.decide(thread(1), authorRole: "something-new") == drop)
    }

    @Test("keptThreads reads author roles from the response's users array")
    func keptThreadsUsesUsers() {
        let response = EdThreadsResponse(
            threads: [
                thread(1, user: 10),                         // staff post: kept
                thread(2, user: 11),                         // student post: dropped
                thread(3, user: 99),                         // author not in users: dropped
                thread(4, user: 10, type: "question"),       // staff question: dropped
                thread(5, user: 11, type: "announcement"),   // kept
                thread(6, user: 10, isPrivate: true),        // private: dropped
            ],
            users: [
                EdThreadUser(id: 10, name: "Dr X", courseRole: "admin"),
                EdThreadUser(id: 11, name: "Sam", courseRole: "student"),
            ]
        )
        let kept = EdThreadFilter.keptThreads(response)
        #expect(kept.map { $0.thread.id } == [1, 5])
        #expect(kept.map { $0.decision.reason } == ["staff post", "announcement"])
    }
}

@Suite("Ed course matcher")
struct EdCourseMatcherTests {
    private let fall2026 = Term(year: 2026, season: .fall)

    private func ed(_ id: Int, _ code: String, year: String? = nil, session: String? = nil) -> EdCourse {
        EdCourse(id: id, code: code, name: "n", year: year, session: session)
    }

    @Test("normalizedCode makes Ed's and Canvas's spellings agree")
    func normalization() {
        for raw in ["CIS 2400", "cis2400", "CIS-2400", "CIS 2400-001", "  cis   2400 ", "CIS\u{00A0}2400"] {
            #expect(EdCourseMatcher.normalizedCode(raw) == "CIS 2400", "\(raw)")
        }
        #expect(EdCourseMatcher.normalizedCode("CHEM 1010L") == "CHEM 1010L")
        #expect(EdCourseMatcher.normalizedCode("ban-phys-151-1234") == "PHYS 151")
        #expect(EdCourseMatcher.normalizedCode("Intro Seminar") == "INTROSEMINAR")
    }

    @Test("term(of:) reads year and session, and gives up on anything ambiguous")
    func edTerms() {
        #expect(EdCourseMatcher.term(of: ed(1, "X 1", year: "2026", session: "Fall")) == fall2026)
        #expect(EdCourseMatcher.term(of: ed(1, "X 1", year: nil, session: "Spring 2027")) == Term(year: 2027, season: .spring))
        #expect(EdCourseMatcher.term(of: ed(1, "X 1", year: "2026", session: "Winter")) == nil)
        #expect(EdCourseMatcher.term(of: ed(1, "X 1", year: "2025-2026", session: "Spring")) == nil)
        #expect(EdCourseMatcher.term(of: ed(1, "X 1", year: "2026", session: nil)) == nil)
        #expect(CanvasCourseRef(code: "X 1", termText: "Fall 2026").term == fall2026)
        #expect(CanvasCourseRef(code: "X 1", termText: "202630").term == fall2026)
    }

    @Test("a link beats code matching, and settles that Canvas code")
    func linkBeatsCode() {
        let matches = EdCourseMatcher.match(
            edCourses: [ed(1, "CIS 2400", year: "2026", session: "Fall"), ed(2, "CIS 2400", year: "2026", session: "Fall")],
            canvasCourses: [CanvasCourseRef(code: "CIS 2400", term: fall2026)],
            edLinks: ["CIS 2400": 2]
        )
        #expect(matches == [EdCourseMatch(edCourseID: 2, canvasCourseCode: "CIS 2400", confidence: .link)])
    }

    @Test("a link to a course the student is not enrolled in is ignored")
    func linkToUnknownCourse() {
        let matches = EdCourseMatcher.match(
            edCourses: [ed(1, "CIS 2400", year: "2026", session: "Fall")],
            canvasCourses: [CanvasCourseRef(code: "CIS 2400", term: fall2026)],
            edLinks: ["CIS 2400": 777]
        )
        #expect(matches == [EdCourseMatch(edCourseID: 1, canvasCourseCode: "CIS 2400", confidence: .codeAndTerm)])
    }

    @Test("code and term beats code only; a missing term on either side is code only")
    func confidenceLevels() {
        let matches = EdCourseMatcher.match(
            edCourses: [
                ed(1, "CIS2400", year: "2026", session: "Fall"),
                ed(2, "MATH 1400-001"),
                ed(3, "PHYS 0151", year: "2026", session: "Fall"),
            ],
            canvasCourses: [
                CanvasCourseRef(code: "CIS 2400", term: fall2026),
                CanvasCourseRef(code: "MATH 1400", term: fall2026),
                CanvasCourseRef(code: "PHYS 0151", term: nil),
            ],
            edLinks: [:]
        )
        #expect(matches == [
            EdCourseMatch(edCourseID: 1, canvasCourseCode: "CIS 2400", confidence: .codeAndTerm),
            EdCourseMatch(edCourseID: 2, canvasCourseCode: "MATH 1400", confidence: .codeOnly),
            EdCourseMatch(edCourseID: 3, canvasCourseCode: "PHYS 0151", confidence: .codeOnly),
        ])
    }

    @Test("two Ed courses with one code: only the one matching the term is returned")
    func duplicateCodeResolvedByTerm() {
        let matches = EdCourseMatcher.match(
            edCourses: [ed(1, "CIS 2400", year: "2025", session: "Fall"), ed(2, "CIS 2400", year: "2026", session: "Fall")],
            canvasCourses: [CanvasCourseRef(code: "CIS 2400", term: fall2026)],
            edLinks: [:]
        )
        #expect(matches == [EdCourseMatch(edCourseID: 2, canvasCourseCode: "CIS 2400", confidence: .codeAndTerm)])
    }

    @Test("a previous offering with a known, different term is not matched")
    func differentTermIsNoMatch() {
        let matches = EdCourseMatcher.match(
            edCourses: [ed(1, "CIS 2400", year: "2025", session: "Fall")],
            canvasCourses: [CanvasCourseRef(code: "CIS 2400", term: fall2026)],
            edLinks: [:]
        )
        #expect(matches.isEmpty)
    }

    @Test("two code-only candidates with nothing to choose between match nothing")
    func ambiguousCodeOnly() {
        let matches = EdCourseMatcher.match(
            edCourses: [ed(1, "CIS 2400"), ed(2, "CIS 2400")],
            canvasCourses: [CanvasCourseRef(code: "CIS 2400", term: nil)],
            edLinks: [:]
        )
        #expect(matches.isEmpty)
    }

    @Test("an Ed course is never matched to two Canvas codes; the higher confidence wins")
    func noDoubleAssignment() {
        let matches = EdCourseMatcher.match(
            edCourses: [ed(1, "CIS 2400", year: "2026", session: "Fall")],
            canvasCourses: [
                CanvasCourseRef(code: "CIS 2400", term: nil),
                CanvasCourseRef(code: "CIS 2400-001", term: fall2026),
            ],
            edLinks: [:]
        )
        #expect(matches == [EdCourseMatch(edCourseID: 1, canvasCourseCode: "CIS 2400-001", confidence: .codeAndTerm)])

        // The same Ed course named by two links is claimed once.
        let linked = EdCourseMatcher.match(
            edCourses: [ed(1, "CIS 2400")],
            canvasCourses: [],
            edLinks: ["CIS 2400": 1, "CIS 2401": 1]
        )
        #expect(linked.count == 1)
    }
}

@Suite("Ed document builder")
struct EdDocumentBuilderTests {
    @Test("header carries the decision, category and subcategory, then the plain-text body")
    func headerAndBody() {
        let t = thread(
            42, pinned: true,
            document: "<document><paragraph>Bring ID.</paragraph></document>",
            category: "Homework", subcategory: "Hw 3"
        )
        let decision = EdThreadFilter.decide(t, authorRole: nil)
        #expect(EdDocumentBuilder.text(for: t, decision: decision) == "[ed · pinned] Homework / Hw 3\nBring ID.")
        #expect(EdDocumentBuilder.sourceID(for: t) == "42")
        #expect(EdDocumentBuilder.kind == "ed")
    }

    @Test("no category: header alone has just the label; a subcategory without a category is not shown")
    func headerWithoutCategory() {
        let t = thread(1, type: "announcement", document: "<document><paragraph>Hi</paragraph></document>", category: "", subcategory: "Sub")
        let decision = EdThreadFilter.decide(t, authorRole: nil)
        #expect(EdDocumentBuilder.text(for: t, decision: decision) == "[ed · announcement]\nHi")
    }

    @Test("falls back to tag-stripped content when there is no document")
    func contentFallback() {
        let t = thread(1, type: "announcement", document: nil, content: "<p>Hello<br>there</p>", category: "General")
        let decision = EdThreadFilter.decide(t, authorRole: nil)
        #expect(EdDocumentBuilder.text(for: t, decision: decision) == "[ed · announcement] General\nHello\nthere")
    }

    @Test("a thread with no body at all is just its header")
    func headerOnly() {
        let t = thread(1, type: "announcement")
        #expect(EdDocumentBuilder.text(for: t, decision: EdThreadDecision(keep: true, reason: "announcement")) == "[ed · announcement]")
    }

    @Test("title is trimmed, with a stand-in when blank")
    func titles() {
        #expect(EdDocumentBuilder.title(for: thread(1, title: "  Exam room  ")) == "Exam room")
        let blank = EdThread(id: 5, title: " ", number: 12)
        #expect(EdDocumentBuilder.title(for: blank) == "Ed thread #12")
        #expect(EdDocumentBuilder.title(for: EdThread(id: 5, title: "")) == "Ed thread #5")
    }
}
