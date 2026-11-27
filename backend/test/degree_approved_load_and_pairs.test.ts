// An approved load is a fact, not an approval still to get; senior project
// halves are a matching pair; the plan drawn never rests on approvals nobody
// granted; advisor questions go out and recorded answers come back in.
// Fixtures are synthetic and local (the planner tests' builders are private).
import { strict as assert } from "node:assert";
import { plan, termLabel } from "../supabase/functions/_shared/degreePlanner/planner.ts";
import { isSequencePair } from "../supabase/functions/_shared/degreePlanner/policy.ts";
import { parseDegreeAdvisorBody, readDegreeIntent } from "../supabase/functions/_shared/degreeAdvisor.ts";
import type {
  CatalogCourse, CatalogSnapshot, Degree, Eligibility, PlanRequest, PlanResult, Slot, SlotGroup,
} from "../supabase/functions/_shared/degreePlanner/types.ts";

function course(code: string, credits = 1, attrs: string[] = [], offered = "fs"): CatalogCourse {
  return {
    code, title: `${code} title`, credits, attributes: attrs,
    offered: { fall: offered.includes("f"), spring: offered.includes("s"), summer: offered.includes("u") },
  };
}
const opts = (...codes: string[]): Eligibility[] => [{ kind: "courses", codes }];
const attr = (...codes: string[]): Eligibility[] => [{ kind: "attribute", codes }];
function slot(degreeId: string, degreeLabel: string, label: string, group: SlotGroup, anyOf: Eligibility[], need = 1): Slot {
  return {
    id: `${degreeId}|b|${label}`, degreeId, degreeLabel, label, blockTitle: "b", blockId: "b", blockType: "OTHER",
    need, unit: "cu", anyOf, exclude: [], group,
  };
}
function cat(list: CatalogCourse[]): CatalogSnapshot {
  const courses: Record<string, CatalogCourse> = {};
  const attributeIndex: Record<string, string[]> = {};
  for (const c of list) {
    courses[c.code] = c;
    for (const a of c.attributes) (attributeIndex[a] ??= []).push(c.code);
  }
  return { courses, attributeIndex, cisTechElective: {}, semesters: ["2026C", "2027A", "2026B"] };
}
const req = (degrees: Degree[], over: Partial<PlanRequest> = {}): PlanRequest =>
  ({ degrees, taken: [], history: {}, currentTerm: "202630", ...over });
const planned = (r: PlanResult) => r.schedule.flatMap((t) => t.courses);
const chosen = (r: PlanResult) => r.scenarios.find((s) => s.id === r.chosen)!;

// ---- the pair rule -----------------------------------------------------------

Deno.test("isSequencePair: second is first plus 10 in the same subject", () => {
  assert.equal(isSequencePair("CIS 4000", "CIS 4010"), true);
  assert.equal(isSequencePair("CIS 4100", "CIS 4010"), false);
  assert.equal(isSequencePair("CIS 4100", "CIS 4110"), true);
  assert.equal(isSequencePair("CIS 4000", "ESE 4010"), false);
  assert.equal(isSequencePair("nonsense", "CIS 4010"), false);
});

const csDeg = (slots: Slot[]): Degree[] => [{ id: "cs", label: "computer science", college: "EU", slots, applied: [] }];
const sp1 = (o: string[]) => slot("cs", "computer science", "Senior Project #1", "seas.core", opts(...o));
const sp2 = (o: string[]) => slot("cs", "computer science", "Senior Project #2", "seas.core", opts(...o));

Deno.test("senior project halves are chosen as a matching pair", () => {
  // Without the rule the greedy tie-break prefers the course offered in both
  // seasons for each slot: CIS 4100 and CIS 4010, a mismatched pair.
  const c = cat([course("CIS 4000", 1, [], "f"), course("CIS 4100", 1, [], "fs"), course("CIS 4010", 1, [], "fs"), course("CIS 4110", 1, [], "f")]);
  const r = plan(req(csDeg([sp1(["CIS 4000", "CIS 4100"]), sp2(["CIS 4010", "CIS 4110"])])), c);
  const codes = planned(r).map((x) => x.code).sort();
  assert.deepEqual(codes, ["CIS 4000", "CIS 4010"]);
  assert.ok(!r.notes.some((n) => n.startsWith("check with your department")));
});

