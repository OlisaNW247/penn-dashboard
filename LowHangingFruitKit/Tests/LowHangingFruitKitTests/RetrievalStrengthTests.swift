import Foundation
import Testing
@testable import LowHangingFruitKit

/// Regression tests for the ways "ask" used to miss material that was in the
/// student's synced class files: the tokenizer, the stemmer, title indexing,
/// course scoping, course-name matching, query synonyms and HTML cleanup.
/// Each test pins one behaviour. Every search here goes through a cold
/// embedding provider so the order under test is BM25's, not whatever
/// `NLEmbedding` asset the machine running the suite happens to have.
@Suite("Retrieval strength")
struct RetrievalStrengthTests {
    private static func search(_ documents: [CourseDocument]) -> CourseSearch {
        CourseSearch(knowledge: CourseKnowledgeBase(documents: documents), embeddingProvider: SentenceEmbeddingProvider { nil })
    }

    private static func page(
        _ text: String,
        title: String = "Course page",
        id: String,
        course: String = "CIS 2400",
        courseID: String = "1",
        kind: CourseDocument.Kind = .page
    ) -> CourseDocument {
        CourseDocument(courseID: courseID, course: course, kind: kind, sourceID: id, title: title, url: nil, text: text)
    }

    // MARK: - Tokenizer

    @Test("a lone digit survives tokenization, a lone letter does not")
    func loneDigitsAreKept() {
        #expect(TextTokenizer.tokens("exam 2") == ["exam", "2"])
        #expect(TextTokenizer.tokens("lab 3 week 4 hw 1") == ["lab", "3", "week", "4", "hw", "1"])
        #expect(TextTokenizer.tokens("exam x") == ["exam"])
    }

    @Test("'exam 2' ranks the Exam 2 passage above Exam 1, even when Exam 1 comes first")
    func examNumberDecidesRanking() throws {
        // Exam 1 is listed first so a tie (the digit being thrown away on both
        // sides, as it used to be) would put it on top.
        let exam1 = Self.page("Exam 1 covers chapters 1 through 4 and is held in September.", id: "a")
        let exam2 = Self.page("Exam 2 covers chapters 5 through 8 and is held in November.", id: "b")
        let hits = Self.search([exam1, exam2]).search("when is exam 2")
        #expect(hits.first?.document.id == exam2.id)
    }

    // MARK: - Stemmer

    @Test("a singular and its plural reach the same stem")
    func singularAndPluralShareAStem() {
        let pairs = [
            ("grade", "grades"), ("absence", "absences"), ("date", "dates"), ("page", "pages"),
            ("class", "classes"), ("course", "courses"), ("exam", "exams"), ("quiz", "quizzes"),
            ("schedule", "scheduled"), ("office", "offices"), ("homework", "homeworks"),
        ]
        for (singular, plural) in pairs {
            #expect(TextTokenizer.stem(singular) == TextTokenizer.stem(plural), "\(singular) / \(plural)")
        }
    }

    // These two go to the index directly: through `CourseSearch`, "grading"'s
    // synonym group ("grade breakdown", "weights") would find the passage
    // even with a broken stemmer, and the point here is the stemmer.
    @Test("'grade' finds a passage that only says 'grades'")
    func singularQueryFindsPlural() {
        let index = BM25Index(passages: [
            Passage(documentID: "a", ordinal: 0, text: "The campus library opens at nine."),
            Passage(documentID: "b", ordinal: 0, text: "Grades are posted within a week of each deadline."),
        ])
        #expect(index.search("grade").first?.passageID == "b#0")
    }

    @Test("'grades' finds a passage that only says 'grade'")
    func pluralQueryFindsSingular() {
        let index = BM25Index(passages: [
            Passage(documentID: "a", ordinal: 0, text: "The campus library opens at nine."),
            Passage(documentID: "b", ordinal: 0, text: "Your final grade is the sum of the parts."),
        ])
        #expect(index.search("grades").first?.passageID == "b#0")
    }

    @Test("'absence' and 'absences' find each other")
    func absenceAndAbsences() {
        let singular = Self.page("One absence is excused without a note.", id: "a")
        let plural = Self.page("More than three absences lowers the participation mark.", id: "b")
        let distractor = Self.page("The campus library opens at nine.", id: "c")
        let search = Self.search([distractor, singular, plural])
        #expect(Set(search.search("absences").map(\.document.id)) == [singular.id, plural.id])
        #expect(Set(search.search("absence").map(\.document.id)) == [singular.id, plural.id])
    }

    // MARK: - Titles

    @Test("a query that matches only a document's title finds that document")
    func titleOnlyQueryFindsDocument() {
        let review = Self.page("Bring a calculator and two pencils. Practice problems are posted online.", title: "Midterm 2 review", id: "a")
        let other = Self.page("Bring a laptop and a charger to every session.", title: "Setup", id: "b")
        let hits = Self.search([other, review]).search("midterm 2 review")
        #expect(hits.first?.document.id == review.id)
    }

