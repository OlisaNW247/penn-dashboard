// The `discover-websites` edge function: finds, verifies and crawls a
// course's own website, per PROTOCOL.md's course-website section. Like
// `sync/index.ts`, this file is deliberately thin -- request parsing,
// per-course orchestration, and response shaping only. Every rule with a
// "why" behind it lives in `_shared/websites.ts` (candidate scoring, CIS
// directory parsing, term/code verification, all pure and unit tested) or
// `_shared/crawl.ts` (the BFS crawl itself, also pure logic over an
// injected `fetchImpl`); this file's only job is fetching the rows those
// modules need, calling them in the right order, and writing the results
// back through `_shared/db.ts`.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { corsHeaders, errorResponse, HttpError, json, readJSON } from "../_shared/http.ts";
import { requireUser } from "../_shared/auth.ts";
import type { CatalogCourseRow } from "../_shared/catalog.ts";
import { crawlSite } from "../_shared/crawl.ts";
import {
  conventionURLs,
  lastPathSegment,
  olderThan,
  parseCisDirectory,
  SEVEN_DAYS_MS,
  ONE_DAY_MS,
  sideIDs,
  verifyPage,
  websiteContentHash,
  websiteDocumentID,
  type DirectoryEntry,
} from "../_shared/websites.ts";
import {
  goneIDs,
  type CourseDocumentWire,
} from "../_shared/manifest.ts";
import {
  markDocumentsGone,
  selectCatalogCoursesByCodes,
  selectCourseWebsites,
  selectCoursesForDiscovery,
  selectDirectoryCache,
  selectEnrolledCourseIDs,
  selectLiveWebsiteDocumentIDsForCourse,
  setCourseWebsiteCrawlStats,
  setCourseWebsiteRejected,
  setCourseWebsiteVerified,
  setProfileStale,
  upsertCourseWebsiteCandidates,
  upsertDirectoryCache,
  upsertDocuments,
  type CourseWebsiteRow,
  type DiscoveryCourseInfo,
  type NewCourseWebsiteCandidate,
} from "../_shared/db.ts";

const MAX_COURSE_IDS_PER_CALL = 3;

// The whole handler's wall-clock budget, per the brief -- discovery piggy-
// backs on the client's normal refresh flow (see PROTOCOL.md's
// `websitesPending`), so it has to stay well inside a mobile request
// timeout even in the worst case of three courses each needing a fresh
// verify-and-crawl pass. Checked between courses (and once more before the
// most expensive step, the crawl) rather than wrapping the whole handler
// in a single `AbortController`, so a course already in flight finishes
// cleanly instead of being cut off mid-write.
const DISCOVERY_BUDGET_MS = 45_000;

const VERIFY_TIMEOUT_MS = 8_000;
const CRAWL_TIMEOUT_MS = 8_000;
const CRAWL_MAX_PAGES = 40;
const CRAWL_MAX_DEPTH = 2;

const USER_AGENT = "LowHangingFruit/1 (course-website discovery; contact in repo)";

// Confidence values for the three candidate sources this function itself
// produces (a `canvas-link` candidate's confidence instead comes from
// `sync/index.ts`'s `candidateFromLink` call). Relative ordering matters
// more than the exact numbers: the CIS Advising Handbook is
// department-curated and most likely correct, Penn Labs' own
// `syllabus_url` is registrar-adjacent but sometimes stale, and the
// guessed `~courseN/current/` convention is the weakest signal -- a
// pattern that merely tends to work, unverified until `verifyPage` says
// so. `verifyPage` succeeding is what actually matters for crawl
// selection in the end (a verified `convention` candidate outranks an
// unverified `cis-directory` one), so these only break ties among
// same-status rows.
const CIS_DIRECTORY_CONFIDENCE = 6;
const PENN_LABS_SYLLABUS_CONFIDENCE = 4;
const CONVENTION_CONFIDENCE = 2;

