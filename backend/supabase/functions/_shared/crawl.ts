// A small, same-host BFS crawler for a course's own website, backing
// `discover-websites/index.ts`. Everything network-shaped goes through an
// injected `fetchImpl`, never the global `fetch`, matching
// `_shared/catalog.ts`'s `fetchCatalogCourse` and `_shared/openrouter.ts`'s
// discipline for the same reason: this container's tests have no real
// network to reach a Penn course site with, so `crawl.test.ts` drives every
// branch (robots.txt, depth/page limits, off-site links, a PDF syllabus)
// against a scripted fake.
//
// What this file deliberately does *not* try to be: a general-purpose web
// crawler. It knows about exactly one shape of target -- a small, mostly
// static Penn course site -- and every limit here (40 pages, depth 2, an
// 8-second per-request timeout, a 200 KB cap on any one PDF) is sized for
// that, not for crawling an arbitrary site politely at scale.
import { extractText, getDocumentProxy } from "npm:unpdf@1";
import {
  extractLinks,
  htmlToText,
  isIgnoredWebsiteHost,
  lastPathSegment,
  normalizeWebsiteURL,
  pageTitle,
  type ExtractedLink,
} from "./websites.ts";

export interface CrawlOptions {
  /** Injected, never the global `fetch` -- see the module doc comment. */
  fetchImpl: typeof fetch;
  /** Where to start -- typically a `course_websites` row's verified URL.
   *  May itself redirect (`~cis2400/current/` -> `~cis2400/26fa/`); the
   *  crawl's same-site containment is computed from where this actually
   *  lands, not from this URL's own host/path. */
  startURL: string;
  maxPages?: number;
  maxDepth?: number;
  timeoutMs?: number;
  userAgent: string;
}

export interface CrawledPage {
  url: string;
  title: string;
  text: string;
  depth: number;
  contentType: string;
}

export interface CrawlResult {
  pages: CrawledPage[];
  /** Every outbound link discovered on every fetched HTML page, deduped by
   *  href -- including links this crawl never followed (off the root
   *  prefix, on an ignored host, or found only past `maxDepth`). Handed to
   *  `sideIDs` by `discover-websites` to recover a Gradescope/Ed course id
   *  even from a page the crawl only fetched, never revisited. */
  links: ExtractedLink[];
  /** Normalized URLs the crawl declined to fetch because `robots.txt`
   *  disallowed them for `User-agent: *` -- surfaced (rather than merely
   *  silently skipped) so a caller or a test can prove the crawler actually
   *  obeyed it, not just that a page happens to be absent from `pages`. */
  blockedByRobots: string[];
}

const DEFAULT_MAX_PAGES = 40;
const DEFAULT_MAX_DEPTH = 2;
const DEFAULT_TIMEOUT_MS = 8000;

// A PDF larger than this (a full textbook, a scanned packet) is not what
// this crawler exists to ingest -- a course's syllabus or a short handout
// PDF is comfortably under this, and capping the *fetch* (not just the
// text extracted from it) keeps a pathological linked PDF from spending
// this call's time budget on a multi-megabyte download.
const PDF_MAX_BYTES = 200_000;
// Matches `_shared/manifest.ts`'s `MAX_TEXT_LENGTH` posture toward a single
// document's text: bounded so one page can never dominate the input a
// later `ask` retrieval or `extract-profile` call has to work with.
const PDF_MAX_TEXT_CHARS = 60_000;

const EMPTY_RESULT: CrawlResult = { pages: [], links: [], blockedByRobots: [] };

async function fetchWithTimeout(
  fetchImpl: typeof fetch,
  url: string,
  timeoutMs: number,
  userAgent: string,
): Promise<Response> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetchImpl(url, {
      method: "GET",
      headers: { "User-Agent": userAgent },
      redirect: "follow",
      signal: controller.signal,
    });
  } finally {
    clearTimeout(timer);
  }
}

/**
 * The path prefix every crawled page must stay under, derived from where
 * the *start* page actually landed after redirects -- not from the URL
 * `crawlSite` was called with. For a Just-the-Docs site whose `current/`
 * redirects to a term-specific directory (`~cis2400/current/` ->
 * `~cis2400/26fa/`), this is `/~cis2400/26fa/`, so a page under that
 * directory is in-bounds and a sibling course's directory
 * (`/~cis1210/...`) never is, even though both live on the same host.
 */
