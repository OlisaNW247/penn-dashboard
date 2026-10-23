import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import {
  courseLinks, currentTermCourses, filterFallbackAssignments, assignments,
  isCompletedAssignmentPage, isLoginPage, parseDate, scoreValues, cleanText,
  requiresReauthentication, accountPageAssignments, courseAssignments,
  refineWithDetailPage, sortAssignments,
} from "../src/core/gradescope.js";
import { makeAssignment, Source, Kind } from "../src/core/assignment.js";
import { makeTerm, termsEqual } from "../src/core/term.js";

const BASE = "https://www.gradescope.com";
const fx = (name) =>
  readFileSync(new URL(`./fixtures/gradescope/${name}`, import.meta.url), "utf8");
// GradescopeTests.swift:759-770, GradescopeTermStampTests.swift:30-37
const utc = (y, m, d, h = 12, mi = 0) => new Date(Date.UTC(y, m - 1, d, h, mi));
const urls = (r) => r.courses.map((c) => c.url);
const spring2026 = makeTerm(2026, 10);

// The suite runs under TZ=America/New_York (npm test); Swift's Calendar.current
// is the machine zone, so the local-time assertions below need it too.
test("tests run in America/New_York", () => {
  assert.equal(new Date(2026, 4, 24, 23, 59).getTimezoneOffset(), 240);
});

// ---- Course discovery and term selection ----------------------------------

// GradescopeTests.swift:46
test("only authentication responses require a Gradescope reconnect", () => {
  assert.equal(requiresReauthentication({ kind: "notLoggedIn" }), true);
  assert.equal(requiresReauthentication({ kind: "http", status: 401 }), true);
  assert.equal(requiresReauthentication({ kind: "http", status: 403 }), true);
  assert.equal(requiresReauthentication({ kind: "http", status: 500 }), false);
  assert.equal(requiresReauthentication({ kind: "notHTTP" }), false);
  assert.equal(requiresReauthentication({ kind: "invalidResponseEncoding" }), false);
});

// GradescopeTests.swift:57-83 minus the URLSession stub: the pure half is that
// a login page served in place of a course page is recognised, and that the
// account page itself yields the course.
test("a login page is recognised and the account page yields its course", () => {
  const r = currentTermCourses(fx("account-fall2026-login-test.html"), BASE, utc(2026, 10, 1));
  assert.deepEqual(urls(r), [`${BASE}/courses/123`]);
  assert.equal(isLoginPage(fx("login-page-with-password.html")), true);
});

// GradescopeTests.swift:85-128 minus the URLSession stub: the course page parses
// to the one unsubmitted assignment whose detail URL the client would fetch.
test("the course page names the detail URL that the client would fetch", () => {
  const [a] = assignments(fx("course-one-homework.html"), {
    courseName: "CIS 5050", courseURL: `${BASE}/courses/123`, referenceDate: utc(2026, 9, 1),
  });
  assert.equal(a.url, `${BASE}/courses/123/assignments/456`);
  assert.equal(a.submitted, false);
});

// GradescopeTests.swift:129
test("discovers course links from account page", () => {
  const courses = courseLinks(fx("account-course-links.html"), BASE);
  assert.equal(courses.length, 2);
  assert.equal(courses[0].name, "CIS 5050 Software Systems");
  assert.equal(courses[0].url, "https://www.gradescope.com/courses/12345");
  assert.equal(courses[1].name, "ENM 5100");
});

// GradescopeTests.swift:150
test("keeps only the current term's courses", () => {
  const r = currentTermCourses(fx("terms-spring2026-fall2025-spring2025.html"), BASE, utc(2026, 5, 21));
  assert.equal(r.courses.length, 2);
  assert.equal(r.isFallback, false);
  assert.deepEqual(urls(r).sort(), [`${BASE}/courses/111`, `${BASE}/courses/222`]);
});