// Verifying successfully is worth more than any single discovery source's
// starting confidence -- a page that actually states this course's code
// and this term is strictly better evidence than "an unverified guess
// from a usually-reliable source".
const VERIFY_CONFIDENCE_BONUS = 5;

const CIS_DIRECTORY_URL = "https://advising.cis.upenn.edu/course-dir/";
const CIS_DIRECTORY_CACHE_KEY = "cis-directory";

// A crawled page whose title or URL matches this is exactly the kind of
// page `extract-profile` cares about (grading weights, late policy, exam
// dates, office hours) -- see PROTOCOL.md's `extract-profile` section.
// Mirrors the pattern `_shared/profile.ts`'s selection logic effectively
// implements via document *kind* for Canvas documents; a crawled page has
// no such kind distinction (every page is `website`), so this function
// substitutes a title/URL heuristic to decide when a crawl should also
// flip `profile_stale`.
const PROFILE_RELEVANT_PATTERN = /syllabus|polic|grading|logistics/i;

interface DiscoveredEntry {
  courseID: string;
  url: string;
  status: CourseWebsiteRow["status"];
}

interface DiscoverContext {
  serviceClient: SupabaseClient;
  fetchImpl: typeof fetch;
  courseInfoByID: Map<string, DiscoveryCourseInfo>;
  catalogRowByCode: Map<string, CatalogCourseRow>;
  deadline: number;
  getDirectoryEntries: () => Promise<DirectoryEntry[]>;
}

async function fetchWithTimeout(fetchImpl: typeof fetch, url: string, timeoutMs: number): Promise<Response> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    return await fetchImpl(url, {
      method: "GET",
      headers: { "User-Agent": USER_AGENT },
      redirect: "follow",
      signal: controller.signal,
    });
  } finally {
    clearTimeout(timer);
  }
}

/**
 * Loads the CIS Advising Handbook's course directory, fetching it at most
 * once per `ONE_DAY_MS` *total* -- across every student's discovery call,
 * not once per student -- via the `directory_cache` table (service-role
 * only; see the `20260907180000_websites.sql` migration). A fetch failure
 * with a cached (even if stale) body still returns something rather than
 * nothing: a slightly-out-of-date directory is far more useful than
 * treating a transient failure to reach `advising.cis.upenn.edu` as "the
 * directory has no entries at all" for every course in this call.
 */
async function loadDirectoryEntries(
  serviceClient: SupabaseClient,
  fetchImpl: typeof fetch,
  now: Date,
): Promise<DirectoryEntry[]> {
  const cached = await selectDirectoryCache(serviceClient, CIS_DIRECTORY_CACHE_KEY);
  if (cached && !olderThan(cached.fetchedAt, now, ONE_DAY_MS)) {
    return parseCisDirectory(cached.body);
  }

  try {
    const response = await fetchWithTimeout(fetchImpl, CIS_DIRECTORY_URL, VERIFY_TIMEOUT_MS);
    if (!response.ok) {
      return cached ? parseCisDirectory(cached.body) : [];
    }
    const body = await response.text();
    await upsertDirectoryCache(serviceClient, CIS_DIRECTORY_CACHE_KEY, body);
    return parseCisDirectory(body);
  } catch {
    return cached ? parseCisDirectory(cached.body) : [];
  }
}

/** Step (a): candidates this function itself can propose without any
 *  per-course state -- the CIS directory (filtered to this course's
 *  catalog code), the guessed CIS/CIT convention URLs, and Penn Labs'
 *  `syllabus_url` when present. A `canvas-link` candidate is never
 *  produced here; those come exclusively from `sync/index.ts`'s
 *  `candidateFromLink` on the client's reported links. Writes nothing
 *  itself -- returns the list for the caller to upsert alongside whatever
 *  already exists, so the merge-by-greatest-confidence logic lives in
 *  exactly one place (`upsertCourseWebsiteCandidates`). */
