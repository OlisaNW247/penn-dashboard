// Pure, dependency-free logic for the `sync` manifest exchange described in
// backend/PROTOCOL.md. Kept free of Supabase/Deno-only APIs (no `Deno.serve`,
// no database client) so it can be unit tested directly with `deno test`
// and so `sync/index.ts` stays a thin wiring layer around it: parse the
// request, call into here, call into db.ts, respond.

/** The six document kinds the protocol recognizes. Anything else is a bug
 * on the client (a new kind must be added here and in the migration's
 * CHECK constraint together, never just one side). */
export type DocumentKind =
  | "home"
  | "syllabus"
  | "assignment"
  | "announcement"
  | "module"
  | "page";

const DOCUMENT_KINDS: readonly DocumentKind[] = [
  "home",
  "syllabus",
  "assignment",
  "announcement",
  "module",
  "page",
];

function isDocumentKind(value: unknown): value is DocumentKind {
  return typeof value === "string" && (DOCUMENT_KINDS as readonly string[]).includes(value);
}

// Only the kinds a course's "shape" -- its syllabus, its home page, its
// static pages -- live in count toward profile staleness. Assignments and
// announcements change constantly (a new announcement posts every week)
// and re-extracting a profile every time one changes would be both wasteful
// and wrong: the profile is meant to capture grading weights, office hours,
// policies -- things that live on the pages the protocol lists here, not
// on a Tuesday's reminder email.
const PROFILE_RELEVANT_KINDS: ReadonlySet<DocumentKind> = new Set([
  "syllabus",
  "home",
  "page",
]);

export const MAX_TEXT_LENGTH = 200_000;

export interface CourseSummaryWire {
  courseID: string;
  code: string;
  name: string;
  url?: string;
  term?: string;
  sectionIDs?: string[];
}

export interface DocumentStub {
  id: string;
  contentHash: string;
}

export interface CourseDocumentWire {
  id: string;
  courseID: string;
  course: string;
  kind: DocumentKind;
  sourceID: string;
  title: string;
  url?: string;
  text: string;
  updatedAt?: string;
  fetchedAt: string;
  contentHash: string;
  dueAt?: string;
  pointsPossible?: number;
  // Deliberately not a declared field: PROTOCOL.md principle 2 says
  // `submitted` is student-specific and must never reach the server.
  // `validateDocument` strips it from the raw input rather than the type
  // system merely omitting it, because omitting it from the type would
  // silently let it ride along inside an object built with `...spread`
  // from client JSON.
}

export interface FullySyncedCourse {
  courseID: string;
  documentIDs: string[];
}

/** Thrown by the validators below; `sync/index.ts` catches this and turns
 * it into a 400 rather than letting a malformed request reach the database
 * or crash the function. */