// GradescopeTests.swift:186
test("falls back to the most recent term within the grace window after its own window ends", () => {
  const r = currentTermCourses(fx("terms-fall2025-spring2025.html"), BASE, utc(2026, 1, 10));
  assert.deepEqual(urls(r), [`${BASE}/courses/333`]);
  assert.equal(r.isFallback, true);
});

// GradescopeTests.swift:217
test("does not fall back once well past the grace window, even with a lone stale term", () => {
  const r = currentTermCourses(fx("term-spring2026.html"), BASE, utc(2026, 7, 25));
  assert.deepEqual(r.courses, []);
  assert.equal(r.isFallback, false);
});

// GradescopeTests.swift:242
test("falls back within the grace window right after a lone term's window ends", () => {
  const r = currentTermCourses(fx("term-spring2026.html"), BASE, utc(2026, 7, 5));
  assert.deepEqual(urls(r), [`${BASE}/courses/111`]);
  assert.equal(r.isFallback, true);
});

// GradescopeTests.swift:269
test("keeps an active Winter term for quarter-system schools", () => {
  const r = currentTermCourses(fx("term-winter2026.html"), BASE, utc(2026, 2, 15));
  assert.deepEqual(urls(r), [`${BASE}/courses/111`]);
  assert.equal(r.isFallback, false);
});

// GradescopeTests.swift:297
test("keeps both Winter and Spring terms when both are active in February", () => {
  const r = currentTermCourses(fx("terms-winter2026-spring2026.html"), BASE, utc(2026, 2, 15));
  assert.equal(r.courses.length, 2);
  assert.equal(r.isFallback, false);
  assert.deepEqual(urls(r).sort(), [`${BASE}/courses/111`, `${BASE}/courses/222`]);
});

// GradescopeTests.swift:330
test("keeps an early-starting Fall term for semester schools", () => {
  const r = currentTermCourses(fx("term-fall2026.html"), BASE, utc(2026, 8, 20));
  assert.deepEqual(urls(r), [`${BASE}/courses/333`]);
  assert.equal(r.isFallback, false);
});

// GradescopeTests.swift:355
test("keeps both Summer and Spring terms when both are active in May", () => {
  const r = currentTermCourses(fx("terms-summer2026-spring2026.html"), BASE, utc(2026, 5, 15));
  assert.equal(r.courses.length, 2);
  assert.equal(r.isFallback, false);
  assert.deepEqual(urls(r).sort(), [`${BASE}/courses/222`, `${BASE}/courses/555`]);
});

// GradescopeTests.swift:386
test("Winter term window reaches back into the prior December", () => {
  const r = currentTermCourses(fx("term-winter2027.html"), BASE, utc(2026, 12, 10));
  assert.deepEqual(urls(r), [`${BASE}/courses/666`]);
  assert.equal(r.isFallback, false);
});

// GradescopeTests.swift:411
test("falls back to all courses when there are no term headings", () => {
  const r = currentTermCourses(fx("no-headings.html"), BASE);
  assert.equal(r.courses.length, 2);
  assert.equal(r.isFallback, false);
});

// GradescopeTests.swift:432
test("fallback courses drop undated assignments; current-term courses keep them", () => {
  const mk = (sourceID, title, dueAt) => makeAssignment({
    source: Source.GRADESCOPE, sourceID, kind: Kind.ASSIGNMENT, course: "CIS 5500", title, dueAt,
  });
  const dated = mk("course-1-assignment-1", "Homework 1", new Date());
  const undated = mk("course-1-assignment-2", "Quiz 1", null);
  assert.deepEqual(
    filterFallbackAssignments([dated, undated], true).map((a) => a.sourceID),
    ["course-1-assignment-1"]);
  assert.deepEqual(
    filterFallbackAssignments([dated, undated], false).map((a) => a.sourceID).sort(),
    ["course-1-assignment-1", "course-1-assignment-2"]);
});

