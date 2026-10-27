import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fnv1a, documentContentHash } from "../src/core/contentHash.js";
import { parseCanvasJSON } from "../src/core/canvasApi.js";
import {
  courseDocumentWire, dateTextLong, dateTextShort, decodeAssignments, decodePage, decodePages,
  assignmentDocument, pageDocument, pageSlugsToFetch, PHONE_MAX_PAGE_BODIES, syllabusDocument,
  syllabusBodyCandidate, syllabusPageCandidate, syllabusTextFromHTML, syllabusNormalizedText,
  announcementPlainText, decodeAnnouncements, announcementDocument, decodeModuleItems, moduleDocuments,
  linksFromPage, linksFromAssignment, linksFromModuleItems, linksFromSyllabusCandidate, dedupeLinks,
  fileDocument, FILE_TEXT_MAX_CHARS, CanvasDecodeError, storableText,
} from "../src/core/canvasDocuments.js";

const fixture = (name) => readFileSync(new URL(`./fixtures/canvas/${name}`, import.meta.url), "utf8");
const json = (name) => parseCanvasJSON(fixture(name));

// CourseKnowledgeTests.swift CourseContentAPITests.course
const course = { courseID: "1234", code: "CIS 2400", url: "https://canvas.upenn.edu/courses/1234" };
const now = new Date("2026-10-22T16:00:00Z");
const NY = { timeZone: "America/New_York" };

// ------------------------------------------------------------------ wire

// BackendJSON.encoder(): ISO 8601 with fractional seconds, sorted keys, nil omitted.
test("wire: dates are ISO strings with milliseconds, keys sorted, absent optionals omitted", () => {
  const w = courseDocumentWire({
    courseID: "1", course: "CIS 1", kind: "page", sourceID: "a", title: "T", text: "x",
    fetchedAt: new Date("2026-09-07T14:03:00Z"),
  });
  assert.deepEqual(Object.keys(w), ["contentHash", "course", "courseID", "fetchedAt", "id", "kind", "sourceID", "text", "title"]);
  assert.equal(w.fetchedAt, "2026-09-07T14:03:00.000Z");
  assert.equal(w.id, "page:1:a");
  assert.ok(!("submitted" in w));
});

// CourseDocument.init: contentHash = fnv1a(title + U+001F + text)
test("wire: contentHash is fnv1a(title + U+001F + text)", () => {
  const w = courseDocumentWire({ courseID: "1", course: "C", kind: "page", sourceID: "a", title: "Doc a", text: "hello" });
  assert.equal(w.contentHash, fnv1a("Doc a\u001Fhello"));
});

// ----------------------------------------------------------- assignments

// CourseKnowledgeTests.swift buildsAssignmentDocument
test("builds an assignment document with due date, points, submission state, and description", () => {
  const assignments = decodeAssignments(json("assignments-xssi.json"));
  const doc = assignmentDocument(assignments[0], course, { now, ...NY });
  assert.equal(doc.kind, "assignment");
  assert.equal(doc.id, "assignment:1234:555");
  assert.equal(doc.course, "CIS 2400");
  assert.equal(doc.title, "PSet 3: caches");
  assert.equal(doc.dueAt, "2026-09-17T03:59:00.000Z");
  assert.equal(doc.pointsPossible, 100);
  assert.ok(doc.text.includes("Status: not submitted"));
  assert.ok(doc.text.includes("direct-mapped cache simulator"));
  assert.ok(doc.text.includes("• Part A"));
  assert.ok(!doc.text.includes("<"));
  assert.ok(!("submitted" in doc));
  // the full text, in the phone's order: due, points, status, description
  assert.equal(
    doc.text,
    "Due: Wed, Sep 16 at 11:59 PM\nPoints: 100\nStatus: not submitted\n" +
      "Implement a direct-mapped cache simulator.\n• Part A\n• Part B",
  );
  assert.equal(doc.updatedAt, "2026-09-01T12:00:00.000Z");
  assert.equal(doc.url, "https://canvas.upenn.edu/courses/1234/assignments/555");
});

