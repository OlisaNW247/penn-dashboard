// Penn's Degree Works "audit template" XML, read into plain JSON.
//
// Path@Penn publishes, without a sign-in, one audit of a dummy student for
// every undergraduate program (`programs-v2-info`). The audit is the program's
// whole rulebook: every requirement block it uses, each rule with the courses
// it accepts, and, which no catalogue page gives, the sharing policy
// (`ShareWith`, i.e. which requirement may double count with which), the caps
// (`MaxClasses`, `MaxCredits`), and the overlays (`MinClasses` "area lists").
// This module is the parser only. It reads one template and returns a
// deterministic structure a planner can load later; it does no I/O, so the
// same code can run in a build script, a test and an Edge Function.
//
// Two decisions that look arbitrary and are not.
//
// 1. Nothing is dropped silently, and nothing throws. Penn adds qualifier
//    names without telling anyone (23 seen across 388 templates today), and a
//    course list is free text typed by an administrator. A parser that threw
//    on the first surprise would take the whole pack down for one odd line,
//    and one that skipped it would give a planner a rulebook with a hole it
//    cannot see. So an unknown qualifier lands in `other` with its text, and a
//    course list that does not read keeps its `text` and is flagged
//    `unparsed`; the build script counts both, so a new Penn construct shows
//    up in a report instead of in a student's plan. The only throw is for XML
//    that is not a template at all (no `<Audit>`): Penn answers an unknown or
//    unpublished program with an `<errors>` document and a 200.
//
// 2. A `<Course>` is read only from a rule's `<Requirement>` (and its
//    `<Except>`), never from `<Advice>` or `<CrossListing>`. The audit repeats
//    every course in Advice with a title and credits for display; reading
//    both would double every list. The rule says what counts; the advice says
//    how to print it.
//
// The `With` clauses on a course are kept verbatim as conditions, except the
// two the planner needs as first-class facts: course attributes (`ATTRIBUTE`,
// `DWATTR`, "any of these") and a term limit that confines the option to
// terms before 2023 (`historic`). Penn's "WUCN or WUCU" style attribute lists
// are one With with several values; two ATTRIBUTE Withs joined by AND mean the
// course must carry both, which "any of these" would get wrong, so in that case
// every attribute stays a condition and `attributes` is left unset.

import { type XmlNode, findAll, parseXml } from "./xml.ts";

export interface PackCondition { code: string; op: string; values: string[]; connector?: string }
export interface PackCourse {
  subject: string; // "CIS"; "@" means any subject
  number: string; // "1200"; may hold the wildcard: "2@", "@"
  numberEnd?: string; // inclusive end of a range
  attributes?: string[]; // With ATTRIBUTE / DWATTR: any of these
  conditions?: PackCondition[]; // every other With clause, kept verbatim
  historic?: boolean; // a DWTERM condition limits it to terms before 2023
}
export interface PackShare {
  scope: "thisBlock" | "type" | "block";
  type?: string; // MAJOR | MINOR | CONC | OTHER | DEGREE, for "type" and "block"
  code?: string; // for "block": the block's Req_value, e.g. "U-MT", "AFRC"
  maxCredits?: number;
  maxClasses?: number; // "ShareWith 2 Credits (...)"
}
export interface PackLimit {
  kind: "MAXCLASS" | "MAXCREDIT" | "SPMAXCREDIT" | "MAXPASSFAIL" | "MAXTRANSFER";
  max: number;
  unit: "cu" | "courses";
  courses: PackCourse[];
  except: PackCourse[];
  tag?: string;
  text: string;
  unparsed?: boolean;
}
export interface PackOverlay {
  kind: "MINCLASS" | "MINCREDIT";
  label?: string;
  labelTag?: string;
  need: number;
  unit: "cu" | "courses";
  courses: PackCourse[];
  except: PackCourse[];
  text: string;
  unparsed?: boolean;
}
export interface PackRule {
  id: string;
  label: string;
  labelTag?: string;
  type: "course" | "subset" | "group" | "block" | "blocktype" | "complete" | "incomplete" | "noncourse";
  branch?: "if" | "else";
  need?: { classes?: number; credits?: number; creditsEnd?: number; op?: "AND" | "OR" };
  decide?: string;
  pick?: { groups: number; of: number }; // Group: NumGroups of NumRules
  courses?: PackCourse[];
  except?: PackCourse[];
  share?: PackShare[];
  exclusive?: boolean;
  limits?: PackLimit[];
  overlays?: PackOverlay[];
  priority?: "high" | "low" | "lowest";
  hidden?: boolean;
  minGrade?: string;
  ref?: { type: string; code?: string; blockId?: string }; // Block / Blocktype rules
  other?: { name: string; text: string }[]; // rule-level qualifiers not modelled
  children?: PackRule[];
}
export interface PackBlock {
  reqId: string;
  type: string;
  code: string;
  title: string;
  catalogYears: { start: string; stop: string };
  minCredits?: number;
  minClasses?: number;
  minResidency?: number;
  lastResidency?: { credits?: number; classes?: number; of?: number };
  minGpa?: number;
  minGrade?: string;
  share: PackShare[];
  exclusive?: boolean;
  standalone: boolean;
  limits: PackLimit[];
  overlays: PackOverlay[];
  other: { name: string; text: string }[]; // header qualifiers not modelled
  rules: PackRule[];
}
export interface ParsedTemplate {
  goals: { college?: string; program?: string; major?: string; conc?: string; minor?: string; degree?: string };
  goalNames: Record<string, string>; // Code -> ValueLit
  blocks: PackBlock[];
}

