// Unit tests for the pure course-website discovery logic in
// supabase/functions/_shared/websites.ts. Run with `deno task test`. No
// network, no database -- fixtures under test/fixtures/ stand in for the
// real CIS Advising Handbook directory page and a CIS course's own site.
import { strict as assert } from "node:assert";
import {
  candidateFromLink,
  conventionURLs,
  extractLinks,
  htmlToText,
  IGNORED_HOSTS,
  olderThan,
  ONE_DAY_MS,
  pageTitle,
  parseCisDirectory,
  SEVEN_DAYS_MS,
  sideIDs,
  termAliases,
  verifyPage,
  websiteDocumentID,
  websiteContentHash,
  websitesPendingCourses,
} from "../supabase/functions/_shared/websites.ts";

async function readFixture(name: string): Promise<string> {
  return await Deno.readTextFile(new URL(`./fixtures/${name}`, import.meta.url));
}

// ---------------------------------------------------------------------
// candidateFromLink
// ---------------------------------------------------------------------

Deno.test("candidateFromLink: scores a .upenn.edu link containing the compact course code", () => {
  const result = candidateFromLink({
    href: "https://www.seas.upenn.edu/~cis2400/current/",
    text: "course site",
    origin: "https://canvas.upenn.edu/courses/1/assignments/1",
    courseCode: "CIS 2400",
  });
  assert.ok(result);
  assert.equal(result.source, "canvas-link");
  // code match (3) + "course site" text match (2) + upenn.edu host (1) = 6
  assert.equal(result.confidence, 6);
  assert.equal(result.url, "https://www.seas.upenn.edu/~cis2400/current/");
});

Deno.test("candidateFromLink: matches a dashed course code in the URL", () => {
  const result = candidateFromLink({
    href: "https://cis-2400.example.org/",
    text: "resources",
    origin: "https://example.org/",
    courseCode: "CIS 2400",
  });
  assert.ok(result);
  assert.equal(result.confidence, 3);
});

Deno.test("candidateFromLink: drops every IGNORED_HOSTS entry", () => {
  for (const host of IGNORED_HOSTS) {
    const result = candidateFromLink({
      href: `https://${host}/courses/2400`,
      text: "course site",
      origin: "https://example.org/",
      courseCode: "CIS 2400",
    });
    assert.equal(result, undefined, `expected ${host} to be ignored`);
  }
});

Deno.test("candidateFromLink: drops a subdomain of an ignored host", () => {
  const result = candidateFromLink({
    href: "https://upenn.instructure.com/courses/1/assignments/1",
    text: "course site",
    origin: "https://example.org/",
    courseCode: "CIS 2400",
  });
  assert.equal(result, undefined);
});

Deno.test("candidateFromLink: never matches a lookalike host by substring", () => {
  // "notgoogle.com" ends with the literal characters "google.com" but is
  // not a subdomain of it -- suffix-with-dot matching must not be fooled.
  const result = candidateFromLink({
    href: "https://notgoogle.com/cis2400/",
    text: "course site",
    origin: "https://example.org/",
    courseCode: "CIS 2400",
  });
  assert.ok(result, "notgoogle.com must not be treated as an ignored host");
});

Deno.test("candidateFromLink: drops the Just the Docs github.com footer credit", () => {
  const result = candidateFromLink({
    href: "https://github.com/just-the-docs/just-the-docs",
    text: "Just the Docs",
    origin: "https://example.org/",
    courseCode: "CIS 2400",
  });
  assert.equal(result, undefined);
});

Deno.test("candidateFromLink: a plain github.com link is not ignored by host alone", () => {
  const result = candidateFromLink({
    href: "https://github.com/CIS-3500",
    text: "course website",
    origin: "https://example.org/",
    courseCode: "CIS 3500",
  });
  // github.com/CIS-3500 doesn't contain the compact code "cis3500" (it's
  // "CIS-3500" with a dash where the compact form has none, and this repo
  // path has no digits touching letters the way a course URL would) --
  // but "course website" text still earns it points, so it is NOT
  // filtered by IGNORED_HOSTS even though it's not a strong candidate.
  assert.ok(result);
});

