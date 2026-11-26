import { assert, assertEquals } from "jsr:@std/assert@1";
import { parseTemplate, toIndexEntry, toProgramPack, type ProgramPack } from "../supabase/functions/_shared/degreePlanner/pack.ts";
import { attachPack, findProgram, packShareCap, packShares } from "../supabase/functions/_shared/degreePlanner/packJoin.ts";
import { clearPackCache, loadPacks, PENN_DATA_BASE } from "../supabase/functions/_shared/degreePlanner/packData.ts";
import { degreesFromAudits } from "../supabase/functions/_shared/degreePlanner/requirements.ts";
import { pennPolicy } from "../supabase/functions/_shared/degreePlanner/policy.ts";
import { runEngine } from "../supabase/functions/_shared/degreePlanner/engine.ts";
import { clearCatalogCache } from "../supabase/functions/_shared/degreePlanner/catalog.ts";
import type { Degree, Slot, SlotPack } from "../supabase/functions/_shared/degreePlanner/types.ts";

const fx = JSON.parse(Deno.readTextFileSync(new URL("./fixtures/degree-audits-synthetic.json", import.meta.url)));
const tplXml = (code: string) =>
  Deno.readTextFileSync(new URL(`./fixtures/penn-templates/${code}.xml`, import.meta.url));
const PROV = { source: "test", srcdb: "202630", fetched: "2026-11-26" };
const packOf = (code: string): ProgramPack => toProgramPack(code, code, parseTemplate(tplXml(code)), PROV);
const CSCI = packOf("CSCI-BSE-NCON");
const MGMT = packOf("MGMT-BS-GEN");
const FNCS = packOf("FNCS-BS");
// A hand-made second management program, to prove the concentration choice.
const MNMT: ProgramPack = { ...MGMT, code: "MGMT-BS-MNMT", goals: { ...MGMT.goals, conc: "MNMT" } };
const INDEX = [CSCI, FNCS, MGMT, MNMT].map(toIndexEntry);

function load(): { cs: Degree; wh: Degree } {
  const r = degreesFromAudits([
    { degreeId: "cs", label: "computer science", audit: fx.cs },
    { degreeId: "wh", label: "management (what if, not declared)", audit: fx.whMgmt },
  ]);
  return { cs: r.degrees[0], wh: r.degrees[1] };
}
function joined() {
  const { cs, wh } = load();
  const rc = attachPack(cs, CSCI);
  const rw = attachPack(wh, MGMT);
  return { cs, wh, rc, rw };
}
/** A copy of a joined slot under another label, joined again. "Flexible Gen
 *  Eds" is in progress in the synthetic audit, so it has no slot of its own. */
function cloneAs(d: Degree, from: string, label: string): Slot {
  const src = slot(d, from);
  const c: Slot = { ...src, id: `${src.id}|clone`, label, pack: undefined };
  attachPack({ ...d, slots: [c] }, d.id === "wh" ? MGMT : CSCI);
  assert(c.pack, `clone ${label} joined`);
  return c;
}
function slot(d: Degree, label: string): Slot {
  const s = d.slots.find((x) => x.label === label);
  assert(s, `no slot ${label}; have ${d.slots.map((x) => x.label).join(" / ")}`);
  return s;
}
const goals = (o: Partial<NonNullable<Degree["goals"]>>): NonNullable<Degree["goals"]> => ({
  college: "", degree: "", program: "", majors: [], concentrations: [], minors: [], catalogYear: "", ...o,
});

// ------------------------------------------------------------ findProgram

