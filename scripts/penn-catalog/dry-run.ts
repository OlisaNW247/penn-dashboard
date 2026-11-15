// Runs the degree planner end to end against Penn's LIVE public data, on a
// GitHub runner (the cloud sessions cannot reach Penn Labs). The audits are
// the synthetic test fixture (Penn's real rule texts, invented courses), so
// nothing here belongs to a student. Prints the slots, the catalogue's size,
// and the plan, so a person can judge whether the double counts and the
// schedule are sensible on real catalogue data.
//
//   deno run --allow-net --allow-read scripts/penn-catalog/dry-run.ts
import { degreesFromAudits } from "../../backend/supabase/functions/_shared/degreePlanner/requirements.ts";
import { buildCatalogSnapshot } from "../../backend/supabase/functions/_shared/degreePlanner/catalog.ts";
import { plan } from "../../backend/supabase/functions/_shared/degreePlanner/planner.ts";
import type { Eligibility } from "../../backend/supabase/functions/_shared/degreePlanner/types.ts";

const fixture = JSON.parse(
  await Deno.readTextFile(new URL("../../backend/test/fixtures/degree-audits-synthetic.json", import.meta.url)),
);
const audits = [
  { degreeId: "cs", label: "computer science", audit: fixture.cs?.audit ?? fixture.cs },
  { degreeId: "wh", label: "management (what if)", audit: fixture.whMgmt?.audit ?? fixture.whMgmt },
];
const { degrees, unfilled, taken } = degreesFromAudits(audits);

console.log("== SLOTS");
for (const d of degrees) {
  for (const s of d.slots) {
    console.log(`${d.label} | ${s.group} | ${s.label} | need ${s.need} ${s.unit} | ${s.anyOf.map(describe).join(" ; ")}`);
  }
}
for (const u of unfilled) console.log(`UNFILLED ${u.degreeLabel} | ${u.label} | ${u.reason}`);

const attributes = new Set<string>();
const subjects = new Set<string>();
const codes = new Set<string>();
for (const d of degrees) {
  for (const s of d.slots) {
    for (const e of s.anyOf) {
      if (e.kind === "attribute") e.codes.forEach((c) => attributes.add(c));
      if (e.kind === "range") subjects.add(e.subject);
      if (e.kind === "subject") e.subjects.forEach((x) => subjects.add(x));
      if (e.kind === "courses") e.codes.forEach((c) => codes.add(c));
      if (e.kind === "pattern") {
        const subj = e.pattern.split(/\s+/)[0];
        if (subj && subj !== "@") subjects.add(subj);
      }
    }
  }
}

const now = new Date("2026-11-15T12:00:00Z");
let t = Date.now();
const catalog = await buildCatalogSnapshot({
  fetchImpl: fetch, now,
  attributes: [...attributes], subjects: [...subjects], codes: [...codes],
});
console.log(`\n== CATALOG ${Object.keys(catalog.courses).length} courses, semesters ${catalog.semesters.join(",")}, ${Date.now() - t} ms`);
for (const [a, list] of Object.entries(catalog.attributeIndex)) console.log(`attr ${a}: ${list.length}`);
console.log(`cis list: ${Object.keys(catalog.cisTechElective).length}`);

for (const target of ["202810", "202830"]) {
  t = Date.now();
  const result = plan({ degrees, taken, history: {}, currentTerm: "202630", targetTerm: target, allowSummer: true }, catalog);
  console.log(`\n== PLAN target ${target} (${Date.now() - t} ms)`);
  console.log(`remaining ${result.remainingCredits} cu, without overlap ${result.remainingCreditsWithoutOverlap} cu, chosen ${result.chosen}`);
  for (const s of result.scenarios) console.log(`scenario ${s.id}: ${s.label} -> ${s.finishTerm} meets ${s.meetsTarget}`);
  for (const term of result.schedule) {
    console.log(`${term.term} (${term.credits} cu)`);
    for (const c of term.courses) console.log(`   ${c.code} ${c.credits} [${c.approval}] ${c.title} :: ${c.countsToward.join(" + ")}`);
  }
  for (const u of result.unfilled) console.log(`unfilled: ${u.degreeLabel} | ${u.label} | ${u.reason}`);
  for (const p of result.petitions) console.log(`petition: ${p.code} ${p.slots.join(" + ")} saves ${p.savesCredits}`);
  for (const n of result.notes) console.log(`note: ${n}`);
}

function describe(e: Eligibility): string {
  switch (e.kind) {
    case "courses": return `courses(${e.codes.length})`;
    case "pattern": return `pattern ${e.pattern}`;
    case "attribute": return `attr ${e.codes.join("|")}`;
    case "range": return `range ${e.subject} ${e.from}-${e.to}`;
    case "subject": return `subjects ${e.subjects.join(",")}`;
    case "number": return `number ${e.numbers.join(",")}`;
  }
}

// The same request through the server's engine, which also fetches the
// prerequisites of the chosen courses and plans a second time.
import { runEngine } from "../../backend/supabase/functions/_shared/degreePlanner/engine.ts";
{
  t = Date.now();
  const out = await runEngine({
    structured: { audits, history: {}, currentTerm: "202630" },
    intent: { targetTerm: "202810", maxLoad: null, allowSummer: null, waive: [], avoid: [], prefer: [] },
    fetchImpl: fetch, now,
  });
  const r = out.plan;
  console.log(`\n== ENGINE (${Date.now() - t} ms) remaining ${r.remainingCredits} chosen ${r.chosen}`);
  for (const s of r.scenarios) console.log(`scenario ${s.id}: ${s.finishTerm} meets ${s.meetsTarget}`);
  for (const term of r.schedule) {
    console.log(`${term.term} (${term.credits} cu): ${term.courses.map((c) => c.code).join(", ")}`);
  }
  const chosen = new Set(r.schedule.flatMap((x) => x.courses.map((c) => c.code)));
  const details = await buildCatalogSnapshot({ fetchImpl: fetch, now, attributes: [], subjects: [], codes: [...chosen] });
  for (const code of chosen) {
    const p = details.courses[code]?.prerequisites;
    if (p) console.log(`prereq ${code}: ${p.slice(0, 160)}`);
  }
  for (const n of r.notes) console.log(`note: ${n}`);
}