Deno.test("candidateFromLink: drops a same-page fragment link", () => {
  const result = candidateFromLink({
    href: "#nav",
    text: "course website",
    origin: "https://example.org/cis2400/",
    courseCode: "CIS 2400",
  });
  assert.equal(result, undefined);
});

Deno.test("candidateFromLink: drops mailto: and javascript: links", () => {
  assert.equal(
    candidateFromLink({
      href: "mailto:prof@upenn.edu",
      text: "course website",
      origin: "https://example.org/",
      courseCode: "CIS 2400",
    }),
    undefined,
  );
  assert.equal(
    candidateFromLink({
      href: "javascript:void(0)",
      text: "course website",
      origin: "https://example.org/",
      courseCode: "CIS 2400",
    }),
    undefined,
  );
});

Deno.test("candidateFromLink: zero-confidence link (no code, no wording, not upenn.edu) is dropped", () => {
  const result = candidateFromLink({
    href: "https://example.org/random-page",
    text: "click here",
    origin: "https://example.org/",
    courseCode: "CIS 2400",
  });
  assert.equal(result, undefined);
});

Deno.test("candidateFromLink: a bare .upenn.edu link with no other signal still scores 1", () => {
  const result = candidateFromLink({
    href: "https://www.upenn.edu/about",
    text: "click here",
    origin: "https://example.org/",
    courseCode: "CIS 2400",
  });
  assert.ok(result);
  assert.equal(result.confidence, 1);
});

Deno.test("candidateFromLink: strips a tracking query parameter but keeps a trailing slash", () => {
  const result = candidateFromLink({
    href: "https://www.seas.upenn.edu/~cis2400/current/?utm_source=canvas",
    text: "course site",
    origin: "https://example.org/",
    courseCode: "CIS 2400",
  });
  assert.ok(result);
  assert.equal(result.url, "https://www.seas.upenn.edu/~cis2400/current/");
});

// ---------------------------------------------------------------------
// parseCisDirectory
// ---------------------------------------------------------------------

Deno.test("parseCisDirectory: finds the row-text code for a plain course link", async () => {
  const html = await readFixture("cis-directory.html");
  const entries = parseCisDirectory(html);
  const cis1210 = entries.find((entry) => entry.url === "https://www.seas.upenn.edu/~cis1210/current/");
  assert.ok(cis1210);
  assert.equal(cis1210.catalogCode, "CIS-1210");
});

Deno.test("parseCisDirectory: recovers a code embedded in the domain (cis1912.org)", async () => {
  const html = await readFixture("cis-directory.html");
  const entries = parseCisDirectory(html);
  const entry = entries.find((entry) => entry.url === "https://cis1912.org/");
  assert.ok(entry);
  assert.equal(entry.catalogCode, "CIS-1912");
});

Deno.test("parseCisDirectory: recovers a code embedded in a numbered subdomain (cis5550.seas.upenn.edu)", async () => {
  const html = await readFixture("cis-directory.html");
  const entries = parseCisDirectory(html);
  const entry = entries.find((entry) => entry.url === "https://cis5550.seas.upenn.edu/");
  assert.ok(entry);
  assert.equal(entry.catalogCode, "CIS-5550");
});

Deno.test("parseCisDirectory: prefers row text over a misleading href for a personal-page URL", async () => {
  const html = await readFixture("cis-directory.html");
  const entries = parseCisDirectory(html);
  const entry = entries.find((entry) => entry.url === "https://www.cis.upenn.edu/~sga001/classes/cis551f25/");
  assert.ok(entry);
  assert.equal(entry.catalogCode, "CIS-5510");
});

Deno.test("parseCisDirectory: keeps a stale link (verification, not parsing, judges staleness)", async () => {
  const html = await readFixture("cis-directory.html");
  const entries = parseCisDirectory(html);
  const entry = entries.find((entry) => entry.url === "https://www.seas.upenn.edu/~bhusnur4/cis105/16fa/");
  assert.ok(entry);
  assert.equal(entry.catalogCode, "CIS-105");
});

