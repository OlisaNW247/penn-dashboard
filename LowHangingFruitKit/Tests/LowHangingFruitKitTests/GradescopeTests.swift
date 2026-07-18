import Foundation
import Testing
@testable import LowHangingFruitKit

@Suite("Gradescope scraping")
struct GradescopeTests {
    @Test("discovers course links from account page")
    func discoversCourses() throws {
        let html = """
        <main>
          <a class="courseBox" href="/courses/12345">CIS 5050 Software Systems</a>
          <a class="courseBox" href="https://www.gradescope.com/courses/67890">ENM 5100</a>
          <a href="/courses/12345">CIS 5050 Software Systems</a>
        </main>
        """

        let courses = GradescopeHTMLParser.courseLinks(
            from: html,
            baseURL: URL(string: "https://www.gradescope.com")!
        )

        #expect(courses.count == 2)
        #expect(courses[0].name == "CIS 5050 Software Systems")
        #expect(courses[0].url.absoluteString == "https://www.gradescope.com/courses/12345")
        #expect(courses[1].name == "ENM 5100")
    }

    @Test("keeps only the current term's courses")
    func keepsOnlyCurrentTermCourses() throws {
        let html = """
        <div class="courseList">
          <div class="courseList--term">Spring 2026</div>
          <div class="courseList--coursesForTerm">
            <a class="courseBox" href="/courses/111">CIS 5500 Databases</a>
            <a class="courseBox" href="/courses/222">CIS 5050 Software Systems</a>
          </div>
          <div class="courseList--term">Fall 2025</div>
          <div class="courseList--coursesForTerm">
            <a class="courseBox" href="/courses/333">CIS 4000 Senior Design</a>
          </div>
          <div class="courseList--term">Spring 2025</div>
          <div class="courseList--coursesForTerm">
            <a class="courseBox" href="/courses/444">CIS 1200 Programming</a>
          </div>
        </div>
        """

        let now = try #require(Self.utcDate(year: 2026, month: 5, day: 21, hour: 12, minute: 0))
        let courses = GradescopeHTMLParser.currentTermCourses(
            from: html,
            baseURL: URL(string: "https://www.gradescope.com")!,
            now: now
        )

        #expect(courses.count == 2)
        let ids = Set(courses.map(\.url.absoluteString))
        #expect(ids.contains("https://www.gradescope.com/courses/111"))
        #expect(ids.contains("https://www.gradescope.com/courses/222"))
        #expect(!ids.contains("https://www.gradescope.com/courses/333"))
        #expect(!ids.contains("https://www.gradescope.com/courses/444"))
    }

    @Test("falls back to the most recent term when none matches today")
    func fallsBackToMostRecentTerm() throws {
        let html = """
        <div class="courseList">
          <div class="courseList--term">Fall 2025</div>
          <div class="courseList--coursesForTerm">
            <a class="courseBox" href="/courses/333">CIS 4000 Senior Design</a>
          </div>
          <div class="courseList--term">Spring 2025</div>
          <div class="courseList--coursesForTerm">
            <a class="courseBox" href="/courses/444">CIS 1200 Programming</a>
          </div>
        </div>
        """

        // July 2026 (summer) — no matching term, so the newest (Fall 2025) wins.
        let now = try #require(Self.utcDate(year: 2026, month: 7, day: 1, hour: 12, minute: 0))
        let courses = GradescopeHTMLParser.currentTermCourses(
            from: html,
            baseURL: URL(string: "https://www.gradescope.com")!,
            now: now
        )

        #expect(courses.count == 1)
        #expect(courses.first?.url.absoluteString == "https://www.gradescope.com/courses/333")
    }

    @Test("falls back to all courses when there are no term headings")
    func fallsBackWhenNoTermHeadings() throws {
        let html = """
        <main>
          <a class="courseBox" href="/courses/111">CIS 5500 Databases</a>
          <a class="courseBox" href="/courses/222">CIS 5050 Software Systems</a>
        </main>
        """

        let courses = GradescopeHTMLParser.currentTermCourses(
            from: html,
            baseURL: URL(string: "https://www.gradescope.com")!
        )

        #expect(courses.count == 2)
    }

