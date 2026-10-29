import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fnv1a } from "../src/core/contentHash.js";
import {
  parseEdDate, decodeThread, decodeThreadsResponse, decodeUserResponse, EdDecodeError, decide,
  keptThreads, plainTextFromDocument, strippingTags, sourceID, title, text, KIND, parseHeader,
  postedDayString, carriesNoText, documents, threadURL, threadsURL, userURL, DEFAULT_MAX_AGE_DAYS,
} from "../src/core/ed.js";

const fixture = (name) => JSON.parse(readFileSync(new URL(`./fixtures/ed/${name}`, import.meta.url), "utf8"));

// EdIngestionTests.swift `thread(...)` helper: course 101, title "T" by default,
// createdAt the epoch.
function thread(id, o = {}) {
  return {
    id, userID: o.user ?? 1, courseID: 101, type: o.type ?? "post", title: o.title ?? "T",
    document: o.document ?? null, content: o.content ?? null, category: o.category ?? null,
    subcategory: o.subcategory ?? null, isPinned: o.pinned ?? false, isPrivate: o.isPrivate ?? false,
    isEndorsed: false, isAnonymous: o.anonymous ?? false, createdAt: o.createdAt ?? new Date(0),
    updatedAt: o.updatedAt ?? null, number: o.number ?? null, replyCount: null,
  };
}
const instant = (s) => new Date(s);

// --------------------------------------------------------------- wire

// EdIngestionTests.swift EdWireTests.decodesUserBody
test("decodes /api/user, tolerating a missing role and ignoring unknown fields", () => {
  const r = decodeUserResponse(fixture("user.json"));
  assert.equal(r.courses.length, 2);
  assert.equal(r.courses[0].course.id, 101);
  assert.equal(r.courses[0].course.session, "Fall");
  assert.equal(r.courses[0].role.role, "student");
  assert.equal(r.courses[1].role, null);
  assert.equal(r.courses[1].course.year, null);
  assert.equal(r.courses[1].course.status, null);
});

// EdIngestionTests.swift EdWireTests.decodesThreadsBody
test("decodes threads: absent is_pinned is false, null document is nil, microsecond +10:00 date parses", () => {
  const r = decodeThreadsResponse(fixture("threads-swift-decode.json"));
  const t = r.threads[0];
  assert.equal(t.id, 900);
  assert.equal(t.userID, 7);
  assert.equal(t.courseID, 101);
  assert.equal(t.isPinned, false);
  assert.equal(t.isEndorsed, false);
  assert.equal(t.isAnonymous, false);
  assert.equal(t.document, null);
  assert.equal(t.content, "<p>hi</p>");
  assert.equal(t.updatedAt, null);
  assert.equal(t.number, 3);
  assert.equal(t.createdAt.getTime(), instant("2026-03-05T04:21:55Z").getTime() + 123);
  assert.equal(r.users.length, 2);
  assert.equal(r.users[0].courseRole, "admin");
  assert.equal(r.users[1].courseRole, null);
});

// EdIngestionTests.swift EdWireTests.missingUserID
test("a missing user_id (anonymous thread) decodes as 0 instead of failing the page", () => {
  const r = decodeThreadsResponse({ threads: [{ id: 1, course_id: 101, type: "post", title: "x", created_at: "2026-03-05T14:21:55Z" }] });
  assert.equal(r.threads[0].userID, 0);
  assert.deepEqual(r.users, []);
});

// Swift (EdThread.init(from:)): `is_private` missing reads as TRUE. The Swift
// test for this is the filter's private rule; this pins the decode default.
test("a thread with no is_private flag decodes as private", () => {
  const t = decodeThread({ id: 1, course_id: 1, type: "post", title: "x", created_at: "2026-03-05T14:21:55Z" });
  assert.equal(t.isPrivate, true);
  assert.equal(decide(decodeThread({ ...{ id: 1, course_id: 1, type: "post", title: "x", created_at: "2026-03-05T14:21:55Z" }, is_pinned: true }), null).keep, false);
});

