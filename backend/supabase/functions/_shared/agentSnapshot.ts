// What the phone uploads to `agent-snapshot` and how the agent's views of it
// are cut (docs/AGENT_CONNECTION_RESEARCH_2026-11-08.md §7: what the snapshot
// may hold, and the "never" list). Pure: the validator takes parsed JSON, the
// views take a clock, so tests pin both with fixed dates.
import { courseCodesMatch } from "./announcement.ts";

export const MAX_SNAPSHOT_BYTES = 1_048_576;
export const MAX_SNAPSHOT_COURSES = 60;
export const MAX_SNAPSHOT_WORK = 2000;
export const MAX_SNAPSHOT_MANUAL = 500;

export const WORK_KINDS = ["assignment", "quiz", "discussion", "event", "other"] as const;
export type SnapshotWorkKind = (typeof WORK_KINDS)[number];

export interface SnapshotCourse {
  courseID: string;
  code: string;
  name: string;
}

export interface WorkItem {
  id: string;
  course: string;
  title: string;
  kind: SnapshotWorkKind;
  dueAt: string | null;
  done: boolean;
  noSubmission: boolean;
  url: string | null;
  source: string;
}

export interface ManualItem {
  id: string;
  course: string;
  title: string;
  dueAt: string | null;
  repeatsWeekly: boolean;
}

export interface Snapshot {
  courses: SnapshotCourse[];
  workList: WorkItem[];
  manual: ManualItem[];
}

export type SnapshotValidation = { ok: true; snapshot: Snapshot } | { ok: false; reason: string };

/** Keys that mean a grade or a person. Research §7 says the snapshot never
 *  holds them; the phone does not send them, so one arriving is a bug or an
 *  attack and the whole snapshot is refused rather than trimmed. Compared
 *  lower-cased. `name` is refused on work and manual items only: a course
 *  has a `name` by design. */
const FORBIDDEN_EVERYWHERE = new Set(["score", "grade", "points", "firstname", "email"]);
const FORBIDDEN_ON_ITEMS = new Set([...FORBIDDEN_EVERYWHERE, "name"]);

class Refused extends Error {}
const refuse = (reason: string): never => {
  throw new Refused(reason);
};

function isObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function checkForbidden(item: Record<string, unknown>, set: Set<string>): void {
  for (const key of Object.keys(item)) if (set.has(key.toLowerCase())) refuse("forbidden_field");
}

function str(item: Record<string, unknown>, key: string, where: string, max: number, min = 1): string {
  const value = item[key];
  if (typeof value !== "string" || value.length < min || value.length > max) refuse(`${where}.${key} must be a string of ${min} to ${max} characters`);
  return value as string;
}

function bool(item: Record<string, unknown>, key: string, where: string): boolean {
  const value = item[key];
  if (typeof value !== "boolean") refuse(`${where}.${key} must be a boolean`);
  return value as boolean;
}

const ISO = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(:\d{2}(\.\d+)?)?(Z|[+-]\d{2}:\d{2})$/;

function due(item: Record<string, unknown>, where: string): string | null {
  const value = item.dueAt;
  if (value === null || value === undefined) return null;
  if (typeof value !== "string" || !ISO.test(value) || Number.isNaN(Date.parse(value))) refuse(`${where}.dueAt must be an ISO date or null`);
  return value as string;
}

/** A Canvas link or nothing. Canvas calendar feed URLs
 *  (`/feeds/calendars/user_<token>.ics`) are bearer credentials: whoever
 *  holds one reads the student's calendar with no login. So a feed URL, any
 *  `user_` segment followed by a token-looking run, and any userinfo in the
 *  URL are refused outright, whatever the host. */
export function acceptableCanvasURL(raw: string): boolean {
  if (raw.length > 2000) return false;
  let url: URL;
  try {
    url = new URL(raw);
  } catch {
    return false;
  }
  if (url.protocol !== "https:" || url.username !== "" || url.password !== "") return false;
  const lowered = raw.toLowerCase();
  if (lowered.includes("/feeds/calendars/")) return false;
  if (/user_[a-z0-9]{8,}/i.test(raw)) return false;
  const host = url.hostname.toLowerCase();
  return host.endsWith(".instructure.com") || host.startsWith("canvas.") || url.pathname.includes("/courses/");
}

function link(item: Record<string, unknown>, where: string): string | null {
  const value = item.url;
  if (value === null || value === undefined) return null;
  if (typeof value !== "string" || !acceptableCanvasURL(value)) refuse(`${where}.url is not an acceptable Canvas link`);
  return value as string;
}

function list(body: Record<string, unknown>, key: string, max: number, required: boolean): unknown[] {
  const value = body[key];
  if (value === undefined && !required) return [];
  if (!Array.isArray(value)) refuse(`${key} must be an array`);
  if ((value as unknown[]).length > max) refuse(`${key} has more than ${max} entries`);
  return value as unknown[];
}

/** Validates the phone's upload. Unknown keys are dropped (the result is
 *  rebuilt field by field); forbidden keys refuse the whole snapshot with the
 *  reason `forbidden_field`. */
