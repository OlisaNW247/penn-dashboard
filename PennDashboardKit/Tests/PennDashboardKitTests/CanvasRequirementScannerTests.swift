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

    @Test("extracts the personal calendar feed URL from the calendar page")
    func extractsCalendarFeedURL() throws {
        let html = """
        <div class="calendar_feed_box_holder">
          <input type="text" id="calendar_feed_box" readonly="readonly"
                 value="https://canvas.upenn.edu/feeds/calendars/user_aBc123XyZ.ics" />
        </div>
        """

        let feed = try #require(CanvasCalendarFeedParser.feedURL(from: html))
        #expect(feed.absoluteString == "https://canvas.upenn.edu/feeds/calendars/user_aBc123XyZ.ics")
    }

    @Test("unescapes HTML entities in the feed URL")
    func unescapesFeedURL() throws {
        let html = #"""
        <a href="webcal://canvas.upenn.edu/feeds/calendars/user_tok.ics?a=1&amp;b=2">Feed</a>
        <span>https://canvas.upenn.edu/feeds/calendars/user_tok.ics?a=1&amp;b=2</span>
        """#

        let feed = try #require(CanvasCalendarFeedParser.feedURL(from: html))
        #expect(feed.absoluteString == "https://canvas.upenn.edu/feeds/calendars/user_tok.ics?a=1&b=2")
    }

    @Test("returns nil when no feed URL is present")
    func noFeedURL() {
        #expect(CanvasCalendarFeedParser.feedURL(from: "<p>no feed here</p>") == nil)
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