// No Swift test: the other branches of CourseDocumentBuilder.assignment.
test("assignment: no due date, fractional points, no submission, submitted by timestamp", () => {
  const [a] = decodeAssignments([{ id: 1, name: "N", points_possible: 12.5, submission: { workflow_state: "unsubmitted", submitted_at: "2026-09-10T03:59:59Z" } }]);
  const doc = assignmentDocument(a, course, { now, ...NY });
  assert.equal(doc.text, "Due: no due date\nPoints: 12.5\nStatus: submitted");
  const [b] = decodeAssignments([{ id: 2, name: "M" }]);
  assert.equal(assignmentDocument(b, course, { now, ...NY }).text, "Due: no due date");
  assert.ok(!("dueAt" in assignmentDocument(b, course, { now })));
});

// No Swift test. Cross-check against the pinned HTMLTextTests.plainText
// output: an assignment whose description is that HTML hashes over
// "Due: no due date\n" + the pinned plain text.
test("hash cross-check: assignment = fnv1a(title + U+001F + text) over the pinned description text", () => {
  const html =
    "<div><h1>Policies</h1><p>Late work &amp; extensions: see below.</p><ul><li>Item&nbsp;one</li><li>Item &#39;two&#39;</li></ul><script>alert(1)</script></div>";
  const [a] = decodeAssignments([{ id: 9, name: "Policies pset", description: html }]);
  const doc = assignmentDocument(a, course, { now });
  const pinnedText = "Due: no due date\nPolicies\nLate work & extensions: see below.\n• Item one\n• Item 'two'";
  assert.equal(doc.text, pinnedText);
  assert.equal(doc.contentHash, fnv1a("Policies pset\u001F" + pinnedText));
});

// Swift's Decodable fails the whole page on one bad field.
test("assignments: a field of the wrong type fails the decode (as Swift's invalidJSON)", () => {
  assert.throws(() => decodeAssignments([{ id: "555", name: "x" }]), CanvasDecodeError);
  assert.throws(() => decodeAssignments([{ id: 5, name: "x", due_at: "soon" }]), CanvasDecodeError);
  assert.throws(() => decodeAssignments({ id: 5 }), CanvasDecodeError);
});

// ----------------------------------------------------------------- pages

// CourseKnowledgeTests.swift buildsOtherDocuments (page part)
test("builds a page document", () => {
  const page = decodePage(json("page-course-policies.json"));
  const doc = pageDocument(page, course, { now });
  assert.equal(doc.id, "page:1234:course-policies");
  assert.equal(doc.text, "No laptops in lecture.");
  assert.equal(doc.title, "Course policies");
  assert.equal(doc.url, "https://canvas.upenn.edu/courses/1234/pages/course-policies");
});

// The pinned title and text above, hashed independently (python FNV-1a).
test("hash cross-check: page = fnv1a(title + U+001F + text) from the pinned strings", () => {
  const doc = pageDocument(decodePage(json("page-course-policies.json")), course, { now });
  assert.equal(doc.contentHash, fnv1a("Course policies\u001FNo laptops in lecture."));
  assert.equal(doc.contentHash, documentContentHash("Course policies", "No laptops in lecture."));
  assert.equal(doc.contentHash, "12548ae04be74d4");
});

// CourseKnowledgeTests.swift stripsPrefix (decoding half)
test("decodes a while(1); page listing", () => {
  const pages = decodePages(json("pages-xssi.json"));
  assert.equal(pages.length, 1);
  assert.equal(pages[0].title, "A");
});

// CanvasCourseContentClient.pages: `listing.prefix(maxBodies)` then
// `where page.published != false`. The Swift has no test.
test("page bodies: the extension fetches every published page; the phone's cap is a parameter", () => {
  const listing = decodePages(json("pages-listing.json"));
  assert.equal(PHONE_MAX_PAGE_BODIES, 40);
  // default: unlimited, unpublished skipped, absent `published` counts as published
  assert.deepEqual(pageSlugsToFetch(listing), ["week-5", "week-4", "week-3", "week-2"]);
  // the phone's behaviour with a smaller cap: cut BEFORE the published filter
  assert.deepEqual(pageSlugsToFetch(listing, { maxBodies: 2 }), ["week-5"]);
  assert.deepEqual(pageSlugsToFetch(listing, { maxBodies: PHONE_MAX_PAGE_BODIES }), ["week-5", "week-4", "week-3", "week-2"]);
  // more than 40 pages, no cap: all of them
  const many = Array.from({ length: 120 }, (_, i) => ({ url: `p${i}`, published: true }));
  assert.equal(pageSlugsToFetch(many).length, 120);
  assert.equal(pageSlugsToFetch(many, { maxBodies: PHONE_MAX_PAGE_BODIES }).length, 40);
});

