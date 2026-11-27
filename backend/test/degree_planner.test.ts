// Degree planner tests. The data is synthetic, modeled on the shape of a real
// dual-degree case (CS BSE + Wharton) without any real student's history.
import { strict as assert } from "node:assert";
import { plan } from "../supabase/functions/_shared/degreePlanner/planner.ts";
import { pennPolicy } from "../supabase/functions/_shared/degreePlanner/policy.ts";
import type {
  CatalogCourse,
  CatalogSnapshot,
  Degree,
  Eligibility,
  PlanRequest,
  PlanResult,
  Slot,
  SlotGroup,
} from "../supabase/functions/_shared/degreePlanner/types.ts";

// ---- builders --------------------------------------------------------------

/** offered: letters f, s, u (fall, spring, summer). */
function course(
  code: string,
  credits: number,
  attrs: string[] = [],
  offered = "fs",
  prerequisites?: string,
  crosslistings?: string[],
): CatalogCourse {
  return {
    code, title: `${code} title`, credits, attributes: attrs,
    offered: { fall: offered.includes("f"), spring: offered.includes("s"), summer: offered.includes("u") },
    prerequisites, crosslistings,
  };
}

const opts = (...codes: string[]): Eligibility[] => [{ kind: "courses", codes }];
const attr = (...codes: string[]): Eligibility[] => [{ kind: "attribute", codes }];

function slot(
  degreeId: string, degreeLabel: string, label: string, group: SlotGroup,
  need: number, unit: "cu" | "courses", anyOf: Eligibility[], extra: Partial<Slot> = {},
): Slot {
  return {
    id: `${degreeId}|b|${label}`, degreeId, degreeLabel, label, blockTitle: "b", blockId: "b", blockType: "OTHER",
    need, unit, anyOf, exclude: [], group, ...extra,
  };
}

const CS = "computer science";
const WH = "wharton";
const cs = (label: string, group: SlotGroup, need: number, unit: "cu" | "courses", anyOf: Eligibility[], extra: Partial<Slot> = {}) =>
  slot("cs", CS, label, group, need, unit, anyOf, extra);
const wh = (label: string, group: SlotGroup, need: number, unit: "cu" | "courses", anyOf: Eligibility[], extra: Partial<Slot> = {}) =>
  slot("wh", WH, label, group, need, unit, anyOf, extra);

function csSlots(): Slot[] {
  return [
    cs("Core 1200", "seas.core", 1, "courses", opts("CIS 1200")),
    cs("Core 1210", "seas.core", 1, "courses", opts("CIS 1210")),
    cs("Core 2400", "seas.core", 1, "courses", opts("CIS 2400")),
    cs("Core 2620", "seas.core", 1, "courses", opts("CIS 2620")),
    cs("Core 3200", "seas.core", 1, "courses", opts("CIS 3200")),
    cs("Senior Project #1", "seas.core", 1, "courses", opts("CIS 4000", "CIS 4500")),
    cs("Senior Project #2", "seas.core", 1, "courses", opts("CIS 4010", "CIS 4510")),
    cs("CIS Electives", "seas.core", 2, "courses", [{ kind: "range", subject: "CIS", from: 2000, to: 4999 }]),
    cs("Networking", "seas.core", 1, "courses", opts("CIS 3310", "CIS 3320")),
    cs("Calculus III", "seas.math", 1, "courses", opts("MATH 2400", "MATH 2600")),
    cs("Math Science Elective", "seas.math", 2, "courses", attr("EUNS", "EUMA")),
    cs("Technical Electives", "seas.techElective", 4, "cu", attr("EUCU")),
    cs("Ethics", "seas.general", 1, "courses", opts("PHIL 2620", "STSC 2000")),
  ];
}

function whSlots(): Slot[] {
  return [
    wh("Accounting II", "wharton.fundamental", 1, "cu", opts("ACCT 1020")),
    wh("Operations", "wharton.fundamental", 1, "cu", opts("OIDD 1010")),
    wh("Leadership MGMT 3010", "wharton.leadership", 1, "cu", opts("MGMT 3010")),
    wh("Senior Capstone", "wharton.leadership", 1, "courses", opts("CIS 4000", "BE 4950")),
    wh("Managerial Economics", "wharton.fundamental", 1, "cu", opts("BEPP 2500", "BEPP 2508")),
    wh("Intro Business Stat II", "wharton.fundamental", 1, "cu", opts("STAT 1020", "STAT 4310", "ESE 4020")),
    wh("Global Economy", "wharton.flex", 1, "cu", attr("WUGE")),
    wh("Technology Innovation", "wharton.flex", 1, "cu", attr("WUTI")),
    wh("Humanities", "wharton.liberal", 1, "cu", attr("WUHM")),
    wh("Cross-Cultural", "wharton.crossCultural", 3, "cu", attr("WUCN", "WUCU")),
    wh("Foreign Language", "wharton.language", 1, "cu", attr("WUFL")),
    wh("Business Breadth", "wharton.breadth", 2, "cu",
      [{ kind: "subject", subjects: ["ACCT", "BEPP", "FNCE", "MKTG", "OIDD", "STAT", "LGST", "MGMT"] }],
      { constraints: { distinctSubjects: true, excludeSubjects: ["MGMT"], minNumber: 2000 } }),
    wh("General Management Electives", "wharton.concentration", 3, "cu",
      [{ kind: "range", subject: "MGMT", from: 1011, to: 4180 }]),
  ];
}

function degrees(): Degree[] {
  return [
    { id: "cs", label: CS, college: "EU", slots: csSlots(), applied: [] },
    { id: "wh", label: WH, college: "WU", slots: whSlots(), applied: [] },
  ];
}

/** The same two degrees with the CS one in the College, so Wharton has no
 *  engineering senior design project to stand in for its capstone. */
function collegeDegrees(): Degree[] {
  return degrees().map((d) => (d.id === "cs" ? { ...d, college: "AS" } : d));
}

