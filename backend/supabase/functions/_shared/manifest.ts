// Pure, dependency-free logic for the `sync` manifest exchange described in
// backend/PROTOCOL.md. Kept free of Supabase/Deno-only APIs (no `Deno.serve`,
// no database client) so it can be unit tested directly with `deno test`
// and so `sync/index.ts` stays a thin wiring layer around it: parse the
// request, call into here, call into db.ts, respond.

/** The nine document kinds the protocol recognizes. Anything else is a
 * bug on the client (a new kind must be added here and in the migration's
 * CHECK constraint together, never just one side). `website` is the one
 * kind never uploaded by the client at all -- it is written directly by
 * `discover-websites/index.ts` for a course's own crawled site (see
 * PROTOCOL.md's course-website section) -- but it still has to be a
 * recognized `DocumentKind` here so a `website` row reads back through
 * `documentRowToWire`/the manifest diff exactly like any other document.
 * `ed` (Ed Discussion announcements, pinned threads and staff posts, see
 * docs/ED_DISCUSSION.md) is uploaded by the client like `announcement`,
 * is content only, and is never profile input (`PROFILE_RELEVANT_KINDS`
 * below and `selectProfileInput` in profile.ts both leave it out).
 * `file` (text the Chrome extension extracted from a Canvas File, see
 * docs/CHROME_EXTENSION.md) is accepted on upload from any client but is
 * only ever *sent* to a client whose manifest request lists it in
 * `acceptsKinds` (`filterByAcceptedKinds` below), and is likewise never
 * profile input. */
export type DocumentKind =
  | "home"
  | "syllabus"
  | "assignment"
  | "announcement"
  | "module"
  | "page"
  | "website"
  | "ed"
  | "file";

const DOCUMENT_KINDS: readonly DocumentKind[] = [
  "home",
  "syllabus",
  "assignment",
  "announcement",
  "module",
  "page",
  "website",
  "ed",
  "file",
];

function isDocumentKind(value: unknown): value is DocumentKind {
  return typeof value === "string" && (DOCUMENT_KINDS as readonly string[]).includes(value);
}

/** Two classes of document kind, and the rules differ because who may speak
 * for the pool differs.
 *
 * A *census* kind (`home`, `syllabus`, `assignment`, `module`, `page`,
 * `website`, `file`) is a thing a course has exactly one of, the same for
 * every enrolled student: one student's complete fetch is the truth, so the
 * upload step's complete-set rule ("live rows of a fully-synced course that
 * the client did not list are gone") is right for it.
 *
 * A *window* kind (`announcement`, `ed`) is a stream. Each client fetched a
 * window of it: the phone asks Canvas for the last 60 days, the extension
 * for whatever it reached, a student not on Ed fetched none of it, and a
 * client whose announcements request failed fetched nothing and still
 * reports the course "fully synced". Treating any one client's list as the
 * truth would let it mark classmates' pooled posts gone, so a window kind is
 * only ever upserted by an upload, never retired by one. The wrong fix is to
 * keep the complete-set rule and make clients "more careful": the failure is
 * a client that does not know it was short.
 *
 * With nothing retiring them, a window kind needs another way out, or a
 * deleted post stays pooled forever: rows older than
 * `WINDOW_KIND_MAX_AGE_DAYS` are simply never served (see
 * `windowAgeOutFilter`). */
export const WINDOW_KINDS: readonly DocumentKind[] = ["announcement", "ed"];

export function isWindowKind(kind: string): boolean {
  return (WINDOW_KINDS as readonly string[]).includes(kind);
}

/** A window-kind row whose `coalesce(updated_at, fetched_at)` is older than
 * this is never served by `sync` (manifest or upload snapshot) and may be
 * deleted by a later cleanup; nothing deletes it today. 120 days is the
 * window the phone itself applies to Ed posts (`EdIngestion.defaultMaxAge`),
 * and for Ed `updated_at` is the thread's last activity, so a thread people
 * are still replying to stays. For an announcement `updated_at` is the post
 * time. */