Deno.test("findProgram: exact major and NCON for a CS student", () => {
  assertEquals(findProgram(INDEX, goals({ college: "EU", degree: "BSE", majors: ["CSCI"] })), { code: "CSCI-BSE-NCON", exactMajor: true });
});
Deno.test("findProgram: management without a concentration gets the GEN program; a named one wins", () => {
  assertEquals(findProgram(INDEX, goals({ college: "WU", degree: "BS", majors: ["MGMT"] })), { code: "MGMT-BS-GEN", exactMajor: true });
  assertEquals(
    findProgram(INDEX, goals({ college: "WU", degree: "BS", majors: ["MGMT"], concentrations: ["mnmt"] })),
    { code: "MGMT-BS-MNMT", exactMajor: true },
  );
});
Deno.test("findProgram: undeclared Wharton (WUNG) falls back to a program of the same degree", () => {
  const r = findProgram(INDEX, goals({ college: "wu", degree: "bs", majors: ["WUNG"] }));
  assertEquals(r, { code: "FNCS-BS", exactMajor: false });
});
Deno.test("findProgram: empty goals or no match is null", () => {
  assertEquals(findProgram(INDEX, undefined), null);
  assertEquals(findProgram(INDEX, goals({})), null);
  assertEquals(findProgram(INDEX, goals({ college: "AS", degree: "BA", majors: ["HIST"] })), null);
});

// ------------------------------------------------------------ attachPack

Deno.test("attachPack: join numbers on the synthetic audits", () => {
  const { cs, wh, rc, rw } = joined();
  const unjoined = [...cs.slots, ...wh.slots].filter((s) => !s.pack).map((s) => `${s.degreeId}:${s.label}`);
  console.log("JOIN cs", JSON.stringify(rc), "wh", JSON.stringify(rw), "unjoined", JSON.stringify(unjoined));
  assertEquals(rc.totalSlots, cs.slots.length);
  assertEquals(rw.totalSlots, wh.slots.length);
  // The audit's block ids ("b1") are not Penn's Req_ids, so every join is by title.
  assertEquals(rc.exactBlocks, 0);
  assertEquals(rw.exactBlocks, 0);
});

Deno.test("attachPack: an exact Req_id join is reported as exact", () => {
  const { wh } = load();
  const blk = MGMT.blocks.find((b) => b.code === "U-WLAS")!;
  const s = slot(wh, "Humanities");
  s.blockId = blk.reqId;
  const r = attachPack(wh, MGMT);
  assert(r.exactBlocks >= 1);
  assertEquals(s.pack?.exact, true);
});

Deno.test("attachPack: area lists are overlays of block CSCI; Wharton rule shares", () => {
  const { cs, wh } = joined();
  const area = slot(cs, "Area List - Networking");
  assertEquals(area.pack?.overlay, true);
  assertEquals(area.pack?.blockCode, "CSCI");
  assertEquals(area.pack?.exact, false);
  const cc = slot(wh, "Cross-Cultural Non-U.S. or U.S.");
  assert(cc.pack!.share.some((s) => s.scope === "thisBlock" && s.maxCredits === 2));
  const fl = slot(wh, "Foreign Language Proficiency");
  assert(fl.pack!.share.some((s) => s.scope === "thisBlock" && s.maxCredits === undefined));
  const fx1 = slot(wh, "FUNDAMENTALS (ACCT 1020)");
  assertEquals(fx1.pack?.ruleLabel, "FUNDAMENTALS");
  for (const label of ["Managerial Economics", "Global Economy, Business and Society", "Senior Capstone"]) {
    const sh = slot(wh, label).pack!.share;
    assert(sh.some((s) => s.scope === "type" && s.type === "MINOR"), label);
    assert(sh.some((s) => s.scope === "block" && s.type === "OTHER" && s.code === "U-SCHOLARS"), label);
  }
});

// ------------------------------------------------------------ packShares

Deno.test("packShares: Penn's table on the synthetic slots", () => {
  const { cs, wh } = joined();
  const area = slot(cs, "Area List - Networking");
  assertEquals(packShares(area, slot(cs, "CIS Elective at the 2000 Level or Above")), true);
  assertEquals(packShares(area, slot(cs, "Ethics Course")), false); // General Electives block, no target
  const cc = slot(wh, "Cross-Cultural Non-U.S. or U.S.");
  const hum = slot(wh, "Humanities");
  const lang = slot(wh, "Foreign Language Proficiency");
  assertEquals(packShares(cc, hum), true);
  assertEquals(packShares(cc, lang), true);
  assertEquals(packShares(hum, cloneAs(wh, "Humanities", "Flexible Gen Eds")), false);
  const conc = slot(wh, "General Management Electives");
  assertEquals(packShares(slot(wh, "Global Economy, Business and Society"), conc), false);
  assertEquals(packShares(slot(wh, "Business Breadth (1 concentration)"), conc), false);
  assertEquals(
    packShares(slot(cs, "Unrestricted Technical Electives"), slot(cs, "Math and Natural Science Elective")),
    false,
  );
  assertEquals(packShares(area, area), null);
  assertEquals(packShares(area, cc), null); // different degrees
});