function catalog(): CatalogSnapshot {
  const list: CatalogCourse[] = [
    course("CIS 1200", 1), course("CIS 1210", 1, [], "fs", "CIS 1200"),
    course("CIS 2400", 1, [], "fs", "CIS 1210"), course("CIS 2620", 1),
    course("CIS 3200", 1, [], "fs", "CIS 2400"),
    course("CIS 4000", 1, [], "f"), course("CIS 4010", 1, [], "s"),
    course("CIS 4500", 1, [], "f"), course("CIS 4510", 1, [], "s"),
    course("CIS 3310", 1), course("CIS 3320", 1),
    course("CIS 4100", 1, ["EUCU"]), course("CIS 4200", 1, ["EUCU"]),
    course("CIS 4300", 1, ["EUCU"]), course("CIS 4400", 1, ["EUCU"]),
    course("CIS 3333", 1),
    course("MATH 2400", 1), course("MATH 2600", 1),
    course("MATH 3140", 1, ["EUMA"]), course("PHYS 0150", 1, ["EUNS"]),
    course("PHIL 2620", 1), course("STSC 2000", 1),
    course("ACCT 1020", 1), course("OIDD 1010", 1), course("MGMT 3010", 1),
    // Wharton fundamentals, several carrying EUCU: the double counts.
    course("BEPP 2500", 1, ["EUCU"]), course("BEPP 2508", 1),
    course("STAT 1020", 1), course("STAT 4310", 1, ["EUCU"]), course("ESE 4020", 1),
    course("FNCE 2190", 1, ["WUGE", "EUCU"]), course("ECON 2300", 1, ["WUGE"]),
    course("OIDD 4770", 1, ["WUTI", "EUCU"]), course("STAT 4770", 1, ["WUTI"]),
    course("OIDD 4690", 1, ["EUCU"]), course("MKTG 2120", 1, ["EUCU"]),
    course("LGST 2100", 1), course("ACCT 2300", 1),
    course("BE 4950", 1),
    // liberal arts
    course("RELS 1000", 1, ["WUHM", "WUCN"]), course("HIST 1000", 1, ["WUHM"]),
    course("ANTH 1000", 1, ["WUCN"]), course("AFRC 1000", 1, ["WUCU"]),
    course("EALC 1000", 1, ["WUCN"]), course("SPAN 0100", 1, ["WUFL"]),
    // course with both flex attributes: still only one flex slot
    course("PSYC 2300", 1, ["WUGE", "WUTI"]),
    // MGMT range
    course("MGMT 2000", 1, ["WUGE"]), course("MGMT 3000", 1), course("MGMT 3100", 1),
    course("MGMT 3200", 1), course("MGMT 4000", 1),
  ];
  const courses: Record<string, CatalogCourse> = {};
  const attributeIndex: Record<string, string[]> = {};
  for (const c of list) {
    courses[c.code] = c;
    for (const a of c.attributes) (attributeIndex[a] ??= []).push(c.code);
  }
  return { courses, attributeIndex, cisTechElective: { "CIS 3333": "unrestricted" }, semesters: ["2026C", "2027A"] };
}

function request(over: Partial<PlanRequest> = {}): PlanRequest {
  return { degrees: degrees(), taken: [], history: {}, currentTerm: "202630", ...over };
}

// ---- helpers ---------------------------------------------------------------

function termOf(r: PlanResult, code: string): string | undefined {
  return r.schedule.find((t) => t.courses.some((c) => c.code === code))?.term;
}
function planned(r: PlanResult) {
  return r.schedule.flatMap((t) => t.courses);
}
function findCourse(r: PlanResult, code: string) {
  const c = planned(r).find((x) => x.code === code);
  assert.ok(c, `${code} is in the plan`);
  return c;
}
const filled = (r: PlanResult, code: string, label: string) =>
  findCourse(r, code).countsToward.some((x) => x.endsWith(`· ${label}`));

// ---- tests -----------------------------------------------------------------

Deno.test("planner: cross-degree double counts are found", () => {
  const r = plan(request(), catalog());
  // CIS 4000 fills senior project #1; the Wharton capstone is satisfied by the
  // engineering senior design project, so it is not a slot (Wharton's Senior
  // Capstone page, 2026-11-26).
  assert.ok(filled(r, "CIS 4000", "Senior Project #1"));
  assert.ok(!filled(r, "CIS 4000", "Senior Capstone"));
  // With the CS degree in the College the capstone is planned and shared.
  const r2 = plan(request({ degrees: collegeDegrees() }), catalog());
  assert.ok(filled(r2, "CIS 4000", "Senior Capstone"));
  // Each of the EUCU courses counts toward its Wharton slot and technical electives.
  let techShared = 0;
  for (const c of planned(r)) {
    if (c.countsToward.some((x) => x.endsWith("· Technical Electives")) &&
        c.countsToward.some((x) => x.startsWith("wharton"))) techShared++;
  }
  assert.equal(techShared, 4, "all four technical electives are shared with Wharton");
  assert.equal(r.unfilled.length, 0);
});

Deno.test("planner: overlap saves exactly the shared credits", () => {
  const r = plan(request(), catalog());
  // 36 cu of need; the humanities/cross-cultural sharing (-1) applies in both runs.
  assert.equal(r.remainingCredits, 30);
  // 35 before the capstone left the plan for a Wharton + Engineering student.
  assert.equal(r.remainingCreditsWithoutOverlap, 34);
  assert.equal(r.remainingCreditsWithoutOverlap - r.remainingCredits, 4);
  const sum = planned(r).reduce((t, c) => t + c.credits, 0);
  assert.equal(sum, r.remainingCredits);
});

Deno.test("planner: within-degree double counting only where policy allows", () => {
  const r = plan(request(), catalog());
  const slots = new Map<string, Slot>();
  for (const d of degrees()) for (const s of d.slots) slots.set(`${s.degreeLabel} · ${s.label}`, s);
  let humCross = 0;
  for (const c of planned(r)) {
    const byDegree = new Map<string, Slot[]>();
    for (const l of c.countsToward) {
      const s = slots.get(l)!;
      byDegree.set(s.degreeId, [...(byDegree.get(s.degreeId) ?? []), s]);
    }
    for (const list of byDegree.values()) {
      for (let i = 0; i < list.length; i++) {
        for (let j = i + 1; j < list.length; j++) {
          assert.ok(pennPolicy.withinDegree(list[i], list[j]), `${c.code}: ${list[i].label} + ${list[j].label}`);
          humCross++;
        }
      }
    }
  }
  assert.equal(humCross, 1, "one course counts for humanities and cross-cultural");
  // MGMT 3010 is leadership, so it cannot also be a management elective.
  assert.ok(!filled(r, "MGMT 3010", "General Management Electives"));
  // No course fills both flex slots.
  for (const c of planned(r)) {
    assert.ok(!(c.countsToward.includes("wharton · Global Economy") && c.countsToward.includes("wharton · Technology Innovation")));
  }
});

