// The `sync` edge function: the manifest exchange and upload steps from
// PROTOCOL.md's "`sync` -- manifest exchange, then upload" section. This
// file is deliberately thin -- request parsing and response shaping only
// -- with every rule that has a "why" behind it (validation, batching,
// the enrollment check, profile staleness) living in `_shared/manifest.ts`
// (pure logic, unit tested without a database) or `_shared/db.ts` (the
// database wrappers), so this file reads as the sequence of steps the
// protocol document already describes.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { corsHeaders, errorResponse, HttpError, json, readJSON } from "../_shared/http.ts";
import { requireUser } from "../_shared/auth.ts";
import { catalogCode, catalogIsStale, fetchCatalogCourse } from "../_shared/catalog.ts";
import {
  markDocumentsGone,
  documentRowToWire,
  selectCatalogCoursesByCodes,
  selectCoursesByIDs,
  selectEnrolledCourseIDs,
  selectLiveDocumentIDsForCourse,
  selectLiveDocumentsForCourses,
  setCourseCatalogCode,
  setLastFullSyncNow,
  setProfileStale,
  upsertCatalogCourse,
  upsertCourses,
  upsertDocuments,
  upsertEnrollments,
} from "../_shared/db.ts";
import {
  diffManifest,
  freshCourses,
  goneIDs,
  profileStaleCourses,
  validateCourse,
  validateDocument,
  validateDocumentStub,
  validateFullySyncedCourse,
  type CourseDocumentWire,
  type CourseSummaryWire,
  type DocumentKind,
  type DocumentStub,
} from "../_shared/manifest.ts";

// Guards against a pathological or malicious request forcing the function
// to do unbounded work in one call; the client-side chunking PROTOCOL.md
// describes (200 documents per upload call) means a well-behaved client
// never approaches these anyway.
const MAX_MANIFEST_COURSES = 60;
const MAX_UPLOAD_DOCUMENTS = 200;

// A manifest call's catalog refresh is bounded on two axes at once: at most
// this many Penn Labs fetches per call (a student rarely has more than a
// handful of *distinct* registrar courses linked across all their Canvas
// sites in one manifest, but nothing stops a pathological one from listing
// 60), and each fetch itself capped at this timeout. Run concurrently
// (`Promise.allSettled`, not a loop of `await`s), the two together bound
// the total added latency to roughly the timeout, not the timeout times
// the course count -- the "~3 s total" ceiling the brief for this feature
// sets on top of the manifest response the client is waiting on.
const MAX_CATALOG_FETCHES_PER_MANIFEST = 8;
const CATALOG_FETCH_TIMEOUT_MS = 2500;

interface ManifestResult {
  coursesFresh: string[];
  serverManifest: DocumentStub[];
  download: CourseDocumentWire[];
}

interface UploadResult {
  accepted: number;
  profileStale: string[];
}

/**
 * Links every course in this manifest call whose Canvas code resolves to a
 * Penn Labs course code, and fetches/upserts a fresh `catalog_courses` row
 * for whichever of those (capped, see `MAX_CATALOG_FETCHES_PER_MANIFEST`)
 * either has none yet or is `catalogIsStale`.
 *
 * This piggybacks on the manifest step rather than running as its own
 * cron for two reasons that both come down to "a cron would just be
 * redoing work this call already does for free": (1) only courses someone
 * is actually enrolled in are worth a Penn Labs request for, and this
 * function already has exactly that list -- the courses in the manifest
 * the caller is currently syncing -- with no separate query needed to
 * rediscover it; (2) every enrolled course reaches this code path at
 * least once an hour regardless (a student's app calls `sync` on its own
 * refresh loop, hourly at minimum per PROTOCOL.md's staleness story), so
 * catalog data can never go stale for longer than a routine cron would
 * tolerate anyway -- there is no gap a cron would close that this doesn't
 * already close on its own.
 *
 * Failures (a 404, a timeout, a transport error -- `fetchCatalogCourse`
 * never throws, it returns `undefined`) are silent to the manifest
 * response's caller and only ever logged as a count: a missing or stale
 * catalog row degrades `ask`'s COURSE STRUCTURE block to simply not
 * mentioning that course's components, not a broken sync.
 */
