// Fetches Penn's public course data into a CatalogSnapshot for the degree
// planner (types.ts). Everything here is best effort: a request that fails,
// times out or returns something unexpected leaves a hole in the snapshot and
// never throws, because the planner treats a missing course as "unverified",
// not as an error. All sources are public and need no credentials.
//
// Why Penn Labs' list endpoint alone is not enough: it carries no attributes,
// so attribute membership (WUGE, EUCU, ...) comes from the search endpoint,
// and prerequisites / crosslistings come from per-course detail for the few
// codes the caller names. The list is about 4 MB, so only the courses the
// caller can use (its subjects, its codes, attribute hits) are kept.

import { academicSemester } from "../catalog.ts";
import type { CatalogCourse, CatalogSnapshot } from "./types.ts";

const BASE = "https://penncoursereview.com/api/base";
const CIS_TE_URL = "https://advising.cis.upenn.edu/assets/json/37cu_csci_tech_elective_list.json";
const USER_AGENT = "LowHangingFruit/1 (student dashboard; contact in repo)";
const CACHE_TTL_MS = 6 * 60 * 60 * 1000;
const MAX_PARALLEL = 6;
const MAX_DETAIL_CODES = 60;

export interface CatalogOptions {
  fetchImpl: typeof fetch;
  now: Date;
  /** Attribute codes to index, e.g. ["WUGE", "EUCU"]. */
  attributes: string[];
  /** Subjects whose courses are kept from the list, e.g. ["CIS", "MGMT"]. */
  subjects: string[];
  /** Specific codes to keep and to fetch detail for. */
  codes: string[];
  timeoutMs?: number;
}

// ---------------------------------------------------------------------------
// Small helpers
// ---------------------------------------------------------------------------

/** "BEPP-2500", "bepp 2500", "BEPP2500" -> "BEPP 2500"; null if not a code. */
export function normalizeCourseCode(raw: unknown): string | null {
  if (typeof raw !== "string") return null;
  const m = /^\s*([A-Za-z]{2,5})[\s-]*(\d{3,4})\s*$/.exec(raw);
  if (!m) return null;
  return `${m[1].toUpperCase()} ${m[2]}`;
}

/** "202630"-style spring/summer/fall by Penn Labs' letter. */
function seasonOf(semester: string): "spring" | "summer" | "fall" | null {
  const letter = semester.slice(-1);
  if (letter === "A") return "spring";
  if (letter === "B") return "summer";
  if (letter === "C") return "fall";
  return null;
}

/** The semesters to read: this one, the next fall/spring one, and the most
 *  recent summer. Deduplicated, in that order. */
export function catalogSemesters(now: Date): string[] {
  const cur = academicSemester(now);
  const year = Number(cur.slice(0, 4));
  const letter = cur.slice(-1);
  let next: string;
  let summer: string;
  if (letter === "C") {
    next = `${year + 1}A`;
    summer = `${year}B`;
  } else if (letter === "A") {
    next = `${year}C`;
    summer = `${year - 1}B`;
  } else {
    next = `${year}C`;
    summer = cur;
  }
  return [...new Set([cur, next, summer])];
}

const cache = new Map<string, { at: number; value: unknown }>();

/** Clears the module cache (tests). */
export function clearCatalogCache(): void {
  cache.clear();
}

async function getJSON(
  opts: CatalogOptions,
  url: string,
  timeoutMs: number,
): Promise<unknown | undefined> {
  const nowMs = opts.now.getTime();
  const hit = cache.get(url);
  if (hit && nowMs - hit.at < CACHE_TTL_MS && nowMs >= hit.at) return hit.value;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const res = await opts.fetchImpl(url, {
      method: "GET",
      headers: { "User-Agent": USER_AGENT, Accept: "application/json" },
      signal: controller.signal,
    });
    if (!res.ok) {
      try { await res.body?.cancel(); } catch { /* ignore */ }
      return undefined;
    }
    const value = await res.json();
    cache.set(url, { at: nowMs, value });
    return value;
  } catch {
    return undefined;
  } finally {
    clearTimeout(timer);
  }
}

async function pool<T>(items: T[], limit: number, work: (item: T) => Promise<void>): Promise<void> {
  let next = 0;
  const runners = Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (next < items.length) {
      const item = items[next++];
      try {
        await work(item);
      } catch { /* a failed item is a hole */ }
    }
  });
  await Promise.all(runners);
}

function asRecord(v: unknown): Record<string, unknown> | null {
  return v && typeof v === "object" && !Array.isArray(v) ? v as Record<string, unknown> : null;
}

function credits(v: unknown): number | undefined {
  const n = typeof v === "number" ? v : typeof v === "string" ? Number(v) : NaN;
  return Number.isFinite(n) ? n : undefined;
}

function blank(code: string, title: string, cr: number): CatalogCourse {
  return {
    code,
    title,
    credits: cr,
    attributes: [],
    offered: { fall: false, spring: false, summer: false },
  };
}

// ---------------------------------------------------------------------------
// Snapshot
// ---------------------------------------------------------------------------

export async function buildCatalogSnapshot(opts: CatalogOptions): Promise<CatalogSnapshot> {
  const snapshot: CatalogSnapshot = { courses: {}, attributeIndex: {}, cisTechElective: {}, semesters: [] };
  try {
    return await build(opts, snapshot);
  } catch {
    return snapshot;
  }
}

