// The server-side replacement for the iOS `ClaudeAnnouncementExtractor`
// (`LowHangingFruitKit/Sources/LowHangingFruitKit/Announcements/ClaudeAnnouncementExtractor.swift`).
// That type called Anthropic directly with a forced tool-use block; this
// backend goes through OpenRouter's `response_format: json_object` instead
// (see `openrouter.ts`'s `chatCompletionJSON`), so the *shape* of the
// request differs, but the instructions and the context lines placed ahead
// of the announcement body are carried over as closely as the change in
// transport allows.
//
// This file's rules exist because of a real failure: the on-device (and
// original v1 of this) heuristic turned "The slides discussed today have
// been posted." into an overdue assignment. That sentence is the
// instructor describing their own completed action (passive voice, no
// verb the *student* performs), not a task -- the fix threads through
// `ANNOUNCEMENT_INSTRUCTIONS` below, `parseAssignments`'s `kind` field, and
// the CLASS MEETINGS context `buildAnnouncementUserContent` now carries so
// "before class Thursday" resolves to an actual class start time instead
// of a guessed end-of-day default.
import { structureBlock, type CatalogCourseRow } from "./catalog.ts";
import { stableStringify } from "./prompt.ts";

/** Rewritten (was the v1, tool-use-era prompt) to draw the passive-voice /
 *  first-person distinction that fixed the "slides posted" false positive
 *  described above, and to add `kind` so a due date can default sensibly
 *  (end-of-day only for a `submission`, never for a `preparation` task). */
export const ANNOUNCEMENT_INSTRUCTIONS: string = [
  `You extract actionable student tasks from a professor's course `
  + `announcement, distinguishing what the STUDENT must do from what the `
  + `instructor is telling the student about the instructor's own `
  + `actions. A sentence written in passive voice or the first person `
  + `about something the instructor did or will do -- "the slides `
  + `discussed today have been posted", "I uploaded the recording", "we `
  + `will cover chapter 6 next week" -- is informational and yields no `
  + `task, even when it names course material by title. A purely `
  + `informational announcement -- slides, notes or a recording posted; a `
  + `room, time or office-hours change; a cancellation -- yields an empty `
  + `assignments list.`,

  `Respond with a single JSON object and nothing else -- no prose, no `
  + `markdown fence -- of exactly this shape:\n`
  + `{ "assignments": [ { "title": string, "dueAt": string | null, `
  + `"kind": "submission" | "preparation" } ] }`,

  `"title" is a short imperative task title, at most 80 characters. `
  + `"kind" is "submission" for anything handed in or completed on a `
  + `platform -- homework, a quiz, a survey, an upload -- and `
  + `"preparation" for a task with nothing to hand in -- read, watch, `
  + `review, bring, prepare. If there are no extractable tasks, respond `
  + `with { "assignments": [] }.`,

  `"dueAt" is an ISO 8601 datetime with a timezone -- never guess a date `
  + `or time the announcement doesn't state or clearly imply. When the `
  + `announcement says "before class", "in class", "for class" or names a `
  + `specific class meeting day without stating a clock time, use the `
  + `CLASS MEETINGS block below (when present) to find that day's class `
  + `start time and use exactly that as "dueAt" -- not 11:59 PM. Only when `
  + `a submission names a day with no time at all, and no class meeting in `
  + `the CLASS MEETINGS block resolves it, use 23:59 America/New_York on `
  + `that day. A preparation task, or any task that names neither a date `
  + `nor a class day, gets "dueAt": null.`,
].join("\n\n");

