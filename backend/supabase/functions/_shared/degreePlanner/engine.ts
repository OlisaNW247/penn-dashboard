// Glue between the request and the deterministic planner: reads the audits,
// fetches the public catalogue data they call for, runs `plan`, and runs it a
// second time once prerequisites are known so they can order the schedule.
//
// Only course codes, subjects and attribute codes leave the server (Penn Labs
// and the CIS list are public). Nothing here throws for a data problem: a
// missing catalogue leaves the plan to explicit options and says so in a note.
import type { DegreeAdvisorStructured } from "../degreeAdvisor.ts";
import { buildCatalogSnapshot } from "./catalog.ts";
import { plan } from "./planner.ts";
import { degreesFromAudits } from "./requirements.ts";
import type { CatalogSnapshot, Degree, PlanResult, Slot, Unfilled } from "./types.ts";

export const ENGINE_BUDGET_MS = 25_000;
/** A second catalogue pass needs at least this much of the budget left. */
const SECOND_PASS_MIN_MS = 4_000;

export interface EngineIntent {
  targetTerm: string | null;
  maxLoad: number | null;
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
}

export interface EngineOutput {
  plan: PlanResult;
  unfilled: Unfilled[];
  /** Counts for the log line. */
  slots: number;
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

/** Case-insensitive substring match either way on the slot's label. */
export function waivedSlotIds(degrees: Degree[], labels: string[]): { ids: string[]; unmatched: string[] } {
  const ids = new Set<string>();
  const unmatched: string[] = [];
  for (const raw of labels) {
    const w = raw.trim().toLowerCase();
    if (!w) continue;
    let hit = false;
    for (const d of degrees) {
      for (const s of d.slots as Slot[]) {
        const l = s.label.toLowerCase();
        if (l.includes(w) || w.includes(l)) {
          ids.add(s.id);
          hit = true;
        }
      }
    }
    if (!hit) unmatched.push(raw.trim());
  }
  return { ids: [...ids], unmatched };
}

export async function runEngine(input: EngineInput): Promise<EngineOutput> {
  const clock = input.clock ?? Date.now;
  const started = clock();
  const budget = input.budgetMs ?? ENGINE_BUDGET_MS;
  const remaining = () => budget - (clock() - started);

  const { structured, intent } = input;
  const req = degreesFromAudits(structured.audits);
  const taken = new Set(req.taken);
  for (const codes of Object.values(structured.history)) for (const c of codes) taken.add(normCode(c));

  const needs = collectNeeds(req.degrees);
  const extraNotes: string[] = [];

  let catalog: CatalogSnapshot = { courses: {}, attributeIndex: {}, cisTechElective: {}, semesters: [] };
  try {
    catalog = await buildCatalogSnapshot({
      fetchImpl: input.fetchImpl,
      now: input.now,
      attributes: needs.attributes,
      subjects: needs.subjects,
      codes: needs.codes,
      timeoutMs: Math.max(1000, Math.min(8000, remaining())),
    });
  } catch { /* buildCatalogSnapshot does not throw; belt and braces */ }

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

  const request = {
    degrees: req.degrees,
    taken: [...taken].sort(),
    history: structured.history,
    currentTerm: structured.currentTerm,
    ...(intent.targetTerm ? { targetTerm: intent.targetTerm } : {}),
    ...(intent.maxLoad !== null ? { maxLoad: intent.maxLoad } : {}),
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
          codes: chosenCodes,
          timeoutMs: Math.max(1000, Math.min(4000, remaining())),
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
  result = { ...result, unfilled, notes: [...result.notes, ...extraNotes] };
  return { plan: result, unfilled, slots: req.degrees.reduce((n, d) => n + d.slots.length, 0) };
}