// ------------------------------------------------------------- syllabus

// CourseKnowledgeTests.swift buildsOtherDocuments (syllabus part)
test("builds a syllabus document; blank text yields none", () => {
  const candidate = { id: "syllabus_body", source: "canvasSyllabusPage", name: "Syllabus", text: "Late policy\nThree late days.", links: [] };
  const doc = syllabusDocument(candidate, course, { now });
  assert.equal(doc.kind, "syllabus");
  assert.ok(doc.text.includes("Three late days."));
  assert.equal(new URL(doc.url).pathname, "/courses/1234/assignments/syllabus");
  assert.equal(syllabusDocument({ id: "x", source: "pasted", name: "", text: "  ", links: [] }, course), null);
});

test("hash cross-check: syllabus = fnv1a(title + U+001F + text) from the pinned strings", () => {
  const candidate = { id: "syllabus_body", source: "canvasSyllabusPage", name: "Syllabus", text: "Late policy\nThree late days.", links: [] };
  const doc = syllabusDocument(candidate, course, { now });
  assert.equal(doc.contentHash, fnv1a("Syllabus\u001FLate policy\nThree late days."));
  assert.equal(doc.contentHash, "62c26ddbc1dd7f8");
});

// No Swift test: the id/name/url rules of CanvasSyllabusClient.findCandidates
// and CourseDocumentBuilder.syllabus, end to end from the REST body.
test("syllabus from course.syllabus_body: id, name, url, links", () => {
  const body = json("course-syllabus-body.json");
  const candidate = syllabusBodyCandidate("1234", body);
  assert.equal(candidate.id, "syllabus-body-1234");
  assert.equal(candidate.name, "Course syllabus page");
  assert.equal(candidate.text, "Late policy\nThree late days.");
  const doc = syllabusDocument(candidate, course, { now });
  assert.equal(doc.id, "syllabus:1234:syllabus-body-1234");
  assert.equal(doc.url, "https://canvas.upenn.edu/courses/1234/assignments/syllabus");
  assert.equal(syllabusBodyCandidate("1", { syllabus_body: "" }), null);
  assert.equal(syllabusBodyCandidate("1", { syllabus_body: "<p> </p>" }), null);
  assert.equal(syllabusBodyCandidate("1", {}), null);
});

test("syllabus from a page hit: id `page-<slug>`, no url, no links, name falls back", () => {
  const c = syllabusPageCandidate({ url: "syllabus-fall", title: "Fall syllabus" }, { body: "<p>Hi <a href=\"https://example.com\">x</a></p>" });
  assert.equal(c.id, "page-syllabus-fall");
  assert.equal(c.source, "canvasPage");
  assert.equal(c.name, "Fall syllabus");
  assert.deepEqual(c.links, []);
  const doc = syllabusDocument(c, course, { now });
  assert.ok(!("url" in doc));
  assert.equal(syllabusPageCandidate({ url: "s" }, { body: "<p>x</p>" }).name, "Course page");
  assert.equal(syllabusPageCandidate({ url: "s", title: "T" }, { body: null }), null);
  assert.equal(syllabusDocument({ ...c, name: "" }, course, { now }).title, "CIS 2400 syllabus");
});

// No Swift test: SyllabusTextExtractor.text(fromHTML:) read off the source.
test("syllabus extractor: cell tabs collapse to a space, entities case-insensitive, numeric entities blanked", () => {
  assert.equal(syllabusTextFromHTML("<table><tr><td>Homework</td><td>30%</td></tr></table>"), "Homework 30%");
  assert.equal(syllabusTextFromHTML("Q&AMP;A &NBSP;x &#8211; y"), "Q&A x y");
  // &amp; is decoded second, so "&amp;lt;" ends as "<" here (unlike HTMLText).
  assert.equal(syllabusTextFromHTML("&amp;lt;"), "<");
  assert.equal(syllabusNormalizedText("a\r\n\r\n\r\n\r\nb–c’s"), "a\n\nb-c's");
});

// ---------------------------------------------------------- announcements

const iso = (s) => new Date(s).getTime();

