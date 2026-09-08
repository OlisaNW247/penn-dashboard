// Unit tests for the same-host BFS crawler in
// supabase/functions/_shared/crawl.ts. Every fetch is a scripted fake --
// this container has no route to a real Penn course site -- keyed by exact
// request URL, with a call log so tests can prove a URL was (or, for
// robots.txt/off-site/ignored-host links, was never) actually fetched, not
// merely absent from the result.
import { strict as assert } from "node:assert";
import { crawlSite } from "../supabase/functions/_shared/crawl.ts";

const USER_AGENT = "LowHangingFruit-test/1";

async function readFixture(name: string): Promise<string> {
  return await Deno.readTextFile(new URL(`./fixtures/${name}`, import.meta.url));
}

async function readFixtureBytes(name: string): Promise<Uint8Array> {
  return await Deno.readFile(new URL(`./fixtures/${name}`, import.meta.url));
}

function withURL(response: Response, url: string): Response {
  // `Response.url` is normally set by the runtime's real fetch to wherever
  // a redirect chain actually landed; a scripted fake has to fake that
  // too, since `crawlSite`'s same-site containment is computed from it.
  Object.defineProperty(response, "url", { value: url, configurable: true });
  return response;
}

function htmlResponse(url: string, body: string): Response {
  return withURL(new Response(body, { status: 200, headers: { "content-type": "text/html; charset=utf-8" } }), url);
}

function pdfResponse(url: string, bytes: Uint8Array): Response {
  return withURL(
    new Response(bytes as unknown as BodyInit, { status: 200, headers: { "content-type": "application/pdf" } }),
    url,
  );
}

function textResponse(url: string, body: string, contentType: string): Response {
  return withURL(new Response(body, { status: 200, headers: { "content-type": contentType } }), url);
}

interface FakeSite {
  fetchImpl: typeof fetch;
  calls: string[];
}

/** Builds a `fetchImpl` from a map of exact URL -> response factory (a
 *  factory, not a bare `Response`, because a `Response` body can only be
 *  read once and a couple of these tests fetch the same URL more than once
 *  across separate `crawlSite` calls). Anything not in the map 404s. */
function fakeSite(handlers: Record<string, () => Response>): FakeSite {
  const calls: string[] = [];
  const fetchImpl = (async (input: RequestInfo | URL) => {
    const url = typeof input === "string"
      ? input
      : input instanceof URL
      ? input.toString()
      : (input as Request).url;
    calls.push(url);
    const handler = handlers[url];
    return handler ? handler() : new Response("not found", { status: 404 });
  }) as typeof fetch;
  return { fetchImpl, calls };
}

const START_URL = "https://www.seas.upenn.edu/~cis2400/current/";
const HOME_URL = "https://www.seas.upenn.edu/~cis2400/26fa/";
const SCHEDULE_URL = "https://www.seas.upenn.edu/~cis2400/26fa/schedule/";
const SYLLABUS_URL = "https://www.seas.upenn.edu/~cis2400/26fa/syllabus/";
const STAFF_URL = "https://www.seas.upenn.edu/~cis2400/26fa/staff/";
const HANDOUT_PDF_URL = "https://www.seas.upenn.edu/~cis2400/26fa/syllabus/handout.pdf";
const CIS1210_URL = "https://www.seas.upenn.edu/~cis1210/current/";
const ROBOTS_URL = "https://www.seas.upenn.edu/robots.txt";

async function buildFullSite(): Promise<FakeSite> {
  const homeHTML = await readFixture("cis2400-home.html");
  const robotsTxt = await readFixture("robots.txt");
  const pdfBytes = await readFixtureBytes("sample.pdf");

  const scheduleHTML = `<!DOCTYPE html><html><head><title>Schedule</title></head><body>
    <h1>Schedule</h1>
    <p>Week 1 readings posted.</p>
    <a href="/~cis2400/26fa/">Home</a>
    <a href="https://www.seas.upenn.edu/~cis1210/current/">A different course</a>
  </body></html>`;

  const syllabusHTML = `<!DOCTYPE html><html><head><title>Syllabus</title></head><body>
    <h1>Syllabus</h1>
    <p>See the <a href="/~cis2400/26fa/syllabus/handout.pdf">grading handout (PDF)</a>.</p>
  </body></html>`;

  return fakeSite({
    [START_URL]: () => htmlResponse(HOME_URL, homeHTML),
    [ROBOTS_URL]: () => textResponse(ROBOTS_URL, robotsTxt, "text/plain"),
    [SCHEDULE_URL]: () => htmlResponse(SCHEDULE_URL, scheduleHTML),
    [SYLLABUS_URL]: () => htmlResponse(SYLLABUS_URL, syllabusHTML),
    [HANDOUT_PDF_URL]: () => pdfResponse(HANDOUT_PDF_URL, pdfBytes),
    [STAFF_URL]: () => htmlResponse(STAFF_URL, "<title>Staff</title><body>should never be fetched</body>"),
  });
}

Deno.test("crawlSite: collects the home page plus in-bounds linked pages, following a redirect", async () => {
  const site = await buildFullSite();
  const result = await crawlSite({ fetchImpl: site.fetchImpl, startURL: START_URL, userAgent: USER_AGENT });

  const urls = result.pages.map((page) => page.url);
  assert.ok(urls.includes(HOME_URL));
  assert.ok(urls.includes(SCHEDULE_URL));
  assert.ok(urls.includes(SYLLABUS_URL));

  const home = result.pages.find((page) => page.url === HOME_URL)!;
  assert.equal(home.title, "CIS 2400 Fall 2026");
  assert.equal(home.depth, 0);
});

