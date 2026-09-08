// Pure logic for the course-catalog layer described in PROTOCOL.md's
// "Catalog" section: turning a Canvas course code into the code Penn Labs'
// public Penn Courses API keys on, fetching and parsing that API's
// response, and rendering the result into the byte-stable text block
// `ask/index.ts` inserts into the prompt. Nothing here touches Supabase --
// `sync/index.ts` calls `fetchCatalogCourse` and hands the result to
// `_shared/db.ts` for the snake_case upsert, and `ask/index.ts` does the
// mirror-image read through `db.ts` and passes the rows here to
// `structureBlock`. Keeping the parsing and rendering pure is what lets
// `catalog.test.ts` exercise every branch (including the malformed-input
// ones) without a network call or a live Postgres.
//
// The problem this whole file exists to solve: a single Canvas course site
// can bundle more than one registrar course component (PHYS 0151 is one
// Canvas site containing a 1.0 CU lecture and a 0.5 CU lab), and nothing
// before this told the assistant that -- so a question about "the class"
// could get answered from whichever component's syllabus text happened to
// be retrieved. `components` below is the fact that fixes that.

/** One registrar activity group -- every section of a given `activity`
 *  code (Penn Labs' short strings: "LEC", "LAB", "REC", ...) folded into a
 *  single entry. `credits` is the *component's* credit units: Penn Labs
 *  states credits per section, not per component, so this is the max
 *  across the group's sections (a component is never partially worth
 *  credit depending which of its own sections you're in) -- and `null`
 *  when no section in the group states a credits value at all, which
 *  `structureBlock` below is careful never to paper over with an assumed
 *  number. */
export interface CatalogComponent {
  activity: string;
  label: string;
  sectionCount: number;
  credits: number | null;
  sectionIDs: string[];
}

/** Mirrors `catalog_courses` (see the `20260907120000_catalog.sql`
 *  migration) but in the camelCase this codebase's pure modules use
 *  throughout -- `_shared/db.ts` does the snake_case mapping on the way in
 *  and out of Postgres, the same split it already keeps for
 *  `CourseDocumentWire`/`CourseDocumentRow`. Review scores
 *  (course_quality, instructor_quality, difficulty, work_required) are
 *  Penn Labs' aggregated Penn Course Review data, not the registrar's, and
 *  are deliberately absent from this type -- there is no field to
 *  accidentally carry them through. */
export interface CatalogCourseRow {
  catalogCode: string;
  semester: string;
  title: string;
  description: string;
  credits: number | null;
  prerequisites: string;
  crosslistings: string[];
  gradeModes: string[];
  attributes: unknown[];
  components: CatalogComponent[];
  source: string;
  fetchedAt: string;
}

// ---------------------------------------------------------------------
// catalogCode: Canvas course code -> Penn Labs course code
// ---------------------------------------------------------------------

// Deliberately permissive on the department-code length (2-5 letters --
// Penn has both short ones like "CIS" and longer ones like "URBS") and on
// whether the input separates department from number with a space (what
// `CourseCode.parse` on the iOS side produces, e.g. "PHYS 0151") or a dash
// (what a caller re-normalizing an already-dashed code would pass), so this
// function is safe to call on either shape. A trailing letter suffix
// ("PHYS 0151A") is allowed since some Penn courses use one, but is not
// itself replaced -- only the department/number separator is.
const CATALOG_CODE_PATTERN = /^[A-Z]{2,5}[ -]\d{3,4}[A-Z]?$/;

/**
 * "PHYS 0151" -> "PHYS-0151", matching the path segment Penn Labs' course
 * endpoint expects. Trims surrounding whitespace, collapses internal
 * whitespace runs to a single separator, and uppercases before matching --
 * a Canvas course code's casing and spacing are not guaranteed uniform
 * (see `CourseCode.parse`'s own tolerance for the same reason). Returns
 * `undefined` for anything that doesn't look like a Penn course code at
 * all (a raw Canvas descriptor that failed to parse into a code, a lab
 * section's own free-text title, ...) rather than guessing -- exactly the
 * "a failed parse falls back to the raw descriptor rather than a key
 * nothing else agrees with" discipline `CourseCode.parse` already follows
 * on the client.
 */
export function catalogCode(fromCourseCode: string): string | undefined {
  const normalized = fromCourseCode.trim().toUpperCase().replace(/\s+/g, " ");
  if (!CATALOG_CODE_PATTERN.test(normalized)) return undefined;
  return normalized.replace(/[ -]/, "-");
}

// ---------------------------------------------------------------------
// parsePennLabsCourse
// ---------------------------------------------------------------------

interface RawSection {
  id: string;
  activity: string;
  credits: number | null;
}

