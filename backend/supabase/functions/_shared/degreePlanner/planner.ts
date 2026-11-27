// The degree planner: pure, synchronous, deterministic. No I/O, no clock.
//
// Two stages.
//   1. Choose courses. Each open requirement ("slot") has a set of eligible
//      courses. One course may fill one slot in each degree (and a few
//      sanctioned pairs inside a degree), so the cheapest plan is a small
//      set-cover with sharing: greedy by units covered per credit, then a
//      prune and a swap pass to remove what greed over-bought.
//   2. Schedule them. Terms come after the current one; sequences (senior
//      project), prerequisites among planned courses and the capstone rule
//      are precedence constraints; loads cap each term. A list scheduler
//      places the courses, once per load scenario.
//
// The wrong shortcut would be one model call guessing both; see types.ts.

import type {
  AdvisorQuestion,
  Approval,
  CatalogCourse,
  CatalogSnapshot,
  Eligibility,
  PlanRequest,
  PlanResult,
  PlannedCourseOut,
  PlannedTermOut,
  Scenario,
  Season,
  Slot,
  Unfilled,
} from "./types.ts";
import { pennPolicy, type Policy } from "./policy.ts";

const EPS = 1e-9;
const HORIZON = 12;

// ---------------------------------------------------------------------------
// Codes and courses
// ---------------------------------------------------------------------------

export function normalizeCode(raw: string): string {
  const s = raw.toUpperCase().replace(/\s+/g, " ").trim();
  const m = /^([A-Z&]+) ?(\d{3,4}[A-Z]?)$/.exec(s);
  return m ? `${m[1]} ${m[2]}` : s;
}

interface Alias {
  code: string;
  subject: string;
  num: number;
}

function parseAlias(code: string): Alias {
  const m = /^([A-Z&]+) (\d+)/.exec(code);
  return { code, subject: m ? m[1] : code, num: m ? parseInt(m[2], 10) : NaN };
}

/** One course, with every code it is cross-listed under folded in. */
interface CourseInfo {
  key: string;
  code: string;
  title: string;
  credits: number;
  attrs: Set<string>;
  offered: { fall: boolean; spring: boolean; summer: boolean };
  prerequisites: string;
  aliases: Alias[];
  subject: string;
  num: number;
  /** Not in the catalogue; named by an explicit option only. */
  synthetic: boolean;
}

function noOfferingData(c: CourseInfo): boolean {
  return !c.offered.fall && !c.offered.spring && !c.offered.summer;
}

/** Union-find over cross-listings; the smallest code names the group. */
function buildCanon(catalog: CatalogSnapshot): (code: string) => string {
  const parent = new Map<string, string>();
  const find = (x: string): string => {
    let r = x;
    while (parent.has(r) && parent.get(r) !== r) r = parent.get(r)!;
    parent.set(x, r);
    return r;
  };
  const union = (a: string, b: string) => {
    const ra = find(a), rb = find(b);
    if (ra === rb) return;
    if (ra < rb) parent.set(rb, ra); else parent.set(ra, rb);
  };
  for (const raw of Object.keys(catalog.courses).sort()) {
    const code = normalizeCode(raw);
    if (!parent.has(code)) parent.set(code, code);
    for (const x of catalog.courses[raw].crosslistings ?? []) {
      const n = normalizeCode(x);
      if (!parent.has(n)) parent.set(n, n);
      union(code, n);
    }
  }
  return (code) => (parent.has(code) ? find(code) : code);
}

// ---------------------------------------------------------------------------
// Slots and eligibility
// ---------------------------------------------------------------------------

interface SlotInfo {
  idx: number;
  slot: Slot;
  need: number;
  /** Eligible course indexes, ascending by course code. */
  cands: number[];
}

type Matcher = (c: CourseInfo) => boolean;