Deno.test("packShares: a slot without a pack is null", () => {
  const { cs } = joined();
  const bare = { ...slot(cs, "Operating Systems") } as Slot;
  delete bare.pack;
  bare.id = "x";
  assertEquals(packShares(bare, slot(cs, "Ethics Course")), null);
});

Deno.test("packShares: a block-level thisBlock-less share does not reach the block itself", () => {
  const { cs } = joined();
  // CSCI's block shares with MAJOR/MINOR/CONC blocks, not with its own rules.
  assertEquals(packShares(slot(cs, "Operating Systems"), slot(cs, "Unrestricted Technical Electives")), false);
});

Deno.test("packShares: symmetry and ancestor inheritance (SEAS writing group)", () => {
  const { cs, wh } = joined();
  // Build two slots under the General Electives block's "Writing Course" group.
  const base = slot(cs, "Ethics Course");
  const mk = (label: string, id: string): Slot => ({
    ...base, id, label,
    pack: { ...base.pack!, ruleLabel: label, share: [...base.pack!.share] },
  });
  const hw = mk("Humanities Writing Course", "w1");
  const sw = mk("Social Sciences Writing Course", "w2");
  // Attach properly through a throwaway degree.
  const d: Degree = { ...cs, slots: [hw, sw] };
  hw.blockId = sw.blockId = "none";
  hw.pack = sw.pack = undefined;
  attachPack(d, CSCI);
  const hp = hw.pack as SlotPack | undefined;
  assert(hp && sw.pack, "writing children join the General Electives block");
  assertEquals(hp.blockCode, "U-SEAS-SSH");
  assert(hp.share.some((x) => x.scope === "thisBlock"), "inherited from the Writing Course group");
  assertEquals(packShares(hw, sw), true);
  assertEquals(packShares(sw, hw), true);
  // Symmetry across blocks: B names nothing, A's type target reaches B.
  const a = slot(wh, "Humanities");
  const b = slot(wh, "General Management Electives");
  a.pack!.share = [{ scope: "type", type: "MAJOR", from: "rule" }];
  b.pack!.share = [];
  assertEquals(packShares(a, b), true);
  assertEquals(packShares(b, a), true);
});

// ------------------------------------------------------------ packShareCap

Deno.test("packShareCap: capped share gives its cap; uncapped or no share gives null", () => {
  const { wh, cs } = joined();
  const cc = slot(wh, "Cross-Cultural Non-U.S. or U.S.");
  const cap = packShareCap(cc, slot(wh, "Humanities"));
  assertEquals(cap?.cu, 2);
  assert(cap!.key.includes("Cross-Cultural".toLowerCase().replace(/[^a-z0-9]+/g, " ")) || cap!.key.includes("cross cultural"));
  assertEquals(packShareCap(cc, slot(wh, "Foreign Language Proficiency")), null); // language's own share is uncapped
  assertEquals(packShareCap(slot(wh, "Humanities"), cloneAs(wh, "Humanities", "Flexible Gen Eds")), null);
  assertEquals(packShareCap(slot(cs, "Area List - Networking"), slot(cs, "CIS Elective at the 2000 Level or Above")), null);
});

// ------------------------------------------------------------ parity

