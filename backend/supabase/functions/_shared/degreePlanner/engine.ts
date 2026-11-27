// Glue between the request and the deterministic planner: reads the audits,
// fetches the public catalogue data they call for, runs `plan`, and runs it a
// second time once prerequisites are known so they can order the schedule.
//
// Only course codes, subjects and attribute codes leave the server (Penn Labs
// and the CIS list are public). Nothing here throws for a data problem: a
// missing catalogue leaves the plan to explicit options and says so in a note.
import type { DegreeAdvisorStructured } from "../degreeAdvisor.ts";
import { buildCatalogSnapshot } from "./catalog.ts";
import { PENN_DATA_BASE, loadPacks } from "./packData.ts";
import { attachPack } from "./packJoin.ts";
import { plan } from "./planner.ts";
import { pennPolicy } from "./policy.ts";
import { degreesFromAudits } from "./requirements.ts";
import type { CatalogSnapshot, Degree, PlanResult, Slot, Unfilled } from "./types.ts";

export const ENGINE_BUDGET_MS = 25_000;
/** A second catalogue pass needs at least this much of the budget left. */
const SECOND_PASS_MIN_MS = 4_000;
/** Work caps. The audits come from the phone, so a hostile or corrupt one
 *  must not be able to make the server fetch or plan without bound. */
export const MAX_ATTRIBUTES = 40;
export const MAX_SUBJECTS = 60;
export const MAX_EXPLICIT_CODES = 150;
export const MAX_SLOTS = 200;
export const MAX_SECOND_PASS_CODES = 60;
const GENERIC_WAIVE_WORDS = new Set([
  "elective", "electives", "requirement", "requirements", "course", "courses", "general",
]);

export interface EngineIntent {
  targetTerm: string | null;
  maxLoad: number | null;
  /** The student says they are already approved for the load they named, or
   *  for 6.5 when they named none. Optional so older callers still compile. */
  loadApproved?: boolean | null;
  /** The student asked for the best case ("assume the approvals"). */
  assumeApprovals?: boolean | null;
  allowSummer: boolean | null;
  waive: string[];
  avoid: string[];
  prefer: string[];
}

export interface EngineInput {
  structured: DegreeAdvisorStructured;
  intent: EngineIntent;
  fetchImpl: typeof fetch;
  now: Date;
  /** Test seam; defaults to ENGINE_BUDGET_MS. */
  budgetMs?: number;
  /** Test seam for the clock; defaults to Date.now. */
  clock?: () => number;
  /** The caller going away cuts off every catalogue request. */
  signal?: AbortSignal;
  /** Where Penn's published program packs are served; null turns them off and
   *  the hand-written sharing rules decide everything. Default: PENN_DATA_BASE. */
  pennData?: { baseUrl: string } | null;
  /** The student's recorded advisor answers, used for this call only. */
  advisorAnswers?: { id: string; answer: "yes" | "no" }[];
}

export interface EnginePackReport {
  degreeId: string;
  program: string | null;
  exactMajor: boolean;
  matchedSlots: number;
  totalSlots: number;
  exactBlocks: number;
  titleBlocks: number;
  ruleMatched: number;
}

export interface EngineOutput {
  plan: PlanResult;
  unfilled: Unfilled[];
  /** Counts for the log line. */
  slots: number;
  /** Which of Penn's program templates joined each degree, and how well. */
  packs: EnginePackReport[];
  packError?: string;
}

function normCode(raw: string): string {
  const t = raw.trim().replace(/\s+/g, " ").toUpperCase();
  const m = /^([A-Z]{2,5})[\s-]*(\d{3,4})$/.exec(t);
  return m ? `${m[1]} ${m[2]}` : t;
}