// EdIngestionTests.swift EdWireTests.dateShapes
test("timestamp shapes: Z, offsets with and without colon, fractions of any length, space separator", () => {
  const base = instant("2026-03-05T04:21:55Z").getTime();
  for (const s of [
    "2026-03-05T04:21:55Z", "2026-03-05T14:21:55+10:00", "2026-03-05T14:21:55+1000",
    "2026-03-05T14:21:55+10", "2026-03-04T23:21:55-05:00", "2026-03-05 14:21:55+10:00",
  ]) {
    assert.equal(parseEdDate(s)?.getTime(), base, s);
  }
  assert.ok(Math.abs(parseEdDate("2026-03-05T14:21:55.5+10:00").getTime() - base - 500) < 1);
  assert.ok(Math.abs(parseEdDate("2026-03-05T14:21:55.123456+10:00").getTime() - base - 123) < 1);
  assert.equal(parseEdDate("yesterday"), null);
  assert.equal(parseEdDate(""), null);
});

// EdIngestionTests.swift EdWireTests.badDateThrows
test("an unparseable timestamp fails the decode rather than inventing a date", () => {
  assert.throws(
    () => decodeThreadsResponse({ threads: [{ id: 1, user_id: 2, course_id: 101, type: "post", title: "x", created_at: "soon" }] }),
    EdDecodeError,
  );
});

// ------------------------------------------------------------------ text

// EdIngestionTests.swift EdDocumentTextTests.representativeDocument
test("heading, paragraph, bold, entity, links, lists, callout and snippet render as Markdown-ish text", () => {
  const xml =
    '<document version="2.0">' +
    '<heading level="2">Midterm info</heading>' +
    "<paragraph>The exam is <bold>Friday</bold> &amp; covers weeks 1-5. " +
    'See <link href="https://example.com/s">the sheet</link> or ' +
    '<link href="https://example.com/x">https://example.com/x</link>.</paragraph>' +
    '<list style="bullet"><list-item><paragraph>Bring a pencil</paragraph></list-item>' +
    "<list-item><paragraph>Bring ID</paragraph></list-item></list>" +
    '<list style="number"><list-item><paragraph>one</paragraph></list-item>' +
    "<list-item><paragraph>two</paragraph></list-item></list>" +
    '<callout type="info"><paragraph>Room changed</paragraph></callout>' +
    '<snippet language="python">print(1)\nprint(2)</snippet>' +
    "</document>";
  const expected = [
    "## Midterm info",
    "The exam is Friday & covers weeks 1-5. See the sheet (https://example.com/s) or https://example.com/x.",
    "- Bring a pencil",
    "- Bring ID",
    "1. one",
    "2. two",
    "> Room changed",
    "```python",
    "print(1)",
    "print(2)",
    "```",
  ].join("\n");
  assert.equal(plainTextFromDocument(xml), expected);
});

// EdDocumentTextTests.smallElements
test("break is a newline, image is [image], pre is fenced, math is kept verbatim", () => {
  const xml =
    '<document><paragraph>a<break/>b</paragraph><image src="https://x/y.png"/>' +
    "<pre>x = 1</pre><paragraph>Solve <math>x^2 = 4</math> now</paragraph></document>";
  assert.equal(plainTextFromDocument(xml), "a\nb\n[image]\n```\nx = 1\n```\nSolve x^2 = 4 now");
});

// EdDocumentTextTests.prettyPrinted
test("pretty-printed whitespace between tags does not leak into the text", () => {
  const xml = `<document version="2.0">
  <paragraph>one</paragraph>
  <list style="bullet">
    <list-item><paragraph>two</paragraph></list-item>
  </list>
</document>`;
  assert.equal(plainTextFromDocument(xml), "one\n- two");
});

// EdDocumentTextTests.collapsesBlankLines
test("three or more newlines collapse to one blank line", () => {
  const xml = "<document><paragraph>a</paragraph><break/><break/><break/><paragraph>b</paragraph></document>";
  assert.equal(plainTextFromDocument(xml), "a\n\nb");
});