Deno.test("parity: where Penn's data and the hand policy disagree", () => {
  const { cs, wh } = joined();
  const diffs: string[] = [];
  for (const d of [cs, wh]) {
    for (let i = 0; i < d.slots.length; i++) {
      for (let j = i + 1; j < d.slots.length; j++) {
        const a = d.slots[i], b = d.slots[j];
        const penn = packShares(a, b);
        if (penn === null) continue;
        const ha = { ...a }, hb = { ...b };
        delete ha.pack;
        delete hb.pack;
        const hand = pennPolicy.withinDegree(ha, hb);
        if (penn !== hand) diffs.push(`${d.id}: ${a.label} | ${b.label} penn=${penn} hand=${hand}`);
      }
    }
  }
  console.log("PARITY\n" + diffs.join("\n"));
  // An overlay shares with every NON-overlay slot of its block (the hand
  // policy allowed only the "CIS Elective at 2000+" slot); cross-cultural +
  // language is new. Overlay + overlay stays false.
  const areaWide = [
    "Calc III or Algebra Course", "Math and Natural Science Elective", "ENGINEERING (14 CU) (CIS 3200)",
    "Operating Systems", "Computer Organization and Design", "Senior Project #1", "Senior Project #2",
    "Unrestricted Technical Electives",
  ].map((l) => `cs: Area List - Networking | ${l} penn=true hand=false`);
  assertEquals(diffs, [
    ...areaWide,
    "wh: Cross-Cultural Non-U.S. or U.S. | Foreign Language Proficiency penn=true hand=false",
  ]);
});

// ------------------------------------------------------------ packData

const BASE = "https://packs.test/pin";
const progJson = JSON.stringify({ generatedFrom: "test", programs: INDEX });
function packFetch(calls: string[], over: Record<string, () => Response | Promise<Response>> = {}): typeof fetch {
  return (async (input: string | URL | Request, init?: RequestInit) => {
    const url = String(input);
    calls.push(url);
    if (over[url]) return await over[url]();
    if (url === `${BASE}/programs.json`) return new Response(progJson, { status: 200 });
    const m = url.match(/\/packs\/([A-Z-]+)\.json$/);
    if (m) {
      const p = [CSCI, MGMT, FNCS, MNMT].find((x) => x.code === m[1]);
      if (p) return new Response(JSON.stringify(p), { status: 200 });
    }
    void init;
    return new Response("nope", { status: 404 });
  }) as typeof fetch;
}
const degreesWithGoals = (): Degree[] => {
  const { cs, wh } = load();
  wh.goals = { ...wh.goals!, majors: ["MGMT"] };
  return [cs, wh];
};

Deno.test("loadPacks: success, then served from the cache", async () => {
  clearPackCache();
  const calls: string[] = [];
  const r = await loadPacks({ baseUrl: BASE, degrees: degreesWithGoals(), fetchImpl: packFetch(calls) });
  assertEquals(r.error, undefined);
  assertEquals(r.programs, { cs: { code: "CSCI-BSE-NCON", exactMajor: true }, wh: { code: "MGMT-BS-GEN", exactMajor: true } });
  assertEquals(Object.keys(r.packs).sort(), ["cs", "wh"]);
  assertEquals(calls.length, 3);
  const r2 = await loadPacks({ baseUrl: BASE, degrees: degreesWithGoals(), fetchImpl: packFetch(calls) });
  assertEquals(calls.length, 3, "a warm isolate refetches nothing");
  assertEquals(Object.keys(r2.packs).sort(), ["cs", "wh"]);
});

Deno.test("loadPacks: a 404 on one pack keeps the other and sets error", async () => {
  clearPackCache();
  const calls: string[] = [];
  const r = await loadPacks({
    baseUrl: BASE, degrees: degreesWithGoals(),
    fetchImpl: packFetch(calls, { [`${BASE}/packs/MGMT-BS-GEN.json`]: () => new Response("x", { status: 404 }) }),
  });
  assertEquals(Object.keys(r.packs), ["cs"]);
  assertEquals(Object.keys(r.programs), ["cs"]);
  assertEquals(r.error, "http 404");
});