async function refreshCatalog(serviceClient: SupabaseClient, courses: CourseSummaryWire[]): Promise<void> {
  const catalogCodeByCourseID = new Map<string, string>();
  for (const course of courses) {
    const code = catalogCode(course.code);
    if (code) catalogCodeByCourseID.set(course.courseID, code);
  }
  if (catalogCodeByCourseID.size === 0) return;

  // Linking a course to its catalog code is a single-column write with no
  // network dependency, so it happens for every resolved course this run,
  // independent of which (capped) subset below actually gets a fresh Penn
  // Labs fetch this time.
  await Promise.allSettled(
    [...catalogCodeByCourseID.entries()].map(([courseID, code]) =>
      setCourseCatalogCode(serviceClient, courseID, code)
    ),
  );

  const uniqueCodes = [...new Set(catalogCodeByCourseID.values())];
  const existingByCode = await selectCatalogCoursesByCodes(serviceClient, uniqueCodes);
  const now = new Date();
  const codesToFetch = uniqueCodes
    .filter((code) => {
      const existing = existingByCode.get(code);
      return existing === undefined || catalogIsStale(existing.fetchedAt, now);
    })
    .slice(0, MAX_CATALOG_FETCHES_PER_MANIFEST);
  if (codesToFetch.length === 0) return;

  const fetchResults = await Promise.allSettled(
    codesToFetch.map((code) =>
      fetchCatalogCourse({ fetchImpl: fetch, catalogCode: code, timeoutMs: CATALOG_FETCH_TIMEOUT_MS })
    ),
  );

  const rowsToUpsert = fetchResults
    .filter((result): result is PromiseFulfilledResult<Awaited<ReturnType<typeof fetchCatalogCourse>>> =>
      result.status === "fulfilled" && result.value !== undefined
    )
    .map((result) => result.value!);
  await Promise.allSettled(rowsToUpsert.map((row) => upsertCatalogCourse(serviceClient, row)));

  const failedCount = codesToFetch.length - rowsToUpsert.length;
  if (failedCount > 0) {
    console.error(`sync: catalog refresh had ${failedCount}/${codesToFetch.length} failure(s)`);
  }
}

async function handleManifest(
  serviceClient: SupabaseClient,
  userId: string,
  body: Record<string, unknown>,
): Promise<ManifestResult> {
  const rawCourses = body["courses"];
  const rawStubs = body["documents"];
  if (!Array.isArray(rawCourses) || !Array.isArray(rawStubs)) {
    throw new HttpError(400, "bad_request", "manifest action requires \"courses\" and \"documents\" arrays");
  }
  if (rawCourses.length > MAX_MANIFEST_COURSES) {
    throw new HttpError(400, "bad_request", `at most ${MAX_MANIFEST_COURSES} courses per manifest call`);
  }

  const courses: CourseSummaryWire[] = rawCourses.map(validateCourse);
  const stubs: DocumentStub[] = rawStubs.map(validateDocumentStub);

  await upsertCourses(serviceClient, courses);
  await upsertEnrollments(serviceClient, userId, courses);
  await refreshCatalog(serviceClient, courses);

  const courseIDs = courses.map((course) => course.courseID);
  const liveRows = await selectLiveDocumentsForCourses(serviceClient, courseIDs);
  const liveWireDocs = liveRows.map(documentRowToWire);

  const { download, serverManifest } = diffManifest(stubs, liveWireDocs);

  const courseFreshnessRows = await selectCoursesByIDs(serviceClient, courseIDs);
  const coursesFresh = freshCourses(
    courseFreshnessRows.map((row) => ({ courseID: row.course_id, lastFullSyncAt: row.last_full_sync_at })),
    new Date(),
  );

  return { coursesFresh, serverManifest, download };
}