export const WINDOW_KIND_MAX_AGE_DAYS = 120;

/** The most window-kind rows of one course a manifest hands a client in
 * `download`, newest first. A term is 30-60 per class, so this is slack, not
 * a squeeze; it exists so one pathological course cannot make a manifest
 * response arbitrarily large. `serverManifest` still lists every row, so the
 * client does not re-upload the ones it was not sent. */
export const MAX_WINDOW_DOWNLOAD_PER_COURSE = 150;

const DAY_MS = 86_400_000;

/** The PostgREST `or` expression that keeps a row if it is not a window kind
 * or is a window kind newer than the cutoff. `updated_at` is nullable, so a
 * window row with none falls back to `fetched_at` in the second clause (a
 * single `updated_at.gte` would silently drop every such row, because a null
 * compares as unknown). `now` is a parameter, never read here: the handlers
 * pass theirs, so a test can pin the exact string. An ISO string from
 * `toISOString()` ends in `Z`, so it needs no URL or `or` quoting (a `+`
 * offset would). */
export function windowAgeOutFilter(now: Date): string {
  const cutoff = new Date(now.getTime() - WINDOW_KIND_MAX_AGE_DAYS * DAY_MS).toISOString();
  const kinds = WINDOW_KINDS.join(",");
  return `kind.not.in.(${kinds}),updated_at.gte.${cutoff},and(updated_at.is.null,fetched_at.gte.${cutoff})`;
}

/** Keeps at most `max` window-kind documents per course, newest by
 * `updatedAt ?? fetchedAt` (ties broken by id so the cut is deterministic),
 * and every non-window document. Order of the input is preserved. */
export function capWindowDocuments<
  T extends { id: string; kind?: string; courseID?: string; updatedAt?: string | null; fetchedAt?: string },
>(docs: T[], max: number): T[] {
  const stamp = (doc: T): number => {
    const ms = Date.parse(doc.updatedAt ?? doc.fetchedAt ?? "");
    return Number.isNaN(ms) ? 0 : ms;
  };
  const byCourse = new Map<string, T[]>();
  for (const doc of docs) {
    if (doc.kind === undefined || !isWindowKind(doc.kind)) continue;
    const key = doc.courseID ?? "";
    const list = byCourse.get(key);
    if (list) list.push(doc);
    else byCourse.set(key, [doc]);
  }
  const dropped = new Set<string>();
  for (const list of byCourse.values()) {
    if (list.length <= max) continue;
    list.sort((a, b) => stamp(b) - stamp(a) || (a.id < b.id ? -1 : a.id > b.id ? 1 : 0));
    for (const doc of list.slice(max)) dropped.add(doc.id);
  }
  return dropped.size === 0 ? docs : docs.filter((doc) => !dropped.has(doc.id));
}

// Only the kinds a course's "shape" -- its syllabus, its home page, its
// static pages, and now its own crawled website -- count toward profile
// staleness. Assignments and announcements change constantly (a new
// announcement posts every week) and re-extracting a profile every time
// one changes would be both wasteful and wrong: the profile is meant to
// capture grading weights, office hours, policies -- things that live on
// the pages the protocol lists here, not on a Tuesday's reminder email.
const PROFILE_RELEVANT_KINDS: ReadonlySet<DocumentKind> = new Set([
  "syllabus",
  "home",
  "page",
  "website",
]);

export const MAX_TEXT_LENGTH = 200_000;

