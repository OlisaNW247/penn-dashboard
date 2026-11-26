import { assert, assertEquals } from "jsr:@std/assert@1";
import { runEngine, waivedSlotIds } from "../supabase/functions/_shared/degreePlanner/engine.ts";
import { clearCatalogCache } from "../supabase/functions/_shared/degreePlanner/catalog.ts";
import { degreesFromAudits } from "../supabase/functions/_shared/degreePlanner/requirements.ts";

const fx = JSON.parse(Deno.readTextFileSync(new URL("./fixtures/degree-audits-synthetic.json", import.meta.url)));
const NOW = new Date("2026-11-15T17:00:00Z"); // 2026C, 2027A, 2026B
const B = "https://penncoursereview.com/api/base";
const CIS_URL = "https://advising.cis.upenn.edu/assets/json/37cu_csci_tech_elective_list.json";

const structured = (history: Record<string, string[]> = {}) => ({
  audits: [
    { degreeId: "cs", label: "computer science", audit: fx.cs },
    { degreeId: "wh", label: "management", audit: fx.whMgmt },
  ],
  history,
  currentTerm: "202630",
});
const intent = (over: Record<string, unknown> = {}) => ({
  targetTerm: null, maxLoad: null, allowSummer: null, waive: [] as string[], avoid: [] as string[], prefer: [] as string[],
  ...over,
});

/** Every explicit option code in the fixtures, so the lists can serve them. */
function explicitCodes(): string[] {
  const r = degreesFromAudits(structured().audits);
  const out = new Set<string>();
  for (const d of r.degrees) for (const s of d.slots) for (const e of s.anyOf) if (e.kind === "courses") e.codes.forEach((c) => out.add(c));
  return [...out].sort();
}

const ATTR_COURSES: Record<string, string[]> = {
  EUCU: ["BEPP 2500", "STAT 4310", "WUGE 2000"],
  EUNS: ["PHYS 0151"],
  EUMA: ["MATH 1410"],
  WUGE: ["WUGE 2000"],
  WUTI: ["OIDD 3140"],
  WUHM: ["HIST 1000"],
  WUCN: ["ANTH 1000"],
  WUCU: ["ANTH 1000"],
  WUFL: ["SPAN 0100"],
  WUMG: ["MGMT 2380"],
};
const slug = (c: string) => c.replace(" ", "-");

function pennFetch(calls: string[] = [], opts: { empty?: boolean; delayMs?: number } = {}): typeof fetch {
  const codes = new Set<string>([...explicitCodes(), ...Object.values(ATTR_COURSES).flat(), "MGMT 2380", "MGMT 3050"]);
  return (async (input: string | URL | Request) => {
    const url = String(input);
    calls.push(url);
    if (opts.delayMs) await new Promise((r) => setTimeout(r, opts.delayMs));
    if (opts.empty) return new Response("down", { status: 503 });
    const json = (v: unknown) => new Response(JSON.stringify(v), { status: 200 });
    if (url === CIS_URL) return json([{ course4d: "CIS 4550", title: "x", status: "unrestricted" }]);
    let m = url.match(/\/base\/(\d{4}[ABC])\/search\/courses\/\?attributes=(\w+)/);
    if (m) return json((ATTR_COURSES[m[2]] ?? []).map((c) => ({ id: slug(c), title: `${c} title`, credits: 1 })));
    m = url.match(/\/base\/(\d{4}[ABC])\/courses\/$/);
    if (m) return json([...codes].map((c) => ({ id: slug(c), title: `${c} title`, credits: 1 })));
    m = url.match(/\/base\/(\d{4}[ABC])\/courses\/([A-Z]+-\d{4})\/$/);
    if (m) {
      const prereq = m[2] === "CIS-4710" ? "CIS 2400" : m[2] === "CIS-4010" ? "CIS 4000" : "";
      return json({ id: m[2], title: `${m[2]} title`, credits: 1, prerequisites: prereq, attributes: [], crosslistings: [] });
    }
    return new Response("nope", { status: 404 });
  }) as typeof fetch;
}

