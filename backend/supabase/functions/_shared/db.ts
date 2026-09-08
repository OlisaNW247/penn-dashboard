// Thin, typed wrappers over a service-role Supabase client for the tables
// in supabase/migrations/20260907000000_init.sql. This is the one place in
// the backend that knows the snake_case column names and does the
// snake_case <-> camelCase mapping to/from the wire types in manifest.ts --
// index.ts should never see a raw row shape, and manifest.ts (pure,
// dependency-free, unit tested without a database) should never import
// this file.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import type {
  CourseDocumentWire,
  CourseSummaryWire,
  DocumentKind,
  DocumentStub,
} from "./manifest.ts";
import type { CatalogComponent, CatalogCourseRow } from "./catalog.ts";

export interface CourseRow {
  course_id: string;
  code: string;
  name: string;
  url: string | null;
  term: string | null;
  first_seen_at: string;
  last_full_sync_at: string | null;
  profile_stale: boolean;
}

export interface CourseDocumentRow {
  id: string;
  course_id: string;
  course_code: string;
  kind: DocumentKind;
  source_id: string;
  title: string;
  url: string | null;
  text: string;
  content_hash: string;
  updated_at: string | null;
  fetched_at: string;
  due_at: string | null;
  points_possible: number | null;
  first_seen_at: string;
  gone_at: string | null;
}

export function documentRowToWire(row: CourseDocumentRow): CourseDocumentWire {
  return {
    id: row.id,
    courseID: row.course_id,
    course: row.course_code,
    kind: row.kind,
    sourceID: row.source_id,
    title: row.title,
    url: row.url ?? undefined,
    text: row.text,
    updatedAt: row.updated_at ?? undefined,
    fetchedAt: row.fetched_at,
    contentHash: row.content_hash,
    dueAt: row.due_at ?? undefined,
    pointsPossible: row.points_possible ?? undefined,
  };
}

export function rowToStub(row: Pick<CourseDocumentRow, "id" | "content_hash">): DocumentStub {
  return { id: row.id, contentHash: row.content_hash };
}

function documentWireToInsertRow(doc: CourseDocumentWire): Omit<CourseDocumentRow, "first_seen_at"> {
  return {
    id: doc.id,
    course_id: doc.courseID,
    course_code: doc.course,
    kind: doc.kind,
    source_id: doc.sourceID,
    title: doc.title,
    url: doc.url ?? null,
    text: doc.text,
    content_hash: doc.contentHash,
    updated_at: doc.updatedAt ?? null,
    fetched_at: doc.fetchedAt,
    due_at: doc.dueAt ?? null,
    points_possible: doc.pointsPossible ?? null,
    // Re-uploading a document that had previously been marked gone (the
    // client re-discovered it in Canvas, or the server's aging was wrong)
    // revives it -- "upserts docs by id (clearing gone_at)" per
    // PROTOCOL.md's description of the upload step.
    gone_at: null,
  };
}

function chunk<T>(items: T[], size: number): T[][] {
  const chunks: T[][] = [];
  for (let i = 0; i < items.length; i += size) {
    chunks.push(items.slice(i, i + size));
  }
  return chunks;
}

// PROTOCOL.md: "the client chunks `documents` into batches of at most 200".
// Batching the write side too keeps a single upsert statement's payload
// bounded even if a future caller ever forwarded more than one client
// batch in a single call.
const UPSERT_BATCH_SIZE = 200;

/** Upserts course rows by `course_id`. Only the columns that can change on
 * a re-sync (code, name, url, term) are included in the payload -- the
 * upsert therefore leaves `first_seen_at`, `last_full_sync_at` and
 * `profile_stale` untouched on conflict, because those are set elsewhere
 * for reasons specific to the sync step in progress (see
 * `setLastFullSyncNow` / `setProfileStale` below) and must never be
 * clobbered back to their defaults just because a manifest call happened
 * to run afterward. */
export async function upsertCourses(client: SupabaseClient, courses: CourseSummaryWire[]): Promise<void> {
  if (courses.length === 0) return;
  const rows = courses.map((course) => ({
    course_id: course.courseID,
    code: course.code,
    name: course.name,
    url: course.url ?? null,
    term: course.term ?? null,
  }));
  const { error } = await client.from("courses").upsert(rows, { onConflict: "course_id" });
  if (error) throw error;
}