export interface CourseSummaryWire {
  courseID: string;
  code: string;
  name: string;
  url?: string;
  term?: string;
  sectionIDs?: string[];
  /** The Canvas SIS section number this specific Canvas course *site*
   *  syncs under (Penn Labs' section-id suffix, e.g. "401" for
   *  "PHYS-0151-401") -- distinct from `sectionIDs` above, which is a
   *  student's own per-enrollment list merged onto `enrollments`. This one
   *  describes the site itself: a Canvas course code can be split across
   *  more than one Canvas site (PHYS 0151's lecture and lab are separate
   *  sites), and `section` combined with the course's resolved
   *  `catalog_code` is what `_shared/catalog.ts`'s `activityForSection`
   *  uses to tell a lecture site's `courses` row from a lab site's row
   *  sharing the same `code`. See the `20260908090000_course_section.sql`
   *  migration and PROTOCOL.md's multi-site paragraph. Validated to at
   *  most 8 characters matching `^[0-9A-Za-z]{1,8}$` -- generous enough
   *  for every real Penn section number (typically 3 digits) while
   *  bounding what a malformed or malicious client can push into a column
   *  with no length constraint of its own. */
  section?: string;
}

/** `CourseSummaryWire.section`'s validation pattern -- see that field's
 *  doc comment. Exported so `catalog.test.ts`/`manifest.test.ts` can
 *  assert against it directly rather than duplicating the literal. */