Deno.test("planner: within-degree policy rules", () => {
  const a = wh("a", "wharton.crossCultural", 1, "cu", []);
  const b = wh("b", "wharton.liberal", 1, "cu", []);
  const lang = wh("l", "wharton.language", 1, "cu", []);
  const flex = wh("f", "wharton.flex", 1, "cu", []);
  const conc = wh("c", "wharton.concentration", 1, "cu", []);
  assert.ok(pennPolicy.withinDegree(a, b) && pennPolicy.withinDegree(b, a));
  assert.ok(pennPolicy.withinDegree(lang, b));
  assert.ok(!pennPolicy.withinDegree(flex, conc));
  // Wharton refuses a petition for the flex fundamentals ("no petitions will
  // be considered", 2026-11-26), in either order.
  assert.ok(!pennPolicy.petitionPairs(flex, conc));
  assert.ok(!pennPolicy.petitionPairs(conc, flex));
  const m = cs("m", "seas.math", 1, "cu", []);
  const t = cs("t", "seas.techElective", 1, "cu", []);
  assert.ok(!pennPolicy.withinDegree(m, t));
  assert.ok(pennPolicy.petitionPairs(m, t));
  assert.ok(pennPolicy.sequences.immediatelyBefore(
    cs("Senior Project #1", "seas.core", 1, "cu", []), cs("Senior Project #2", "seas.core", 1, "cu", [])));
  assert.equal(pennPolicy.loads.summerPerTerm, 2);
  assert.equal(pennPolicy.loads.summerCeiling, 4);
  assert.equal((pennPolicy.loads as Record<string, unknown>)["max" + "SummerTotal"], undefined);
});

Deno.test("planner: scenario finish terms, standard vs approved", () => {
  const r = plan(request({ targetTerm: "202810" }), catalog());
  const get = (id: string) => r.scenarios.find((s) => s.id === id)!;
  const std = get("standard"), summer = get("summer"), appr = get("approved");
  assert.ok(std.finishTerm && summer.finishTerm && appr.finishTerm);
  assert.ok(std.finishTerm >= summer.finishTerm);
  assert.ok(summer.finishTerm >= appr.finishTerm);
  assert.ok(std.finishTerm > appr.finishTerm, "a higher load finishes sooner");
  // 30 cu cannot fit in spring 2027 through spring 2028 even at 6.5.
  assert.equal(appr.meetsTarget, false);
  // Changed on purpose: the "approved" 6.5 scenario needs an approval nobody
  // gave, so it is not drawn as the plan; the chosen finish is the earliest
  // among the scenarios that need none (standard, summer, fullSummer).
  const free = ["standard", "summer", "fullSummer"].map(get).map((s) => s.finishTerm!).sort()[0];
  assert.equal(r.scenarios.find((s) => s.id === r.chosen)!.finishTerm, free);
  assert.ok(r.notes.some((n) => n.includes("does not fit by spring 2028")));
  assert.equal(r.scenarios.find((s) => s.id === "student"), undefined);
});

// A lighter request (nine required cu waived) that can meet spring 2028.
function lightRequest(over: Partial<PlanRequest> = {}): PlanRequest {
  const waive = ["Core 1200", "Core 1210", "Core 2400", "Core 2620", "Core 3200", "Foreign Language", "Math Science Elective", "Calculus III", "General Management Electives"]
    .map((l) => `cs|b|${l}`)
    .concat(["wh|b|Foreign Language", "wh|b|General Management Electives"]);
  return request({ waive, targetTerm: "202810", ...over });
}

Deno.test("planner: a waived slot is skipped", () => {
  const r = plan(lightRequest(), catalog());
  assert.ok(!planned(r).some((c) => c.code === "CIS 1200"));
  assert.ok(!planned(r).some((c) => c.countsToward.some((x) => x.endsWith("· Foreign Language"))));
  assert.ok(!planned(r).some((c) => c.code === "SPAN 0100"));
});

Deno.test("planner: a lighter plan meets the target only at a higher load", () => {
  const r = plan(lightRequest(), catalog());
  const get = (id: string) => r.scenarios.find((s) => s.id === id)!;
  // Need after the waivers is under 21 cu, past 16.5 at the standard load.
  assert.equal(get("standard").meetsTarget, false);
  assert.ok(get("approved").finishTerm! <= get("summer").finishTerm!);
  const chosen = r.scenarios.find((s) => s.id === r.chosen)!;
  // Changed on purpose: "approved" (6.5, nobody granted it) is never the
  // plan; the scenario that needs no approval is, so test summer/fullSummer.
  if (get("summer").meetsTarget || get("fullSummer").meetsTarget) {
    assert.ok(chosen.meetsTarget);
    assert.notEqual(chosen.id, "standard");
    assert.notEqual(chosen.id, "approved");
  }
});

Deno.test("planner: a student's load is used when it meets the target", () => {
  const r = plan(lightRequest({ maxLoad: 7, allowSummer: true }), catalog());
  const stu = r.scenarios.find((s) => s.id === "student")!;
  assert.equal(stu.maxLoad, 7);
  if (stu.meetsTarget) assert.equal(r.chosen, "student");
  for (const t of r.schedule) {
    if (r.chosen === "student" && !t.term.endsWith("20")) assert.ok(t.credits <= 7 + 1e-9);
  }
});

