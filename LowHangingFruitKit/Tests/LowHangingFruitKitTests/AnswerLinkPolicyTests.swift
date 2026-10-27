import Foundation
import Testing
@testable import LowHangingFruitKit
@testable import LowHangingFruitUI

/// Which links in an ask answer may be opened (`AnswerLinkPolicy`). The rule is
/// a pure function of a URL and the student's Canvas host, so every case here
/// is a string in and a Bool out: no view, no network.
@Suite("Ask: links in an answer open only Canvas and Ed")
struct AnswerLinkPolicyTests {
    private static let canvas = "canvas.upenn.edu"

    private static func allowed(_ string: String, canvasHost: String? = canvas) -> Bool {
        guard let url = URL(string: string) else { return false }
        return AnswerLinkPolicy.allows(url, canvasHost: canvasHost)
    }

    @Test("the student's Canvas host opens, on any path")
    func canvasHostOpens() {
        #expect(Self.allowed("https://canvas.upenn.edu/courses/1/assignments/2"))
        #expect(Self.allowed("https://canvas.upenn.edu/courses/1/assignments/syllabus"))
        #expect(Self.allowed("https://canvas.upenn.edu"))
    }

    @Test("Ed Discussion's two hosts open")
    func edHostsOpen() {
        #expect(Self.allowed("https://edstem.org/us/courses/9/discussion/101"))
        #expect(Self.allowed("https://us.edstem.org/courses/9/discussion/101"))
    }

    @Test("a custom school's Canvas host opens, and Penn's no longer does")
    func customCanvasHost() {
        let host = "canvas.brown.edu"
        #expect(Self.allowed("https://canvas.brown.edu/courses/5", canvasHost: host))
        #expect(!Self.allowed("https://canvas.upenn.edu/courses/5", canvasHost: host))
    }

    @Test("any other host is dropped")
    func otherHostsDropped() {
        #expect(!Self.allowed("https://example.com/"))
        #expect(!Self.allowed("https://www.cis.upenn.edu/~cis2400/schedule"))
        #expect(!Self.allowed("https://upenn.edu/"))
        #expect(!Self.allowed("https://pennkey.upenn.edu/login"))
    }

    @Test("a look-alike host is dropped: the match is exact, not a prefix or suffix")
    func lookAlikesDropped() {
        #expect(!Self.allowed("https://canvas.upenn.edu.example.com/"))
        #expect(!Self.allowed("https://evilcanvas.upenn.edu/"))
        #expect(!Self.allowed("https://canvas.upenn.edu.evil.edstem.org.example.com/"))
        #expect(!Self.allowed("https://notedstem.org/"))
        #expect(!Self.allowed("https://edstem.org.example.com/"))
        #expect(!Self.allowed("https://eu.edstem.org/"))
        #expect(!Self.allowed("https://example.com/canvas.upenn.edu"))
        #expect(!Self.allowed("https://example.com/?next=https://canvas.upenn.edu/"))
    }

    @Test("user-info in front of the host does not borrow its name")
    func userInfoDoesNotCount() {
        // The host of this URL is example.com; what precedes the @ is a login name.
        #expect(!Self.allowed("https://canvas.upenn.edu@example.com/"))
        #expect(!Self.allowed("https://edstem.org:pw@example.com/"))
        // And the same shape on a real host still resolves to that host.
        #expect(Self.allowed("https://someone@canvas.upenn.edu/courses/1"))
    }

    @Test("only https: every other scheme is dropped, even on an allowed host")
    func onlyHTTPS() {
        #expect(!Self.allowed("http://canvas.upenn.edu/courses/1"))
        #expect(!Self.allowed("http://edstem.org/us/courses/9"))
        #expect(!Self.allowed("javascript:alert(1)"))
        #expect(!Self.allowed("tel:+12155551234"))
        #expect(!Self.allowed("mailto:someone@canvas.upenn.edu"))
        #expect(!Self.allowed("sms:+12155551234"))
        #expect(!Self.allowed("file:///etc/hosts"))
        #expect(!Self.allowed("smooth://pair?c=123#k=abc"))
        #expect(!Self.allowed("facetime://someone@canvas.upenn.edu"))
        #expect(!Self.allowed("itms-apps://apps.apple.com/app/id1"))
    }

    @Test("no host means no link: relative, schemeless and empty URLs are dropped")
    func noHost() {
        #expect(!Self.allowed("/courses/1/assignments/2"))
        #expect(!Self.allowed("courses/1"))
        #expect(!Self.allowed("canvas.upenn.edu/courses/1"))
        #expect(!Self.allowed("https:///courses/1"))
        #expect(!Self.allowed("#assignment_9"))
        #expect(!Self.allowed(""))
    }

    @Test("case does not matter in the scheme or the host")
    func caseInsensitive() {
        #expect(Self.allowed("HTTPS://Canvas.UPenn.edu/courses/1"))
        #expect(Self.allowed("https://EDSTEM.ORG/us/courses/9"))
        #expect(Self.allowed("https://canvas.upenn.edu/courses/1", canvasHost: "Canvas.UPenn.edu"))
    }

    @Test("with no Canvas host known, only Ed opens")
    func noCanvasHost() {
        #expect(!Self.allowed("https://canvas.upenn.edu/courses/1", canvasHost: nil))
        #expect(!Self.allowed("https://canvas.upenn.edu/courses/1", canvasHost: ""))
        #expect(Self.allowed("https://edstem.org/us/courses/9", canvasHost: nil))
        #expect(Self.allowed("https://us.edstem.org/courses/9", canvasHost: ""))
    }

    @Test("an empty Canvas host does not match a URL whose host is empty")
    func emptyHostsNeverMatch() {
        #expect(!Self.allowed("https://", canvasHost: ""))
    }

    /// The point of the whole file: the links a model can put in Markdown are
    /// the ones `AssistantView` parses, so run its parse and the rule together
    /// and read off which links would open.
    @Test("in a parsed answer, only the Canvas and Ed links survive")
    func parsedAnswerKeepsOnlyAllowedLinks() throws {
        let answer = """
        The policy is on the [syllabus](https://canvas.upenn.edu/courses/1/assignments/syllabus), \
        discussed in [this Ed thread](https://edstem.org/us/courses/9/discussion/101). \
        The [full answer](https://example.com/phish) is elsewhere, so [call](tel:+12155551234) \
        or <https://canvas.upenn.edu.example.com/login> or [open](javascript:alert(1)).
        """
        let parsed = try AttributedString(
            markdown: answer,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        )
        let links = parsed.runs.compactMap(\.link)
        #expect(links.count == 6)
        let opened = links.filter { AnswerLinkPolicy.allows($0, canvasHost: Self.canvas) }
        #expect(opened.map(\.absoluteString) == [
            "https://canvas.upenn.edu/courses/1/assignments/syllabus",
            "https://edstem.org/us/courses/9/discussion/101",
        ])
    }
}