export const SECTION_PATTERN = /^[0-9A-Za-z]{1,8}$/;

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
  const section = optionalString(raw, "section");
  if (section !== undefined && !SECTION_PATTERN.test(section)) {
    throw new ManifestValidationError(`invalid section "${section}"`);
  }
  return {
    courseID: requireString(raw, "courseID"),
    code: requireString(raw, "code"),
    name: requireString(raw, "name"),
    url: optionalString(raw, "url"),
    term: optionalString(raw, "term"),
    sectionIDs: optionalStringArray(raw, "sectionIDs"),
    section,
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

/** Where on Canvas the client found a link -- carried through for
 * provenance/debugging only; `_shared/websites.ts`'s `candidateFromLink`
 * scoring (code match, "course site" wording, `.upenn.edu` host) does not
 * currently vary by it. Kept as a closed set here, matching `DocumentKind`
 * above, rather than an open string, so a client typo produces a 400
 * instead of a silently-uncategorized row. */
export type LinkOrigin = "page" | "assignment" | "module" | "syllabus";

const LINK_ORIGINS: readonly LinkOrigin[] = ["page", "assignment", "module", "syllabus"];

function isLinkOrigin(value: unknown): value is LinkOrigin {
  return typeof value === "string" && (LINK_ORIGINS as readonly string[]).includes(value);
}

/** One link the client found while extracting course material from
 * Canvas -- the raw material `_shared/websites.ts`'s `candidateFromLink`
 * scores into a `course_websites` candidate row. See PROTOCOL.md's
 * course-website section for the wire shape and `sync/index.ts`'s upload
 * step for how these become candidates. */
export interface LinkWire {
  courseID: string;
  href: string;
  text: string;
  origin: LinkOrigin;
}

/** Matches the brief's "href <= 2048 chars" cap -- long enough for any
 * real URL a Canvas page would ever contain, short enough that a
 * pathological or malicious href can't be used to smuggle a large payload
 * into a table with no length constraint of its own on `url`. */
export const MAX_LINK_HREF_LENGTH = 2048;

export function validateLink(raw: unknown): LinkWire {
  if (!isRecord(raw)) {
    throw new ManifestValidationError("link entry must be an object");
  }
  const courseID = requireString(raw, "courseID");
  const href = requireString(raw, "href");
  if (href.length > MAX_LINK_HREF_LENGTH) {
    throw new ManifestValidationError(`link href exceeds ${MAX_LINK_HREF_LENGTH} characters`);
  }
  const text = optionalString(raw, "text") ?? "";
  const originRaw = raw["origin"];
  if (!isLinkOrigin(originRaw)) {
    throw new ManifestValidationError(`unknown link origin "${String(originRaw)}"`);
  }
  return { courseID, href, text, origin: originRaw };
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

  // Cleaned after the cut, so a surrogate pair the cut splits is mended too.
  const text = storableText(requireString(raw, "text").slice(0, MAX_TEXT_LENGTH));
  if (text.length === 0) throw new ManifestValidationError(`expected non-empty string field "text"`);
  const url = optionalString(raw, "url");

  return {
    id,
    courseID,
    course: storableText(course),
    kind: kindRaw,
    sourceID,
    title: storableText(title),
    url: url === undefined ? undefined : storableText(url),
    text,
    updatedAt: optionalString(raw, "updatedAt"),
    fetchedAt,
    contentHash,
    dueAt: optionalString(raw, "dueAt"),
    pointsPossible: optionalNumber(raw, "pointsPossible"),
  };
}

/** Text Postgres can store. A NUL (`\u0000`) or a lone UTF-16 surrogate in
 * a string the upsert sends makes Postgres refuse the whole statement
 * ("unsupported Unicode escape sequence"), which used to surface as a 500
 * for the entire upload batch, not a per-document `rejected` entry: on
 * 2026-10-27 one PDF whose extracted text held NULs failed 200 documents
 * at once. Cleaned rather than rejected, because the rest of such a
 * document is real course material. The client's `contentHash` is kept as
 * sent: it is only compared with the same client's next hash, and that
 * client hashes the same uncleaned text again, so nothing re-uploads in a
 * loop. A lone surrogate becomes U+FFFD. */
export function storableText(s: string): string {
  return s
    .replace(/\u0000/g, "")
    .replace(/[\ud800-\udbff](?![\udc00-\udfff])|(?<![\ud800-\udbff])[\udc00-\udfff]/g, "\ufffd");
}

export interface RejectedDocument {
  /** The document's own `id` when it had one, else "". */
  id: string;
  reason: string;
}

/** Validates an upload batch one document at a time. A Canvas announcement
 * can have an empty title or an image-only body, which `validateDocument`
 * rightly refuses; but if that threw out of the batch, one such post would
 * 500 the whole request, and the client would resend the same batch (with
 * the same post) forever. So each failure is collected and reported in the
 * response's `rejected`, and the rest of the batch goes through. Only
 * `ManifestValidationError` is caught: anything else is a bug and stays
 * loud. `validateDocument` itself keeps throwing, which its tests pin. */
export function validateDocuments(raw: unknown[]): { documents: CourseDocumentWire[]; rejected: RejectedDocument[] } {
  const documents: CourseDocumentWire[] = [];
  const rejected: RejectedDocument[] = [];
  for (const entry of raw) {
    try {
      documents.push(validateDocument(entry));
    } catch (err) {
      if (!(err instanceof ManifestValidationError)) throw err;
      const id = isRecord(entry) && typeof entry["id"] === "string" ? entry["id"] : "";
      rejected.push({ id, reason: err.message });
    }
  }
  return { documents, rejected };
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
export function diffManifest<
  T extends { id: string; contentHash: string; kind?: string; courseID?: string; updatedAt?: string | null; fetchedAt?: string },
>(
  clientStubs: DocumentStub[],
  serverDocs: T[],
  options: { maxWindowPerCourse?: number } = {},
): { download: T[]; serverManifest: DocumentStub[] } {
  const clientHashByID = new Map<string, string>();
  for (const stub of clientStubs) {
    clientHashByID.set(stub.id, stub.contentHash);
  }

  // The cap applies to what is *sent*, never to what is *listed*: listing
  // every row in `serverManifest` is what tells the client the server
  // already has the rest, so it does not upload them again. Capping the
  // list too would make every client re-upload the same old posts on every
  // sync.
  const sendable = options.maxWindowPerCourse === undefined
    ? serverDocs
    : capWindowDocuments(serverDocs, options.maxWindowPerCourse);
  const download = sendable.filter((doc) => clientHashByID.get(doc.id) !== doc.contentHash);
  const serverManifest = serverDocs.map((doc) => ({ id: doc.id, contentHash: doc.contentHash }));

  return { download, serverManifest };
}

/** Who is talking to `sync`. Absent on the wire means `phone`: every
 * shipped build predates the field, so absence must keep meaning what it
 * always meant. */
export type SyncClient = "phone" | "extension";

/** `client` on a sync request. Anything other than absent/null, "phone" or
 * "extension" is refused rather than defaulted: a typo silently becoming
 * "phone" would make an extension's complete-set report retire only phone
 * rows, and silently becoming "extension" would do the reverse. */
export function parseSyncClient(raw: unknown): SyncClient {
  if (raw === undefined || raw === null) return "phone";
  if (raw === "phone" || raw === "extension") return raw;
  throw new ManifestValidationError(`unknown client "${String(raw)}"`);
}

/** Kinds only a client that says it understands them is sent. `file`
 * because `CourseDocument.Kind` on the phone is a strict Codable enum: one
 * unknown kind in `download` fails the whole manifest decode on every
 * build in the field. The wrong fix would be to gate by client name: a new
 * phone build and the extension both want `file`, an old phone does not,
 * and only the client knows which it is. */
export const CAPABILITY_GATED_KINDS: readonly DocumentKind[] = ["file"];

const MAX_ACCEPTS_KINDS = 32;
const MAX_ACCEPTS_KIND_LENGTH = 32;

/** `acceptsKinds` on a manifest request. Absent means "the kinds that
 * existed before this field", i.e. the empty list of extras. Unknown
 * strings are kept and ignored (a newer client may list kinds this server
 * has never heard of); only the shape and size are validated. */
export function parseAcceptsKinds(raw: unknown): string[] {
  if (raw === undefined || raw === null) return [];
  if (!Array.isArray(raw) || raw.length > MAX_ACCEPTS_KINDS ||
    raw.some((k) => typeof k !== "string" || k.length > MAX_ACCEPTS_KIND_LENGTH)) {
    throw new ManifestValidationError(`"acceptsKinds" must be an array of at most ${MAX_ACCEPTS_KINDS} short strings`);
  }
  return raw as string[];
}

/** Drops capability-gated documents the client did not opt into. Applied
 * to the server's live set *before* `diffManifest`, so a withheld document
 * is absent from both `download` and `serverManifest` -- a `serverManifest`
 * entry the client has no row for would read as "delete or re-upload me". */
export function filterByAcceptedKinds<T extends { kind: string }>(docs: T[], acceptsKinds: readonly string[]): T[] {
  const gated = CAPABILITY_GATED_KINDS.filter((kind) => !acceptsKinds.includes(kind));
  if (gated.length === 0) return docs;
  return docs.filter((doc) => !(gated as readonly string[]).includes(doc.kind));
}

/** Which rows the complete-set rule may retire for a given reporting
 * client: the phone only retires rows the phone collected (it cannot see
 * announcements, pages past its cap or files, so their absence from its
 * list means nothing); the extension sees everything the phone can and more,
 * so its list is authoritative for all collectors (`undefined` = no
 * restriction). */
export function retirableCollector(client: SyncClient): "phone" | undefined {
  return client === "phone" ? "phone" : undefined;
}

/** In-memory form of the same rule, for tests and any caller that already
 * holds rows; `db.selectLiveDocumentIDsForCourse` applies it in SQL. Window
 * kinds are never retirable by anyone (see `WINDOW_KINDS`), the extension
 * included: its window is no more the whole stream than the phone's. */
export function liveIDsRetirableBy<T extends { id: string; kind: string; collector?: string }>(
  liveRows: T[],
  client: SyncClient,
): string[] {
  const only = retirableCollector(client);
  return liveRows
    .filter((row) => !isWindowKind(row.kind))
    .filter((row) => (row.collector ?? "phone") !== "server")
    .filter((row) => only === undefined || (row.collector ?? "phone") === only)
    .map((row) => row.id);
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