/** Qualifier names the parser turns into fields, per place they appear. The
 * build script reports every other name it meets, per place, as `other`. */
export const MODELLED_HEADER_QUALIFIERS: readonly string[] = [
  "CLASSESCREDITS", "MINRES", "LASTRES", "MINGPA", "MINGRADE", "NONEXCLUSIVE", "EXCLUSIVE",
  "STANDALONEBLOCK", "MAXCLASS", "MAXCREDIT", "SPMAXCREDIT", "MAXPASSFAIL", "MAXTRANSFER",
  "MINCLASS", "MINCREDIT",
];
export const MODELLED_RULE_QUALIFIERS: readonly string[] = [
  "NONEXCLUSIVE", "EXCLUSIVE", "MAXCLASS", "MAXCREDIT", "SPMAXCREDIT", "MAXPASSFAIL", "MAXTRANSFER",
  "MINCLASS", "MINCREDIT", "HIGHPRIORITY", "LOWPRIORITY", "LOWESTPRIORITY", "HIDERULE", "MINGRADE",
];

// ---------------------------------------------------------------- helpers

const kids = (n: XmlNode, tag: string) => n.children.filter((c) => c.tag === tag);
const kid = (n: XmlNode, tag: string) => n.children.find((c) => c.tag === tag);
const norm = (s: string) => s.replace(/\s+/g, " ").trim();

function num(s: string | undefined): number | undefined {
  if (s === undefined) return undefined;
  const t = s.trim();
  if (!/^-?\d+(\.\d+)?$/.test(t)) return undefined;
  return Number(t);
}

/** `<Text>` pieces, then `<SubText>` pieces, joined with single spaces. A long
 * expression is split across SubTexts at arbitrary points ("... = Y AND" then
 * "DWTERM <> ..."), so joining without a space would glue words together. */
function qualText(q: XmlNode): string {
  const t = kids(q, "Text").map((x) => x.text).join(" ");
  const s = kids(q, "SubText").map((x) => x.text).join(" ");
  return normParens(norm(`${t} ${s}`));
}
function subText(q: XmlNode): string {
  return normParens(norm(kids(q, "SubText").map((x) => x.text).join(" ")));
}
/** Penn pads parentheses and commas ("(With  DWTERM > 1 ) ,  5000"). */
function normParens(s: string): string {
  return s.replace(/\(\s+/g, "(").replace(/\s+\)/g, ")").replace(/\s+,/g, ",").replace(/\s+/g, " ").trim();
}

// ------------------------------------------------------------ term / With

/** 202220 -> 202220; "Summer 2022" -> 202220; anything else undefined. YYYY10
 * is spring, YYYY20 summer, YYYY30 fall (Penn's Banner codes). */