/** Penn Labs' short activity codes mapped to the human word this file's
 *  `structureBlock` and the stored `components` use, in the display order
 *  a course's components are rendered in -- lecture first, then lab, is
 *  the order a student thinks of "the class", matching the example in the
 *  catalog delegation brief. An activity code not in this table (Penn
 *  Labs has a long tail of rarely-used ones) falls back to the raw code
 *  itself as its label and sorts after every known one, alphabetically. */
const ACTIVITY_LABELS: ReadonlyMap<string, string> = new Map([
  ["LEC", "Lecture"],
  ["LAB", "Lab"],
  ["REC", "Recitation"],
  ["SEM", "Seminar"],
  ["STU", "Studio"],
  ["IND", "Independent Study"],
  ["ONL", "Online"],
  ["HYB", "Hybrid"],
  ["CLN", "Clinic"],
  ["FLD", "Field Work"],
  ["PRC", "Practicum"],
]);

const ACTIVITY_ORDER: readonly string[] = [...ACTIVITY_LABELS.keys()];

function activityLabel(activity: string): string {
  return ACTIVITY_LABELS.get(activity) ?? activity;
}

function activitySortKey(activity: string): string {
  const index = ACTIVITY_ORDER.indexOf(activity);
  // Known activities sort by their table position (zero-padded so it
  // precedes every unknown one lexically); unknown activities fall back to
  // sorting alphabetically by their own code, after every known activity.
  return index >= 0 ? `0${String(index).padStart(3, "0")}` : `1${activity}`;
}

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function asString(value: unknown, fallback = ""): string {
  return typeof value === "string" ? value : fallback;
}

function asNumberOrNull(value: unknown): number | null {
  return typeof value === "number" && Number.isFinite(value) ? value : null;
}

function asStringArray(value: unknown): string[] {
  if (!Array.isArray(value)) return [];
  return value.filter((item): item is string => typeof item === "string");
}

/** Reads `raw.sections` (an array of Penn Labs section objects) down to
 *  just the fields component grouping needs, dropping anything malformed
 *  rather than failing the whole course -- a single garbled section in an
 *  otherwise-fine response shouldn't take out the course's other, valid
 *  components. */
function readSections(value: unknown): RawSection[] {
  if (!Array.isArray(value)) return [];
  const sections: RawSection[] = [];
  for (const item of value) {
    if (!isRecord(item)) continue;
    const id = item["id"];
    const activity = item["activity"];
    if (typeof id !== "string" || id.length === 0) continue;
    if (typeof activity !== "string" || activity.length === 0) continue;
    sections.push({ id, activity, credits: asNumberOrNull(item["credits"]) });
  }
  return sections;
}

/** Groups sections by `activity` into the `components` this table exists
 *  to capture. A component's `credits` is the max of its sections'
 *  credits (Penn Labs states credits per section; a component with no
 *  section stating a value comes back `null` rather than a guessed
 *  number), and `sectionIDs` preserves each section's own id list order
 *  as it appeared in the response. */
function buildComponents(sections: RawSection[]): CatalogComponent[] {
  const byActivity = new Map<string, RawSection[]>();
  for (const section of sections) {
    const group = byActivity.get(section.activity);
    if (group) {
      group.push(section);
    } else {
      byActivity.set(section.activity, [section]);
    }
  }

  const components: CatalogComponent[] = [];
  for (const [activity, group] of byActivity) {
    const credits = group.reduce<number | null>((max, section) => {
      if (section.credits === null) return max;
      return max === null ? section.credits : Math.max(max, section.credits);
    }, null);
    components.push({
      activity,
      label: activityLabel(activity),
      sectionCount: group.length,
      credits,
      sectionIDs: group.map((section) => section.id),
    });
  }

  return components.sort((a, b) => activitySortKey(a.activity).localeCompare(activitySortKey(b.activity)));
}

/** `MODE`-school attributes are Penn's own encoding of a course's offered
 *  grade modes (e.g. `{ code: "QS", school: "MODE", description: "Grade
 *  Mode: Standard Lettr Grd" }`); this strips the constant "Grade Mode: "
 *  prefix so `grade_modes` holds the plain human phrase both
 *  `structureBlock` and any future direct display of it can use as-is. An
 *  attribute whose description doesn't actually carry the prefix (a Penn
 *  Labs schema change, or a stray MODE attribute that isn't grade-mode
 *  after all) is kept verbatim rather than dropped -- better to show an
 *  odd-looking entry than to silently lose a grade mode the registrar did
 *  state. */
const GRADE_MODE_PREFIX = "Grade Mode: ";

/** The registrar abbreviates inside a fixed-width field ("Standard Lettr
 *  Grd"); the model reads better English. Unknown modes pass through
 *  unchanged rather than being dropped. */
const GRADE_MODE_SPELLINGS: Record<string, string> = {
  "Standard Lettr Grd": "Standard Letter Grade",
  "Pass/Fail": "Pass/Fail",
};

