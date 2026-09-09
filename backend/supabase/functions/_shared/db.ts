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
import {
  catalogEntryWire,
  catalogIsStale,
  type CatalogComponent,
  type CatalogCourseRow,
  type CatalogEntryWire,
} from "./catalog.ts";

export interface CourseRow {
  course_id: string;
  code: string;
  name: string;
  url: string | null;
  term: string | null;
  section: string | null;
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
 * a re-sync (code, name, url, term, section) are included in the payload --
 * the upsert therefore leaves `first_seen_at`, `last_full_sync_at` and
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
    section: course.section ?? null,
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
  syllabus_url: string | null;
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
    syllabus_url: row.syllabusURL ?? null,
  };
}

/**
 * Reads `catalog_courses.components` -- a jsonb column, so Postgres hands
 * it back as whatever shape was last written, not necessarily today's
 * `CatalogComponent` -- into a fully-populated `CatalogComponent[]`, and
 * reports whether any component was missing `meetings` entirely. The first
 * catalog commit (2026-09-07) wrote components shaped
 * `{ activity, label, sectionCount, credits, sectionIDs }`; 6104d86 added
 * `meetings: CatalogMeeting[]` to the type but did nothing to the rows
 * already on disk, so a row written before that commit reads back missing
 * the field, and `catalogEntryWire`'s `for (const meeting of
 * component.meetings)` threw a TypeError on it -- the live 500 this
 * function exists to stop. `sectionIDs` gets the same treatment for the
 * same reason (an array field the type requires but an old row might lack),
 * even though every row observed so far has had it; there is no cost to
 * being defensive about a second field the same bug class could hit.
 * `activity`/`label`/`sectionCount`/`credits` are read straight through --
 * every catalog shape that has ever existed carried those, so there is
 * nothing to default there.
 */
function normalizeCatalogComponents(raw: unknown): { components: CatalogComponent[]; lacksMeetings: boolean } {
  if (!Array.isArray(raw)) return { components: [], lacksMeetings: false };
  let lacksMeetings = false;
  const components = raw.map((entry) => {
    const component = (entry ?? {}) as Partial<CatalogComponent> & Record<string, unknown>;
    const hasMeetings = Array.isArray(component.meetings);
    if (!hasMeetings) lacksMeetings = true;
    return {
      activity: component.activity ?? "",
      label: component.label ?? "",
      sectionCount: component.sectionCount ?? 0,
      credits: component.credits ?? null,
      sectionIDs: Array.isArray(component.sectionIDs) ? component.sectionIDs : [],
      meetings: hasMeetings ? (component.meetings as CatalogComponent["meetings"]) : [],
    };
  });
  return { components, lacksMeetings };
}

// Exported (unlike most of this file's row<->wire mappers) so
// `db.test.ts` can exercise the legacy-row normalization directly without
// a `SupabaseClient` -- it's pure, and the normalization behavior (not
// just the round-trip) is exactly what the fix in this commit needs a
// test to pin down.
export function dbRowToCatalogRow(row: CatalogCourseDBRow): CatalogCourseRow {
  const { components, lacksMeetings } = normalizeCatalogComponents(row.components);
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
    components,
    source: row.source,
    fetchedAt: row.fetched_at,
    syllabusURL: row.syllabus_url ?? undefined,
    componentsLackMeetings: lacksMeetings,
  };
}

/**
 * Whether `existing` (the current `catalog_courses` row for a code, if any)
 * needs a fresh Penn Labs fetch this manifest call. Factored out of
 * `sync/index.ts`'s `refreshCatalog` so the decision is unit-testable
 * without a `SupabaseClient` -- it is pure, taking the already-normalized
 * row and the caller's clock.
 *
 * A row missing entirely is the ordinary "never fetched" case.
 * `componentsLackMeetings` is checked *before* `catalogIsStale` and short-
 * circuits it: a legacy row is worse than a missing one, because it
 * answers -- `selectCatalogEntriesForCourses` will happily hand the client
 * a `CatalogEntryWire` with an empty `meetings` array, which reads as "this
 * course truly has no scheduled meetings" rather than "we don't know yet" --
 * and the Announcement Watcher's "before class Thursday" resolution and
 * `ask`'s COURSE STRUCTURE block both depend on that data being either
 * present or visibly absent (not silently wrong), so a legacy row must be
 * refetched even when it was fetched five minutes ago and is nowhere near
 * `catalogIsStale`.
 */
export function catalogNeedsFetch(existing: CatalogCourseRow | undefined, now: Date): boolean {
  if (existing === undefined) return true;
  if (existing.componentsLackMeetings) return true;
  return catalogIsStale(existing.fetchedAt, now);
}