Deno.test("engine: plans both degrees, counts a course twice and returns scenarios", async () => {
  clearCatalogCache();
  const calls: string[] = [];
  const out = await runEngine({ structured: structured(), intent: intent(), fetchImpl: pennFetch(calls), now: NOW, pennData: null });
  assert(out.plan.schedule.length > 0);
  assert(out.plan.scenarios.length >= 1);
  assert(out.plan.remainingCredits > 0);
  assert(out.plan.remainingCreditsWithoutOverlap >= out.plan.remainingCredits);
  const all = out.plan.schedule.flatMap((t) => t.courses);
  assert(all.some((c) => c.countsToward.length >= 2), "some course counts toward two requirements");
  assert(calls.some((u) => u.includes("attributes=EUCU")), "attribute search made");
  const attrOnly = all.map((c) => c.code).filter((c) => Object.values(ATTR_COURSES).flat().includes(c) && !explicitCodes().includes(c));
  assert(attrOnly.length > 0, "plan uses an attribute-only course");
  assert(calls.some((u) => u.includes(`/courses/${slug(attrOnly[0])}/`)), "detail fetched in the second pass");
  assertEquals(out.unfilled, out.plan.unfilled);
  assert(out.slots > 10);
});

Deno.test("engine: only codes, subjects and attributes are requested", async () => {
  clearCatalogCache();
  const calls: string[] = [];
  await runEngine({ structured: structured(), intent: intent(), fetchImpl: pennFetch(calls), now: NOW, pennData: null });
  for (const u of calls) {
    assert(u.startsWith(`${B}/`) || u === CIS_URL, u);
  }
});

Deno.test("engine: history codes count as taken", async () => {
  clearCatalogCache();
  const base = await runEngine({ structured: structured(), intent: intent(), fetchImpl: pennFetch(), now: NOW, pennData: null });
  clearCatalogCache();
  const withHist = await runEngine({
    pennData: null,
    structured: structured({ "202530": ["cis 4710"] }), intent: intent(), fetchImpl: pennFetch(), now: NOW,
  });
  const has = (r: typeof base, code: string) => r.plan.schedule.some((t) => t.courses.some((c) => c.code === code));
  assert(has(base, "CIS 4710"), "baseline plans CIS 4710");
  assert(!has(withHist, "CIS 4710"), "history course is not planned again");
});

Deno.test("engine: waive labels map to slots (substring either way, any case)", () => {
  const r = degreesFromAudits(structured().audits);
  const w = waivedSlotIds(r.degrees, ["foreign language", "Foreign Language Proficiency (placement exam)", "nonsense thing"]);
  assertEquals(w.ids.length, 1);
  assert(w.ids[0].endsWith("Foreign Language Proficiency") || w.ids[0].includes("|"));
  assertEquals(w.unmatched, ["nonsense thing"]);
});

Deno.test("engine: a waived requirement is not planned and an unmatched label is noted", async () => {
  clearCatalogCache();
  const out = await runEngine({
    pennData: null,
    structured: structured(), intent: intent({ waive: ["Foreign Language", "Unicorn Studies"] }), fetchImpl: pennFetch(), now: NOW,
  });
  const targets = out.plan.schedule.flatMap((t) => t.courses.flatMap((c) => c.countsToward));
  assert(!targets.some((l) => l.includes("Foreign Language")));
  assert(out.plan.notes.some((n) => n.includes("Unicorn Studies")));
});

Deno.test("engine: an empty catalogue still plans from explicit options and says so", async () => {
  clearCatalogCache();
  const out = await runEngine({ structured: structured(), intent: intent(), fetchImpl: pennFetch([], { empty: true }), now: NOW, pennData: null });
  assert(out.plan.notes.some((n) => n.toLowerCase().includes("catalogue")));
  assert(Array.isArray(out.plan.schedule));
});

Deno.test("engine: a spent budget skips the prerequisite pass and says so", async () => {
  clearCatalogCache();
  const calls: string[] = [];
  let t = 0;
  // The clock jumps 30 s after the first read, so the second pass is skipped.
  const clock = () => (t++ < 2 ? 0 : 30_000);
  const out = await runEngine({
    pennData: null,
    structured: structured(), intent: intent(), fetchImpl: pennFetch(calls), now: NOW, budgetMs: 25_000, clock,
  });
  const attrOnly = Object.values(ATTR_COURSES).flat().filter((c) => !explicitCodes().includes(c)).map(slug);
  assert(!calls.some((u) => attrOnly.some((a) => u.endsWith(`/courses/${a}/`))), "no second-pass detail requests");
  assert(out.plan.notes.some((n) => n.includes("prerequisites were not checked")));
});

Deno.test("engine: target, load and summer flow through to the scenarios", async () => {
  clearCatalogCache();
  const out = await runEngine({
    pennData: null,
    structured: structured(), intent: intent({ targetTerm: "202810", maxLoad: 7, allowSummer: false }), fetchImpl: pennFetch(), now: NOW,
  });
  assert(out.plan.scenarios.some((s) => s.id === "student"));
});