export interface AnnouncementContext {
  courseCode: string;
  title: string;
  message: string;
  /** ISO 8601, omitted from the context lines when absent -- mirrors
   *  `announcement.postedAt` being optional on the Swift side. */
  postedAt?: string;
  /** ISO 8601 "now", supplied by the caller (the request body's `now`
   *  field) rather than read from the system clock here, for the same
   *  reason every other "current date" in this backend is caller-supplied:
   *  it keeps this function pure and testable with a fixed instant. */
  now: string;
  /** The one `catalog_courses` row for this announcement's course, when
   *  the server could resolve `courseCode` to one of the caller's
   *  enrollments and that course has a fetched catalog row -- see
   *  `extract-announcement/index.ts`'s course resolution. Missing (rather
   *  than an error) whenever any step of that chain comes up empty: an
   *  unresolved course code, a course with no registrar catalog code, or
   *  one whose code Penn Labs has never answered for. Feeds both the
   *  COURSE STRUCTURE block (via `structureBlock`) and the CLASS MEETINGS
   *  block (via `classMeetingsBlock`). */
  catalog?: CatalogCourseRow;
  /** The resolved course's `course_profiles.profile` JSON value, when one
   *  exists -- the same untyped `unknown` shape `ask/index.ts` reads this
   *  column as. Only `courseProfileBlock`'s four permitted keys ever reach
   *  the prompt; see that function. */
  profile?: unknown;
}

const COURSE_STRUCTURE_HEADER = "COURSE STRUCTURE (from the Penn registrar via Penn Labs):";
const CLASS_MEETINGS_HEADER = "CLASS MEETINGS:";
const COURSE_PROFILE_HEADER = "COURSE PROFILE (extracted from the syllabus):";

/** Penn Labs' letters mapped to the three-letter weekday abbreviation
 *  `classMeetingsBlock` renders, keyed by the same 1 (Sunday) .. 7
 *  (Saturday) convention `_shared/catalog.ts`'s `CatalogMeeting.weekday`
 *  uses -- see that file's doc comment. */
const WEEKDAY_ABBREVIATIONS: ReadonlyMap<number, string> = new Map([
  [1, "Sun"],
  [2, "Mon"],
  [3, "Tue"],
  [4, "Wed"],
  [5, "Thu"],
  [6, "Fri"],
  [7, "Sat"],
]);

/** `930` (minutes after midnight) -> `"15:30"`. 24-hour, no leading zero on
 *  the hour, matching the register of a student's own class schedule
 *  rather than a formal AM/PM rendering the model would have to parse
 *  back apart. */
function formatClockMinutes(totalMinutes: number): string {
  const hours = Math.floor(totalMinutes / 60);
  const minutes = totalMinutes % 60;
  return `${hours}:${String(minutes).padStart(2, "0")}`;
}

/** `"PHYS-0151-401"` -> `"401"` -- the section-number suffix a student
 *  actually recognizes, rather than the full Penn Labs section id, which
 *  repeats the course code the CLASS MEETINGS line already states via its
 *  `activity`. A section id with no dash (shouldn't happen given Penn
 *  Labs' own id scheme, but this file never trusts upstream shape more
 *  than it has to) is used verbatim rather than crashing. */
function sectionLabel(sectionID: string): string {
  const index = sectionID.lastIndexOf("-");
  return index >= 0 ? sectionID.slice(index + 1) : sectionID;
}

/**
 * Renders every meeting across every component of `catalog` into one line
 * each -- `"LEC Tue 10:15-11:44 (section 401)"` -- sorted by weekday, then
 * start time, then section id for the byte-stability every other prompt
 * fragment in this backend holds itself to (see the module doc comment on
 * `prompt.ts`). Returns `""` -- not a header with nothing under it -- both
 * when `catalog` is absent and when it has no meetings at all (a course
 * with a registrar row but no parsed section times), so the caller can
 * omit the whole CLASS MEETINGS block in either case rather than emitting
 * an empty section.
 */