/** The `catalog_courses` rows sync already has for a set of catalog codes,
 *  keyed by code -- used to decide which of a manifest call's courses need
 *  a fresh Penn Labs fetch (missing entirely, `componentsLackMeetings`, or
 *  `catalogIsStale` -- see `catalogNeedsFetch`) versus which can be left
 *  alone this run. */
export async function selectCatalogCoursesByCodes(
  client: SupabaseClient,
  catalogCodes: string[],
): Promise<Map<string, CatalogCourseRow>> {
  if (catalogCodes.length === 0) return new Map();
  const { data, error } = await client
    .from("catalog_courses")
    .select(
      "catalog_code, semester, title, description, credits, prerequisites, crosslistings, grade_modes, attributes, components, source, fetched_at, syllabus_url",
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

/**
 * The per-course `CatalogEntryWire` list `sync`'s manifest response hands
 * the client -- distinct from `selectCatalogCoursesForCourseIDs` just
 * above in that this one keeps the `course_id` <-> `catalog_code` pairing
 * (that function dedupes down to unique catalog rows for `ask`'s prompt,
 * which never needs to know which specific Canvas course id a row came
 * from). A course whose `catalog_code` hasn't yet had a successful Penn
 * Labs fetch (no `catalog_courses` row exists for it yet) simply
 * contributes nothing here, the same "missing is not an error" posture
 * `selectCatalogCoursesForCourseIDs` and `fetchCatalogCourse` both take.
 */
export async function selectCatalogEntriesForCourses(
  client: SupabaseClient,
  courseIDs: string[],
): Promise<CatalogEntryWire[]> {
  if (courseIDs.length === 0) return [];

  const { data: courseRows, error: courseError } = await client
    .from("courses")
    .select("course_id, catalog_code")
    .in("course_id", courseIDs)
    .not("catalog_code", "is", null);
  if (courseError) throw courseError;

  const linked = (courseRows ?? []) as Array<{ course_id: string; catalog_code: string }>;
  if (linked.length === 0) return [];

  const uniqueCodes = [...new Set(linked.map((row) => row.catalog_code))];
  const byCode = await selectCatalogCoursesByCodes(client, uniqueCodes);

  const entries: CatalogEntryWire[] = [];
  for (const row of linked) {
    const catalogRow = byCode.get(row.catalog_code);
    if (!catalogRow) continue;
    entries.push(catalogEntryWire(catalogRow, row.course_id));
  }
  // Sorted by courseID for the same determinism reason every other
  // manifest-response list in this codebase is sorted before being
  // handed back, even though this particular field isn't part of any
  // cached prompt prefix -- a stable order makes a client-side diff or
  // test assertion meaningful without also asserting on Postgres's
  // unspecified row order.
  return entries.sort((a, b) => a.courseID.localeCompare(b.courseID));
}

// ---------------------------------------------------------------------
// Course websites (supabase/migrations/20260907180000_websites.sql). See
// _shared/websites.ts and _shared/crawl.ts for the pure discovery/crawl
// logic, and `discover-websites/index.ts` for how these are wired
// together. As with the catalog section above, this is only the
// snake_case <-> camelCase mapping and the Supabase calls; no discovery
// policy (what counts as a candidate, when to re-verify) lives here.
// ---------------------------------------------------------------------

export type CourseWebsiteSource = "canvas-link" | "cis-directory" | "convention" | "penn-labs-syllabus";
export type CourseWebsiteStatus = "candidate" | "verified" | "rejected";

export interface CourseWebsiteRow {
  id: number;
  courseID: string;
  url: string;
  source: CourseWebsiteSource;
  confidence: number;
  status: CourseWebsiteStatus;
  anchorText: string | null;
  verifiedTerm: string | null;
  verifiedAt: string | null;
  lastCrawledAt: string | null;
  pageCount: number;
  gradescopeCourseID: string | null;
  edCourseID: string | null;
  createdAt: string;
}

interface CourseWebsiteDBRow {
  id: number;
  course_id: string;
  url: string;
  source: CourseWebsiteSource;
  confidence: number;
  status: CourseWebsiteStatus;
  anchor_text: string | null;
  verified_term: string | null;
  verified_at: string | null;
  last_crawled_at: string | null;
  page_count: number;
  gradescope_course_id: string | null;
  ed_course_id: string | null;
  created_at: string;
}

const COURSE_WEBSITE_COLUMNS =
  "id, course_id, url, source, confidence, status, anchor_text, verified_term, verified_at, last_crawled_at, page_count, gradescope_course_id, ed_course_id, created_at";

function dbRowToCourseWebsite(row: CourseWebsiteDBRow): CourseWebsiteRow {
  return {
    id: row.id,
    courseID: row.course_id,
    url: row.url,
    source: row.source,
    confidence: row.confidence,
    status: row.status,
    anchorText: row.anchor_text,
    verifiedTerm: row.verified_term,
    verifiedAt: row.verified_at,
    lastCrawledAt: row.last_crawled_at,
    pageCount: row.page_count,
    gradescopeCourseID: row.gradescope_course_id,
    edCourseID: row.ed_course_id,
    createdAt: row.created_at,
  };
}

/** Every `course_websites` row (any status) for the given courses --
 *  `discover-websites` uses this both to gather already-known candidates
 *  before adding directory/convention/Penn-Labs ones, and to pick which
 *  verified row (if any) is due for a re-crawl. */
export async function selectCourseWebsites(
  client: SupabaseClient,
  courseIDs: string[],
): Promise<CourseWebsiteRow[]> {
  if (courseIDs.length === 0) return [];
  const { data, error } = await client
    .from("course_websites")
    .select(COURSE_WEBSITE_COLUMNS)
    .in("course_id", courseIDs);
  if (error) throw error;
  return ((data ?? []) as CourseWebsiteDBRow[]).map(dbRowToCourseWebsite);
}

export interface NewCourseWebsiteCandidate {
  courseID: string;
  url: string;
  source: CourseWebsiteSource;
  confidence: number;
  anchorText?: string;
}

/**
 * Upserts candidate rows by `(course_id, url)`, taking the *greater* of an
 * existing row's confidence and the new signal's -- two different sources
 * agreeing on the same URL (a Canvas link and a CIS directory entry both
 * pointing at `~cis2400/current/`) is stronger evidence than either alone,
 * so the row should reflect whichever discovery so far thought most highly
 * of it, never regress to a weaker one. `status` is deliberately left
 * alone when a row already exists: rediscovering an already-`verified` or
 * already-`rejected` URL from a fresh sync's links is not new evidence
 * that overrides a verification outcome only `discover-websites`' own
 * verify step is allowed to change. Supabase's JS client has no
 * `GREATEST(...)`-in-an-upsert primitive, so this reads existing rows
 * first and computes the merge in application code -- the same pattern
 * `upsertEnrollments` above already uses to merge `section_ids`.
 */
export async function upsertCourseWebsiteCandidates(
  client: SupabaseClient,
  candidates: NewCourseWebsiteCandidate[],
): Promise<void> {
  if (candidates.length === 0) return;

  const courseIDs = [...new Set(candidates.map((candidate) => candidate.courseID))];
  const { data: existingRows, error: selectError } = await client
    .from("course_websites")
    .select("course_id, url, confidence, status, anchor_text")
    .in("course_id", courseIDs);
  if (selectError) throw selectError;

  interface ExistingSlice {
    confidence: number;
    status: CourseWebsiteStatus;
    anchor_text: string | null;
  }
  const existingByKey = new Map<string, ExistingSlice>();
  for (const row of (existingRows ?? []) as Array<ExistingSlice & { course_id: string; url: string }>) {
    existingByKey.set(`${row.course_id}\u0000${row.url}`, row);
  }

  const rows = candidates.map((candidate) => {
    const existing = existingByKey.get(`${candidate.courseID}\u0000${candidate.url}`);
    return {
      course_id: candidate.courseID,
      url: candidate.url,
      source: candidate.source,
      confidence: Math.max(existing?.confidence ?? 0, candidate.confidence),
      status: existing?.status ?? "candidate",
      anchor_text: candidate.anchorText ?? existing?.anchor_text ?? null,
    };
  });

  const { error } = await client.from("course_websites").upsert(rows, { onConflict: "course_id,url" });
  if (error) throw error;
}

/** Marks one `course_websites` row verified for `verifiedTerm`, with the
 *  caller-computed `confidence` (existing confidence + the verify bonus --
 *  computed by the caller, which already has the row in hand from
 *  `selectCourseWebsites`, rather than this function re-reading it). */
export async function setCourseWebsiteVerified(
  client: SupabaseClient,
  id: number,
  input: { verifiedTerm: string; confidence: number },
): Promise<void> {
  const { error } = await client
    .from("course_websites")
    .update({
      status: "verified",
      verified_term: input.verifiedTerm,
      verified_at: new Date().toISOString(),
      confidence: input.confidence,
    })
    .eq("id", id);
  if (error) throw error;
}

/** Marks one `course_websites` row rejected -- fetched successfully but
 *  `verifyPage` didn't match. Kept (not deleted) so this URL isn't
 *  re-fetched-and-rejected every single `discover-websites` call; see the
 *  migration's `status` column comment. */
export async function setCourseWebsiteRejected(client: SupabaseClient, id: number): Promise<void> {
  const { error } = await client.from("course_websites").update({ status: "rejected" }).eq("id", id);
  if (error) throw error;
}

/** Records the outcome of crawling one verified `course_websites` row --
 *  when it was last crawled, how many pages it yielded, and any
 *  Gradescope/Ed course id `sideIDs` recovered from its pages. */
export async function setCourseWebsiteCrawlStats(
  client: SupabaseClient,
  id: number,
  input: {
    lastCrawledAt: string;
    pageCount: number;
    gradescopeCourseID?: string;
    edCourseID?: string;
  },
): Promise<void> {
  const { error } = await client
    .from("course_websites")
    .update({
      last_crawled_at: input.lastCrawledAt,
      page_count: input.pageCount,
      gradescope_course_id: input.gradescopeCourseID ?? null,
      ed_course_id: input.edCourseID ?? null,
    })
    .eq("id", id);
  if (error) throw error;
}

/** The subset of `courses` columns `discover-websites` (and `sync`'s
 *  link-candidate scoring) needs per course: its own Canvas code (what
 *  `candidateFromLink` matches a link's URL/text against), its resolved
 *  registrar `catalog_code`, if any (the join to
 *  `catalog_courses.semester`/`syllabus_url` and to `parseCisDirectory`
 *  entries, which key on catalog code, not the raw Canvas code), and its
 *  own Canvas `url` -- used only as the base a relative link href resolves
 *  against, since the wire's `LinkWire` carries no page URL of its own,
 *  only which kind of Canvas page (`origin`) it came from. */
export interface DiscoveryCourseInfo {
  courseID: string;
  code: string;
  catalogCode: string | null;
  url: string | null;
}

export async function selectCoursesForDiscovery(
  client: SupabaseClient,
  courseIDs: string[],
): Promise<DiscoveryCourseInfo[]> {
  if (courseIDs.length === 0) return [];
  const { data, error } = await client
    .from("courses")
    .select("course_id, code, catalog_code, url")
    .in("course_id", courseIDs);
  if (error) throw error;
  return (
    (data ?? []) as Array<{ course_id: string; code: string; catalog_code: string | null; url: string | null }>
  ).map((row) => ({
    courseID: row.course_id,
    code: row.code,
    catalogCode: row.catalog_code,
    url: row.url,
  }));
}

/** Live `website`-kind document ids for one course -- `discover-websites`'
 *  own equivalent of `selectLiveDocumentIDsForCourse`, scoped to `kind =
 *  'website'` because a crawl only ever knows about that course's website
 *  pages, never its Canvas-sourced documents; marking a Canvas page gone
 *  just because a crawl didn't happen to re-see it would be wrong. */
export async function selectLiveWebsiteDocumentIDsForCourse(
  client: SupabaseClient,
  courseID: string,
): Promise<string[]> {
  const { data, error } = await client
    .from("course_documents")
    .select("id")
    .eq("course_id", courseID)
    .eq("kind", "website")
    .is("gone_at", null);
  if (error) throw error;
  return (data ?? []).map((row) => (row as { id: string }).id);
}

// ---------------------------------------------------------------------
// directory_cache (supabase/migrations/20260907180000_websites.sql):
// service-role-only key/value cache so `discover-websites` fetches the CIS
// Advising Handbook's course directory at most once per 24h *total* across
// every student's call, not once per student -- see that function and
// PROTOCOL.md's course-website section.
// ---------------------------------------------------------------------

export interface DirectoryCacheEntry {
  body: string;
  fetchedAt: string;
}

export async function selectDirectoryCache(
  client: SupabaseClient,
  key: string,
): Promise<DirectoryCacheEntry | undefined> {
  const { data, error } = await client
    .from("directory_cache")
    .select("body, fetched_at")
    .eq("key", key)
    .maybeSingle();
  if (error) throw error;
  if (!data) return undefined;
  const row = data as { body: string; fetched_at: string };
  return { body: row.body, fetchedAt: row.fetched_at };
}

export async function upsertDirectoryCache(client: SupabaseClient, key: string, body: string): Promise<void> {
  const { error } = await client
    .from("directory_cache")
    .upsert({ key, body, fetched_at: new Date().toISOString() }, { onConflict: "key" });
  if (error) throw error;
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
