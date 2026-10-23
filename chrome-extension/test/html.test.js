import { test } from "node:test";
import assert from "node:assert/strict";
import { plainText, decodeEntities, links } from "../src/core/html.js";

// Ports of HTMLLinksTests.swift ("HTML links") and the HTMLText cases in
// CourseKnowledgeTests.swift ("HTML to text") and RetrievalStrengthTests.swift
// ("HTML cleanup"). Swift is the spec.

// HTMLLinksTests.doubleQuoted
test("links: parses a double-quoted href", () => {
  assert.deepEqual(links('<a href="https://example.com/syllabus">Course site</a>'), [
    { href: "https://example.com/syllabus", text: "Course site" },
  ]);
});

// HTMLLinksTests.singleQuoted
test("links: parses a single-quoted href", () => {
  assert.deepEqual(links("<a href='https://example.com/syllabus'>Course site</a>"), [
    { href: "https://example.com/syllabus", text: "Course site" },
  ]);
});

// HTMLLinksTests.attributeBeforeHref
test("links: finds href when other attributes come first", () => {
  assert.deepEqual(links('<a class="external" target="_blank" href="https://example.com">Site</a>'), [
    { href: "https://example.com", text: "Site" },
  ]);
});

// HTMLLinksTests.attributeAfterHref
test("links: finds href when other attributes come after", () => {
  assert.deepEqual(links('<a href="https://example.com" target="_blank" rel="noopener">Site</a>'), [
    { href: "https://example.com", text: "Site" },
  ]);
});

// HTMLLinksTests.entityDecodedText
test("links: decodes entities in the link text", () => {
  assert.deepEqual(links('<a href="https://example.com">Smith &amp; Jones&#39;s page</a>'), [
    { href: "https://example.com", text: "Smith & Jones's page" },
  ]);
});

// HTMLLinksTests.nestedTagsStripped
test("links: strips nested tags from the link text", () => {
  assert.deepEqual(links('<a href="https://example.com"><b>Bold</b> and <i>italic</i> text</a>'), [
    { href: "https://example.com", text: "Bold and italic text" },
  ]);
});

// HTMLLinksTests.skipsBareHashAnchor
test("links: skips a bare # anchor", () => {
  assert.deepEqual(links('<a href="#">Jump</a>'), []);
});

// HTMLLinksTests.skipsFragmentOnlyHref
test("links: skips a #fragment-only href", () => {
  assert.deepEqual(links('<a href="#section-2">Jump to section 2</a>'), []);
});

// HTMLLinksTests.skipsEmptyHref
test("links: skips an anchor with an empty href", () => {
  assert.deepEqual(links('<a href="">Nowhere</a>'), []);
});

// HTMLLinksTests.skipsMissingHref
test("links: skips an anchor with no href attribute at all", () => {
  assert.deepEqual(links('<a name="top">Top</a>'), []);
});

// HTMLLinksTests.keepsRelativeHrefVerbatim
test("links: keeps a relative href verbatim", () => {
  assert.deepEqual(links('<a href="/courses/1234/pages/syllabus">Syllabus</a>'), [
    { href: "/courses/1234/pages/syllabus", text: "Syllabus" },
  ]);
});

// HTMLLinksTests.multipleLinks
test("links: finds multiple links in one document", () => {
  const html = `<p>See <a href="https://a.example">A</a> and <a href='https://b.example'>B</a>.</p>`;
  assert.deepEqual(links(html), [
    { href: "https://a.example", text: "A" },
    { href: "https://b.example", text: "B" },
  ]);
});

// HTMLLinksTests.caseInsensitiveTag
test("links: case-insensitive <A> tag matches", () => {
  assert.deepEqual(links('<A HREF="https://example.com">Site</A>'), [{ href: "https://example.com", text: "Site" }]);
});

// No Swift test. `<abbr>` must not be read as an anchor (\b after "a").
test("links: <abbr href> is not an anchor", () => {
  assert.deepEqual(links('<abbr href="https://example.com">x</abbr>'), []);
});

// CourseKnowledgeTests.swift HTMLTextTests.plainText
test("plainText: keeps paragraphs and list items on separate lines and decodes entities", () => {
  const html =
    "<div><h1>Policies</h1><p>Late work &amp; extensions: see below.</p><ul><li>Item&nbsp;one</li><li>Item &#39;two&#39;</li></ul><script>alert(1)</script></div>";
  assert.equal(plainText(html), "Policies\nLate work & extensions: see below.\n• Item one\n• Item 'two'");
});

// CourseKnowledgeTests.swift HTMLTextTests.numericEntities
test("decodeEntities: numeric entities", () => {
  assert.equal(decodeEntities("&#8217;s &#x2014; ok"), "’s — ok");
});

// No Swift test. An entity that is not a Unicode scalar is left as written
// (Unicode.Scalar(value) is nil), and &amp; is decoded last.
test("decodeEntities: surrogates and out-of-range stay as written; &amp;lt; is not double-decoded", () => {
  assert.equal(decodeEntities("&#xD800; &#1114112;"), "&#xD800; &#1114112;");
  assert.equal(decodeEntities("&amp;lt;"), "&lt;");
});

// RetrievalStrengthTests.swift multiLineStyleIsRemoved
test("plainText: a multi-line <style> block leaves no CSS behind", () => {
  const html = '<p>Before</p><style type="text/css">\n.note { color: red; }\n.box { margin: 0; }\n</style><p>After</p>';
  assert.equal(plainText(html), "Before\nAfter");
});

// RetrievalStrengthTests.swift multiLineScriptIsRemoved
test("plainText: a multi-line <script> block leaves no JavaScript behind", () => {
  const html = "<p>Before</p><script>\nvar secret = 1;\nfunction hidden() { return secret; }\n</script><p>After</p>";
  assert.equal(plainText(html), "Before\nAfter");
});

// RetrievalStrengthTests.swift multiLineCommentIsRemoved
test("plainText: a multi-line HTML comment that contains a '>' leaves nothing behind", () => {
  const html = "<p>Before</p><!--[if gte mso 9]><xml>\n<o:Settings>hidden word</o:Settings>\n</xml><![endif]-->\n<p>After</p>";
  assert.equal(plainText(html), "Before\nAfter");
});

// SyllabusExamExtractorTests.swift tableRows: "the same row, through the real
// HTML flattening". Swift asserts only the parsed date; this pins the
// flattened line itself (each cell separated by one space, each row a line).
test("plainText: table rows flatten to one line per row", () => {
  const html =
    "<table><tr><td>Week 7</td><td>10/14</td><td>Lecture</td></tr>" +
    "<tr><td>Week 8</td><td>10/21</td><td>Midterm</td></tr></table>";
  assert.equal(plainText(html), "Week 7 10/14 Lecture\nWeek 8 10/21 Midterm");
});

// No Swift test: the ICU \b rewrite. <style> must not match <styled>.
test("plainText: <styled> is not a <style> block", () => {
  assert.equal(plainText("<styled>keep</styled>x</style>"), "keep x");
});
