import Testing
@testable import PennDashboardKit

@Suite("Canvas requirement scanner")
struct CanvasRequirementScannerTests {
    @Test("finds recurring weekly discussion requirements")
    func findsWeeklyDiscussionRequirement() throws {
        let html = """
        <article>
          <p>Weekly discussion posts are required. Please post by Sunday at 11:59 PM and reply to one classmate.</p>
        </article>
        """

        let suggestions = CanvasRequirementScanner.suggestions(
            from: html,
            course: "CIS 5050",
            source: .syllabus
        )

        let suggestion = try #require(suggestions.first)
        #expect(suggestion.title == "Weekly discussion post")
        #expect(suggestion.course == "CIS 5050")
        #expect(suggestion.weekday == 1)
        #expect(suggestion.hour == 23)
        #expect(suggestion.minute == 59)
        #expect(suggestion.source == .syllabus)
    }

    @Test("ignores non-recurring discussion mentions")
    func ignoresNonRecurringMentions() {
        let html = "<p>We discussed the final project in lecture today.</p>"
        let suggestions = CanvasRequirementScanner.suggestions(
            from: html,
            course: "CIS 5050",
            source: .announcement
        )

        #expect(suggestions.isEmpty)
    }

    @Test("discovers Canvas course links")
    func discoversCourseLinks() throws {
        let html = """
        <a href="/courses/12345">CIS 5050 Software Systems</a>
        <a href="https://canvas.upenn.edu/courses/67890">ENM 5100</a>
        <a href="/courses">All Courses</a>
        """

        let courses = CanvasCourseDiscoveryParser.courseLinks(from: html)

        #expect(courses.count == 2)
        #expect(courses[0].id == "12345")
        #expect(courses[0].name == "CIS 5050 Software Systems")
        #expect(courses[1].id == "67890")
    }
}