function collectNeeds(degrees: Degree[]): { attributes: string[]; subjects: string[]; codes: string[] } {
  const attributes = new Set<string>();
  const subjects = new Set<string>();
  const codes = new Set<string>();
  for (const d of degrees) {
    for (const slot of d.slots) {
      for (const e of slot.anyOf) {
        if (e.kind === "attribute") e.codes.forEach((c) => attributes.add(c));
        else if (e.kind === "range") subjects.add(e.subject.toUpperCase());
        else if (e.kind === "subject") e.subjects.forEach((s) => subjects.add(s.toUpperCase()));
        else if (e.kind === "pattern") {
          const s = e.pattern.trim().split(/\s+/)[0]?.toUpperCase();
          if (s && s !== "@" && /^[A-Z]{2,5}$/.test(s)) subjects.add(s);
        } else if (e.kind === "courses") e.codes.forEach((c) => codes.add(normCode(c)));
      }
    }
  }
  return { attributes: [...attributes].sort(), subjects: [...subjects].sort(), codes: [...codes].sort() };
}

/** Keeps the first MAX_SLOTS slots across all degrees, in audit order. */
export function capSlots(degrees: Degree[]): { degrees: Degree[]; dropped: boolean } {
  let budget = MAX_SLOTS;
  let dropped = false;
  const out = degrees.map((d) => {
    if (d.slots.length <= budget) {
      budget -= d.slots.length;
      return d;
    }
    dropped = true;
    const kept = d.slots.slice(0, budget);
    budget = 0;
    return { ...d, slots: kept };
  });
  return { degrees: out, dropped };
}

/** Caps what the first catalogue pass asks for (inputs are already sorted, so
 *  what is dropped is deterministic). */
export function capNeeds(
  needs: { attributes: string[]; subjects: string[]; codes: string[] },
): { attributes: string[]; subjects: string[]; codes: string[]; truncated: boolean } {
  return {
    attributes: needs.attributes.slice(0, MAX_ATTRIBUTES),
    subjects: needs.subjects.slice(0, MAX_SUBJECTS),
    codes: needs.codes.slice(0, MAX_EXPLICIT_CODES),
    truncated: needs.attributes.length > MAX_ATTRIBUTES || needs.subjects.length > MAX_SUBJECTS ||
      needs.codes.length > MAX_EXPLICIT_CODES,
  };
}

/** Matches the model's short labels to requirement slots. A label must be
 *  specific (4+ characters, not a generic word) because a loose match once
 *  waived every slot whose label happened to contain "elective". Per label the
 *  exact label wins; otherwise the single slot whose label contains it; two or
 *  more such slots are ambiguous and waive nothing. */
export function waivedSlotIds(
  degrees: Degree[],
  labels: string[],
): { ids: string[]; unmatched: string[]; ambiguous: string[]; waivedLabels: string[] } {
  const ids = new Set<string>();
  const waivedLabels: string[] = [];
  const unmatched: string[] = [];
  const ambiguous: string[] = [];
  const all = degrees.flatMap((d) => d.slots as Slot[]);
  for (const raw of labels) {
    const w = raw.trim().toLowerCase();
    if (!w) continue;
    if (w.length < 4 || GENERIC_WAIVE_WORDS.has(w)) {
      unmatched.push(raw.trim());
      continue;
    }
    const exact = all.filter((s) => s.label.trim().toLowerCase() === w);
    let pool = exact.length > 0 ? exact : all.filter((s) => s.label.toLowerCase().includes(w));
    if (pool.length === 0) {
      // The model's label may be longer than Penn's ("Foreign Language
      // Proficiency (placement exam)"); a slot label that is itself specific
      // and sits inside it counts, under the same one-match rule.
      pool = all.filter((s) => {
        const l = s.label.trim().toLowerCase();
        return l.length >= 4 && !GENERIC_WAIVE_WORDS.has(l) && w.includes(l);
      });
    }
    if (pool.length === 0) {
      unmatched.push(raw.trim());
    } else if (exact.length === 0 && pool.length > 1) {
      ambiguous.push(raw.trim());
    } else {
      for (const s of pool) {
        if (!ids.has(s.id)) waivedLabels.push(s.label);
        ids.add(s.id);
      }
    }
  }
  return { ids: [...ids], unmatched, ambiguous, waivedLabels };
}

