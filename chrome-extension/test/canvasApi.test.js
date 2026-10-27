import { test } from "node:test";
import assert from "node:assert/strict";
import {
  assignmentsURL, pagesListURL, pageBodyURL, tabsURL, modulesURL, syllabusBodyURL,
  syllabusPagesSearchURL, syllabusFilesURL, announcementsURL, announcementWindow,
  announcementsRequestURL, stripAntiHijackPrefix, looksLikeHTML, parseCanvasJSON, parseDate,
  parseNextLink, isTrustedNextPageURL, nextPageURL, UnsafePaginationURLError,
  ANNOUNCEMENT_LOOKBACK_DAYS, MAX_PAGES,
} from "../src/core/canvasApi.js";

const BASE = "https://canvas.upenn.edu";

// CourseKnowledgeTests.swift CourseContentAPITests.stripsPrefix
test("strips the while(1); anti-hijack prefix", () => {
  assert.equal(stripAntiHijackPrefix('while(1);[{"url": "a"}]'), '[{"url": "a"}]');
  assert.equal(stripAntiHijackPrefix("[]"), "[]");
  // only at the very start
  assert.equal(stripAntiHijackPrefix(" while(1);[]"), " while(1);[]");
  const parsed = parseCanvasJSON('while(1);[{"url": "a", "title": "A"}]');
  assert.equal(parsed[0].title, "A");
});

// CourseKnowledgeTests.swift CourseContentAPITests.decodesDates
test("decodes Canvas timestamps with and without fractional seconds", () => {
  assert.notEqual(parseDate("2026-09-10T03:59:59Z"), null);
  assert.notEqual(parseDate("2026-09-10T03:59:59.123Z"), null);
  assert.equal(parseDate("not a date"), null);
  assert.equal(parseDate("2026-09-10T03:59:59.123Z").getTime(), Date.UTC(2026, 8, 10, 3, 59, 59, 123));
  assert.equal(parseDate("2026-09-10T03:59:59+05:00").toISOString(), "2026-09-09T22:59:59.000Z");
  assert.equal(parseDate("2026-02-31T00:00:00Z"), null);
});

// CourseKnowledgeTests.swift CourseContentAPITests.linkHeader
test("follows a same-host Link header and refuses another host", () => {
  const header =
    '<https://canvas.upenn.edu/api/v1/courses/1/assignments?page=2&per_page=100>; rel="next", <https://canvas.upenn.edu/api/v1/courses/1/assignments?page=1>; rel="first"';
  assert.equal(nextPageURL(header, BASE), "https://canvas.upenn.edu/api/v1/courses/1/assignments?page=2&per_page=100");
  assert.equal(nextPageURL('<https://x/y?page=1>; rel="first"', BASE), null);
  assert.equal(nextPageURL(null, BASE), null);
  assert.throws(() => nextPageURL('<https://evil.example/next>; rel="next"', BASE), UnsafePaginationURLError);
});

// CanvasAnnouncementsClientTests.swift nextPageGuard
test("same-host https next-page URL is trusted; http and off-host are not", () => {
  assert.ok(isTrustedNextPageURL("https://canvas.upenn.edu/api/v1/announcements?page=2", BASE));
  assert.ok(isTrustedNextPageURL("https://CANVAS.UPENN.EDU/api/v1/announcements?page=2", BASE));
  assert.ok(!isTrustedNextPageURL("http://canvas.upenn.edu/api/v1/announcements?page=2", BASE));
  assert.ok(!isTrustedNextPageURL("https://evil.example.com/api/v1/announcements", BASE));
  assert.ok(!isTrustedNextPageURL("https://canvas.upenn.edu.evil.example.com/api", BASE));
});

// CanvasAnnouncementsClientTests.swift linkHeaderParsing
test('Link header parsing finds rel="next" and returns nil without one', () => {
  const header =
    '<https://canvas.upenn.edu/api/v1/announcements?page=2&per_page=100>; rel="next", <https://canvas.upenn.edu/api/v1/announcements?page=1>; rel="first"';
  assert.equal(parseNextLink(header), "https://canvas.upenn.edu/api/v1/announcements?page=2&per_page=100");
  assert.equal(parseNextLink('<https://canvas.upenn.edu/x>; rel="prev"'), null);
  assert.equal(parseNextLink(null), null);
});

// No Swift test: the response-shape guards the three Swift clients share.
test("looksLikeHTML spots Canvas's silent login redirect", () => {
  assert.ok(looksLikeHTML("  \n<!DOCTYPE html><html>"));
  assert.ok(!looksLikeHTML('while(1);[{"a":1}]'));
  assert.ok(!looksLikeHTML("   "));
});

const pinnedSince = new Date(1_800_000_000 * 1000); // 2027-01-15T08:00:00Z

// CanvasAnnouncementsClientTests.swift urlWithoutUntilIsUnchanged (the literal
// is the Swift test's own)
test("announcementsURL without `until` is exactly the phone's collector request", () => {
  assert.equal(
    announcementsURL(["1010", "2020"], pinnedSince),
    "https://canvas.upenn.edu/api/v1/announcements?context_codes%5B%5D=course_1010&context_codes%5B%5D=course_2020&start_date=2027-01-15T08:00:00Z&per_page=100",
  );
  assert.ok(!announcementsURL(["1010"], pinnedSince, null).includes("end_date"));
});