async function build(opts: CatalogOptions, snapshot: CatalogSnapshot): Promise<CatalogSnapshot> {
  const listTimeout = opts.timeoutMs ?? 8000;
  const detailTimeout = Math.min(opts.timeoutMs ?? 4000, 4000);
  const semesters = catalogSemesters(opts.now);
  const subjects = new Set(opts.subjects.map((s) => s.trim().toUpperCase()).filter(Boolean));
  const wantedCodes = new Set(
    opts.codes.map(normalizeCourseCode).filter((c): c is string => c !== null),
  );
  const got = new Set<string>();

  const ensure = (code: string, title: string, cr: number): CatalogCourse => {
    let c = snapshot.courses[code];
    if (!c) {
      c = blank(code, title, cr);
      snapshot.courses[code] = c;
    }
    return c;
  };
  const markOffered = (c: CatalogCourse, sem: string) => {
    const s = seasonOf(sem);
    if (s) c.offered[s] = true;
  };

  // 1. Attribute membership first, so attribute hits are kept from the lists.
  const attrCourses = new Map<string, { title: string; credits: number; sems: Set<string> }>();
  const attrSems = semesters.filter((s) => seasonOf(s) !== "summer");
  const attrJobs: { attr: string; sem: string }[] = [];
  const attrs = [...new Set(opts.attributes.map((a) => a.trim().toUpperCase()).filter(Boolean))];
  for (const attr of attrs) for (const sem of attrSems) attrJobs.push({ attr, sem });
  const attrResults: { attr: string; sem: string; rows: unknown[] }[] = [];
  await pool(attrJobs, MAX_PARALLEL, async ({ attr, sem }) => {
    const body = await getJSON(
      opts,
      `${BASE}/${sem}/search/courses/?attributes=${encodeURIComponent(attr)}`,
      listTimeout,
    );
    if (Array.isArray(body)) {
      attrResults.push({ attr, sem, rows: body });
      got.add(sem);
    }
  });
  // Deterministic order regardless of completion order.
  attrResults.sort((a, b) => a.attr.localeCompare(b.attr) || a.sem.localeCompare(b.sem));
  const attrHits: { code: string; attr: string; sem: string; title: string; cr: number }[] = [];
  for (const { attr, sem, rows } of attrResults) {
    for (const row of rows) {
      const r = asRecord(row);
      const code = r ? normalizeCourseCode(r.id ?? r.code) : null;
      if (!r || !code) continue;
      attrHits.push({
        code,
        attr,
        sem,
        title: typeof r.title === "string" ? r.title : "",
        cr: credits(r.credits) ?? 1,
      });
    }
  }
  const attrCodes = new Set(attrHits.map((h) => h.code));

  // 2. Course lists per semester.
  for (const sem of semesters) {
    const body = await getJSON(opts, `${BASE}/${sem}/courses/`, listTimeout);
    if (!Array.isArray(body)) continue;
    got.add(sem);
    for (const row of body) {
      const r = asRecord(row);
      const code = r ? normalizeCourseCode(r.id ?? r.code) : null;
      if (!r || !code) continue;
      const subject = code.split(" ")[0];
      if (!subjects.has(subject) && !wantedCodes.has(code) && !attrCodes.has(code)) continue;
      const c = ensure(code, typeof r.title === "string" ? r.title : "", credits(r.credits) ?? 1);
      if (!c.title && typeof r.title === "string") c.title = r.title;
      markOffered(c, sem);
    }
  }

  // 3. Fold attribute hits in (adds courses the lists did not hold).
  for (const h of attrHits) {
    const c = ensure(h.code, h.title, h.cr);
    markOffered(c, h.sem);
    if (!c.attributes.includes(h.attr)) c.attributes.push(h.attr);
    const list = (snapshot.attributeIndex[h.attr] ??= []);
    if (!list.includes(h.code)) list.push(h.code);
  }
  for (const list of Object.values(snapshot.attributeIndex)) list.sort();
  for (const c of Object.values(snapshot.courses)) c.attributes.sort();

  // 4. Detail for the named codes.
  const detailCodes = [...wantedCodes].slice(0, MAX_DETAIL_CODES);
  await pool(detailCodes, MAX_PARALLEL, async (code) => {
    const slug = code.replace(" ", "-");
    for (const sem of semesters) {
      const body = await getJSON(opts, `${BASE}/${sem}/courses/${slug}/`, detailTimeout);
      const r = asRecord(body);
      if (!r) continue;
      got.add(sem);
      const c = ensure(
        code,
        typeof r.title === "string" ? r.title : "",
        credits(r.credits) ?? 1,
      );
      markOffered(c, sem);
      if (typeof r.prerequisites === "string" && r.prerequisites.trim()) {
        c.prerequisites = r.prerequisites.trim();
      }
      if (Array.isArray(r.attributes)) {
        for (const a of r.attributes) {
          const ar = asRecord(a);
          const raw = ar ? ar.code : a;
          if (typeof raw !== "string" || !raw.trim()) continue;
          const ac = raw.trim().toUpperCase();
          if (!c.attributes.includes(ac)) c.attributes.push(ac);
        }
        c.attributes.sort();
      }
      if (Array.isArray(r.crosslistings)) {
        const xs: string[] = [];
        for (const x of r.crosslistings) {
          const xr = asRecord(x);
          const xc = normalizeCourseCode(xr ? xr.id ?? xr.code : x);
          if (xc && xc !== code && !xs.includes(xc)) xs.push(xc);
        }
        if (xs.length) c.crosslistings = xs;
      }
      return;
    }
  });

  // 5. CIS technical electives.
  const cis = await getJSON(opts, CIS_TE_URL, listTimeout);
  if (Array.isArray(cis)) {
    for (const row of cis) {
      const r = asRecord(row);
      const code = r ? normalizeCourseCode(r.course4d) : null;
      if (!r || !code || typeof r.status !== "string") continue;
      snapshot.cisTechElective[code] = r.status;
    }
  }

  snapshot.semesters = semesters.filter((s) => got.has(s));
  return snapshot;
}