    @Test("only the first dozen distinct words of a title are indexed")
    func longTitleIsCapped() {
        let title = "alpha bravo charlie delta echo foxtrot golf hotel india juliet kilo lima mike november"
        let passage = Passage(documentID: "d", ordinal: 0, text: "unrelated body text about nothing")
        let index = BM25Index(passages: [passage], titles: ["d": title])
        #expect(!index.search("alpha").isEmpty)
        #expect(index.search("november").isEmpty)
    }

    // MARK: - Scope before the cut

    @Test("a question naming one course still gets its passages when 45 stronger ones sit in other courses")
    func scopeIsAppliedBeforeTheCut() {
        var documents: [CourseDocument] = []
        for n in 0..<45 {
            documents.append(Self.page(
                "Late policy. Late work is penalized. The late penalty for late homework is ten percent per late day under this late policy.",
                title: "Syllabus \(n)", id: "s\(n)", course: "OTHR \(n % 4)", courseID: "other\(n % 4)", kind: .syllabus
            ))
        }
        let target = Self.page("Homework may be turned in late with a note to the instructor.", id: "target", course: "CIS 2400", courseID: "target")
        let hits = Self.search(documents + [target]).search("late policy", courseIDs: ["target"], limit: 3)
        #expect(!hits.isEmpty)
        #expect(hits.allSatisfy { $0.document.courseID == "target" })
    }

    @Test("a scoped search with no hits retries once, unscoped")
    func emptyScopeFallsBackToUnscoped() {
        let cis = Self.page("Grading is homework and exams.", id: "a", course: "CIS 2400", courseID: "1", kind: .syllabus)
        let econ = Self.page("The guest lecture on tariffs moved to Thursday.", id: "b", course: "ECON 1", courseID: "2", kind: .announcement)
        let hits = Self.search([cis, econ]).search("when is the tariffs lecture", courseIDs: ["1"])
        #expect(hits.first?.document.id == econ.id)
    }

    @Test("a scope that does have hits is never widened")
    func scopeWithHitsStaysScoped() {
        let cis = Self.page("The guest lecture on tariffs is optional.", id: "a", course: "CIS 2400", courseID: "1")
        let econ = Self.page("The guest lecture on tariffs moved to Thursday.", id: "b", course: "ECON 1", courseID: "2")
        let hits = Self.search([cis, econ]).search("tariffs lecture", courseIDs: ["1"])
        #expect(hits.map(\.document.courseID) == ["1"])
    }

    // MARK: - Result limits

    @Test("a document contributes two passages by default and more when the caller asks")
    func perDocumentCapIsAdjustable() {
        let paragraph = "tariff " + Array(repeating: "filler", count: 99).joined(separator: " ")
        let long = Self.page(Array(repeating: paragraph, count: 4).joined(separator: "\n"), id: "long")
        let search = Self.search([long])
        #expect(search.search("tariff", limit: 8).count == 2)
        #expect(search.search("tariff", limit: 8, perDocument: 4).count == 4)
    }

    // MARK: - Course names

    private static let lecture = CourseSummary(courseID: "1", code: "PHYS 0151", name: "PHYS 0151-151 Principles of Physics", url: nil)
    private static let lab = CourseSummary(courseID: "2", code: "PHYS 0151", name: "PHYS 0151-401 Physics Lab", url: nil)
    private static let cis = CourseSummary(courseID: "3", code: "CIS 2400", name: "CIS 2400 Intro to Computer Systems", url: nil)
    /// A second course in the same department. With it present, a department
    /// word alone ("phys") is ambiguous, so the tests below can only pass by
    /// reading the course number itself.
    private static let mechanics = CourseSummary(courseID: "4", code: "PHYS 0150", name: "PHYS 0150 Mechanics", url: nil)

    @Test("'phys 151' names the course PHYS 0151")
    func leadingZeroIsOptional() {
        let match = CourseMatcher.match(in: "when is the phys 151 midterm", courses: [Self.cis, Self.mechanics, Self.lecture])
        #expect(match?.course.courseID == "1")
    }

    @Test("'phys151' names the course PHYS 0151")
    func noSpaceAndNoLeadingZero() {
        let match = CourseMatcher.match(in: "phys151 late policy", courses: [Self.cis, Self.mechanics, Self.lecture])
        #expect(match?.course.courseID == "1")
    }

    @Test("a typed leading zero still names a course stored without one")
    func typedLeadingZeroMatchesBareCode() {
        let bare = CourseSummary(courseID: "9", code: "MATH 104", name: "MATH 104 Calculus", url: nil)
        let sibling = CourseSummary(courseID: "8", code: "MATH 114", name: "MATH 114 Calculus II", url: nil)
        let match = CourseMatcher.match(in: "math 0104 homework", courses: [Self.cis, sibling, bare])
        #expect(match?.course.courseID == "9")
    }

