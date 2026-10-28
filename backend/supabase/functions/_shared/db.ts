// Thin, typed wrappers over a service-role Supabase client for the tables
// in supabase/migrations/20260907000000_init.sql. This is the one place in
// the backend that knows the snake_case column names and does the
// snake_case <-> camelCase mapping to/from the wire types in manifest.ts --
// index.ts should never see a raw row shape, and manifest.ts (pure,
// dependency-free, unit tested without a database) should never import
// this file.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2.115.0";
import type {
  CourseDocumentWire,
  CourseSummaryWire,
  DocumentKind,
  DocumentStub,
  SyncClient,
} from "./manifest.ts";
import { WINDOW_KINDS, windowAgeOutFilter } from "./manifest.ts";
import { isAuthUserGone } from "./devices.ts";
import {
  catalogEntryWire,
  academicSemester,
  catalogIsStale,
  rowsForSemester,
  type CatalogComponent,
  type CatalogCourseRow,
  type CatalogMeeting,
  type CatalogEntryWire,
} from "./catalog.ts";
import {
  isoDayOf,
  sanitizeProfile,
  type CourseProfileWire,
  type ExamDate,
  type GradingWeight,
  type ProfileComponent,
} from "./profile.ts";

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
  /** Who uploaded the row; absent on rows read by the explicit column
   *  lists above (the default, 'phone', applies in the database). */
  collector?: DocumentCollector;
}

/** Who wrote a `course_documents` row: one of the two sync clients, or the
 *  server itself (`discover-websites`' crawl of a course's own website,
 *  since 2026-10-27). */
export type DocumentCollector = SyncClient | "server";

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

