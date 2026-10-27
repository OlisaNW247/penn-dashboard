// Unit tests for the same-host BFS crawler in
// supabase/functions/_shared/crawl.ts. Every fetch is a scripted fake --
// this container has no route to a real Penn course site -- keyed by exact
// request URL, with a call log so tests can prove a URL was (or, for
// robots.txt/off-site/ignored-host links, was never) actually fetched, not
// merely absent from the result.
import { strict as assert } from "node:assert";
import { crawlSite as crawlSiteWithGuard, type CrawlOptions } from "../supabase/functions/_shared/crawl.ts";
import type { NetGuard } from "../supabase/functions/_shared/netguard.ts";

const USER_AGENT = "LowHangingFruit-test/1";

// The crawler's default guard resolves names with real DNS. These tests are
// about crawl logic, so they hand it a guard whose resolver answers with a
// public address and never touches the network; the guard itself is covered
// by netguard.test.ts and the crawl-level cases at the end of this file.
const TEST_GUARD: NetGuard = {
  allowedHostSuffixes: ["upenn.edu"],
  resolve: () => Promise.resolve(["130.91.1.1"]),
  maxRedirects: 5,
  resolveTimeoutMs: 1000,
};

function crawlSite(options: CrawlOptions) {
  return crawlSiteWithGuard({ guard: TEST_GUARD, ...options });
}

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

// ---------------------------------------------------------------------
// The guard inside the crawl (hardening BE-F): what the crawler will fetch,
// and how much of it it will read. The rules themselves are pinned in
// netguard.test.ts; these show `crawlSite` actually applies them to the
// start page, robots.txt, every redirect hop and every page body.
// ---------------------------------------------------------------------

function redirectResponse(location: string, status = 302): Response {
  return new Response(null, { status, headers: { location } });
}

/** A response whose body never ends; `state` records how much was pulled
 *  and whether the consumer cancelled it. */
function endlessHTML(url: string, state: { pulled: number; cancelled: boolean }): Response {
  const chunk = new TextEncoder().encode("x".repeat(64 * 1024));
  const body = new ReadableStream<Uint8Array>({
    pull(controller) {
      state.pulled += chunk.byteLength;
      controller.enqueue(chunk);
    },
    cancel() {
      state.cancelled = true;
    },
  });
  return withURL(new Response(body, { status: 200, headers: { "content-type": "text/html" } }), url);
}

Deno.test("crawlSite: a start URL that redirects to a metadata address is never followed", async () => {
  const site = fakeSite({
    [START_URL]: () => redirectResponse("https://169.254.169.254/latest/meta-data/"),
    "https://169.254.169.254/latest/meta-data/": () => htmlResponse("https://169.254.169.254/latest/meta-data/", "secrets"),
  });
  const result = await crawlSite({ fetchImpl: site.fetchImpl, startURL: START_URL, userAgent: USER_AGENT });
  assert.deepEqual(result, { pages: [], links: [], blockedByRobots: [] });
  assert.deepEqual(site.calls, [START_URL], "the redirect target must never be requested");
});

Deno.test("crawlSite: a start URL on a host off the allow-list, or not https, is never requested", async () => {
  for (const startURL of ["https://example.org/course/", "http://www.seas.upenn.edu/~cis2400/", "https://127.0.0.1/"]) {
    const site = fakeSite({ [startURL]: () => htmlResponse(startURL, "<title>x</title>") });
    const result = await crawlSite({ fetchImpl: site.fetchImpl, startURL, userAgent: USER_AGENT });
    assert.deepEqual(result, { pages: [], links: [], blockedByRobots: [] }, startURL);
    assert.deepEqual(site.calls, [], `${startURL} must not be requested`);
  }
});

Deno.test("crawlSite: an in-bounds link that redirects off the allowed hosts is skipped and its target never requested", async () => {
  const redirectingLink = "https://www.seas.upenn.edu/~cis2400/26fa/bounce/";
  const site = fakeSite({
    [START_URL]: () =>
      htmlResponse(HOME_URL, `<title>Home</title><a href="/~cis2400/26fa/bounce/">bounce</a><a href="/~cis2400/26fa/ok/">ok</a>`),
    [ROBOTS_URL]: () => new Response("", { status: 404 }),
    [redirectingLink]: () => redirectResponse("https://169.254.169.254/latest/meta-data/"),
    "https://169.254.169.254/latest/meta-data/": () => htmlResponse("https://169.254.169.254/latest/meta-data/", "secrets"),
    "https://www.seas.upenn.edu/~cis2400/26fa/ok/": () =>
      htmlResponse("https://www.seas.upenn.edu/~cis2400/26fa/ok/", "<title>OK</title><body>fine</body>"),
  });
  const result = await crawlSite({ fetchImpl: site.fetchImpl, startURL: START_URL, userAgent: USER_AGENT });
  assert.deepEqual(result.pages.map((page) => page.title).sort(), ["Home", "OK"]);
  assert.equal(site.calls.includes("https://169.254.169.254/latest/meta-data/"), false);
});