Deno.test("planner: load caps are never exceeded", () => {
  for (const req of [request(), lightRequest()]) {
    const r = plan(req, catalog());
    const sc = r.scenarios.find((s) => s.id === r.chosen)!;
    for (const t of r.schedule) {
      if (t.term.endsWith("20")) {
        assert.ok(sc.summer);
        assert.ok(t.credits <= pennPolicy.loads.summerPerTerm + 1e-9);
      } else {
        assert.ok(t.credits <= sc.maxLoad + 1e-9, `${t.term} has ${t.credits}`);
      }
    }
  }
});

Deno.test("planner: senior project runs fall then the following spring", () => {
  const r = plan(request(), catalog());
  const a = termOf(r, "CIS 4000")!, b = termOf(r, "CIS 4010")!;
  assert.ok(a.endsWith("30"), "fall");
  assert.ok(b.endsWith("10"), "spring");
  assert.equal(b, `${parseInt(a.slice(0, 4), 10) + 1}10`);
  assert.ok(r.notes.some((n) => n.startsWith("CIS 4000 goes in fall") && n.includes("CIS 4010 in spring")));
});

Deno.test("planner: prerequisites among planned courses come first", () => {
  const r = plan(request(), catalog());
  const t = (c: string) => termOf(r, c)!;
  assert.ok(t("CIS 1200") < t("CIS 1210"));
  assert.ok(t("CIS 1210") < t("CIS 2400"));
  assert.ok(t("CIS 2400") < t("CIS 3200"));
});

Deno.test("planner: taken courses satisfy prerequisites and are not planned", () => {
  const r = plan(request({ taken: ["cis 1200", "CIS 1210"] }), catalog());
  assert.ok(!planned(r).some((c) => c.code === "CIS 1200" || c.code === "CIS 1210"));
  assert.ok(r.unfilled.some((u) => u.label === "Core 1200"), "its only option is taken");
  assert.equal(termOf(r, "CIS 2400")! >= "202710", true);
});

Deno.test("planner: capstone comes after fundamentals and leadership", () => {
  const r = plan(request({ degrees: collegeDegrees() }), catalog());
  const cap = termOf(r, "CIS 4000")!;
  for (const code of ["ACCT 1020", "OIDD 1010", "MGMT 3010", "BEPP 2500", "STAT 4310"]) {
    const t = termOf(r, code);
    if (t) assert.ok(t < cap, `${code} (${t}) before the capstone (${cap})`);
  }
  assert.ok(r.notes.some((n) => n.includes("before the Wharton capstone")));
});

Deno.test("planner: offered seasons are respected", () => {
  const r = plan(request(), catalog());
  const cat = catalog();
  for (const t of r.schedule) {
    const season = t.term.endsWith("10") ? "spring" : t.term.endsWith("20") ? "summer" : "fall";
    for (const c of t.courses) {
      const o = cat.courses[c.code]?.offered;
      if (o && (o.fall || o.spring || o.summer)) assert.ok(o[season], `${c.code} in ${t.term}`);
    }
  }
});

Deno.test("planner: courses without offering data are marked check", () => {
  const cat = catalog();
  cat.courses["MGMT 2000"] = course("MGMT 2000", 1, [], "");
  cat.courses["MGMT 3000"] = course("MGMT 3000", 1, [], "");
  cat.courses["MGMT 3100"] = course("MGMT 3100", 1, [], "");
  const r = plan(request({ prefer: ["MGMT 2000", "MGMT 3000", "MGMT 3100"] }), cat);
  const c = findCourse(r, "MGMT 2000");
  assert.equal(c.approval, "check");
  assert.ok(r.notes.some((n) => /no offering data/.test(n)));
});

Deno.test("planner: an explicit option missing from the catalogue is possible but unverified", () => {
  const cat = catalog();
  delete cat.courses["PHIL 2620"];
  delete cat.courses["STSC 2000"];
  const r = plan(request(), cat);
  const ethics = planned(r).find((c) => c.countsToward.some((x) => x.endsWith("· Ethics")))!;
  assert.equal(ethics.approval, "check");
  assert.equal(ethics.credits, 1);
});

Deno.test("planner: avoid and prefer are respected", () => {
  const r = plan(request({ avoid: ["BEPP 2500", "stat 4310"], prefer: ["PHIL 2620"] }), catalog());
  assert.ok(!planned(r).some((c) => c.code === "BEPP 2500" || c.code === "STAT 4310"));
  assert.ok(filled(r, "BEPP 2508", "Managerial Economics"));
  assert.ok(filled(r, "PHIL 2620", "Ethics"), "preferred option wins the tie");
  const plain = plan(request(), catalog());
  assert.ok(filled(plain, "STSC 2000", "Ethics"), "lower number wins an unpreferred tie");
});

Deno.test("planner: crosslisted codes are one course", () => {
  const cat = catalog();
  cat.courses["BEPP 2500"] = course("BEPP 2500", 1, ["EUCU"], "fs", undefined, ["REAL 2500"]);
  cat.courses["REAL 2500"] = course("REAL 2500", 1, ["EUCU"], "fs", undefined, ["BEPP 2500"]);
  const r = plan(request({ taken: ["REAL 2500"] }), cat);
  assert.ok(!planned(r).some((c) => c.code === "BEPP 2500" || c.code === "REAL 2500"));
  assert.ok(filled(r, "BEPP 2508", "Managerial Economics"));
});

Deno.test("planner: techElective EUCU also accepts unrestricted CIS list courses", () => {
  const cat = catalog();
  for (const c of ["CIS 4100", "CIS 4200", "CIS 4300", "CIS 4400"]) cat.courses[c] = course(c, 1);
  cat.attributeIndex["EUCU"] = ["BEPP 2500"];
  for (const c of Object.values(cat.courses)) c.attributes = c.attributes.filter((a) => a !== "EUCU");
  cat.courses["BEPP 2500"].attributes = ["EUCU"];
  cat.cisTechElective = { "CIS 4100": "unrestricted", "CIS 4200": "unrestricted", "CIS 4300": "unrestricted", "CIS 4400": "restricted" };
  const r = plan(request(), cat);
  const te = planned(r).filter((c) => c.countsToward.some((x) => x.endsWith("· Technical Electives")));
  assert.ok(te.some((c) => c.code === "CIS 4100"));
  assert.ok(!te.some((c) => c.code === "CIS 4400"));
});