/** Upserts the caller's enrollment rows for exactly the courses listed in
 * this manifest call -- this *is* the enrollment proof the protocol's
 * "Limitations" section describes, so it deliberately never removes an
 * enrollment for a course the caller stops listing; a course a student
 * temporarily doesn't have loaded is not evidence they dropped it.
 * `section_ids` is merged (union), not replaced, because the same course
 * can be synced from multiple devices or after a mid-semester section
 * change and neither device knows the other's section list. */
export async function upsertEnrollments(
  client: SupabaseClient,
  userId: string,
  courses: CourseSummaryWire[],
): Promise<void> {
  if (courses.length === 0) return;
  const courseIDs = courses.map((course) => course.courseID);

  const { data: existingRows, error: selectError } = await client
    .from("enrollments")
    .select("course_id, section_ids")
    .eq("user_id", userId)
    .in("course_id", courseIDs);
  if (selectError) throw selectError;

  const existingSectionsByCourse = new Map<string, string[]>();
  for (const row of (existingRows ?? []) as Array<{ course_id: string; section_ids: string[] }>) {
    existingSectionsByCourse.set(row.course_id, row.section_ids ?? []);
  }

  const nowISO = new Date().toISOString();
  const rows = courses.map((course) => {
    const merged = new Set<string>(existingSectionsByCourse.get(course.courseID) ?? []);
    for (const sectionID of course.sectionIDs ?? []) merged.add(sectionID);
    return {
      user_id: userId,
      course_id: course.courseID,
      section_ids: [...merged],
      last_seen_at: nowISO,
    };
  });

  const { error } = await client.from("enrollments").upsert(rows, { onConflict: "user_id,course_id" });
  if (error) throw error;
}

/** Full live-document rows for a set of course ids -- used to build the
 * manifest's `download` list (needs complete `CourseDocumentWire` bodies)
 * and, filtered by the caller to profile-relevant kinds, the "before"
 * state for `profileStaleCourses`. */
export async function selectLiveDocumentsForCourses(
  client: SupabaseClient,
  courseIDs: string[],
): Promise<CourseDocumentRow[]> {
  if (courseIDs.length === 0) return [];
  const { data, error } = await client
    .from("course_documents")
    .select(
      "id, course_id, course_code, kind, source_id, title, url, text, content_hash, updated_at, fetched_at, due_at, points_possible, first_seen_at, gone_at",
    )
    .in("course_id", courseIDs)
    .is("gone_at", null);
  if (error) throw error;
  return (data ?? []) as CourseDocumentRow[];
}

/** Just the live ids for one course -- all `goneIDs` needs, and cheap
 * enough to call once per fully-synced course in the upload step without
 * pulling every document's full text along for the ride. */
export async function selectLiveDocumentIDsForCourse(client: SupabaseClient, courseID: string): Promise<string[]> {
  const { data, error } = await client
    .from("course_documents")
    .select("id")
    .eq("course_id", courseID)
    .is("gone_at", null);
  if (error) throw error;
  return (data ?? []).map((row) => (row as { id: string }).id);
}

/** Upserts documents by id in batches of `UPSERT_BATCH_SIZE`. Assumes the
 * caller (sync/index.ts) has already run every document through
 * `validateDocument`, so this layer does no further shape checking -- its
 * only job is the wire-to-row mapping and staying under Postgres's
 * practical statement size. */
export async function upsertDocuments(client: SupabaseClient, documents: CourseDocumentWire[]): Promise<void> {
  for (const batch of chunk(documents, UPSERT_BATCH_SIZE)) {
    const rows = batch.map(documentWireToInsertRow);
    const { error } = await client.from("course_documents").upsert(rows, { onConflict: "id" });
    if (error) throw error;
  }
}

/** Sets `gone_at = now()` on exactly the given live document ids. Never
 * deletes a row -- see the migration's comment on `course_documents` for
 * why gone documents are kept rather than dropped. */
