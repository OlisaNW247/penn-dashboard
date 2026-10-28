// discover-websites' crawl step end to end (`crawlBestSite`), with Supabase's
// PostgREST stubbed (see `support/edgeStub.ts`) and the course site a scripted
// fake. What this pins is what the step WRITES. A crawl that comes back with
// zero pages used to mean one thing to the code after it, "the site has
// nothing", and that code retires every website document the course already
// has (`markDocumentsGone`) and stamps `last_crawled_at`, so nothing retried
// for seven days. That is right for a site that answered and was empty, and
// wrong when the fetch rules refused the site (the name resolves somewhere
// private, a redirect left the allowed hosts, or the runtime cannot check
// addresses at all): a refusal says nothing about the site, so it must leave
// every row as it was and try again on the next call.
import { strict as assert } from "node:assert";
import { createClient } from "npm:@supabase/supabase-js@2.115.0";
import { crawlBestSite, type DiscoverContext } from "../supabase/functions/discover-websites/index.ts";
import { type NetGuard, ResolverUnavailableError } from "../supabase/functions/_shared/netguard.ts";
import { GRANTED, installStub } from "./support/edgeStub.ts";

const COURSE = "100";
const SITE = "https://cis1912.org/";
const LIVE_BEFORE = ["website:100:aaaa", "website:100:bbbb"];

function guard(overrides: Partial<NetGuard> = {}): NetGuard {
  return {
    allowedHostSuffixes: null,
    resolve: (hostname) => Promise.resolve(hostname === "trap.example.com" ? ["10.0.0.5"] : ["203.0.114.7"]),
    maxRedirects: 5,
    resolveTimeoutMs: 1000,
    ...overrides,
  };
}

function websiteRow(url = SITE, overrides: Record<string, unknown> = {}) {
  return {
    id: 7,
    course_id: COURSE,
    url,
    source: "canvas-link",
    confidence: 5,
    status: "verified",
    anchor_text: null,
    verified_term: "2026C",
    verified_at: new Date(Date.now() - 86_400_000).toISOString(),
    last_crawled_at: null,
    page_count: 0,
    gradescope_course_id: null,
    ed_course_id: null,
    created_at: "2026-09-01T00:00:00Z",
    ...overrides,
  };
}

interface Writes {
  /** document ids marked gone (PATCH course_documents). */
  gone: string[];
  /** bodies of PATCH course_websites (the crawl stats stamp). */
  stats: Array<Record<string, unknown>>;
  /** document ids upserted (POST course_documents). */
  upserted: string[];
}