async function gatherNewCandidates(
  ctx: DiscoverContext,
  courseID: string,
  catalogCode: string,
): Promise<NewCourseWebsiteCandidate[]> {
  const candidates: NewCourseWebsiteCandidate[] = [];

  const directoryEntries = await ctx.getDirectoryEntries();
  for (const entry of directoryEntries) {
    if (entry.catalogCode === catalogCode) {
      candidates.push({ courseID, url: entry.url, source: "cis-directory", confidence: CIS_DIRECTORY_CONFIDENCE });
    }
  }

  for (const url of conventionURLs(catalogCode)) {
    candidates.push({ courseID, url, source: "convention", confidence: CONVENTION_CONFIDENCE });
  }

  const syllabusURL = ctx.catalogRowByCode.get(catalogCode)?.syllabusURL;
  if (syllabusURL) {
    candidates.push({
      courseID,
      url: syllabusURL,
      source: "penn-labs-syllabus",
      confidence: PENN_LABS_SYLLABUS_CONFIDENCE,
    });
  }

  return candidates;
}

/** Step (b): (re-)verifies every `candidate` row and every `verified` row
 *  whose `verified_at` is more than `SEVEN_DAYS_MS` old -- a verified
 *  site is re-checked periodically because the term it verified for does
 *  eventually end. `rejected` rows are deliberately skipped every time
 *  (see the migration's `status` column comment): a URL this function
 *  already fetched and found not to match is not re-fetched on every
 *  future call just because time passed. A row is also left untouched
 *  (not fetched at all) when this course has no resolved `catalogCode` or
 *  no known `semester` yet -- without both, `verifyPage` cannot
 *  distinguish "wrong" from "unknown", and a false `rejected` from missing
 *  catalog data would be worse than simply trying again once that data
 *  exists. */
async function verifyCandidates(
  ctx: DiscoverContext,
  courseID: string,
  catalogCode: string | undefined,
  semester: string | undefined,
  now: Date,
): Promise<DiscoveredEntry[]> {
  const rows = await selectCourseWebsites(ctx.serviceClient, [courseID]);
  const discovered: DiscoveredEntry[] = [];

  for (const row of rows) {
    if (Date.now() > ctx.deadline) {
      discovered.push({ courseID, url: row.url, status: row.status });
      continue;
    }

    const needsVerify = row.status === "candidate" ||
      (row.status === "verified" && olderThan(row.verifiedAt, now, SEVEN_DAYS_MS));
    if (!needsVerify || !catalogCode || !semester) {
      discovered.push({ courseID, url: row.url, status: row.status });
      continue;
    }

    let response: Response;
    try {
      response = await fetchWithTimeout(ctx.fetchImpl, row.url, VERIFY_TIMEOUT_MS);
    } catch {
      // Network failure/timeout: leave the row exactly as it was. Per the
      // brief, this is bundled with a 404 below -- neither is evidence
      // the URL is *wrong*, only that this attempt to check it failed.
      discovered.push({ courseID, url: row.url, status: row.status });
      continue;
    }
    if (!response.ok) {
      discovered.push({ courseID, url: row.url, status: row.status });
      continue;
    }

    const html = await response.text();
    const finalURL = response.url || row.url;
    const result = verifyPage({ html, finalURL, catalogCode, semester });

    if (result.ok) {
      await setCourseWebsiteVerified(ctx.serviceClient, row.id, {
        verifiedTerm: semester,
        confidence: row.confidence + VERIFY_CONFIDENCE_BONUS,
      });
      discovered.push({ courseID, url: row.url, status: "verified" });
    } else {
      await setCourseWebsiteRejected(ctx.serviceClient, row.id);
      discovered.push({ courseID, url: row.url, status: "rejected" });
    }
  }

  return discovered;
}

/** Step (c): crawls the highest-confidence verified site whose
 *  `last_crawled_at` is null or more than `SEVEN_DAYS_MS` old, and writes
 *  every page it finds as a `website`-kind `course_documents` row. Returns
 *  whether a crawl was actually attempted (used to build the response's
 *  `crawled` list) -- `true` even if the crawl itself came back with zero
 *  pages (a real attempt against a site that turned out to be
 *  unreachable this run is still "this course was crawled", not silently
 *  equivalent to never having tried). */