function termKey(v: string): number | undefined {
  const t = v.trim();
  let m = /^(\d{4})(\d{2})$/.exec(t);
  if (m) return Number(m[1]) * 100 + Number(m[2]);
  m = /^(spring|summer|fall|winter)\s+(\d{4})$/i.exec(t);
  if (m) {
    const s = { spring: 10, summer: 20, fall: 30, winter: 10 }[m[1].toLowerCase() as "spring"];
    return Number(m[2]) * 100 + s;
  }
  return undefined;
}

const FIRST_TERM_OF_2023 = 202310;

function isHistoric(conds: PackCondition[]): boolean {
  for (const c of conds) {
    if (c.code !== "DWTERM" && c.code !== "DWTERMM") continue;
    if (c.op !== "<" && c.op !== "<=") continue;
    const keys = c.values.map(termKey).filter((k): k is number => k !== undefined);
    if (!keys.length) continue;
    const top = Math.max(...keys);
    // "< 202310" is every term before 2023; "<= 202230" too; "<= 202310" is not.
    if (c.op === "<" ? top <= FIRST_TERM_OF_2023 : top < FIRST_TERM_OF_2023) return true;
  }
  return false;
}

function conditionsToCourse(subject: string, number: string, numberEnd: string | undefined, conds: PackCondition[]): PackCourse {
  const c: PackCourse = { subject, number };
  if (numberEnd !== undefined) c.numberEnd = numberEnd;
  const attrWiths = conds.filter((x) => (x.code === "ATTRIBUTE" || x.code === "DWATTR") && x.op === "=");
  let rest = conds;
  if (attrWiths.length === 1) {
    c.attributes = [...attrWiths[0].values];
    rest = conds.filter((x) => x !== attrWiths[0]);
  }
  if (rest.length) c.conditions = rest;
  if (isHistoric(conds)) c.historic = true;
  return c;
}

const OPS = "<>|<=|>=|=|<|>";
const CONDITION = new RegExp(`^([A-Za-z]+)\\s*(${OPS})\\s*(.+)$`);

/** "DWPASSFAIL = Y AND DWTERM <> 202010, 202020" -> two conditions, the first
 * carrying connector AND (the connector joins a clause to the NEXT one). */
export function parseWithText(s: string): PackCondition[] | null {
  const parts = norm(s).split(/\s+(AND|OR)\s+/i);
  const out: PackCondition[] = [];
  for (let i = 0; i < parts.length; i += 2) {
    const m = CONDITION.exec(parts[i]);
    if (!m) return null;
    const cond: PackCondition = {
      code: m[1].toUpperCase(),
      op: m[2],
      values: m[3].split(",").map((v) => v.trim()).filter((v) => v !== ""),
    };
    if (i + 1 < parts.length) cond.connector = parts[i + 1].toUpperCase();
    out.push(cond);
  }
  return out.length ? out : null;
}

function conditionsFromXml(course: XmlNode): PackCondition[] {
  const withs = kids(course, "With");
  return withs.map((w, i) => {
    const cond: PackCondition = {
      code: w.attrs.Code ?? "",
      op: w.attrs.Operator || "=",
      values: kids(w, "Value").map((v) => norm(v.text)),
    };
    // Penn writes "AND" on the last With too; a connector with nothing to join
    // is noise, so only the ones that have a successor are kept.
    const c = (w.attrs.Connector ?? "").trim();
    if (c && i < withs.length - 1) cond.connector = c.toUpperCase();
    return cond;
  });
}

function courseFromXml(c: XmlNode): PackCourse {
  return conditionsToCourse(c.attrs.Disc ?? "", c.attrs.Num ?? "", c.attrs.Num_end || undefined, conditionsFromXml(c));
}

// -------------------------------------------------- header course lists

