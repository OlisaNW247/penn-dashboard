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
//     `maxClasses` is ignored: across the 388 published templates it appears
//     27 times, always on a BLOCK-level share (never on a rule), and the
//     planner counts credits, not classes.

import type { PackBlock, PackRule, PackShare, ProgramIndexEntry, ProgramPack } from "./pack.ts";
import type { Degree, Slot, SlotPack } from "./types.ts";

const nrm = (s: string): string =>
  s.toLowerCase().replace(/[^a-z0-9]+/g, " ").replace(/\s+/g, " ").trim();

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
  pick ??= withMajor.find((e) => ["", "NCON", "GEN"].includes(concOf(e)));
  pick ??= withMajor[0];
  return { code: pick.code, exactMajor: true };
}

// ---------------------------------------------------------------------------
// Attaching a pack to a degree's slots
// ---------------------------------------------------------------------------

const SUFFIX_RE = /\s*\(\s*[A-Za-z]{2,5}\s*\d{3,4}\s*\)\s*$/;

function dedupShares(list: PackShare[]): PackShare[] {
  const seen = new Set<string>();
  const out: PackShare[] = [];
  for (const s of list) {
    const k = JSON.stringify([s.scope, s.type ?? "", s.code ?? "", s.maxCredits ?? "", s.maxClasses ?? ""]);
    if (!seen.has(k)) {
      seen.add(k);
      out.push(s);
    }
  }
  return out;
}

function findRule(rules: PackRule[], label: string, inherited: PackShare[]): { rule: PackRule; shares: PackShare[] } | null {
  for (const r of rules) {
    const own = [...inherited, ...(r.share ?? [])];
    if (nrm(r.label) === label) return { rule: r, shares: own };
    if (r.children?.length) {
      const f = findRule(r.children, label, own);
      if (f) return f;
    }
  }
  return null;
}

export function attachPack(
  degree: Degree,
  pack: ProgramPack,
): { matchedSlots: number; totalSlots: number; exactBlocks: number; titleBlocks: number } {
  const blocks = pack.blocks.filter((b) => b.type !== "DEGREE");
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
    const found = findRule(block.rules ?? [], label, []) ?? (bare !== label ? findRule(block.rules ?? [], bare, []) : null);
    let overlay = false;
    let ruleLabel: string | undefined;
    let shares = [...(block.share ?? [])];
    if (found) {
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
      overlay,
      ...(ruleLabel !== undefined ? { ruleLabel } : {}),
    };
    slot.pack = sp;
    matched++;
    (exact ? exactSet : titleSet).add(block.reqId);
  }
  return { matchedSlots: matched, totalSlots: degree.slots.length, exactBlocks: exactSet.size, titleBlocks: titleSet.size };
}

// ---------------------------------------------------------------------------
// The sharing decision
// ---------------------------------------------------------------------------

/** The shares of `from` that reach `to`. */
function reaching(from: SlotPack, to: SlotPack): PackShare[] {
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
  share: PackShare | null; // null: an overlay, which needs no share
}

function applicable(a: Slot, b: Slot): Applicable[] | null {
  if (!a.pack || !b.pack) return null;
  if (a.degreeId !== b.degreeId || a.id === b.id) return null;
  const out: Applicable[] = [];
  if (a.pack.reqId === b.pack.reqId && (a.pack.overlay || b.pack.overlay)) {
    out.push({ carrier: a.pack.overlay ? a : b, share: null });
  }
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
    const cu = x.share?.maxCredits;
    if (cu === undefined) return null; // an uncapped road exists
    if (!best || cu < best.cu) {
      const sh = x.share!;
      best = {
        key: `pack:${x.carrier.degreeId}|${x.carrier.pack!.reqId}|${nrm(x.carrier.pack!.ruleLabel ?? "")}|${sh.scope}:${sh.type ?? ""}:${sh.code ?? ""}`,
        cu,
      };
    }
  }
  return best;
}