async function crawlBestSite(
  ctx: DiscoverContext,
  courseID: string,
  now: Date,
): Promise<boolean> {
  if (Date.now() > ctx.deadline) return false;

  const rows = await selectCourseWebsites(ctx.serviceClient, [courseID]);
  const eligible = rows
    .filter((row) => row.status === "verified")
    .filter((row) => row.lastCrawledAt === null || olderThan(row.lastCrawledAt, now, SEVEN_DAYS_MS))
    .sort((a, b) => b.confidence - a.confidence);

  const target = eligible[0];
  if (!target) return false;

  const crawlResult = await crawlSite({
    fetchImpl: ctx.fetchImpl,
    startURL: target.url,
    maxPages: CRAWL_MAX_PAGES,
    maxDepth: CRAWL_MAX_DEPTH,
    timeoutMs: CRAWL_TIMEOUT_MS,
    userAgent: USER_AGENT,
  });

  const liveBeforeIDs = await selectLiveWebsiteDocumentIDsForCourse(ctx.serviceClient, courseID);
  const courseCode = ctx.courseInfoByID.get(courseID)?.code ?? courseID;
  const nowISO = now.toISOString();

  const wireDocs: CourseDocumentWire[] = [];
  let profileStaleHit = false;

  for (const page of crawlResult.pages) {
    const id = await websiteDocumentID(courseID, page.url);
    // The id is "website:{courseID}:{hash}" -- see `websiteDocumentID`'s
    // doc comment; `sourceID` is that same hash, not re-derived
    // separately, so the id and the row it names can never disagree
    // about what hash they're built from.
    const sourceID = id.slice(id.lastIndexOf(":") + 1);
    let title = page.title.trim();
    if (title.length === 0) {
      try {
        title = lastPathSegment(new URL(page.url));
      } catch {
        title = page.url;
      }
    }
    const contentHash = await websiteContentHash(title, page.text);

    wireDocs.push({
      id,
      courseID,
      course: courseCode,
      kind: "website",
      sourceID,
      title,
      url: page.url,
      text: page.text,
      fetchedAt: nowISO,
      contentHash,
    });

    if (PROFILE_RELEVANT_PATTERN.test(title) || PROFILE_RELEVANT_PATTERN.test(page.url)) {
      profileStaleHit = true;
    }
  }

  if (wireDocs.length > 0) {
    await upsertDocuments(ctx.serviceClient, wireDocs);
  }
  // Any website document this course had before that this crawl didn't
  // re-see is gone -- the same `goneIDs` rule `sync`'s upload step applies
  // to a fully-synced Canvas course, reused here rather than
  // re-implemented (see `_shared/manifest.ts`).
  await markDocumentsGone(ctx.serviceClient, goneIDs(liveBeforeIDs, wireDocs.map((doc) => doc.id)));

  const ids = sideIDs(crawlResult.links);
  await setCourseWebsiteCrawlStats(ctx.serviceClient, target.id, {
    lastCrawledAt: nowISO,
    pageCount: wireDocs.length,
    gradescopeCourseID: ids.gradescopeCourseID,
    edCourseID: ids.edCourseID,
  });

  if (profileStaleHit) {
    await setProfileStale(ctx.serviceClient, [courseID]);
  }

  return true;
}