    @Test("parses assignments from a course table")
    func parsesAssignments() throws {
        let html = """
        <table>
          <tr>
            <th>Name</th><th>Status</th><th>Released</th><th>Due</th>
          </tr>
          <tr>
            <td><a href="/courses/12345/assignments/444">Homework 4 &amp; writeup</a></td>
            <td>Not Submitted</td>
            <td>May 1 at 12:00 PM</td>
            <td>May 24 at 11:59 PM</td>
          </tr>
          <tr>
            <td><a href="/courses/12345/assignments/555">Project Checkpoint</a></td>
            <td>Submitted</td>
            <td>May 5 at 12:00 PM</td>
            <td>June 2, 2026 at 11:59 PM</td>
          </tr>
          <tr>
            <td><a href="/courses/12345/assignments/666">Quiz Retake</a></td>
            <td>Graded</td>
            <td>May 8 at 12:00 PM</td>
            <td>June 4, 2026 at 11:59 PM</td>
          </tr>
          <tr>
            <td><a href="/courses/12345/assignments/777">Optional Practice</a></td>
            <td>Ungraded</td>
            <td>May 8 at 12:00 PM</td>
            <td>June 6, 2026 at 11:59 PM</td>
          </tr>
        </table>
        """

        let reference = try #require(Self.utcDate(year: 2026, month: 5, day: 21, hour: 12, minute: 0))
        let assignments = GradescopeHTMLParser.assignments(
            from: html,
            courseName: "CIS 5050 Software Systems",
            courseURL: URL(string: "https://www.gradescope.com/courses/12345")!,
            referenceDate: reference
        )

        #expect(assignments.count == 4)

        let hw = try #require(assignments.first { $0.sourceID == "course-12345-assignment-444" })
        #expect(hw.source == .gradescope)
        #expect(hw.kind == .assignment)
        #expect(hw.course == "CIS 5050 Software Systems")
        #expect(hw.title == "Homework 4 & writeup")
        #expect(hw.url?.absoluteString == "https://www.gradescope.com/courses/12345/assignments/444")
        #expect(hw.submitted == false)

        let checkpoint = try #require(assignments.first { $0.sourceID == "course-12345-assignment-555" })
        #expect(checkpoint.submitted == true)
        #expect(checkpoint.dueAt != nil)

        let graded = try #require(assignments.first { $0.sourceID == "course-12345-assignment-666" })
        #expect(graded.submitted == true)

        let ungraded = try #require(assignments.first { $0.sourceID == "course-12345-assignment-777" })
        #expect(ungraded.submitted == false)
    }

    @Test("parses due date and time from non-table Gradescope markup")
    func parsesDueDateFromSummaryMarkup() throws {
        let html = """
        <section>
          <a href="/courses/12345/assignments/888">Written Homework</a>
          <span>Due Date: May 24, 2026, 11:59 PM</span>
          <span>Status: Not Submitted</span>
        </section>
        """

        let assignments = GradescopeHTMLParser.assignments(
            from: html,
            courseName: "CIS 5050 Software Systems",
            courseURL: URL(string: "https://www.gradescope.com/courses/12345")!
        )

        let assignment = try #require(assignments.first)
        let due = try #require(assignment.dueAt)
        let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: due)