Deno.test("crawlSite: a page whose body never ends is cut at the cap and the connection cancelled", async () => {
  const state = { pulled: 0, cancelled: false };
  const site = fakeSite({
    [START_URL]: () => endlessHTML(HOME_URL, state),
    [ROBOTS_URL]: () => new Response("", { status: 404 }),
  });
  const started = Date.now();
  const result = await crawlSite({ fetchImpl: site.fetchImpl, startURL: START_URL, userAgent: USER_AGENT });
  assert.equal(result.pages.length, 1, "the truncated page is still a page");
  assert.ok(result.pages[0].text.length > 0);
  assert.equal(state.cancelled, true);
  assert.ok(state.pulled < 3_000_000, `read ${state.pulled} bytes of an endless body`);
  assert.ok(Date.now() - started < 5000);
});

Deno.test("crawlSite: a linked PDF that never ends is skipped after the cap, not downloaded", async () => {
  const state = { pulled: 0, cancelled: false };
  const pdfURL = "https://www.seas.upenn.edu/~cis2400/26fa/huge.pdf";
  const chunk = new Uint8Array(32 * 1024);
  const site = fakeSite({
    [START_URL]: () => htmlResponse(HOME_URL, `<title>Home</title><a href="/~cis2400/26fa/huge.pdf">notes</a>`),
    [ROBOTS_URL]: () => new Response("", { status: 404 }),
    [pdfURL]: () =>
      withURL(
        new Response(
          new ReadableStream<Uint8Array>({
            pull(controller) {
              state.pulled += chunk.byteLength;
              controller.enqueue(chunk);
            },
            cancel() {
              state.cancelled = true;
            },
          }),
          { status: 200, headers: { "content-type": "application/pdf" } },
        ),
        pdfURL,
      ),
  });
  const result = await crawlSite({ fetchImpl: site.fetchImpl, startURL: START_URL, userAgent: USER_AGENT });
  assert.equal(result.pages.some((page) => page.contentType === "application/pdf"), false);
  assert.equal(state.cancelled, true);
  assert.ok(state.pulled < 1_000_000, `read ${state.pulled} bytes of an endless PDF`);
});

Deno.test("crawlSite: a deadline in the past fetches the start page and nothing after it", async () => {
  const site = await buildFullSite();
  const result = await crawlSite({
    fetchImpl: site.fetchImpl,
    startURL: START_URL,
    userAgent: USER_AGENT,
    deadline: Date.now() - 1,
  });
  assert.deepEqual(result.pages.map((page) => page.url), [HOME_URL]);
  assert.equal(site.calls.includes(SCHEDULE_URL), false);
});

Deno.test("crawlSite: with no guard given the scheme, port and address rules still apply, with no DNS needed", async () => {
  // The default guard is the production one (any public host unless
  // LHF_DISCOVERY_HOSTS is set). These start URLs fail its shape rules before
  // any lookup, so the test never touches DNS.
  for (const startURL of ["http://www.seas.upenn.edu/~cis2400/", "https://127.0.0.1/", "https://169.254.169.254/latest/", "https://localhost/", "https://svc.internal/"]) {
    const site = fakeSite({ [startURL]: () => htmlResponse(startURL, "<title>x</title>") });
    const result = await crawlSiteWithGuard({ fetchImpl: site.fetchImpl, startURL, userAgent: USER_AGENT });
    assert.deepEqual(result.pages, [], startURL);
    assert.deepEqual(site.calls, [], `${startURL} must not be requested`);
  }
});

// A course site on its own domain is exactly what discovery exists to find, so
// with no host allow-list configured it is crawled like any other; the
// address and redirect rules still bind it.
const OPEN_GUARD: NetGuard = {
  allowedHostSuffixes: null,
  resolve: (hostname) =>
    hostname === "trap.example.com" ? Promise.resolve(["10.0.0.5"]) : Promise.resolve(["203.0.114.7"]),
  maxRedirects: 5,
  resolveTimeoutMs: 1000,
};

Deno.test("crawlSite, no allow-list: crawls a course site on its own domain", async () => {
  const start = "https://cis1912.org/";
  const syllabus = "https://cis1912.org/syllabus/";
  const site = fakeSite({
    [start]: () => htmlResponse(start, `<title>CIS 1912</title><a href="/syllabus/">syllabus</a>`),
    ["https://cis1912.org/robots.txt"]: () => new Response("", { status: 404 }),
    [syllabus]: () => htmlResponse(syllabus, "<title>Syllabus</title><body>grading</body>"),
  });
  const result = await crawlSiteWithGuard({ fetchImpl: site.fetchImpl, startURL: start, userAgent: USER_AGENT, guard: OPEN_GUARD });
  assert.deepEqual(result.pages.map((page) => page.title).sort(), ["CIS 1912", "Syllabus"]);
});

Deno.test("crawlSite, no allow-list: a public site that redirects to a name resolving inward is not followed", async () => {
  const start = "https://cis1912.org/";
  const site = fakeSite({
    [start]: () => redirectResponse("https://trap.example.com/admin"),
    "https://trap.example.com/admin": () => htmlResponse("https://trap.example.com/admin", "internal"),
  });
  const result = await crawlSiteWithGuard({ fetchImpl: site.fetchImpl, startURL: start, userAgent: USER_AGENT, guard: OPEN_GUARD });
  assert.deepEqual(result.pages, []);
  assert.deepEqual(site.calls, [start], "the inward-resolving target must never be requested");
});