// CanvasAnnouncementsClientTests.swift decodesTwoAnnouncements
test("two realistic announcements decode with plain-text messages and parsed dates", () => {
  const a = decodeAnnouncements(json("announcements.json"));
  assert.equal(a.length, 2);
  const first = a.find((x) => x.id === "5001");
  assert.equal(first.courseID, "12345");
  assert.equal(first.title, "Midterm info");
  assert.equal(first.message, "The midterm is on Friday.\nBring a calculator & two pencils.");
  assert.equal(first.postedAt.getTime(), iso("2026-02-01T12:30:00.123Z"));
  assert.equal(first.url, "https://canvas.upenn.edu/courses/12345/discussion_topics/5001");
  const second = a.find((x) => x.id === "5002");
  assert.equal(second.courseID, "67890");
  assert.equal(second.title, "Office hours moved");
  assert.equal(second.message, "Office hours moved to\nThursday 3-5pm.");
  assert.equal(second.postedAt.getTime(), iso("2026-02-02T09:00:00Z"));
});

// CanvasAnnouncementsClientTests.swift decodesXSSIPrefixedPayload
test("XSSI-prefixed announcements payload decodes after stripping while(1);", () => {
  const a = decodeAnnouncements(parseCanvasJSON("while(1);" + fixture("announcements.json")));
  assert.equal(a.length, 2);
});

// CanvasAnnouncementsClientTests.swift skipsElementMissingContextCode
test("an element with no context_code is skipped; the rest of the page survives", () => {
  const a = decodeAnnouncements(json("announcements-missing-context.json"));
  assert.equal(a.length, 1);
  assert.equal(a[0].id, "7002");
  assert.equal(a[0].courseID, "222");
});

// CanvasAnnouncementsClientTests.swift oneMalformedElementDoesNotSinkBatch
test("one structurally malformed array element is dropped without sinking the page", () => {
  const a = decodeAnnouncements(json("announcements-malformed-element.json"));
  assert.equal(a.length, 1);
  assert.equal(a[0].id, "9002");
});

// CanvasAnnouncementsClientTests.swift garbageJSONThrowsDecodingFailed
// (Swift parses the bytes inside decodeAnnouncements; here parsing is
// parseCanvasJSON, and a non-array page is the decode failure)
test("garbage JSON throws, never crashes", () => {
  assert.throws(() => parseCanvasJSON("not json at all"), SyntaxError);
  assert.throws(() => decodeAnnouncements({ errors: [] }), CanvasDecodeError);
});

// CanvasAnnouncementsClientTests.swift nullMessageYieldsEmptyString
test("null message decodes to an empty string", () => {
  const a = decodeAnnouncements(json("announcements-null-message.json"));
  assert.equal(a.length, 1);
  assert.equal(a[0].message, "");
});

// No Swift test: the other context_code shapes courseID(fromContextCode:) refuses.
test("only course_<digits> context codes are kept", () => {
  const mk = (code) => decodeAnnouncements([{ id: 1, context_code: code, title: "t", message: "m" }]).length;
  assert.equal(mk("course_12"), 1);
  assert.equal(mk("group_1"), 0);
  assert.equal(mk("course_"), 0);
  assert.equal(mk("course_1x"), 0);
  assert.equal(decodeAnnouncements([{ id: "1", context_code: "course_1" }]).length, 0);
});

// CanvasAnnouncementsClientTests.swift plainTextStripsTags
test("announcement plainText strips arbitrary tags that carry no useful text content", () => {
  const text = announcementPlainText('<div><strong>Bold</strong> and <a href="https://example.com">a link</a>.</div>');
  assert.ok(!text.includes("<") && !text.includes(">"));
  assert.ok(text.includes("Bold and a link."));
});

// CanvasAnnouncementsClientTests.swift plainTextNewlinesFromBrAndClosingP
test("announcement plainText turns <br> and </p> into newlines", () => {
  assert.equal(announcementPlainText("<p>Line one</p><p>Line two<br>Line three</p>"), "Line one\nLine two\nLine three");
});

// CanvasAnnouncementsClientTests.swift plainTextDecodesEntities
test("announcement plainText decodes the common HTML entities, with &amp; decoded last", () => {
  assert.equal(
    announcementPlainText("Tom &amp; Jerry &lt;3 &quot;friends&quot; &#39;forever&#39;&nbsp;ok"),
    "Tom & Jerry <3 \"friends\" 'forever' ok",
  );
});