Deno.test("planner: breadth constraints", () => {
  const r = plan(request(), catalog());
  const breadth = planned(r).filter((c) => c.countsToward.some((x) => x.endsWith("· Business Breadth")));
  const subjects = breadth.map((c) => c.code.split(" ")[0]);
  assert.equal(new Set(subjects).size, subjects.length, "distinct subjects");
  for (const c of breadth) {
    assert.notEqual(c.code.split(" ")[0], "MGMT");
    assert.ok(parseInt(c.code.split(" ")[1], 10) >= 2000);
  }
  const used = plan(request({
    degrees: degrees().map((d) => ({
      ...d,
      slots: d.slots.map((s) => s.label === "Business Breadth"
        ? { ...s, need: 1, constraints: { ...s.constraints, usedSubjects: ["OIDD", "MKTG", "STAT", "BEPP", "FNCE", "LGST"] } }
        : s),
    })),
  }), catalog());
  const only = planned(used).filter((c) => c.countsToward.some((x) => x.endsWith("· Business Breadth")));
  assert.deepEqual(only.map((c) => c.code), ["ACCT 2300"]);
});

Deno.test("planner: a slot with no eligible course is reported unfilled", () => {
  const degs = degrees();
  degs[1].slots.push(wh("Quantum Finance", "wharton.concentration", 1, "cu", opts("ZZZZ 9999")));
  degs[1].slots[degs[1].slots.length - 1].anyOf = attr("NOPE");
  const r = plan(request({ degrees: degs }), catalog());
  const u = r.unfilled.find((x) => x.label === "Quantum Finance")!;
  assert.ok(u);
  assert.equal(u.reason, "no eligible course found in Penn's catalogue");
  assert.equal(u.degreeLabel, WH);
});

Deno.test("planner: petitions report within-degree savings", () => {
  const r = plan(request(), catalog());
  // The flex + concentration pair is no longer a petition (Wharton refuses it),
  // so with Wharton sharing the technical electives nothing is offered here.
  assert.equal(r.petitions.length, 0);
  assert.ok(!r.petitions.some((p) => p.slots.some((x) => x.endsWith("Technology Innovation"))));
  for (const p of r.petitions) {
    assert.ok(p.savesCredits > 0);
    assert.equal(p.slots.length, 2);
    assert.ok(planned(r).every((c) => c.approval !== "petition"), "main plan never uses a petition");
  }
  // Math/science and technical electives is a seas petition pair. Technical
  // electives are only free when Wharton shares them, so strip that first.
  const cat = catalog();
  for (const code of ["BEPP 2500", "STAT 4310", "FNCE 2190", "OIDD 4770", "OIDD 4690", "MKTG 2120"]) {
    cat.courses[code].attributes = cat.courses[code].attributes.filter((a) => a !== "EUCU");
  }
  cat.attributeIndex["EUCU"] = ["CIS 4100", "CIS 4200", "CIS 4300", "CIS 4400", "MATH 3140"];
  cat.courses["MATH 3140"].attributes = ["EUMA", "EUCU"];
  const r2 = plan(request(), cat);
  const p = r2.petitions.find((x) => x.slots.some((s) => s.endsWith("Technical Electives")));
  assert.ok(p, "the seas pair shows up");
  assert.equal(p!.code, "MATH 3140");
  assert.equal(p!.savesCredits, 1);
});

Deno.test("planner: deterministic", () => {
  const a = JSON.stringify(plan(request({ targetTerm: "202810", maxLoad: 6 }), catalog()));
  const b = JSON.stringify(plan(request({ targetTerm: "202810", maxLoad: 6 }), catalog()));
  assert.equal(a, b);
});

function bigCatalog(): CatalogSnapshot {
  const cat = catalog();
  for (let i = 0; i < 3000; i++) {
    const code = `${["ABCD", "EFGH", "IJKL", "MNOP"][i % 4]} ${1000 + i}`;
    cat.courses[code] = course(code, 1, i % 50 === 0 ? ["EUCU"] : []);
  }
  return cat;
}

function withWildcards(n: number): Degree[] {
  const degs = degrees();
  for (let k = 0; k < n; k++) {
    const d = degs[k % 2];
    d.slots.push(slot(d.id, d.label, `Free ${k}`, "other", 1, "cu", [{ kind: "pattern", pattern: "@ @" }]));
  }
  return degs;
}

// 3,000 courses; 26 real slots plus wildcard "free elective" slots (4 is
// typical, 34 brings the slot count to 60 and is the stress case).
for (const [wild, budgetMs] of [[4, 1000], [34, 3000]] as const) {
  Deno.test(`planner: scale, 3,000 courses with ${wild} wildcard slots`, () => {
    const t0 = performance.now();
    const r = plan(request({ degrees: withWildcards(wild) }), bigCatalog());
    const ms = performance.now() - t0;
    console.log(`scale ${wild} wildcards: ${ms.toFixed(0)} ms`);
    assert.ok(ms < budgetMs, `${ms} ms`);
    // A course already chosen for one degree can also fill the other degree's
    // free slot, so wildcards cost between nothing and one course per pair.
    assert.ok(r.remainingCredits >= 30 && r.remainingCredits <= 30 + wild / 2, `${r.remainingCredits}`);
    assert.equal(r.unfilled.length, 0);
  });
}

// ---- loads above standard, language placement, nothing left ----------------

Deno.test("planner: loads above the standard are flagged for approval or permission", () => {
  const mid = plan(lightRequest({ maxLoad: 6 }), catalog());
  assert.equal(mid.chosen, "student");
  assert.ok(mid.notes.some((n) => n === "6 cu semesters need approval: Engineering's department can approve up to 1 cu above your previous semester (6.5 at most for dual-degree students), and Wharton needs a petition to its Petitions Committee"), mid.notes.join("|"));
  const high = plan(lightRequest({ maxLoad: 7 }), catalog());
  assert.ok(
    high.notes.some((n) => n === "7 cu a semester is above Penn's 6.5 cu limit for dual-degree students and needs special permission"),
    high.notes.join("|"),
  );
  const std = plan(request(), catalog());
  assert.equal(std.chosen, "standard");
  assert.ok(!std.notes.some((n) => n.includes("advisor's approval") || n.includes("special permission") || n.includes("need approval")));
});

