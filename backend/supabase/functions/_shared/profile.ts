// Everything `extract-profile/index.ts` needs that doesn't itself touch the
// network or a database: the instructions sent to the model, picking which
// documents to send, parsing what comes back, and hashing the input so the
// caller knows whether it's stale. Kept here, not inline in the function,
// so all of it is testable without a live OpenRouter key or a Supabase
// project -- `profile.test.ts` drives every one of these directly.

/** Live documents of a profile-eligible kind, reduced to the columns this
 *  module reads. Matches the relevant subset of the `course_documents`
 *  table (see PROTOCOL.md and the init migration); `extract-profile`'s
 *  Supabase query selects exactly these columns. */
export interface ProfileSourceDocument {
  id: string;
  kind: "home" | "syllabus" | "assignment" | "announcement" | "module" | "page";
  title: string;
  text: string;
  content_hash: string;
}

/** Sent as the system message for the extraction call. Demands JSON-only
 *  output (no fence, no prose) so `parseProfile` doesn't have to depend on
 *  fence-stripping to succeed on a well-behaved model -- that tolerance
 *  exists as a safety net for the models that ignore the instruction, not
 *  as the expected path. */
export const PROFILE_INSTRUCTIONS: string = [
  `You extract a structured profile from a Penn course's syllabus and `
  + `course-site pages. Respond with a single JSON object and nothing else `
  + `-- no prose before or after it, no markdown code fence, no `
  + `commentary.`,

  `Use exactly these top-level keys, every one optional -- omit a key `
  + `entirely, or use null for one of its scalar fields, whenever the `
  + `source material doesn't state it. Never guess, infer, or fill in a `
  + `typical value for a Penn course; every string you emit must be a `
  + `verbatim quote or a close paraphrase of text that actually appears in `
  + `the source:\n`
  + `{ "gradingWeights": [ { "name", "percent" } ],\n`
  + `  "latePolicy": string, "attendancePolicy": string,\n`
  + `  "examDates": [ { "name", "date"?, "text" } ],\n`
  + `  "officeHours": [ { "who", "when", "where"? } ],\n`
  + `  "contacts": [ { "name", "role"?, "email"? } ],\n`
  + `  "textbooks": [ string ],\n`
  + `  "keyPolicies": [ { "topic", "text" } ],\n`
  + `  "components": [ { "name", "gradingBasis"?, "creditUnits"?, "notes"? } ],\n`
  + `  "sourceDocumentIDs": [ string ] }`,

  `"percent" is a plain number (12.5, not "12.5%"). "date" fields are ISO `
  + `8601 dates when the source gives an exact date, omitted otherwise --`
  + ` never guess a date from a vague reference like "midterm week".`,

  `"components" is for a course that is more than one thing under one `
  + `syllabus -- a lecture with a separate lab or recitation graded on its `
  + `own terms. Emit one entry per component *only* when the syllabus `
  + `itself distinguishes them (e.g. "the lab is graded pass/fail, 0.5 `
  + `CU" or "recitation attendance is 10% of the recitation grade"); a `
  + `course the syllabus never splits into parts should have no `
  + `"components" key at all, even if you happen to know from context that `
  + `its Canvas site has a lab. "name" is the component as the syllabus `
  + `names it ("Lab", "Recitation"); "gradingBasis" is a short phrase like `
  + `"Pass/Fail" or "20% of course grade" only when the syllabus states `
  + `one for that component specifically; "creditUnits" is a plain number `
  + `only when the syllabus states that component's own credit value; `
  + `"notes" is any other component-specific rule worth keeping verbatim.`,
].join("\n\n");

/**
 * Concatenates `docs` into one string for the model, syllabus first, then
 * home, then page (the priority order PROTOCOL.md specifies), stopping
 * once `maxChars` would be exceeded.
 *
 * Truncation happens at a document boundary wherever possible: adding a
 * whole document that would overflow the budget is simply skipped rather
 * than cut short, because a document sliced off mid-sentence or mid-table
 * reads worse to the model than one more lower-priority page just not
 * being included. The one exception is the very first document selected --
 * if even that alone is longer than `maxChars` (a long syllabus, most
 * likely), it is truncated rather than the whole call producing empty
 * input for a course that plainly does have a syllabus to read.
 */