// EdDocumentTextTests.malformedDocument
test("malformed XML degrades to tag-stripped text, never an empty string", () => {
  const unclosed = plainTextFromDocument("<document><paragraph>Hello <bold>world</paragraph> Tom &amp; Jerry");
  assert.ok(unclosed.includes("Hello world"));
  assert.ok(unclosed.includes("Tom & Jerry"));
  // A bare ampersand is not legal XML but is exactly what someone types.
  assert.equal(plainTextFromDocument("<document><paragraph>Q&A hours</paragraph></document>"), "Q&A hours");
  // Not markup at all.
  assert.equal(plainTextFromDocument("just words"), "just words");
});

// EdDocumentTextTests.emptyDocument
test("an empty document is the empty string", () => {
  assert.equal(plainTextFromDocument(""), "");
  assert.equal(plainTextFromDocument('<document version="2.0"></document>'), "");
});

// EdDocumentTextTests.strippingTags
test("strippingTags turns block tags into line breaks and decodes entities", () => {
  assert.equal(strippingTags("<p>Hello&nbsp;there</p><p>a &lt; b &#38; c</p>"), "Hello there\n\na < b & c");
  assert.equal(strippingTags("1 < 2 and 3 > 2"), "1 < 2 and 3 > 2");
});

// No Swift test: HTML entities XMLParser rejects (the reason for the fallback).
test("an HTML-only entity in the document falls back to tag-stripped text with the word kept", () => {
  assert.equal(plainTextFromDocument("<document><paragraph>Tom&nbsp;Jerry</paragraph></document>"), "Tom Jerry");
});

// ---------------------------------------------------------------- filter

// EdThreadFilterTests.privateDropped
test("a private announcement is dropped: private beats everything", () => {
  assert.deepEqual(decide(thread(1, { type: "announcement", isPrivate: true }), "admin"), { keep: false, reason: "private" });
});

// EdThreadFilter's anonymous rule (SEC-10): dropped after private, before
// every keep rule, so an anonymous announcement, pinned post or staff post
// never leaves the student's devices.
test("an anonymous thread is dropped, even an announcement, a pinned post or a staff post", () => {
  const drop = { keep: false, reason: "anonymous" };
  assert.deepEqual(decide(thread(1, { type: "announcement", anonymous: true }), "admin"), drop);
  assert.deepEqual(decide(thread(1, { pinned: true, anonymous: true }), "staff"), drop);
  assert.deepEqual(decide(thread(1, { anonymous: true }), "instructor"), drop);
  assert.deepEqual(decide(thread(1, { type: "announcement", isPrivate: true, anonymous: true }), "admin"),
    { keep: false, reason: "private" });
});

// EdThreadFilterTests.announcementKept
test("announcements are kept whoever wrote them", () => {
  assert.deepEqual(decide(thread(1, { type: "announcement" }), null), { keep: true, reason: "announcement" });
});

// EdThreadFilterTests.pinnedKept
test("a pinned student post is kept: only staff can pin", () => {
  assert.deepEqual(decide(thread(1, { pinned: true }), "student"), { keep: true, reason: "pinned" });
});

// EdThreadFilterTests.staffPostKept
test("a staff post is kept, in any case, for every staff role", () => {
  for (const role of ["admin", "Staff", "INSTRUCTOR", "ta", "tutor", "mentor"]) {
    assert.deepEqual(decide(thread(1), role), { keep: true, reason: "staff post" }, role);
  }
});

// EdThreadFilterTests.staffQuestionDropped
test("a staff question is dropped", () => {
  assert.deepEqual(decide(thread(1, { type: "question" }), "staff"), { keep: false, reason: "student or question" });
});

// EdThreadFilterTests.studentAndUnknownDropped
test("a student post is dropped, and an unknown author is treated as a student", () => {
  const drop = { keep: false, reason: "student or question" };
  assert.deepEqual(decide(thread(1), "student"), drop);
  assert.deepEqual(decide(thread(1), null), drop);
  assert.deepEqual(decide(thread(1), undefined), drop);
  assert.deepEqual(decide(thread(1), "something-new"), drop);
});