Deno.test("policy: approvalNote names who approves", () => {
  const eng = "Engineering's department can approve up to 1 cu above your previous semester (6.5 at most for dual-degree students)";
  assert.equal(pennPolicy.loads.approvalNote(["EU", "WU"], 6), `6 cu semesters need approval: ${eng}, and Wharton needs a petition to its Petitions Committee`);
  assert.equal(pennPolicy.loads.approvalNote(["EU"], 6.5), `6.5 cu semesters need approval: ${eng}`);
  assert.equal(pennPolicy.loads.approvalNote(["WU"], 6), "6 cu semesters need a petition to Wharton's Petitions Committee");
  assert.equal(pennPolicy.loads.approvalNote(["AS", "WU2"], 6), "6 cu semesters need your advisor's approval");
});

Deno.test("planner: a language course from level 200 up assumes placement", () => {
  const cat = catalog();
  cat.courses["SPAN 0200"] = course("SPAN 0200", 1, ["WUFL"]);
  delete cat.courses["SPAN 0100"];
  cat.attributeIndex["WUFL"] = ["SPAN 0200"];
  const onlyLanguage = (taken: string[]) => request({
    waive: degrees().flatMap((d) => d.slots.map((x) => x.id)).filter((id) => id !== "wh|b|Foreign Language"),
    taken,
  });
  const r = plan(onlyLanguage([]), cat);
  const placed = r.schedule.flatMap((t) => t.courses.map((c) => c.code));
  assert.ok(placed.includes("SPAN 0200"));
  assert.ok(r.notes.some((n) => n.startsWith("SPAN 0200 assumes you place into it") && n.includes("SPAN 0100")));
  // Already in the subject: no note.
  const r2 = plan(onlyLanguage(["SPAN 0100"]), cat);
  assert.ok(!r2.notes.some((n) => n.includes("placement exam")));
});

Deno.test("planner: a plan with nothing left says so", () => {
  const r = plan(request({ degrees: [{ id: "cs", label: CS, college: "EU", slots: [], applied: [] }] }), catalog());
  assert.equal(r.schedule.length, 0);
  assert.ok(r.notes.includes("nothing is left to plan"));
});

// ---- area lists, graduate courses, empty labels, the best case -------------

const relabel = (from: string, to: string) => (d: Degree): Degree => ({
  ...d, slots: d.slots.map((s) => s.label === from ? { ...s, id: `${s.degreeId}|b|${to}`, label: to } : s),
});

Deno.test("planner: an area-list course also counts as a CIS elective, automatically", () => {
  const plain = plan(request(), catalog());
  const asArea = (r: PlanRequest): PlanRequest => ({
    ...r, degrees: r.degrees.map(relabel("Networking", "Area List - Networking"))
      .map(relabel("CIS Electives", "CIS Elective at the 2000 Level or Above")),
  });
  const r = plan(asArea(request()), catalog());
  assert.equal(r.remainingCredits, plain.remainingCredits - 1);
  const both = planned(r).filter((c) =>
    c.countsToward.some((x) => x.endsWith("· Area List - Networking")) &&
    c.countsToward.some((x) => x.endsWith("· CIS Elective at the 2000 Level or Above")));
  assert.equal(both.length, 1);
  assert.equal(both[0].approval, "automatic");
  // It is the curriculum's rule, so not a petition, and not for other pairs.
  assert.ok(!r.petitions.some((p) => p.slots.some((s) => s.endsWith("Area List - Networking"))));
  const [a, e] = [asArea(request()).degrees[0].slots, 0];
  const net = a.find((s) => s.label.startsWith("Area List"))!;
  const el = a.find((s) => s.label.startsWith("CIS Elective"))!;
  const tech = a.find((s) => s.label === "Technical Electives")!;
  assert.equal(pennPolicy.withinDegree(net, el), true);
  assert.equal(pennPolicy.withinDegree(el, net), true);
  assert.equal(pennPolicy.withinDegree(net, tech), false);
  assert.equal(pennPolicy.withinDegree(el, tech), false);
  void e;
});

Deno.test("planner: graduate courses only through an explicit option", () => {
  const cat = catalog();
  cat.courses["FNCE 7210"] = course("FNCE 7210", 1, ["WUGE", "EUCU"]);
  cat.attributeIndex["WUGE"].push("FNCE 7210");
  cat.attributeIndex["EUCU"].push("FNCE 7210");
  cat.courses["MGMT 6000"] = course("MGMT 6000", 1);
  const r = plan(request(), cat);
  const codes = planned(r).map((c) => c.code);
  assert.ok(!codes.includes("FNCE 7210") && !codes.includes("MGMT 6000"), codes.join(","));
  // Named by Penn for the requirement: allowed. 5000-level too.
  cat.courses["CIS 5000"] = course("CIS 5000", 1, ["EUCU"]);
  cat.attributeIndex["EUCU"].push("CIS 5000");
  const named = request({ degrees: [{ id: "wh", label: WH, college: "WU", applied: [], slots: [
    wh("Only Grad", "wharton.flex", 1, "cu", opts("FNCE 7210")),
  ] }] });
  assert.deepEqual(planned(plan(named, cat)).map((c) => c.code), ["FNCE 7210"]);
  const byAttr = request({ degrees: [{ id: "wh", label: WH, college: "WU", applied: [], slots: [
    wh("By attribute", "wharton.flex", 1, "cu", attr("WUGE")),
  ] }] });
  assert.ok(!planned(plan(byAttr, cat)).some((c) => c.code === "FNCE 7210"));
  const five = request({ degrees: [{ id: "cs", label: CS, college: "EU", applied: [], slots: [
    cs("Five", "seas.core", 1, "courses", [{ kind: "range", subject: "CIS", from: 5000, to: 5999 }]),
  ] }] });
  assert.deepEqual(planned(plan(five, cat)).map((c) => c.code), ["CIS 5000"]);
});