Deno.test("no matching pair in the options: the choice stays and a note says to check", () => {
  const c = cat([course("CIS 4100", 1, [], "f"), course("CIS 4010", 1, [], "s")]);
  const r = plan(req(csDeg([sp1(["CIS 4100"]), sp2(["CIS 4010"])])), c);
  assert.deepEqual(planned(r).map((x) => x.code).sort(), ["CIS 4010", "CIS 4100"]);
  assert.ok(r.notes.some((n) => n.startsWith("check with your department that CIS 4100 and CIS 4010 are the two halves")), r.notes.join("|"));
});

Deno.test("a first half already taken: the open second half pairs with it", () => {
  const c = cat([course("CIS 4110", 1, [], "fs"), course("CIS 4010", 1, [], "f")]);
  const r = plan(req(csDeg([sp2(["CIS 4110", "CIS 4010"])]), { taken: ["CIS 4000"] }), c);
  assert.deepEqual(planned(r).map((x) => x.code), ["CIS 4010"]);
});

// ---- petitions, approvals, the best case ---------------------------------------

function petitionFixture(): { degrees: Degree[]; catalog: CatalogSnapshot } {
  const wh = (l: string, code: string) => slot("wh", "wharton", l, "wharton.fundamental", opts(code));
  return {
    degrees: [
      { id: "wh", label: "wharton", college: "WU", applied: [], slots: [
        wh("A", "ACCT 1020"), wh("B", "OIDD 1010"), wh("C", "MGMT 3010"), wh("D", "BEPP 2500"), wh("E", "ACCT 2300"),
        slot("wh", "wharton", "Foreign Language", "wharton.language", attr("WUFL")),
      ] },
      { id: "cs", label: "computer science", college: "EU", applied: [], slots: [
        slot("cs", "computer science", "Math Science Elective", "seas.math", opts("MATH 3140")),
        slot("cs", "computer science", "Technical Electives", "seas.techElective", opts("MATH 3140")),
      ] },
    ],
    catalog: cat([
      course("ACCT 1020"), course("OIDD 1010"), course("MGMT 3010"), course("BEPP 2500"), course("ACCT 2300"),
      course("MATH 3140"), course("SPAN 0100", 1, ["WUFL"]),
    ]),
  };
}
const PID = "doubleCount:cs:MATH 3140:cs|b|Math Science Elective+cs|b|Technical Electives";

Deno.test("best case needed for the target is reported, not drawn", () => {
  const f = petitionFixture();
  const r = plan(req(f.degrees, { targetTerm: "202710", allowSummer: false }), f.catalog);
  assert.notEqual(r.chosen, "best");
  assert.ok(planned(r).every((c) => c.approval !== "petition"), "no petition pair in the schedule");
  assert.ok(planned(r).some((c) => c.code === "SPAN 0100"), "language is not waived");
  assert.ok(r.bestCase && r.bestCase.approvals.length > 0, JSON.stringify(r.bestCase));
  assert.ok(r.bestCase!.approvals.some((a) => a.startsWith("MATH 3140 counted for both")));
  assert.ok(r.bestCase!.approvals.some((a) => /placement exam/.test(a)));
  assert.ok(r.notes.some((n) => n.startsWith(`${termLabel("202710")} is reachable only if:`) && n.includes("Say \"assume the approvals\"")), r.notes.join("|"));
  assert.deepEqual(r.approvals.filter((a) => /MATH 3140|placement/.test(a)), []);
});

Deno.test("assumeApprovals draws the best case and lists what it needs", () => {
  const f = petitionFixture();
  const r = plan(req(f.degrees, { targetTerm: "202710", allowSummer: false, assumeApprovals: true }), f.catalog);
  assert.equal(r.chosen, "best");
  assert.ok(r.approvals.length >= 2, r.approvals.join("|"));
  for (const c of planned(r).filter((x) => x.approval === "petition")) {
    assert.ok(r.approvals.some((a) => a.startsWith(`${c.code} counted for both`)), c.code);
  }
  assert.ok(r.approvals.every((a) => a.length <= 80) && r.approvals.length <= 8);
  assert.equal(r.bestCase, undefined);
});

Deno.test("a plan that needs nothing has no approvals", () => {
  const f = petitionFixture();
  const r = plan(req(f.degrees), f.catalog);
  assert.equal(r.chosen, "standard");
  assert.deepEqual(r.approvals, []);
});