function splitTop(s: string, sep: RegExp | ",", ): string[] {
  const parts: string[] = [];
  let depth = 0;
  let cur = "";
  const tokens = sep === "," ? null : sep;
  for (let i = 0; i < s.length; i++) {
    const ch = s[i];
    if (ch === "(") depth++;
    else if (ch === ")") depth = Math.max(0, depth - 1);
    if (depth === 0) {
      if (sep === ",") {
        if (ch === ",") {
          parts.push(cur);
          cur = "";
          continue;
        }
      } else if (tokens) {
        tokens.lastIndex = i;
        const m = tokens.exec(s);
        if (m && m.index === i) {
          parts.push(cur);
          cur = "";
          i += m[0].length - 1;
          continue;
        }
      }
    }
    cur += ch;
  }
  parts.push(cur);
  return parts;
}

const SUBJECT = /^[A-Z@][A-Z0-9@]*$/;
const NUMBER = /^[0-9A-Z@]+(?::[0-9A-Z@]+)?$/;

/** The shorthand list in a MaxClasses / MinCredits... qualifier:
 * "NETS 1500, 2120, CIS 4510" (a bare number repeats the subject), "@ @",
 * "MED 0000:9999" (inclusive range), "CIT @", "(With ...)" per item, and an
 * `Except` tail. `ok` is false when any item does not read; the items that did
 * are still returned. */
export function parseCourseList(text: string): { courses: PackCourse[]; except: PackCourse[]; ok: boolean } {
  const t = normParens(norm(text));
  let ok = true;
  const [inc, ...exc] = splitTop(t, /\bExcept\b/iy);
  if (exc.length > 1) ok = false;
  const parse = (part: string): PackCourse[] => {
    const out: PackCourse[] = [];
    let subject: string | undefined;
    for (const raw of splitTop(part, ",")) {
      const item = raw.trim();
      if (!item) continue;
      let body = item;
      let conds: PackCondition[] = [];
      const wm = /^(.*?)\s*\(\s*with\s+(.*)\)$/i.exec(item);
      if (wm) {
        body = wm[1].trim();
        const parsed = parseWithText(wm[2]);
        if (!parsed) {
          ok = false;
          continue;
        }
        conds = parsed;
      } else if (item.includes("(")) {
        ok = false;
        continue;
      }
      const toks = body.split(" ").filter(Boolean);
      let num: string;
      if (toks.length === 2 && SUBJECT.test(toks[0]) && NUMBER.test(toks[1])) {
        subject = toks[0];
        num = toks[1];
      } else if (toks.length === 1 && subject !== undefined && NUMBER.test(toks[0]) && /[\d@]/.test(toks[0])) {
        num = toks[0];
      } else {
        ok = false;
        continue;
      }
      const [lo, hi] = num.split(":");
      out.push(conditionsToCourse(subject!, lo, hi, conds));
    }
    return out;
  };
  return { courses: parse(inc ?? ""), except: exc.length ? parse(exc[0]) : [], ok };
}

// ------------------------------------------------------------ share

const SHARE_TYPES = new Set(["MAJOR", "MINOR", "CONC", "OTHER", "DEGREE"]);

/** "ShareWith 2 Credits (OTHER = U-MT)", "ShareWith (MAJOR = AFRC, MAJOR = ANCH)",
 * "ShareWith (MINOR, CONC)", "ShareWith (THISBLOCK)". null when it does not read. */
export function parseShare(text: string): PackShare[] | null {
  const m = /^ShareWith\s*(?:(\d+(?:\.\d+)?)\s*(Credits?|Classes?)\s*)?\((.*)\)$/i.exec(norm(text));
  if (!m) return null;
  const cap = m[1] === undefined ? undefined : Number(m[1]);
  const credits = m[2] !== undefined && /^credit/i.test(m[2]);
  const out: PackShare[] = [];
  let prevType: string | undefined;
  for (const clause of m[3].split(",")) {
    const c = clause.trim();
    if (!c) continue;
    const eq = c.indexOf("=");
    let s: PackShare;
    if (eq >= 0) {
      const type = c.slice(0, eq).trim().toUpperCase();
      const code = c.slice(eq + 1).trim();
      if (!SHARE_TYPES.has(type) || !code) return null;
      s = { scope: "block", type, code };
      prevType = type;
    } else if (c.toUpperCase() === "THISBLOCK") {
      s = { scope: "thisBlock" };
    } else if (SHARE_TYPES.has(c.toUpperCase())) {
      s = { scope: "type", type: c.toUpperCase() };
      prevType = undefined;
    } else if (prevType) {
      s = { scope: "block", type: prevType, code: c }; // "MAJOR = AFRC, ANCH"
    } else return null;
    if (cap !== undefined) {
      if (credits) s.maxCredits = cap;
      else s.maxClasses = cap;
    }
    out.push(s);
  }
  return out.length ? out : null;
}