// CanvasAnnouncementsClientTests.swift plainTextCollapsesNewlines
test("announcement plainText collapses runs of 3+ newlines to a single blank line and trims the ends", () => {
  assert.equal(announcementPlainText("<p>A</p><p></p><p></p><p>B</p>"), "A\n\nB");
});

// CanvasAnnouncementsClientTests.swift plainTextEmptyInputIsEmptyOutput
test("announcement plainText of an empty string is an empty string", () => {
  assert.equal(announcementPlainText(""), "");
});

// CourseKnowledgeTests.swift buildsOtherDocuments (announcement part). Since
// 2026-10-23 the text is the message alone (no "Posted:" line) and the date
// lives in updatedAt, matching the phone's builder byte for byte.
test("builds an announcement document", () => {
  const a = decodeAnnouncements(json("announcements.json")).find((x) => x.id === "5001");
  const doc = announcementDocument(a, { courseID: "12345", code: "CIS 2400" }, { now });
  assert.equal(doc.kind, "announcement");
  assert.equal(doc.id, "announcement:12345:5001");
  assert.ok(!doc.text.includes("Posted:"));
  assert.equal(doc.text, "The midterm is on Friday.\nBring a calculator & two pencils.");
  assert.equal(doc.updatedAt, "2026-02-01T12:30:00.123Z");
  assert.equal(doc.url, "https://canvas.upenn.edu/courses/12345/discussion_topics/5001");
});

// CourseDocumentBuilder.announcement: a dated post's updatedAt is its postedAt
// and the zone no longer matters to the text.
test("announcement updatedAt equals postedAt and the text is the same in any zone", () => {
  const [a] = decodeAnnouncements([{ id: 5003, context_code: "course_12345", title: "Dated", message: "Body", posted_at: "2026-02-01T12:30:00.123Z" }]);
  const doc = announcementDocument(a, { courseID: "12345", code: "CIS 2400" }, { now, timeZone: "Asia/Tokyo" });
  assert.equal(doc.text, "Body");
  assert.equal(doc.updatedAt, "2026-02-01T12:30:00.123Z");
});

// CourseDocumentBuilder.announcement empty-title guard (server rejects "").
test("announcement with an empty or blank title is titled Announcement", () => {
  for (const title of ["", "  \n "]) {
    const [a] = decodeAnnouncements([{ id: 5004, context_code: "course_12345", title, message: "Body" }]);
    const doc = announcementDocument(a, { courseID: "12345", code: "CIS 2400" }, { now });
    assert.equal(doc.title, "Announcement");
    assert.equal(doc.contentHash, fnv1a("Announcement\u001FBody"));
  }
});

// CourseDocumentBuilder.announcement empty-message guard (server rejects "").
test("announcement with an empty message produces no document", () => {
  const [a] = decodeAnnouncements([{ id: 5005, context_code: "course_12345", title: "Image only", message: "<p>  </p>", posted_at: "2026-02-01T12:30:00Z" }]);
  assert.equal(announcementDocument(a, { courseID: "12345", code: "CIS 2400" }, { now }), null);
});

// A posted_at-less announcement's text is exactly the message, so the Swift
// test's pinned title and message give the whole document.
test("hash cross-check: announcement = fnv1a(title + U+001F + text) from the pinned strings", () => {
  const [a] = decodeAnnouncements([{ id: 5002, context_code: "course_67890", title: "Office hours moved", message: "Office hours moved to<br>Thursday 3-5pm." }]);
  const doc = announcementDocument(a, { courseID: "67890", code: "CIS 2400" }, { now });
  assert.equal(doc.text, "Office hours moved to\nThursday 3-5pm.");
  assert.equal(doc.contentHash, fnv1a("Office hours moved\u001FOffice hours moved to\nThursday 3-5pm."));
  assert.equal(doc.contentHash, "dda5b4549f133f05");
  assert.ok(!("updatedAt" in doc));
});

// --------------------------------------------------------------- modules

// CourseKnowledgeTests.swift buildsOtherDocuments (modules part)
test("builds one module document per module, grouped by name in order", () => {
  const items = decodeModuleItems([json("modules.json")]);
  const docs = moduleDocuments(items.filter((i) => i.typeRaw !== "Assignment"), course, { now });
  assert.deepEqual(docs.map((d) => d.title), ["Week 2", "Week 3"]);
  assert.equal(docs[0].text, "• Lecture 3 slides (file)\n• Reading: Chapter 2 (externalurl)");
  assert.equal(docs[0].url, "https://canvas.upenn.edu/courses/1234/modules");
  assert.equal(docs[0].sourceID, fnv1a("Week 2"));
});