export function classMeetingsBlock(catalog: CatalogCourseRow | undefined): string {
  if (!catalog) return "";

  interface Line {
    weekday: number;
    startMinutes: number;
    sectionID: string;
    text: string;
  }

  const lines: Line[] = [];
  for (const component of catalog.components) {
    for (const meeting of component.meetings) {
      const weekdayAbbreviation = WEEKDAY_ABBREVIATIONS.get(meeting.weekday);
      if (!weekdayAbbreviation) continue; // defensive; catalog.ts never emits an out-of-range weekday
      const text = `${component.activity} ${weekdayAbbreviation} `
        + `${formatClockMinutes(meeting.startMinutes)}–${formatClockMinutes(meeting.endMinutes)} `
        + `(section ${sectionLabel(meeting.sectionID)})`;
      lines.push({ weekday: meeting.weekday, startMinutes: meeting.startMinutes, sectionID: meeting.sectionID, text });
    }
  }
  if (lines.length === 0) return "";

  lines.sort((a, b) =>
    a.weekday - b.weekday || a.startMinutes - b.startMinutes || a.sectionID.localeCompare(b.sectionID)
  );
  return lines.map((line) => line.text).join("\n");
}

/** The only four `CourseProfile` keys (see `_shared/profile.ts`) worth an
 *  announcement's prompt budget: grading weights, the late policy,
 *  syllabus-distinguished components, and any other key policy -- the
 *  facts most likely to bear on whether an announcement's task is a
 *  submission, a preparation task, or nothing at all, and on how it should
 *  be titled. Exam dates, office hours, contacts and textbooks are already
 *  irrelevant to extracting a task from a single announcement, so they're
 *  dropped rather than carried along "just in case", per the brief's "keep
 *  it short". Returns `""` -- prompting the caller to omit the header
 *  entirely -- when `profile` isn't a plain object or none of the four
 *  keys are present, exactly `structureBlock`'s and `classMeetingsBlock`'s
 *  "nothing to say" posture. */
export function courseProfileBlock(profile: unknown): string {
  if (typeof profile !== "object" || profile === null || Array.isArray(profile)) return "";
  const record = profile as Record<string, unknown>;
  const subset: Record<string, unknown> = {};
  for (const key of ["gradingWeights", "latePolicy", "components", "keyPolicies"]) {
    const value = record[key];
    if (value !== undefined && value !== null) subset[key] = value;
  }
  if (Object.keys(subset).length === 0) return "";
  return stableStringify(subset);
}

/**
 * Course code, announcement title, optional posted-at, "Current date", then
 * -- when available -- COURSE STRUCTURE, CLASS MEETINGS and COURSE PROFILE
 * context blocks in that fixed order (each omitted independently when its
 * own source data isn't available), then the announcement body. The base
 * four lines are the same grounding `ClaudeAnnouncementExtractor.userContent
 * (for:now:)` gives the model, reproduced line for line; the three context
 * blocks are new, added to fix a real false positive (see this file's
 * module doc comment) by giving the model the class's own meeting times
 * instead of letting it guess. Byte-stable for identical input, the same
 * discipline `prompt.ts`'s `buildMessages` documents at length: nothing
 * here reads a clock, and `classMeetingsBlock`/`courseProfileBlock`/
 * `structureBlock` all sort or key-normalize their own output.
 *
 * The body is capped at 4000 characters for the same reason the Swift
 * version caps it: a professor occasionally pastes an entire syllabus into
 * an "announcement", and the sentence that states the actual task is
 * almost always in the first paragraph.
 */
export function buildAnnouncementUserContent(context: AnnouncementContext): string {
  const lines: string[] = [
    `Course: ${context.courseCode}`,
    `Announcement title: ${context.title}`,
  ];
  if (context.postedAt) {
    lines.push(`Posted at: ${context.postedAt}`);
  }
  lines.push(`Current date: ${context.now}`);

  if (context.catalog) {
    lines.push("");
    lines.push(`${COURSE_STRUCTURE_HEADER}\n${structureBlock([context.catalog])}`);

    const meetings = classMeetingsBlock(context.catalog);
    if (meetings.length > 0) {
      lines.push("");
      lines.push(`${CLASS_MEETINGS_HEADER}\n${meetings}`);
    }
  }

  const profile = courseProfileBlock(context.profile);
  if (profile.length > 0) {
    lines.push("");
    lines.push(`${COURSE_PROFILE_HEADER}\n${profile}`);
  }

  lines.push("");
  lines.push(context.message.slice(0, 4000));
  return lines.join("\n");
}

export type AssignmentKind = "submission" | "preparation";