function addShares(into: PackShare[], more: PackShare[]) {
  const seen = new Set(into.map((s) => JSON.stringify(s)));
  for (const s of more) {
    const k = JSON.stringify(s);
    if (!seen.has(k)) {
      seen.add(k);
      into.push(s);
    }
  }
}

// ------------------------------------------------------ limits / overlays

type Other = { name: string; text: string }[];

function qualNumber(q: XmlNode, ...names: string[]): number | undefined {
  for (const n of names) {
    const v = num(q.attrs[n]);
    if (v !== undefined) return v;
  }
  return undefined;
}

/** Penn's number can also be in the text ("MAXPASSFAIL 0 CLASSES"). */
function textNumber(text: string): { n: number; unit?: "cu" | "courses" } | undefined {
  const m = /(\d+(?:\.\d+)?)\s*(credits?|classes)?/i.exec(text.replace(/^[A-Za-z]+/, ""));
  if (!m) return undefined;
  const u = m[2]?.toLowerCase();
  return { n: Number(m[1]), unit: u === undefined ? undefined : u.startsWith("credit") ? "cu" : "courses" };
}

function buildLimit(q: XmlNode, kind: PackLimit["kind"], other: Other): PackLimit | null {
  const text = qualText(q);
  let max = qualNumber(q, kind === "MAXCLASS" ? "Classes" : "Credits", "Classes", "Credits");
  let unit: PackLimit["unit"];
  if (kind === "MAXCLASS") unit = "courses";
  else if (kind === "MAXCREDIT" || kind === "SPMAXCREDIT") unit = "cu";
  else unit = q.attrs.Credits !== undefined && q.attrs.Classes === undefined ? "cu" : "courses";
  if (max === undefined) {
    const t = textNumber(text);
    if (!t) {
      other.push({ name: kind, text });
      return null;
    }
    max = t.n;
    if (t.unit && (kind === "MAXPASSFAIL" || kind === "MAXTRANSFER")) unit = t.unit;
  }
  const list = subText(q);
  const parsed = list ? parseCourseList(list) : { courses: [], except: [], ok: true };
  const lim: PackLimit = { kind, max, unit, courses: parsed.courses, except: parsed.except, text };
  if (q.attrs.Tag) lim.tag = q.attrs.Tag;
  if (!parsed.ok) lim.unparsed = true;
  return lim;
}

function buildOverlay(q: XmlNode, kind: PackOverlay["kind"], other: Other): PackOverlay | null {
  const text = qualText(q);
  const need = qualNumber(q, kind === "MINCLASS" ? "Classes" : "Credits", "Needed", "Classes", "Credits") ?? textNumber(text)?.n;
  if (need === undefined) {
    other.push({ name: kind, text });
    return null;
  }
  const list = subText(q);
  const parsed = list ? parseCourseList(list) : { courses: [], except: [], ok: true };
  const o: PackOverlay = {
    kind, need, unit: kind === "MINCLASS" ? "courses" : "cu",
    courses: parsed.courses, except: parsed.except, text,
  };
  if (q.attrs.Label) o.label = q.attrs.Label;
  if (q.attrs.LabelTag) o.labelTag = q.attrs.LabelTag;
  if (!parsed.ok) o.unparsed = true;
  return o;
}

// ------------------------------------------------------------- rules

const RULE_TYPES = new Set(["course", "subset", "group", "block", "blocktype", "complete", "incomplete", "noncourse"]);