export async function markDocumentsGone(client: SupabaseClient, ids: string[]): Promise<void> {
  if (ids.length === 0) return;
  const nowISO = new Date().toISOString();
  const { error } = await client
    .from("course_documents")
    .update({ gone_at: nowISO })
    .in("id", ids)
    .is("gone_at", null);
  if (error) throw error;
}

export async function setLastFullSyncNow(client: SupabaseClient, courseIDs: string[]): Promise<void> {
  if (courseIDs.length === 0) return;
  const nowISO = new Date().toISOString();
  const { error } = await client.from("courses").update({ last_full_sync_at: nowISO }).in("course_id", courseIDs);
  if (error) throw error;
}

export async function setProfileStale(client: SupabaseClient, courseIDs: string[]): Promise<void> {
  if (courseIDs.length === 0) return;
  const { error } = await client.from("courses").update({ profile_stale: true }).in("course_id", courseIDs);
  if (error) throw error;
}

/** Courses (subset needed for freshness/manifest bookkeeping) the caller
 * is enrolled in, restricted to the given course ids -- used by sync's
 * manifest step to look up `last_full_sync_at` for `freshCourses` without
 * pulling every column `courses` has. */
export async function selectCoursesByIDs(
  client: SupabaseClient,
  courseIDs: string[],
): Promise<Array<Pick<CourseRow, "course_id" | "last_full_sync_at">>> {
  if (courseIDs.length === 0) return [];
  const { data, error } = await client
    .from("courses")
    .select("course_id, last_full_sync_at")
    .in("course_id", courseIDs);
  if (error) throw error;
  return (data ?? []) as Array<Pick<CourseRow, "course_id" | "last_full_sync_at">>;
}

/** The set of course ids the caller currently holds an enrollment row for
 * -- used by sync's upload step to enforce "the upload call verifies the
 * caller is enrolled in every course it uploads for" from the delegation
 * brief / protocol limitations section, so a tampered client can't upload
 * (as opposed to merely list-in-a-manifest, which is the accepted
 * enrollment-proof gap) documents into a course it never claimed. */
export async function selectEnrolledCourseIDs(client: SupabaseClient, userId: string): Promise<Set<string>> {
  const { data, error } = await client.from("enrollments").select("course_id").eq("user_id", userId);
  if (error) throw error;
  return new Set((data ?? []).map((row) => (row as { course_id: string }).course_id));
}

// ---------------------------------------------------------------------
// Course catalog (supabase/migrations/20260907120000_catalog.sql). See
// _shared/catalog.ts for the pure fetch/parse/render logic this section
// wraps in the snake_case <-> camelCase mapping the rest of this file
// already does for `course_documents`.
// ---------------------------------------------------------------------

export interface CatalogCourseDBRow {
  catalog_code: string;
  semester: string;
  title: string;
  description: string;
  credits: number | null;
  prerequisites: string;
  crosslistings: string[];
  grade_modes: string[];
  attributes: unknown[];
  components: CatalogComponent[];
  source: string;
  fetched_at: string;
}

function catalogRowToDBRow(row: CatalogCourseRow): CatalogCourseDBRow {
  return {
    catalog_code: row.catalogCode,
    semester: row.semester,
    title: row.title,
    description: row.description,
    credits: row.credits,
    prerequisites: row.prerequisites,
    crosslistings: row.crosslistings,
    grade_modes: row.gradeModes,
    attributes: row.attributes,
    components: row.components,
    source: row.source,
    fetched_at: row.fetchedAt,
  };
}

function dbRowToCatalogRow(row: CatalogCourseDBRow): CatalogCourseRow {
  return {
    catalogCode: row.catalog_code,
    semester: row.semester,
    title: row.title,
    description: row.description,
    credits: row.credits,
    prerequisites: row.prerequisites,
    crosslistings: row.crosslistings,
    gradeModes: row.grade_modes,
    attributes: row.attributes,
    components: row.components,
    source: row.source,
    fetchedAt: row.fetched_at,
  };
}

/** The `catalog_courses` rows sync already has for a set of catalog codes,
 *  keyed by code -- used to decide which of a manifest call's courses need
 *  a fresh Penn Labs fetch (missing entirely, or `catalogIsStale`) versus
 *  which can be left alone this run. */
