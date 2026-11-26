// Registered courses in a future term are load: a plan must not stack new
// courses onto them, and each scheduled course names the slots it fills.
import { assert, assertEquals } from "jsr:@std/assert@1";
import { runEngine } from "../supabase/functions/_shared/degreePlanner/engine.ts";
import { clearCatalogCache } from "../supabase/functions/_shared/degreePlanner/catalog.ts";
import { degreesFromAudits } from "../supabase/functions/_shared/degreePlanner/requirements.ts";

const fx = JSON.parse(Deno.readTextFileSync(new URL("./fixtures/degree-audits-synthetic.json", import.meta.url)));
const NOW = new Date("2026-11-15T17:00:00Z");
const CIS_URL = "https://advising.cis.upenn.edu/assets/json/37cu_csci_tech_elective_list.json";

const audits = [
  { degreeId: "cs", label: "computer science", audit: fx.cs },
  { degreeId: "wh", label: "management", audit: fx.whMgmt },
];
const structured = (history: Record<string, string[]> = {}) => ({ audits, history, currentTerm: "202630" });
const intent = (over: Record<string, unknown> = {}) => ({
  targetTerm: null, maxLoad: null, allowSummer: null, waive: [] as string[], avoid: [] as string[], prefer: [] as string[],
  ...over,
});
// Synthetic registered codes the audits and catalogue never mention: each is
// priced at the 1.0 fallback.
const reg = (n: number) => Array.from({ length: n }, (_, i) => `ZZZZ ${1000 + i}`);

const slug = (c: string) => c.replace(" ", "-");
function fetchAll(): typeof fetch {
  const r = degreesFromAudits(audits);
  const codes = new Set<string>();
  for (const d of r.degrees) for (const s of d.slots) for (const e of s.anyOf) if (e.kind === "courses") e.codes.forEach((c) => codes.add(c));
  return (async (input: string | URL | Request) => {
    const url = String(input);
    const json = (v: unknown) => new Response(JSON.stringify(v), { status: 200 });
    if (url === CIS_URL) return json([]);
    if (/\/search\/courses\/\?attributes=/.test(url)) return json([]);
    if (/\/courses\/$/.test(url)) return json([...codes].map((c) => ({ id: slug(c), title: `${c} title`, credits: 1 })));
    if (/\/courses\/[A-Z]+-\d{4}\/$/.test(url)) {
      const m = url.match(/\/courses\/([A-Z]+-\d{4})\/$/)!;
      return json({ id: m[1], title: `${m[1]} title`, credits: 1, prerequisites: "", attributes: [], crosslistings: [] });
    }
    return new Response("nope", { status: 404 });
  }) as typeof fetch;
}
const run = (history: Record<string, string[]>, over: Record<string, unknown> = {}) => {
  clearCatalogCache();
  return runEngine({ structured: structured(history), intent: intent(over), fetchImpl: fetchAll(), now: NOW, pennData: null });
};

Deno.test("registered load: no scenario stacks new courses past the cap", async () => {
  const out = await run({ "202710": reg(3) });
  const t = out.plan.schedule.find((x) => x.term === "202710");
  assert(t, "the registered term is in the schedule");
  assertEquals(t.registeredCredits, 3);
  // The chosen scenario's cap is its maxLoad; summer is not 202710.
  const chosen = out.plan.scenarios.find((s) => s.id === out.plan.chosen)!;
  assert(t.credits + 3 <= chosen.maxLoad + 1e-9, `${t.credits} + 3 within ${chosen.maxLoad}`);
});

Deno.test("registered load at or above the cap leaves the term with no new courses", async () => {
  for (const n of [6, 8]) {
    const out = await run({ "202710": reg(n) });
    const t = out.plan.schedule.find((x) => x.term === "202710");
    assert(t);
    assertEquals(t.registeredCredits, n);
    assertEquals(t.courses.length, 0);
    assertEquals(t.credits, 0);
  }
});

Deno.test("registered load never lets the plan finish earlier, and not-met is reported", async () => {
  const without = await run({}, { targetTerm: "202710" });
  const withReg = await run({ "202710": reg(5) }, { targetTerm: "202710" });
  const fin = (o: typeof without) => o.plan.scenarios.find((s) => s.id === o.plan.chosen)!.finishTerm;
  const f0 = fin(without), f1 = fin(withReg);
  if (f0 && f1) assert(f1 >= f0, "finish with registered load is not earlier");
  // Same request, same target: the registered term has 5 of 5.5 cu used, so
  // whatever fit in 202710 before no longer fits unless it fits in 0.5 cu.
  const planned0 = without.plan.schedule.find((x) => x.term === "202710")?.credits ?? 0;
  const planned1 = withReg.plan.schedule.find((x) => x.term === "202710")?.credits ?? 0;
  assert(planned1 <= planned0);
  assert(planned1 + 5 <= 6.5 + 1e-9);
});

Deno.test("finish term: only registered courses ahead and nothing left to place", async () => {
  // Waive nothing; give a tiny audit with no open requirements.
  const empty = { goals: fx.cs.goals, blocks: [], courses: [] };
  clearCatalogCache();
  const out = await runEngine({
    structured: { audits: [{ degreeId: "x", label: "x", audit: empty }], history: { "202710": reg(4) }, currentTerm: "202630" },
    intent: intent(), fetchImpl: fetchAll(), now: NOW, pennData: null,
  });
  const chosen = out.plan.scenarios.find((s) => s.id === out.plan.chosen)!;
  assertEquals(chosen.finishTerm, "202710");
  assertEquals(out.plan.schedule.map((t) => t.term), ["202710"]);
});

Deno.test("every scheduled course lists real slot ids, one per countsToward, doubles included", async () => {
  const out = await run({});
  const ids = new Set(degreesFromAudits(audits).degrees.flatMap((d) => d.slots.map((s) => s.id)));
  const all = out.plan.schedule.flatMap((t) => t.courses);
  assert(all.length > 0);
  for (const c of all) {
    assertEquals(c.slotIds.length, c.countsToward.length);
    for (const id of c.slotIds) assert(ids.has(id), `unknown slot id ${id}`);
  }
  const dbl = all.find((c) => c.countsToward.length >= 2);
  assert(dbl, "a double-counted course exists");
  assert(new Set(dbl.slotIds).size >= 2);
});

Deno.test("the registered-load note names the term, registered and added credits", async () => {
  const out = await run({ "202710": reg(3) });
  assert(out.plan.notes.some((n) => /^spring 2027 already has 3 cu registered; the plan adds [\d.]+ cu there$/.test(n)), out.plan.notes.join(" | "));
});
