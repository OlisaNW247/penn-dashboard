// Turns the audits the phone sends (the JSON Swift makes of `DegreeAudit`) into
// the planner's Degree/Slot values: one Slot per requirement still to fill,
// with the courses that can fill it. Pure; no network.
//
// The audit is Penn's own reading, so this module only restates it: which
// rules are still open, how much each needs, and what Penn says may satisfy
// it (advice courses, plus the "Any course(s) with attribute ..." info lines
// the phone keeps as rules with status "info"). Anything Penn describes only
// in words, or that needs a decision the student has not made (an undeclared
// concentration), goes to `unfilled` with a reason, never to a guessed slot.

import type { Degree, Eligibility, Slot, SlotGroup, Unfilled } from "./types.ts";

type Json = Record<string, unknown>;

export interface AuditInput {
  degreeId: string;
  label: string;
  audit: unknown;
}

export interface RequirementsResult {
  degrees: Degree[];
  unfilled: Unfilled[];
  taken: string[];
}

// ---------------------------------------------------------------------------
// Lenient readers (optional numbers may be absent or null)
// ---------------------------------------------------------------------------

function rec(v: unknown): Json | null {
  return v && typeof v === "object" && !Array.isArray(v) ? v as Json : null;
}
function arr(v: unknown): Json[] {
  return Array.isArray(v) ? v.map(rec).filter((x): x is Json => x !== null) : [];
}
function str(v: unknown): string {
  return typeof v === "string" ? v : "";
}
function num(v: unknown): number | undefined {
  return typeof v === "number" && Number.isFinite(v) ? v : undefined;
}

/** "cis  1200" -> "CIS 1200". Codes that do not fit the shape are upper-cased
 *  with spaces collapsed, never dropped. */
export function normalizeCode(raw: string): string {
  const t = raw.trim().replace(/\s+/g, " ").toUpperCase();
  const m = /^([A-Z]{2,5})[\s-]*(\d{3,4})$/.exec(t);
  return m ? `${m[1]} ${m[2]}` : t;
}

interface AppliedCourse {
  code: string;
  credits?: number;
}
interface RuleView {
  id: string;
  label: string;
  status: string;
  needCourses?: number;
  needCredits?: number;
  appliedCount?: number;
  appliedCredits?: number;
  applied: AppliedCourse[];
  advice: string[];
  adviceText: string;
  children: RuleView[];
}

function readRule(r: Json): RuleView {
  return {
    id: str(r.id),
    label: str(r.label),
    status: str(r.status) || "open",
    needCourses: num(r.needCourses),
    needCredits: num(r.needCredits),
    appliedCount: num(r.appliedCount),
    appliedCredits: num(r.appliedCredits),
    applied: arr(r.applied).map((a) => ({ code: normalizeCode(str(a.code)), credits: num(a.credits) }))
      .filter((a) => a.code),
    advice: arr(r.advice).map((a) => normalizeCode(str(a.code))).filter(Boolean),
    adviceText: str(r.adviceText),
    children: arr(r.children).map(readRule),
  };
}

// ---------------------------------------------------------------------------
// Eligibility text
// ---------------------------------------------------------------------------

interface Parsed {
  anyOf: Eligibility[];
  exclude: Eligibility[];
  unknown: string[];
}

function newParsed(): Parsed {
  return { anyOf: [], exclude: [], unknown: [] };
}

function addCourses(list: Eligibility[], codes: string[]) {
  const have = list.find((e) => e.kind === "courses") as Extract<Eligibility, { kind: "courses" }> | undefined;
  if (have) {
    for (const c of codes) if (!have.codes.includes(c)) have.codes.push(c);
  } else if (codes.length) list.push({ kind: "courses", codes: [...new Set(codes)] });
}
function addAttrs(list: Eligibility[], codes: string[]) {
  const have = list.find((e) => e.kind === "attribute") as Extract<Eligibility, { kind: "attribute" }> | undefined;
  if (have) {
    for (const c of codes) if (!have.codes.includes(c)) have.codes.push(c);
  } else if (codes.length) list.push({ kind: "attribute", codes: [...new Set(codes)] });
}
function addSubjects(list: Eligibility[], subjects: string[]) {
  const have = list.find((e) => e.kind === "subject") as Extract<Eligibility, { kind: "subject" }> | undefined;
  if (have) {
    for (const c of subjects) if (!have.subjects.includes(c)) have.subjects.push(c);
  } else if (subjects.length) list.push({ kind: "subject", subjects: [...new Set(subjects)] });
}
function addNumbers(list: Eligibility[], numbers: number[]) {
  const have = list.find((e) => e.kind === "number") as Extract<Eligibility, { kind: "number" }> | undefined;
  if (have) {
    for (const c of numbers) if (!have.numbers.includes(c)) have.numbers.push(c);
  } else if (numbers.length) list.push({ kind: "number", numbers: [...new Set(numbers)] });
}
function addAdviceCode(list: Eligibility[], code: string) {
  if (code.includes("@")) list.push({ kind: "pattern", pattern: code });
  else addCourses(list, [code]);
}