function parseRule(n: XmlNode): PackRule {
  const rule: PackRule = {
    id: n.attrs.Rule_id ?? "",
    label: n.attrs.Label ?? "",
    type: (n.attrs.RuleType ?? "").toLowerCase() as PackRule["type"],
  };
  if (!RULE_TYPES.has(rule.type)) rule.type = "noncourse"; // unknown types carry nothing a planner can place
  if (n.attrs.LabelTag) rule.labelTag = n.attrs.LabelTag;
  const ie = kid(n, "IfElsePart")?.text.trim();
  if (ie === "IfPart") rule.branch = "if";
  else if (ie === "ElsePart") rule.branch = "else";

  const req = kid(n, "Requirement");
  if (req) {
    const classes = num(req.attrs.Classes_begin);
    const credits = num(req.attrs.Credits_begin);
    if (classes !== undefined || credits !== undefined) {
      const need: NonNullable<PackRule["need"]> = {};
      if (classes !== undefined) need.classes = classes;
      if (credits !== undefined) need.credits = credits;
      const end = num(req.attrs.Credits_end);
      if (end !== undefined) need.creditsEnd = end;
      const op = (req.attrs.Class_cred_op ?? "").toUpperCase();
      if (op === "AND" || op === "OR") need.op = op;
      rule.need = need;
    }
    if (req.attrs.Decide) rule.decide = req.attrs.Decide;
    const groups = num(req.attrs.NumGroups);
    const of = num(req.attrs.NumRules);
    if (groups !== undefined && of !== undefined) rule.pick = { groups, of };
    const courses = kids(req, "Course").map(courseFromXml);
    if (courses.length) rule.courses = courses;
    const ex = kid(req, "Except");
    const except = ex ? kids(ex, "Course").map(courseFromXml) : [];
    if (except.length) rule.except = except;

    if (rule.type === "block" || rule.type === "blocktype") {
      const type = kid(req, "Type")?.text.trim();
      if (type) {
        const ref: NonNullable<PackRule["ref"]> = { type };
        const code = kid(req, "Value")?.text.trim();
        if (code) ref.code = code;
        const blockId = kid(kid(n, "Advice") ?? n, "BlockID")?.text.trim();
        if (blockId) ref.blockId = blockId;
        rule.ref = ref;
      }
    }

    const share: PackShare[] = [];
    const limits: PackLimit[] = [];
    const overlays: PackOverlay[] = [];
    const other: Other = [];
    for (const q of kids(req, "Qualifier")) {
      const name = q.attrs.Name ?? "";
      const text = qualText(q);
      switch (name) {
        case "NONEXCLUSIVE": {
          const s = parseShare(text);
          if (s) addShares(share, s);
          else other.push({ name, text });
          break;
        }
        case "EXCLUSIVE": rule.exclusive = true; break;
        case "MAXCLASS": case "MAXCREDIT": case "SPMAXCREDIT": case "MAXPASSFAIL": case "MAXTRANSFER": {
          const l = buildLimit(q, name, other);
          if (l) limits.push(l);
          break;
        }
        case "MINCLASS": case "MINCREDIT": {
          const o = buildOverlay(q, name, other);
          if (o) overlays.push(o);
          break;
        }
        case "HIGHPRIORITY": rule.priority = "high"; break;
        case "LOWPRIORITY": rule.priority = "low"; break;
        case "LOWESTPRIORITY": rule.priority = "lowest"; break;
        case "HIDERULE": rule.hidden = true; break;
        case "MINGRADE":
          if (q.attrs.MinGrade && rule.minGrade === undefined) rule.minGrade = q.attrs.MinGrade;
          else other.push({ name, text });
          break;
        default: other.push({ name, text });
      }
    }
    if (share.length) rule.share = share;
    if (limits.length) rule.limits = limits;
    if (overlays.length) rule.overlays = overlays;
    if (other.length) rule.other = other;
  }
  const children = kids(n, "Rule").map(parseRule);
  if (children.length) rule.children = children;
  return rule;
}

// ------------------------------------------------------------- blocks

