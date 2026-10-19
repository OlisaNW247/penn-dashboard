import Foundation
import Testing
@testable import LowHangingFruitKit

/// An assignment's own name must never decide whether it was handed in.
///
/// `GradescopeHTMLParser.parseAssignmentRow` reads "submitted" from keyword
/// text in the row, and the name cell is part of the row. A name such as
/// "Graded Problem Set 3" or "Resubmit Lab 2" therefore read as submitted even
/// when the status cell said "No Submission". The detail page
/// (`isCompletedAssignmentPage`) repeats the name in its heading and `<title>`
/// and had the same hazard. These tests pin the text with the name blanked out
/// as the only thing that votes.
///
/// Not every test here failed on the old code, and the ones that did not are
/// labelled "pin" in a comment: they hold behaviour that must survive the
/// change (a guard, a table-layout reading, an unchanged ordinary title). The
/// ones that did fail on it are the window-layout fixtures, the detail-page
/// fixtures, and the table fixtures whose title carries a positive keyword.
@Suite("Gradescope row status ignores the assignment's own title")
struct GradescopeTitleStatusTests {

    private static let courseURL = URL(string: "https://www.gradescope.com/courses/12345")!

    private static func parse(_ html: String) -> [Assignment] {
        GradescopeHTMLParser.assignments(
            from: html,
            courseName: "CIS 5050 Software Systems",
            courseURL: courseURL
        )
    }

    /// The submitted-work shape: the name is a link to the submission page.
    private static func linkedRow(id: Int, title: String, status: String) -> String {
        """
        <tr>
          <th><a href="/courses/12345/assignments/\(id)">\(title)</a></th>
          <td>\(status)</td>
          <td>May 1 at 12:00 PM</td>
          <td>June 2, 2026 at 11:59 PM</td>
        </tr>
        """
    }

    /// The unsubmitted-work shape: the name is a "submit" button carrying
    /// `data-assignment-id` / `data-assignment-title`, with no href.
    private static func buttonRow(id: Int, title: String, status: String) -> String {
        """
        <tr>
          <th><button class="js-submitAssignment" data-assignment-id="\(id)" data-assignment-title="\(title)">\(title)</button></th>
          <td>\(status)</td>
          <td>June 2, 2026 at 11:59 PM</td>
        </tr>
        """
    }

    @Test("a title containing 'graded' is not submitted when the status cell says No Submission")
    func gradedInTitleWithNoSubmission() throws {
        let linked = try #require(Self.parse("<table>\(Self.linkedRow(id: 1, title: "Graded Problem Set 3", status: "No Submission"))</table>").first)
        #expect(linked.title == "Graded Problem Set 3")
        #expect(linked.submitted == false)

        let button = try #require(Self.parse("<table>\(Self.buttonRow(id: 2, title: "Graded Problem Set 3", status: "No Submission"))</table>").first)
        #expect(button.submitted == false)
    }

    @Test("a title containing 'resubmission' is not submitted when the status cell says No Submission")
    func resubmissionInTitleWithNoSubmission() throws {
        // Pin, not a discriminator: "resubmit" is not a substring of
        // "resubmission", so the old scan never read this title as handed in.
        // "Resubmit Lab 2" below is the one that did.
        let linked = try #require(Self.parse("<table>\(Self.linkedRow(id: 3, title: "Resubmission: Lab 2", status: "No Submission"))</table>").first)
        #expect(linked.title == "Resubmission: Lab 2")
        #expect(linked.submitted == false)

        let button = try #require(Self.parse("<table>\(Self.buttonRow(id: 4, title: "Resubmission: Lab 2", status: "No Submission"))</table>").first)
        #expect(button.submitted == false)
    }

    @Test("a title containing 'resubmit', 'uploaded' or 'submitted' is not submitted when the status cell says Not Submitted")
    func otherKeywordTitlesStayNotSubmitted() throws {
        // "Resubmission: Lab 2" above does not actually trip the keyword scan
        // ("resubmit" is not a substring of "resubmission"), so it pins the
        // behaviour without discriminating. "Resubmit Lab 2" is the title that
        // did read as handed in before the name was excluded.
        for (id, title) in [(5, "Uploaded Files Quiz"), (6, "Submitted Work Reflection"), (15, "Resubmit Lab 2")] {
            let row = try #require(Self.parse("<table>\(Self.linkedRow(id: id, title: title, status: "Not Submitted"))</table>").first)
            #expect(row.submitted == false, "\(title)")
        }
    }