function summerFixture(n: number) {
  const list: CatalogCourse[] = [];
  const slots: Slot[] = [];
  for (let i = 0; i < n; i++) {
    const code = `SUMR ${1000 + i}`;
    list.push(course(code, 1, [], "u"));
    slots.push(slot("wh", "wharton", `S${i}`, "wharton.fundamental", opts(code)));
  }
  return { degrees: [{ id: "wh", label: "wharton", college: "WU", applied: [], slots } as Degree], catalog: cat(list) };
}

Deno.test("fullSummer: 4 cu summers with no approval", () => {
  const f = summerFixture(10);
  const r = plan(req(f.degrees, { targetTerm: "202920" }), f.catalog);
  assert.equal(r.chosen, "fullSummer");
  assert.deepEqual(r.approvals, []);
  assert.equal(chosen(r).label, "5.5 cu a semester, summers at up to 4 cu");
  const summers = r.schedule.filter((t) => t.term.endsWith("20")).map((t) => t.credits);
  assert.ok(summers.some((c) => c > 2) && summers.every((c) => c <= 4 + 1e-9));
  assert.ok(r.notes.some((n) => /^summer courses are placed from Penn's summer 2026 listing; check summer 20\d\d's when it is published$/.test(n)), r.notes.join("|"));
});

// ---- an approved load is a fact --------------------------------------------------

function loadFixture() {
  const list: CatalogCourse[] = [];
  const slots: Slot[] = [];
  for (let i = 0; i < 12; i++) {
    const code = `LOAD ${1000 + i}`;
    list.push(course(code));
    slots.push(slot("wh", "wharton", `L${i}`, "wharton.fundamental", opts(code)));
  }
  return { degrees: [{ id: "wh", label: "wharton", college: "WU", applied: [], slots } as Degree], catalog: cat(list) };
}
const NEEDS = /\bneeds? (an? )?(approval|permission|petition)|which need/i;

Deno.test("loadApproved: no note, label or approval calls 6.5 an approval; the fact is noted", () => {
  const f = loadFixture();
  const r = plan(req(f.degrees, { targetTerm: "202730", allowSummer: false, maxLoad: 6.5, loadApproved: true }), f.catalog);
  assert.equal(r.chosen, "student");
  for (const text of [...r.notes, ...r.approvals, ...r.scenarios.map((s) => s.label)]) assert.ok(!NEEDS.test(text), text);
  assert.ok(r.notes.includes("you said you are approved for 6.5 cu a semester"));
  assert.deepEqual(r.approvals, []);
});

Deno.test("without loadApproved the same load is listed as needing approval", () => {
  const f = loadFixture();
  const r = plan(req(f.degrees, { targetTerm: "202730", allowSummer: false, maxLoad: 6.5 }), f.catalog);
  assert.equal(r.chosen, "student");
  assert.ok(r.approvals.some((a) => /^6\.5 cu semesters need/.test(a)), r.approvals.join("|"));
});

Deno.test("intent reader: loadApproved and assumeApprovals are true or null, junk is null", () => {
  const body = parseDegreeAdvisorBody({
    question: "q", history: [], context: "c", terms: [{ code: "202730", label: "Fall 2027" }], addable: [], now: "2026-11-14T12:00:00Z",
  })!;
  const read = (o: Record<string, unknown>) => readDegreeIntent(JSON.stringify({ intent: "plan", ...o }), body).params;
  assert.equal(read({ loadApproved: true }).loadApproved, true);
  assert.equal(read({ loadApproved: false }).loadApproved, null);
  assert.equal(read({ loadApproved: null }).loadApproved, null);
  assert.equal(read({ loadApproved: "yes" }).loadApproved, null);
  assert.equal(read({ assumeApprovals: true }).assumeApprovals, true);
  assert.equal(read({ assumeApprovals: 1 }).assumeApprovals, null);
});

// ---- advisor questions and answers ---------------------------------------------------

Deno.test("advisor questions: one of each kind, readable, with stable ids", () => {
  const f = petitionFixture();
  const a = plan(req(f.degrees, { targetTerm: "202710", allowSummer: false }), f.catalog);
  const b = plan(req(f.degrees, { targetTerm: "202710", allowSummer: false }), f.catalog);
  assert.deepEqual(a.advisorQuestions.map((q) => q.id), b.advisorQuestions.map((q) => q.id));
  const kinds = a.advisorQuestions.map((q) => q.kind);
  assert.ok(kinds.includes("doubleCount") && kinds.includes("placement"), kinds.join());
  for (const q of a.advisorQuestions) {
    assert.ok(q.question.endsWith("?") && q.question.length <= 220 && q.detail.length <= 140 && q.id.length <= 200);
    assert.ok(!q.question.includes("|") && !q.question.includes(q.id), q.question);
    assert.equal(q.answer, null);
  }
  const dc = a.advisorQuestions.find((q) => q.kind === "doubleCount")!;
  assert.equal(dc.id, PID);
  assert.equal(dc.question, "Can MATH 3140 count toward both Math Science Elective and Technical Electives in my computer science degree?");
  assert.equal(dc.detail, "lets one course fill both");
  const pl = a.advisorQuestions.find((q) => q.kind === "placement")!;
  assert.equal(pl.id, "placement:language:wh");
});