async function handleUpload(
  serviceClient: SupabaseClient,
  userId: string,
  body: Record<string, unknown>,
): Promise<UploadResult> {
  const rawDocuments = body["documents"];
  const rawFullySynced = body["fullySyncedCourses"];
  if (!Array.isArray(rawDocuments) || !Array.isArray(rawFullySynced)) {
    throw new HttpError(
      400,
      "bad_request",
      "upload action requires \"documents\" and \"fullySyncedCourses\" arrays",
    );
  }
  if (rawDocuments.length > MAX_UPLOAD_DOCUMENTS) {
    throw new HttpError(400, "bad_request", `at most ${MAX_UPLOAD_DOCUMENTS} documents per upload call`);
  }

  const documents = rawDocuments.map(validateDocument);
  const fullySyncedCourses = rawFullySynced.map(validateFullySyncedCourse);

  const affectedCourseIDs = new Set<string>();
  for (const doc of documents) affectedCourseIDs.add(doc.courseID);
  for (const course of fullySyncedCourses) affectedCourseIDs.add(course.courseID);

  // Enrollment is asserted by the client at the manifest step (see
  // PROTOCOL.md's "Limitations" section), but the upload step still
  // checks the caller has *some* enrollment row for every course it is
  // about to write material for or mark documents gone/stale in -- a
  // client that skipped the manifest call entirely, or that lists a
  // course id it was never enrolled in, is refused here rather than
  // silently accepted.
  const enrolledCourseIDs = await selectEnrolledCourseIDs(serviceClient, userId);
  for (const courseID of affectedCourseIDs) {
    if (!enrolledCourseIDs.has(courseID)) {
      throw new HttpError(403, "not_enrolled", `not enrolled in course ${courseID}`);
    }
  }

  // Snapshot the live (id -> contentHash) and (id -> kind) state for every
  // affected course *before* this call's writes land, so
  // `profileStaleCourses` below can tell what actually changed. Taken
  // before `upsertDocuments`/gone-marking on purpose -- diffing against a
  // state already mutated by this same request would compare a value
  // against itself for every document this call touches.
  const beforeRows = await selectLiveDocumentsForCourses(serviceClient, [...affectedCourseIDs]);
  const beforeHashByID = new Map<string, string>();
  const kindByID = new Map<string, DocumentKind>();
  for (const row of beforeRows) {
    beforeHashByID.set(row.id, row.content_hash);
    kindByID.set(row.id, row.kind);
  }
  for (const doc of documents) {
    kindByID.set(doc.id, doc.kind);
  }

  await upsertDocuments(serviceClient, documents);

  const nowFullySyncedCourseIDs: string[] = [];
  for (const course of fullySyncedCourses) {
    const liveIDsNow = await selectLiveDocumentIDsForCourse(serviceClient, course.courseID);
    const idsToMarkGone = goneIDs(liveIDsNow, course.documentIDs);
    await markDocumentsGone(serviceClient, idsToMarkGone);
    nowFullySyncedCourseIDs.push(course.courseID);
  }
  await setLastFullSyncNow(serviceClient, nowFullySyncedCourseIDs);

  const afterRows = await selectLiveDocumentsForCourses(serviceClient, [...affectedCourseIDs]);
  const afterHashByID = new Map<string, string>();
  for (const row of afterRows) {
    afterHashByID.set(row.id, row.content_hash);
    kindByID.set(row.id, row.kind);
  }

  const staleCourseIDs = profileStaleCourses(beforeHashByID, afterHashByID, (id) => kindByID.get(id));
  await setProfileStale(serviceClient, [...staleCourseIDs]);

  return { accepted: documents.length, profileStale: [...staleCourseIDs] };
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { status: 204, headers: corsHeaders });
  }

  try {
    if (req.method !== "POST") {
      throw new HttpError(405, "method_not_allowed", "sync only accepts POST");
    }

    const { userId, serviceClient } = await requireUser(req);
    const body = await readJSON<Record<string, unknown>>(req);
    const action = body["action"];

    if (action === "manifest") {
      const result = await handleManifest(serviceClient, userId, body);
      return json(200, result);
    }

    if (action === "upload") {
      const result = await handleUpload(serviceClient, userId, body);
      return json(200, result);
    }

    throw new HttpError(400, "bad_request", `unknown action "${String(action)}"`);
  } catch (err) {
    if (err instanceof HttpError) {
      // Deliberately never logs the request body: per the brief, document
      // text, titles and user ids beyond a bare count must never appear
      // in logs, and the simplest way to guarantee that is for the error
      // path to only ever touch the error's own code/message/status.
      console.error(`sync error: ${err.code} (${err.status})`);
      return errorResponse(err.code, err.message, err.status);
    }
    console.error("sync error: unexpected", err instanceof Error ? err.message : String(err));
    return errorResponse("internal_error", "unexpected server error", 500);
  }
});