export function selectProfileInput(
  docs: ProfileSourceDocument[],
  maxChars: number,
): string {
  const priority: Record<string, number> = { syllabus: 0, home: 1, page: 2 };

  const ordered = docs
    .filter((doc) => doc.kind in priority)
    .slice()
    .sort((a, b) => {
      const byKind = priority[a.kind] - priority[b.kind];
      // Ties within a kind are broken by id for determinism -- this
      // function's output feeds `profileSourceHash` indirectly (both are
      // derived from the same document set) and a non-deterministic order
      // would make an otherwise-unchanged course look "changed" from one
      // run to the next for no reason.
      return byKind !== 0 ? byKind : a.id.localeCompare(b.id);
    });

  const blocks: string[] = [];
  let total = 0;

  for (const doc of ordered) {
    const block = `### ${doc.kind}: ${doc.title}\n${doc.text}`;

    if (blocks.length === 0 && block.length > maxChars) {
      blocks.push(block.slice(0, maxChars));
      break;
    }
    if (total + block.length > maxChars) {
      break;
    }

    blocks.push(block);
    total += block.length + 2; // +2 for the "\n\n" joiner below
  }

  return blocks.join("\n\n");
}

// ---------------------------------------------------------------------
// Response parsing
// ---------------------------------------------------------------------

export interface GradingWeight {
  name: string;
  percent: number;
}
export interface ExamDate {
  name: string;
  date?: string;
  text: string;
}
export interface OfficeHours {
  who: string;
  when: string;
  where?: string;
}
export interface Contact {
  name: string;
  role?: string;
  email?: string;
}
export interface KeyPolicy {
  topic: string;
  text: string;
}
/** One syllabus-distinguished component of a course that is more than one
 *  thing under a single Canvas site -- e.g. PHYS 0151's lab, graded
 *  separately from its lecture. Deliberately a *narrower* fact than
 *  `_shared/catalog.ts`'s `CatalogComponent`: the catalog's components come
 *  from the registrar's section list (every course with a lab section has
 *  one, whether or not its syllabus ever mentions grading it separately),
 *  while this one only exists when the syllabus itself states something
 *  component-specific -- see `PROFILE_INSTRUCTIONS`'s "only when the
 *  syllabus itself distinguishes them" instruction. The two are combined
 *  by nothing in this codebase; `ask`'s prompt carries both blocks and
 *  leaves reconciling them to the model. */
export interface ProfileComponent {
  name: string;
  gradingBasis?: string;
  creditUnits?: number;
  notes?: string;
}

export interface CourseProfile {
  gradingWeights?: GradingWeight[];
  latePolicy?: string;
  attendancePolicy?: string;
  examDates?: ExamDate[];
  officeHours?: OfficeHours[];
  contacts?: Contact[];
  textbooks?: string[];
  keyPolicies?: KeyPolicy[];
  components?: ProfileComponent[];
  sourceDocumentIDs?: string[];
}

/**
 * Parses the model's response text into a `CourseProfile`. Tolerant of a
 * ```json fenced block despite `PROFILE_INSTRUCTIONS` asking for bare JSON
 * -- models occasionally wrap their answer in a fence anyway even under
 * explicit instruction not to, and stripping it costs nothing. Anything
 * that still isn't valid JSON, or isn't a JSON object, comes back as `{}`
 * rather than throwing: one course's malformed extraction must not fail
 * the whole `extract-profile` batch (see the caller's per-course loop),
 * and an empty profile is a safe, honest fallback for "the model didn't
 * give us anything usable this time".
 *
 * Every known key is independently validated by shape; a key present with
 * the wrong type (a string where an array was expected, a non-numeric
 * `percent`, ...) is dropped rather than coerced or allowed to poison the
 * whole object, and any key not in the schema at all is dropped
 * unconditionally.
 */
export function parseProfile(text: string): CourseProfile {
  let raw: unknown;
  try {
    raw = JSON.parse(extractJSON(text));
  } catch {
    return {};
  }
  if (typeof raw !== "object" || raw === null || Array.isArray(raw)) {
    return {};
  }
  return sanitizeProfile(raw as Record<string, unknown>);
}

function extractJSON(text: string): string {
  const fenced = text.match(/```(?:json)?\s*([\s\S]*?)```/i);
  return (fenced ? fenced[1] : text).trim();
}

function isString(value: unknown): value is string {
  return typeof value === "string";
}
function isFiniteNumber(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value);
}
function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