function gradeModesFromAttributes(attributes: unknown[]): string[] {
  const modes: string[] = [];
  for (const attribute of attributes) {
    if (!isRecord(attribute)) continue;
    if (attribute["school"] !== "MODE") continue;
    const description = attribute["description"];
    if (typeof description !== "string" || description.length === 0) continue;
    const mode = description.startsWith(GRADE_MODE_PREFIX) ? description.slice(GRADE_MODE_PREFIX.length) : description;
    modes.push(GRADE_MODE_SPELLINGS[mode] ?? mode);
  }
  return modes;
}

/**
 * Validates and maps one Penn Labs course response
 * (`GET .../api/base/current/courses/{DEPT-NNNN}/`) into a
 * `CatalogCourseRow`. Returns `undefined` for anything that doesn't even
 * have the two fields this whole table is keyed and gated on (`id`,
 * `semester`) -- everything else (`description`, `prerequisites`,
 * `crosslistings`, ...) has a safe empty default per the migration's
 * column defaults, matching "the source material doesn't state it" being a
 * normal, expected case rather than an error, the same posture
 * `parseProfile` takes toward a model response missing an optional key.
 *
 * Review-score fields present on the real response (`course_quality`,
 * `instructor_quality`, `difficulty`, `work_required`, and the same four
 * per section) are read by nothing here and so never make it into the
 * returned row -- see the migration's and this file's own comments on why
 * that line is drawn where it is.
 */
export function parsePennLabsCourse(json: unknown): CatalogCourseRow | undefined {
  if (!isRecord(json)) return undefined;

  const catalogCodeValue = json["id"];
  const semester = json["semester"];
  if (typeof catalogCodeValue !== "string" || catalogCodeValue.length === 0) return undefined;
  if (typeof semester !== "string" || semester.length === 0) return undefined;

  const attributesRaw = Array.isArray(json["attributes"]) ? (json["attributes"] as unknown[]) : [];
  const sections = readSections(json["sections"]);

  return {
    catalogCode: catalogCodeValue,
    semester,
    title: asString(json["title"]),
    description: asString(json["description"]),
    credits: asNumberOrNull(json["credits"]),
    prerequisites: asString(json["prerequisites"]),
    crosslistings: asStringArray(json["crosslistings"]),
    gradeModes: gradeModesFromAttributes(attributesRaw),
    attributes: attributesRaw,
    components: buildComponents(sections),
    source: "penn-labs",
    fetchedAt: new Date().toISOString(),
  };
}

// ---------------------------------------------------------------------
// fetchCatalogCourse
// ---------------------------------------------------------------------

export interface FetchCatalogCourseOptions {
  /** Injected, never the global `fetch`, so `catalog.test.ts` can exercise
   *  every branch (404, timeout, malformed JSON, network failure) with a
   *  fake -- the same discipline `openrouter.ts` holds itself to and for
   *  the same reason: this container has no real network access to Penn
   *  Labs to test against. */
  fetchImpl: typeof fetch;
  catalogCode: string;
  timeoutMs: number;
}

const PENN_LABS_BASE_URL = "https://penncoursereview.com/api/base/current/courses";

/** Identifies this app to Penn Labs' operators the way any well-behaved
 *  anonymous API consumer should, per the brief -- the endpoint takes no
 *  auth and no key, but a nameless default `fetch` user agent gives Penn
 *  Labs nothing to go on if this ever needs to be throttled or contacted. */
const USER_AGENT = "LowHangingFruit/1 (student dashboard; contact in repo)";

/**
 * Fetches and parses one course from Penn Labs. Never throws -- a 404 (the
 * course code Penn Labs doesn't recognize, or isn't offered this
 * semester), a timeout, a network failure, or a response that parses as
 * JSON but not as a course all come back as `undefined`, and the caller
 * (`sync/index.ts`'s catalog refresh step) treats every one of those
 * identically: skip this course's catalog row for now, try again on the
 * next sync. That is a deliberate simplification -- a 404 and a network
 * blip are different failures with different next steps in principle, but
 * both are already tolerated by "refresh piggybacks on sync, which runs at
 * least hourly for every enrolled course" (see the migration and the sync
 * wiring), so distinguishing them here would add complexity with no
 * behavior actually depending on the distinction.
 */
export async function fetchCatalogCourse(
  options: FetchCatalogCourseOptions,
): Promise<CatalogCourseRow | undefined> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), options.timeoutMs);
  try {
    const response = await options.fetchImpl(`${PENN_LABS_BASE_URL}/${options.catalogCode}/`, {
      method: "GET",
      headers: { "User-Agent": USER_AGENT },
      signal: controller.signal,
    });
    if (!response.ok) return undefined;

    let body: unknown;
    try {
      body = await response.json();
    } catch {
      return undefined;
    }
    return parsePennLabsCourse(body);
  } catch {
    // Covers both a transport-level failure and the abort this function
    // itself triggers on timeout -- `AbortController.abort()` makes the
    // in-flight `fetch` reject, which lands here rather than needing its
    // own branch.
    return undefined;
  } finally {
    clearTimeout(timer);
  }
}