Deno.test("a load question appears when 6.5 would finish sooner, with who decides", () => {
  const f = loadFixture();
  const r = plan(req(f.degrees, { targetTerm: "202730", allowSummer: false }), f.catalog);
  const q = r.advisorQuestions.find((x) => x.kind === "load")!;
  assert.equal(q.id, "load:6.5");
  assert.equal(q.question, "Can I get approval to take 6.5 cu a semester, which Wharton's Petitions Committee decides?");
  assert.equal(q.detail, "lets you take 6.5 cu a semester");
});

Deno.test("a yes on a double count grants it to the ordinary plan", () => {
  const f = petitionFixture();
  const r = plan(req(f.degrees, { targetTerm: "202730", allowSummer: false, advisorAnswers: [{ id: PID, answer: "yes" }] }), f.catalog);
  const m = planned(r).find((c) => c.code === "MATH 3140")!;
  assert.equal(m.countsToward.length, 2);
  assert.equal(m.approval, "automatic");
  assert.ok(!r.approvals.some((a) => a.includes("MATH 3140")));
  assert.ok(r.notes.includes("your advisor approved MATH 3140 for both Math Science Elective and Technical Electives"));
  assert.equal(r.advisorQuestions.find((q) => q.id === PID)!.answer, "yes");
  assert.ok(!r.petitions.some((p) => p.code === "MATH 3140"));
});

Deno.test("a no on a double count removes it from the best case and keeps the question", () => {
  const f = petitionFixture();
  const r = plan(req(f.degrees, { targetTerm: "202710", allowSummer: false, assumeApprovals: true, advisorAnswers: [{ id: PID, answer: "no" }] }), f.catalog);
  assert.ok(planned(r).every((c) => c.countsToward.length < 2 || c.code !== "MATH 3140"));
  assert.ok(!r.approvals.some((a) => a.includes("MATH 3140")));
  assert.ok(!(r.bestCase?.approvals ?? []).some((a) => a.includes("MATH 3140")));
  assert.equal(r.advisorQuestions.find((q) => q.id === PID)!.answer, "no");
  const noAssume = plan(req(f.degrees, { targetTerm: "202710", allowSummer: false, advisorAnswers: [{ id: PID, answer: "no" }] }), f.catalog);
  assert.ok(!(noAssume.bestCase?.approvals ?? []).some((a) => a.includes("MATH 3140")));
});

Deno.test("placement answers: yes waives the language, no keeps the best case from assuming it", () => {
  const f = petitionFixture();
  const base = { targetTerm: "202710", allowSummer: false, assumeApprovals: true };
  const yes = plan(req(f.degrees, { ...base, advisorAnswers: [{ id: "placement:language:wh", answer: "yes" }] }), f.catalog);
  assert.ok(!planned(yes).some((c) => c.code === "SPAN 0100"));
  assert.ok(!yes.approvals.some((a) => /placement/.test(a)));
  assert.ok(yes.notes.includes("your advisor confirmed you place out of the foreign language requirement"));
  assert.equal(yes.advisorQuestions.find((q) => q.kind === "placement")!.answer, "yes");
  const no = plan(req(f.degrees, { ...base, advisorAnswers: [{ id: "placement:language:wh", answer: "no" }] }), f.catalog);
  assert.ok(planned(no).some((c) => c.code === "SPAN 0100"), "language is planned, not assumed away");
  assert.ok(!no.approvals.some((a) => /placement/.test(a)));
  assert.equal(no.advisorQuestions.find((q) => q.kind === "placement")!.answer, "no");
});