Deno.test("parseCisDirectory: drops the ~cis19x wildcard placeholder", async () => {
  const html = await readFixture("cis-directory.html");
  const entries = parseCisDirectory(html);
  const entry = entries.find((entry) => entry.url.includes("cis19x"));
  assert.equal(entry, undefined);
});

Deno.test("parseCisDirectory: drops a github.com repo link", async () => {
  const html = await readFixture("cis-directory.html");
  const entries = parseCisDirectory(html);
  const entry = entries.find((entry) => entry.url.includes("github.com"));
  assert.equal(entry, undefined);
});

Deno.test("parseCisDirectory: drops mailto: and bare department-index links", async () => {
  const html = await readFixture("cis-directory.html");
  const entries = parseCisDirectory(html);
  assert.equal(entries.some((entry) => entry.url.startsWith("mailto:")), false);
  assert.equal(entries.some((entry) => entry.url === "https://www.cis.upenn.edu/"), false);
});

Deno.test("parseCisDirectory: drops links back to the handbook's own navigation", async () => {
  const html = await readFixture("cis-directory.html");
  const entries = parseCisDirectory(html);
  assert.equal(entries.some((entry) => entry.url.includes("advising.cis.upenn.edu")), false);
  assert.equal(entries.some((entry) => entry.url.includes("ugrad.cis.upenn.edu")), false);
});

// ---------------------------------------------------------------------
// conventionURLs
// ---------------------------------------------------------------------

Deno.test("conventionURLs: both historical CIS hostnames, lowercase, no dash", () => {
  assert.deepEqual(conventionURLs("CIS-2400"), [
    "https://www.seas.upenn.edu/~cis2400/current/",
    "https://www.cis.upenn.edu/~cis2400/current/",
  ]);
});

Deno.test("conventionURLs: empty for a non-CIS/CIT department", () => {
  assert.deepEqual(conventionURLs("PHYS-0151"), []);
});

Deno.test("conventionURLs: empty for an unparseable code", () => {
  assert.deepEqual(conventionURLs("not a code"), []);
});

// ---------------------------------------------------------------------
// termAliases
// ---------------------------------------------------------------------

Deno.test("termAliases: fall 2026", () => {
  assert.deepEqual(termAliases("2026C"), [
    "fall 2026",
    "2026 fall",
    "26fa",
    "fa26",
    "f26",
    "fall26",
    "2026c",
  ]);
});

Deno.test("termAliases: spring includes the brief's abbreviations", () => {
  const aliases = termAliases("2026A");
  for (const expected of ["sp26", "26sp", "s26"]) {
    assert.ok(aliases.includes(expected), `expected spring aliases to include "${expected}"`);
  }
});

Deno.test("termAliases: summer includes the brief's abbreviations", () => {
  const aliases = termAliases("2026B");
  for (const expected of ["su26", "26su"]) {
    assert.ok(aliases.includes(expected), `expected summer aliases to include "${expected}"`);
  }
});

Deno.test("termAliases: unparseable semester returns []", () => {
  assert.deepEqual(termAliases("not-a-term"), []);
});

// ---------------------------------------------------------------------
// verifyPage
// ---------------------------------------------------------------------

Deno.test("verifyPage: a live cis2400 page for the right term verifies", async () => {
  const html = await readFixture("cis2400-home.html");
  const result = verifyPage({
    html,
    finalURL: "https://www.seas.upenn.edu/~cis2400/26fa/",
    catalogCode: "CIS-2400",
    semester: "2026C",
  });
  assert.equal(result.ok, true);
  assert.equal(result.codeHit, true);
  assert.equal(result.termHit, true);
  assert.equal(result.title, "CIS 2400 Fall 2026");
});