export function validateSnapshot(body: unknown): SnapshotValidation {
  try {
    if (!isObject(body)) return { ok: false, reason: "body must be an object" };
    const courses = list(body, "courses", MAX_SNAPSHOT_COURSES, true).map((raw, i): SnapshotCourse => {
      const where = `courses[${i}]`;
      if (!isObject(raw)) refuse(`${where} must be an object`);
      const item = raw as Record<string, unknown>;
      checkForbidden(item, FORBIDDEN_EVERYWHERE);
      const courseID = str(item, "courseID", where, 40);
      if (!/^\d+$/.test(courseID)) refuse(`${where}.courseID must be digits`);
      return { courseID, code: str(item, "code", where, 40), name: str(item, "name", where, 200) };
    });
    const workList = list(body, "workList", MAX_SNAPSHOT_WORK, true).map((raw, i): WorkItem => {
      const where = `workList[${i}]`;
      if (!isObject(raw)) refuse(`${where} must be an object`);
      const item = raw as Record<string, unknown>;
      checkForbidden(item, FORBIDDEN_ON_ITEMS);
      const kind = item.kind;
      if (typeof kind !== "string" || !(WORK_KINDS as readonly string[]).includes(kind)) refuse(`${where}.kind is not a known kind`);
      return {
        id: str(item, "id", where, 200),
        course: str(item, "course", where, 40),
        title: str(item, "title", where, 300),
        kind: kind as SnapshotWorkKind,
        dueAt: due(item, where),
        done: bool(item, "done", where),
        noSubmission: bool(item, "noSubmission", where),
        url: link(item, where),
        source: str(item, "source", where, 40),
      };
    });
    const manual = list(body, "manual", MAX_SNAPSHOT_MANUAL, false).map((raw, i): ManualItem => {
      const where = `manual[${i}]`;
      if (!isObject(raw)) refuse(`${where} must be an object`);
      const item = raw as Record<string, unknown>;
      checkForbidden(item, FORBIDDEN_ON_ITEMS);
      return {
        id: str(item, "id", where, 200),
        course: str(item, "course", where, 40, 0),
        title: str(item, "title", where, 300),
        dueAt: due(item, where),
        repeatsWeekly: bool(item, "repeatsWeekly", where),
      };
    });
    return { ok: true, snapshot: { courses, workList, manual } };
  } catch (err) {
    if (err instanceof Refused) return { ok: false, reason: err.message };
    throw err;
  }
}

// ---------------------------------------------------------------------------
// Views.

const HOUR_MS = 3_600_000;
const DAY_MS = 24 * HOUR_MS;
/** Simplification: the dashboard's done tab keeps items placed on or after
 *  `Term(date:).startDate()`; the snapshot has no term, so "this term" is the
 *  last 150 days. */
export const TERM_DAYS = 150;

/** Case-insensitive, ignoring spaces and dashes ("phys-0151" is "PHYS 0151"). */
export function sameCourse(a: string, b: string): boolean {
  return courseCodesMatch(a, b);
}

function dueMs(item: WorkItem): number | null {
  return item.dueAt === null ? null : Date.parse(item.dueAt);
}

function byDueThenID(a: WorkItem, b: WorkItem): number {
  const x = dueMs(a);
  const y = dueMs(b);
  if (x === null && y === null) return a.id < b.id ? -1 : a.id > b.id ? 1 : 0;
  if (x === null) return 1;
  if (y === null) return -1;
  return x === y ? (a.id < b.id ? -1 : a.id > b.id ? 1 : 0) : x - y;
}

/** The dashboard's three lists (`DashboardViewModel` todoSections,
 *  allSections, doneSections), flattened:
 *  - todo: not done, and overdue (due before now) or due within the next 48
 *    hours, inclusive. Undated items are not in todo. Most overdue first,
 *    then soonest first, which is one ascending sort by due date.
 *  - all: not done, due now or later, or undated; soonest first, undated last.
 *  - prev: done, newest first by due date (the snapshot carries no
 *    completion time, so the dashboard's completedAt ordering is not
 *    available), keeping the last 150 days and undated items, as the
 *    dashboard keeps items it cannot place.
 *  `course`, when given, narrows by `sameCourse` first. The dashboard's
 *  cancelled-fact rule is not applied: facts are served separately. */
export function workView(items: WorkItem[], view: "todo" | "all" | "prev", now: Date, course?: string): WorkItem[] {
  const t = now.getTime();
  const scoped = course ? items.filter((i) => sameCourse(i.course, course)) : items;
  if (view === "prev") {
    const cutoff = t - TERM_DAYS * DAY_MS;
    return scoped
      .filter((i) => i.done && (dueMs(i) === null || dueMs(i)! >= cutoff))
      .sort((a, b) => {
        const x = dueMs(a);
        const y = dueMs(b);
        if (x === null || y === null) return byDueThenID(a, b);
        return x === y ? (a.id < b.id ? -1 : 1) : y - x;
      });
  }
  const open = scoped.filter((i) => !i.done);
  if (view === "todo") {
    return open
      .filter((i) => {
        const d = dueMs(i);
        return d !== null && d - t <= 2 * DAY_MS;
      })
      .sort((a, b) => byDueThenID(a, b));
  }
  return open
    .filter((i) => {
      const d = dueMs(i);
      return d === null || d >= t;
    })
    .sort((a, b) => byDueThenID(a, b));
}