Deno.test("load answers: yes is a fact, no caps every scenario at the standard load", () => {
  const f = loadFixture();
  const base = { targetTerm: "202730", allowSummer: false };
  const yes = plan(req(f.degrees, { ...base, advisorAnswers: [{ id: "load:6.5", answer: "yes" }] }), f.catalog);
  assert.equal(yes.chosen, "approved");
  assert.deepEqual(yes.approvals, []);
  for (const t of [...yes.notes, ...yes.scenarios.map((s) => s.label)]) assert.ok(!NEEDS.test(t), t);
  assert.ok(yes.notes.includes("your advisor approved 6.5 cu a semester"));
  assert.equal(yes.advisorQuestions.find((q) => q.kind === "load")!.answer, "yes");
  const no = plan(req(f.degrees, { ...base, loadApproved: true, maxLoad: 6.5, advisorAnswers: [{ id: "load:6.5", answer: "no" }] }), f.catalog);
  assert.ok(no.scenarios.every((s) => s.maxLoad <= 5.5 + 1e-9), JSON.stringify(no.scenarios.map((s) => s.maxLoad)));
  assert.ok(no.schedule.every((t) => t.credits <= 5.5 + 1e-9));
  assert.equal(no.advisorQuestions.find((q) => q.kind === "load")!.answer, "no");
});

Deno.test("at most 12 questions, ids distinct per degree and course", () => {
  const degrees: Degree[] = [];
  const list: CatalogCourse[] = [];
  for (let d = 0; d < 14; d++) {
    const code = `XQ${String.fromCharCode(65 + d)} 1000`;
    list.push(course(code));
    degrees.push({ id: `d${d}`, label: `degree ${d}`, college: "EU", applied: [], slots: [
      slot(`d${d}`, `degree ${d}`, "Math", "seas.math", opts(code)),
      slot(`d${d}`, `degree ${d}`, "Tech", "seas.techElective", opts(code)),
    ] });
  }
  const r = plan(req(degrees), cat(list));
  assert.equal(r.advisorQuestions.length, 12);
  assert.equal(new Set(r.advisorQuestions.map((q) => q.id)).size, 12);
});

Deno.test("advisorAnswers on the request: bad elements are dropped, never refused", () => {
  const good = { id: "load:6.5", answer: "yes" };
  const body = parseDegreeAdvisorBody({
    question: "q", history: [], context: "c", terms: [{ code: "202730", label: "Fall 2027" }], addable: [], now: "2026-11-14T12:00:00Z",
    advisorAnswers: [good, { id: "", answer: "yes" }, { id: "x".repeat(201), answer: "yes" }, { id: "a", answer: "maybe" }, 7, null, { answer: "no" }, { id: "b", answer: "no" }],
  })!;
  assert.deepEqual(body.advisorAnswers, [good, { id: "b", answer: "no" }]);
  const many = parseDegreeAdvisorBody({
    question: "q", history: [], context: "c", terms: [{ code: "202730", label: "Fall 2027" }], addable: [], now: "2026-11-14T12:00:00Z",
    advisorAnswers: Array.from({ length: 60 }, (_, i) => ({ id: `i${i}`, answer: "yes" })),
  })!;
  assert.equal(many.advisorAnswers!.length, 40);
  assert.equal(parseDegreeAdvisorBody({
    question: "q", history: [], context: "c", terms: [{ code: "202730", label: "Fall 2027" }], addable: [], now: "2026-11-14T12:00:00Z", advisorAnswers: "x",
  })!.advisorAnswers, undefined);
});

// ---- coverage ---------------------------------------------------------------------

Deno.test("coverage: complete when every slot is filled by a placed course", () => {
  const f = loadFixture();
  const r = plan(req(f.degrees), f.catalog);
  assert.deepEqual(r.coverage, [{ degreeId: "wh", slots: 12, filled: 12, complete: true }]);
  const ids = new Set(planned(r).flatMap((c) => c.slotIds));
  assert.equal(ids.size, 12);
});

Deno.test("coverage: an unfilled slot makes the degree incomplete", () => {
  const f = loadFixture();
  f.degrees[0].slots.push(slot("wh", "wharton", "Nothing Lists This", "wharton.fundamental", attr("NOSUCHATTR")));
  const r = plan(req(f.degrees), f.catalog);
  const c = r.coverage[0];
  assert.equal(c.slots, 13);
  assert.ok(c.filled < c.slots || r.unfilled.length > 0);
  assert.equal(c.complete, false);
});