function parseBlock(b: XmlNode): PackBlock {
  const block: PackBlock = {
    reqId: b.attrs.Req_id ?? "",
    type: b.attrs.Req_type ?? "",
    code: b.attrs.Req_value ?? "",
    title: b.attrs.Title ?? "",
    catalogYears: { start: b.attrs.Cat_yr_start ?? "", stop: b.attrs.Cat_yr_stop ?? "" },
    share: [],
    standalone: false,
    limits: [],
    overlays: [],
    other: [],
    rules: [],
  };
  const header = kid(b, "Header");
  for (const q of header ? kids(header, "Qualifier") : []) {
    const name = q.attrs.Name ?? "";
    const text = qualText(q);
    // A single-valued field set twice keeps the first and files the second
    // under `other`, so a template with two minimums is visible, not merged.
    const once = <K extends keyof PackBlock>(key: K, value: PackBlock[K] | undefined) => {
      if (value === undefined || block[key] !== undefined) block.other.push({ name, text });
      else block[key] = value;
    };
    switch (name) {
      case "CLASSESCREDITS": {
        const credits = num(q.attrs.Credits);
        const classes = num(q.attrs.Classes);
        if (credits === undefined && classes === undefined) block.other.push({ name, text });
        if (credits !== undefined) once("minCredits", credits);
        if (classes !== undefined) once("minClasses", classes);
        break;
      }
      case "MINRES": once("minResidency", num(q.attrs.Credits)); break;
      case "LASTRES": {
        const m = /LASTRES\s+(\d+(?:\.\d+)?)\s+(CLASSES|CREDITS)(?:\s+OF\s+(\d+(?:\.\d+)?))?/i.exec(text);
        if (!m) { block.other.push({ name, text }); break; }
        const lr: NonNullable<PackBlock["lastResidency"]> = {};
        if (/^credits/i.test(m[2])) lr.credits = Number(m[1]);
        else lr.classes = Number(m[1]);
        if (m[3] !== undefined) lr.of = Number(m[3]);
        once("lastResidency", lr);
        break;
      }
      case "MINGPA": once("minGpa", num(q.attrs.MinGPA)); break;
      case "MINGRADE": once("minGrade", q.attrs.MinGrade || undefined); break;
      case "NONEXCLUSIVE": {
        const s = parseShare(text);
        if (s) addShares(block.share, s);
        else block.other.push({ name, text });
        break;
      }
      case "EXCLUSIVE": block.exclusive = true; break;
      case "STANDALONEBLOCK": block.standalone = true; break;
      case "MAXCLASS": case "MAXCREDIT": case "SPMAXCREDIT": case "MAXPASSFAIL": case "MAXTRANSFER": {
        const l = buildLimit(q, name, block.other);
        if (l) block.limits.push(l);
        break;
      }
      case "MINCLASS": case "MINCREDIT": {
        const o = buildOverlay(q, name, block.other);
        if (o) block.overlays.push(o);
        break;
      }
      default: block.other.push({ name, text });
    }
  }
  block.rules = kids(b, "Rule").map(parseRule);
  return block;
}

// ---------------------------------------------------------- template

const GOAL_KEYS: Record<string, keyof ParsedTemplate["goals"]> = {
  COLLEGE: "college", PROGRAM: "program", MAJOR: "major", CONC: "conc", MINOR: "minor",
};

export function parseTemplate(xml: string): ParsedTemplate {
  const root = parseXml(xml);
  const audit = root.tag === "Audit" ? root : findAll(root, "Audit")[0];
  if (!audit) throw new Error(`not an audit template: root element is <${root.tag}>, no <Audit>`);
  const goals: ParsedTemplate["goals"] = {};
  const goalNames: Record<string, string> = {};
  for (const g of findAll(root, "Goal")) {
    const code = g.attrs.Code ?? "";
    const key = GOAL_KEYS[code];
    if (!key || goals[key] !== undefined) continue;
    goals[key] = g.attrs.Value ?? "";
    goalNames[code] = g.attrs.ValueLit ?? "";
  }
  const dd = findAll(root, "DegreeData")[0];
  if (dd?.attrs.Degree) {
    goals.degree = dd.attrs.Degree;
    if (dd.attrs.DegreeLit) goalNames.DEGREE = dd.attrs.DegreeLit;
  }
  return { goals, goalNames, blocks: findAll(audit, "Block").map(parseBlock) };
}