// EdThreadFilterTests.keptThreadsUsesUsers
test("keptThreads reads author roles from the response's users array", () => {
  const response = {
    threads: [
      thread(1, { user: 10 }),
      thread(2, { user: 11 }),
      thread(3, { user: 99 }),
      thread(4, { user: 10, type: "question" }),
      thread(5, { user: 11, type: "announcement" }),
      thread(6, { user: 10, isPrivate: true }),
    ],
    users: [{ id: 10, courseRole: "admin" }, { id: 11, courseRole: "student" }],
  };
  const kept = keptThreads(response);
  assert.deepEqual(kept.map((k) => k.thread.id), [1, 5]);
  assert.deepEqual(kept.map((k) => k.decision.reason), ["staff post", "announcement"]);
});

// ---------------------------------------------------------------- builder

// EdDocumentBuilderTests.headerAndBody
test("header carries the decision, category and subcategory, then the plain-text body", () => {
  const t = thread(42, { pinned: true, document: "<document><paragraph>Bring ID.</paragraph></document>", category: "Homework", subcategory: "Hw 3" });
  assert.equal(text(t, decide(t, null)), "[ed · pinned] Homework / Hw 3\nBring ID.");
  assert.equal(sourceID(t), "42");
  assert.equal(KIND, "ed");
});

// EdDocumentBuilderTests.headerWithoutCategory
test("no category: header alone has just the label; a subcategory without a category is not shown", () => {
  const t = thread(1, { type: "announcement", document: "<document><paragraph>Hi</paragraph></document>", category: "", subcategory: "Sub" });
  assert.equal(text(t, decide(t, null)), "[ed · announcement]\nHi");
});

// EdDocumentBuilderTests.contentFallback
test("falls back to tag-stripped content when there is no document", () => {
  const t = thread(1, { type: "announcement", document: null, content: "<p>Hello<br>there</p>", category: "General" });
  assert.equal(text(t, decide(t, null)), "[ed · announcement] General\nHello\nthere");
});

// EdDocumentBuilderTests.headerCarriesCreationDay
test("the header ends with the day the thread was created, in US Eastern, and never the last-activity day", () => {
  const t = thread(7, {
    type: "announcement", document: "<document><paragraph>Happy Monday!</paragraph></document>", category: "General",
    createdAt: instant("2026-10-12T15:30:00Z"), updatedAt: instant("2026-10-17T03:00:00Z"),
  });
  assert.equal(text(t, decide(t, null)), "[ed · announcement] General · posted 2026-10-12\nHappy Monday!");
});

// EdDocumentBuilderTests.headerOnly
test("a thread with no body at all is just its header", () => {
  assert.equal(text(thread(1, { type: "announcement" }), { keep: true, reason: "announcement" }), "[ed · announcement]");
});

// EdDocumentBuilderTests.titles
test("title is trimmed, with a stand-in when blank", () => {
  assert.equal(title(thread(1, { title: "  Exam room  " })), "Exam room");
  assert.equal(title(thread(5, { title: " ", number: 12 })), "Ed thread #12");
  assert.equal(title(thread(5, { title: "" })), "Ed thread #5");
});

// ---------------------------------------------------------------- header

const PARAGRAPH = '<document version="2.0"><paragraph>Bring ID.</paragraph></document>';

// EdDocumentHeaderTests.keptThread
function keptThread(reason, { document = PARAGRAPH, category = "Homework", subcategory = "Hw 3", createdAt = new Date(0) } = {}) {
  let t;
  let role = null;
  if (reason === "announcement") t = thread(1, { user: 7, type: "announcement", title: "A", document, category, subcategory, createdAt });
  else if (reason === "pinned") t = thread(2, { user: 7, title: "P", document, category, subcategory, pinned: true, createdAt });
  else {
    t = thread(3, { user: 7, title: "S", document, category, subcategory, createdAt });
    role = "ta";
  }
  return [t, decide(t, role)];
}