// CanvasAnnouncementsClientTests.swift urlWithUntilCarriesEndDate
test("announcementsURL with `until` carries end_date, formatted like start_date", () => {
  const until = new Date(pinnedSince.getTime() + 24 * 60 * 60 * 1000);
  const url = announcementsURL(["1010", "2020"], pinnedSince, until);
  assert.equal(
    url,
    "https://canvas.upenn.edu/api/v1/announcements?context_codes%5B%5D=course_1010&context_codes%5B%5D=course_2020&start_date=2027-01-15T08:00:00Z&end_date=2027-01-16T08:00:00Z&per_page=100",
  );
  assert.equal(
    url.replace("&end_date=2027-01-16T08:00:00Z", ""),
    announcementsURL(["1010", "2020"], pinnedSince),
  );
});

// No Swift test pins the window (the phone's announcementFetchWindow lives in
// the UI module). CLAUDE.md "announcements-window trap": the extension must
// always send end_date. since = now - 200 days (the collector's look-back),
// until = now + 24h (the phone's announcementFetchWindow).
test("the extension's announcement request always carries start_date and end_date, through tomorrow", () => {
  const now = new Date("2026-10-22T15:00:00Z");
  const w = announcementWindow(now);
  assert.equal(ANNOUNCEMENT_LOOKBACK_DAYS, 200);
  assert.equal(w.until.toISOString(), "2026-10-23T15:00:00.000Z");
  assert.equal(w.since.toISOString(), "2026-04-05T15:00:00.000Z");
  const url = announcementsRequestURL(["1", "2"], now);
  assert.equal(
    url,
    "https://canvas.upenn.edu/api/v1/announcements?context_codes%5B%5D=course_1&context_codes%5B%5D=course_2&start_date=2026-04-05T15:00:00Z&end_date=2026-10-23T15:00:00Z&per_page=100",
  );
  // The window is longer than Canvas's 28-day default, which is why end_date must be explicit.
  assert.ok(w.until - w.since > 28 * 86_400_000);
});

// No Swift test pins these literals; each is read off the Swift request
// builder named in the comment.
test("endpoint URLs carry the phone's query params", () => {
  // CanvasCourseContentClient.assignments
  assert.equal(
    assignmentsURL("1234"),
    "https://canvas.upenn.edu/api/v1/courses/1234/assignments?per_page=100&include%5B%5D=submission&order_by=due_at",
  );
  // CanvasCourseContentClient.pages (listing)
  assert.equal(
    pagesListURL("1234"),
    "https://canvas.upenn.edu/api/v1/courses/1234/pages?per_page=100&sort=updated_at&order=desc",
  );
  // CanvasCourseContentClient.tabs
  assert.equal(tabsURL("1234"), "https://canvas.upenn.edu/api/v1/courses/1234/tabs?include%5B%5D=external&per_page=100");
  // CanvasModulesClient.fetchAllModulePages
  assert.equal(
    modulesURL("1234"),
    "https://canvas.upenn.edu/api/v1/courses/1234/modules?include%5B%5D=items&include%5B%5D=content_details&per_page=100",
  );
  // CanvasSyllabusClient
  assert.equal(syllabusBodyURL("1234"), "https://canvas.upenn.edu/api/v1/courses/1234?include%5B%5D=syllabus_body");
  assert.equal(
    syllabusPagesSearchURL("1234"),
    "https://canvas.upenn.edu/api/v1/courses/1234/pages?search_term=syllabus&per_page=10",
  );
  assert.equal(
    syllabusFilesURL("1234"),
    "https://canvas.upenn.edu/api/v1/courses/1234/files?search_term=syllabus&per_page=10",
  );
  // A trailing slash on the base does not double up.
  assert.equal(tabsURL("1", { baseURL: "https://canvas.upenn.edu/" }), "https://canvas.upenn.edu/api/v1/courses/1/tabs?include%5B%5D=external&per_page=100");
  assert.equal(MAX_PAGES, 50);
});

// No Swift test. The slug is percent-encoded with urlPathAllowed.
test("pageBodyURL encodes the slug like .urlPathAllowed", () => {
  assert.equal(pageBodyURL("1234", "course-policies"), "https://canvas.upenn.edu/api/v1/courses/1234/pages/course-policies");
  assert.equal(pageBodyURL("1234", "week 1/intro?"), "https://canvas.upenn.edu/api/v1/courses/1234/pages/week%201/intro%3F");
});

import { canvasFileIDsFromLinks } from "../src/core/canvasApi.js";

test("canvasFileIDsFromLinks: Canvas file links in their usual forms, distinct, in order", () => {
  const ids = canvasFileIDsFromLinks([
    { href: "https://canvas.upenn.edu/courses/111/files/55/download?download_frd=1" },
    { href: "/courses/111/files/56?wrap=1#x" },
    { href: "/files/57/preview" },
    { href: "https://canvas.upenn.edu/files/55" },
    { href: "https://canvas.upenn.edu/courses/111/files/58/" },
  ]);
  assert.deepEqual(ids, ["55", "56", "57", "58"]);
});

test("canvasFileIDsFromLinks: other hosts, folders, non-file paths and junk are ignored", () => {
  assert.deepEqual(canvasFileIDsFromLinks([
    { href: "https://example.com/courses/1/files/9" },
    { href: "https://canvas.upenn.edu.evil.com/files/9" },
    { href: "http://canvas.upenn.edu/files/9" },
    { href: "/courses/111/files/folder/Lectures" },
    { href: "/courses/111/files" },
    { href: "/courses/111/assignments/9" },
    { href: "/files/abc" },
    { href: "/files/9/other" },
    { href: "" }, { href: 5 }, null, {},
  ]), []);
  assert.deepEqual(canvasFileIDsFromLinks(undefined), []);
});