Deno.test("coverage: waived slots count as filled by a stated fact", () => {
  const f = loadFixture();
  const r = plan(req(f.degrees, { waive: ["wh|b|L0", "wh|b|L1"] }), f.catalog);
  const ids = new Set(planned(r).flatMap((c) => c.slotIds));
  assert.equal(r.coverage[0].slots, 12);
  assert.equal(r.coverage[0].filled, ids.size + 2);
  assert.equal(r.coverage[0].complete, true);
});

Deno.test("coverage: the 46 cu floor row makes both degrees incomplete", () => {
  const f = loadFixture();
  const degs: Degree[] = [
    { ...f.degrees[0], creditsSoFar: 10 },
    { id: "cs", label: "computer science", college: "EU", applied: [], slots: [] },
  ];
  const r = plan(req(degs), f.catalog);
  assert.ok(r.unfilled.some((u) => u.degreeLabel === "both degrees"), JSON.stringify(r.unfilled));
  assert.deepEqual(r.coverage.map((c) => c.degreeId), ["wh", "cs"]);
  assert.ok(r.coverage.every((c) => !c.complete));
});

Deno.test("coverage: a degree with no open slots is complete; entries keep request order", () => {
  const f = loadFixture();
  const degs: Degree[] = [
    { id: "cs", label: "computer science", college: "AS", applied: [], slots: [] },
    f.degrees[0],
  ];
  const r = plan(req(degs), f.catalog);
  assert.deepEqual(r.coverage.map((c) => c.degreeId), ["cs", "wh"]);
  assert.deepEqual(r.coverage[0], { degreeId: "cs", slots: 0, filled: 0, complete: true });
});

Deno.test("coverage: no finish term means incomplete", () => {
  const f = summerFixture(10);
  // Summer-only courses cannot be placed with summers ruled out.
  const r = plan(req(f.degrees, { allowSummer: false }), f.catalog);
  assert.equal(chosen(r).finishTerm, null);
  assert.equal(r.coverage[0].complete, false);
});

// ---- coverage by the target ---------------------------------------------------------

Deno.test("coverage by target: absent without a target", () => {
  const f = loadFixture();
  const r = plan(req(f.degrees), f.catalog);
  assert.equal(r.targetTerm, undefined);
  assert.equal(r.coverage[0].filledByTarget, undefined);
  assert.equal(r.coverage[0].bestFilledByTarget, undefined);
});

Deno.test("coverage by target: a late granted schedule covers less by the target than the best case", () => {
  const f = petitionFixture();
  const r = plan(req(f.degrees, { targetTerm: "202710", allowSummer: false }), f.catalog);
  assert.equal(r.targetTerm, "202710");
  assert.notEqual(r.chosen, "best");
  for (const c of r.coverage) {
    assert.ok(c.filledByTarget! <= c.filled && c.filled <= c.slots);
    assert.ok(c.filledByTarget! <= c.bestFilledByTarget! && c.bestFilledByTarget! <= c.slots);
  }
  assert.ok(r.coverage.some((c) => c.filledByTarget! < c.filled), JSON.stringify(r.coverage));
  assert.ok(r.coverage.some((c) => c.bestFilledByTarget! > c.filledByTarget!), JSON.stringify(r.coverage));
});

Deno.test("coverage by target: chosen best equals best", () => {
  const f = petitionFixture();
  const r = plan(req(f.degrees, { targetTerm: "202710", allowSummer: false, assumeApprovals: true }), f.catalog);
  assert.equal(r.chosen, "best");
  for (const c of r.coverage) assert.equal(c.bestFilledByTarget, c.filledByTarget);
});

Deno.test("coverage by target: advisor no on every petition and placement leaves nothing to add", () => {
  const f = petitionFixture();
  const r = plan(req(f.degrees, {
    targetTerm: "202710", allowSummer: false,
    advisorAnswers: [{ id: PID, answer: "no" }, { id: "placement:language:wh", answer: "no" }, { id: "load:6.5", answer: "no" }],
  }), f.catalog);
  for (const c of r.coverage) assert.equal(c.bestFilledByTarget, c.filledByTarget);
});

Deno.test("coverage by target: invariants over the load and summer fixtures", () => {
  for (const f of [loadFixture(), summerFixture(10)]) {
    const r = plan(req(f.degrees, { targetTerm: "202730" }), f.catalog);
    for (const c of r.coverage) {
      assert.ok(0 <= c.filledByTarget! && c.filledByTarget! <= c.filled && c.filled <= c.slots);
      assert.ok(c.filledByTarget! <= c.bestFilledByTarget! && c.bestFilledByTarget! <= c.slots);
    }
  }
});