// EdDocumentHeaderTests.roundTripsEveryReason
test("header: round-trips real builder output for every reason the filter keeps", () => {
  for (const reason of ["announcement", "pinned", "staff post"]) {
    const [t, d] = keptThread(reason);
    assert.ok(d.keep && d.reason === reason);
    const h = parseHeader(text(t, d));
    assert.equal(h.reason, reason);
    assert.equal(h.category, "Homework / Hw 3");
    assert.equal(h.body, "Bring ID.");
    assert.ok(!h.body.includes("[ed ·"));
  }
});

// EdDocumentHeaderTests.missingCategoryAndBody
test("header: a header with no category has none; a thread with no body is just its header", () => {
  const [withBody, d] = keptThread("announcement", { category: null, subcategory: null });
  const hi = parseHeader(text(withBody, d));
  assert.equal(hi.reason, "announcement");
  assert.equal(hi.category, null);
  assert.equal(hi.body, "Bring ID.");

  const [empty, ed] = keptThread("pinned", { document: null, category: "General", subcategory: null });
  const t = text(empty, ed);
  assert.equal(t, "[ed · pinned] General");
  const headerOnly = parseHeader(t);
  assert.equal(headerOnly.reason, "pinned");
  assert.equal(headerOnly.category, "General");
  assert.equal(headerOnly.body, "");
});

// EdDocumentHeaderTests.multiLineBody
test("header: a multi-line body comes back exactly as the builder wrote it", () => {
  const doc = '<document version="2.0"><heading level="1">Plan</heading><paragraph>First.</paragraph><paragraph>Second: Due Friday.</paragraph></document>';
  const [t, d] = keptThread("announcement", { document: doc });
  const full = text(t, d);
  const h = parseHeader(full);
  assert.equal(h.body, full.slice(full.indexOf("\n") + 1));
  assert.ok(h.body.includes("First."));
  assert.ok(h.body.includes("Second: Due Friday."));
});

// EdDocumentHeaderTests.noHeaderIsReturnedWhole
test("header: text without a header is returned whole, with no reason", () => {
  for (const s of [
    "Grading\nProblem sets 50%.", "", "[ed · unclosed header\nbody", "[ed · ]\nbody",
    "  [ed · pinned] indented, so not the builder's line", "Posted: Mon, Sep 7 at 9:00 AM\nRecitation moved.",
  ]) {
    const h = parseHeader(s);
    assert.equal(h.reason, null);
    assert.equal(h.category, null);
    assert.equal(h.body, s);
  }
});

// EdDocumentHeaderTests.laterHeaderLikeLineIsBody
test("header: the header is only the first line", () => {
  const s = "Plain first line\n[ed · pinned] not a header";
  const h = parseHeader(s);
  assert.equal(h.reason, null);
  assert.equal(h.body, s);
});

const utc = (y, mo, d, h = 0, mi = 0) => new Date(Date.UTC(y, mo - 1, d, h, mi));
// October is EDT: noon Eastern is 16:00Z.
const easternNoonOct = (day) => new Date(Date.UTC(2026, 9, day, 16));

// EdDocumentHeaderTests.postedTokenRoundTrips
test("header: the builder writes the creation day as a posted token, and the parser reads noon Eastern back", () => {
  for (const reason of ["announcement", "pinned", "staff post"]) {
    const [t, d] = keptThread(reason, { createdAt: utc(2026, 10, 12, 15, 30) });
    const s = text(t, d);
    assert.equal(s, `[ed · ${reason}] Homework / Hw 3 · posted 2026-10-12\nBring ID.`);
    const h = parseHeader(s);
    assert.equal(h.reason, reason);
    assert.equal(h.category, "Homework / Hw 3");
    assert.equal(h.postedAt.getTime(), easternNoonOct(12).getTime());
    assert.equal(h.body, "Bring ID.");
  }
});

// EdDocumentHeaderTests.postedTokenWithoutCategory
test("header: a thread with no category still carries the token, and the category stays nil", () => {
  const [t, d] = keptThread("announcement", { category: null, subcategory: null, createdAt: utc(2026, 10, 12, 9) });
  const s = text(t, d);
  assert.equal(s, "[ed · announcement] · posted 2026-10-12\nBring ID.");
  const h = parseHeader(s);
  assert.equal(h.reason, "announcement");
  assert.equal(h.category, null);
  assert.equal(h.postedAt.getTime(), easternNoonOct(12).getTime());
  assert.equal(h.body, "Bring ID.");

  const [bare, bd] = keptThread("pinned", { document: null, category: null, subcategory: null, createdAt: utc(2026, 10, 12, 12) });
  assert.equal(text(bare, bd), "[ed · pinned] · posted 2026-10-12");
});

