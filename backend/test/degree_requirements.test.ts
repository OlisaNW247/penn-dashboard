import { assert, assertEquals } from "jsr:@std/assert@1";
import { degreesFromAudits } from "../supabase/functions/_shared/degreePlanner/requirements.ts";
import type { Degree, Slot } from "../supabase/functions/_shared/degreePlanner/types.ts";

// Synthetic audits in the Swift JSON shape: Penn's rule labels, texts and
// structure, invented taken courses (no student's history is committed).
const fx = JSON.parse(Deno.readTextFileSync(new URL("./fixtures/degree-audits-synthetic.json", import.meta.url)));

function run(): { cs: Degree; wh: Degree; unfilled: ReturnType<typeof degreesFromAudits>["unfilled"]; taken: string[] } {
  const r = degreesFromAudits([
    { degreeId: "cs", label: "computer science", audit: fx.cs },
    { degreeId: "wh", label: "management (what if, not declared)", audit: fx.whMgmt },
  ]);
  return { cs: r.degrees[0], wh: r.degrees[1], unfilled: r.unfilled, taken: r.taken };
}
function slot(d: Degree, label: string): Slot {
  const s = d.slots.find((x) => x.label === label);
  assert(s, `no slot ${label}; have ${d.slots.map((x) => x.label).join(" / ")}`);
  return s;
}
const summary = (d: Degree) => d.slots.map((s) => `${s.label}|${s.need}${s.unit}|${s.group}`);

Deno.test("CS BSE: exact slot set", () => {
  const { cs, unfilled } = run();
  assertEquals(summary(cs), [
    "Area List - Networking|1courses|seas.core",
    "Calc III or Algebra Course|1courses|seas.math",
    "Math and Natural Science Elective|1cu|seas.math",
    "ENGINEERING (14 CU) (CIS 3200)|1courses|seas.core",
    "Operating Systems|1courses|seas.core",
    "Computer Organization and Design|1courses|seas.core",
    "Senior Project #1|1courses|seas.core",
    "Senior Project #2|1courses|seas.core",
    "CIS Elective at the 2000 Level or Above|2cu|seas.core",
    "Unrestricted Technical Electives|3cu|seas.techElective",
    "Ethics Course|1cu|seas.general",
  ]);
  assertEquals(unfilled, []);
  assertEquals(cs.college, "EU");
});

Deno.test("CS BSE: eligibility and exclusions", () => {
  const { cs } = run();
  assertEquals(slot(cs, "Area List - Networking").anyOf, [
    { kind: "courses", codes: ["NETS 1500", "NETS 2120", "CIS 4510", "CIS 5510", "CIS 4550", "CIS 5550", "CIS 5050", "CIS 5530"] },
  ]);
  assertEquals(slot(cs, "Math and Natural Science Elective").anyOf, [{ kind: "attribute", codes: ["EUNS", "EUMA"] }]);
  const e = slot(cs, "CIS Elective at the 2000 Level or Above");
  assertEquals(e.anyOf, [
    { kind: "courses", codes: ["ESE 3500"] },
    { kind: "range", subject: "CIS", from: 2000, to: 9999 },
    { kind: "range", subject: "NETS", from: 2000, to: 5999 },
  ]);
  assertEquals(e.exclude, [{ kind: "attribute", codes: ["EUNE"] }, { kind: "number", numbers: [2970] }]);
  assertEquals(slot(cs, "Unrestricted Technical Electives").anyOf, [{ kind: "attribute", codes: ["EUCU"] }]);
  const req = slot(cs, "ENGINEERING (14 CU) (CIS 3200)");
  assertEquals(req.id, `${req.degreeId}|b1|${req.id.split("|")[2]}|CIS 3200`);
  assertEquals(req.anyOf, [{ kind: "courses", codes: ["CIS 3200"] }]);
});

Deno.test("CS BSE: skipped rules leave no slot", () => {
  const { cs } = run();
  const labels = cs.slots.map((s) => s.label).join("|");
  assert(!/Minimum|See Appendix|Area List - Databases|Area List - Project|courses$/.test(labels));
  assert(!cs.slots.some((s) => s.blockTitle === "Elective Coursework"));
});