Deno.test("planner: an unfilled item always has a label", () => {
  const empty = wh("", "wharton.concentration", 1, "cu", opts("NOPE 1234"), { blockTitle: "Finance Concentration" });
  const r = plan(request({ degrees: [{ id: "wh", label: WH, college: "WU", applied: [], slots: [
    { ...empty, anyOf: [{ kind: "attribute", codes: ["ZZZZ"] }] },
    { ...empty, id: "wh|b|2", blockTitle: " ", anyOf: [{ kind: "attribute", codes: ["ZZZZ"] }] },
  ] }] }), catalog());
  assert.deepEqual(r.unfilled.map((u) => u.label), ["Finance Concentration", "a requirement"]);
});

Deno.test("planner: best is always reported, never preferred when an ordinary scenario fits", () => {
  const r = plan(request({ targetTerm: "209910" }), catalog());
  const best = r.scenarios.find((s) => s.id === "best")!;
  assert.ok(best);
  assert.equal(best.maxLoad, 6.5);
  assert.equal(best.label, "6.5 cu, summers at up to 4 cu, your advisor's approvals and the language placement exam");
  assert.equal(r.chosen, "standard");
  const noSummer = plan(request({ allowSummer: false }), catalog()).scenarios.find((s) => s.id === "best")!;
  assert.equal(noSummer.summer, false);
  assert.equal(noSummer.label, "6.5 cu, your advisor's approvals and the language placement exam");
  assert.ok(!r.notes.some((n) => n.startsWith("best case")));
});

Deno.test("planner: best is picked when the ordinary scenarios miss the target", () => {
  // Fixture: 8 cu of 1-cu single-option courses can't fit one 5.5 semester
  // plus no summer, but a 6.5 load with the petition pair and the language
  // waiver needs only 6.
  const cat = catalog();
  const cs0: Slot[] = [];
  const mk = (n: string, code: string) => wh(n, "wharton.fundamental", 1, "cu", opts(code));
  const slotsW: Slot[] = [
    mk("A", "ACCT 1020"), mk("B", "OIDD 1010"), mk("C", "MGMT 3010"), mk("D", "BEPP 2500"), mk("E", "ACCT 2300"),
    wh("Foreign Language", "wharton.language", 1, "cu", attr("WUFL")),
  ];
  void cs0;
  const req: PlanRequest = request({
    // The petition pair is Engineering's: math with a technical elective.
    // (The Wharton flex + concentration pair used to be the example; Wharton
    // refuses it, so it is no longer a petition.)
    degrees: [
      { id: "wh", label: WH, college: "WU", applied: [], slots: slotsW },
      { id: "cs", label: CS, college: "EU", applied: [], slots: [
        cs("Math Science Elective", "seas.math", 1, "cu", opts("MATH 3140")),
        cs("Technical Electives", "seas.techElective", 1, "cu", opts("MATH 3140")),
      ] },
    ],
    targetTerm: "202710", allowSummer: false, assumeApprovals: true,
  });
  const r = plan(req, cat);
  // Changed on purpose: best is chosen only when the student asks for it.
  assert.notEqual(plan({ ...req, assumeApprovals: undefined }, cat).chosen, "best");
  // ordinary: 5 + OIDD 4770 + (concentration also needs 4770: same course can't) -> 6 courses + SPAN = 7 > 5.5, 6.5
  assert.equal(r.scenarios.find((s) => s.id === "standard")!.meetsTarget, false);
  assert.equal(r.scenarios.find((s) => s.id === "approved")!.meetsTarget, false);
  const best = r.scenarios.find((s) => s.id === "best")!;
  assert.equal(best.meetsTarget, true, JSON.stringify(r.scenarios));
  assert.equal(r.chosen, "best");
  const oidd = findCourse(r, "MATH 3140");
  assert.equal(oidd.approval, "petition");
  assert.equal(oidd.countsToward.length, 2);
  assert.ok(!planned(r).some((c) => c.code === "SPAN 0100"), "language is waived");
  assert.ok(r.unfilled.every((u) => u.label !== "Foreign Language"));
  const note = r.notes.find((n) => n.startsWith("best case assumes"))!;
  assert.ok(note, r.notes.join("|"));
  assert.ok(note.includes("6.5 cu semesters"));
  assert.ok(note.includes("MATH 3140"));
  assert.ok(note.includes("placement exam"));
  // A language already studied is not waived.
  const r2 = plan({ ...req, taken: ["SPAN 0050"] }, (() => { const c = catalog(); c.courses["SPAN 0050"] = course("SPAN 0050", 1, ["WUFL"]); c.attributeIndex["WUFL"].push("SPAN 0050"); return c; })());
  assert.ok(!r2.notes.some((n) => n.includes("placement exam")));
  // When nothing meets the target, best is not chosen.
  const none = plan({ ...req, targetTerm: "202630", assumeApprovals: undefined }, cat);
  assert.notEqual(none.chosen, "best");
});

// ---- summer, capstone, floor (Penn's pages read 2026-11-26) -----------------

function summerOnlyCatalog(n: number): { cat: CatalogSnapshot; slots: Slot[] } {
  const cat = catalog();
  const slots: Slot[] = [];
  for (let i = 0; i < n; i++) {
    const code = `SUMR ${1000 + i}`;
    cat.courses[code] = course(code, 1, [], "u");
    slots.push(wh(`S${i}`, "wharton.fundamental", 1, "cu", opts(code)));
  }
  return { cat, slots };
}