Deno.test("loadPacks: malformed JSON and wrong shapes are misses and never throw", async () => {
  clearPackCache();
  let r = await loadPacks({
    baseUrl: BASE, degrees: degreesWithGoals(),
    fetchImpl: packFetch([], { [`${BASE}/programs.json`]: () => new Response("{not json", { status: 200 }) }),
  });
  assertEquals(r.packs, {});
  assert(r.error);
  clearPackCache();
  r = await loadPacks({
    baseUrl: BASE, degrees: degreesWithGoals(),
    fetchImpl: packFetch([], { [`${BASE}/programs.json`]: () => new Response(JSON.stringify({ programs: "no" }), { status: 200 }) }),
  });
  assertEquals(r.error, "bad shape");
  clearPackCache();
  r = await loadPacks({
    baseUrl: BASE, degrees: degreesWithGoals(),
    fetchImpl: packFetch([], { [`${BASE}/packs/CSCI-BSE-NCON.json`]: () => new Response(JSON.stringify({ code: "x", blocks: [{}] }), { status: 200 }) }),
  });
  assertEquals(Object.keys(r.packs), ["wh"]);
  clearPackCache();
  r = await loadPacks({
    baseUrl: BASE, degrees: degreesWithGoals(),
    fetchImpl: (() => { throw new Error("boom"); }) as unknown as typeof fetch,
  });
  assertEquals(r.packs, {});
  assert(r.error);
});

Deno.test("loadPacks: a hang is cut by the deadline", async () => {
  clearPackCache();
  const hang = (_u: string | URL | Request, init?: RequestInit) =>
    new Promise<Response>((_res, rej) => init?.signal?.addEventListener("abort", () => rej(new Error("aborted"))));
  const t0 = Date.now();
  const r = await loadPacks({
    baseUrl: BASE, degrees: degreesWithGoals(), fetchImpl: hang as unknown as typeof fetch, deadline: Date.now() + 60,
  });
  assert(Date.now() - t0 < 1500, "returned promptly");
  assertEquals(r.packs, {});
  assertEquals(r.error, "timeout");
  // A deadline already past makes no request at all.
  let n = 0;
  const r2 = await loadPacks({
    baseUrl: BASE, degrees: degreesWithGoals(), deadline: Date.now() - 1,
    fetchImpl: (() => { n++; return Promise.resolve(new Response("{}")); }) as unknown as typeof fetch,
  });
  assertEquals(n, 0);
  assertEquals(r2.error, "deadline");
});

Deno.test("loadPacks: the default base is pinned to the raw GitHub path", () => {
  assert(PENN_DATA_BASE.startsWith("https://raw.githubusercontent.com/OlisaNW247/penn-dashboard/"));
});

// ------------------------------------------------------------ engine

const NOW = new Date("2026-11-15T17:00:00Z");
const CIS_URL = "https://advising.cis.upenn.edu/assets/json/37cu_csci_tech_elective_list.json";
const structured = () => ({
  audits: [
    { degreeId: "cs", label: "computer science", audit: fx.cs },
    { degreeId: "wh", label: "management", audit: fx.whMgmt },
  ],
  history: {} as Record<string, string[]>,
  currentTerm: "202630",
});
const intent = { targetTerm: null, maxLoad: null, allowSummer: null, waive: [] as string[], avoid: [] as string[], prefer: [] as string[] };
const ALL = ["NETS 2120", "CIS 4510", "CIS 4550", "NETS 1500", "CIS 5510", "CIS 5050", "CIS 5530", "CIS 5550"];
function engineFetch(calls: string[]): typeof fetch {
  const inner = packFetch(calls);
  return (async (input: string | URL | Request, init?: RequestInit) => {
    const url = String(input);
    if (url.startsWith(BASE)) return await inner(input, init);
    calls.push(url);
    const json = (v: unknown) => new Response(JSON.stringify(v), { status: 200 });
    if (url === CIS_URL) return json([]);
    if (/\/search\/courses\/\?attributes=EUCU/.test(url)) return json(ALL.map((c) => ({ id: c.replace(" ", "-"), title: c, credits: 1 })));
    if (/\/search\/courses\/\?attributes=/.test(url)) return json([]);
    if (/\/courses\/$/.test(url)) return json(ALL.map((c) => ({ id: c.replace(" ", "-"), title: c, credits: 1 })));
    return new Response("nope", { status: 404 });
  }) as typeof fetch;
}
const counts = (out: Awaited<ReturnType<typeof runEngine>>) =>
  out.plan.schedule.flatMap((t) => t.courses).map((c) => c.countsToward);