/** Maps every element of `value` that is a plain object through `mapItem`,
 *  drops elements `mapItem` rejects (returns `undefined` for) or that
 *  aren't objects to begin with, and returns `undefined` -- not an empty
 *  array -- when nothing survives, so the caller can `if (result) out.key
 *  = result` and get "omit the key" for free on a fully-invalid input. */
function sanitizeArray<T>(
  value: unknown,
  mapItem: (item: Record<string, unknown>) => T | undefined,
): T[] | undefined {
  if (!Array.isArray(value)) return undefined;
  const items = value
    .filter(isPlainObject)
    .map(mapItem)
    .filter((item): item is T => item !== undefined);
  return items.length > 0 ? items : undefined;
}

function sanitizeProfile(raw: Record<string, unknown>): CourseProfile {
  const out: CourseProfile = {};

  const gradingWeights = sanitizeArray(raw.gradingWeights, (item) =>
    isString(item.name) && isFiniteNumber(item.percent)
      ? { name: item.name, percent: item.percent }
      : undefined);
  if (gradingWeights) out.gradingWeights = gradingWeights;

  if (isString(raw.latePolicy)) out.latePolicy = raw.latePolicy;
  if (isString(raw.attendancePolicy)) out.attendancePolicy = raw.attendancePolicy;

  const examDates = sanitizeArray(raw.examDates, (item) => {
    if (!isString(item.name) || !isString(item.text)) return undefined;
    return isString(item.date)
      ? { name: item.name, date: item.date, text: item.text }
      : { name: item.name, text: item.text };
  });
  if (examDates) out.examDates = examDates;

  const officeHours = sanitizeArray(raw.officeHours, (item) => {
    if (!isString(item.who) || !isString(item.when)) return undefined;
    return isString(item.where)
      ? { who: item.who, when: item.when, where: item.where }
      : { who: item.who, when: item.when };
  });
  if (officeHours) out.officeHours = officeHours;

  const contacts = sanitizeArray(raw.contacts, (item) => {
    if (!isString(item.name)) return undefined;
    const contact: Contact = { name: item.name };
    if (isString(item.role)) contact.role = item.role;
    if (isString(item.email)) contact.email = item.email;
    return contact;
  });
  if (contacts) out.contacts = contacts;

  const keyPolicies = sanitizeArray(raw.keyPolicies, (item) =>
    isString(item.topic) && isString(item.text)
      ? { topic: item.topic, text: item.text }
      : undefined);
  if (keyPolicies) out.keyPolicies = keyPolicies;

  const components = sanitizeArray(raw.components, (item) => {
    if (!isString(item.name)) return undefined;
    const component: ProfileComponent = { name: item.name };
    if (isString(item.gradingBasis)) component.gradingBasis = item.gradingBasis;
    if (isFiniteNumber(item.creditUnits)) component.creditUnits = item.creditUnits;
    if (isString(item.notes)) component.notes = item.notes;
    return component;
  });
  if (components) out.components = components;

  if (Array.isArray(raw.textbooks)) {
    const textbooks = raw.textbooks.filter(isString);
    if (textbooks.length > 0) out.textbooks = textbooks;
  }

  if (Array.isArray(raw.sourceDocumentIDs)) {
    const ids = raw.sourceDocumentIDs.filter(isString);
    if (ids.length > 0) out.sourceDocumentIDs = ids;
  }

  return out;
}

// ---------------------------------------------------------------------
// Staleness hashing
// ---------------------------------------------------------------------

/**
 * SHA-256 hex digest over the sorted `"{id}:{content_hash}"` pairs of
 * `docs`. Stored alongside the extracted profile as `source_hash` so a
 * future caller could, in principle, tell whether a profile is still
 * derived from the exact document set it was built from -- independent of
 * `courses.profile_stale`, which only tracks *that* something in
 * syllabus/home/page changed, not *what*. Sorting before hashing is what
 * makes this order-independent: the caller's Supabase query has no
 * `ORDER BY` guarantee, and this hash must not flip for the same
 * underlying set of documents fetched in a different row order.
 */
export async function profileSourceHash(
  docs: Array<Pick<ProfileSourceDocument, "id" | "content_hash">>,
): Promise<string> {
  const pairs = docs.map((doc) => `${doc.id}:${doc.content_hash}`).sort();
  const bytes = new TextEncoder().encode(pairs.join("\n"));
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  return Array.from(new Uint8Array(digest))
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}
