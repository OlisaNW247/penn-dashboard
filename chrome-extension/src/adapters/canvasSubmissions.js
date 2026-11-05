// Which Canvas assignments the student has turned in, from Canvas's own API.
// The calendar feed carries no submission state, so without this the laptop
// lists work the student already handed in. Mirrors the phone's rule
// (CanvasGradesClient.swift AssignmentSubmissionInfo.indicatesSubmitted):
// conservative, only positive signals count.
//
// No cookie is read (credentials: "include" only). Nothing here logs a URL.
import { assignmentsURL } from "../core/canvasApi.js";
import { makeContext, canvasPaged, listCourses } from "./collector.js";

// 5 minutes: the phone's own refresh loop is 5 minutes, and a laptop with a
// live Canvas session is the better source for submission state.
export const THROTTLE_MS = 5 * 60 * 1000;
export const MAX_COURSES = 20;
export const MAX_PAGES_PER_COURSE = 10;

// submission: a Canvas submission object, or null/undefined.
export function isSubmitted(submission) {
  if (typeof submission !== "object" || submission === null) return false;
  if (submission.missing === true) return false;
  if (typeof submission.submitted_at === "string") return true;
  return submission.workflow_state === "submitted" || submission.workflow_state === "pending_review";
}

// Returns { status: "in" | "out" | "error" | "throttled", at, submitted }.
// `submitted` maps canvasAssignmentID -> { submittedAt: string|null }. Any status but "in" carries
// `prior`'s map (last good wins) and `prior`'s `at`.
export async function readCanvasSubmissions({ fetchFn = fetch, now = new Date(), prior, sleep, delayMs } = {}) {
  const keep = { at: prior?.at ?? null, submitted: { ...(prior?.submitted ?? {}) } };
  const nowMs = now.getTime();
  const priorMs = prior?.at ? Date.parse(prior.at) : NaN;
  if (Number.isFinite(priorMs) && nowMs - priorMs >= 0 && nowMs - priorMs < THROTTLE_MS) {
    return { status: "throttled", ...keep };
  }
  const ctx = makeContext({ fetch: fetchFn, limits: { delayMs, sleep } });
  const submitted = {};
  try {
    const courses = (await listCourses(ctx)).slice(0, MAX_COURSES);
    for (const course of courses) {
      let pages;
      try {
        pages = await canvasPaged(ctx, assignmentsURL(course.courseID), MAX_PAGES_PER_COURSE);
      } catch (e) {
        if (e?.kind === "forbidden" || e?.kind === "truncated") continue; // this course only
        throw e;
      }
      for (const page of pages) {
        if (!Array.isArray(page)) continue;
        for (const a of page) {
          if (a && a.id !== undefined && a.id !== null && isSubmitted(a.submission)) submitted[String(a.id)] = { submittedAt: typeof a.submission.submitted_at === "string" ? a.submission.submitted_at : null };
        }
      }
    }
  } catch (e) {
    return { status: e?.kind === "out" ? "out" : "error", ...keep };
  }
  return { status: "in", at: now.toISOString(), submitted };
}
