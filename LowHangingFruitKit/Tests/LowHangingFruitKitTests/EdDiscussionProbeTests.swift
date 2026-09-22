import Foundation
import Testing
@testable import LowHangingFruitKit

/// Covers the pure Kit-side pieces of the "probe ed discussion" DEBUG
/// diagnostic (CLAUDE.md's own name for the task): finding the Ed
/// Discussion nav tab, building its borderless launch URL, decoding
/// `/courses/:id/tabs` and the probe's own JSON report, and — the one test
/// that stands as a permanent guard on this feature's privacy rule — that
/// the in-page script never calls `getItem`. None of this touches WebKit;
/// the WebView-driving half of the feature (`EdDiscussionProbe` in
/// `LowHangingFruitUI`) has no pure logic left to test once this file
/// covers everything it delegates to.
@Suite("Ed tab finder")
struct EdTabFinderTests {
    @Test("prefers a tab whose url/html_url mentions edstem over one that only matches by label")
    func edTabPrefersURLOverLabel() {
        let tabs = [
            CanvasCourseTab(id: "ed-by-label", label: "Ed"),
            CanvasCourseTab(id: "ed-by-url", label: "Class Chat", url: "https://us.edstem.org/lti/launch/42"),
        ]
        #expect(EdTabFinder.edTab(in: tabs)?.id == "ed-by-url")
    }

    @Test("matches 'Ed Discussion' and bare 'Ed' by label when no URL mentions edstem")
    func edTabMatchesExpectedLabels() {
        let discussionTabs = [
            CanvasCourseTab(id: "modules", label: "Modules"),
            CanvasCourseTab(id: "ed-discussion", label: "Ed Discussion"),
        ]
        #expect(EdTabFinder.edTab(in: discussionTabs)?.id == "ed-discussion")

        let bareTabs = [
            CanvasCourseTab(id: "grades", label: "Grades"),
            CanvasCourseTab(id: "ed", label: "Ed"),
        ]
        #expect(EdTabFinder.edTab(in: bareTabs)?.id == "ed")
    }

    @Test("never matches Feedback, Media Gallery or Modules")
    func edTabRejectsLookalikeLabels() {
        let tabs = [
            CanvasCourseTab(id: "1", label: "Feedback"),
            CanvasCourseTab(id: "2", label: "Media Gallery"),
            CanvasCourseTab(id: "3", label: "Modules"),
        ]
        #expect(EdTabFinder.edTab(in: tabs) == nil)
    }

    @Test("nil when no tab exists at all")
    func edTabNilWhenAbsent() {
        #expect(EdTabFinder.edTab(in: []) == nil)
    }

    @Test("launchURL appends display=borderless and resolves a relative html_url against the Canvas base")
    func launchURLResolvesAndAppendsQueryItem() throws {
        let base = URL(string: "https://canvas.upenn.edu")!

        let relativeTab = CanvasCourseTab(id: "1", label: "Ed", htmlURL: "/courses/123/external_tools/456")
        let relativeURL = try #require(EdTabFinder.launchURL(for: relativeTab, canvasBase: base))
        #expect(relativeURL.host == "canvas.upenn.edu")
        #expect(relativeURL.path == "/courses/123/external_tools/456")
        #expect(relativeURL.query == "display=borderless")

        let absoluteTab = CanvasCourseTab(
            id: "2",
            label: "Ed",
            htmlURL: "https://canvas.upenn.edu/courses/1/external_tools/2?foo=bar"
        )
        let absoluteURL = try #require(EdTabFinder.launchURL(for: absoluteTab, canvasBase: base))
        let queryItems = URLComponents(url: absoluteURL, resolvingAgainstBaseURL: false)?.queryItems ?? []
        #expect(queryItems.contains(URLQueryItem(name: "foo", value: "bar")))
        #expect(queryItems.contains(URLQueryItem(name: "display", value: "borderless")))
    }

    @Test("launchURL is nil when the tab has no html_url")
    func launchURLNilWithoutHTMLURL() {
        let tab = CanvasCourseTab(id: "1", label: "Ed")
        #expect(EdTabFinder.launchURL(for: tab, canvasBase: URL(string: "https://canvas.upenn.edu")!) == nil)
    }
}

@Suite("CanvasCourseTab decoding")
struct CanvasCourseTabDecodingTests {
    @Test("decodes Canvas's /courses/:id/tabs JSON shape, including html_url's snake_case key")
    func decodesTabsJSON() throws {
        let json = """
        [{"id":"context_external_tool_123","label":"Ed Discussion","type":"external","html_url":"https://canvas.upenn.edu/courses/1/external_tools/123"}]
        """.data(using: .utf8)!
        let tabs = try CourseContentAPI.decoder().decode([CanvasCourseTab].self, from: json)
        #expect(tabs.count == 1)
        #expect(tabs[0].id == "context_external_tool_123")
        #expect(tabs[0].label == "Ed Discussion")
        #expect(tabs[0].type == "external")
        #expect(tabs[0].htmlURL == "https://canvas.upenn.edu/courses/1/external_tools/123")
    }
}

@Suite("Ed hosts")
struct EdHostsTests {
    @Test("recognizes edstem.org and its subdomains, and only those")
    func isEdHost() {
        #expect(EdHosts.isEd(URL(string: "https://edstem.org/")))
        #expect(EdHosts.isEd(URL(string: "https://us.edstem.org/course/1")))
        #expect(!EdHosts.isEd(URL(string: "https://canvas.upenn.edu/")))
        #expect(!EdHosts.isEd(URL(string: "https://notedstem.org/")))
        #expect(!EdHosts.isEd(nil))
    }
}

@Suite("Ed probe report")
struct EdProbeReportTests {
    @Test("formatted() surfaces storage/cookie key names and the whoAmI status line, never a value")
    func formattedReportSurfacesExpectedText() throws {
        let json = """
        {
          "host": "us.edstem.org",
          "path": "/course/999",
          "title": "Ed",
          "localStorageKeys": ["ed_token", "theme"],
          "sessionStorageKeys": [],
          "cookieNames": ["ed_session_v2"],
          "whoAmI": {"status": 200, "ok": true, "courseCount": 2, "courseCodes": ["CIS 1200", "PHYS 0151"]}
        }
        """.data(using: .utf8)!
        let report = try JSONDecoder().decode(EdProbeReport.self, from: json)
        let text = report.formatted()
        #expect(text.contains("us.edstem.org"))
        #expect(text.contains("ed_token"))
        #expect(text.contains("ed_session_v2"))
        #expect(text.contains("status=200"))
        #expect(text.contains("ok=true"))
        #expect(text.contains("CIS 1200"))
    }

    @Test("formatted() reports an error field instead of crashing when a step failed")
    func formattedReportSurfacesErrors() throws {
        let json = """
        {"host": "us.edstem.org", "path": "/course/999", "whoAmIError": "network error"}
        """.data(using: .utf8)!
        let report = try JSONDecoder().decode(EdProbeReport.self, from: json)
        #expect(report.formatted().contains("network error"))
    }
}

@Suite("Ed probe script — privacy rule")
struct EdProbeScriptTests {
    @Test("never calls getItem — only enumerates storage key names, never reads a value")
    func scriptNeverReadsStorageValues() {
        #expect(!EdProbeScript.inspectPage.contains("getItem"))
    }
}