Deno.test("Wharton management what-if: exact slot set", () => {
  const { wh } = run();
  assertEquals(summary(wh), [
    "LEADERSHIP JOURNEY (MGMT 3010)|1courses|wharton.leadership",
    "Senior Capstone|0.5cu|wharton.leadership",
    "FUNDAMENTALS (ACCT 1020)|1courses|wharton.fundamental",
    "FUNDAMENTALS (OIDD 1010)|1courses|wharton.fundamental",
    "Managerial Economics|1cu|wharton.fundamental",
    "Intro Business Stat II|1cu|wharton.fundamental",
    "Global Economy, Business and Society|1cu|wharton.flex",
    "Technology, Innovation, and Analytics|1cu|wharton.flex",
    "Humanities|1cu|wharton.liberal",
    "Cross-Cultural Non-U.S. or U.S.|3cu|wharton.crossCultural",
    "Foreign Language Proficiency|1cu|wharton.language",
    "Business Breadth (1 concentration)|2cu|wharton.breadth",
    "General Management Electives|3cu|wharton.concentration",
  ]);
  assertEquals(slot(wh, "Global Economy, Business and Society").anyOf, [{ kind: "attribute", codes: ["WUGE"] }]);
  assertEquals(slot(wh, "Technology, Innovation, and Analytics").anyOf, [
    { kind: "courses", codes: ["OIDD 4770", "STAT 4770"] },
    { kind: "attribute", codes: ["WUTI"] },
  ]);
  assertEquals(slot(wh, "Cross-Cultural Non-U.S. or U.S.").anyOf, [{ kind: "attribute", codes: ["WUCN", "WUCU"] }]);
  assertEquals(slot(wh, "General Management Electives").anyOf, [
    { kind: "range", subject: "MGMT", from: 1011, to: 4180 },
    { kind: "attribute", codes: ["WUMG"] },
  ]);
});

Deno.test("Wharton breadth constraints and ids", () => {
  const { wh } = run();
  const b = slot(wh, "Business Breadth (1 concentration)");
  assertEquals(b.constraints, {
    distinctSubjects: true,
    excludeSubjects: ["MGMT"],
    usedSubjects: ["LGST"],
    minNumber: 2000,
  });
  assertEquals(b.anyOf, [{
    kind: "subject",
    subjects: ["ACCT", "BEPP", "FNCE", "HCMG", "LGST", "MGMT", "MKTG", "OIDD", "REAL", "STAT", "WH"],
  }]);
  const ids = new Set(wh.slots.map((s) => s.id));
  assertEquals(ids.size, wh.slots.length);
  for (const s of wh.slots) assert(s.id.startsWith("wh|w"));
  assert(wh.slots.every((s) => s.degreeLabel === "management (what if, not declared)"));
});

Deno.test("applied and taken", () => {
  const { cs, wh, taken } = run();
  assert(cs.applied.includes("CIS 2400") && cs.applied.includes("MATH 1410"));
  assert(wh.applied.includes("WH 2010") && wh.applied.includes("MGMT 2110"));
  assertEquals(new Set(taken).size, taken.length);
  assertEquals(new Set(taken), new Set([...cs.applied, ...wh.applied]));
  assert(taken.every((c) => /^[A-Z]{2,5} \d{4}$/.test(c)));
});

Deno.test("undeclared Wharton: declare-a-concentration goes to unfilled", () => {
  const r = degreesFromAudits([{ degreeId: "wu", label: "wharton", audit: fx.whUndeclared }]);
  const d = r.degrees[0];
  assert(!d.slots.some((s) => s.group === "wharton.concentration" || s.group === "wharton.breadth"));
  assertEquals(
    r.unfilled.map((u) => [u.label, u.reason]),
    [
      ["Major Required", "declare a concentration first"],
      ["Concentration Undeclared", "declare a concentration first"],
    ],
  );
  assertEquals(d.slots.length, 11);
});

Deno.test("finance what-if: exclusion by course, options plus range", () => {
  const r = degreesFromAudits([{ degreeId: "fi", label: "finance", audit: fx.whFinance }]);
  const s = r.degrees[0].slots[0];
  assertEquals(s.label, "Finance Courses");
  assertEquals(s.need, 4);
  assertEquals(s.group, "wharton.concentration");
  assertEquals(s.anyOf, [
    { kind: "courses", codes: ["BEPP 2020", "BEPP 2300", "REAL 2090", "REAL 2300"] },
    { kind: "range", subject: "FNCE", from: 2020, to: 4030 },
  ]);
  assertEquals(s.exclude, [{ kind: "courses", codes: ["FNCE 3990"] }]);
});

Deno.test("a slot with no courses is unfilled; wildcards become patterns; bad input is tolerated", () => {
  const rule = (o: Record<string, unknown>) => ({
    id: "x", label: "Odd", ruleType: "g", status: "open", applied: [], advice: [], children: [], ...o,
  });
  const audit = {
    goals: { college: "AS" },
    blocks: [{ id: "b", type: "OTHER", title: "T", rules: [
      rule({ id: "a", label: "Nothing", needCourses: 2 }),
      rule({ id: "b2", label: "Wild", needCourses: 1, advice: [{ code: "mgmt @" }] }),
      rule({ id: "c", label: "Done", needCourses: 1, appliedCount: 1, applied: [{ code: "x 1" }] }),
    ] }],
  };
  const r = degreesFromAudits([{ degreeId: "d", label: "L", audit }, { degreeId: "e", label: "E", audit: null }]);
  assertEquals(r.unfilled.map((u) => [u.label, u.reason]), [["Nothing", "Penn's audit names no courses for this"]]);
  assertEquals(r.degrees[0].slots[0].anyOf, [{ kind: "pattern", pattern: "MGMT @" }]);
  assertEquals(r.degrees[1].slots, []);
});