    @Test("a title containing a negative word still reads submitted when the status cell says Submitted")
    func negativeWordInTitleDoesNotSuppressSubmitted() throws {
        // Pin for the TABLE layout only. A table row's cells are scanned one at
        // a time, so the "Submitted" cell won even before the title was
        // blanked. The layout where a negative word in the name really did
        // suppress a genuine "Submitted" is the window one: see
        // `windowLayoutNegativeWordTitleStillSubmitted`.
        let linked = try #require(Self.parse("<table>\(Self.linkedRow(id: 7, title: "Missing Data Lab", status: "Submitted"))</table>").first)
        #expect(linked.title == "Missing Data Lab")
        #expect(linked.submitted == true)
    }

    @Test("an ordinary title with a Submitted status is unchanged")
    func ordinaryTitleSubmitted() throws {
        let submitted = try #require(Self.parse("<table>\(Self.linkedRow(id: 8, title: "Lab 4", status: "Submitted"))</table>").first)
        #expect(submitted.submitted == true)

        let graded = try #require(Self.parse("<table>\(Self.linkedRow(id: 9, title: "Lab 4", status: "Graded"))</table>").first)
        #expect(graded.submitted == true)

        let notYet = try #require(Self.parse("<table>\(Self.linkedRow(id: 10, title: "Lab 4", status: "No Submission"))</table>").first)
        #expect(notYet.submitted == false)
    }

    @Test("a title with an HTML entity is blanked as the decoded text, so its keywords still do not vote")
    func entityTitleDecodedBeforeBlanking() throws {
        let row = try #require(Self.parse("<table>\(Self.linkedRow(id: 11, title: "Graded &amp; Reflective Essay", status: "No Submission"))</table>").first)
        #expect(row.title == "Graded & Reflective Essay")
        #expect(row.submitted == false)
    }

    @Test("non-table markup: the link text is blanked from the row window too")
    func windowLayoutIgnoresTitle() throws {
        // Pin: both halves also passed on the old code (the first is negative
        // by its status text alone, the second positive by its status text
        // alone). The next two tests are the window fixtures it failed.
        let html = """
        <section>
          <a href="/courses/12345/assignments/12">Graded Problem Set 3</a>
          <span>Due Date: May 24, 2026, 11:59 PM</span>
          <span>Status: No Submission</span>
        </section>
        """
        let row = try #require(Self.parse(html).first)
        #expect(row.submitted == false)

        let submittedHTML = """
        <section>
          <a href="/courses/12345/assignments/13">Graded Problem Set 3</a>
          <span>Due Date: May 24, 2026, 11:59 PM</span>
          <span>Status: Submitted</span>
        </section>
        """
        let submitted = try #require(Self.parse(submittedHTML).first)
        #expect(submitted.submitted == true)
    }

    @Test("non-table markup: a keyword in the title with a status that has no keyword is not submitted")
    func windowLayoutTitleKeywordWithOpenStatus() throws {
        // Old code: the window's whole text is "Graded Problem Set 3 Due Date:
        // ... Status: Open", "graded" is positive, so this read as submitted.
        let html = """
        <section>
          <a href="/courses/12345/assignments/16">Graded Problem Set 3</a>
          <span>Due Date: May 24, 2026, 11:59 PM</span>
          <span>Status: Open</span>
        </section>
        """
        let row = try #require(Self.parse(html).first)
        #expect(row.title == "Graded Problem Set 3")
        #expect(row.submitted == false)
    }

    @Test("non-table markup: a negative word in the title does not suppress a genuine Submitted status")
    func windowLayoutNegativeWordTitleStillSubmitted() throws {
        // Old code: a window has no table cells, only the whole text, and
        // "missing" in the name made that text negative before "Submitted"
        // was ever consulted, so a handed-in assignment read as not done.
        let html = """
        <section>
          <a href="/courses/12345/assignments/17">Missing Data Lab</a>
          <span>Due Date: May 24, 2026, 11:59 PM</span>
          <span>Status: Submitted</span>
        </section>
        """
        let row = try #require(Self.parse(html).first)
        #expect(row.title == "Missing Data Lab")
        #expect(row.submitted == true)
    }

