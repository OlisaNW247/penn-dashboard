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
import {
  markDocumentsGone,
  documentRowToWire,
  selectCoursesByIDs,
  selectEnrolledCourseIDs,
  selectLiveDocumentIDsForCourse,
  selectLiveDocumentsForCourses,
  setLastFullSyncNow,
  setProfileStale,
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

interface ManifestResult {
  coursesFresh: string[];
  serverManifest: DocumentStub[];
  download: CourseDocumentWire[];
}

interface UploadResult {
  accepted: number;
  profileStale: string[];
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