Deno.test("verifyPage: right course, wrong term does not verify", async () => {
  const html = await readFixture("cis2400-home.html");
  const result = verifyPage({
    html,
    finalURL: "https://www.seas.upenn.edu/~cis2400/26fa/",
    catalogCode: "CIS-2400",
    semester: "2027C",
  });
  assert.equal(result.ok, false);
  assert.equal(result.codeHit, true);
  assert.equal(result.termHit, false);
  assert.equal(result.reason, "matched course code but not term");
});

Deno.test("verifyPage: right term, wrong course does not verify", async () => {
  const html = await readFixture("cis2400-home.html");
  const result = verifyPage({
    html,
    finalURL: "https://www.seas.upenn.edu/~cis2400/26fa/",
    catalogCode: "CIS-1210",
    semester: "2026C",
  });
  assert.equal(result.ok, false);
  assert.equal(result.codeHit, false);
  assert.equal(result.termHit, true);
});

Deno.test("verifyPage: term match via URL path alone (26fa)", async () => {
  const result = verifyPage({
    html: "<title>CIS 2400</title><h1>CIS 2400</h1><p>Welcome.</p>",
    finalURL: "https://www.seas.upenn.edu/~cis2400/26fa/",
    catalogCode: "CIS-2400",
    semester: "2026C",
  });
  assert.equal(result.termHit, true);
});

// ---------------------------------------------------------------------
// extractLinks / sideIDs
// ---------------------------------------------------------------------

Deno.test("extractLinks: resolves relative hrefs against the base URL", async () => {
  const html = await readFixture("cis2400-home.html");
  const links = extractLinks(html, "https://www.seas.upenn.edu/~cis2400/26fa/");
  const hrefs = links.map((link) => link.href);
  assert.ok(hrefs.includes("https://www.seas.upenn.edu/~cis2400/26fa/schedule/"));
  assert.ok(hrefs.includes("https://www.seas.upenn.edu/~cis2400/26fa/staff/"));
  assert.ok(hrefs.includes("https://www.gradescope.com/courses/1343650"));
});

Deno.test("extractLinks: skips fragment, javascript: and mailto: hrefs", () => {
  const html = `
    <a href="#top">top</a>
    <a href="javascript:void(0)">js</a>
    <a href="mailto:x@y.com">mail</a>
    <a href="/real/">real</a>
  `;
  const links = extractLinks(html, "https://example.org/base/");
  assert.deepEqual(links.map((link) => link.href), ["https://example.org/real/"]);
});

Deno.test("sideIDs: extracts Gradescope and Ed course ids from a page's links", async () => {
  const html = await readFixture("cis2400-home.html");
  const links = extractLinks(html, "https://www.seas.upenn.edu/~cis2400/26fa/");
  const ids = sideIDs(links);
  assert.equal(ids.gradescopeCourseID, "1343650");
  assert.equal(ids.edCourseID, "100922");
});

Deno.test("sideIDs: returns an empty object when neither is present", () => {
  const ids = sideIDs([{ href: "https://example.org/", text: "home" }]);
  assert.deepEqual(ids, {});
});

// ---------------------------------------------------------------------
// htmlToText / pageTitle
// ---------------------------------------------------------------------

Deno.test("htmlToText: drops script/style content and decodes entities", () => {
  const html = "<style>.x{color:red}</style><script>alert(1)</script><p>Caf&eacute;? &amp; more &mdash; ok</p>";
  const text = htmlToText(html);
  assert.equal(text.includes("alert"), false);
  assert.equal(text.includes("color:red"), false);
  assert.ok(text.includes("&"));
  assert.ok(text.includes("—"));
});

Deno.test("htmlToText: keeps nav content (it may carry the schedule/assignment list)", async () => {
  const html = await readFixture("cis2400-home.html");
  const text = htmlToText(html);
  assert.ok(text.includes("Schedule"));
  assert.ok(text.includes("Syllabus"));
});

Deno.test("htmlToText: inserts a line break between block elements", () => {
  const text = htmlToText("<p>First paragraph.</p><p>Second paragraph.</p>");
  assert.match(text, /First paragraph\.\n+Second paragraph\./);
});