test("hash cross-check: module = fnv1a(title + U+001F + text) from the pinned strings", () => {
  const docs = moduleDocuments(decodeModuleItems([json("modules.json")]), course, { now });
  const week2 = docs[0];
  assert.equal(week2.contentHash, fnv1a("Week 2\u001F• Lecture 3 slides (file)\n• Reading: Chapter 2 (externalurl)"));
  assert.equal(week2.contentHash, "bc83c38d1d805bdc");
  assert.equal(week2.sourceID, "1e247a575170c1af");
});

// CanvasModulesClient.moduleItems(fromPages:): SubHeader dropped, due date from
// content_details, ExternalUrl only keeps external_url. No Swift test here
// (CanvasModulesClientTests covers the Swift side).
test("module items: SubHeader dropped, dated item rendered with its due date", () => {
  const items = decodeModuleItems([json("modules.json")]);
  assert.deepEqual(items.map((i) => i.title), ["Lecture 3 slides", "Reading: Chapter 2", "Lecture 5 slides", "PSet 3"]);
  assert.equal(items[0].contentID, "71");
  assert.equal(items[1].externalURL, "https://example.com/chapter-2");
  assert.equal(items[0].externalURL, null);
  const docs = moduleDocuments(items, course, { now, ...NY });
  assert.equal(docs[1].text, "• Lecture 5 slides (file)\n• PSet 3 (assignment) · due Wed Sep 16, 11:59 PM");
});

test("module items: a module-less item groups under \"Modules\"; a bad page contributes nothing", () => {
  const docs = moduleDocuments([{ id: "1", title: "Loose", typeRaw: "Page", dueAt: null, moduleName: null }], course, { now });
  assert.equal(docs[0].title, "Modules");
  assert.deepEqual(decodeModuleItems([{ not: "an array" }, [{ name: "M", items: [{ id: "x", title: "t", type: "File" }] }]]), []);
});

test("date text: long and short formats", () => {
  const d = new Date("2026-09-17T03:59:00Z");
  assert.equal(dateTextLong(d, NY), "Wed, Sep 16 at 11:59 PM");
  assert.equal(dateTextShort(d, NY), "Wed Sep 16, 11:59 PM");
  assert.equal(dateTextLong(new Date("2026-09-17T16:05:00Z"), NY), "Thu, Sep 17 at 12:05 PM");
  assert.equal(dateTextLong(new Date("2026-09-17T04:05:00Z"), NY), "Thu, Sep 17 at 12:05 AM");
});

// ----------------------------------------------------------------- links

// CourseKnowledgeTests.swift buildsLinksFromPage
test("links(from: page) returns both an internal Canvas link and an external one", () => {
  const links = linksFromPage(decodePage(json("page-with-links.json")), course);
  assert.equal(links.length, 2);
  assert.ok(links.every((l) => l.courseID === "1234" && l.origin === "page"));
  const hrefs = links.map((l) => l.href);
  assert.ok(hrefs.includes("https://canvas.upenn.edu/courses/1234/assignments/1"));
  assert.ok(hrefs.includes("https://example.com/course-site"));
});

// CourseKnowledgeTests.swift buildsLinksFromAssignment
test("links(from: assignment) pulls links from the assignment description", () => {
  const [a] = decodeAssignments(json("assignments-links.json"));
  assert.deepEqual(linksFromAssignment(a, course), [
    { courseID: "1234", href: "https://example.com/handout", text: "the handout", origin: "assignment" },
  ]);
});

// CourseKnowledgeTests.swift buildsLinksFromModuleItems
test("links(from: [ModuleItem]) returns one link per ExternalUrl item, named by its title", () => {
  const items = [
    { id: "1", title: "Lecture 3 slides", dueAt: null, typeRaw: "File", moduleName: "Week 2", externalURL: null },
    { id: "2", title: "Course website", dueAt: null, typeRaw: "ExternalUrl", moduleName: "Week 2", externalURL: "https://example.com/course" },
  ];
  assert.deepEqual(linksFromModuleItems(items, course), [
    { courseID: "1234", href: "https://example.com/course", text: "Course website", origin: "module" },
  ]);
});