// ---------------------------------------------------------------------
// catalogIsStale
// ---------------------------------------------------------------------

const DEFAULT_MAX_AGE_DAYS = 7;

/**
 * Whether a `catalog_courses` row fetched at `fetchedAt` is old enough that
 * sync's refresh step should re-fetch it. `now` is a parameter, never
 * `new Date()` read internally, for the same testability-and-determinism
 * reason every other clock-reading function in this codebase takes `now`
 * as an argument (see `manifest.ts`'s `freshCourses`). An unparseable
 * `fetchedAt` counts as stale rather than fresh -- a corrupt timestamp
 * should trigger a re-fetch, not silently pin a row as permanently
 * up-to-date.
 */
export function catalogIsStale(
  fetchedAt: string | Date,
  now: Date,
  maxAgeDays: number = DEFAULT_MAX_AGE_DAYS,
): boolean {
  const fetchedMs = new Date(fetchedAt).getTime();
  if (Number.isNaN(fetchedMs)) return true;
  const ageMs = now.getTime() - fetchedMs;
  return ageMs > maxAgeDays * 24 * 60 * 60 * 1000;
}

// ---------------------------------------------------------------------
// structureBlock
// ---------------------------------------------------------------------

const DESCRIPTION_MAX_CHARS = 600;

function collapseWhitespace(text: string): string {
  return text.replace(/\s+/g, " ").trim();
}

/** Per-component credits are stated only when they tell the model
 *  something the course total does not. The registrar hangs the whole
 *  course's credit on the lecture section and reports 0 for an attached
 *  lab (PHYS 0151: lecture 1.5, lab 0.0, course 1.5), so echoing "0 CU
 *  each" would have the model tell a student their lab is worth nothing. */
function componentPhrase(component: CatalogComponent, courseCredits: number | null): string {
  const noun = component.sectionCount === 1 ? "section" : "sections";
  const stateCredits = component.credits !== null && component.credits > 0 && component.credits !== courseCredits;
  const creditsPhrase = stateCredits ? `, ${component.credits} CU each` : "";
  return `${component.label} (${component.sectionCount} ${noun}${creditsPhrase})`;
}

/**
 * Renders `rows` into the fixed-format text block `ask/index.ts` splices
 * into the prompt as "COURSE STRUCTURE (from the Penn registrar via Penn
 * Labs)". Byte-stable for identical input -- same discipline as
 * `prompt.ts`'s `buildMessages` and for the identical reason: this text
 * sits ahead of the per-turn user message in the cached prefix, so
 * `AssistantContextDocument`'s "never read a clock, always sort" rules
 * apply here too. Rows are sorted by `catalogCode` regardless of the
 * order the caller's Postgres query returned them in, for exactly that
 * reason.
 *
 * One paragraph per course, in this fixed field order: title and overall
 * credits, then the components sentence (omitted entirely when a course
 * has no section data at all -- there's nothing to say), then grade modes
 * (omitted when none), then prerequisites (omitted when empty, per the
 * brief), then a whitespace-collapsed, 600-character-capped description
 * (omitted when empty). A course with only a title and nothing else still
 * gets a one-sentence paragraph rather than being dropped, so its presence
 * in `courseIDs` is never silently invisible to the model.
 */
export function structureBlock(rows: CatalogCourseRow[]): string {
  if (rows.length === 0) return "";

  const sorted = [...rows].sort((a, b) => a.catalogCode.localeCompare(b.catalogCode));

  const paragraphs = sorted.map((row) => {
    const sentences: string[] = [];

    const creditsClause = row.credits !== null ? ` — ${row.credits} CU.` : ".";
    sentences.push(`${row.catalogCode} "${row.title}"${creditsClause}`);

    if (row.components.length > 0) {
      const phrases = row.components.map((component) => componentPhrase(component, row.credits)).join(", ");
      sentences.push(`Components: ${phrases}.`);
    }

    if (row.gradeModes.length > 0) {
      sentences.push(`Grade modes offered: ${row.gradeModes.join(", ")}.`);
    }

    if (row.prerequisites.trim().length > 0) {
      sentences.push(`Prerequisites: ${collapseWhitespace(row.prerequisites)}.`);
    }

    const description = collapseWhitespace(row.description).slice(0, DESCRIPTION_MAX_CHARS);
    if (description.length > 0) {
      sentences.push(`Description: ${description}${description.endsWith(".") ? "" : "."}`);
    }

    return sentences.join(" ");
  });

  return paragraphs.join("\n\n");
}