// EdDocumentHeaderTests.postedDayIsEastern
test("header: the day is the Eastern day, whatever the device zone", () => {
  assert.equal(postedDayString(utc(2026, 10, 13, 1, 30)), "2026-10-12");
  assert.equal(postedDayString(utc(2026, 10, 12, 3, 30)), "2026-10-11");
  assert.equal(postedDayString(utc(2026, 10, 13, 3, 59)), "2026-10-12");
  assert.equal(postedDayString(utc(2026, 10, 13, 4, 0)), "2026-10-13");
  assert.equal(postedDayString(utc(2026, 1, 6, 4, 30)), "2026-01-05");
  assert.equal(postedDayString(utc(2026, 1, 5, 12)), "2026-01-05");
});

// EdDocumentHeaderTests.epochCreatedAtOmitsToken
test("header: the epoch default of a hand-built thread gets no token", () => {
  const [t, d] = keptThread("pinned");
  const s = text(t, d);
  assert.equal(s, "[ed · pinned] Homework / Hw 3\nBring ID.");
  assert.equal(parseHeader(s).postedAt, null);
});

// EdDocumentHeaderTests.oldHeaderHasNoPostedAt
test("header: a header written before the token existed parses as before, with no postedAt", () => {
  assert.deepEqual(parseHeader("[ed · pinned] Homework / Hw 3\nBring ID."), {
    reason: "pinned", category: "Homework / Hw 3", body: "Bring ID.", postedAt: null,
  });
  assert.equal(parseHeader("[ed · announcement]").postedAt, null);
  assert.equal(parseHeader("no header · posted 2026-10-12").postedAt, null);
});

// EdDocumentHeaderTests.malformedPostedToken
test("header: a malformed or impossible date is nil and leaves the category and body alone", () => {
  for (const bad of ["2026-13-45", "2026-02-31", "yesterday", "2026-10-1", "20261012", "2026-10-12T09:00", "", "0000-00-00"]) {
    const h = parseHeader(`[ed · pinned] Homework · posted ${bad}\nBring ID.`);
    assert.equal(h.postedAt, null, bad);
    assert.equal(h.reason, "pinned");
    assert.ok(h.category.startsWith("Homework"));
    assert.equal(h.body, "Bring ID.");
  }
  const dotted = parseHeader("[ed · pinned] Labs · Week 3\nBring ID.");
  assert.equal(dotted.category, "Labs · Week 3");
  assert.equal(dotted.postedAt, null);
});

// EdDocumentHeaderTests.imageOnlyPostCarriesNoText
test("header: a post that is only a picture carries no text; the placeholder comes from the real converter", () => {
  const doc = '<document version="2.0"><image src="https://static.edusercontent.com/files/x" width="100" height="100"/></document>';
  const [t, d] = keptThread("announcement", { document: doc });
  const s = text(t, d);
  assert.ok(s.includes("[image]"));
  assert.ok(carriesNoText(s));
});

// EdDocumentHeaderTests.emptyShapes
test("header: a header alone, several placeholders, and a bulleted placeholder all carry no text", () => {
  assert.ok(carriesNoText("[ed · announcement]"));
  assert.ok(carriesNoText("[ed · announcement] General"));
  assert.ok(carriesNoText("[ed · pinned] General / FAQ\n[image]\n[image]"));
  assert.ok(carriesNoText("[ed · pinned]\n- [image]\n> [image]"));
  assert.ok(carriesNoText("[image]"));
  assert.ok(carriesNoText("   \n"));
});