export async function runEngine(input: EngineInput): Promise<EngineOutput> {
  const clock = input.clock ?? Date.now;
  const started = clock();
  const budget = input.budgetMs ?? ENGINE_BUDGET_MS;
  const remaining = () => budget - (clock() - started);

  const { structured, intent } = input;
  const req = degreesFromAudits(structured.audits);
  const extraNotes: string[] = [];
  // At most MAX_SLOTS requirements across all degrees, in audit order; the
  // rest are dropped and the plan says so.
  const capped = capSlots(req.degrees);
  req.degrees = capped.degrees;
  const slotsDropped = capped.dropped;
  if (slotsDropped) extraNotes.push("the audit was too large; some requirements were not planned");
  const taken = new Set(req.taken);
  for (const codes of Object.values(structured.history)) for (const c of codes) taken.add(normCode(c));

  const capNeed = capNeeds(collectNeeds(req.degrees));
  const needs = capNeed;
  if (capNeed.truncated) {
    extraNotes.push("the audit listed more courses than could be looked up, so some options were not considered");
  }
  const deadline = started + budget;

  // Penn's own sharing rules load beside the catalogue (both are public data;
  // only a program code and course codes leave the server). Never throws.
  const pennData = input.pennData === undefined ? { baseUrl: PENN_DATA_BASE } : input.pennData;
  const packPromise = pennData
    ? loadPacks({
      baseUrl: pennData.baseUrl, degrees: req.degrees, fetchImpl: input.fetchImpl, deadline, signal: input.signal, clock,
    })
    : null;

  let catalog: CatalogSnapshot = { courses: {}, attributeIndex: {}, cisTechElective: {}, semesters: [] };
  try {
    catalog = await buildCatalogSnapshot({
      fetchImpl: input.fetchImpl,
      now: input.now,
      attributes: needs.attributes,
      subjects: needs.subjects,
      codes: needs.codes,
      timeoutMs: 8000,
      deadline,
      signal: input.signal,
      clock,
    });
  } catch { /* buildCatalogSnapshot does not throw; belt and braces */ }

  const packReports: EnginePackReport[] = [];
  let packError: string | undefined;
  const loadedPacks = packPromise ? await packPromise : null;
  if (loadedPacks?.error) packError = loadedPacks.error;
  for (const d of req.degrees) {
    const pack = loadedPacks?.packs[d.id];
    const prog = loadedPacks?.programs[d.id];
    let report: EnginePackReport | null = null;
    if (pack && prog) {
      try {
        const r = attachPack(d, pack, { exactMajor: prog.exactMajor });
        report = { degreeId: d.id, program: pack.code, exactMajor: prog.exactMajor, ...r };
      } catch {
        // No partial state: the whole degree goes back to the hand policy.
        for (const s of d.slots) delete s.pack;
        packError = packError ? `${packError}; attach failed` : "attach failed";
      }
    }
    packReports.push(report ?? {
      degreeId: d.id, program: null, exactMajor: false, matchedSlots: 0, totalSlots: d.slots.length,
      exactBlocks: 0, titleBlocks: 0, ruleMatched: 0,
    });
  }

  const catalogEmpty = Object.keys(catalog.courses).length === 0;
  if (catalogEmpty) {
    extraNotes.push(
      "Penn's course catalogue could not be read, so only courses named explicitly in the audits were considered",
    );
  }

  const waive = waivedSlotIds(req.degrees, intent.waive);
  for (const label of waive.unmatched) {
    extraNotes.push(`could not match "${label}" to a requirement, so it was not waived`);
  }
  for (const label of waive.ambiguous) {
    extraNotes.push(`"${label}" matches more than one requirement, so it was not waived`);
  }
  if (waive.waivedLabels.length > 0) extraNotes.push(`treated as done: ${waive.waivedLabels.join(", ")}`);

  // Credits already registered in future terms. The history carries those
  // terms beside the past ones; each course is priced from Penn's audits, then
  // the catalogue, then 1.0. The planner seeds each term's load with this, so
  // the plan never stacks new courses onto a full registered term.
  const registered: Record<string, number> = {};
  for (const [term, codes] of Object.entries(structured.history)) {
    if (!(term > structured.currentTerm)) continue;
    let cu = 0;
    for (const raw of new Set(codes.map(normCode))) {
      cu += req.courseCredits[raw] ?? catalog.courses[raw]?.credits ?? 1;
    }
    if (cu > 0) registered[term] = cu;
  }

  const request = {
    degrees: req.degrees,
    ...(Object.keys(registered).length > 0 ? { registered } : {}),
    taken: [...taken].sort(),
    history: structured.history,
    currentTerm: structured.currentTerm,
    ...(intent.targetTerm ? { targetTerm: intent.targetTerm } : {}),
    // "I am approved for 6.5" with no load named plans at the approved load
    // (the student's own scenario), not at 5.5 with the approved case held in
    // reserve; the wrong fix is leaving maxLoad null and letting the planner
    // reach 6.5 only as a scenario that "needs approval".
    ...(intent.maxLoad !== null
      ? { maxLoad: intent.maxLoad }
      : intent.loadApproved === true ? { maxLoad: pennPolicy.loads.approved } : {}),
    ...(intent.loadApproved === true ? { loadApproved: true } : {}),
    ...(intent.assumeApprovals === true ? { assumeApprovals: true } : {}),
    ...(input.advisorAnswers && input.advisorAnswers.length > 0 ? { advisorAnswers: input.advisorAnswers } : {}),
    ...(intent.allowSummer !== null ? { allowSummer: intent.allowSummer } : {}),
    ...(waive.ids.length > 0 ? { waive: waive.ids } : {}),
    ...(intent.avoid.length > 0 ? { avoid: intent.avoid } : {}),
    ...(intent.prefer.length > 0 ? { prefer: intent.prefer } : {}),
  };

  let result = plan(request, catalog);

  // Second pass: prerequisites of the chosen courses, so they order the
  // schedule. Skipped when the budget is nearly spent or nothing was chosen.
  const chosenCodes = [...new Set(result.schedule.flatMap((t) => t.courses.map((c) => c.code)))];
  if (chosenCodes.length > 0 && !catalogEmpty) {
    if (remaining() >= SECOND_PASS_MIN_MS) {
      try {
        const detail = await buildCatalogSnapshot({
          fetchImpl: input.fetchImpl,
          now: input.now,
          attributes: [],
          subjects: [],
          codes: chosenCodes.slice(0, MAX_SECOND_PASS_CODES),
          timeoutMs: 4000,
          deadline,
          signal: input.signal,
          clock,
        });
        let merged = false;
        for (const [code, d] of Object.entries(detail.courses)) {
          const c = catalog.courses[code];
          if (!c) continue;
          if (d.prerequisites && !c.prerequisites) { c.prerequisites = d.prerequisites; merged = true; }
          if (d.crosslistings && !c.crosslistings) { c.crosslistings = d.crosslistings; merged = true; }
          for (const a of d.attributes) if (!c.attributes.includes(a)) { c.attributes.push(a); merged = true; }
        }
        if (merged) result = plan(request, catalog);
      } catch { /* keep the first plan */ }
    } else {
      extraNotes.push("prerequisites were not checked because Penn's catalogue was slow");
    }
  }

  const seen = new Set<string>();
  const unfilled: Unfilled[] = [];
  for (const u of [...req.unfilled, ...result.unfilled]) {
    const key = `${u.degreeLabel}|${u.label}`.toLowerCase();
    if (seen.has(key)) continue;
    seen.add(key);
    unfilled.push(u);
  }
  // Requirements the audit reader could not turn into slots are not in the
  // planner's counts, so a degree that has such a row is not complete.
  const coverage = result.coverage.map((c) => {
    const label = req.degrees.find((d) => d.id === c.degreeId)?.label;
    const hit = req.unfilled.some((u) => u.degreeLabel === label || u.degreeLabel === "both degrees");
    return hit ? { ...c, complete: false } : c;
  });
  result = { ...result, unfilled, coverage, notes: [...result.notes, ...extraNotes] };
  return {
    plan: result, unfilled, slots: req.degrees.reduce((n, d) => n + d.slots.length, 0), packs: packReports,
    ...(packError ? { packError } : {}),
  };
}