        #expect(components.year == 2026)
        #expect(components.month == 5)
        #expect(components.day == 24)
        #expect(components.hour == 23)
        #expect(components.minute == 59)
        #expect(assignment.submitted == false)
    }

    @Test("parses separate card assignments with datetime attributes")
    func parsesCardAssignmentsWithDatetimeAttributes() throws {
        let html = """
        <div class="assignment">
          <a href="/courses/12345/assignments/888">Written Homework</a>
          <time datetime="2026-05-24T23:59:00-04:00">Due May 24 at 11:59 PM EDT</time>
          <span>Status: Not Submitted</span>
        </div>
        <div class="assignment">
          <a href="/courses/12345/assignments/999">Project Demo</a>
          <span data-due-date="2026-06-02T17:30:00-04:00">Due Jun 2 at 5:30 PM EDT</span>
          <span>Status: Submitted</span>
        </div>
        """

        let assignments = GradescopeHTMLParser.assignments(
            from: html,
            courseName: "CIS 5050 Software Systems",
            courseURL: URL(string: "https://www.gradescope.com/courses/12345")!
        )

        #expect(assignments.count == 2)

        let homework = try #require(assignments.first { $0.sourceID == "course-12345-assignment-888" })
        let homeworkDue = try #require(homework.dueAt)
        var easternCalendar = Calendar(identifier: .gregorian)
        easternCalendar.timeZone = TimeZone(identifier: "America/New_York")!
        let homeworkComponents = easternCalendar.dateComponents([.year, .month, .day, .hour, .minute], from: homeworkDue)
        #expect(homeworkComponents.year == 2026)
        #expect(homeworkComponents.month == 5)
        #expect(homeworkComponents.day == 24)

        let demo = try #require(assignments.first { $0.sourceID == "course-12345-assignment-999" })
        let demoDue = try #require(demo.dueAt)
        let demoComponents = easternCalendar.dateComponents([.year, .month, .day, .hour, .minute], from: demoDue)
        #expect(demoComponents.year == 2026)
        #expect(demoComponents.month == 6)
        #expect(demoComponents.day == 2)
        #expect(demo.submitted == true)
    }

    @Test("yearless date far in the future resolves to last year")
    func yearlessFutureResolvesToLastYear() throws {
        let reference = try #require(Self.utcDate(year: 2026, month: 5, day: 21, hour: 12, minute: 0))
        let due = try #require(GradescopeHTMLParser.parseDate("Oct 15 at 11:59 PM", referenceDate: reference))
        let year = Calendar.current.component(.year, from: due)
        #expect(year == 2025)
    }

    @Test("yearless near-future date keeps the current year")
    func yearlessNearFutureKeepsCurrentYear() throws {
        let reference = try #require(Self.utcDate(year: 2026, month: 5, day: 21, hour: 12, minute: 0))
        let due = try #require(GradescopeHTMLParser.parseDate("Jun 5 at 11:59 PM", referenceDate: reference))
        let year = Calendar.current.component(.year, from: due)
        #expect(year == 2026)
    }

    @Test("yearless January date near year-end rolls into next year")
    func yearlessJanuaryRollsToNextYear() throws {
        let reference = try #require(Self.utcDate(year: 2026, month: 12, day: 20, hour: 12, minute: 0))
        let due = try #require(GradescopeHTMLParser.parseDate("Jan 5 at 11:59 PM", referenceDate: reference))
        let year = Calendar.current.component(.year, from: due)
        #expect(year == 2027)
    }

    @Test("explicit year in the string is always respected")
    func explicitYearRespected() throws {
        let reference = try #require(Self.utcDate(year: 2026, month: 5, day: 21, hour: 12, minute: 0))
        let due = try #require(GradescopeHTMLParser.parseDate("Oct 15, 2024 at 11:59 PM", referenceDate: reference))
        let year = Calendar.current.component(.year, from: due)
        #expect(year == 2024)
    }

    @Test("detects completed assignment detail pages")
    func detectsCompletedAssignmentDetailPages() {
        let submittedHTML = """
        <main>
          <h1>Homework 4</h1>
          <a href="/courses/12345/assignments/444/submissions/999">View Submission</a>
          <button>Resubmit</button>
        </main>
        """
        let scoredHTML = """
        <main>
          <h1>Project Demo</h1>
          <div>Score: 10 / 10</div>
        </main>
        """
        let missingHTML = """
        <main>
          <h1>Optional Practice</h1>
          <p>No submissions yet</p>
          <button>Submit Assignment</button>
        </main>
        """

        #expect(GradescopeHTMLParser.isCompletedAssignmentPage(submittedHTML))
        #expect(GradescopeHTMLParser.isCompletedAssignmentPage(scoredHTML))
        #expect(!GradescopeHTMLParser.isCompletedAssignmentPage(missingHTML))
    }

    @Test("detects Gradescope login pages")
    func detectsLoginPages() {
        let html = """
        <main>
          <h1>Log in to Gradescope</h1>
          <label>Email</label>
          <label>Password</label>
        </main>
        """

        #expect(GradescopeHTMLParser.isLoginPage(html))
    }

    private static func utcDate(year: Int, month: Int, day: Int, hour: Int, minute: Int) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(
            timeZone: TimeZone(identifier: "UTC"),
            year: year,
            month: month,
            day: day,
            hour: hour,
            minute: minute
        ))
    }
}