Deno.test("engine: unfilled from requirements and the planner are merged without duplicates", async () => {
  clearCatalogCache();
  const s = structured();
  s.audits.push({ degreeId: "wu", label: "wharton undeclared", audit: fx.whUndeclared });
  const out = await runEngine({ structured: s, intent: intent(), fetchImpl: pennFetch(), now: NOW, pennData: null });
  const keys = out.unfilled.map((u) => `${u.degreeLabel}|${u.label}`.toLowerCase());
  assertEquals(new Set(keys).size, keys.length);
});

// ---- deadline, caps, waive rules -------------------------------------------

import { capNeeds, capSlots, MAX_SLOTS } from "../supabase/functions/_shared/degreePlanner/engine.ts";
import type { Slot } from "../supabase/functions/_shared/degreePlanner/types.ts";

Deno.test("engine: a hung catalogue is bounded by the engine budget on a fake clock", async () => {
  clearCatalogCache();
  let t = 0;
  const calls: string[] = [];
  // Every request answers only when aborted; the fake clock is past the
  // budget after the first request is made, so nothing else may start.
  const fetchImpl = ((input: string | URL | Request, init?: RequestInit) => {
    calls.push(String(input));
    t += 30_000;
    return new Promise<Response>((_, reject) => {
      init?.signal?.addEventListener("abort", () => reject(new Error("aborted")), { once: true });
      setTimeout(() => reject(new Error("aborted")), 20);
    });
  }) as typeof fetch;
  const out = await runEngine({
    pennData: null,
    structured: structured(), intent: intent(), fetchImpl, now: NOW, clock: () => t, budgetMs: 25_000,
  });
  assert(calls.length <= 6, `${calls.length} requests started`);
  assert(out.plan.notes.some((n) => n.includes("catalogue could not be read")));
});

Deno.test("engine: the caller's signal reaches the catalogue requests", async () => {
  clearCatalogCache();
  const ctl = new AbortController();
  ctl.abort();
  const calls: string[] = [];
  await runEngine({
    pennData: null,
    structured: structured(), intent: intent(), fetchImpl: pennFetch(calls), now: NOW, signal: ctl.signal,
  });
  assertEquals(calls.length, 0);
});

Deno.test("engine: slot and lookup caps are deterministic", () => {
  const mk = (n: number, id: string) => ({
    id, label: id, college: "EU",
    slots: Array.from({ length: n }, (_, i) => ({ id: `${id}${i}` })) as unknown as Slot[],
    applied: [],
  });
  const c = capSlots([mk(150, "a"), mk(150, "b")] as never);
  assertEquals(c.dropped, true);
  assertEquals(c.degrees.reduce((n, d) => n + d.slots.length, 0), MAX_SLOTS);
  assertEquals(c.degrees[1].slots.length, 50);
  assertEquals(capSlots([mk(10, "a")] as never).dropped, false);

  const many = (n: number, p: string) => Array.from({ length: n }, (_, i) => `${p}${String(i).padStart(3, "0")}`);
  const n = capNeeds({ attributes: many(100, "A"), subjects: many(100, "S"), codes: many(300, "C") });
  assertEquals([n.attributes.length, n.subjects.length, n.codes.length, n.truncated], [40, 60, 150, true]);
  assertEquals(n.attributes[0], "A000");
  assertEquals(capNeeds({ attributes: ["A"], subjects: [], codes: [] }).truncated, false);
});

Deno.test("engine: waive labels must be specific, and ambiguity waives nothing", () => {
  const r = degreesFromAudits(structured().audits);
  const w = waivedSlotIds(r.degrees, ["elective", "Courses", "abc", "foreign language"]);
  assertEquals(w.unmatched, ["elective", "Courses", "abc"]);
  assertEquals(w.ids.length, 1);
  assertEquals(w.waivedLabels.length, 1);

  const slot = (id: string, label: string) => ({ id, label }) as unknown as Slot;
  const deg = [{ id: "d", label: "d", college: "WU", applied: [], slots: [slot("1", "Business Breadth I"), slot("2", "Business Breadth II"), slot("3", "Humanities")] }];
  const amb = waivedSlotIds(deg as never, ["business breadth", "humanities", "Business Breadth II"]);
  assertEquals(amb.ambiguous, ["business breadth"]);
  assertEquals(amb.ids.sort(), ["2", "3"]);
  assertEquals(amb.waivedLabels.sort(), ["Business Breadth II", "Humanities"]);
});

Deno.test("engine: waived requirements are listed in a note", async () => {
  clearCatalogCache();
  const out = await runEngine({
    pennData: null,
    structured: structured(), intent: intent({ waive: ["Foreign Language"] }), fetchImpl: pennFetch(), now: NOW,
  });
  assert(out.plan.notes.some((n) => n.startsWith("treated as done: ") && n.includes("Foreign Language")));
});