function rootPrefixFromFinalURL(finalURL: URL): string {
  const path = finalURL.pathname;
  if (path.endsWith("/")) return path;
  const lastSlash = path.lastIndexOf("/");
  return lastSlash >= 0 ? path.slice(0, lastSlash + 1) : "/";
}

/**
 * The `Disallow` prefixes from a `robots.txt` body that apply to
 * `User-agent: *`. Deliberately the minimum slice of the robots.txt spec
 * this crawler's own behavior needs -- one group per `User-agent` line,
 * simple prefix matching, no `Allow` override, no wildcard/`$`-anchor
 * support -- the same "smallest slice that makes the real rule true"
 * discipline `test/local_auth_stub.sql`'s doc comment applies to standing
 * in for Supabase's `auth` schema. A course site's own robots.txt (see the
 * `robots.txt` fixture) is exactly this simple in practice; a more
 * elaborate one degrades to under-blocking rather than over-blocking,
 * which is the safer direction for a crawler that already caps itself on
 * page count and depth.
 */
function parseRobotsDisallow(body: string): string[] {
  const disallows: string[] = [];
  let inStarGroup = false;

  for (const rawLine of body.split(/\r?\n/)) {
    const line = rawLine.replace(/#.*/, "").trim();
    if (line.length === 0) continue;

    const colon = line.indexOf(":");
    if (colon < 0) continue;
    const key = line.slice(0, colon).trim().toLowerCase();
    const value = line.slice(colon + 1).trim();

    if (key === "user-agent") {
      inStarGroup = value === "*";
      continue;
    }
    if (key === "disallow" && inStarGroup && value.length > 0) {
      disallows.push(value);
    }
  }

  return disallows;
}

function isDisallowed(pathname: string, disallowPrefixes: readonly string[]): boolean {
  return disallowPrefixes.some((prefix) => pathname.startsWith(prefix));
}

async function fetchRobotsDisallow(
  fetchImpl: typeof fetch,
  siteOrigin: URL,
  timeoutMs: number,
  userAgent: string,
): Promise<string[]> {
  const robotsURL = `${siteOrigin.protocol}//${siteOrigin.host}/robots.txt`;
  try {
    const response = await fetchWithTimeout(fetchImpl, robotsURL, timeoutMs, userAgent);
    if (!response.ok) return [];
    return parseRobotsDisallow(await response.text());
  } catch {
    // No robots.txt, a network blip fetching it, or a timeout all mean the
    // same thing for this crawler's purposes: no stated restriction, so
    // crawl as normal rather than failing the whole call over a robots.txt
    // this site may simply not have.
    return [];
  }
}

/**
 * Reads a PDF response into a `CrawledPage`, or `undefined` if it's over
 * the size cap or `unpdf` can't parse it (a corrupt or unusually-encoded
 * PDF) -- either way, the caller simply doesn't get a page for this URL,
 * the same "skip, don't fail the whole crawl" posture every other
 * per-page failure in this file takes.
 */
async function pdfToPage(response: Response, url: URL, depth: number): Promise<CrawledPage | undefined> {
  const buffer = await response.arrayBuffer();
  if (buffer.byteLength === 0 || buffer.byteLength > PDF_MAX_BYTES) return undefined;

  try {
    const pdf = await getDocumentProxy(new Uint8Array(buffer));
    const { text } = await extractText(pdf, { mergePages: true });
    return {
      url: url.toString(),
      title: lastPathSegment(url),
      text: text.slice(0, PDF_MAX_TEXT_CHARS),
      depth,
      contentType: "application/pdf",
    };
  } catch {
    return undefined;
  }
}

function contentTypeOf(response: Response): string {
  return (response.headers.get("content-type") ?? "").split(";")[0].trim().toLowerCase();
}

interface QueueItem {
  url: string;
  depth: number;
}

/**
 * Crawls a course website starting from `startURL`, breadth-first, staying
 * on the host and path prefix the start URL redirects to (see
 * `rootPrefixFromFinalURL`), honoring `robots.txt`'s `Disallow` rules for
 * `User-agent: *`, and never following a link onto an `IGNORED_HOSTS`
 * host (Canvas, Gradescope, Zoom, ... -- see `_shared/websites.ts`). Stops
 * once `maxPages` pages have been collected or the queue is exhausted;
 * links found on a page at `maxDepth` are recorded in the returned
 * `links` list but not fetched.
 *
 * Never throws: a start-page fetch failure (network error, non-2xx
 * status) returns the empty result rather than propagating, matching
 * `fetchCatalogCourse`'s "the caller treats a failure as simply nothing to
 * do this round" posture -- `discover-websites` calls this once per
 * course per run, and one course's unreachable site must not fail the
 * whole batch.
 */
export async function crawlSite(options: CrawlOptions): Promise<CrawlResult> {
  const {
    fetchImpl,
    startURL,
    maxPages = DEFAULT_MAX_PAGES,
    maxDepth = DEFAULT_MAX_DEPTH,
    timeoutMs = DEFAULT_TIMEOUT_MS,
    userAgent,
  } = options;

  let startResponse: Response;
  try {
    startResponse = await fetchWithTimeout(fetchImpl, startURL, timeoutMs, userAgent);
  } catch {
    return EMPTY_RESULT;
  }
  if (!startResponse.ok) return EMPTY_RESULT;

  let finalURL: URL;
  try {
    finalURL = new URL(startResponse.url || startURL);
  } catch {
    return EMPTY_RESULT;
  }

  const rootHost = finalURL.hostname.toLowerCase();
  const rootPrefix = rootPrefixFromFinalURL(finalURL);
  const disallowPrefixes = await fetchRobotsDisallow(fetchImpl, finalURL, timeoutMs, userAgent);

  const pages: CrawledPage[] = [];
  const linksByHref = new Map<string, ExtractedLink>();
  const blockedByRobots = new Set<string>();
  const visited = new Set<string>();
  const queue: QueueItem[] = [];

  const isInBounds = (url: URL): boolean =>
    url.hostname.toLowerCase() === rootHost &&
    url.pathname.startsWith(rootPrefix) &&
    !isIgnoredWebsiteHost(url);

  async function processResponse(response: Response, url: URL, depth: number): Promise<void> {
    if (pages.length >= maxPages) return;
    const contentType = contentTypeOf(response);

    if (contentType === "application/pdf") {
      const page = await pdfToPage(response, url, depth);
      if (page) pages.push(page);
      return; // A PDF has no HTML links to follow.
    }

    // Some static file servers (a plain Apache directory for a course
    // site, in particular) omit Content-Type entirely; treating a blank
    // type as "try it as HTML" is more useful here than skipping a page
    // that's almost certainly HTML just because a header was missing.
    if (contentType.length > 0 && !contentType.startsWith("text/html")) return;

    const html = await response.text();
    if (pages.length >= maxPages) return;

    pages.push({
      url: url.toString(),
      title: pageTitle(html),
      text: htmlToText(html),
      depth,
      contentType: contentType.length > 0 ? contentType : "text/html",
    });

    const links = extractLinks(html, url.toString());
    for (const link of links) {
      if (!linksByHref.has(link.href)) linksByHref.set(link.href, link);
    }

    if (depth >= maxDepth) return;
    for (const link of links) {
      let linkURL: URL;
      try {
        linkURL = new URL(link.href);
      } catch {
        continue;
      }
      if (!isInBounds(linkURL)) continue;
      const key = normalizeWebsiteURL(linkURL);
      if (visited.has(key)) continue;
      queue.push({ url: linkURL.toString(), depth: depth + 1 });
    }
  }

  visited.add(normalizeWebsiteURL(finalURL));
  await processResponse(startResponse, finalURL, 0);

  while (queue.length > 0 && pages.length < maxPages) {
    const item = queue.shift()!;

    let url: URL;
    try {
      url = new URL(item.url);
    } catch {
      continue;
    }
    const key = normalizeWebsiteURL(url);
    if (visited.has(key)) continue;
    visited.add(key);

    if (!isInBounds(url)) continue;
    if (isDisallowed(url.pathname, disallowPrefixes)) {
      blockedByRobots.add(key);
      continue;
    }

    let response: Response;
    try {
      response = await fetchWithTimeout(fetchImpl, url.toString(), timeoutMs, userAgent);
    } catch {
      continue;
    }
    if (!response.ok) continue;

    await processResponse(response, url, item.depth);
  }

  return {
    pages,
    links: [...linksByHref.values()],
    blockedByRobots: [...blockedByRobots],
  };
}
