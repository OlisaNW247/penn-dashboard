// Joins Penn's published program template (a ProgramPack, see pack.ts) to the
// slots made from a student's audit, so the within-degree sharing decision can
// come from Penn's own data instead of the hand-written rules in policy.ts.
//
// The audit stays the authority for WHAT is still needed and how much; the
// pack only adds what the audit does not say: which requirements may count the
// same course. Pure: no I/O, no clock.
//
// Degree Works semantics assumed here (the audit never spells them out; this
// is how Penn Labs' open-source planner reads the same template data):
//   - Default is exclusive: with no share target, a course applied to one rule
//     may not also count for another rule.
//   - `thisBlock`: the rule (or, for a block-level share, every rule of the
//     block) may share with other rules of the SAME block.
//   - `type` (MINOR, MAJOR, CONC, ...): may share with rules of any OTHER block
//     of that type. `block` (type + code): with that specific other block.
//   - Sharing is symmetric: if A's targets cover B's block, A and B share even
//     when B names nothing.
//   - A rule inherits its block's shares and its ancestor rules' shares.
//   - An overlay (a header MINCLASS/MINCREDIT with a label, e.g. "Area List -
//     Networking") is not a rule competing for a course: it counts courses
//     already applied anywhere in its own block, so it shares with every other
//     slot of that block.
//   - `maxCredits` on a share caps how much may be double counted through it.
//     `maxClasses` is read as the same number of cu (a class is 1 cu in nearly
//     every case; the planner counts credits, not classes, so the
//     conservative reading is the right one until it counts classes). It
//     appears 27 times across the 388 published templates, always on a
//     BLOCK-level share.
//   - EXCLUSIVE (on a rule, an ancestor rule, or the block) means the course
//     counted there counts nowhere else: a slot carrying it shares with no
//     other slot, from either side. One exception, an ASSUMPTION: an overlay
//     still counts a course applied to an exclusive rule, because an overlay
//     is a count over the block, not a second use of the course.
//   - Two overlay slots do NOT share with each other. Degree Works would let
//     one course satisfy two area lists, but no Penn page read so far says
//     the department intends it, and refusing it only asks for one more
//     course. The wrong fix is allowing it because the engine would.
//   - A program found only by school and degree (`exactMajor: false`) is
//     joined for its school-wide blocks (type OTHER) alone: its MAJOR, MINOR
//     and CONC blocks belong to some other program and keep the hand policy.

import type { PackBlock, PackRule, PackShare, ProgramIndexEntry, ProgramPack } from "./pack.ts";
import type { Degree, Slot, SlotPack, SlotShare } from "./types.ts";

const nrm = (s: unknown): string =>
  (typeof s === "string" ? s : "").toLowerCase().replace(/[^a-z0-9]+/g, " ").replace(/\s+/g, " ").trim();

// ---------------------------------------------------------------------------
// Which program is this student's?
// ---------------------------------------------------------------------------

export function findProgram(
  index: ProgramIndexEntry[],
  goals: Degree["goals"],
): { code: string; exactMajor: boolean } | null {
  if (!goals) return null;
  const college = goals.college.toUpperCase();
  const degree = goals.degree.toUpperCase();
  if (!college || !degree) return null;
  const same = index
    .filter((e) =>
      (e.goals?.college ?? "").toUpperCase() === college && (e.goals?.degree ?? "").toUpperCase() === degree
    )
    .sort((x, y) => (x.code < y.code ? -1 : x.code > y.code ? 1 : 0));
  if (same.length === 0) return null;
  const major = (goals.majors[0] ?? "").toUpperCase();
  const withMajor = major ? same.filter((e) => (e.goals?.major ?? "").toUpperCase() === major) : [];
  if (withMajor.length === 0) return { code: same[0].code, exactMajor: false };
  const conc = (goals.concentrations[0] ?? "").toUpperCase();
  const concOf = (e: ProgramIndexEntry) => (e.goals?.conc ?? "").toUpperCase();
  let pick: ProgramIndexEntry | undefined;
  if (conc) pick = withMajor.find((e) => concOf(e) === conc);
  // A concentration no program of the major carries: the block content of a
  // sibling program differs by concentration under one reqId, so the major's
  // own blocks cannot be trusted.
  const concMissing = !!conc && !pick;
  pick ??= withMajor.find((e) => ["", "NCON", "GEN"].includes(concOf(e)));
  pick ??= withMajor[0];
  return { code: pick.code, exactMajor: !concMissing };
}

// ---------------------------------------------------------------------------
// Attaching a pack to a degree's slots
// ---------------------------------------------------------------------------

const SUFFIX_RE = /\s*\(\s*[A-Za-z]{2,5}\s*\d{3,4}\s*\)\s*$/;

function dedupShares(list: SlotShare[]): SlotShare[] {
  const seen = new Set<string>();
  const out: SlotShare[] = [];
  for (const s of list) {
    const k = JSON.stringify([s.scope, s.type ?? "", s.code ?? "", s.maxCredits ?? "", s.maxClasses ?? ""]);
    if (!seen.has(k)) {
      seen.add(k);
      out.push(s);
    }
  }
  return out;
}

interface Found { rule: PackRule; shares: SlotShare[]; exclusive: boolean }