    @Test("a title that is only a negation is not blanked, so Not Submitted stays negative")
    func negationOnlyTitleStaysNotSubmitted() throws {
        // Guard pin. Blanking "Not" from "Not Submitted" would leave
        // " Submitted", which reads as handed in. The old code never blanked
        // anything, so it passed this too; a blanking without the guard fails.
        for (id, title, status) in [(18, "Not", "Not Submitted"), (19, "No", "No Submission"), (20, "Missing", "Missing")] {
            let row = try #require(Self.parse("<table>\(Self.linkedRow(id: id, title: title, status: status))</table>").first)
            #expect(row.submitted == false, "\(title) / \(status)")
        }
    }

    @Test("the score is still read from a row whose title was blanked, and the status verdict matches the same row with a plain title")
    func scoreStillReadFromTitledRow() throws {
        let html = """
        <table><tr>
          <th><a href="/courses/12345/assignments/14">Graded Problem Set 3</a></th>
          <td>87.5 / 100.0</td>
          <td>June 2, 2026 at 11:59 PM</td>
        </tr></table>
        """
        // The bare fraction cell is not a keyword and was never a status
        // signal on its own, so this row has no status words and stays
        // not-submitted, exactly as a plain "Problem Set 3" with the same
        // cells does today. What must survive the change is the score.
        let row = try #require(Self.parse(html).first)
        #expect(row.scoreEarned == 87.5)
        #expect(row.scoreMax == 100)
        let plain = try #require(Self.parse(html.replacingOccurrences(of: "Graded Problem Set 3", with: "Problem Set 3")).first)
        #expect(row.submitted == plain.submitted)
    }

    // MARK: - removingTitle