// EdDocumentHeaderTests.realTextCarriesText
test("header: any real word or number in the body means the post carries text", () => {
  assert.ok(!carriesNoText("[ed · announcement] General\nMidterm moved to Friday."));
  assert.ok(!carriesNoText("[ed · pinned]\n[image]\nSee the diagram above."));
  assert.ok(!carriesNoText("[ed · pinned]\n[image]\nRoom 100"));
  assert.ok(!carriesNoText("Plain text with no header"));
});

// ------------------------------------------------------------- ingestion

const NOW = new Date(1_800_000_000 * 1000);
const COURSE = { courseID: "555", code: "CIS 2400" };
const staffResponse = (threads) => ({ threads, users: [{ id: 7, courseRole: "admin" }, { id: 8, courseRole: "student" }] });
const daysAgo = (n) => new Date(NOW.getTime() - n * 86_400_000);
const staffPost = (id, days) => thread(id, { user: 7, title: `Post ${id}`, content: `<p>Body ${id}</p>`, createdAt: daysAgo(days) });

// EdClientTests.swift EdIngestionDocumentTests.announcementBecomesDocument
test("ingestion: a kept announcement becomes an ed document with the pooled identity and link", () => {
  const t = thread(900, { user: 7, type: "announcement", title: "Welcome", content: "<p>Hello class</p>", createdAt: daysAgo(1) });
  const docs = documents({ course: COURSE, edCourseID: 101, response: staffResponse([t]), now: NOW });
  assert.equal(docs.length, 1);
  const doc = docs[0];
  assert.equal(doc.kind, "ed");
  assert.equal(doc.id, "ed:555:900");
  assert.equal(doc.courseID, "555");
  assert.equal(doc.course, "CIS 2400");
  assert.equal(doc.title, "Welcome");
  assert.equal(doc.url, threadURL(101, 900));
  assert.equal(doc.url, "https://edstem.org/us/courses/101/discussion/900");
  assert.ok(doc.text.startsWith("[ed · announcement]"));
  assert.equal(doc.fetchedAt, NOW.toISOString());
  assert.equal(doc.updatedAt, t.createdAt.toISOString());
});

// EdClientTests.swift documentCarriesPostingDay
test("ingestion: the header carries the creation day while updatedAt stays the last-activity time", () => {
  const created = daysAgo(7);
  const bumped = daysAgo(1);
  const t = thread(901, { user: 7, type: "announcement", title: "Welcome", content: "<p>Hello class</p>", createdAt: created, updatedAt: bumped });
  const doc = documents({ course: COURSE, edCourseID: 101, response: staffResponse([t]), now: NOW })[0];
  const h = parseHeader(doc.text);
  assert.equal(doc.updatedAt, bumped.toISOString());
  assert.ok(doc.text.includes(" · posted " + postedDayString(created)));
  assert.equal(postedDayString(h.postedAt), postedDayString(created));
  assert.equal(h.body, "Hello class");
});

// EdClientTests.swift studentPostDropped
test("ingestion: a student post yields no document", () => {
  const student = thread(5, { user: 8, title: "Help", content: "<p>x</p>", createdAt: daysAgo(1) });
  assert.deepEqual(documents({ course: COURSE, edCourseID: 101, response: staffResponse([student]), now: NOW }), []);
});

// EdClientTests.swift maxAgeApplies
test("ingestion: maxAge drops a 200-day-old staff post and keeps a 10-day-old one", () => {
  const docs = documents({ course: COURSE, edCourseID: 101, response: staffResponse([staffPost(1, 200), staffPost(2, 10)]), now: NOW });
  assert.deepEqual(docs.map((d) => d.sourceID), ["2"]);
  assert.equal(DEFAULT_MAX_AGE_DAYS, 120);
});

// EdClientTests.swift updatedAtWins
test("ingestion: updatedAt, not createdAt, decides recency when present", () => {
  const old = thread(3, { user: 7, title: "Edited", content: "<p>x</p>", createdAt: daysAgo(300), updatedAt: daysAgo(2) });
  assert.equal(documents({ course: COURSE, edCourseID: 101, response: staffResponse([old]), now: NOW }).length, 1);
});