function findRule(rules: PackRule[], label: string, inherited: SlotShare[], exclusive: boolean): Found | null {
  for (const r of rules) {
    const own = [...inherited, ...(r.share ?? []).map((x): SlotShare => ({ ...x, from: "rule" }))];
    const excl = exclusive || r.exclusive === true;
    if (nrm(r.label) === label) return { rule: r, shares: own, exclusive: excl };
    if (r.children?.length) {
      const f = findRule(r.children, label, own, excl);
      if (f) return f;
    }
  }
  return null;
}

export interface AttachReport {
  matchedSlots: number;
  totalSlots: number;
  exactBlocks: number;
  titleBlocks: number;
  /** Slots whose rule or overlay label matched (the rest matched a block only). */
  ruleMatched: number;
}

export function attachPack(
  degree: Degree,
  pack: ProgramPack,
  opts: { exactMajor: boolean } = { exactMajor: true },
): AttachReport {
  const blocks = pack.blocks.filter((b) => b.type !== "DEGREE" && (opts.exactMajor || b.type === "OTHER"));
  let ruleMatched = 0;
  const exactSet = new Set<string>();
  const titleSet = new Set<string>();
  let matched = 0;
  for (const slot of degree.slots) {
    let block: PackBlock | undefined = blocks.find((b) => b.reqId === slot.blockId);
    let exact = true;
    if (!block) {
      const t = nrm(slot.blockTitle);
      block = t ? blocks.find((b) => b.type === slot.blockType && nrm(b.title) === t) : undefined;
      exact = false;
    }
    if (!block) continue;
    const label = nrm(slot.label);
    const bare = nrm(slot.label.replace(SUFFIX_RE, ""));
    const found = findRule(block.rules ?? [], label, [], false) ??
      (bare !== label ? findRule(block.rules ?? [], bare, [], false) : null);
    let overlay = false;
    let ruleLabel: string | undefined;
    let exclusive = block.exclusive === true;
    let shares: SlotShare[] = [...(block.share ?? [])].map((x): SlotShare => ({ ...x, from: "block" }));
    if (found) {
      exclusive = exclusive || found.exclusive;
      shares = [...shares, ...found.shares];
      ruleLabel = found.rule.label;
    } else {
      const ov = (block.overlays ?? []).find((o) => o.label && (nrm(o.label) === label || nrm(o.label) === bare));
      if (ov) {
        overlay = true;
        ruleLabel = ov.label;
      }
    }
    const sp: SlotPack = {
      program: pack.code,
      blockType: block.type,
      blockCode: block.code,
      reqId: block.reqId,
      exact,
      share: dedupShares(shares),
      exclusive,
      overlay,
      ...(ruleLabel !== undefined ? { ruleLabel } : {}),
    };
    slot.pack = sp;
    matched++;
    if (ruleLabel !== undefined) ruleMatched++;
    (exact ? exactSet : titleSet).add(block.reqId);
  }
  return { matchedSlots: matched, totalSlots: degree.slots.length, exactBlocks: exactSet.size, titleBlocks: titleSet.size, ruleMatched };
}

// ---------------------------------------------------------------------------
// The sharing decision
// ---------------------------------------------------------------------------

/** The shares of `from` that reach `to`. */
function reaching(from: SlotPack, to: SlotPack): SlotShare[] {
  const same = from.reqId === to.reqId;
  return from.share.filter((s) => {
    if (s.scope === "thisBlock") return same;
    if (same) return false;
    if (s.scope === "type") return s.type === to.blockType;
    return s.type === to.blockType && s.code === to.blockCode;
  });
}

interface Applicable {
  carrier: Slot;
  share: SlotShare | null; // null: an overlay, which needs no share
}

function applicable(a: Slot, b: Slot): Applicable[] | null {
  if (!a.pack || !b.pack) return null;
  if (a.degreeId !== b.degreeId || a.id === b.id) return null;
  const out: Applicable[] = [];
  if (a.pack.overlay && b.pack.overlay) return out;
  if (a.pack.reqId === b.pack.reqId && (a.pack.overlay || b.pack.overlay)) {
    // An overlay counts courses applied in its block, exclusive rules included.
    out.push({ carrier: a.pack.overlay ? a : b, share: null });
    return out;
  }
  if (a.pack.exclusive || b.pack.exclusive) return out;
  for (const s of reaching(a.pack, b.pack)) out.push({ carrier: a, share: s });
  for (const s of reaching(b.pack, a.pack)) out.push({ carrier: b, share: s });
  return out;
}

export function packShares(a: Slot, b: Slot): boolean | null {
  const ap = applicable(a, b);
  if (ap === null) return null;
  return ap.length > 0;
}

export function packShareCap(a: Slot, b: Slot): { key: string; cu: number } | null {
  const ap = applicable(a, b);
  if (!ap || ap.length === 0) return null;
  let best: { key: string; cu: number } | null = null;
  for (const x of ap) {
    const sh = x.share;
    const caps = [sh?.maxCredits, sh?.maxClasses].filter((n): n is number => typeof n === "number");
    if (!sh || caps.length === 0) return null; // an uncapped road exists
    const cu = Math.min(...caps);
    if (!best || cu < best.cu) {
      const target = `${sh.scope}:${sh.type ?? ""}:${sh.code ?? ""}`;
      // A cap from a block-level share is one budget for the whole block; a
      // rule's own cap is per rule.
      const key = sh.from === "block"
        ? `pack:${x.carrier.degreeId}|${x.carrier.pack!.reqId}|${target}`
        : `pack:${x.carrier.degreeId}|${x.carrier.pack!.reqId}|${nrm(x.carrier.pack!.ruleLabel ?? "")}|${target}`;
      best = { key, cu };
    }
  }
  return best;
}