// CourseKnowledgeCollector.run: syllabus links carry origin "syllabus"
test("syllabus links come from the body candidate; announcements contribute none", () => {
  const c = syllabusBodyCandidate("1234", { syllabus_body: '<p>Site: <a href="https://example.com/cis">course site</a></p>' });
  assert.deepEqual(linksFromSyllabusCandidate(c, course), [
    { courseID: "1234", href: "https://example.com/cis", text: "course site", origin: "syllabus" },
  ]);
});

// CourseKnowledgeCollector.run: dedupe by (courseID, href), cap 400
test("dedupeLinks keeps the first of each (courseID, href) and caps at 400", () => {
  const l = (courseID, href) => ({ courseID, href, text: href, origin: "page" });
  assert.deepEqual(dedupeLinks([l("1", "a"), l("1", "a"), l("2", "a"), l("1", "b")]).map((x) => x.courseID + x.href), ["1a", "2a", "1b"]);
  const many = Array.from({ length: 500 }, (_, i) => l("1", `h${i}`));
  assert.equal(dedupeLinks(many).length, 400);
  assert.equal(dedupeLinks(many).at(-1).href, "h399");
});

// ----------------------------------------------------------------- files

// No Swift origin: `file` is new (docs/CHROME_EXTENSION.md).
test("fileDocument: id, hash, ISO dates, 60,000-character cap", () => {
  const doc = fileDocument({
    courseID: "1234", course: "CIS 2400", fileID: 98765, displayName: "Lecture 3.pdf",
    url: "https://canvas.upenn.edu/courses/1234/files/98765", updatedAt: "2026-10-01T12:00:00Z",
    text: "slides text", fetchedAt: now,
  });
  assert.equal(doc.id, "file:1234:98765");
  assert.equal(doc.kind, "file");
  assert.equal(doc.sourceID, "98765");
  assert.equal(doc.title, "Lecture 3.pdf");
  assert.equal(doc.updatedAt, "2026-10-01T12:00:00.000Z");
  assert.equal(doc.fetchedAt, "2026-10-22T16:00:00.000Z");
  assert.equal(doc.contentHash, fnv1a("Lecture 3.pdf\u001Fslides text"));

  const long = fileDocument({ courseID: "1", course: "C", fileID: 1, displayName: "f", text: "x".repeat(70_000), fetchedAt: now });
  assert.equal(FILE_TEXT_MAX_CHARS, 60_000);
  assert.equal(long.text.length, 60_000);
  assert.equal(long.contentHash, fnv1a("f\u001F" + "x".repeat(60_000)));
  assert.ok(!("url" in long) && !("updatedAt" in long));
  // not cut when exactly at the cap, and never mid surrogate pair
  assert.equal(fileDocument({ courseID: "1", course: "C", fileID: 1, displayName: "f", text: "y".repeat(60_000), fetchedAt: now }).text.length, 60_000);
  const emoji = "x".repeat(59_999) + "\u{1F600}";
  assert.equal(fileDocument({ courseID: "1", course: "C", fileID: 1, displayName: "f", text: emoji, fetchedAt: now }).text, "x".repeat(59_999));
});

// 2026-10-27: a PDF whose text held NULs failed a whole upload batch with a
// 500 ("unsupported Unicode escape sequence" from Postgres).
test("storableText drops NULs and replaces lone surrogates, keeping real pairs", () => {
  assert.equal(storableText("a\u0000b\u0000"), "ab");
  assert.equal(storableText("x\ud800y"), "x�y");
  assert.equal(storableText("x\udc00y"), "x�y");
  assert.equal(storableText("ok 😀"), "ok 😀");
  assert.equal(storableText(undefined), undefined);
});

test("a document's text, title and hash describe the cleaned text", () => {
  const dirty = fileDocument({
    courseID: "1", course: "PHYS 0151", fileID: 9, displayName: "Exam\u0000 1",
    text: "Q1\u0000 \ud800done", fetchedAt: new Date("2026-10-27T00:00:00Z"),
  });
  const clean = fileDocument({
    courseID: "1", course: "PHYS 0151", fileID: 9, displayName: "Exam 1",
    text: "Q1 �done", fetchedAt: new Date("2026-10-27T00:00:00Z"),
  });
  assert.deepEqual(dirty, clean);
  assert.ok(!JSON.stringify(dirty).includes("\\u0000"));
});