Deno.test("engine: packs are loaded, reported and used for within-degree sharing", async () => {
  clearCatalogCache();
  clearPackCache();
  const calls: string[] = [];
  const out = await runEngine({
    structured: structured(), intent, fetchImpl: engineFetch(calls), now: NOW, pennData: { baseUrl: BASE },
  });
  assertEquals(out.packError, undefined);
  const cs = out.packs.find((p) => p.degreeId === "cs")!;
  const wh = out.packs.find((p) => p.degreeId === "wh")!;
  assertEquals(cs.program, "CSCI-BSE-NCON");
  assertEquals(cs.matchedSlots, cs.totalSlots);
  assertEquals(wh.program, wh.exactMajor ? "MGMT-BS-GEN" : wh.program);
  assert(wh.matchedSlots > 0 && wh.titleBlocks > 0);
  // Which courses the planner doubles up is its own cost-driven choice (the
  // template also allows area list + technical elective, which parity covers);
  // here the area list and the CIS elective share a course under both rules.
  const both = (c: string[]) =>
    c.some((l) => l.endsWith("Area List - Networking")) && c.some((l) => l.endsWith("CIS Elective at the 2000 Level or Above"));
  assert(counts(out).some(both), "an area-list course also fills the CIS elective");
  // The title-matched block gets the one catalog-year note.
  assertEquals(out.plan.notes.filter((n) => n.startsWith("double counting inside")).length, 1);

  clearCatalogCache();
  const off = await runEngine({
    structured: structured(), intent, fetchImpl: engineFetch([]), now: NOW, pennData: null,
  });
  assertEquals(off.packs.every((p) => p.program === null), true);
  assert(counts(off).some(both), "the hand policy allows that pair too");
  assert(!off.plan.notes.some((n) => n.startsWith("double counting inside")));
});

Deno.test("engine: unreachable pack data leaves the plan to the hand policy and reports why", async () => {
  clearCatalogCache();
  clearPackCache();
  const dead = engineFetch([]);
  const out = await runEngine({
    structured: structured(), intent, now: NOW, pennData: { baseUrl: "https://down.test/x" },
    fetchImpl: ((i: string | URL | Request, n?: RequestInit) =>
      String(i).startsWith("https://down.test") ? Promise.resolve(new Response("x", { status: 503 })) : dead(i, n)) as typeof fetch,
  });
  assertEquals(out.packError, "http 503");
  assert(out.packs.every((p) => p.program === null));
  assert(out.plan.schedule.length > 0);
});

// ------------------------------------------------------------ review fixes

import type { PackBlock, PackRule } from "../supabase/functions/_shared/degreePlanner/pack.ts";

const mkRule = (label: string, extra: Partial<PackRule> = {}): PackRule => ({ id: label, label, type: "course", ...extra });
const mkBlock = (reqId: string, type: string, code: string, title: string, rules: PackRule[], extra: Partial<PackBlock> = {}): PackBlock => ({
  reqId, type, code, title, catalogYears: { start: "2020", stop: "9999" }, share: [], standalone: false, limits: [], overlays: [],
  other: [], rules, ...extra,
});
const mkPack = (blocks: PackBlock[]): ProgramPack => ({
  code: "X-BS", title: "x", goals: {}, goalNames: {}, provenance: PROV, blocks,
});
let slotN = 0;
const mkSlot = (label: string, block: PackBlock): Slot => ({
  id: `s${slotN++}`, degreeId: "d", degreeLabel: "d", label, blockTitle: block.title, blockId: "audit-id", blockType: block.type,
  need: 1, unit: "courses", anyOf: [], exclude: [], group: "other",
});
const mkDegree = (slots: Slot[]): Degree => ({ id: "d", label: "d", college: "AS", slots, applied: [] });
function joinedPair(pack: ProgramPack, a: string, b: string, blockIdx = 0): [Slot, Slot] {
  const blk = pack.blocks[blockIdx];
  const sa = mkSlot(a, blk), sb = mkSlot(b, blk);
  attachPack(mkDegree([sa, sb]), pack);
  return [sa, sb];
}