// ---- Assignment rows -------------------------------------------------------

const COURSE_URL = `${BASE}/courses/12345`;

// GradescopeTests.swift:462
test("parses assignments from a course table", () => {
  const list = assignments(fx("course-table.html"), {
    courseName: "CIS 5050 Software Systems", courseURL: COURSE_URL, referenceDate: utc(2026, 5, 21),
  });
  assert.equal(list.length, 4);
  const by = (id) => list.find((a) => a.sourceID === `course-12345-assignment-${id}`);

  const hw = by(444);
  assert.equal(hw.source, Source.GRADESCOPE);
  assert.equal(hw.kind, Kind.ASSIGNMENT);
  assert.equal(hw.course, "CIS 5050 Software Systems");
  assert.equal(hw.title, "Homework 4 & writeup");
  assert.equal(hw.url, "https://www.gradescope.com/courses/12345/assignments/444");
  assert.equal(hw.submitted, false);

  assert.equal(by(555).submitted, true);
  assert.notEqual(by(555).dueAt, null);
  assert.equal(by(666).submitted, true);
  assert.equal(by(777).submitted, false);
});

// GradescopeTests.swift:525
test("parses due date and time from non-table Gradescope markup", () => {
  const [a] = assignments(fx("summary-markup.html"), {
    courseName: "CIS 5050 Software Systems", courseURL: COURSE_URL,
  });
  const d = a.dueAt;
  assert.deepEqual(
    [d.getFullYear(), d.getMonth() + 1, d.getDate(), d.getHours(), d.getMinutes()],
    [2026, 5, 24, 23, 59]);
  assert.equal(a.submitted, false);
});

function easternParts(date) {
  const p = Object.fromEntries(
    new Intl.DateTimeFormat("en-US", {
      timeZone: "America/New_York", year: "numeric", month: "numeric", day: "numeric",
      hour: "numeric", minute: "numeric", hourCycle: "h23",
    }).formatToParts(date).map((x) => [x.type, Number(x.value)]));
  return p;
}

// GradescopeTests.swift:553
test("parses separate card assignments with datetime attributes", () => {
  const list = assignments(fx("cards-datetime.html"), {
    courseName: "CIS 5050 Software Systems", courseURL: COURSE_URL,
  });
  assert.equal(list.length, 2);
  const hw = list.find((a) => a.sourceID === "course-12345-assignment-888");
  const e1 = easternParts(hw.dueAt);
  assert.deepEqual([e1.year, e1.month, e1.day], [2026, 5, 24]);
  const demo = list.find((a) => a.sourceID === "course-12345-assignment-999");
  const e2 = easternParts(demo.dueAt);
  assert.deepEqual([e2.year, e2.month, e2.day], [2026, 6, 2]);
  assert.equal(demo.submitted, true);
});

// GradescopeTests.swift:594
test("yearless date far in the future resolves to last year", () => {
  assert.equal(parseDate("Oct 15 at 11:59 PM", utc(2026, 5, 21)).getFullYear(), 2025);
});

// GradescopeTests.swift:602
test("yearless near-future date keeps the current year", () => {
  assert.equal(parseDate("Jun 5 at 11:59 PM", utc(2026, 5, 21)).getFullYear(), 2026);
});

// GradescopeTests.swift:610
test("yearless January date near year-end rolls into next year", () => {
  assert.equal(parseDate("Jan 5 at 11:59 PM", utc(2026, 12, 20)).getFullYear(), 2027);
});

// GradescopeTests.swift:618
test("explicit year in the string is always respected", () => {
  assert.equal(parseDate("Oct 15, 2024 at 11:59 PM", utc(2026, 5, 21)).getFullYear(), 2024);
});

// GradescopeTests.swift:626
test("detects completed assignment detail pages", () => {
  assert.equal(isCompletedAssignmentPage(fx("detail-submitted.html")), true);
  assert.equal(isCompletedAssignmentPage(fx("detail-scored.html")), true);
  assert.equal(isCompletedAssignmentPage(fx("detail-missing.html")), false);
});