    @Test("'my phys class' matches when a lecture and a lab share the code")
    func departmentMentionMatchesSplitCourse() {
        let match = CourseMatcher.match(in: "when is my phys quiz", courses: [Self.cis, Self.lecture, Self.lab])
        #expect(match?.course.code == "PHYS 0151")
    }

    @Test("'my phys class' still matches nothing when two different PHYS courses exist")
    func departmentMentionStaysAmbiguousAcrossCodes() {
        #expect(CourseMatcher.match(in: "when is my phys quiz", courses: [Self.cis, Self.lecture, Self.mechanics]) == nil)
    }

    // MARK: - Synonyms

    @Test("'when is the midterm' finds a passage that only says 'Exam 1'")
    func midtermFindsExam() {
        let exam = Self.page("Exam 1 will be held on October 14 in class.", id: "a")
        let other = Self.page("Tuesday sessions meet in the main lecture hall.", id: "b")
        #expect(Self.search([other, exam]).search("when is the midterm").first?.document.id == exam.id)
    }

    @Test("'hw' finds a passage that says 'problem set'")
    func hwFindsProblemSet() {
        let pset = Self.page("Problem Set 3 is due Friday at five.", id: "a")
        let other = Self.page("Tuesday sessions meet in the main lecture hall.", id: "b")
        #expect(Self.search([other, pset]).search("when is hw due").first?.document.id == pset.id)
    }

    @Test("each synonym group reaches a passage that never uses the student's word", arguments: [
        ("when is the prelim", "Exam 1 takes place in October."),
        ("when is the final", "Exam 3 takes place during exam week."),
        ("who is the ta", "Your teaching assistant will email you."),
        ("when is oh", "Office hours are on Tuesdays."),
        ("contact the prof", "Reach your instructor with questions."),
        ("attendance", "A single absence is excused with a note."),
        ("extension", "Lateness costs ten percent per day."),
        ("grading", "Weights: homework forty percent, exams sixty."),
        ("pset due", "Homework is collected on Fridays."),
    ])
    func synonymGroupsReachTheirPassage(query: String, text: String) {
        let target = Self.page(text, id: "target")
        let distractor = Self.page("The campus library opens at nine.", id: "distractor")
        #expect(Self.search([distractor, target]).search(query).first?.document.id == target.id)
    }

    @Test("an expansion word counts for less than the student's own")
    func expansionCountsLess() {
        let terms = QueryExpansion.weightedTerms(for: "midterm")
        let own = terms.first { $0.term == "midterm" }
        let guessed = terms.first { $0.term == "exam" }
        #expect(own?.weight == 1)
        #expect((guessed?.weight ?? 1) < 1)
        #expect(guessed != nil)
    }

    @Test("a passage with the student's own word outranks one that only matches a synonym")
    func ownWordOutranksSynonym() {
        let own = Self.page("The midterm is on Friday.", id: "own")
        let synonym = Self.page("Exam material: exam rules, exam room, exam format, and exam grading.", id: "synonym")
        #expect(Self.search([synonym, own]).search("midterm").first?.document.id == own.id)
    }

    @Test("a synonym the student also typed keeps its full weight")
    func typedSynonymKeepsFullWeight() {
        let terms = QueryExpansion.weightedTerms(for: "midterm exam")
        #expect(terms.first { $0.term == "exam" }?.weight == 1)
    }

    @Test("the index itself never expands: a passage saying only 'exam' is not found by 'midterm'")
    func indexDoesNotExpand() {
        let index = BM25Index(passages: [Passage(documentID: "d", ordinal: 0, text: "The exam is on Friday.")])
        #expect(index.search("midterm").isEmpty)
        #expect(!index.search("exam").isEmpty)
    }

    // MARK: - HTML cleanup

    @Test("a multi-line <style> block leaves no CSS behind")
    func multiLineStyleIsRemoved() {
        let html = "<p>Before</p><style type=\"text/css\">\n.note { color: red; }\n.box { margin: 0; }\n</style><p>After</p>"
        let text = HTMLText.plainText(from: html)
        #expect(text == "Before\nAfter")
    }

    @Test("a multi-line <script> block leaves no JavaScript behind")
    func multiLineScriptIsRemoved() {
        let html = "<p>Before</p><script>\nvar secret = 1;\nfunction hidden() { return secret; }\n</script><p>After</p>"
        let text = HTMLText.plainText(from: html)
        #expect(text == "Before\nAfter")
    }

    @Test("a multi-line HTML comment that contains a '>' leaves nothing behind")
    func multiLineCommentIsRemoved() {
        // Word-pasted Canvas pages carry comments like this one. Without a
        // '>' inside, the generic tag stripper happened to swallow the whole
        // comment anyway; with one, it stopped at the first '>' and the rest
        // of the comment was indexed as prose.
        let html = "<p>Before</p><!--[if gte mso 9]><xml>\n<o:Settings>hidden word</o:Settings>\n</xml><![endif]-->\n<p>After</p>"
        let text = HTMLText.plainText(from: html)
        #expect(text == "Before\nAfter")
    }
}