export async function selectCatalogCoursesByCodes(
  client: SupabaseClient,
  catalogCodes: string[],
): Promise<Map<string, CatalogCourseRow>> {
  if (catalogCodes.length === 0) return new Map();
  const { data, error } = await client
    .from("catalog_courses")
    .select(
      "catalog_code, semester, title, description, credits, prerequisites, crosslistings, grade_modes, attributes, components, source, fetched_at",
    )
    .in("catalog_code", catalogCodes);
  if (error) throw error;
  const byCode = new Map<string, CatalogCourseRow>();
  for (const row of (data ?? []) as CatalogCourseDBRow[]) {
    byCode.set(row.catalog_code, dbRowToCatalogRow(row));
  }
  return byCode;
}

/** Sets `courses.catalog_code` for a course whose Canvas code
 *  `catalogCode()` (see `_shared/catalog.ts`) resolved successfully.
 *  Separate from `upsertCourses` above (which only ever writes the columns
 *  a manifest call itself carries) because this is derived data computed
 *  by the sync function, not part of the client's `CourseSummaryWire`. */
export async function setCourseCatalogCode(
  client: SupabaseClient,
  courseID: string,
  catalogCode: string,
): Promise<void> {
  const { error } = await client.from("courses").update({ catalog_code: catalogCode }).eq("course_id", courseID);
  if (error) throw error;
}

/** Upserts one freshly-fetched Penn Labs course by `catalog_code`. Called
 *  once per successful `fetchCatalogCourse` result in sync's catalog
 *  refresh step -- there is no batching helper here the way
 *  `upsertDocuments` batches, because the per-call cap on catalog fetches
 *  (see sync/index.ts) already keeps this to a handful of single-row
 *  upserts per manifest call. */
export async function upsertCatalogCourse(client: SupabaseClient, row: CatalogCourseRow): Promise<void> {
  const { error } = await client
    .from("catalog_courses")
    .upsert(catalogRowToDBRow(row), { onConflict: "catalog_code" });
  if (error) throw error;
}

/**
 * Every `catalog_courses` row reachable from `courseIDs` through
 * `courses.catalog_code` -- the join `ask/index.ts` needs to build the
 * COURSE STRUCTURE block for the courses the caller is asking about. Two
 * queries rather than a single joined one for the same reason
 * `loadCourseProfiles` in ask/index.ts is two queries: `serviceClient` runs
 * as `service_role` and bypasses RLS, so there is no policy doing the
 * enrollment-scoping here -- but the caller is responsible for restricting
 * `courseIDs` to courses it already checked the user is enrolled in, and
 * this function trusts that, exactly as `loadCourseProfiles` trusts its own
 * `courseIDs` after doing that check.
 */
export async function selectCatalogCoursesForCourseIDs(
  client: SupabaseClient,
  courseIDs: string[],
): Promise<CatalogCourseRow[]> {
  if (courseIDs.length === 0) return [];

  const { data: courseRows, error: courseError } = await client
    .from("courses")
    .select("catalog_code")
    .in("course_id", courseIDs)
    .not("catalog_code", "is", null);
  if (courseError) throw courseError;

  const catalogCodes = [
    ...new Set((courseRows ?? []).map((row) => (row as { catalog_code: string }).catalog_code)),
  ];
  if (catalogCodes.length === 0) return [];

  const byCode = await selectCatalogCoursesByCodes(client, catalogCodes);
  return [...byCode.values()];
}

/** Deletes the caller's private rows ahead of deleting the auth user
 * itself. `courses`/`course_documents`/`course_profiles` are untouched --
 * per PROTOCOL.md, shared course material is not the user's data. */
export async function deleteUserData(client: SupabaseClient, userId: string): Promise<void> {
  const { error: enrollmentsError } = await client.from("enrollments").delete().eq("user_id", userId);
  if (enrollmentsError) throw enrollmentsError;

  const { error: askUsageError } = await client.from("ask_usage").delete().eq("user_id", userId);
  if (askUsageError) throw askUsageError;
}