// ---- Scores -----------------------------------------------------------------

// GradescopeTests.swift:656
test("extracts earned/max from a labelled score string", () => {
  assert.deepEqual(scoreValues(["Score: 87.5 / 100"]), { earned: 87.5, max: 100 });
});

// GradescopeTests.swift:663
test("extracts earned/max from a bare score cell", () => {
  assert.deepEqual(scoreValues(["10.0 / 10.0"]), { earned: 10, max: 10 });
});

// GradescopeTests.swift:670
test("extracts a decimal score", () => {
  assert.deepEqual(scoreValues(["Grade: 92.75 / 100"]), { earned: 92.75, max: 100 });
});

// GradescopeTests.swift:677
test("extracts a genuine zero score, not confused with ungraded", () => {
  assert.deepEqual(scoreValues(["0 / 100"]), { earned: 0, max: 100 });
});

// GradescopeTests.swift:684
test("returns null for an ungraded cell", () => {
  assert.equal(scoreValues(["Ungraded"]), null);
  assert.equal(scoreValues(["Not Submitted"]), null);
  assert.equal(scoreValues(["Submitted"]), null);
});

// GradescopeTests.swift:691
test("tolerates weird whitespace around the slash", () => {
  assert.deepEqual(scoreValues(["  87.5   /   100  "]), { earned: 87.5, max: 100 });
  assert.deepEqual(scoreValues(["Score:    9  /  10   pts"]), { earned: 9, max: 10 });
});

// GradescopeTests.swift:702
test("a due-date-shaped cell never false-positives as a score", () => {
  assert.equal(scoreValues(["5/24/2026"]), null);
  assert.equal(scoreValues(["Due May 24 at 11:59 PM"]), null);
});

// GradescopeTests.swift:708
test("parses assignment rows with a graded score into scoreEarned/scoreMax", () => {
  const list = assignments(fx("course-table-scores.html"), {
    courseName: "CIS 5050 Software Systems", courseURL: COURSE_URL,
  });
  const graded = list.find((a) => a.sourceID === "course-12345-assignment-111");
  assert.equal(graded.scoreEarned, 87.5);
  assert.equal(graded.scoreMax, 100);
  assert.equal(graded.submitted, true);
  const open = list.find((a) => a.sourceID === "course-12345-assignment-222");
  assert.equal(open.scoreEarned, null);
  assert.equal(open.scoreMax, null);
});

// GradescopeTests.swift:746
test("detects Gradescope login pages", () => {
  assert.equal(isLoginPage(fx("login-page.html")), true);
});

// ---- Term stamping (GradescopeTermStampTests.swift) -------------------------

// GradescopeTermStampTests.swift:39
test("a course carries the term heading it was listed under", () => {
  const r = currentTermCourses(fx("stamp-two-terms.html"), BASE, utc(2026, 5, 21));
  assert.equal(r.courses.length, 1);
  assert.ok(termsEqual(r.courses[0].term, spring2026));
});

// GradescopeTermStampTests.swift:51
test("an assignment inherits its course's term", () => {
  const [a] = assignments(fx("stamp-assignment-row.html"), {
    courseName: "CIS 5500 Databases", courseURL: `${BASE}/courses/111`,
    term: spring2026, referenceDate: utc(2026, 5, 21),
  });
  assert.equal(a.source, Source.GRADESCOPE);
  assert.ok(termsEqual(a.term, spring2026));
});

// GradescopeTermStampTests.swift:76
test("courses kept by the fallback path are stamped too", () => {
  const r = currentTermCourses(fx("stamp-fall2025.html"), BASE, utc(2026, 1, 10));
  assert.equal(r.isFallback, true);
  assert.ok(termsEqual(r.courses[0].term, makeTerm(2025, 30)));
});