Deno.test("crawlSite: never follows a link to a different course under the same host", async () => {
  const site = await buildFullSite();
  const result = await crawlSite({ fetchImpl: site.fetchImpl, startURL: START_URL, userAgent: USER_AGENT });

  assert.equal(result.pages.some((page) => page.url === CIS1210_URL), false);
  assert.equal(site.calls.includes(CIS1210_URL), false);
  // Still recorded as a link the crawl saw, just not one it followed.
  assert.ok(result.links.some((link) => link.href === CIS1210_URL));
});

Deno.test("crawlSite: never follows or fetches an IGNORED_HOSTS link (Gradescope, Ed, OHQ)", async () => {
  const site = await buildFullSite();
  const result = await crawlSite({ fetchImpl: site.fetchImpl, startURL: START_URL, userAgent: USER_AGENT });

  for (const host of ["gradescope.com", "edstem.org", "ohq.io"]) {
    assert.equal(site.calls.some((url) => url.includes(host)), false, `expected no fetch to ${host}`);
  }
  // Still surfaced in `links` -- discover-websites' sideIDs() reads these.
  assert.ok(result.links.some((link) => link.href.includes("gradescope.com")));
});

Deno.test("crawlSite: obeys robots.txt Disallow for the staff page", async () => {
  const site = await buildFullSite();
  const result = await crawlSite({ fetchImpl: site.fetchImpl, startURL: START_URL, userAgent: USER_AGENT });

  assert.equal(result.pages.some((page) => page.url === STAFF_URL), false);
  assert.equal(site.calls.includes(STAFF_URL), false, "staff/ must never actually be fetched");
  assert.ok(result.blockedByRobots.includes(STAFF_URL));
});

Deno.test("crawlSite: fetches and extracts text from a linked PDF, capped and via unpdf", async () => {
  const site = await buildFullSite();
  const result = await crawlSite({ fetchImpl: site.fetchImpl, startURL: START_URL, userAgent: USER_AGENT });

  const pdfPage = result.pages.find((page) => page.url === HANDOUT_PDF_URL);
  assert.ok(pdfPage, "expected the linked PDF to be crawled");
  assert.equal(pdfPage!.contentType, "application/pdf");
  assert.ok(pdfPage!.text.includes("Late policy"));
  assert.equal(pdfPage!.title, "handout.pdf");
});

Deno.test("crawlSite: an oversized PDF is skipped rather than truncated-and-kept", async () => {
  const oversized = new Uint8Array(200_001);
  const site = fakeSite({
    [START_URL]: () =>
      htmlResponse(
        HOME_URL,
        `<title>Home</title><a href="/~cis2400/26fa/big.pdf">big</a>`,
      ),
    [ROBOTS_URL]: () => new Response("", { status: 404 }),
    ["https://www.seas.upenn.edu/~cis2400/26fa/big.pdf"]: () =>
      pdfResponse("https://www.seas.upenn.edu/~cis2400/26fa/big.pdf", oversized),
  });

  const result = await crawlSite({ fetchImpl: site.fetchImpl, startURL: START_URL, userAgent: USER_AGENT });
  assert.equal(result.pages.some((page) => page.contentType === "application/pdf"), false);
});

Deno.test("crawlSite: maxDepth stops link-following past the limit", async () => {
  const site = await buildFullSite();
  const result = await crawlSite({
    fetchImpl: site.fetchImpl,
    startURL: START_URL,
    userAgent: USER_AGENT,
    maxDepth: 0,
  });

  assert.deepEqual(result.pages.map((page) => page.url), [HOME_URL]);
  assert.equal(site.calls.includes(SCHEDULE_URL), false);
});

Deno.test("crawlSite: maxPages stops the crawl once reached", async () => {
  const site = await buildFullSite();
  const result = await crawlSite({
    fetchImpl: site.fetchImpl,
    startURL: START_URL,
    userAgent: USER_AGENT,
    maxPages: 2,
  });

  assert.equal(result.pages.length, 2);
});

Deno.test("crawlSite: deduplicates a link back to an already-visited page", async () => {
  const site = await buildFullSite();
  const result = await crawlSite({ fetchImpl: site.fetchImpl, startURL: START_URL, userAgent: USER_AGENT });

  // The schedule page links back to home; home must only ever be fetched
  // once (as the start URL), never re-fetched via its own nav link.
  const homeFetches = site.calls.filter((url) => url === START_URL || url === HOME_URL);
  assert.equal(homeFetches.length, 1);
});

Deno.test("crawlSite: a start-page network failure returns the empty result, never throws", async () => {
  const fetchImpl = (async () => {
    throw new Error("network unreachable");
  }) as typeof fetch;

  const result = await crawlSite({ fetchImpl, startURL: START_URL, userAgent: USER_AGENT });
  assert.deepEqual(result, { pages: [], links: [], blockedByRobots: [] });
});

Deno.test("crawlSite: a non-ok start response returns the empty result", async () => {
  const fetchImpl = (async () => new Response("nope", { status: 404 })) as typeof fetch;

  const result = await crawlSite({ fetchImpl, startURL: START_URL, userAgent: USER_AGENT });
  assert.deepEqual(result, { pages: [], links: [], blockedByRobots: [] });
});

Deno.test("crawlSite: missing robots.txt (404) means no restriction at all", async () => {
  const site = fakeSite({
    [START_URL]: () => htmlResponse(HOME_URL, "<title>Home</title><body>no nav here</body>"),
    [ROBOTS_URL]: () => new Response("not found", { status: 404 }),
  });

  const result = await crawlSite({ fetchImpl: site.fetchImpl, startURL: START_URL, userAgent: USER_AGENT });
  assert.equal(result.pages.length, 1);
  assert.deepEqual(result.blockedByRobots, []);
});