export class ManifestValidationError extends Error {
  constructor(message: string) {
    super(message);
    this.name = "ManifestValidationError";
  }
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function requireString(record: Record<string, unknown>, key: string): string {
  const value = record[key];
  if (typeof value !== "string" || value.length === 0) {
    throw new ManifestValidationError(`expected non-empty string field "${key}"`);
  }
  return value;
}

function optionalString(record: Record<string, unknown>, key: string): string | undefined {
  const value = record[key];
  if (value === undefined || value === null) return undefined;
  if (typeof value !== "string") {
    throw new ManifestValidationError(`expected string field "${key}" when present`);
  }
  return value;
}

function optionalNumber(record: Record<string, unknown>, key: string): number | undefined {
  const value = record[key];
  if (value === undefined || value === null) return undefined;
  if (typeof value !== "number" || Number.isNaN(value)) {
    throw new ManifestValidationError(`expected number field "${key}" when present`);
  }
  return value;
}

function optionalStringArray(record: Record<string, unknown>, key: string): string[] | undefined {
  const value = record[key];
  if (value === undefined || value === null) return undefined;
  if (!Array.isArray(value) || value.some((item) => typeof item !== "string")) {
    throw new ManifestValidationError(`expected string array field "${key}" when present`);
  }
  return value as string[];
}

function requireStringArray(record: Record<string, unknown>, key: string): string[] {
  const value = optionalStringArray(record, key);
  if (value === undefined) {
    throw new ManifestValidationError(`expected string array field "${key}"`);
  }
  return value;
}

export function validateCourse(raw: unknown): CourseSummaryWire {
  if (!isRecord(raw)) {
    throw new ManifestValidationError("course entry must be an object");
  }
  return {
    courseID: requireString(raw, "courseID"),
    code: requireString(raw, "code"),
    name: requireString(raw, "name"),
    url: optionalString(raw, "url"),
    term: optionalString(raw, "term"),
    sectionIDs: optionalStringArray(raw, "sectionIDs"),
  };
}

export function validateDocumentStub(raw: unknown): DocumentStub {
  if (!isRecord(raw)) {
    throw new ManifestValidationError("document stub must be an object");
  }
  return {
    id: requireString(raw, "id"),
    contentHash: requireString(raw, "contentHash"),
  };
}

export function validateFullySyncedCourse(raw: unknown): FullySyncedCourse {
  if (!isRecord(raw)) {
    throw new ManifestValidationError("fullySyncedCourse entry must be an object");
  }
  return {
    courseID: requireString(raw, "courseID"),
    documentIDs: requireStringArray(raw, "documentIDs"),
  };
}

/** Parses the client-computed `"{kind}:{courseID}:{sourceID}"` id format.
 * `sourceID` is allowed to itself contain colons (Canvas ids don't, but this
 * keeps the parser from being a landmine if that ever changes) -- only the
 * first two colons are structural. */
export function parseDocumentID(
  id: string,
): { kind: string; courseID: string; sourceID: string } | null {
  const firstColon = id.indexOf(":");
  if (firstColon < 0) return null;
  const secondColon = id.indexOf(":", firstColon + 1);
  if (secondColon < 0) return null;
  const kind = id.slice(0, firstColon);
  const courseID = id.slice(firstColon + 1, secondColon);
  const sourceID = id.slice(secondColon + 1);
  if (!kind || !courseID || !sourceID) return null;
  return { kind, courseID, sourceID };
}

/** Validates and normalizes one uploaded document. Per PROTOCOL.md and the
 * migration's schema, `submitted` -- a per-student fact -- must never
 * persist; rather than reject a request that carries it (a reasonable
 * client bug, e.g. spreading a local model object), we drop it and keep
 * going, since dropping it is exactly as safe as the field never having
 * been sent and rejecting would be pure friction for zero security
 * benefit (the column doesn't exist server-side to receive it either
 * way). What *is* rejected outright is an id that doesn't match its own
 * kind/courseID/sourceID -- that's not a stray field, it's the row's own
 * identity being inconsistent, and silently "fixing" it would let a
 * document be attributed to the wrong course. */
export function validateDocument(raw: unknown): CourseDocumentWire {
  if (!isRecord(raw)) {
    throw new ManifestValidationError("document entry must be an object");
  }

  // Strip `submitted` before doing anything else with the object, so it
  // can never leak through into a later `{...raw}` spread by a future
  // edit to this function.
  if ("submitted" in raw) {
    delete raw["submitted"];
  }

  const id = requireString(raw, "id");
  const courseID = requireString(raw, "courseID");
  const course = requireString(raw, "course");
  const kindRaw = raw["kind"];
  if (!isDocumentKind(kindRaw)) {
    throw new ManifestValidationError(`unknown document kind "${String(kindRaw)}"`);
  }
  const sourceID = requireString(raw, "sourceID");
  const title = requireString(raw, "title");
  const fetchedAt = requireString(raw, "fetchedAt");
  const contentHash = requireString(raw, "contentHash");

  const expectedID = `${kindRaw}:${courseID}:${sourceID}`;
  if (id !== expectedID) {
    throw new ManifestValidationError(
      `document id "${id}" does not match "${expectedID}" derived from its own kind/courseID/sourceID`,
    );
  }

  const text = requireString(raw, "text").slice(0, MAX_TEXT_LENGTH);

  return {
    id,
    courseID,
    course,
    kind: kindRaw,
    sourceID,
    title,
    url: optionalString(raw, "url"),
    text,
    updatedAt: optionalString(raw, "updatedAt"),
    fetchedAt,
    contentHash,
    dueAt: optionalString(raw, "dueAt"),
    pointsPossible: optionalNumber(raw, "pointsPossible"),
  };
}

/** Step 1 of sync: compares what the client already has (`clientStubs`)
 * against every live server document for the courses in play
 * (`serverDocs`, expected pre-filtered to `gone_at is null`) and reports
 * both directions -- `serverManifest` for the client to diff against on
 * its own upload, `download` for documents the server has that the client
 * doesn't (new id, or same id with a different hash meaning it changed
 * server-side since the client last saw it). A document the client
 * already has with a matching hash is intentionally left out of
 * `download` -- re-sending unchanged text is exactly the bandwidth this
 * exchange exists to avoid. */
export function diffManifest<T extends { id: string; contentHash: string }>(
  clientStubs: DocumentStub[],
  serverDocs: T[],
): { download: T[]; serverManifest: DocumentStub[] } {
  const clientHashByID = new Map<string, string>();
  for (const stub of clientStubs) {
    clientHashByID.set(stub.id, stub.contentHash);
  }

  const download = serverDocs.filter((doc) => clientHashByID.get(doc.id) !== doc.contentHash);
  const serverManifest = serverDocs.map((doc) => ({ id: doc.id, contentHash: doc.contentHash }));

  return { download, serverManifest };
}

/** Step 2 of sync: for a fully-synced course, any id that is currently
 * live server-side but absent from the client's complete id list for that
 * course is a document the client no longer sees in Canvas at all, and
 * should be marked gone -- the server-side mirror of the on-device
 * ledger's `isGoneFromFeed` aging. */
export function goneIDs(liveIDsForCourse: string[], uploadedIDs: string[]): string[] {
  const uploaded = new Set(uploadedIDs);
  return liveIDsForCourse.filter((id) => !uploaded.has(id));
}

/** Step 2 of sync: which courses need `profile_stale` set, given the
 * before/after `(id -> contentHash)` state of that course's documents.
 * Only `syllabus | home | page` ids participate (see
 * `PROFILE_RELEVANT_KINDS` above); an id appearing, disappearing, or
 * changing hash within that kind set marks its course. `kindOf` resolves
 * an id to its `DocumentKind` -- callers pass a lookup built from the
 * batch of documents already in hand, rather than this function trying to
 * parse the kind back out of the id itself (which would silently produce
 * garbage for a malformed id that validation should have already
 * rejected). */
export function profileStaleCourses(
  before: Map<string, string>,
  after: Map<string, string>,
  kindOf: (id: string) => DocumentKind | undefined,
): Set<string> {
  const stale = new Set<string>();
  const allIDs = new Set<string>([...before.keys(), ...after.keys()]);

  for (const id of allIDs) {
    const kind = kindOf(id);
    if (kind === undefined || !PROFILE_RELEVANT_KINDS.has(kind)) continue;

    const beforeHash = before.get(id);
    const afterHash = after.get(id);
    if (beforeHash === afterHash) continue;

    const parsed = parseDocumentID(id);
    if (parsed) stale.add(parsed.courseID);
  }

  return stale;
}

const DEFAULT_FRESH_WINDOW_MINUTES = 60;

function readFreshWindowMinutes(): number {
  const raw = Deno.env.get("SYNC_FRESH_WINDOW_MINUTES");
  if (!raw) return DEFAULT_FRESH_WINDOW_MINUTES;
  const parsed = Number(raw);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : DEFAULT_FRESH_WINDOW_MINUTES;
}

/** Evaluated once at module load, matching every other env-derived
 * constant in this codebase's Deno functions -- `Deno.env.get` inside a
 * hot path would be a needless syscall per request for a value that only
 * changes with a redeploy. */
export const FRESH_WINDOW_MS = readFreshWindowMinutes() * 60_000;

export interface CourseFreshnessInput {
  courseID: string;
  lastFullSyncAt: string | Date | null;
}

/** `coursesFresh` in the manifest response: courses whose last full sync
 * is recent enough that the client shouldn't bother re-fetching Canvas for
 * them this run. `now` is a parameter rather than `new Date()` inside the
 * function specifically so tests can pin it and hit the exact boundary --
 * see the byte-stable-prefix lesson elsewhere in this codebase about
 * functions that read the clock silently. */
export function freshCourses(courses: CourseFreshnessInput[], now: Date): string[] {
  const nowMs = now.getTime();
  return courses
    .filter((course) => {
      if (course.lastFullSyncAt === null) return false;
      const lastSyncMs = new Date(course.lastFullSyncAt).getTime();
      if (Number.isNaN(lastSyncMs)) return false;
      return nowMs - lastSyncMs < FRESH_WINDOW_MS;
    })
    .map((course) => course.courseID);
}
