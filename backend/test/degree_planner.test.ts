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
    id: `${degreeId}|b|${label}`, degreeId, degreeLabel, label, blockTitle: "b",
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
  // CIS 4000 fills senior project #1 and the Wharton capstone together.
  assert.ok(filled(r, "CIS 4000", "Senior Project #1"));
  assert.ok(filled(r, "CIS 4000", "Senior Capstone"));
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
  assert.equal(r.remainingCreditsWithoutOverlap, 35);
  assert.equal(r.remainingCreditsWithoutOverlap - r.remainingCredits, 5);
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
  assert.ok(pennPolicy.petitionPairs(flex, conc));
  const m = cs("m", "seas.math", 1, "cu", []);
  const t = cs("t", "seas.techElective", 1, "cu", []);
  assert.ok(!pennPolicy.withinDegree(m, t));
  assert.ok(pennPolicy.petitionPairs(m, t));
  assert.ok(pennPolicy.sequences.immediatelyBefore(
    cs("Senior Project #1", "seas.core", 1, "cu", []), cs("Senior Project #2", "seas.core", 1, "cu", [])));
  assert.equal(pennPolicy.loads.maxSummerTotal, 4);
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
  assert.equal(r.scenarios.find((s) => s.id === r.chosen)!.finishTerm, appr.finishTerm);
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
  if (get("summer").meetsTarget || get("approved").meetsTarget) {
    assert.ok(chosen.meetsTarget);
    assert.notEqual(chosen.id, "standard");
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
    let summerTotal = 0;
    for (const t of r.schedule) {
      if (t.term.endsWith("20")) {
        assert.ok(sc.summer);
        assert.ok(t.credits <= pennPolicy.loads.summerPerTerm + 1e-9);
        summerTotal += t.credits;
      } else {
        assert.ok(t.credits <= sc.maxLoad + 1e-9, `${t.term} has ${t.credits}`);
      }
    }
    assert.ok(summerTotal <= pennPolicy.loads.maxSummerTotal + 1e-9);
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
  const r = plan(request(), catalog());
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
  assert.ok(r.petitions.length > 0);
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