Deno.test("pageTitle: reads and decodes the <title>", () => {
  assert.equal(pageTitle("<title>CIS 2400 &mdash; Fall 2026</title>"), "CIS 2400 — Fall 2026");
});

Deno.test("pageTitle: empty string when there is no <title>", () => {
  assert.equal(pageTitle("<p>no title here</p>"), "");
});

// ---------------------------------------------------------------------
// websiteDocumentID / websiteContentHash
// ---------------------------------------------------------------------

Deno.test("websiteDocumentID: stable, prefixed, 16 hex chars of the URL's hash", async () => {
  const id = await websiteDocumentID("100", "https://www.seas.upenn.edu/~cis2400/26fa/syllabus/");
  assert.match(id, /^website:100:[0-9a-f]{16}$/);
  const again = await websiteDocumentID("100", "https://www.seas.upenn.edu/~cis2400/26fa/syllabus/");
  assert.equal(id, again);
});

Deno.test("websiteDocumentID: different urls hash differently", async () => {
  const a = await websiteDocumentID("100", "https://example.org/a/");
  const b = await websiteDocumentID("100", "https://example.org/b/");
  assert.notEqual(a, b);
});

Deno.test("websiteContentHash: stable for identical input, differs when text changes", async () => {
  const a = await websiteContentHash("Syllabus", "grading: 60% projects");
  const b = await websiteContentHash("Syllabus", "grading: 60% projects");
  const c = await websiteContentHash("Syllabus", "grading: 70% projects");
  assert.equal(a, b);
  assert.notEqual(a, c);
});

// ---------------------------------------------------------------------
// olderThan / websitesPendingCourses
// ---------------------------------------------------------------------

Deno.test("olderThan: null is always stale", () => {
  assert.equal(olderThan(null, new Date("2026-09-08T00:00:00Z"), SEVEN_DAYS_MS), true);
});

Deno.test("olderThan: an unparseable timestamp is stale", () => {
  assert.equal(olderThan("not-a-date", new Date("2026-09-08T00:00:00Z"), SEVEN_DAYS_MS), true);
});

Deno.test("olderThan: within the window is not stale, past it is", () => {
  const now = new Date("2026-09-08T00:00:00Z");
  const fiveDaysAgo = new Date(now.getTime() - 5 * ONE_DAY_MS).toISOString();
  const eightDaysAgo = new Date(now.getTime() - 8 * ONE_DAY_MS).toISOString();
  assert.equal(olderThan(fiveDaysAgo, now, SEVEN_DAYS_MS), false);
  assert.equal(olderThan(eightDaysAgo, now, SEVEN_DAYS_MS), true);
});

Deno.test("websitesPendingCourses: excludes a course recently verified", () => {
  const result = websitesPendingCourses([
    { courseID: "100", hasCandidate: true, recentlyVerified: true, catalogCode: "CIS-2400" },
  ]);
  assert.deepEqual(result, []);
});

Deno.test("websitesPendingCourses: includes a course with a candidate and no recent verification", () => {
  const result = websitesPendingCourses([
    { courseID: "100", hasCandidate: true, recentlyVerified: false },
  ]);
  assert.deepEqual(result, ["100"]);
});

Deno.test("websitesPendingCourses: includes a CIS/CIT course even with zero candidates", () => {
  const result = websitesPendingCourses([
    { courseID: "100", hasCandidate: false, recentlyVerified: false, catalogCode: "CIS-1210" },
    { courseID: "200", hasCandidate: false, recentlyVerified: false, catalogCode: "CIT-5900" },
  ]);
  assert.deepEqual(result, ["100", "200"]);
});

Deno.test("websitesPendingCourses: excludes a non-CIS/CIT course with no candidate", () => {
  const result = websitesPendingCourses([
    { courseID: "100", hasCandidate: false, recentlyVerified: false, catalogCode: "PHYS-0151" },
  ]);
  assert.deepEqual(result, []);
});
