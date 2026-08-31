import Foundation
import Testing
@testable import LowHangingFruitKit

/// Gradescope names the term on its account page ("Fall 2025") and, until the
/// stamp existed, threw it away: the label chose which courses to fetch and
/// nothing kept it, so every Gradescope assignment reached the app with
/// `term == nil` — the one field the semester archive acts on. A Canvas item
/// gets its term free, from the `YYYYTT` suffix in the course code.
///
/// These pin the term surviving the trip from a course heading to an assignment.
@Suite("Gradescope term stamping")
struct GradescopeTermStampTests {

    private static let baseURL = URL(string: "https://www.gradescope.com")!

    private static let twoTermHTML = """
    <div class="courseList">
      <div class="courseList--term">Spring 2026</div>
      <div class="courseList--coursesForTerm">
        <a class="courseBox" href="/courses/111">CIS 5500 Databases</a>
      </div>
      <div class="courseList--term">Fall 2025</div>
      <div class="courseList--coursesForTerm">
        <a class="courseBox" href="/courses/333">CIS 4000 Senior Design</a>
      </div>
    </div>
    """

    private static func utcDate(_ year: Int, _ month: Int, _ day: Int) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(
            timeZone: TimeZone(identifier: "UTC"),
            year: year, month: month, day: day, hour: 12, minute: 0
        ))
    }

    @Test("a course carries the term heading it was listed under")
    func courseCarriesItsTerm() throws {
        let now = try #require(Self.utcDate(2026, 5, 21))
        let result = GradescopeHTMLParser.currentTermCourses(
            from: Self.twoTermHTML, baseURL: Self.baseURL, now: now
        )

        let course = try #require(result.courses.first)
        #expect(result.courses.count == 1)
        #expect(course.term == Term(year: 2026, season: .spring))
    }

    @Test("an assignment inherits its course's term")
    func assignmentInheritsItsCoursesTerm() throws {
        let html = """
        <table>
          <tr>
            <td><a href="/courses/111/assignments/444">Homework 4</a></td>
            <td>No Submission</td>
            <td>June 2, 2026 at 11:59 PM</td>
          </tr>
        </table>
        """
        let spring = Term(year: 2026, season: .spring)
        let assignments = GradescopeHTMLParser.assignments(
            from: html,
            courseName: "CIS 5500 Databases",
            courseURL: URL(string: "https://www.gradescope.com/courses/111")!,
            term: spring,
            referenceDate: try #require(Self.utcDate(2026, 5, 21))
        )

        let homework = try #require(assignments.first)
        #expect(homework.source == .gradescope)
        #expect(homework.term == spring)
    }

    @Test("courses kept by the fallback path are stamped too")
    func fallbackCoursesCarryTheirTerm() throws {
        let html = """
        <div class="courseList">
          <div class="courseList--term">Fall 2025</div>
          <div class="courseList--coursesForTerm">
            <a class="courseBox" href="/courses/333">CIS 4000 Senior Design</a>
          </div>
        </div>
        """
        // Inside the 21-day grace window past Fall 2025's window ending.
        let now = try #require(Self.utcDate(2026, 1, 10))
        let result = GradescopeHTMLParser.currentTermCourses(
            from: html, baseURL: Self.baseURL, now: now
        )

        #expect(result.isFallback == true)
        #expect(result.courses.first?.term == Term(year: 2025, season: .fall))
    }

    @Test("a quarter school's Winter files under Penn's spring")
    func winterFilesUnderSpring() throws {
        let html = """
        <div class="courseList">
          <div class="courseList--term">Winter 2026</div>
          <div class="courseList--coursesForTerm">
            <a class="courseBox" href="/courses/777">MATH 1400 Calculus</a>
          </div>
        </div>
        """
        let now = try #require(Self.utcDate(2026, 2, 10))
        let result = GradescopeHTMLParser.currentTermCourses(
            from: html, baseURL: Self.baseURL, now: now
        )

        #expect(result.courses.first?.term == Term(year: 2026, season: .spring))
    }

    @Test("with no term heading to read, the term stays unknown rather than guessed")
    func ungroupedCoursesCarryNoTerm() throws {
        let html = """
        <main><a class="courseBox" href="/courses/999">CIS 1200 Programming</a></main>
        """
        let result = GradescopeHTMLParser.currentTermCourses(
            from: html, baseURL: Self.baseURL, now: try #require(Self.utcDate(2026, 5, 21))
        )

        #expect(result.courses.first?.term == nil)
    }
}