function patternRegex(pattern: string): RegExp {
  const norm = pattern.toUpperCase().replace(/\s+/g, " ").trim();
  const src = norm.split("@").map((p) => p.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")).join(".*");
  return new RegExp(`^${src}$`);
}

interface Env {
  canon: (code: string) => string;
  attrSets: Map<string, Set<string>>;
}

function compile(e: Eligibility, env: Env): Matcher {
  switch (e.kind) {
    case "courses": {
      const keys = new Set(e.codes.map((c) => env.canon(normalizeCode(c))));
      return (c) => keys.has(c.key);
    }
    case "pattern": {
      const re = patternRegex(e.pattern);
      return (c) => c.aliases.some((a) => re.test(a.code));
    }
    case "attribute": {
      const codes = e.codes.map((x) => x.toUpperCase());
      return (c) =>
        codes.some((k) => c.attrs.has(k) || env.attrSets.get(k)?.has(c.key) === true);
    }
    case "range": {
      const subj = e.subject.toUpperCase();
      return (c) => c.aliases.some((a) => a.subject === subj && a.num >= e.from && a.num <= e.to);
    }
    case "subject": {
      const subs = new Set(e.subjects.map((s) => s.toUpperCase()));
      return (c) => c.aliases.some((a) => subs.has(a.subject));
    }
    case "number": {
      const nums = new Set(e.numbers);
      return (c) => c.aliases.some((a) => nums.has(a.num));
    }
  }
}

/** 0 when matched by an explicit option, 1 by any other rule, -1 not eligible. */
type Kind = 0 | 1 | -1;

function buildMatcher(slot: Slot, env: Env, unrestricted: Set<string>): (c: CourseInfo) => Kind {
  const any = slot.anyOf.map((e) => ({ explicit: e.kind === "courses", fn: compile(e, env) }));
  const excl = slot.exclude.map((e) => compile(e, env));
  const k = slot.constraints ?? {};
  const used = new Set((k.usedSubjects ?? []).map((s) => s.toUpperCase()));
  const banned = new Set((k.excludeSubjects ?? []).map((s) => s.toUpperCase()));
  const minNumber = k.minNumber;
  // A CIS technical elective that Penn lists as "unrestricted" is as good as
  // one carrying the attribute, so it also counts when the slot is EUCU.
  const eucu = slot.group === "seas.techElective" &&
    slot.anyOf.some((e) => e.kind === "attribute" && e.codes.some((x) => x.toUpperCase() === "EUCU"));
  return (c) => {
    let best: Kind = -1;
    for (const m of any) {
      if (c.synthetic && !m.explicit) continue;
      if (m.fn(c)) {
        const kind: Kind = m.explicit ? 0 : 1;
        if (best < 0 || kind < best) best = kind;
      }
    }
    if (best < 0 && eucu && !c.synthetic && unrestricted.has(c.key)) best = 1;
    if (best < 0) return -1;
    // Numbers from 6000 up are graduate courses (FNCE 7210 is an MBA course
    // an attribute list happened to carry). Undergraduates take one only when
    // Penn names it for the requirement; no attribute, range, subject,
    // pattern, number rule or unrestricted list reaches it.
    if (best !== 0 && c.num >= 6000) return -1;
    if (!c.synthetic) for (const x of excl) if (x(c)) return -1;
    if (minNumber !== undefined && !(c.num >= minNumber)) return -1;
    if (used.has(c.subject)) return -1;
    if (banned.size && c.aliases.some((a) => banned.has(a.subject))) return -1;
    return best;
  };
}

// ---------------------------------------------------------------------------
// Choosing courses
// ---------------------------------------------------------------------------

interface Ctx {
  policy: Policy;
  slots: SlotInfo[];
  courses: CourseInfo[];
  /** per course: slot index -> kind */
  kindOf: Map<number, Kind>[];
  /** per course: eligible slot indexes, ascending */
  slotsOf: number[][];
  prefer: Set<string>;
  /** Canonical keys of the courses the student has already taken. */
  taken: Set<string>;
}

interface Opts {
  /** false: a course may fill slots in one degree only (the "no overlap" run). */
  crossDegree: boolean;
  /** Within-degree pairs allowed beyond the policy, "i|j" with i < j. */
  extra: Set<string>;
}

const pairKey = (i: number, j: number) => (i < j ? `${i}|${j}` : `${j}|${i}`);

function unit(ctx: Ctx, ci: number, si: number): number {
  return ctx.slots[si].slot.unit === "courses" ? 1 : ctx.courses[ci].credits;
}

/** What each course fills, and the coverage that implies. */
class State {
  byCourse = new Map<number, number[]>();
  cov: number[] = [];
  subj: Set<string>[] = [];
  capUsed = new Map<string, number>();
  constructor(readonly ctx: Ctx, readonly opts: Opts) {
    this.rebuild();
  }
  clone(): State {
    const s = new State(this.ctx, this.opts);
    for (const [k, v] of this.byCourse) s.byCourse.set(k, v.slice());
    s.rebuild();
    return s;
  }
  rebuild() {
    const { ctx } = this;
    this.cov = ctx.slots.map(() => 0);
    this.subj = ctx.slots.map(() => new Set<string>());
    this.capUsed = new Map();
    for (const [ci, sl] of this.byCourse) {
      const c = ctx.courses[ci];
      for (const si of sl) {
        this.cov[si] += unit(ctx, ci, si);
        if (ctx.slots[si].slot.constraints?.distinctSubjects) this.subj[si].add(c.subject);
      }
      for (const key of countedKeys(ctx, sl)) {
        this.capUsed.set(key, (this.capUsed.get(key) ?? 0) + c.credits);
      }
    }
  }
  totalCredits(): number {
    let t = 0;
    for (const ci of this.byCourse.keys()) t += this.ctx.courses[ci].credits;
    return t;
  }
}

/** Keys of the capped within-degree pairs a course's slots form. */
function countedKeys(ctx: Ctx, sl: number[]): Set<string> {
  const out = new Set<string>();
  for (let i = 0; i < sl.length; i++) {
    for (let j = i + 1; j < sl.length; j++) {
      const a = ctx.slots[sl[i]].slot, b = ctx.slots[sl[j]].slot;
      if (a.degreeId !== b.degreeId) continue;
      const cap = ctx.policy.withinDegreeCap(a, b);
      if (cap) out.add(`${a.degreeId}|${cap.key}`);
    }
  }
  return out;
}

interface Selection {
  added: number[];
  gain: number;
  explicit: boolean;
}

/** Which open slots would this course fill, given what it already fills?
 *  Forced slots first, then by units covered. Pure: changes nothing. */
function selectSlots(st: State, ci: number, forced: number[], allowCovered = false): Selection {
  const { ctx, opts } = st;
  const course = ctx.courses[ci];
  const picked = (st.byCourse.get(ci) ?? []).slice();
  const counted = countedKeys(ctx, picked);
  const capAdd = new Map<string, number>();
  const added: number[] = [];
  let gain = 0;
  let explicit = false;

  const tryAdd = (si: number): boolean => {
    const s = ctx.slots[si];
    const rem = s.need - st.cov[si];
    if ((rem <= EPS && !allowCovered) || picked.includes(si)) return false;
    if (s.slot.constraints?.distinctSubjects && st.subj[si].has(course.subject)) return false;
    let newKeys: Set<string> | null = null;
    for (const t of picked) {
      const a = s.slot, b = ctx.slots[t].slot;
      if (a.degreeId !== b.degreeId) {
        if (!opts.crossDegree) return false;
        continue;
      }
      if (!(ctx.policy.withinDegree(a, b) || opts.extra.has(pairKey(si, t)))) return false;
      const cap = ctx.policy.withinDegreeCap(a, b);
      if (cap) {
        const key = `${a.degreeId}|${cap.key}`;
        if (!counted.has(key) && !newKeys?.has(key)) {
          const used = (st.capUsed.get(key) ?? 0) + (capAdd.get(key) ?? 0);
          if (used + course.credits > cap.cu + EPS) return false;
          (newKeys ??= new Set()).add(key);
        }
      }
    }
    for (const k of newKeys ?? []) {
      counted.add(k);
      capAdd.set(k, (capAdd.get(k) ?? 0) + course.credits);
    }
    picked.push(si);
    added.push(si);
    gain += Math.min(unit(ctx, ci, si), Math.max(rem, 0));
    if (ctx.kindOf[ci].get(si) === 0) explicit = true;
    return true;
  };

  for (const f of forced) tryAdd(f);
  const rest = ctx.slotsOf[ci]
    .filter((si) => !forced.includes(si))
    .map((si) => ({ si, g: Math.min(unit(ctx, ci, si), ctx.slots[si].need - st.cov[si]) }))
    .filter((x) => allowCovered || x.g > EPS)
    // Equal gain: the slot with fewer eligible courses first, so a course
    // that could fill a scarce slot (networking) is not spent on a roomy one
    // (any CIS elective).
    .sort((a, b) => b.g - a.g || ctx.slots[a.si].cands.length - ctx.slots[b.si].cands.length || a.si - b.si);
  for (const r of rest) tryAdd(r.si);
  return { added, gain, explicit };
}

function applySelection(st: State, ci: number, sel: Selection) {
  const cur = st.byCourse.get(ci) ?? [];
  st.byCourse.set(ci, [...cur, ...sel.added].sort((a, b) => a - b));
  st.rebuild();
}

interface Cand {
  ci: number;
  sel: Selection;
  ratio: number;
}

/** Is a better than b? Ratio first, then the spec's tie-breaks. */
function better(ctx: Ctx, a: Cand, b: Cand): boolean {
  if (Math.abs(a.ratio - b.ratio) > 1e-9) return a.ratio > b.ratio;
  const ca = ctx.courses[a.ci], cb = ctx.courses[b.ci];
  const pa = ctx.prefer.has(ca.key), pb = ctx.prefer.has(cb.key);
  if (pa !== pb) return pa;
  if (a.sel.explicit !== b.sel.explicit) return a.sel.explicit;
  const ba = ca.offered.fall && ca.offered.spring, bb = cb.offered.fall && cb.offered.spring;
  if (ba !== bb) return ba;
  if (ca.num !== cb.num && !Number.isNaN(ca.num) && !Number.isNaN(cb.num)) return ca.num < cb.num;
  return ca.code < cb.code;
}

function solve(ctx: Ctx, opts: Opts): State {
  const st = new State(ctx, opts);

  // (a) A slot with one eligible course gets it.
  for (const s of ctx.slots) {
    if (s.cands.length !== 1) continue;
    const sel = selectSlots(st, s.cands[0], [s.idx]);
    if (sel.added.includes(s.idx)) applySelection(st, s.cands[0], sel);
  }

  // (b) Greedy: most units newly covered per credit. Lazy: a course's gain
  // only ever falls as slots fill, so a cached ratio is an upper bound and a
  // course is re-evaluated only when it reaches the top of the list.
  const cache: (Cand | null)[] = ctx.courses.map(() => null);
  const fresh: boolean[] = ctx.courses.map(() => false);
  const evaluate = (ci: number) => {
    const sel = selectSlots(st, ci, []);
    fresh[ci] = true;
    cache[ci] = sel.gain <= EPS ? null
      : { ci, sel, ratio: sel.gain / Math.max(ctx.courses[ci].credits, 0.01) };
  };
  for (let ci = 0; ci < ctx.courses.length; ci++) {
    if (ctx.slotsOf[ci].length && !st.byCourse.has(ci)) evaluate(ci);
  }
  for (let guard = 0; guard < 2000; guard++) {
    let pick: Cand | null = null;
    for (;;) {
      let best: Cand | null = null;
      for (let ci = 0; ci < cache.length; ci++) {
        const c = cache[ci];
        if (c && (!best || better(ctx, c, best))) best = c;
      }
      if (!best) break;
      if (fresh[best.ci]) { pick = best; break; }
      evaluate(best.ci);
    }
    if (!pick) break;
    applySelection(st, pick.ci, pick.sel);
    cache[pick.ci] = null;
    fresh.fill(false);
  }

  // (c) and (d): drop what is no longer needed, then try cheaper swaps.
  settle(st);
  for (let round = 0; round < 60; round++) {
    if (!swapOnce(st)) break;
    settle(st);
  }
  pairSequences(st);
  return st;
}

/** Where a course sits in a slot's own (Penn's) explicit option order; a
 *  course that is no explicit option sorts after all of them, by index. */
function optionRank(ctx: Ctx, si: number, ci: number): number {
  const c = ctx.courses[ci];
  let r = 0;
  for (const e of ctx.slots[si].slot.anyOf) {
    if (e.kind !== "courses") continue;
    for (const raw of e.codes) {
      const k = normalizeCode(raw);
      if (c.key === k || c.aliases.some((a) => a.code === k)) return r;
      r++;
    }
  }
  return 1e6 + ci;
}

/**
 * The two halves of a senior project are chosen slot by slot, so nothing made
 * them a matching pair: a real plan came back with CIS 4100 (thesis) for
 * "Senior Project #1" and CIS 4010 for "#2". After the greedy choice, for each
 * linked pair of slots (the same link the scheduler uses) whose courses are
 * not `isSequencePair`, look for a matching pair among the two slots' options,
 * the first in the #1 slot's own option order, and move just those two slots
 * onto it. A half the student already took counts too: if only #2 is open,
 * #2 becomes a course that pairs with a taken one. When no matching pair
 * exists the choice is left as it was (plan() adds a note). The wrong fix is
 * weighting pairs inside the greedy ratio, which would bend every other
 * requirement's choice for a naming rule that touches two slots.
 */
function pairSequences(st: State) {
  const { ctx } = st;
  const seq = ctx.policy.sequences;
  const coverers = (si: number) => [...st.byCourse.entries()].filter(([, sl]) => sl.includes(si)).map(([ci]) => ci).sort((a, b) => a - b);
  const detach = (ci: number, si: number) => {
    const rest = st.byCourse.get(ci)!.filter((x) => x !== si);
    if (rest.length) st.byCourse.set(ci, rest);
    else st.byCourse.delete(ci);
    st.rebuild();
  };
  const attach = (ci: number, si: number): boolean => {
    const sel = selectSlots(st, ci, [si]);
    if (!sel.added.includes(si)) return false;
    applySelection(st, ci, { ...sel, added: [si] });
    return true;
  };
  const ranked = (si: number) => ctx.slots[si].cands.slice().sort((a, b) => optionRank(ctx, si, a) - optionRank(ctx, si, b) || a - b);
  const attempt = (moves: [number, number][], drop: [number, number][]): boolean => {
    const snapshot = new Map([...st.byCourse].map(([k, v]) => [k, v.slice()] as [number, number[]]));
    for (const [ci, si] of drop) detach(ci, si);
    let ok = true;
    for (const [ci, si] of moves) if (!attach(ci, si)) { ok = false; break; }
    if (!ok) { st.byCourse = snapshot; st.rebuild(); }
    return ok;
  };
  const takenCodes = [...ctx.taken];
  for (const A of ctx.slots) {
    for (const B of ctx.slots) {
      if (!seq.immediatelyBefore(A.slot, B.slot)) continue;
      const xs = coverers(A.idx), ys = coverers(B.idx);
      if (xs.length !== 1 || ys.length !== 1) continue;
      const [X, Y] = [xs[0], ys[0]];
      if (seq.isSequencePair(ctx.courses[X].code, ctx.courses[Y].code)) continue;
      let done = false;
      for (const x of ranked(A.idx)) {
        for (const y of ranked(B.idx)) {
          if (x === y || !seq.isSequencePair(ctx.courses[x].code, ctx.courses[y].code)) continue;
          if (attempt([[x, A.idx], [y, B.idx]], [[X, A.idx], [Y, B.idx]])) { done = true; break; }
        }
        if (done) break;
      }
    }
  }
  // Only the second half is open: the first is already on the audit.
  for (const B of ctx.slots) {
    if (!seq.isSecondHalf(B.slot)) continue;
    if (ctx.slots.some((A) => seq.immediatelyBefore(A.slot, B.slot))) continue;
    const ys = coverers(B.idx);
    if (ys.length !== 1) continue;
    const Y = ys[0];
    if (takenCodes.some((t) => seq.isSequencePair(t, ctx.courses[Y].code))) continue;
    for (const y of ranked(B.idx)) {
      if (y === Y || !takenCodes.some((t) => seq.isSequencePair(t, ctx.courses[y].code))) continue;
      if (attempt([[y, B.idx]], [[Y, B.idx]])) break;
    }
  }
}

/** Greed fixes a course's slots when it is picked, so a course picked late
 *  never learns it could also have covered a slot an earlier pick filled.
 *  Let every chosen course join every slot it legally can, drop the courses
 *  that makes redundant, then take the surplus assignments back off so a
 *  slot lists only what it needs. */
function settle(st: State) {
  const { ctx } = st;
  const byCode = (a: number, b: number) => (ctx.courses[a].code < ctx.courses[b].code ? -1 : 1);
  for (const ci of [...st.byCourse.keys()].sort(byCode)) {
    const sel = selectSlots(st, ci, [], true);
    if (sel.added.length) applySelection(st, ci, sel);
  }
  prune(st);
  const order = [...st.byCourse.keys()].sort((a, b) =>
    st.byCourse.get(b)!.length - st.byCourse.get(a)!.length || byCode(a, b)
  );
  for (const ci of order) {
    for (const si of st.byCourse.get(ci)!.slice().reverse()) {
      const sl = st.byCourse.get(ci)!;
      if (sl.length <= 1) break;
      if (st.cov[si] - unit(ctx, ci, si) >= ctx.slots[si].need - EPS) {
        st.byCourse.set(ci, sl.filter((x) => x !== si));
        st.rebuild();
      }
    }
  }
}

/** Remove any course whose slots stay as covered without it. */
function prune(st: State) {
  const { ctx } = st;
  for (let changed = true; changed;) {
    changed = false;
    const order = [...st.byCourse.keys()].sort((a, b) =>
      ctx.courses[b].credits - ctx.courses[a].credits || (ctx.courses[a].code < ctx.courses[b].code ? -1 : 1)
    );
    for (const ci of order) {
      const sl = st.byCourse.get(ci)!;
      const ok = sl.every((si) => {
        const need = ctx.slots[si].need;
        return Math.min(need, st.cov[si] - unit(ctx, ci, si)) >= Math.min(need, st.cov[si]) - EPS;
      });
      if (ok) {
        st.byCourse.delete(ci);
        st.rebuild();
        changed = true;
      }
    }
  }
}

function slotsCanShare(st: State, sl: number[]): boolean {
  const { ctx, opts } = st;
  for (let i = 0; i < sl.length; i++) {
    for (let j = i + 1; j < sl.length; j++) {
      const a = ctx.slots[sl[i]].slot, b = ctx.slots[sl[j]].slot;
      if (a.degreeId !== b.degreeId) {
        if (!opts.crossDegree) return false;
      } else if (!(ctx.policy.withinDegree(a, b) || opts.extra.has(pairKey(sl[i], sl[j])))) {
        return false;
      }
    }
  }
  return true;
}

/** Try to replace one chosen course, or two single-slot ones, with a single
 *  cheaper course. Applies the best improvement found; false when none. */
function swapOnce(st: State): boolean {
  const { ctx } = st;
  const chosen = [...st.byCourse.keys()].sort((a, b) => (ctx.courses[a].code < ctx.courses[b].code ? -1 : 1));
  const groups: number[][] = chosen.map((c) => [c]);
  const singles = chosen.filter((c) => st.byCourse.get(c)!.length === 1);
  for (let i = 0; i < singles.length; i++) {
    for (let j = i + 1; j < singles.length; j++) groups.push([singles[i], singles[j]]);
  }
  const base = st.totalCredits();
  for (const R of groups) {
    const removed = R.reduce((t, c) => t + ctx.courses[c].credits, 0);
    const t0 = st.clone();
    for (const r of R) t0.byCourse.delete(r);
    t0.rebuild();
    const lost: number[] = [];
    for (const r of R) {
      for (const si of st.byCourse.get(r)!) {
        const need = ctx.slots[si].need;
        if (Math.min(need, t0.cov[si]) < Math.min(need, st.cov[si]) - EPS && !lost.includes(si)) lost.push(si);
      }
    }
    lost.sort((a, b) => a - b);
    if (!lost.length) {
      st.byCourse = t0.byCourse;
      st.rebuild();
      return true;
    }
    // One course must fill every lost slot, so the slots must be able to
    // share a course at all; checking once per group saves a scan of the
    // catalogue for each hopeless pair.
    if (!slotsCanShare(st, lost)) continue;
    // Cheap rejections first; only the best survivor is built for real.
    let bestTrial: { d: number; sel: Selection; total: number; code: string } | null = null;
    for (const d of ctx.slots[lost[0]].cands) {
      const dc = ctx.courses[d];
      if (t0.byCourse.has(d) || R.includes(d)) continue;
      if (dc.credits >= removed - EPS) continue;
      if (!lost.every((si) => ctx.kindOf[d].has(si))) continue;
      const sel = selectSlots(t0, d, lost);
      const fine = lost.every((si) => {
        if (!sel.added.includes(si)) return false;
        const need = ctx.slots[si].need;
        return Math.min(need, t0.cov[si] + unit(ctx, d, si)) >= Math.min(need, st.cov[si]) - EPS;
      });
      if (!fine) continue;
      const total = base - removed + dc.credits;
      if (total >= base - EPS) continue;
      if (!bestTrial || total < bestTrial.total - EPS || (Math.abs(total - bestTrial.total) <= EPS && dc.code < bestTrial.code)) {
        bestTrial = { d, sel, total, code: dc.code };
      }
    }
    if (bestTrial) {
      applySelection(t0, bestTrial.d, bestTrial.sel);
      st.byCourse = t0.byCourse;
      st.rebuild();
      return true;
    }
  }
  return false;
}

// ---------------------------------------------------------------------------
// Scheduling
// ---------------------------------------------------------------------------

interface Item {
  ci: number;
  course: CourseInfo;
  slots: number[];
}

interface Constraints {
  preds: Map<number, Set<number>>;
  /** first -> second, placed in fall then the following spring */
  next: Map<number, number>;
  linkedFrom: Map<number, number>;
  hasCapstoneRule: boolean;
  height: Map<number, number>;
  /** Courses that gate a fixed-season pair (everything before a senior project). */
  urgent: Set<number>;
}

function nextTerm(t: string): string {
  const y = parseInt(t.slice(0, 4), 10);
  const s = t.slice(4);
  if (s === "10") return `${y}20`;
  if (s === "20") return `${y}30`;
  return `${y + 1}10`;
}

function seasonOf(t: string): Season {
  const s = t.slice(4);
  return s === "10" ? "spring" : s === "20" ? "summer" : "fall";
}

export function termLabel(t: string): string {
  return `${seasonOf(t)} ${t.slice(0, 4)}`;
}

function escapeRe(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function buildConstraints(items: Item[], ctx: Ctx): Constraints {
  const { policy } = ctx;
  const preds = new Map<number, Set<number>>();
  for (const it of items) preds.set(it.ci, new Set());
  const next = new Map<number, number>();
  const linkedFrom = new Map<number, number>();

  // Sequences: senior project #1 then #2.
  for (const a of items) {
    for (const b of items) {
      if (a.ci === b.ci || next.has(a.ci) || linkedFrom.has(b.ci)) continue;
      const hit = a.slots.some((sa) =>
        b.slots.some((sb) => policy.sequences.immediatelyBefore(ctx.slots[sa].slot, ctx.slots[sb].slot))
      );
      if (hit) {
        next.set(a.ci, b.ci);
        linkedFrom.set(b.ci, a.ci);
      }
    }
  }

  // Capstone rule.
  let hasCapstoneRule = false;
  const capItems = items.filter((it) => it.slots.some((s) => policy.capstoneRule.isCapstone(ctx.slots[s].slot)));
  for (const cap of capItems) {
    for (const it of items) {
      if (it.ci === cap.ci) continue;
      if (it.slots.some((s) => policy.capstoneRule.mustPrecedeCapstone(ctx.slots[s].slot))) {
        preds.get(cap.ci)!.add(it.ci);
        hasCapstoneRule = true;
      }
    }
  }

  // Prerequisites that name another planned course.
  if (policy.sequences.prerequisiteOrdering) {
    for (const x of items) {
      const text = x.course.prerequisites.toUpperCase();
      if (!text) continue;
      for (const y of items) {
        if (y.ci === x.ci) continue;
        const re = new RegExp(
          `(^|[^A-Z0-9])(${y.course.aliases.map((a) => escapeRe(a.code).replace(" ", "\\s?")).join("|")})(?![0-9])`,
        );
        if (re.test(text)) preds.get(x.ci)!.add(y.ci);
      }
    }
  }

  breakCycles(items, preds, next, ctx);

  // Height: the longest chain that depends on a course.
  const succs = new Map<number, number[]>();
  for (const it of items) succs.set(it.ci, []);
  for (const [x, ps] of preds) for (const p of ps) succs.get(p)!.push(x);
  for (const [a, b] of next) succs.get(a)!.push(b);
  const height = new Map<number, number>();
  const h = (x: number): number => {
    const known = height.get(x);
    if (known !== undefined) return known;
    height.set(x, 0);
    let m = 0;
    for (const s of succs.get(x)!) m = Math.max(m, 1 + h(s));
    height.set(x, m);
    return m;
  };
  for (const it of items) h(it.ci);
  const urgent = new Set<number>();
  const mark = (x: number) => {
    for (const p of preds.get(x)!) if (!urgent.has(p)) { urgent.add(p); mark(p); }
  };
  for (const a of next.keys()) mark(a);
  return { preds, next, linkedFrom, hasCapstoneRule, height, urgent };
}

/** "A mentions B and B mentions A" (an "or" in prerequisite text) is not an
 *  order. Drop edges until the graph can be sorted, smallest code first. */
function breakCycles(items: Item[], preds: Map<number, Set<number>>, next: Map<number, number>, ctx: Ctx) {
  const all = (x: number): number[] => {
    const out = [...preds.get(x)!];
    for (const [a, b] of next) if (b === x) out.push(a);
    return out;
  };
  for (let guard = 0; guard < items.length + 5; guard++) {
    const done = new Set<number>();
    for (let progress = true; progress;) {
      progress = false;
      for (const it of items) {
        if (!done.has(it.ci) && all(it.ci).every((p) => done.has(p))) {
          done.add(it.ci);
          progress = true;
        }
      }
    }
    const left = items.filter((it) => !done.has(it.ci));
    if (!left.length) return;
    left.sort((a, b) => (ctx.courses[a.ci].code < ctx.courses[b.ci].code ? -1 : 1));
    const target = left[0].ci;
    const ps = preds.get(target)!;
    let removedAny = false;
    for (const p of [...ps]) if (!done.has(p)) { ps.delete(p); removedAny = true; }
    if (!removedAny) {
      for (const [a, b] of [...next]) if (b === target) { next.delete(a); removedAny = true; }
    }
    if (!removedAny) return;
  }
}

interface Run {
  placed: Map<number, number>;
  unplaced: number[];
  finishIdx: number;
}

function runSchedule(
  items: Item[],
  cons: Constraints,
  terms: string[],
  params: { maxLoad: number; summer: boolean; summerLoad: number },
  policy: Policy,
  variant: 0 | 1,
  /** Credits already registered in each term (same index as `terms`). A
   *  term's load is registered plus planned, so these seed the load; a term
   *  already at or over its cap simply has no room (never negative). */
  seed: number[],
): Run {
  const byCi = new Map(items.map((i) => [i.ci, i]));
  const load = terms.map((_, i) => seed[i] ?? 0);
  const placed = new Map<number, number>();
  const failed = new Set<number>();

  const offeredIn = (it: Item, t: number) => noOfferingData(it.course) || it.course.offered[seasonOf(terms[t])];
  const room = (t: number, credits: number): boolean => {
    if (seasonOf(terms[t]) === "summer") {
      // One summer's limit only: Engineering's handbook (Enrollment page,
      // read 2026-11-26) sets no cap across summers, so no running total.
      return params.summer && load[t] + credits <= params.summerLoad + EPS;
    }
    return load[t] + credits <= params.maxLoad + EPS;
  };
  const put = (it: Item, t: number) => {
    placed.set(it.ci, t);
    load[t] += it.course.credits;
  };
  const predsOk = (ci: number, t: number, skip: number | undefined): boolean => {
    for (const p of cons.preds.get(ci)!) {
      if (p === skip) continue;
      const pt = placed.get(p);
      if (pt === undefined || pt >= t) return false;
    }
    return true;
  };
  const required = (ci: number): number[] => {
    const out = [...cons.preds.get(ci)!];
    const link = cons.next.get(ci);
    if (link !== undefined) for (const p of cons.preds.get(link)!) if (p !== ci) out.push(p);
    return out;
  };
  const priority = (a: Item, b: Item): number => {
    // Variant 1 puts what gates a fall-to-spring pair first: a fundamental
    // squeezed out of spring pushes the capstone a whole year.
    if (variant === 1) {
      const ua = cons.urgent.has(a.ci), ub = cons.urgent.has(b.ci);
      if (ua !== ub) return ua ? -1 : 1;
    }
    const ha = cons.height.get(a.ci)!, hb = cons.height.get(b.ci)!;
    if (ha !== hb) return hb - ha;
    const sa = noOfferingData(a.course) ? 3 : Object.values(a.course.offered).filter(Boolean).length;
    const sb = noOfferingData(b.course) ? 3 : Object.values(b.course.offered).filter(Boolean).length;
    if (sa !== sb) return sa - sb;
    return a.course.code < b.course.code ? -1 : 1;
  };
  const fail = (it: Item) => {
    failed.add(it.ci);
    const link = cons.next.get(it.ci);
    if (link !== undefined) failed.add(link);
  };

  const remaining = new Set(items.filter((i) => !cons.linkedFrom.has(i.ci)).map((i) => i.ci));
  while (remaining.size) {
    // Anything waiting on a course that could not be placed cannot be placed.
    for (const ci of [...remaining]) {
      if (required(ci).some((p) => failed.has(p))) {
        fail(byCi.get(ci)!);
        remaining.delete(ci);
      }
    }
    const ready = [...remaining].map((ci) => byCi.get(ci)!)
      .filter((it) => required(it.ci).every((p) => placed.has(p)))
      .sort(priority);
    if (!ready.length) {
      for (const ci of remaining) fail(byCi.get(ci)!);
      break;
    }
    const it = ready[0];
    remaining.delete(it.ci);
    const link = cons.next.get(it.ci);
    const second = link !== undefined ? byCi.get(link)! : undefined;
    let done = false;
    for (let t = 0; t < terms.length && !done; t++) {
      if (!offeredIn(it, t) || !predsOk(it.ci, t, undefined) || !room(t, it.course.credits)) continue;
      if (second) {
        if (seasonOf(terms[t]) !== "fall") continue;
        let t2 = t + 1;
        while (t2 < terms.length && seasonOf(terms[t2]) === "summer") t2++;
        if (t2 >= terms.length) continue;
        if (!offeredIn(second, t2) || !predsOk(second.ci, t2, it.ci) || !room(t2, second.course.credits)) continue;
        put(it, t);
        put(second, t2);
      } else {
        put(it, t);
      }
      done = true;
    }
    if (!done) fail(it);
  }

  // A term the student is already registered in is part of the plan's span:
  // with nothing left to place, the finish is the last registered term.
  let finishIdx = -1;
  for (const t of placed.values()) finishIdx = Math.max(finishIdx, t);
  seed.forEach((cu, i) => { if (cu > EPS) finishIdx = Math.max(finishIdx, i); });
  const unplaced = items.filter((i) => !placed.has(i.ci)).map((i) => i.ci);
  return { placed, unplaced, finishIdx };
}

// ---------------------------------------------------------------------------
// plan()
// ---------------------------------------------------------------------------

function whoDecidesShort(colleges: (string | undefined)[]): string {
  const eng = colleges.includes("EU"), wh = colleges.includes("WU");
  return eng && wh ? "approval from Engineering and Wharton" : eng ? "approval from Engineering" : wh ? "a petition to Wharton" : "your advisor's approval";
}
function whoDecidesLong(colleges: (string | undefined)[]): string {
  const eng = colleges.includes("EU"), wh = colleges.includes("WU");
  return eng && wh
    ? "Engineering's department and Wharton's Petitions Committee decide"
    : eng ? "Engineering's department decides"
    : wh ? "Wharton's Petitions Committee decides" : "your advisor decides";
}

const fmt = (n: number) => (Number.isInteger(n) ? String(n) : n.toFixed(1));

export function plan(req: PlanRequest, catalog: CatalogSnapshot, policy: Policy = pennPolicy): PlanResult {
  const canon = buildCanon(catalog);

  // ---- courses -----------------------------------------------------------
  const groups = new Map<string, CatalogCourse[]>();
  for (const raw of Object.keys(catalog.courses).sort()) {
    const course = { ...catalog.courses[raw], code: normalizeCode(catalog.courses[raw].code || raw) };
    const key = canon(normalizeCode(raw));
    if (!groups.has(key)) groups.set(key, []);
    groups.get(key)!.push(course);
  }
  const courses: CourseInfo[] = [];
  const byKey = new Map<string, number>();
  const addCourse = (c: CourseInfo) => {
    byKey.set(c.key, courses.length);
    courses.push(c);
  };
  for (const key of [...groups.keys()].sort()) {
    const g = groups.get(key)!;
    const base = g.find((c) => c.code === key) ?? g[0];
    const aliasCodes = new Set<string>();
    const attrs = new Set<string>();
    const offered = { fall: false, spring: false, summer: false };
    for (const c of g) {
      aliasCodes.add(c.code);
      for (const x of c.crosslistings ?? []) aliasCodes.add(normalizeCode(x));
      for (const a of c.attributes) attrs.add(a.toUpperCase());
      offered.fall ||= c.offered.fall;
      offered.spring ||= c.offered.spring;
      offered.summer ||= c.offered.summer;
    }
    aliasCodes.add(key);
    const p = parseAlias(key);
    addCourse({
      key,
      code: key,
      title: base.title,
      credits: base.credits,
      attrs,
      offered,
      prerequisites: g.map((c) => c.prerequisites ?? "").find((t) => t) ?? "",
      aliases: [...aliasCodes].sort().map(parseAlias),
      subject: p.subject,
      num: p.num,
      synthetic: false,
    });
  }

  const taken = new Set(req.taken.map((c) => canon(normalizeCode(c))));
  const avoid = new Set((req.avoid ?? []).map((c) => canon(normalizeCode(c))));
  const prefer = new Set((req.prefer ?? []).map((c) => canon(normalizeCode(c))));
  const waive = new Set(req.waive ?? []);

  // ---- the student's recorded advisor answers ---------------------------
  // Used for this request only. A later answer to the same id wins.
  const answers = new Map<string, "yes" | "no">();
  for (const a of req.advisorAnswers ?? []) answers.set(a.id, a.answer);
  let loadYes: number | null = null;
  let loadNo = false;
  for (const [id, a] of answers) {
    const m = /^load:(\d+(?:\.\d+)?)$/.exec(id);
    if (!m) continue;
    if (a === "yes") loadYes = Math.max(loadYes ?? 0, Number(m[1]));
    else loadNo = true;
  }
  // A recorded "no" beats a chat statement or a yes: the advisor's word is the
  // newest word. (A yes and a no on different loads: the no wins, which is the
  // cautious side.)
  if (loadNo) loadYes = null;

  const attrSets = new Map<string, Set<string>>();
  for (const [attr, codes] of Object.entries(catalog.attributeIndex)) {
    attrSets.set(attr.toUpperCase(), new Set(codes.map((c) => canon(normalizeCode(c)))));
  }
  const unrestricted = new Set<string>();
  for (const [code, status] of Object.entries(catalog.cisTechElective)) {
    if (status === "unrestricted") unrestricted.add(canon(normalizeCode(code)));
  }
  const env: Env = { canon, attrSets };

  // The language requirement the best case assumes is met by Penn's placement
  // exam, per degree. Judged over every language slot the request did not
  // already waive, so an advisor's "yes" (which waives them below) does not
  // make the question disappear.
  const langAll = req.degrees.flatMap((d) => d.slots).filter((s) => s.group === "wharton.language" && s.need > EPS && !waive.has(s.id));
  const langSubjects = new Set<string>();
  for (const s of langAll) {
    const match = buildMatcher(s, env, unrestricted);
    for (const c of courses) if (match(c) >= 0) langSubjects.add(c.subject);
  }
  const takenSubjectSet = new Set([...taken].map((k) => parseAlias(k).subject));
  const noLanguageHistory = langAll.length > 0 && ![...langSubjects].some((x) => takenSubjectSet.has(x));
  const placementAnswer = (degreeId: string) => answers.get(`placement:language:${degreeId}`) ?? null;
  const placementDegrees = noLanguageHistory ? [...new Set(langAll.map((s) => s.degreeId))] : [];
  const placementConfirmed: string[] = [];
  for (const d of placementDegrees) {
    if (placementAnswer(d) !== "yes") continue;
    placementConfirmed.push(d);
    for (const s of langAll) if (s.degreeId === d) waive.add(s.id);
  }

  // ---- slots -------------------------------------------------------------
  // Wharton counts an Engineering senior design project as the capstone for a
  // Wharton + Engineering student (Senior Capstone page, 2026-11-26), so that
  // slot is left out like a waived one, in every scenario including "best".
  let capstoneBySeniorDesign = false;
  const active = req.degrees.flatMap((d) => d.slots).filter((s) => {
    if (waive.has(s.id) || s.need <= EPS) return false;
    if (policy.capstoneRule.satisfiedBySeniorDesign(s, req.degrees)) {
      capstoneBySeniorDesign = true;
      return false;
    }
    return true;
  });

  // Explicit options the catalogue lacks are possible but unverified.
  for (const s of active) {
    for (const e of s.anyOf) {
      if (e.kind !== "courses") continue;
      for (const raw of e.codes) {
        const key = canon(normalizeCode(raw));
        if (byKey.has(key) || taken.has(key) || avoid.has(key)) continue;
        const p = parseAlias(key);
        addCourse({
          key, code: key, title: key, credits: 1, attrs: new Set(),
          offered: { fall: false, spring: false, summer: false }, prerequisites: "",
          aliases: [p], subject: p.subject, num: p.num, synthetic: true,
        });
      }
    }
  }

  const makeCtx = (list: Slot[], pol: Policy): Ctx => {
    const kindOf: Map<number, Kind>[] = courses.map(() => new Map());
    const slotsOf: number[][] = courses.map(() => []);
    const slots: SlotInfo[] = list.map((slot, idx) => ({ idx, slot, need: slot.need, cands: [] }));
    for (const s of slots) {
      const match = buildMatcher(s.slot, env, unrestricted);
      for (let ci = 0; ci < courses.length; ci++) {
        const c = courses[ci];
        if (taken.has(c.key) || avoid.has(c.key)) continue;
        const k = match(c);
        if (k < 0) continue;
        s.cands.push(ci);
        kindOf[ci].set(s.idx, k);
        slotsOf[ci].push(s.idx);
      }
    }
    return { policy: pol, slots, courses, kindOf, slotsOf, prefer, taken };
  };
  const ctx = makeCtx(active, policy);
  const { slots, kindOf } = ctx;

  // ---- choose ------------------------------------------------------------
  // First the candidate within-degree petitions, judged from the plain solve
  // (no extras), so a question's id and its saving do not move with answers.
  const main0 = solve(ctx, { crossDegree: true, extra: new Set() });
  const remainingCredits = main0.totalCredits();
  const skey = (a: Slot, b: Slot) => [a.id, b.id].sort().join("+");
  interface Candidate { i: number; j: number; code: string; saves: number; fills: boolean; id: string; a: Slot; b: Slot }
  const coveredOf = (st: State) => slots.reduce((n, s) => n + Math.min(s.need, st.cov[s.idx]), 0);
  const candidates: Candidate[] = [];
  for (let i = 0; i < slots.length; i++) {
    for (let j = i + 1; j < slots.length; j++) {
      const a = slots[i].slot, b = slots[j].slot;
      if (a.degreeId !== b.degreeId) continue;
      if (policy.withinDegree(a, b) || !(policy.petitionPairs(a, b) || policy.petitionPairs(b, a))) continue;
      const shared = slots[i].cands.some((c) => kindOf[c].has(j));
      if (!shared) continue;
      const alt = solve(ctx, { crossDegree: true, extra: new Set([pairKey(i, j)]) });
      const saves = remainingCredits - alt.totalCredits();
      // A pair is worth asking about when it saves credits, or when it lets
      // one course fill a slot the plain solve could not fill at all (two slots
      // that each want the only listed course).
      const fills = coveredOf(alt) > coveredOf(main0) + EPS;
      if (saves <= EPS && !fills) continue;
      let code = "";
      for (const [ci, sl] of alt.byCourse) if (sl.includes(i) && sl.includes(j)) code = courses[ci].code;
      if (!code) continue;
      candidates.push({ i, j, code, saves: Math.max(0, Math.round(saves * 1000) / 1000), fills, id: `doubleCount:${a.degreeId}:${code}:${skey(a, b)}`.slice(0, 200), a, b });
    }
  }
  candidates.sort((x, y) => y.saves - x.saves || (x.code < y.code ? -1 : x.code > y.code ? 1 : 0));
  // A "yes" grants that pair to the ordinary scenarios (the solver's own
  // `extra` mechanism, by slot); a "no" takes it away from every scenario,
  // best included. Slot-level, not course-level: the id names the course the
  // plain solve used, and the wrong fix of tracking courses would need the
  // solver to know them. Known limit: another course that could use the same
  // slot pair is refused or granted with it.
  const grantedKeys = new Set<string>();
  const deniedKeys = new Set<string>();
  const grantedExtra = new Set<string>();
  const grantedNotes: string[] = [];
  for (const c of candidates) {
    const a = answers.get(c.id);
    if (a === "yes") {
      grantedKeys.add(skey(c.a, c.b));
      grantedExtra.add(pairKey(c.i, c.j));
      grantedNotes.push(`your advisor approved ${c.code} for both ${c.a.label.trim()} and ${c.b.label.trim()}`);
    } else if (a === "no") deniedKeys.add(skey(c.a, c.b));
  }
  const petitions: PlanResult["petitions"] = candidates
    .filter((c) => c.saves > EPS && !grantedKeys.has(skey(c.a, c.b)) && !deniedKeys.has(skey(c.a, c.b)))
    .map((c) => ({ code: c.code, slots: [`${c.a.degreeLabel} · ${c.a.label}`, `${c.b.degreeLabel} · ${c.b.label}`], savesCredits: c.saves }));

  // The best case: every petition pair not refused counts as if an advisor
  // approved it, and the language requirement is met by the placement exam
  // when the student has taken nothing in a language subject and has not been
  // told no. A separate solve over the same machinery, with a policy that
  // allows the pairs.
  const bestPolicy: Policy = {
    ...policy,
    withinDegree: (a, b) =>
      policy.withinDegree(a, b) ||
      ((policy.petitionPairs(a, b) || policy.petitionPairs(b, a)) && !deniedKeys.has(skey(a, b))),
  };
  const dropForBest = new Set(placementDegrees.filter((d) => placementAnswer(d) !== "no" && !placementConfirmed.includes(d)));
  const bestSlots = active.filter((s) => !(s.group === "wharton.language" && dropForBest.has(s.degreeId)));
  const placesOut = bestSlots.length < active.length;
  const bestCtx = makeCtx(bestSlots, bestPolicy);

  const main = grantedExtra.size ? solve(ctx, { crossDegree: true, extra: grantedExtra }) : main0;
  const flat = solve(ctx, { crossDegree: false, extra: grantedExtra });
  const bestMain = solve(bestCtx, { crossDegree: true, extra: new Set() });
  const remainingCreditsWithoutOverlap = flat.totalCredits();

  // ---- unfilled ----------------------------------------------------------
  // Never an empty label: the phone prints it in a sentence.
  const unfilledOf = (c: Ctx, st: State): Unfilled[] => {
    const out: Unfilled[] = [];
    for (const s of c.slots) {
      const covered = Math.min(s.need, st.cov[s.idx]);
      if (covered >= s.need - EPS) continue;
      const word = s.slot.unit === "cu" ? "cu" : "courses";
      out.push({
        slotId: s.slot.id,
        degreeLabel: s.slot.degreeLabel,
        label: s.slot.label.trim() || s.slot.blockTitle.trim() || "a requirement",
        reason: s.cands.length === 0
          ? "no eligible course found in Penn's catalogue"
          : `only ${fmt(covered)} of ${fmt(s.need)} ${word} can be filled from Penn's catalogue`,
      });
    }
    return out;
  };

  // ---- schedule ----------------------------------------------------------
  interface Assign { ctx: Ctx; st: State; items: Item[]; cons: Constraints }
  const mkAssign = (c: Ctx, st: State): Assign => {
    const items: Item[] = [...st.byCourse.entries()]
      .map(([ci, sl]) => ({ ci, course: courses[ci], slots: sl.slice().sort((a, b) => a - b) }))
      .sort((a, b) => (a.course.code < b.course.code ? -1 : 1));
    return { ctx: c, st, items, cons: buildConstraints(items, c) };
  };
  const mainA = mkAssign(ctx, main);
  const bestA = mkAssign(bestCtx, bestMain);

  const terms: string[] = [];
  for (let t = req.currentTerm, n = 0; n < HORIZON; n++) {
    t = nextTerm(t);
    terms.push(t);
  }

  const seed = terms.map((t) => Math.max(0, req.registered?.[t] ?? 0));

  // A load the student reports they are already approved for is a fact: no
  // note, label or approval may call it something still to be granted. The
  // figure is the load they named, else Penn's approved load; the wrong fix is
  // treating "approved" as "any load", which would hide a real request for 7.
  const approvedFigure: number | null = loadYes !== null
    ? loadYes
    : !loadNo && req.loadApproved === true ? (req.maxLoad ?? policy.loads.approved) : null;
  // An advisor's "no" on a load: nothing above the standard load is planned.
  const cap = (n: number) => (loadNo ? Math.min(n, policy.loads.standard) : n);
  const loadIsApproved = (n: number) => approvedFigure !== null && n <= approvedFigure + EPS;
  const summerOk = req.allowSummer !== false;
  // `summerLoad` is the most one summer may hold in that scenario. The
  // ordinary scenarios use the planner's cautious default (one course per
  // session); only "best" reaches Penn's own ceiling.
  const sl = policy.loads.summerPerTerm;
  const defs: { id: Scenario["id"]; label: string; maxLoad: number; summer: boolean; summerLoad: number }[] = [
    { id: "standard", label: `${fmt(policy.loads.standard)} cu a semester, no summer`, maxLoad: policy.loads.standard, summer: false, summerLoad: sl },
    { id: "summer", label: `${fmt(policy.loads.standard)} cu a semester, summers at ${fmt(policy.loads.summerPerTerm)} cu`, maxLoad: policy.loads.standard, summer: summerOk, summerLoad: sl },
    { id: "approved", label: `${fmt(cap(policy.loads.approved))} cu a semester, summers at ${fmt(policy.loads.summerPerTerm)} cu`, maxLoad: cap(policy.loads.approved), summer: summerOk, summerLoad: sl },
  ];
  // Penn's own summer limit (4 cu a summer, Engineering's Enrollment page) is a
  // rule, not an approval, so it gets an ordinary scenario: the highest load
  // the student may take without a NEW approval (6.5 only when they said they
  // have it) with summers at the ceiling, no petitions, no placement exam.
  // The wrong fix is leaving the 4 cu summer inside "best", which then looked
  // like it depended on approvals it does not need.
  const freeLoad = approvedFigure !== null && approvedFigure > policy.loads.standard + EPS ? approvedFigure : policy.loads.standard;
  if (summerOk) {
    defs.push({
      id: "fullSummer",
      label: `${fmt(freeLoad)} cu a semester, summers at up to ${fmt(policy.loads.summerCeiling)} cu`,
      maxLoad: freeLoad,
      summer: true,
      summerLoad: policy.loads.summerCeiling,
    });
  }
  if (req.maxLoad !== undefined) {
    defs.push({
      id: "student",
      label: `${fmt(cap(req.maxLoad))} cu a semester${summerOk ? `, summers at ${fmt(policy.loads.summerPerTerm)} cu` : ", no summer"}`,
      maxLoad: cap(req.maxLoad),
      summer: summerOk,
      summerLoad: sl,
    });
  }
  defs.push({
    id: "best",
    label: `${fmt(cap(policy.loads.approved))} cu${loadIsApproved(policy.loads.approved) ? " (already approved)" : ""}${summerOk ? `, summers at up to ${fmt(policy.loads.summerCeiling)} cu` : ""}, your advisor's approvals and the language placement exam`,
    maxLoad: cap(policy.loads.approved),
    summer: summerOk,
    summerLoad: policy.loads.summerCeiling,
  });
  const runs = defs.map((d) => {
    // "best" schedules its own course set; the others share the main one.
    const A = d.id === "best" ? bestA : mainA;
    // Two list orders; keep the one that finishes sooner (ties: the first).
    const first = runSchedule(A.items, A.cons, terms, d, policy, 0, seed);
    const second = A.cons.urgent.size ? runSchedule(A.items, A.cons, terms, d, policy, 1, seed) : first;
    const score = (r: Run) => [r.unplaced.length, r.finishIdx] as const;
    const [fa, fb] = [score(first), score(second)];
    const run = fb[0] < fa[0] || (fb[0] === fa[0] && fb[1] < fa[1]) ? second : first;
    const finishTerm = run.unplaced.length ? null : (run.finishIdx >= 0 ? terms[run.finishIdx] : req.currentTerm);
    const meetsTarget = finishTerm !== null && (req.targetTerm === undefined || finishTerm <= req.targetTerm);
    const scenario: Scenario = { id: d.id, label: d.label, maxLoad: d.maxLoad, summer: d.summer, finishTerm, meetsTarget };
    return { scenario, run };
  });

  const byId = (id: Scenario["id"]) => runs.find((r) => r.scenario.id === id);
  // What may be drawn as THE plan. "best" leans on approvals and a placement
  // exam nobody granted, so it is chosen only when the student asks to see it
  // (assumeApprovals). An ordinary scenario is eligible when its load needs no
  // new approval: at most the standard load, a load the student reports they
  // have, or the load they themselves asked for. The "approved" scenario at
  // 6.5 is therefore eligible only when 6.5 is a stated fact. The wrong fix is
  // letting best win whenever it is the only one that meets the target: that
  // wrote a schedule resting on double counts no Penn page supports into the
  // student's table as if it were a plan he could follow.
  const eligible = runs.filter((r) => {
    const id = r.scenario.id;
    if (id === "best") return req.assumeApprovals === true;
    if (id === "student") return true;
    return r.scenario.maxLoad <= policy.loads.standard + EPS || loadIsApproved(r.scenario.maxLoad);
  });
  const order: Scenario["id"][] = ["student", "standard", "summer", "fullSummer", "approved", "best"];
  const inOrder = order.map((id) => eligible.find((r) => r.scenario.id === id)).filter((r): r is NonNullable<typeof r> => !!r);
  let chosenRun = inOrder.find((r) => r.scenario.meetsTarget);
  if (!chosenRun) {
    const finished = eligible.filter((r) => r.scenario.finishTerm !== null);
    const pool = finished.length ? finished : eligible;
    chosenRun = pool.slice().sort((a, b) => {
      if (finished.length) {
        const fa = a.scenario.finishTerm!, fb = b.scenario.finishTerm!;
        if (fa !== fb) return fa < fb ? -1 : 1;
      } else if (a.run.placed.size !== b.run.placed.size) {
        return b.run.placed.size - a.run.placed.size;
      }
      return a.scenario.maxLoad - b.scenario.maxLoad || order.indexOf(a.scenario.id) - order.indexOf(b.scenario.id);
    })[0];
  }
  const chosen = chosenRun.scenario;
  const A = chosen.id === "best" ? bestA : mainA;
  const { items, cons } = A;
  const chosenSlots = A.ctx.slots;
  const chosenCredits = A.st.totalCredits();
  const unfilled = unfilledOf(A.ctx, A.st);

  const label = (si: number) => `${chosenSlots[si].slot.degreeLabel} · ${chosenSlots[si].slot.label}`;
  // A course that fills two slots only a petition pair joins (judged by the
  // standing policy, not the best-case variant) needs an advisor's yes.
  // A pair the advisor granted is no longer a petition; one refused is never
  // planned, so it cannot appear either.
  const petitionPairsOf = (it: Item, slotList: SlotInfo[] = chosenSlots): [number, number][] => {
    const out: [number, number][] = [];
    for (let i = 0; i < it.slots.length; i++) {
      for (let j = i + 1; j < it.slots.length; j++) {
        const a = slotList[it.slots[i]].slot, b = slotList[it.slots[j]].slot;
        if (a.degreeId !== b.degreeId || policy.withinDegree(a, b)) continue;
        if (grantedKeys.has(skey(a, b)) || deniedKeys.has(skey(a, b))) continue;
        if (policy.petitionPairs(a, b) || policy.petitionPairs(b, a)) out.push([it.slots[i], it.slots[j]]);
      }
    }
    return out;
  };
  const outFor = (it: Item): PlannedCourseOut => {
    const check = it.course.synthetic || noOfferingData(it.course);
    const approval: Approval = petitionPairsOf(it).length ? "petition" : check ? "check" : "automatic";
    const out: PlannedCourseOut = {
      code: it.course.code,
      title: it.course.title,
      credits: it.course.credits,
      countsToward: it.slots.map(label),
      slotIds: it.slots.map((si) => chosenSlots[si].slot.id),
      approval,
    };
    if (approval === "petition") out.note = "counting it twice in one degree needs your advisor's approval";
    else if (it.course.synthetic) out.note = "not in the catalogue data; check it is offered";
    else if (check) out.note = "no offering data; the term is a guess";
    return out;
  };
  const schedule: PlannedTermOut[] = [];
  const termOf = new Map<number, number>();
  for (const [ci, t] of chosenRun.run.placed) termOf.set(ci, t);
  for (let t = 0; t < terms.length; t++) {
    const here = items.filter((i) => termOf.get(i.ci) === t);
    // A term with registered courses and nothing new still appears, so the
    // phone and the explanation see its full load.
    if (!here.length && !(seed[t] > EPS)) continue;
    schedule.push({
      term: terms[t],
      courses: here.map(outFor),
      credits: here.reduce((s, i) => s + i.course.credits, 0),
      ...(seed[t] > EPS ? { registeredCredits: seed[t] } : {}),
    });
  }

  // ---- notes -------------------------------------------------------------
  const notes: string[] = [];
  const saved = remainingCreditsWithoutOverlap - chosenCredits;
  if (saved > EPS) notes.push(`counting courses toward both degrees saves ${fmt(Math.round(saved * 100) / 100)} cu`);
  const byCi = new Map(items.map((i) => [i.ci, i]));
  // What "best" leans on, named exactly, so the explanation can say it.
  const bestAssumptions = (): string[] => {
    const out: string[] = loadIsApproved(policy.loads.approved) ? [] : [`${fmt(policy.loads.approved)} cu semesters, which need approval`];
    if (chosen.summer) out.push(`summer courses, up to ${fmt(policy.loads.summerCeiling)} cu a summer${req.degrees.some((d) => d.college === "EU") ? " (Engineering's limit, 2 per session)" : ""}`);
    for (const it of items) {
      for (const [i, j] of petitionPairsOf(it)) {
        out.push(`your advisor approving ${it.course.code} for both ${label(i)} and ${label(j)}`);
      }
    }
    if (placesOut) out.push("you place out of the language requirement with Penn's placement exam");
    return out;
  };
  for (const [a, b] of cons.next) {
    const ta = termOf.get(a), tb = termOf.get(b);
    if (ta === undefined || tb === undefined) continue;
    const sl = byCi.get(a)!.slots.map((s) => chosenSlots[s].slot.label).find((l) => /#\s*1\b/.test(l)) ?? "sequence";
    const name = sl.replace(/#\s*1\b/, "").trim().toLowerCase();
    notes.push(`${byCi.get(a)!.course.code} goes in ${termLabel(terms[ta])} and ${byCi.get(b)!.course.code} in ${termLabel(terms[tb])} (${name} runs fall to spring)`);
    if (!policy.sequences.isSequencePair(byCi.get(a)!.course.code, byCi.get(b)!.course.code)) {
      notes.push(`check with your department that ${byCi.get(a)!.course.code} and ${byCi.get(b)!.course.code} are the two halves of one ${name || "senior project"}`);
    }
  }
  // Within-degree double counts that rest on a template block matched only by
  // title (possibly another catalog year of the same block).
  {
    const loose = new Map<string, string>(); // degree label -> program
    for (const it of items) {
      for (let i = 0; i < it.slots.length; i++) {
        for (let j = i + 1; j < it.slots.length; j++) {
          const a = chosenSlots[it.slots[i]].slot, b = chosenSlots[it.slots[j]].slot;
          if (a.degreeId !== b.degreeId) continue;
          const pa = a.pack, pb = b.pack;
          if (!pa || !pb || (pa.exact && pb.exact)) continue;
          if (!loose.has(a.degreeLabel)) loose.set(a.degreeLabel, (pa.exact ? pb : pa).program);
        }
      }
    }
    if (loose.size > 0) {
      const labels = [...loose.keys()].join(" and ");
      const programs = [...new Set(loose.values())].join("/");
      notes.push(
        `double counting inside ${labels} follows Penn's current template for ${programs}; your catalog year's rules may differ, so confirm with your advisor`,
      );
    }
  }
  if (capstoneBySeniorDesign) {
    notes.push("Wharton counts your engineering senior design project as its senior capstone; if your audit still shows the capstone open, ask your Wharton advisor to record it");
  }
  if (cons.hasCapstoneRule) {
    notes.push("fundamentals and leadership courses are placed before the Wharton capstone (rule for capstones from fall 2027)");
  }
  for (const t of schedule) {
    if (t.registeredCredits === undefined) continue;
    notes.push(`${termLabel(t.term)} already has ${fmt(t.registeredCredits)} cu registered; the plan adds ${fmt(Math.round(t.credits * 100) / 100)} cu there`);
  }
  const noData = items.filter((i) => noOfferingData(i.course)).length;
  if (noData) notes.push(`${noData} course${noData === 1 ? " had" : "s had"} no offering data; their terms are a guess`);
  if (chosenRun.run.unplaced.length) {
    const names = chosenRun.run.unplaced.map((c) => courses[c].code).join(", ");
    notes.push(`${names} could not be placed in the next ${HORIZON} terms`);
  }
  if (req.targetTerm !== undefined) {
    if (chosen.meetsTarget) {
      if (chosen.id === "best") {
        notes.push(`this fits by ${termLabel(req.targetTerm)} only in the best case, whose assumptions follow`);
      } else if (chosen.id === "approved") {
        notes.push(loadIsApproved(chosen.maxLoad)
          ? `this fits by ${termLabel(req.targetTerm)} only with ${fmt(chosen.maxLoad)} cu semesters`
          : `this fits by ${termLabel(req.targetTerm)} only with ${fmt(chosen.maxLoad)} cu semesters, which need approval`);
      }
      else if ((chosen.id === "summer" || chosen.id === "fullSummer") && chosen.summer) notes.push(`this fits by ${termLabel(req.targetTerm)} only with summer courses`);
    } else if (chosen.finishTerm) {
      notes.push(`this does not fit by ${termLabel(req.targetTerm)}; the earliest finish is ${termLabel(chosen.finishTerm)} at ${fmt(chosen.maxLoad)} cu a semester${chosen.summer ? " with summer courses" : ""}`);
    } else {
      notes.push(`this does not fit by ${termLabel(req.targetTerm)} or within ${HORIZON} terms`);
    }
  }
  if (req.maxLoad !== undefined && chosen.id !== "student") {
    const stu = byId("student")!.scenario;
    notes.push(stu.finishTerm
      ? `at ${fmt(req.maxLoad)} cu a semester the plan finishes in ${termLabel(stu.finishTerm)}`
      : `at ${fmt(req.maxLoad)} cu a semester the plan does not fit in ${HORIZON} terms`);
  }
  if (chosen.id === "best") notes.push(`best case assumes ${bestAssumptions().join("; ")}`);
  const used = schedule.some((t) => t.courses.length > 0 && seasonOf(t.term) === "summer");
  if (used) notes.push("summer terms are used");

  // Loads above the standard one are never automatic, whichever scenario was
  // chosen (a student's own "I can do 7" included), so the plan says who has
  // to say yes. Course approvals stay as they are.
  if (approvedFigure !== null) notes.push(loadYes !== null ? `your advisor approved ${fmt(approvedFigure)} cu a semester` : `you said you are approved for ${fmt(approvedFigure)} cu a semester`);
  if (chosen.maxLoad > policy.loads.standard + EPS && !loadIsApproved(chosen.maxLoad)) {
    notes.push(chosen.maxLoad > policy.loads.approved + EPS
      ? `${fmt(chosen.maxLoad)} cu a semester is above Penn's ${fmt(policy.loads.approved)} cu limit for dual-degree students and needs special permission`
      : policy.loads.approvalNote(req.degrees.map((d) => d.college), chosen.maxLoad));
  }

  // The 46 cu floor (Engineering's Dual Degrees page, 2026-11-26). Known
  // limit: no filler courses are added to the schedule, so when the floor
  // binds the finish term can be optimistic; the plan only says how many
  // more cu of any courses are owed.
  const floor = policy.totalFloor(req.degrees);
  const sofar = req.degrees.map((d) => d.creditsSoFar).filter((v): v is number => v !== undefined);
  if (floor && sofar.length) {
    const have = Math.max(...sofar);
    const short = Math.round((floor.cu - (have + chosenCredits)) * 100) / 100;
    if (short > EPS) {
      unfilled.push({
        slotId: "policy|totalFloor",
        degreeLabel: "both degrees",
        label: `${floor.cu} cu minimum`,
        reason: `${fmt(short)} more cu of any courses are needed: ${floor.reason}`,
      });
      notes.push(`the plan ends at ${fmt(Math.round((have + chosenCredits) * 100) / 100)} cu; ${floor.reason}, so ${fmt(short)} more cu of any courses are needed`);
    }
  }

  // Penn Labs' prerequisites field is empty for most language courses, so the
  // prerequisite pass cannot tell that SPAN 0200 is not a first course. A
  // course from level 200 up, chosen for the language requirement by a
  // student with nothing in that subject behind them, depends on placement.
  const takenSubjects = new Set([...taken].map((k) => parseAlias(k).subject));
  const langNoted = new Set<string>();
  for (const it of items) {
    if (!termOf.has(it.ci)) continue;
    if (!it.slots.some((si) => chosenSlots[si].slot.group === "wharton.language")) continue;
    const c = it.course;
    if (!Number.isFinite(c.num) || c.num % 1000 < 200 || takenSubjects.has(c.subject)) continue;
    if (langNoted.has(c.code)) continue;
    langNoted.add(c.code);
    notes.push(`${c.code} assumes you place into it with Penn's language placement exam; otherwise start with ${c.subject} 0100 (or the first course in the sequence)`);
  }
  if (!schedule.some((t) => t.courses.length > 0) && chosenCredits <= EPS && unfilled.length === 0) {
    notes.push("nothing is left to plan");
  }

  // What a scenario still depends on someone else granting, or on an
  // assumption, built from the same facts the notes use. Empty when it depends
  // on nothing. A 4 cu summer is Penn's own limit, not an approval, so it is
  // not listed here.
  const colleges = req.degrees.map((d) => d.college);
  const approvalsFor = (sc: Scenario, run: Run, Aa: { items: Item[]; ctx: Ctx }): string[] => {
    const out: string[] = [];
    const add = (text: string) => {
      const t = text.length > 80 ? `${text.slice(0, 79).trimEnd()}…` : text;
      if (!out.includes(t) && out.length < 8) out.push(t);
    };
    if (sc.maxLoad > policy.loads.standard + EPS && !loadIsApproved(sc.maxLoad)) {
      const who = sc.maxLoad > policy.loads.approved + EPS
        ? "special permission"
        : whoDecidesShort(colleges);
      add(`${fmt(sc.maxLoad)} cu semesters need ${who}`);
    }
    for (const it of Aa.items) {
      if (!run.placed.has(it.ci)) continue;
      for (const [i, j] of petitionPairsOf(it, Aa.ctx.slots)) {
        add(`${it.course.code} counted for both ${Aa.ctx.slots[i].slot.label.trim()} and ${Aa.ctx.slots[j].slot.label.trim()}`);
      }
    }
    if (sc.id === "best" && placesOut) add("placing out of the language requirement by Penn's placement exam");
    return out;
  };
  const approvals = approvalsFor(chosen, chosenRun.run, A);
  const bestRun = byId("best")!;
  const bestApprovals = approvalsFor(bestRun.scenario, bestRun.run, bestA);
  let bestCase: PlanResult["bestCase"];
  if (chosen.id !== "best" && bestRun.scenario.finishTerm !== null && bestApprovals.length > 0 &&
      (chosen.finishTerm === null || bestRun.scenario.finishTerm < chosen.finishTerm)) {
    bestCase = { finishTerm: bestRun.scenario.finishTerm, approvals: bestApprovals };
  }
  if (bestCase && req.targetTerm !== undefined && bestRun.scenario.meetsTarget && !chosen.meetsTarget) {
    notes.push(`${termLabel(req.targetTerm)} is reachable only if: ${bestApprovals.join("; ")}; the schedule shown does not assume them. Say "assume the approvals" to see that plan.`);
  }

  // ---- questions for the advisor ----------------------------------------
  // One for everything the best case leans on that nobody has granted, plus
  // every one already answered that still applies, so the phone can show the
  // answer and let it change. Ids are built from degree, course and slot ids
  // only: the same audits give the same ids, with no index or randomness.
  const clip = (t: string, n: number) => (t.length > n ? `${t.slice(0, n - 1).trimEnd()}…` : t);
  const advisorQuestions: AdvisorQuestion[] = [];
  const ask = (q: Omit<AdvisorQuestion, "answer">) => advisorQuestions.push({ ...q, id: q.id.slice(0, 200), answer: answers.get(q.id) ?? null });
  for (const c of candidates) {
    ask({
      id: c.id,
      kind: "doubleCount",
      question: `Can ${c.code} count toward both ${clip(c.a.label.trim(), 60)} and ${clip(c.b.label.trim(), 60)} in my ${clip(c.a.degreeLabel, 40)} degree?`,
      detail: clip(c.saves > EPS ? `saves ${fmt(c.saves)} cu` : "lets one course fill both", 140),
    });
  }
  for (const d of placementDegrees) {
    const need = langAll.filter((s) => s.degreeId === d).reduce((n, s) => n + s.need, 0);
    ask({
      id: `placement:language:${d}`,
      kind: "placement",
      question: "Can I meet the foreign language requirement by Penn's placement exam, and how do I arrange it?",
      detail: clip(`saves ${fmt(need)} ${langAll.some((s) => s.degreeId === d && s.unit === "courses") ? "course" + (need === 1 ? "" : "s") : "cu"}`, 140),
    });
  }
  {
    const loadId = `load:${fmt(policy.loads.approved)}`;
    const freeFinish = runs
      .filter((r) => ["standard", "summer", "fullSummer"].includes(r.scenario.id) && r.scenario.finishTerm !== null)
      .map((r) => r.scenario.finishTerm!).sort()[0] ?? null;
    const appr = byId("approved")?.scenario.finishTerm ?? null;
    const helps = !loadIsApproved(policy.loads.approved) && !loadNo && appr !== null && (freeFinish === null || appr < freeFinish);
    if (helps || answers.has(loadId)) {
      ask({
        id: loadId,
        kind: "load",
        question: `Can I get approval to take ${fmt(policy.loads.approved)} cu a semester, which ${whoDecidesLong(colleges)}?`,
        detail: clip(`lets you take ${fmt(policy.loads.approved)} cu a semester`, 140),
      });
    }
  }
  advisorQuestions.length = Math.min(advisorQuestions.length, 12);
  for (const n of grantedNotes) notes.push(n);
  if (placementConfirmed.length) notes.push("your advisor confirmed you place out of the foreign language requirement");

  // Summer terms are placed from the most recent summer listing Penn Labs
  // published, which is a past summer; say so, because a course can run in
  // summer 2026 and not in summer 2027.
  {
    const plannedSummer = schedule.find((t) => t.courses.length > 0 && seasonOf(t.term) === "summer");
    const listed = catalog.semesters.filter((x) => /B$/.test(x)).sort().pop();
    if (plannedSummer && listed) {
      notes.push(`summer courses are placed from Penn's summer ${listed.slice(0, 4)} listing; check summer ${plannedSummer.term.slice(0, 4)}'s when it is published`);
    }
  }

  return {
    remainingCredits: chosenCredits,
    remainingCreditsWithoutOverlap,
    scenarios: runs.map((r) => r.scenario),
    chosen: chosen.id,
    schedule,
    unfilled,
    petitions,
    approvals,
    ...(bestCase ? { bestCase } : {}),
    advisorQuestions,
    notes,
  };
}