    @Test("removingTitle ignores case and whitespace runs, and replaces with a space")
    func removingTitleCaseAndWhitespace() {
        #expect(GradescopeHTMLParser.removingTitle("Graded Problem Set 3", from: "GRADED   problem set 3 No Submission")
            .trimmingCharacters(in: .whitespaces) == "No Submission")
        #expect(GradescopeHTMLParser.removingTitle("Lab 2", from: "xLab 2y")  == "xLab 2y")
        // Blanked to a space, so neighbours cannot fuse into a keyword.
        #expect(GradescopeHTMLParser.removingTitle("Lab", from: "sub Lab mitted") == "sub   mitted")
    }

    @Test("removingTitle never eats part of a longer word")
    func removingTitleRespectsWordBoundaries() {
        #expect(GradescopeHTMLParser.removingTitle("Lab", from: "Labelled Lab Labs") == "Labelled   Labs")
    }

    @Test("removingTitle treats the title literally, not as a pattern")
    func removingTitleEscapesRegexCharacters() {
        #expect(GradescopeHTMLParser.removingTitle("HW (1+2) [final]", from: "HW (1+2) [final] Submitted")
            .trimmingCharacters(in: .whitespaces) == "Submitted")
        #expect(GradescopeHTMLParser.removingTitle("a.c", from: "abc a.c").trimmingCharacters(in: .whitespaces) == "abc")
    }

    @Test("removingTitle with an empty title changes nothing")
    func removingTitleEmpty() {
        #expect(GradescopeHTMLParser.removingTitle("", from: "Submitted") == "Submitted")
        #expect(GradescopeHTMLParser.removingTitle("   ", from: "Submitted") == "Submitted")
    }

    @Test("removingTitle leaves text alone when the title is a whole-word run of a negative phrase")
    func removingTitleGuardsNegativePhrases() {
        #expect(GradescopeHTMLParser.removingTitle("Not", from: "Not Submitted") == "Not Submitted")
        #expect(GradescopeHTMLParser.removingTitle("no", from: "No Submission") == "No Submission")
        #expect(GradescopeHTMLParser.removingTitle("Not Graded", from: "Not Graded") == "Not Graded")
        #expect(GradescopeHTMLParser.removingTitle("Graded", from: "Not Graded") == "Not Graded")
        #expect(GradescopeHTMLParser.removingTitle("Missing", from: "Missing") == "Missing")
        // "Un" is not a whole word of "unsubmitted", and the word boundary keeps
        // it from being eaten out of that word either way.
        #expect(GradescopeHTMLParser.removingTitle("Un", from: "Unsubmitted") == "Unsubmitted")
        // A title that merely contains a negative word, or whose words are not
        // consecutive inside one phrase, is still blanked.
        #expect(GradescopeHTMLParser.removingTitle("Missing Data Lab", from: "Missing Data Lab Submitted")
            .trimmingCharacters(in: .whitespaces) == "Submitted")
        #expect(GradescopeHTMLParser.removingTitle("Not Late", from: "Not Late Submitted")
            .trimmingCharacters(in: .whitespaces) == "Submitted")
    }

    // MARK: - The detail page

    /// A detail page whose only keyword is the assignment's own name, in its
    /// `<title>` and its heading.
    private static let titleOnlyDetailPage = """
    <html>
      <head><title>Graded Problem Set 3</title></head>
      <body><h1>Graded Problem Set 3</h1></body>
    </html>
    """

    @Test("a detail page whose only keyword is the title is not completed when the title is given")
    func detailPageTitleOnlyIsNotCompleted() {
        #expect(!GradescopeHTMLParser.isCompletedAssignmentPage(Self.titleOnlyDetailPage, title: "Graded Problem Set 3"))
        // The no-title call keeps its old reading of the very same page.
        #expect(GradescopeHTMLParser.isCompletedAssignmentPage(Self.titleOnlyDetailPage))
        #expect(GradescopeHTMLParser.isCompletedAssignmentPage(Self.titleOnlyDetailPage, title: nil))
    }

    @Test("the same detail page with a real Submitted status is completed")
    func detailPageWithRealStatusIsCompleted() {
        let page = """
        <html>
          <head><title>Graded Problem Set 3</title></head>
          <body><h1>Graded Problem Set 3</h1><p>Status: Submitted</p></body>
        </html>
        """
        #expect(GradescopeHTMLParser.isCompletedAssignmentPage(page, title: "Graded Problem Set 3"))
    }

    @Test("a detail page whose title holds a negative word is still completed by its real status")
    func detailPageNegativeWordTitleStillCompleted() {
        // Old reading: one text for the whole page, "missing" in the heading
        // made it negative, so a handed-in assignment read as not submitted.
        let page = """
        <html>
          <head><title>Missing Data Lab | Gradescope</title></head>
          <body><h1>Missing Data Lab</h1><p>Submitted at Oct 5, 2026 at 11:12 PM</p></body>
        </html>
        """
        #expect(GradescopeHTMLParser.isCompletedAssignmentPage(page, title: "Missing Data Lab"))
        #expect(!GradescopeHTMLParser.isCompletedAssignmentPage(page))
    }

    @Test("a detail page for a negation-only title keeps its Not Submitted reading")
    func detailPageNegationOnlyTitle() {
        let page = "<html><head><title>Not</title></head><body><h1>Not</h1><p>Not Submitted</p></body></html>"
        #expect(!GradescopeHTMLParser.isCompletedAssignmentPage(page, title: "Not"))
    }

    @Test("passing a title to a detail page changes nothing for pages whose keywords are not the title")
    func detailPageOrdinaryFixturesUnchangedByTitle() {
        let submittedHTML = """
        <main>
          <h1>Homework 4</h1>
          <a href="/courses/12345/assignments/444/submissions/999">View Submission</a>
          <button>Resubmit</button>
        </main>
        """
        let scoredHTML = "<main><h1>Project Demo</h1><div>Score: 10 / 10</div></main>"
        let missingHTML = """
        <main>
          <h1>Optional Practice</h1>
          <p>No submissions yet</p>
          <button>Submit Assignment</button>
        </main>
        """
        for (html, title) in [(submittedHTML, "Homework 4"), (scoredHTML, "Project Demo"), (missingHTML, "Optional Practice")] {
            #expect(GradescopeHTMLParser.isCompletedAssignmentPage(html, title: title)
                == GradescopeHTMLParser.isCompletedAssignmentPage(html))
        }
    }
}