const CODE_RE = /[A-Za-z]{2,5}\s*\d{3,4}/g;
function codesIn(text: string): string[] {
  return (text.match(CODE_RE) ?? []).map(normalizeCode);
}
function attrCodes(text: string): string[] {
  return text.split(/\s*,\s*|\s+or\s+|\s+and\s+/i).map((s) => s.trim().replace(/\.$/, "").toUpperCase())
    .filter((s) => /^[A-Z0-9]{3,6}$/.test(s));
}

/** One piece of an exclusion sentence ("any course(s) with attribute EUNE"). */
function parseExclusionPiece(piece: string, into: Eligibility[]): boolean {
  const p = piece.trim().replace(/\.$/, "");
  let m = /^any course\(s\) with attribute (.+)$/i.exec(p);
  if (m) {
    addAttrs(into, attrCodes(m[1]));
    return true;
  }
  m = /^any (\d{4}) course\(s\)$/i.exec(p);
  if (m) {
    addNumbers(into, [Number(m[1])]);
    return true;
  }
  m = /^any ([A-Z]{2,5}) course\(s\)$/i.exec(p);
  if (m) {
    addSubjects(into, [m[1].toUpperCase()]);
    return true;
  }
  const codes = codesIn(p);
  if (codes.length) {
    addCourses(into, codes);
    return true;
  }
  return false;
}

function parseInfoText(raw: string, p: Parsed) {
  const text = raw.trim().replace(/\s+/g, " ");
  let m = /^Note:\s*This requirement may not be satisfied with (.+)$/i.exec(text);
  if (m) {
    const pieces = m[1].split(/\s+or\s+(?=any\b)/i);
    let ok = true;
    for (const piece of pieces) if (!parseExclusionPiece(piece, p.exclude)) ok = false;
    if (!ok) p.unknown.push(text);
    return;
  }
  m = /^Any course\(s\) with attribute (.+)$/i.exec(text);
  if (m) {
    addAttrs(p.anyOf, attrCodes(m[1]));
    return;
  }
  m = /^Any ([A-Z]{2,5}) (\d{4})-(\d{4}) course\(s\)\.?$/i.exec(text);
  if (m) {
    p.anyOf.push({ kind: "range", subject: m[1].toUpperCase(), from: Number(m[2]), to: Number(m[3]) });
    return;
  }
  m = /^Any ([A-Z]{2,5}) course\(s\)\.?$/i.exec(text);
  if (m) {
    addSubjects(p.anyOf, [m[1].toUpperCase()]);
    return;
  }
  m = /^A course from the following list is required:\s*(.+)$/i.exec(text);
  if (m) {
    const codes = codesIn(m[1]);
    if (codes.length) {
      addCourses(p.anyOf, codes);
      return;
    }
  }
  p.unknown.push(text);
}

// ---------------------------------------------------------------------------
// Groups
// ---------------------------------------------------------------------------

function groupFor(college: string, blockType: string, blockTitle: string, path: string[]): SlotGroup {
  const bt = blockTitle.toLowerCase();
  const has = (re: RegExp) => path.some((p) => re.test(p));
  if (college === "WU") {
    if (blockType === "MAJOR") return "wharton.concentration";
    if (bt.includes("business fundamentals")) {
      if (has(/^leadership journey/i) || has(/^senior capstone/i)) return "wharton.leadership";
      if (has(/^global economy/i) || has(/^technology, innovation/i) || has(/^flex fundamentals/i)) {
        return "wharton.flex";
      }
      return "wharton.fundamental";
    }
    if (bt.includes("liberal arts")) {
      if (has(/^cross-cultural/i)) return "wharton.crossCultural";
      if (has(/^foreign language/i)) return "wharton.language";
      return "wharton.liberal";
    }
    if (bt.includes("business breadth")) return "wharton.breadth";
    return "other";
  }
  if (college === "EU") {
    if (has(/technical electives/i)) return "seas.techElective";
    if (has(/^math and natural science/i)) return "seas.math";
    if (bt.includes("general electives") || has(/ethics/i)) return "seas.general";
    if (blockType === "MAJOR") return "seas.core";
    return "other";
  }
  return "other";
}

// ---------------------------------------------------------------------------
// Walk
// ---------------------------------------------------------------------------

