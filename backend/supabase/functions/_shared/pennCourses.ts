// Checks that course codes a model proposed exist in Penn's public catalogue
// (Penn Labs' course API, the same source `catalog.ts` reads). Only course
// codes leave the server; no student data is involved.
//
// The semester is always named explicitly and Penn Labs' `current` is never
// used: it is whatever is open for registration, not what is in session (see
// `academicSemester` in catalog.ts). Two semesters are tried, this one and the
// next regular one, because a student plans ahead and a course may be listed
// only for the coming term. Never throws: any failure leaves that code
// unverified.
import { academicSemester } from "./catalog.ts";

export const MAX_VERIFIED_CODES = 40;
const DEFAULT_TIMEOUT_MS = 3000;
const PENN_LABS_BASE_URL = "https://penncoursereview.com/api/base";
const USER_AGENT = "LowHangingFruit/1 (student dashboard; contact in repo)";

export interface VerifiedCourse {
  title: string | null;
  credits: number | null;
}

/** A -> C (summer is skipped), B -> C, C -> A of the next year. */
export function nextSemester(semester: string): string {
  const year = Number(semester.slice(0, 4));
  const letter = semester.slice(4);
  if (letter === "C") return `${year + 1}A`;
  return `${year}C`;
}

async function lookupOne(
  code: string,
  semesters: string[],
  fetchImpl: typeof fetch,
  timeoutMs: number,
): Promise<VerifiedCourse | undefined> {
  const [subject, number] = code.split(" ");
  for (const semester of semesters) {
    const controller = new AbortController();
    const timer = setTimeout(() => controller.abort(), timeoutMs);
    try {
      const response = await fetchImpl(`${PENN_LABS_BASE_URL}/${semester}/courses/${subject}-${number}/`, {
        method: "GET",
        headers: { "User-Agent": USER_AGENT },
        signal: controller.signal,
      });
      if (response.status !== 200) continue;
      let body: unknown;
      try {
        body = await response.json();
      } catch {
        continue;
      }
      if (typeof body !== "object" || body === null || Array.isArray(body)) continue;
      const o = body as Record<string, unknown>;
      if (typeof o.id !== "string" || typeof o.title !== "string") continue;
      let credits: number | null = null;
      if (typeof o.credits === "number" && Number.isFinite(o.credits)) credits = o.credits;
      else if (typeof o.credits === "string" && o.credits.trim() !== "" && Number.isFinite(Number(o.credits))) {
        credits = Number(o.credits);
      }
      return { title: o.title, credits };
    } catch {
      continue;
    } finally {
      clearTimeout(timer);
    }
  }
  return undefined;
}

/** Codes are "SUBJ 1234", already normalized. Unfound codes are absent from
 *  the map. At most 40 distinct codes are looked up. */
export async function verifyPennCourses(
  codes: string[],
  opts: { fetchImpl: typeof fetch; now: Date; timeoutMs?: number },
): Promise<Map<string, VerifiedCourse>> {
  const result = new Map<string, VerifiedCourse>();
  const distinct = [...new Set(codes)].slice(0, MAX_VERIFIED_CODES);
  if (distinct.length === 0) return result;
  const first = academicSemester(opts.now);
  const semesters = [first, nextSemester(first)];
  const timeoutMs = opts.timeoutMs ?? DEFAULT_TIMEOUT_MS;
  await Promise.all(distinct.map(async (code) => {
    try {
      const found = await lookupOne(code, semesters, opts.fetchImpl, timeoutMs);
      if (found) result.set(code, found);
    } catch {
      // unverified
    }
  }));
  return result;
}