// GradescopeTermStampTests.swift:96
test("a quarter school's Winter files under Penn's spring", () => {
  const r = currentTermCourses(fx("stamp-winter-math.html"), BASE, utc(2026, 2, 10));
  assert.ok(termsEqual(r.courses[0].term, spring2026));
});

// GradescopeTermStampTests.swift:114
test("with no term heading to read, the term stays unknown rather than guessed", () => {
  const r = currentTermCourses(fx("stamp-ungrouped.html"), BASE, utc(2026, 5, 21));
  assert.equal(r.courses[0].term, null);
});

// ---- Quirks the Swift tests do not pin (port-map hazards) --------------------
// Each states what Swift's source does; no Swift test covers them.

// Hazard #1, GradescopeClient.swift:824-840. Swift's order is unspecified; this
// port decodes &amp; last.
test("entities decode once: &amp; last, so &amp;lt; stays &lt;", () => {
  assert.equal(cleanText("<p>A &amp; B &amp;lt; &lt;C&gt; &quot;x&quot; &#39;y&#39; &apos;z&apos;&nbsp;w</p>"),
    "A & B &lt; <C> \"x\" 'y' 'z' w");
});

// Hazard #7, GradescopeClient.swift:729-730.
test("single-line script is stripped; a multi-line script body leaks (not dotall)", () => {
  assert.equal(cleanText("a<script>var x = 1;</script>b"), "a b");
  assert.equal(cleanText("a<SCRIPT type='t'>x\ny</SCRIPT>b"), "a x y b");
  assert.equal(cleanText("a<style>p{}</style>b"), "a b");
});

// Hazard #6, GradescopeClient.swift:405.
test("time-zone words are removed by an ungrouped alternation", () => {
  const ref = utc(2026, 5, 21);
  const d = parseDate("Due May 24 at 11:59 PM EDT", ref);
  assert.deepEqual([d.getMonth() + 1, d.getDate(), d.getHours()], [5, 24, 23]);
  // "EDT" is removed from inside a word because only EST and MDT carry a \b.
  assert.equal(parseDate("May 24 11:59 PMEDT", ref).getHours(), 23);
  assert.equal(parseDate("Jun 5 at 9:00 AMEDT", ref).getHours(), 9);
});

// Hazard #8, GradescopeClient.swift:494-496.
test("a link-less row builds its URL on the hard-coded host, not the base URL", () => {
  const html = `<table><tr><td><button data-assignment-id="31" data-assignment-title="Lab 1">Submit</button></td></tr></table>`;
  const [a] = assignments(html, {
    courseName: "X", courseURL: "https://gradescope.example.edu/courses/77",
  });
  assert.equal(a.url, "https://www.gradescope.com/courses/77/assignments/31");
  assert.equal(a.sourceID, "course-77-assignment-31");
});

// GradescopeClient.swift:463, 505: no course id in the URL.
test("a course URL without an id gives source id course-0 and no constructed URL", () => {
  const html = `<tr><td data-assignment-id="5" data-assignment-title="Quiz"></td></tr>`;
  const [a] = assignments(html, { courseName: "Gradescope", courseURL: BASE });
  assert.equal(a.sourceID, "course-0-assignment-5");
  assert.equal(a.url, null);
});

// Hazard #10, GradescopeClient.swift:500, 625-668.
test("a title containing 'graded' marks an unsubmitted row submitted", () => {
  const html = `<tr><td><a href="/courses/1/assignments/2">Graded Discussion</a></td><td>May 24 at 11:59 PM</td></tr>`;
  const [a] = assignments(html, { courseName: "X", courseURL: `${BASE}/courses/1`, referenceDate: utc(2026, 5, 21) });
  assert.equal(a.submitted, true);
  // Cells are tested one by one and any positive cell wins, so a "Not Submitted"
  // cell beside the title does not rescue the row (L500, `texts.contains`).
  const neg = `<tr><td><a href="/courses/1/assignments/2">Graded Discussion</a></td><td>Not Submitted</td></tr>`;
  assert.equal(assignments(neg, { courseName: "X", courseURL: `${BASE}/courses/1` })[0].submitted, true);
});