const SKIPPED_BLOCKS = new Set(["DEGREE", "CL_SYNTHETIC_BLOCK", "N/A"]);
const NO_COURSES_REASON = "Penn's audit names no courses for this";
const DECLARE_REASON = "declare a concentration first";

function round(n: number): number {
  return Math.round(n * 1e6) / 1e6;
}

interface Ctx {
  degreeId: string;
  degreeLabel: string;
  college: string;
  blockId: string;
  blockType: string;
  blockTitle: string;
  slots: Slot[];
  unfilled: Unfilled[];
}

function appliedCredits(r: RuleView): number {
  if (r.appliedCredits !== undefined) return r.appliedCredits;
  return r.applied.reduce((s, a) => s + (a.credits ?? 0), 0);
}

function subjectOf(code: string): string {
  return code.split(" ")[0];
}

/** The phone prints a label inside a sentence, so it is never empty: the
 *  rule's own, else the block's title, else a plain word. */
function labelOr(label: string, ctx: Ctx): string {
  return label.trim() || ctx.blockTitle.trim() || "a requirement";
}

function makeSlot(ctx: Ctx, r: RuleView, path: string[], opts: {
  idSuffix?: string;
  label?: string;
  need: number;
  unit: "cu" | "courses";
  parsed: Parsed;
  extraText?: string;
}): void {
  const id = `${ctx.degreeId}|${ctx.blockId}|${r.id}${opts.idSuffix ? `|${opts.idSuffix}` : ""}`;
  const label = labelOr(opts.label ?? r.label, ctx);
  if (opts.parsed.anyOf.length === 0) {
    ctx.unfilled.push({ slotId: id, degreeLabel: ctx.degreeLabel, label, reason: NO_COURSES_REASON });
    return;
  }
  const group = groupFor(ctx.college, ctx.blockType, ctx.blockTitle, path);
  const slot: Slot = {
    id,
    degreeId: ctx.degreeId,
    degreeLabel: ctx.degreeLabel,
    label,
    blockTitle: ctx.blockTitle,
    need: opts.need,
    unit: opts.unit,
    anyOf: opts.parsed.anyOf,
    exclude: opts.parsed.exclude,
    group,
  };
  if (group === "wharton.breadth") {
    slot.constraints = {
      distinctSubjects: true,
      excludeSubjects: [],
      usedSubjects: [...new Set(r.applied.map((a) => subjectOf(a.code)))],
      minNumber: 2000,
    };
  }
  const texts = [...opts.parsed.unknown];
  if (opts.extraText) texts.push(opts.extraText);
  if (texts.length) slot.text = texts.join(" ");
  ctx.slots.push(slot);
}

function leafParsed(r: RuleView, infoChildren: RuleView[]): Parsed {
  const p = newParsed();
  for (const code of r.advice) addAdviceCode(p.anyOf, code);
  for (const c of infoChildren) parseInfoText(c.label, p);
  return p;
}

function walkRule(ctx: Ctx, r: RuleView, ancestors: string[]) {
  if (r.status === "met" || r.status === "info") return;
  const label = r.label.trim();
  if (/ - See /.test(label)) return;
  if (/^Minimum Credits/i.test(label)) return;
  const path = [...ancestors, label];

  const infoChildren = r.children.filter((c) => c.status === "info");
  const realChildren = r.children.filter((c) => c.status !== "info");

  // Needs a decision the student has not made.
  if (
    /^Major Required/i.test(label) || /^Concentration Undeclared/i.test(label) ||
    infoChildren.some((c) => /must declare a concentration/i.test(c.label))
  ) {
    ctx.unfilled.push({
      slotId: `${ctx.degreeId}|${ctx.blockId}|${r.id}`,
      degreeLabel: ctx.degreeLabel,
      label: labelOr(label, ctx),
      reason: DECLARE_REASON,
    });
    return;
  }

  const hasNeed = r.needCredits !== undefined || r.needCourses !== undefined;

  // The rule's own advice plus children: each advice course is required on its
  // own (FUNDAMENTALS -> ACCT 1020, OIDD 1010), unless Penn gives a count.
  if (r.advice.length > 0 && realChildren.length > 0) {
    if (hasNeed) {
      emitLeaf(ctx, r, infoChildren, path);
    } else {
      for (const code of r.advice) {
        const p = newParsed();
        addAdviceCode(p.anyOf, code);
        makeSlot(ctx, r, path, {
          idSuffix: code,
          label: `${label} (${code})`,
          need: 1,
          unit: "courses",
          parsed: p,
        });
      }
    }
    for (const c of realChildren) walkRule(ctx, c, path);
    return;
  }

  if (realChildren.length > 0) {
    for (const c of realChildren) walkRule(ctx, c, path);
    return;
  }

  emitLeaf(ctx, r, infoChildren, path);
}