export interface ExtractedAssignment {
  title: string;
  dueAt?: string;
  kind: AssignmentKind;
}

const MAX_DUE_DATE_SKEW_MS = 400 * 24 * 60 * 60 * 1000;

/**
 * Parses the model's `{ "assignments": [...] }` response. Tolerant of a
 * fenced ```json block for the same reason `profile.ts`'s `parseProfile`
 * is; unparseable or wrongly-shaped input yields `[]` rather than
 * throwing, since a request that made it this far already spent its quota
 * and a parse failure should surface as "nothing extracted", not a 5xx.
 *
 * A `dueAt` is only kept when it parses as a real date *and* falls within
 * 400 days of `now` in either direction -- "future-or-recent sanity". That
 * catches a model hallucinating a year (a two-year-old syllabus template
 * left in the announcement text) or echoing an unfilled placeholder like
 * `"2024-01-01"`. A rejected date drops just the date, not the whole task
 * -- an undated task the app can't schedule is still more useful to show
 * the student than not surfacing it at all.
 */
export function parseAssignments(text: string, now: Date): ExtractedAssignment[] {
  let raw: unknown;
  try {
    raw = JSON.parse(extractJSON(text));
  } catch {
    return [];
  }
  if (typeof raw !== "object" || raw === null) return [];
  const assignments = (raw as Record<string, unknown>).assignments;
  if (!Array.isArray(assignments)) return [];

  const results: ExtractedAssignment[] = [];
  for (const entry of assignments) {
    if (typeof entry !== "object" || entry === null) continue;
    const title = (entry as Record<string, unknown>).title;
    if (typeof title !== "string" || title.trim().length === 0) continue;

    const rawDue = (entry as Record<string, unknown>).dueAt;
    const dueAt = typeof rawDue === "string" ? sanitizeDueDate(rawDue, now) : undefined;
    const kind = sanitizeKind((entry as Record<string, unknown>).kind);

    results.push(dueAt !== undefined ? { title, dueAt, kind } : { title, kind });
  }
  return results;
}

/** "submission" when the model states it explicitly; "preparation" only
 *  when the model states that exactly; anything else -- absent, `null`, a
 *  typo, a value from some other schema entirely -- defaults to
 *  "submission" per the brief, since a task this function can't confidently
 *  classify as prep-only is safer treated as something the student should
 *  actually track than silently downgraded to informational-adjacent. */
function sanitizeKind(value: unknown): AssignmentKind {
  return value === "preparation" ? "preparation" : "submission";
}

function sanitizeDueDate(raw: string, now: Date): string | undefined {
  const parsed = new Date(raw);
  if (Number.isNaN(parsed.getTime())) return undefined;
  const skew = Math.abs(parsed.getTime() - now.getTime());
  return skew <= MAX_DUE_DATE_SKEW_MS ? raw : undefined;
}

function extractJSON(text: string): string {
  const fenced = text.match(/```(?:json)?\s*([\s\S]*?)```/i);
  return (fenced ? fenced[1] : text).trim();
}

/**
 * Whether `a` and `b` name the same registrar course code once case,
 * surrounding whitespace and the space/dash between department and number
 * are normalized away -- `"PHYS 0151"`, `"phys-0151"` and `"PHYS  0151"`
 * all match each other. Used by `extract-announcement/index.ts` to resolve
 * the request's free-text `courseCode` against the caller's own enrolled
 * `courses.code` values, which may have been entered with different
 * spacing than Canvas's own descriptor. Two codes that both normalize to
 * the empty string never match -- an empty `courseCode` shouldn't
 * "resolve" to an equally-empty (and therefore meaningless) stored code.
 */
export function courseCodesMatch(a: string, b: string): boolean {
  const normalizedA = normalizeCourseCodeForMatch(a);
  const normalizedB = normalizeCourseCodeForMatch(b);
  return normalizedA.length > 0 && normalizedA === normalizedB;
}

function normalizeCourseCodeForMatch(code: string): string {
  return code.trim().toUpperCase().replace(/[\s-]+/g, "");
}