Deno.test("exclusive: a rule carrying EXCLUSIVE shares with nothing, from either side (inline template)", () => {
  const blk = mkBlock("R1", "MAJOR", "H", "Major in H", [
    mkRule("SEMINAR", { share: [{ scope: "thisBlock" }] }),
    mkRule("ELECTIVES", { exclusive: true }),
    mkRule("OPEN"),
  ]);
  const pack = mkPack([blk]);
  const [sem, el] = joinedPair(pack, "SEMINAR", "ELECTIVES");
  assertEquals(el.pack?.exclusive, true);
  assertEquals(packShares(sem, el), false);
  assertEquals(packShares(el, sem), false);
  assertEquals(packShareCap(sem, el), null);
  // A neighbour that is not exclusive still shares through the share.
  const [s2, o] = joinedPair(pack, "SEMINAR", "OPEN");
  assertEquals(packShares(s2, o), true);
  // An exclusive ancestor makes its children exclusive.
  const g = mkBlock("R2", "MAJOR", "G", "Major in G", [mkRule("GROUP", { exclusive: true, children: [mkRule("CHILD")] }), mkRule("OTHER", { share: [{ scope: "thisBlock" }] })]);
  const [c, ot] = joinedPair(mkPack([g]), "CHILD", "OTHER");
  assertEquals(c.pack?.exclusive, true);
  assertEquals(packShares(c, ot), false);
  // An overlay still counts a course applied to an exclusive rule (assumption in the module comment).
  const ov = mkBlock("R3", "MAJOR", "O", "Major in O", [mkRule("EX", { exclusive: true })], {
    overlays: [{ kind: "MINCLASS", label: "Area List - X", need: 1, unit: "courses", courses: [], except: [], text: "" }],
  });
  const [area, ex] = joinedPair(mkPack([ov]), "Area List - X", "EX");
  assertEquals(area.pack?.overlay, true);
  assertEquals(packShares(area, ex), true);
});

Deno.test("overlays: share with non-overlay slots of their block, not with each other", () => {
  const ov = (label: string) => ({ kind: "MINCLASS" as const, label, need: 1, unit: "courses" as const, courses: [], except: [], text: "" });
  const blk = mkBlock("R1", "MAJOR", "C", "Major in C", [mkRule("CORE")], { overlays: [ov("Area List - A"), ov("Area List - B")] });
  const pack = mkPack([blk]);
  const a = mkSlot("Area List - A", blk), b = mkSlot("Area List - B", blk), core = mkSlot("CORE", blk);
  attachPack(mkDegree([a, b, core]), pack);
  assertEquals(packShares(a, core), true);
  assertEquals(packShares(a, b), false);
});

Deno.test("maxClasses is read as that many cu", () => {
  const blk = mkBlock("R1", "MAJOR", "C", "Major in C", [mkRule("A"), mkRule("B")], { share: [{ scope: "thisBlock", maxClasses: 2 }] });
  const [a, b] = joinedPair(mkPack([blk]), "A", "B");
  assertEquals(packShareCap(a, b)?.cu, 2);
  const both = mkBlock("R2", "MAJOR", "D", "Major in D", [mkRule("A"), mkRule("B")], { share: [{ scope: "thisBlock", maxClasses: 3, maxCredits: 1.5 }] });
  const [c, d] = joinedPair(mkPack([both]), "A", "B");
  assertEquals(packShareCap(c, d)?.cu, 1.5);
});

