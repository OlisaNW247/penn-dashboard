import Foundation
import Testing
@testable import LowHangingFruitKit

/// `HTMLText.links(in:)` — the seam `CourseDocumentBuilder.links(from:)`
/// uses to find outbound pointers in Canvas page/assignment HTML. No
/// network; pure parsing against inline fixture strings.
@Suite("HTML links")
struct HTMLLinksTests {
    @Test("parses a double-quoted href")
    func doubleQuoted() {
        let links = HTMLText.links(in: #"<a href="https://example.com/syllabus">Course site</a>"#)
        #expect(links == [HTMLLink(href: "https://example.com/syllabus", text: "Course site")])
    }

    @Test("parses a single-quoted href")
    func singleQuoted() {
        let links = HTMLText.links(in: "<a href='https://example.com/syllabus'>Course site</a>")
        #expect(links == [HTMLLink(href: "https://example.com/syllabus", text: "Course site")])
    }

    @Test("finds href when other attributes come first")
    func attributeBeforeHref() {
        let links = HTMLText.links(in: #"<a class="external" target="_blank" href="https://example.com">Site</a>"#)
        #expect(links == [HTMLLink(href: "https://example.com", text: "Site")])
    }

    @Test("finds href when other attributes come after")
    func attributeAfterHref() {
        let links = HTMLText.links(in: #"<a href="https://example.com" target="_blank" rel="noopener">Site</a>"#)
        #expect(links == [HTMLLink(href: "https://example.com", text: "Site")])
    }

    @Test("decodes entities in the link text")
    func entityDecodedText() {
        let links = HTMLText.links(in: #"<a href="https://example.com">Smith &amp; Jones&#39;s page</a>"#)
        #expect(links == [HTMLLink(href: "https://example.com", text: "Smith & Jones's page")])
    }

    @Test("strips nested tags from the link text")
    func nestedTagsStripped() {
        let links = HTMLText.links(in: #"<a href="https://example.com"><b>Bold</b> and <i>italic</i> text</a>"#)
        #expect(links == [HTMLLink(href: "https://example.com", text: "Bold and italic text")])
    }

    @Test("skips a bare # anchor")
    func skipsBareHashAnchor() {
        let links = HTMLText.links(in: #"<a href="#">Jump</a>"#)
        #expect(links.isEmpty)
    }

    @Test("skips a #fragment-only href")
    func skipsFragmentOnlyHref() {
        let links = HTMLText.links(in: #"<a href="#section-2">Jump to section 2</a>"#)
        #expect(links.isEmpty)
    }

    @Test("skips an anchor with an empty href")
    func skipsEmptyHref() {
        let links = HTMLText.links(in: #"<a href="">Nowhere</a>"#)
        #expect(links.isEmpty)
    }

    @Test("skips an anchor with no href attribute at all")
    func skipsMissingHref() {
        let links = HTMLText.links(in: #"<a name="top">Top</a>"#)
        #expect(links.isEmpty)
    }

    @Test("keeps a relative href verbatim")
    func keepsRelativeHrefVerbatim() {
        let links = HTMLText.links(in: #"<a href="/courses/1234/pages/syllabus">Syllabus</a>"#)
        #expect(links == [HTMLLink(href: "/courses/1234/pages/syllabus", text: "Syllabus")])
    }

    @Test("finds multiple links in one document")
    func multipleLinks() {
        let html = #"<p>See <a href="https://a.example">A</a> and <a href='https://b.example'>B</a>.</p>"#
        let links = HTMLText.links(in: html)
        #expect(links == [
            HTMLLink(href: "https://a.example", text: "A"),
            HTMLLink(href: "https://b.example", text: "B"),
        ])
    }

    @Test("case-insensitive <A> tag matches")
    func caseInsensitiveTag() {
        let links = HTMLText.links(in: #"<A HREF="https://example.com">Site</A>"#)
        #expect(links == [HTMLLink(href: "https://example.com", text: "Site")])
    }
}