function emitLeaf(ctx: Ctx, r: RuleView, infoChildren: RuleView[], path: string[]) {
  const label = r.label.trim();
  let need: number;
  let unit: "cu" | "courses";
  if (r.needCredits !== undefined) {
    unit = "cu";
    need = round(r.needCredits - appliedCredits(r));
  } else if (r.needCourses !== undefined) {
    unit = "courses";
    need = r.needCourses - (r.appliedCount ?? r.applied.length);
  } else {
    // Penn gave no number.
    if (r.status === "inProgress") return; // completes with the in-progress course
    const m = /choose\s+(\d+(?:\.\d+)?)\s*(cu|credit|unit)?/i.exec(r.adviceText);
    if (m && m[2]) {
      unit = "cu";
      need = Number(m[1]);
    } else if (m) {
      unit = "courses";
      need = Number(m[1]);
    } else {
      unit = "courses";
      need = 1; // "Area List ...", "Choose 1 ...", or an open rule with options
    }
  }
  if (!(need > 0)) return;
  const parsed = leafParsed(r, infoChildren);
  makeSlot(ctx, r, path, { need, unit, parsed });
}

// ---------------------------------------------------------------------------
// Entry point
// ---------------------------------------------------------------------------

export function degreesFromAudits(audits: AuditInput[]): RequirementsResult {
  const degrees: Degree[] = [];
  const unfilled: Unfilled[] = [];
  const taken: string[] = [];
  const takenSet = new Set<string>();

  for (const input of audits) {
    const audit = rec(input.audit) ?? {};
    const goals = rec(audit.goals) ?? {};
    const college = str(goals.college).toUpperCase();
    const slots: Slot[] = [];
    const applied: string[] = [];
    const appliedSet = new Set<string>();
    const noteApplied = (code: string) => {
      if (!code) return;
      if (!appliedSet.has(code)) {
        appliedSet.add(code);
        applied.push(code);
      }
      if (!takenSet.has(code)) {
        takenSet.add(code);
        taken.push(code);
      }
    };
    let creditsSoFar: number | undefined;
    const findCredits = (r: RuleView): number | undefined => {
      const m = /currently have\s+([\d.]+)\s*CU/i.exec(r.label);
      if (m && Number.isFinite(Number(m[1]))) return Number(m[1]);
      for (const c of r.children) {
        const v = findCredits(c);
        if (v !== undefined) return v;
      }
      return undefined;
    };
    const collect = (r: RuleView) => {
      for (const a of r.applied) noteApplied(a.code);
      for (const c of r.children) collect(c);
    };

    for (const b of arr(audit.blocks)) {
      const rules = arr(b.rules).map(readRule);
      for (const r of rules) collect(r);
      const type = str(b.type);
      // Penn's own count of cu earned plus in progress sits in the DEGREE
      // block's label. A MAJOR block says "You currently have 16." (the
      // major's own count, no "CU"), which must not be taken for it.
      if (type === "DEGREE" && creditsSoFar === undefined) {
        for (const r of rules) {
          creditsSoFar = findCredits(r);
          if (creditsSoFar !== undefined) break;
        }
      }
      if (SKIPPED_BLOCKS.has(type)) continue;
      const ctx: Ctx = {
        degreeId: input.degreeId,
        degreeLabel: input.label,
        college,
        blockId: str(b.id),
        blockType: type,
        blockTitle: str(b.title),
        slots,
        unfilled,
      };
      for (const r of rules) walkRule(ctx, r, []);
    }
    for (const c of arr(audit.courses)) noteApplied(normalizeCode(str(c.code)));

    // Business breadth may not use the concentration's own subjects.
    const concSubjects = new Set<string>();
    for (const s of slots) {
      if (s.group !== "wharton.concentration") continue;
      for (const e of s.anyOf) {
        if (e.kind === "range") concSubjects.add(e.subject);
        else if (e.kind === "subject") e.subjects.forEach((x) => concSubjects.add(x));
        else if (e.kind === "pattern") {
          const sub = e.pattern.trim().split(/\s+/)[0];
          if (/^[A-Z]{2,5}$/.test(sub)) concSubjects.add(sub);
        }
      }
    }
    for (const s of slots) {
      if (s.constraints?.distinctSubjects) s.constraints.excludeSubjects = [...concSubjects].sort();
    }

    degrees.push({ id: input.degreeId, label: input.label, college, slots, applied, ...(creditsSoFar !== undefined ? { creditsSoFar } : {}) });
  }
  return { degrees, unfilled, taken };
}