Deno.test("an unfilled entry never has an empty label", () => {
  const rule = (o: Record<string, unknown>) => ({
    id: "x", label: "Odd", ruleType: "g", status: "open", applied: [], advice: [], children: [], ...o,
  });
  const audit = {
    goals: { college: "WU" },
    blocks: [{ id: "b", type: "OTHER", title: "Business Breadth", rules: [
      rule({ id: "a", label: "  ", needCourses: 2 }),
      rule({ id: "d", label: "", children: [], adviceText: "", needCourses: 1, advice: [] }),
      rule({ id: "m", label: "", status: "open", children: [rule({ id: "i", label: "You must declare a concentration", status: "info" })] }),
    ] }],
  };
  const noTitle = { ...audit, blocks: [{ ...audit.blocks[0], title: "" }] };
  const r = degreesFromAudits([{ degreeId: "d", label: "L", audit }, { degreeId: "e", label: "E", audit: noTitle }]);
  assert(r.unfilled.length >= 4, `${r.unfilled.length}`);
  for (const u of r.unfilled) assert(u.label.trim() !== "", JSON.stringify(u));
  assertEquals(r.unfilled.filter((u) => u.degreeLabel === "L").every((u) => u.label === "Business Breadth"), true);
  assertEquals(r.unfilled.filter((u) => u.degreeLabel === "E").every((u) => u.label === "a requirement"), true);
});

Deno.test("CS BSE: area lists sit beside the CIS elective", () => {
  const { cs } = run();
  assert(slot(cs, "Area List - Networking"));
  assert(slot(cs, "CIS Elective at the 2000 Level or Above"));
});

// ---- creditsSoFar (Engineering's 46 cu floor, read 2026-11-26) -------------

const rule = (id: string, label: string, status = "info", children: unknown[] = []) => ({ id, label, status, children });
const audit = (blocks: unknown[]) => ({ goals: { college: "EU" }, blocks, courses: [] });

Deno.test("creditsSoFar: read from the DEGREE block's label, searching children", () => {
  const label = "You currently have 28.5 CU including both earned and in-progress courses. To graduate, you need to successfully complete a minimum of 8.5 additional CU and all graduation requirements.";
  const flat = degreesFromAudits([{ degreeId: "a", label: "a", audit: audit([{ id: "b0", type: "DEGREE", title: "t", rules: [rule("r1", label)] }]) }]);
  assertEquals(flat.degrees[0].creditsSoFar, 28.5);
  const nested = degreesFromAudits([{ degreeId: "a", label: "a", audit: audit([{ id: "b0", type: "DEGREE", title: "t", rules: [rule("r0", "Total", "open", [rule("r1", label)])] }]) }]);
  assertEquals(nested.degrees[0].creditsSoFar, 28.5);
});

Deno.test("creditsSoFar: absent without the label, and not taken from a MAJOR block", () => {
  const none = degreesFromAudits([{ degreeId: "a", label: "a", audit: audit([{ id: "b0", type: "DEGREE", title: "t", rules: [rule("r1", "Minimum Total Credits Required")] }]) }]);
  assertEquals(none.degrees[0].creditsSoFar, undefined);
  const major = degreesFromAudits([{ degreeId: "a", label: "a", audit: audit([
    { id: "b0", type: "DEGREE", title: "t", rules: [rule("r1", "Minimum Total Credits Required")] },
    { id: "b1", type: "MAJOR", title: "m", rules: [rule("r2", "29 CU are required. You currently have 16.")] },
  ]) }]);
  assertEquals(major.degrees[0].creditsSoFar, undefined);
});

Deno.test("creditsSoFar: prefers the label that says earned over an earlier one", () => {
  const a = degreesFromAudits([{ degreeId: "a", label: "a", audit: audit([{ id: "b0", type: "DEGREE", title: "t", rules: [
    rule("r1", "You currently have 20 CU."),
    rule("r2", "You currently have 28.5 CU including both earned and in-progress courses."),
  ] }]) }]);
  assertEquals(a.degrees[0].creditsSoFar, 28.5);
  const b = degreesFromAudits([{ degreeId: "a", label: "a", audit: audit([{ id: "b0", type: "DEGREE", title: "t", rules: [
    rule("r1", "You currently have 20 CU."), rule("r2", "You currently have 25 CU."),
  ] }]) }]);
  assertEquals(b.degrees[0].creditsSoFar, 20);
});