// EdClientTests.swift newestFirst
test("ingestion: documents come out newest first", () => {
  const docs = documents({ course: COURSE, edCourseID: 101, response: staffResponse([staffPost(1, 30), staffPost(2, 1), staffPost(3, 10)]), now: NOW });
  assert.deepEqual(docs.map((d) => d.sourceID), ["2", "3", "1"]);
});

// EdClientTests.swift threadsPageRequest / threadsClampsLimit (the URL half;
// the URLSession half is not ported)
test("threadsURL: path, defaults, and the 1...100 clamp", () => {
  const u = new URL(threadsURL(101));
  assert.equal(u.pathname, "/api/courses/101/threads");
  assert.equal(u.searchParams.get("limit"), "100");
  assert.equal(u.searchParams.get("sort"), "new");
  assert.equal(u.searchParams.get("offset"), "0");
  assert.equal(new URL(threadsURL(101, { limit: 500 })).searchParams.get("limit"), "100");
  assert.equal(new URL(threadsURL(101, { limit: 0 })).searchParams.get("limit"), "1");
  assert.equal(userURL(), "https://us.edstem.org/api/user");
});

// ---------------------------------------------------------- privacy, whole

// No Swift test in this exact form (the Swift guarantee is structural:
// CourseDocument has no author field). This drives a whole response through
// decode, filter, build and JSON, then looks for every author string and
// every dropped thread's text.
test("privacy: a student post is dropped and no author string survives anywhere", () => {
  const response = decodeThreadsResponse(fixture("threads.json"));
  const now = new Date("2026-10-22T16:00:00Z");
  const docs = documents({ course: COURSE, edCourseID: 101, response, now });

  // kept: announcement 900, pinned 901, staff post 904; newest activity first
  assert.deepEqual(docs.map((d) => d.sourceID), ["900", "904", "901"]);
  assert.deepEqual(
    docs.map((d) => d.text.split("\n")[0]),
    [
      "[ed · announcement] Exams / Midterm · posted 2026-10-12",
      "[ed · staff post] Logistics · posted 2026-10-11",
      "[ed · pinned] Policies · posted 2026-10-01",
    ],
  );
  assert.equal(docs[0].text.split("\n")[1], "The midterm is in Towne 100 & starts at 10.");
  assert.equal(docs[1].text.split("\n")[1], "Recitation moves to Thursday.");
  assert.equal(docs[2].text.split("\n")[1], "You have three late days.");

  // Author strings: not in the documents, and not even kept by the decoder.
  const everything = JSON.stringify(docs) + JSON.stringify(response);
  for (const author of ["Fixture Instructorname", "Fixture Studentname", "Fixture Taname", "fixture.instructor", "example.invalid"]) {
    assert.ok(!everything.includes(author), `${author} survived`);
  }
  for (const dropped of ["STUDENT-ONLY", "STAFF-QUESTION", "PRIVATE-", "NO-PRIVATE-FLAG"]) {
    assert.ok(!JSON.stringify(docs).includes(dropped), `${dropped} survived`);
  }
  // Only the documented wire fields exist on a document.
  for (const d of docs) {
    assert.deepEqual(Object.keys(d), ["contentHash", "course", "courseID", "fetchedAt", "id", "kind", "sourceID", "text", "title", "updatedAt", "url"]);
  }
});

// The pinned strings of EdDocumentBuilderTests.headerAndBody (title "T" is
// the Swift helper's default) hashed independently.
test("hash cross-check: ed = fnv1a(title + U+001F + text) from the pinned strings", () => {
  const t = thread(42, {
    user: 7, pinned: true, document: "<document><paragraph>Bring ID.</paragraph></document>",
    category: "Homework", subcategory: "Hw 3", updatedAt: daysAgo(1),
  });
  const doc = documents({ course: COURSE, edCourseID: 101, response: staffResponse([t]), now: NOW })[0];
  assert.equal(doc.title, "T");
  assert.equal(doc.text, "[ed · pinned] Homework / Hw 3\nBring ID.");
  assert.equal(doc.contentHash, fnv1a("T\u001F[ed · pinned] Homework / Hw 3\nBring ID."));
  assert.equal(doc.contentHash, "44fa634e300c701c");
});