function documentWireToInsertRow(
  doc: CourseDocumentWire,
  collector: DocumentCollector,
): Omit<CourseDocumentRow, "first_seen_at"> {
  return {
    // Stamped on every upsert, so the row belongs to whoever uploaded it
    // last. A phone re-uploading a page the extension had pooled takes
    // ownership of it, which is right: the phone's next complete-set report
    // is then entitled to retire it if Canvas drops the page.
    collector,
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

const LIVE_DOCUMENT_FULL_COLUMNS =
  "id, course_id, course_code, kind, source_id, title, url, text, content_hash, updated_at, fetched_at, due_at, points_possible, first_seen_at, gone_at";

/** What the upload's before/after snapshots read: enough to diff content
 * hashes and resolve an id to its kind, with no `text` along for the ride. */
const LIVE_DOCUMENT_SNAPSHOT_COLUMNS = "id, kind, content_hash, collector";

/** Rows per PostgREST request. The live project's `max_rows` is 1000
 * (read through the Management API on 2026-10-23); a request for more is
 * silently cut to 1000 with a 200, not refused. 500 stays well under it and
 * keeps the full-text pages (up to 200,000 characters a row) a sane size. */
export const LIVE_DOCUMENT_PAGE_SIZE = 500;

/** The pager shared by the two live reads below. Pages are ordered by `id`
 * so `range` windows are stable while rows are written between requests (an
 * unordered paginated read can repeat or skip rows), and it stops at the
 * first short page. The wrong fix is a bigger single select: the cap is the
 * server's, and exceeding it truncates without an error, which is exactly
 * how a manifest used to lose the tail of a big student's pool. The window
 * kinds' age-out (`windowAgeOutFilter`) is applied in SQL here, so the
 * manifest, its `serverManifest` and the upload snapshots all agree on what
 * is live. */
async function pagedLiveRows<T>(
  client: SupabaseClient,
  courseIDs: string[],
  now: Date,
  columns: string,
): Promise<T[]> {
  if (courseIDs.length === 0) return [];
  const orFilter = windowAgeOutFilter(now);
  const rows: T[] = [];
  for (let from = 0;; from += LIVE_DOCUMENT_PAGE_SIZE) {
    const { data, error } = await client
      .from("course_documents")
      .select(columns)
      .in("course_id", courseIDs)
      .is("gone_at", null)
      .or(orFilter)
      .order("id", { ascending: true })
      .range(from, from + LIVE_DOCUMENT_PAGE_SIZE - 1);
    if (error) throw error;
    const page = (data ?? []) as T[];
    rows.push(...page);
    if (page.length < LIVE_DOCUMENT_PAGE_SIZE) break;
  }
  return rows;
}

/** Full live-document rows for a set of course ids -- used to build the
 * manifest's `download` list (needs complete `CourseDocumentWire` bodies).
 * Window-kind rows older than `WINDOW_KIND_MAX_AGE_DAYS` are not returned,
 * and the read is paginated; see `pagedLiveRows`. `now` is the caller's, so
 * a request reads the clock once. */
export async function selectLiveDocumentsForCourses(
  client: SupabaseClient,
  courseIDs: string[],
  now: Date,
): Promise<CourseDocumentRow[]> {
  return await pagedLiveRows<CourseDocumentRow>(client, courseIDs, now, LIVE_DOCUMENT_FULL_COLUMNS);
}

export type LiveDocumentSnapshotRow = Pick<CourseDocumentRow, "id" | "kind" | "content_hash" | "collector">;

/** The same live set as `selectLiveDocumentsForCourses` (same age-out, same
 * paging) with only the columns the upload's before/after diff reads. A
 * separate function rather than a `columns` argument so the return type
 * cannot claim a `text` it did not select. */
export async function selectLiveDocumentSnapshots(
  client: SupabaseClient,
  courseIDs: string[],
  now: Date,
): Promise<LiveDocumentSnapshotRow[]> {
  return await pagedLiveRows<LiveDocumentSnapshotRow>(client, courseIDs, now, LIVE_DOCUMENT_SNAPSHOT_COLUMNS);
}

/** Just the live ids for one course -- all `goneIDs` needs, and cheap
 * enough to call once per fully-synced course in the upload step without
 * pulling every document's full text along for the ride. */
export async function selectLiveDocumentIDsForCourse(
  client: SupabaseClient,
  courseID: string,
  onlyCollector?: "phone" | "extension",
): Promise<string[]> {
  // Window kinds (`announcement`, `ed`; see `WINDOW_KINDS` in manifest.ts)
  // are excluded on purpose, so the complete-set rule in the upload step can
  // never mark them gone. A course's Canvas material is the same for every
  // enrolled student, so one student's full fetch is authoritative for the
  // whole pool; its announcements and Ed board are not: a student who has
  // not joined Ed yet, whose Canvas site lacks the Ed tab, or whose
  // announcements request failed legitimately uploads a fully-synced course
  // with zero such ids, and treating that as "every post was deleted" would
  // erase what their classmates pooled. The cost is that a post deleted at
  // the source stays pooled until it ages out (`WINDOW_KIND_MAX_AGE_DAYS`).
  // Clients still drop them locally.
  //
  // `onlyCollector` is the second exemption (see `retirableCollector` in
  // manifest.ts): a phone reporting a complete set may only retire rows the
  // phone collected, since it never sees the extension's late pages or
  // files.
  let query = client
    .from("course_documents")
    .select("id")
    .eq("course_id", courseID)
    .not("kind", "in", `(${WINDOW_KINDS.join(",")})`)
    .is("gone_at", null);
  //
  // And no client report ever retires a row the server wrote (2026-10-27).
  // A crawl's pages are the server's to retire, which `discover-websites`
  // does itself when a later crawl stops seeing a page; a phone that synced
  // between a crawl and its own next manifest simply had not downloaded
  // them, which is exactly how ECON 0100 lost five fresh crawl rows on
  // 2026-10-26, when crawled rows still carried the default 'phone'.
  query = onlyCollector ? query.eq("collector", onlyCollector) : query.neq("collector", "server");
  const { data, error } = await query;
  if (error) throw error;
  return (data ?? []).map((row) => (row as { id: string }).id);
}

/** Upserts documents by id in batches of `UPSERT_BATCH_SIZE`. Assumes the
 * caller (sync/index.ts) has already run every document through
 * `validateDocument`, so this layer does no further shape checking -- its
 * only job is the wire-to-row mapping and staying under Postgres's
 * practical statement size. */
export async function upsertDocuments(
  client: SupabaseClient,
  documents: CourseDocumentWire[],
  collector: DocumentCollector = "phone",
): Promise<void> {
  for (const batch of chunk(documents, UPSERT_BATCH_SIZE)) {
    const rows = batch.map((doc) => documentWireToInsertRow(doc, collector));
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
 *
 * The same thing happened a second time when rooms and instructors were
 * added: a meeting written before then has no `room` key and a component
 * has no `instructorsBySection` key. Those are normalized to `room: null`
 * and `{}` so every reader can rely on the shape, and `lacksSectionDetails`
 * reports that it happened. It is decided by whether the *key is present*,
 * never by the value: a stored `room: null` is a real fact (an online
 * section lists no room) and `instructorsBySection: {}` is a real fact (no
 * instructor listed), so a null/empty test would call every such course
 * legacy and `catalogNeedsFetch` would refetch it from Penn Labs on every
 * manifest call forever. A fresh fetch always writes both keys, so a row
 * with the keys never gets flagged again. The wrong shortcut is treating
 * the normalized `null`/`{}` as "missing": after normalization the two
 * cases are indistinguishable, which is why the flag is computed from the
 * raw json before the defaults are filled in.
 */
function normalizeCatalogComponents(
  raw: unknown,
): { components: CatalogComponent[]; lacksMeetings: boolean; lacksSectionDetails: boolean } {
  if (!Array.isArray(raw)) return { components: [], lacksMeetings: false, lacksSectionDetails: false };
  let lacksMeetings = false;
  let lacksSectionDetails = false;
  const components = raw.map((entry) => {
    const component = (entry ?? {}) as Partial<CatalogComponent> & Record<string, unknown>;
    const hasMeetings = Array.isArray(component.meetings);
    if (!hasMeetings) lacksMeetings = true;
    const hasInstructors = typeof component.instructorsBySection === "object" &&
      component.instructorsBySection !== null && !Array.isArray(component.instructorsBySection);
    if (!hasInstructors) lacksSectionDetails = true;
    const meetings = hasMeetings
      ? (component.meetings as unknown[]).map((meeting) => {
        const record = (meeting ?? {}) as Record<string, unknown>;
        if (!("room" in record)) lacksSectionDetails = true;
        return { ...record, room: typeof record["room"] === "string" ? record["room"] : null } as unknown as CatalogMeeting;
      })
      : [];
    return {
      activity: component.activity ?? "",
      label: component.label ?? "",
      sectionCount: component.sectionCount ?? 0,
      credits: component.credits ?? null,
      sectionIDs: Array.isArray(component.sectionIDs) ? component.sectionIDs : [],
      meetings,
      instructorsBySection: hasInstructors ? (component.instructorsBySection as Record<string, string[]>) : {},
    };
  });
  return { components, lacksMeetings, lacksSectionDetails };
}

// Exported (unlike most of this file's row<->wire mappers) so
// `db.test.ts` can exercise the legacy-row normalization directly without
// a `SupabaseClient` -- it's pure, and the normalization behavior (not
// just the round-trip) is exactly what the fix in this commit needs a
// test to pin down.
export function dbRowToCatalogRow(row: CatalogCourseDBRow): CatalogCourseRow {
  const { components, lacksMeetings, lacksSectionDetails } = normalizeCatalogComponents(row.components);
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
    componentsLackSectionDetails: lacksSectionDetails,
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
 *
 * `componentsLackSectionDetails` short-circuits the same way, for a row
 * written before rooms and instructors were kept: it answers, but `ask`
 * would tell a student "no room is listed" for a lecture whose room we simply
 * never stored. Whether a row is in that state is decided by key presence
 * in the stored json (see `normalizeCatalogComponents`), not by `room`
 * being null, so a genuinely roomless online section does not refetch
 * every hour.
 */
export function catalogNeedsFetch(existing: CatalogCourseRow | undefined, now: Date): boolean {
  if (existing === undefined) return true;
  if (existing.componentsLackMeetings) return true;
  if (existing.componentsLackSectionDetails) return true;
  // Around 2026-10-15 Penn Labs flipped its `current` semester to 2027A
  // while students were still in Fall 2026, and refetches stored Spring
  // rows. A row for the wrong semester is worse than a missing one for the
  // same reason a legacy row is: it answers, with next semester's rooms and
  // times, and nothing marks it as wrong. It is refetched however fresh it
  // is (and never served meanwhile: see `rowsForSemester`).
  if (existing.semester !== academicSemester(now)) return true;
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
  semester: string,
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
  // Rows stored for another semester are dropped, not served: see
  // `rowsForSemester`.
  const byCode = new Map(
    rowsForSemester([...(await selectCatalogCoursesByCodes(client, uniqueCodes)).values()], semester)
      .map((row) => [row.catalogCode, row] as const),
  );

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

function isJsonRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** The columns `selectProfileWiresForCourses` reads from `course_profiles`
 *  -- `profile` deliberately typed `unknown` rather than `CourseProfile`,
 *  since Postgres hands this jsonb column back exactly as last written,
 *  not as whatever shape today's code expects (see `profileRowToWire`'s
 *  doc comment). */
export interface CourseProfileDBRow {
  course_id: string;
  profile: unknown;
  updated_at: string;
}

/** A `ProfileComponent`'s `gradingBasis`/`creditUnits` dropped straight
 *  onto the wire only when actually present, rather than as an explicit
 *  `undefined` value -- the same "omit the key, don't set it to undefined"
 *  discipline `sanitizeProfile` itself already follows for every other
 *  optional field, and required here because a plain `{ gradingBasis:
 *  component.gradingBasis }` spread would instead produce an *own*
 *  property holding `undefined`, which survives a `JSON.stringify` round
 *  trip differently than a genuinely absent key and would make
 *  `assert.deepEqual` in tests see two different-looking objects for what
 *  should be the same wire shape. */
function toWireComponent(component: ProfileComponent): CourseProfileWire["components"][number] {
  const wire: CourseProfileWire["components"][number] = { name: component.name };
  if (component.gradingBasis !== undefined) wire.gradingBasis = component.gradingBasis;
  if (component.creditUnits !== undefined) wire.creditUnits = component.creditUnits;
  return wire;
}

/** One stored exam entry as it goes on the wire, or `undefined` when it
 *  can't be an exam at all (no name left after trimming). `date` rides along
 *  only as a real `YYYY-MM-DD` day (`isoDayOf`); a date the model wrote some
 *  other way, or one that doesn't exist on the calendar, is dropped and the
 *  entry goes out undated, because the entry itself ("Final Exam", "TBD")
 *  is still true and only the date is not usable. Built key by key, like
 *  `toWireComponent`, so an absent date is an absent key rather than an own
 *  property holding `undefined`. */
function toWireExamDate(exam: ExamDate): ExamDate | undefined {
  const name = exam.name.trim();
  if (name === "") return undefined;
  const wire: ExamDate = { name, text: exam.text };
  const day = exam.date === undefined ? undefined : isoDayOf(exam.date);
  if (day !== undefined) wire.date = day;
  return wire;
}

/**
 * Maps one `course_profiles` row into the `CourseProfileWire` `sync`'s
 * manifest response hands the client -- Grade Watcher's suggested grading
 * scheme (see PROTOCOL.md's "sync" section and `_shared/profile.ts`'s
 * `CourseProfileWire` doc comment). Exported (unlike most of this file's
 * row<->wire mappers) so `db.test.ts` can exercise the normalization
 * directly without a `SupabaseClient` -- the same reason `dbRowToCatalogRow`
 * above is exported.
 *
 * `profile` is read as `unknown` and pushed through `sanitizeProfile` --
 * the same normalize-on-read discipline `dbRowToCatalogRow` applies to
 * `catalog_courses.components` and for the identical reason: this column is
 * jsonb, so a row can predate a shape change (the `expectedCount`/
 * `dropLowest` fields added alongside this function, or any future one) and
 * Postgres hands it back exactly as last written, not as today's
 * `CourseProfile`. `sanitizeProfile` was written to validate a *model's*
 * JSON response, but "arbitrary untrusted-shaped JSON in, a safely-typed
 * `CourseProfile` out" is exactly the problem a stored jsonb value poses
 * too, so reusing it here means there is only one place that knows what a
 * valid `gradingWeights`/`components` entry looks like, not two
 * definitions to keep in sync -- including a malformed value (e.g.
 * `gradingWeights` stored as something other than an array), which
 * `sanitizeArray`'s `Array.isArray` guard inside `sanitizeProfile` already
 * turns into "omit the field" rather than a thrown error. A `profile`
 * value that isn't even a JSON object (defensive only -- the column is
 * `not null` and every writer today only ever stores an object) degrades
 * to an empty profile the same way, so this function never fails the way
 * an unguarded read of `catalog_courses.components` once did (see
 * CLAUDE.md's jsonb trap) -- the caller (`sync/index.ts`'s
 * `handleManifest`) still wraps the call in try/catch as a second line of
 * defense, matching how it already treats `selectCatalogEntriesForCourses`.
 */
export function profileRowToWire(row: CourseProfileDBRow): CourseProfileWire {
  const profile = isJsonRecord(row.profile) ? sanitizeProfile(row.profile) : {};
  return {
    courseID: row.course_id,
    gradingWeights: profile.gradingWeights ?? [],
    components: (profile.components ?? []).map(toWireComponent),
    // Normalized here for the same reason as the two arrays above: this is
    // jsonb. A row extracted before `examDates` existed has no such key, one
    // with a malformed value was already turned into "omit" by
    // `sanitizeProfile`'s `sanitizeArray`, and an entry whose date is not a
    // real ISO day is undated by `toWireExamDate`. None of those may fail the
    // manifest, which `handleManifest` would otherwise answer with no
    // profiles at all.
    examDates: (profile.examDates ?? [])
      .map(toWireExamDate)
      .filter((exam): exam is ExamDate => exam !== undefined),
    extractedAt: row.updated_at,
  };
}

/**
 * The per-course `CourseProfileWire` list `sync`'s manifest response hands
 * the client. One entry per `courseIDs` member that has a `course_profiles`
 * row at all; a course that has never had `extract-profile` build one
 * simply contributes nothing, the same "missing is not an error" posture
 * `selectCatalogEntriesForCourses` takes toward an unresolved catalog code.
 * All normalization lives in `profileRowToWire` above -- this is only the
 * Supabase read and the same by-`courseID` sort every other manifest-
 * response list in this codebase gets.
 */
export async function selectProfileWiresForCourses(
  client: SupabaseClient,
  courseIDs: string[],
): Promise<CourseProfileWire[]> {
  if (courseIDs.length === 0) return [];

  const { data, error } = await client
    .from("course_profiles")
    .select("course_id, profile, updated_at")
    .in("course_id", courseIDs);
  if (error) throw error;

  const rows = (data ?? []) as CourseProfileDBRow[];
  return rows
    .map(profileRowToWire)
    .sort((a, b) => a.courseID.localeCompare(b.courseID));
}

// ---------------------------------------------------------------------
// Category map cache (supabase/migrations/20260910120000_category_map.sql).
// See PROTOCOL.md's "map-categories" section and `_shared/categoryMap.ts`
// for the pure validation/hashing/sanitizing logic this wraps.
// ---------------------------------------------------------------------

/** What `map-categories/index.ts` needs from one course's `course_profiles`
 *  row: the syllabus-derived grading weights (to know the category names
 *  a mapping is even allowed to use, and to build the model prompt), plus
 *  whatever cached mapping already exists. `profile`/`categoryMap` are
 *  read as `unknown`, the same "jsonb hands back exactly what was last
 *  written, not today's type" posture `CourseProfileDBRow.profile` already
 *  takes -- see `dbRowToCatalogRow`'s and `profileRowToWire`'s doc
 *  comments for why that discipline matters (CLAUDE.md's jsonb trap). */
export interface CategoryMapCourseRow {
  gradingWeights: GradingWeight[];
  categoryMap: unknown;
  categoryMapHash: string | null;
  /** When the cached `categoryMap` was actually computed by the model --
   *  distinct from "now", which is what a cache-hit response would
   *  otherwise (wrongly) report as `extractedAt` if this weren't carried
   *  through from storage. `null` whenever `categoryMap`/`categoryMapHash`
   *  are also null (no mapping has ever been cached for this course). */
  categoryMapAt: string | null;
}

interface CategoryMapCourseDBRow {
  profile: unknown;
  category_map: unknown;
  category_map_hash: string | null;
  category_map_at: string | null;
}

/**
 * Loads the one `course_profiles` row for `courseID`, or `undefined` when
 * the course has no profile yet -- the same "no syllabus extraction has
 * ever run for this course" case `map-categories/index.ts` answers with
 * `{ "mapping": null }` per PROTOCOL.md, without ever reaching the model.
 * `sanitizeProfile` normalizes `profile` on read for the reason
 * `profileRowToWire` already documents; `categoryMap`/`categoryMapHash`
 * are handed back unsanitized here on purpose -- validating a *cached*
 * mapping needs the current request's own valid-id sets, which this
 * function has no access to, so that normalization happens in
 * `map-categories/index.ts` via `sanitizeCategoryMapping`, re-run against
 * the live request every time a cache hit is served.
 */
export async function selectCourseProfileForCategoryMap(
  client: SupabaseClient,
  courseID: string,
): Promise<CategoryMapCourseRow | undefined> {
  const { data, error } = await client
    .from("course_profiles")
    .select("profile, category_map, category_map_hash, category_map_at")
    .eq("course_id", courseID)
    .maybeSingle();
  if (error) throw error;
  if (!data) return undefined;

  const row = data as CategoryMapCourseDBRow;
  const profile = isJsonRecord(row.profile) ? sanitizeProfile(row.profile) : {};
  return {
    gradingWeights: profile.gradingWeights ?? [],
    categoryMap: row.category_map,
    categoryMapHash: row.category_map_hash,
    categoryMapAt: row.category_map_at,
  };
}

/**
 * Stores a freshly-computed mapping and the structure hash it answers, on
 * the course's existing `course_profiles` row. Always an `update`, never
 * an `upsert`: a call only reaches here once
 * `selectCourseProfileForCategoryMap` has already found a row for this
 * course (that's what supplied the `gradingWeights` a mapping needs to
 * exist at all), so there is always a row to update.
 */
export async function storeCategoryMap(
  client: SupabaseClient,
  courseID: string,
  categoryMap: unknown,
  categoryMapHash: string,
): Promise<void> {
  const { error } = await client
    .from("course_profiles")
    .update({
      category_map: categoryMap,
      category_map_hash: categoryMapHash,
      category_map_at: new Date().toISOString(),
    })
    .eq("course_id", courseID);
  if (error) throw error;
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

/** Deletes an owner's private rows ahead of deleting the auth user
 * itself. `courses`/`course_documents`/`course_profiles` are untouched --
 * per PROTOCOL.md, shared course material is not the user's data.
 *
 * Also removes the owner's device links and every sync blob. The linked
 * devices' auth users are deleted by the caller (`delete-account`) from the
 * ids returned by `selectLinkedDeviceIDs`, read *before* this runs: once
 * the links are gone there is no way left to find them.
 *
 * Only ever call this with the id of the token's own user, never with a
 * resolved owner id from a linked device's token -- `delete-account`
 * guards that with `decideDeleteAccount`. */
export async function deleteUserData(client: SupabaseClient, userId: string): Promise<void> {
  const { error: enrollmentsError } = await client.from("enrollments").delete().eq("user_id", userId);
  if (enrollmentsError) throw enrollmentsError;

  const { error: askUsageError } = await client.from("ask_usage").delete().eq("user_id", userId);
  if (askUsageError) throw askUsageError;

  const { error: blobsError } = await client.from("device_sync_blobs").delete().eq("owner_user_id", userId);
  if (blobsError) throw blobsError;

  const { error: linksError } = await client.from("device_links").delete().eq("owner_user_id", userId);
  if (linksError) throw linksError;
}

// ---------------------------------------------------------------------
// Pairing and device sync (20261022090000_chrome_extension.sql). The
// decisions live in devices.ts; these are only the queries.
// ---------------------------------------------------------------------

/** The device user ids linked to an owner. */
export async function selectLinkedDeviceIDs(client: SupabaseClient, ownerId: string): Promise<string[]> {
  const { data, error } = await client.from("device_links").select("device_user_id").eq("owner_user_id", ownerId);
  if (error) throw error;
  return (data ?? []).map((row) => (row as { device_user_id: string }).device_user_id);
}

/** Replaces any waiting pairing of this device user with a new one. */
export async function replacePairing(
  client: SupabaseClient,
  deviceUserId: string,
  code: string,
  expiresAt: Date,
): Promise<void> {
  const { error: deleteError } = await client.from("pairings").delete().eq("device_user_id", deviceUserId);
  if (deleteError) throw deleteError;
  const { error } = await client
    .from("pairings")
    .insert({ code, device_user_id: deviceUserId, expires_at: expiresAt.toISOString() });
  if (error) throw error;
}

export async function selectPairing(
  client: SupabaseClient,
  code: string,
): Promise<{ deviceUserId: string; expiresAt: string } | null> {
  const { data, error } = await client
    .from("pairings")
    .select("device_user_id, expires_at")
    .eq("code", code)
    .maybeSingle();
  if (error) throw error;
  if (!data) return null;
  const row = data as { device_user_id: string; expires_at: string };
  return { deviceUserId: row.device_user_id, expiresAt: row.expires_at };
}

/** Atomically consumes a pairing: a delete that returns the row, so two
 * phones claiming one code cannot both win. Returns whether this call was
 * the one that consumed it. */
export async function consumePairing(client: SupabaseClient, code: string): Promise<boolean> {
  const { data, error } = await client.from("pairings").delete().eq("code", code).select("code");
  if (error) throw error;
  return (data ?? []).length === 1;
}

export async function insertDeviceLink(
  client: SupabaseClient,
  deviceUserId: string,
  ownerUserId: string,
): Promise<"linked" | "already_linked"> {
  const { error } = await client
    .from("device_links")
    .insert({ device_user_id: deviceUserId, owner_user_id: ownerUserId });
  // 23505 = unique_violation on the device_user_id primary key.
  if (error?.code === "23505") return "already_linked";
  if (error) throw error;
  return "linked";
}

/** Device user ids among `candidateIDs` (or all, when undefined) that are
 * linked to this owner. Scoping by owner here is what keeps "the named
 * device must be theirs" a query fact rather than a caller's promise. */
export async function selectOwnedDeviceIDs(
  client: SupabaseClient,
  ownerId: string,
  candidateIDs?: string[],
): Promise<string[]> {
  let query = client.from("device_links").select("device_user_id").eq("owner_user_id", ownerId);
  if (candidateIDs) query = query.in("device_user_id", candidateIDs);
  const { data, error } = await query;
  if (error) throw error;
  return (data ?? []).map((row) => (row as { device_user_id: string }).device_user_id);
}

/** Cuts the link first (so the device loses access at once), then its
 * blob row, then the device's auth user. Callers pass ids already proven
 * to belong to `ownerId`. Failure of the last step leaves an unlinked,
 * empty anonymous user, which resolves to itself and sees nothing. */
export async function removeDevices(
  client: SupabaseClient,
  ownerId: string,
  deviceUserIds: string[],
): Promise<number> {
  if (deviceUserIds.length === 0) return 0;
  const { error: linkError } = await client
    .from("device_links")
    .delete()
    .eq("owner_user_id", ownerId)
    .in("device_user_id", deviceUserIds);
  if (linkError) throw linkError;

  // A device's blob row is keyed by its own user id (see device-sync).
  const { error: blobError } = await client
    .from("device_sync_blobs")
    .delete()
    .eq("owner_user_id", ownerId)
    .in("device_id", deviceUserIds);
  if (blobError) throw blobError;

  for (const id of deviceUserIds) {
    const { error } = await client.auth.admin.deleteUser(id);
    // A device user that is already gone is the outcome this call wants, so
    // unpairing twice (or retrying after a failure part way) is not an error.
    if (error && !isAuthUserGone(error)) throw new Error("failed to delete device auth user");
  }
  return deviceUserIds.length;
}

export async function upsertDeviceBlob(
  client: SupabaseClient,
  ownerId: string,
  deviceId: string,
  ciphertext: string,
): Promise<string> {
  const updatedAt = new Date().toISOString();
  const { error } = await client
    .from("device_sync_blobs")
    .upsert(
      { owner_user_id: ownerId, device_id: deviceId, ciphertext, updated_at: updatedAt },
      { onConflict: "owner_user_id,device_id" },
    );
  if (error) throw error;
  return updatedAt;
}

export async function selectDeviceBlobs(
  client: SupabaseClient,
  ownerId: string,
): Promise<Array<{ deviceId: string; ciphertext: string; updatedAt: string }>> {
  const { data, error } = await client
    .from("device_sync_blobs")
    .select("device_id, ciphertext, updated_at")
    .eq("owner_user_id", ownerId)
    .order("device_id", { ascending: true });
  if (error) throw error;
  return (data ?? []).map((row) => {
    const r = row as { device_id: string; ciphertext: string; updated_at: string };
    return { deviceId: r.device_id, ciphertext: r.ciphertext, updatedAt: r.updated_at };
  });
}