// Hazard #11, GradescopeClient.swift:58-65.
test("the account page with no courses is parsed as assignments and not filtered", () => {
  const html = `<tr><td><a href="/courses/1/assignments/2">Essay</a></td></tr>`;
  const list = accountPageAssignments(html, BASE);
  assert.equal(list.length, 1);
  assert.equal(list[0].course, "Gradescope");
  assert.equal(list[0].dueAt, null);
  const course = { name: "C", url: `${BASE}/courses/1`, term: null };
  assert.equal(courseAssignments(html, course, true).length, 0);
  assert.equal(courseAssignments(html, course, false).length, 1);
});

// Hazard #12, GradescopeClient.swift:286-293.
test("fallback has no lower bound: a term that has not started can be chosen", () => {
  // Fall 2026's window ends Dec 31 2026, so on Jan 10 2026 `now` is before it
  // and the guard (now < upper + 21 days) passes.
  const r = currentTermCourses(fx("term-fall2026.html"), BASE, utc(2026, 3, 1));
  assert.equal(r.isFallback, true);
  assert.equal(r.courses.length, 1);
});

// Hazard #13, GradescopeClient.swift:694-705: lower bound is (ref + 45d) - 1y.
test("yearless date 44 days before the true 12-month mark rolls forward", () => {
  // ref 2026-05-21; upper = 2026-07-05; lower = 2025-07-05. Jul 1 2026 is
  // inside (lower, upper]; Jul 4 2025 would be too old, but the candidate is
  // always built in the reference year, so test the boundary with Jan 1.
  assert.equal(parseDate("Jan 1 at 12:00 AM", utc(2026, 5, 21)).getFullYear(), 2026);
  assert.equal(parseDate("Jul 5 at 12:00 AM", utc(2026, 5, 21)).getFullYear(), 2026);
  assert.equal(parseDate("Jul 6 at 12:00 AM", utc(2026, 5, 21)).getFullYear(), 2025);
});

// GradescopeClient.swift:412-414
test("an empty or 'No Due Date' string has no date", () => {
  assert.equal(parseDate("", utc(2026, 5, 21)), null);
  assert.equal(parseDate("No due date", utc(2026, 5, 21)), null);
});

// GradescopeClient.swift:435-437 (non-lenient DateFormatter, unverified)
test("an impossible date is not rolled over", () => {
  assert.equal(parseDate("Feb 30, 2026 11:59 PM", utc(2026, 5, 21)), null);
  assert.equal(parseDate("Feb 29 11:59 PM", utc(2026, 5, 21)), null);
});

// GradescopeClient.swift:84-112
test("a detail page only upgrades an unsubmitted assignment", () => {
  const a = makeAssignment({
    source: Source.GRADESCOPE, sourceID: "s", kind: Kind.ASSIGNMENT, course: "C", title: "T",
  });
  assert.equal(refineWithDetailPage(a, fx("detail-submitted.html")).submitted, true);
  assert.equal(refineWithDetailPage(a, fx("detail-missing.html")), a);
});

// Assignment.swift:61-72 via GradescopeClient.swift:147
test("sortAssignments puts dated first, earliest first", () => {
  const mk = (id, dueAt) => makeAssignment({
    source: Source.GRADESCOPE, sourceID: id, kind: Kind.ASSIGNMENT, course: "C", title: id, dueAt,
  });
  const sorted = sortAssignments([mk("c", null), mk("b", utc(2026, 6, 1)), mk("a", utc(2026, 5, 1))]);
  assert.deepEqual(sorted.map((a) => a.sourceID), ["a", "b", "c"]);
});