Deno.test("planner: ordinary scenarios stay at 2 cu a summer, best reaches 4, and nothing caps the total", () => {
  const { cat, slots } = summerOnlyCatalog(10);
  const degs: Degree[] = [{ id: "wh", label: WH, college: "WU", applied: [], slots }];
  const summers = (r: PlanResult) => r.schedule.filter((t) => t.term.endsWith("20")).map((t) => t.credits);
  // 10 summer-only cu by summer 2029: only best's 4-cu summers fit (4+4+2).
  // Changed on purpose: a 4 cu summer is Penn's own limit, so it is the
  // ordinary "fullSummer" scenario now and needs no approval to be chosen.
  const hard = plan(request({ degrees: degs, targetTerm: "202920" }), cat);
  assert.equal(hard.chosen, "fullSummer");
  assert.deepEqual(hard.approvals, []);
  const bs = summers(hard);
  assert.ok(bs.length >= 3 && bs.every((c) => c <= 4 + 1e-9));
  assert.ok(bs.some((c) => c > 2), "best uses more than the cautious 2 cu");
  assert.ok(bs.reduce((a, b) => a + b, 0) > 4, "no cap across summers");
  for (const id of ["standard", "summer", "approved"]) {
    assert.equal(hard.scenarios.find((s) => s.id === id)!.meetsTarget, false, id);
  }
  // With no target an ordinary scenario is chosen and keeps to 2 cu a summer.
  const six = summerOnlyCatalog(6);
  const easy = plan(request({ degrees: [{ id: "wh", label: WH, college: "WU", applied: [], slots: six.slots }], targetTerm: "209910" }), six.cat);
  assert.notEqual(easy.chosen, "best");
  assert.ok(summers(easy).length > 2, "more than two summers are used");
  assert.ok(summers(easy).every((c) => c <= 2 + 1e-9));
  assert.ok(summers(easy).reduce((a, b) => a + b, 0) > 4, "the old 4-in-all cap is gone");
  // Changed on purpose: the 4 cu summer is no longer a best-case assumption
  // (there is no "best case assumes" note when an ordinary scenario fits); it
  // is the fullSummer scenario's own label, and it names no approval.
  assert.equal(hard.scenarios.find((s) => s.id === "fullSummer")!.label, "5.5 cu a semester, summers at up to 4 cu");
  assert.ok(!hard.notes.some((n) => n.startsWith("best case assumes")));
});

Deno.test("planner: a Wharton + Engineering student does not plan the capstone", () => {
  const r = plan(request(), catalog());
  assert.ok(!planned(r).some((c) => c.countsToward.some((x) => x.endsWith("· Senior Capstone"))));
  assert.ok(!r.unfilled.some((u) => /capstone/i.test(u.label)));
  const note = "Wharton counts your engineering senior design project as its senior capstone; if your audit still shows the capstone open, ask your Wharton advisor to record it";
  assert.ok(r.notes.includes(note));
  // Every scenario, best included: ask for a target only best can meet.
  const best = plan(request({ targetTerm: "202710" }), catalog());
  assert.ok(best.notes.includes(note));
  assert.ok(!planned(best).some((c) => c.countsToward.some((x) => x.endsWith("· Senior Capstone"))));
  // Wharton + College, and Wharton alone, still plan it after the fundamentals.
  for (const degs of [collegeDegrees(), [degrees()[1]]]) {
    const r2 = plan(request({ degrees: degs }), catalog());
    assert.ok(!r2.notes.includes(note));
    assert.ok(planned(r2).some((c) => c.countsToward.some((x) => x.endsWith("· Senior Capstone"))));
    const cap = termOf(r2, planned(r2).find((c) => c.countsToward.some((x) => x.endsWith("· Senior Capstone")))!.code)!;
    for (const code of ["ACCT 1020", "OIDD 1010", "MGMT 3010"]) {
      const t = termOf(r2, code);
      if (t) assert.ok(t < cap, `${code} before the capstone`);
    }
    assert.ok(r2.notes.some((n) => n.includes("before the Wharton capstone")));
  }
});

Deno.test("policy: senior design satisfies the capstone only for Wharton + Engineering", () => {
  const capstone = wh("Senior Capstone", "wharton.leadership", 1, "courses", []);
  const other = wh("Humanities", "wharton.liberal", 1, "cu", []);
  const [eu, wu] = degrees();
  const rule = pennPolicy.capstoneRule;
  assert.ok(rule.satisfiedBySeniorDesign(capstone, [eu, wu]));
  assert.ok(!rule.satisfiedBySeniorDesign(other, [eu, wu]));
  assert.ok(!rule.satisfiedBySeniorDesign(capstone, [{ ...eu, college: "AS" }, wu]));
  assert.ok(!rule.satisfiedBySeniorDesign(capstone, [wu]));
});

Deno.test("planner: the 46 cu floor for a dual degree with Engineering", () => {
  const withSoFar = (n: number | undefined, degs = degrees()): Degree[] =>
    degs.map((d, i) => (i === 0 && n !== undefined ? { ...d, creditsSoFar: n } : d));
  const base = plan(request(), catalog());
  const chosen = base.remainingCredits;
  const short = 46 - 5 - chosen;
  assert.ok(short > 0);
  const r = plan(request({ degrees: withSoFar(5) }), catalog());
  const row = r.unfilled.find((u) => u.slotId === "policy|totalFloor")!;
  assert.ok(row, JSON.stringify(r.unfilled));
  assert.equal(row.degreeLabel, "both degrees");
  assert.equal(row.label, "46 cu minimum");
  assert.equal(row.reason, `${short} more cu of any courses are needed: a dual degree with Engineering needs at least 46 cu`);
  assert.ok(r.notes.includes(`the plan ends at ${5 + chosen} cu; a dual degree with Engineering needs at least 46 cu, so ${short} more cu of any courses are needed`), r.notes.join("|"));
  // Enough already, nothing known, or one degree: no row.
  const none = (req: PlanRequest) => !plan(req, catalog()).unfilled.some((u) => u.slotId === "policy|totalFloor");
  assert.ok(none(request({ degrees: withSoFar(40) })));
  assert.ok(none(request({ degrees: withSoFar(46 - chosen) })));
  assert.ok(none(request({ degrees: withSoFar(undefined) })));
  assert.ok(none(request({ degrees: [{ ...degrees()[0], creditsSoFar: 5 }] })));
  assert.equal(pennPolicy.totalFloor(collegeDegrees().slice(1)), null);
  assert.equal(pennPolicy.totalFloor([{ ...degrees()[1] }, { ...degrees()[1], id: "x" }]), null);
  assert.deepEqual(pennPolicy.totalFloor(degrees()), { cu: 46, reason: "a dual degree with Engineering needs at least 46 cu" });
});