function install(rows: unknown[]) {
  const writes: Writes = { gone: [], stats: [], upserted: [] };
  const stub = installStub({
    reserve: () => GRANTED,
    openrouter: { kind: "fail", status: 500 },
    route: ({ method, url, body }) => {
      const table = url.pathname.replace("/rest/v1/", "");
      if (!url.pathname.startsWith("/rest/v1/")) return undefined;
      const json = (value: unknown) =>
        new Response(JSON.stringify(value), { status: 200, headers: { "content-type": "application/json" } });
      if (table === "course_websites" && method === "GET") return json(rows);
      if (table === "course_documents" && method === "GET") return json(LIVE_BEFORE.map((id) => ({ id })));
      if (table === "course_documents" && method === "PATCH") {
        const ids = /^in\.\((.*)\)$/.exec(url.searchParams.get("id") ?? "")?.[1] ?? "";
        writes.gone.push(...ids.split(",").map((id) => id.replace(/"/g, "")).filter(Boolean));
        return new Response(null, { status: 204 });
      }
      if (table === "course_websites" && method === "PATCH") {
        writes.stats.push(JSON.parse(body));
        return new Response(null, { status: 204 });
      }
      if (table === "course_documents" && method === "POST") {
        const docs = JSON.parse(body) as Array<{ id: string }>;
        writes.upserted.push(...docs.map((doc) => doc.id));
        return new Response(null, { status: 201 });
      }
      return undefined;
    },
  });
  return { writes, stub };
}

function html(url: string, body: string): Response {
  const response = new Response(body, { status: 200, headers: { "content-type": "text/html" } });
  Object.defineProperty(response, "url", { value: url, configurable: true });
  return response;
}

function fakeSite(handlers: Record<string, () => Response>) {
  const calls: string[] = [];
  const fetchImpl = (async (input: RequestInfo | URL) => {
    const url = String(input);
    calls.push(url);
    const handler = handlers[url];
    return handler ? handler() : new Response("not found", { status: 404 });
  }) as typeof fetch;
  return { fetchImpl, calls };
}

function context(fetchImpl: typeof fetch, g: NetGuard): DiscoverContext {
  return {
    serviceClient: createClient("http://supabase.test", "service-key", { auth: { persistSession: false } }),
    fetchImpl,
    courseInfoByID: new Map(),
    catalogRowByCode: new Map(),
    deadline: Date.now() + 60_000,
    getDirectoryEntries: () => Promise.resolve([]),
    guard: g,
  };
}

const NOW = new Date();

Deno.test("crawlBestSite: a site that answered with real pages is crawled, stale documents retired, and the crawl stamped", async () => {
  const { writes, stub } = install([websiteRow()]);
  try {
    const site = fakeSite({
      [SITE]: () => html(SITE, `<title>CIS 1912</title><a href="/syllabus/">syllabus</a>`),
      "https://cis1912.org/robots.txt": () => new Response("", { status: 404 }),
      "https://cis1912.org/syllabus/": () => html("https://cis1912.org/syllabus/", "<title>Syllabus</title><body>grading</body>"),
    });
    const crawled = await crawlBestSite(context(site.fetchImpl, guard()), COURSE, NOW);
    assert.equal(crawled, true);
    assert.equal(writes.upserted.length, 2);
    assert.deepEqual(writes.gone.sort(), LIVE_BEFORE, "documents the crawl did not see again are retired");
    assert.equal(writes.stats.length, 1);
    assert.equal(writes.stats[0].page_count, 2);
    assert.ok(typeof writes.stats[0].last_crawled_at === "string");
  } finally {
    stub.restore();
  }
});

Deno.test("crawlBestSite: a runtime that cannot check addresses skips the site: nothing retired, nothing stamped, nothing fetched", async () => {
  const { writes, stub } = install([websiteRow()]);
  try {
    const site = fakeSite({ [SITE]: () => html(SITE, "<title>x</title>") });
    const noDNS = guard({ resolve: () => Promise.reject(new ResolverUnavailableError("no dns")) });
    const crawled = await crawlBestSite(context(site.fetchImpl, noDNS), COURSE, NOW);
    assert.equal(crawled, false, "a skipped crawl is not reported as crawled");
    assert.deepEqual(writes, { gone: [], stats: [], upserted: [] });
    assert.deepEqual(site.calls, []);
  } finally {
    stub.restore();
  }
});

Deno.test("crawlBestSite: a start URL whose name resolves to a private address is skipped, nothing written", async () => {
  const { writes, stub } = install([websiteRow("https://trap.example.com/course/")]);
  try {
    const site = fakeSite({ "https://trap.example.com/course/": () => html("https://trap.example.com/course/", "internal") });
    const crawled = await crawlBestSite(context(site.fetchImpl, guard()), COURSE, NOW);
    assert.equal(crawled, false);
    assert.deepEqual(writes, { gone: [], stats: [], upserted: [] });
    assert.deepEqual(site.calls, []);
  } finally {
    stub.restore();
  }
});

Deno.test("crawlBestSite: a start URL that redirects somewhere the guard refuses is skipped, nothing written", async () => {
  const { writes, stub } = install([websiteRow()]);
  try {
    const site = fakeSite({
      [SITE]: () => new Response(null, { status: 302, headers: { location: "https://trap.example.com/admin" } }),
      "https://trap.example.com/admin": () => html("https://trap.example.com/admin", "internal"),
    });
    const crawled = await crawlBestSite(context(site.fetchImpl, guard()), COURSE, NOW);
    assert.equal(crawled, false);
    assert.deepEqual(writes, { gone: [], stats: [], upserted: [] }, "a refused redirect is not an empty site");
    assert.deepEqual(site.calls, [SITE], "the refused hop must never be requested");
  } finally {
    stub.restore();
  }
});

Deno.test("crawlBestSite: after a refusal the next call crawls normally, because nothing was stamped", async () => {
  const { writes, stub } = install([websiteRow()]);
  try {
    const site = fakeSite({
      [SITE]: () => html(SITE, "<title>CIS 1912</title><body>hello</body>"),
      "https://cis1912.org/robots.txt": () => new Response("", { status: 404 }),
    });
    const noDNS = guard({ resolve: () => Promise.reject(new ResolverUnavailableError("no dns")) });
    assert.equal(await crawlBestSite(context(site.fetchImpl, noDNS), COURSE, NOW), false);
    assert.equal(writes.stats.length, 0);

    // The row is still `last_crawled_at: null`, so it is still eligible.
    assert.equal(await crawlBestSite(context(site.fetchImpl, guard()), COURSE, NOW), true);
    assert.equal(writes.stats.length, 1);
    assert.equal(writes.stats[0].page_count, 1);
  } finally {
    stub.restore();
  }
});

Deno.test("crawlBestSite: a site that really is gone (404) still retires its documents and is stamped, as before", async () => {
  const { writes, stub } = install([websiteRow()]);
  try {
    const site = fakeSite({}); // everything 404s
    const crawled = await crawlBestSite(context(site.fetchImpl, guard()), COURSE, NOW);
    assert.equal(crawled, true);
    assert.deepEqual(writes.gone.sort(), LIVE_BEFORE);
    assert.equal(writes.stats.length, 1);
    assert.equal(writes.stats[0].page_count, 0);
  } finally {
    stub.restore();
  }
});

Deno.test("crawlBestSite: with an allow-list set, a site off it is not picked and nothing is written", async () => {
  const { writes, stub } = install([websiteRow("https://other-site.example.org/")]);
  try {
    const site = fakeSite({ "https://other-site.example.org/": () => html("https://other-site.example.org/", "x") });
    const crawled = await crawlBestSite(context(site.fetchImpl, guard({ allowedHostSuffixes: ["upenn.edu"] })), COURSE, NOW);
    assert.equal(crawled, false);
    assert.deepEqual(writes, { gone: [], stats: [], upserted: [] });
    assert.deepEqual(site.calls, []);
  } finally {
    stub.restore();
  }
});

Deno.test("crawlBestSite: a site stored as an http:// link is crawled over https, not skipped", async () => {
  const { writes, stub } = install([websiteRow("http://cis1912.org/")]);
  try {
    const site = fakeSite({
      [SITE]: () => html(SITE, "<title>CIS 1912</title><body>hello</body>"),
      "https://cis1912.org/robots.txt": () => new Response("", { status: 404 }),
    });
    const crawled = await crawlBestSite(context(site.fetchImpl, guard()), COURSE, NOW);
    assert.equal(crawled, true);
    assert.ok(site.calls.length > 0 && site.calls.every((call) => call.startsWith("https://")), site.calls.join(", "));
    assert.equal(writes.stats.length, 1);
    assert.equal(writes.stats[0].page_count, 1);
  } finally {
    stub.restore();
  }
});