async function discoverForCourse(ctx: DiscoverContext, courseID: string): Promise<{
  discovered: DiscoveredEntry[];
  crawled: boolean;
}> {
  const now = new Date();
  const info = ctx.courseInfoByID.get(courseID);
  const catalogCode = info?.catalogCode ?? undefined;
  const semester = catalogCode ? ctx.catalogRowByCode.get(catalogCode)?.semester : undefined;

  if (catalogCode) {
    const newCandidates = await gatherNewCandidates(ctx, courseID, catalogCode);
    if (newCandidates.length > 0) {
      await upsertCourseWebsiteCandidates(ctx.serviceClient, newCandidates);
    }
  }

  const discovered = await verifyCandidates(ctx, courseID, catalogCode, semester, now);
  const crawled = await crawlBestSite(ctx, courseID, now);

  return { discovered, crawled };
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders });
  }

  try {
    if (req.method !== "POST") {
      throw new HttpError(405, "method_not_allowed", "discover-websites only accepts POST");
    }

    const { userId, serviceClient } = await requireUser(req);
    const body = await readJSON<Record<string, unknown>>(req);

    const rawCourseIDs = body["courseIDs"];
    if (!Array.isArray(rawCourseIDs) || !rawCourseIDs.every((id): id is string => typeof id === "string")) {
      throw new HttpError(400, "bad_request", "\"courseIDs\" must be an array of strings");
    }
    const courseIDs = [...new Set(rawCourseIDs)];
    if (courseIDs.length > MAX_COURSE_IDS_PER_CALL) {
      throw new HttpError(400, "bad_request", `at most ${MAX_COURSE_IDS_PER_CALL} courseIDs per call`);
    }
    if (courseIDs.length === 0) {
      return json(200, { discovered: [], crawled: [] });
    }

    // Enrollment is the caller's proof of access to a course's material
    // throughout this backend (see PROTOCOL.md's "Limitations" section);
    // discovery writes `course_websites` rows and crawled `website`
    // documents for a course, so it holds itself to the same gate `sync`'s
    // upload step does.
    const enrolledCourseIDs = await selectEnrolledCourseIDs(serviceClient, userId);
    for (const courseID of courseIDs) {
      if (!enrolledCourseIDs.has(courseID)) {
        throw new HttpError(403, "not_enrolled", `not enrolled in course ${courseID}`);
      }
    }

    const courseInfos = await selectCoursesForDiscovery(serviceClient, courseIDs);
    const courseInfoByID = new Map(courseInfos.map((info) => [info.courseID, info]));

    const catalogCodes = [
      ...new Set(courseInfos.map((info) => info.catalogCode).filter((code): code is string => code !== null)),
    ];
    const catalogRowByCode = await selectCatalogCoursesByCodes(serviceClient, catalogCodes);

    const deadline = Date.now() + DISCOVERY_BUDGET_MS;
    // The CIS directory fetch is shared across every course in this call
    // (a student can easily have two or three CIS courses in one batch)
    // rather than repeated per course -- lazily created on first use and
    // memoized via this closure, not module scope, so it never survives
    // past this one request.
    let directoryEntriesPromise: Promise<DirectoryEntry[]> | undefined;
    const getDirectoryEntries = (): Promise<DirectoryEntry[]> => {
      directoryEntriesPromise ??= loadDirectoryEntries(serviceClient, fetch, new Date());
      return directoryEntriesPromise;
    };

    const ctx: DiscoverContext = {
      serviceClient,
      fetchImpl: fetch,
      courseInfoByID,
      catalogRowByCode,
      deadline,
      getDirectoryEntries,
    };

    const discovered: DiscoveredEntry[] = [];
    const crawled: string[] = [];

    for (const courseID of courseIDs) {
      if (Date.now() > deadline) break;
      const result = await discoverForCourse(ctx, courseID);
      discovered.push(...result.discovered);
      if (result.crawled) crawled.push(courseID);
    }

    // Per the brief: log counts only, never a URL, title or document body
    // -- matching sync/index.ts's and delete-account/index.ts's logging
    // discipline.
    console.error(
      `discover-websites: courses=${courseIDs.length} discovered=${discovered.length} crawled=${crawled.length}`,
    );

    return json(200, { discovered, crawled });
  } catch (err) {
    if (err instanceof HttpError) {
      console.error(`discover-websites error: ${err.code} (${err.status})`);
      return errorResponse(err.code, err.message, err.status);
    }
    console.error("discover-websites error: unexpected", err instanceof Error ? err.message : String(err));
    return errorResponse("internal_error", "unexpected server error", 500);
  }
});