Deno.test("cap keys: a block-level cap is one budget for the block, a rule-level cap is per rule", () => {
  const blkCap = mkBlock("R1", "MAJOR", "C", "Major in C", [mkRule("A"), mkRule("B"), mkRule("C")], { share: [{ scope: "thisBlock", maxCredits: 3 }] });
  const p1 = mkPack([blkCap]);
  const [a, b] = joinedPair(p1, "A", "B");
  const [a2, c2] = joinedPair(p1, "A", "C");
  const k1 = packShareCap(a, b)!, k2 = packShareCap(a2, c2)!;
  assertEquals(k1.key, k2.key);
  assert(!k1.key.includes("|a|"), "no rule label in a block-level key");
  const ruleCap = mkBlock("R2", "MAJOR", "D", "Major in D", [
    mkRule("A", { share: [{ scope: "thisBlock", maxCredits: 2 }] }),
    mkRule("B", { share: [{ scope: "thisBlock", maxCredits: 2 }] }),
    mkRule("C"),
  ]);
  const p2 = mkPack([ruleCap]);
  const [ra, rc] = joinedPair(p2, "A", "C");
  const [rb, rc2] = joinedPair(p2, "B", "C");
  assert(packShareCap(ra, rc)!.key !== packShareCap(rb, rc2)!.key, "each rule keeps its own budget");
  assertEquals(packShareCap(ra, rc)!.cu, 2);
});

Deno.test("findProgram: a concentration no program carries is not an exact major", () => {
  assertEquals(
    findProgram(INDEX, goals({ college: "WU", degree: "BS", majors: ["MGMT"], concentrations: ["ZZZZ"] })),
    { code: "MGMT-BS-GEN", exactMajor: false },
  );
});

Deno.test("attachPack: a program found by school and degree only joins its school-wide blocks", () => {
  const { wh } = load();
  const r = attachPack(wh, MGMT, { exactMajor: false });
  assert(wh.slots.some((s) => s.pack), "school-wide blocks join");
  for (const s of wh.slots) {
    if (s.blockType !== "OTHER") assertEquals(s.pack, undefined, s.label);
    else assert(s.pack, s.label);
  }
  assert(r.matchedSlots < r.totalSlots);
  assertEquals(slot(wh, "General Management Electives").pack, undefined);
});

Deno.test("attachPack: ruleMatched counts slots whose rule or overlay label matched", () => {
  const { cs, wh, rc, rw } = joined();
  const blockOnly = [...cs.slots, ...wh.slots].filter((s) => s.pack && s.pack.ruleLabel === undefined).map((s) => s.label);
  console.log("RULEMATCHED cs", rc.ruleMatched, "/", rc.matchedSlots, "wh", rw.ruleMatched, "/", rw.matchedSlots, "blockOnly", JSON.stringify(blockOnly));
  assertEquals(rc.ruleMatched + rw.ruleMatched + blockOnly.length, rc.matchedSlots + rw.matchedSlots);
  const blk = mkBlock("R1", "MAJOR", "C", "Major in C", [mkRule("KNOWN")]);
  const k = mkSlot("KNOWN", blk), u = mkSlot("UNKNOWN", blk);
  const r = attachPack(mkDegree([k, u]), mkPack([blk]));
  assertEquals([r.matchedSlots, r.ruleMatched], [2, 1]);
});

Deno.test("engine: a pack that throws in attachPack leaves the degree on the hand policy and says so", async () => {
  clearCatalogCache();
  clearPackCache();
  const bad = { ...CSCI, blocks: CSCI.blocks.map((b) => ({ ...b, rules: [{ id: "1", label: "x", share: 5 }] })) };
  const inner = engineFetch([]);
  const out = await runEngine({
    structured: structured(), intent, now: NOW, pennData: { baseUrl: BASE },
    fetchImpl: ((i: string | URL | Request, n?: RequestInit) =>
      String(i).endsWith("/packs/CSCI-BSE-NCON.json") ? Promise.resolve(new Response(JSON.stringify(bad), { status: 200 })) : inner(i, n)) as typeof fetch,
  });
  assert(out.packError?.includes("attach failed"), String(out.packError));
  const cs = out.packs.find((p) => p.degreeId === "cs")!;
  assertEquals(cs.program, null);
  assert(out.plan.schedule.length > 0);
  assert(out.packs.find((p) => p.degreeId === "wh")!.program !== null, "the other degree keeps its pack");
});
