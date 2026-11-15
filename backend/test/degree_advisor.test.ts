import { strict as assert } from "node:assert";
import {
  buildDegreeAdvice,
  buildDegreeAdvisorMessages,
  DEGREE_ADVISOR_INSTRUCTIONS,
  DEGREE_ADVISOR_SCHEMA,
  finalizeDegreeAdvice,
  matchesCoursePattern,
  normalizeCourseCode,
  parseDegreeAdvisorBody,
  type DegreeAdvisorBody,
} from "../supabase/functions/_shared/degreeAdvisor.ts";
import { handleDegreeAdvisor } from "../supabase/functions/degree-advisor/index.ts";
import { GRANTED, installStub } from "./support/edgeStub.ts";

function valid(over: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    question: "what should I take?",
    history: [],
    context: "audit text",
    terms: [{ code: "202730", label: "Fall 2027" }],
    addable: ["CIS 4710"],
    now: "2026-11-14T12:00:00Z",
    ...over,
  };
}

Deno.test("degree-advisor: parse accepts a valid body and ignores extra keys", () => {
  const body = parseDegreeAdvisorBody(valid({ extra: 1, question: "  hi  " }));
  assert.ok(body);
  assert.equal(body.question, "hi");
});

const prog = { code: "FNCS-BS", name: "Finance BS", kind: "concentration" };

Deno.test("degree-advisor: programs are optional and default to empty", () => {
  assert.deepEqual(parseDegreeAdvisorBody(valid())!.programs, []);
  assert.deepEqual(parseDegreeAdvisorBody(valid({ programs: [prog] }))!.programs, [prog]);
  const edge = parseDegreeAdvisorBody(valid({
    programs: Array(80).fill({ code: "a".repeat(40), name: "a".repeat(80), kind: "a".repeat(20) }),
  }));
  assert.equal(edge!.programs.length, 80);
});

Deno.test("degree-advisor: parse rejects every cap and type violation", () => {
  const turn = { role: "user", content: "x" };
  const cases: Array<[string, unknown]> = [
    ["null", null],
    ["array", []],
    ["question missing", valid({ question: undefined })],
    ["question empty after trim", valid({ question: "   " })],
    ["question 1001", valid({ question: "a".repeat(1001) })],
    ["history not array", valid({ history: "x" })],
    ["history 7 entries", valid({ history: Array(7).fill(turn) })],
    ["history bad role", valid({ history: [{ role: "system", content: "x" }] })],
    ["history non-string content", valid({ history: [{ role: "user", content: 3 }] })],
    ["history over 6000 chars", valid({ history: [{ role: "user", content: "a".repeat(3001) }, { role: "assistant", content: "a".repeat(3000) }] })],
    ["context empty", valid({ context: "" })],
    ["context 60001", valid({ context: "a".repeat(60001) })],
    ["context not string", valid({ context: 1 })],
    ["terms 13", valid({ terms: Array(13).fill({ code: "202730", label: "x" }) })],
    ["term code not six digits", valid({ terms: [{ code: "2027", label: "x" }] })],
    ["term label missing", valid({ terms: [{ code: "202730" }] })],
    ["addable 801", valid({ addable: Array(801).fill("CIS 1200") })],
    ["addable non-string", valid({ addable: [1] })],
    ["programs not array", valid({ programs: "x" })],
    ["programs 81", valid({ programs: Array(81).fill(prog) })],
    ["program not object", valid({ programs: [1] })],
    ["program code empty", valid({ programs: [{ ...prog, code: "" }] })],
    ["program code 41", valid({ programs: [{ ...prog, code: "a".repeat(41) }] })],
    ["program name empty", valid({ programs: [{ ...prog, name: "" }] })],
    ["program name 81", valid({ programs: [{ ...prog, name: "a".repeat(81) }] })],
    ["program kind empty", valid({ programs: [{ ...prog, kind: "" }] })],
    ["program kind 21", valid({ programs: [{ ...prog, kind: "a".repeat(21) }] })],
    ["program kind missing", valid({ programs: [{ code: "FNCS-BS", name: "Finance" }] })],
    ["now missing", valid({ now: undefined })],
    ["now not a date", valid({ now: "yesterday" })],
  ];
  for (const [name, value] of cases) {
    assert.equal(parseDegreeAdvisorBody(value), undefined, name);
  }
});

Deno.test("degree-advisor: parse accepts the caps exactly", () => {
  const body = parseDegreeAdvisorBody(valid({
    question: "a".repeat(1000),
    history: Array(6).fill({ role: "user", content: "a".repeat(1000) }),
    context: "a".repeat(60000),
    terms: Array(12).fill({ code: "202730", label: "x" }),
    addable: Array(800).fill("CIS 1200"),
  }));
  assert.ok(body);
});

Deno.test("degree-advisor: normalizeCourseCode", () => {
  assert.equal(normalizeCourseCode("cis  4710"), "CIS 4710");
  assert.equal(normalizeCourseCode("  Math\t1400 "), "MATH 1400");
});

function bodyOf(over: Partial<DegreeAdvisorBody> = {}): DegreeAdvisorBody {
  return {
    question: "plan fall",
    history: [{ role: "user", content: "hi" }, { role: "assistant", content: "hello" }],
    context: "AUDIT",
    terms: [{ code: "202730", label: "Fall 2027" }, { code: "202810", label: "Spring 2028" }],
    addable: ["cis  4710", "MATH 1400"],
    programs: [],
    requirements: [],
    now: "2026-11-14T12:00:00Z",
    ...over,
  };
}

Deno.test("degree-advisor: messages are ordered stable-first with the date last", () => {
  const m = buildDegreeAdvisorMessages(bodyOf());
  assert.equal(m.length, 5);
  assert.equal(m[0].role, "system");
  assert.equal(m[0].content, DEGREE_ADVISOR_INSTRUCTIONS);
  assert.equal(m[1].role, "system");
  const s = m[1].content;
  assert.ok(s.startsWith("DOCUMENT\nAUDIT"));
  assert.ok(s.indexOf("DOCUMENT") < s.indexOf("TERMS") && s.indexOf("TERMS") < s.indexOf("ADDABLE"));
  assert.ok(s.includes("202730 | Fall 2027\n202810 | Spring 2028"));
  assert.ok(s.endsWith("ADDABLE\nCIS 4710, MATH 1400\n\nREQUIREMENTS\nnone\n\nPROGRAMS\nnone"));
  assert.deepEqual(m.slice(2, 4), [{ role: "user", content: "hi" }, { role: "assistant", content: "hello" }]);
  assert.equal(m[4].role, "user");
  assert.equal(m[4].content, "Current date: 2026-11-14T12:00:00Z\n\nplan fall");
});

Deno.test("degree-advisor: PROGRAMS follows ADDABLE, one line per program", () => {
  const m = buildDegreeAdvisorMessages(bodyOf({ programs: [prog, { code: "MATH-BA", name: "Math", kind: "major" }] }));
  const s = m[1].content;
  assert.ok(s.indexOf("ADDABLE") < s.indexOf("PROGRAMS"));
  assert.ok(s.endsWith("PROGRAMS\nFNCS-BS | Finance BS | concentration\nMATH-BA | Math | major"));
});

Deno.test("degree-advisor: empty terms and addable read as none", () => {
  const m = buildDegreeAdvisorMessages(bodyOf({ terms: [], addable: [], history: [] }));
  assert.ok(m[1].content.includes("TERMS\nnone"));
  assert.ok(m[1].content.endsWith("ADDABLE\nnone\n\nREQUIREMENTS\nnone\n\nPROGRAMS\nnone"));
  assert.equal(m.length, 3);
});

const act = (o: Record<string, unknown>) => ({ op: "add", code: "CIS 4710", term: "202730", toTerm: null, ...o });
const reply = (actions: unknown[], answer = "ok", whatIf: unknown = null) =>
  JSON.stringify({ actions, whatIf, answer });

Deno.test("degree-advisor: advice keeps a valid add and normalizes the code", () => {
  const r = buildDegreeAdvice(reply([act({ code: "cis 4710" })]), bodyOf());
  assert.deepEqual(r.actions, [{ op: "add", code: "CIS 4710", term: "202730", toTerm: null, for: null, title: null, credits: null }]);
});

Deno.test("degree-advisor: advice drops adds outside addable and unknown terms", () => {
  const r = buildDegreeAdvice(reply([act({ code: "CIS 9999" }), act({ term: "209999" })]), bodyOf());
  assert.deepEqual(r.actions, []);
});

Deno.test("degree-advisor: move needs a different valid toTerm; add nulls toTerm", () => {
  const r = buildDegreeAdvice(
    reply([
      { op: "move", code: "cis 1200", term: "202730", toTerm: "202810" },
      { op: "move", code: "CIS 1200", term: "202730", toTerm: "202730" },
      { op: "move", code: "CIS 1200", term: "202730", toTerm: "209999" },
      { op: "move", code: "CIS 1200", term: "202730", toTerm: null },
      act({ toTerm: "202810" }),
      { op: "remove", code: "CIS 1200", term: "202730", toTerm: "202810" },
    ]),
    bodyOf(),
  );
  assert.deepEqual(r.actions, [
    { op: "move", code: "CIS 1200", term: "202730", toTerm: "202810", for: null, title: null, credits: null },
    { op: "add", code: "CIS 4710", term: "202730", toTerm: null, for: null, title: null, credits: null },
    { op: "remove", code: "CIS 1200", term: "202730", toTerm: null, for: null, title: null, credits: null },
  ]);
});

Deno.test("degree-advisor: advice drops duplicates and caps at 80", () => {
  const dup = buildDegreeAdvice(reply([act({}), act({ code: "cis 4710" })]), bodyOf());
  assert.equal(dup.actions.length, 1);
  const many = Array.from({ length: 100 }, (_, i) => ({ op: "remove", code: `CIS ${1000 + i}`, term: "202730", toTerm: null }));
  assert.equal(buildDegreeAdvice(reply(many), bodyOf()).actions.length, 80);
});

Deno.test("degree-advisor: whatIf is kept only for a listed program and empties actions", () => {
  const b = bodyOf({ programs: [prog] });
  const kept = buildDegreeAdvice(reply([act({})], "reading", " FNCS-BS "), b);
  assert.equal(kept.whatIf, "FNCS-BS");
  assert.deepEqual(kept.actions, []);
  const unlisted = buildDegreeAdvice(reply([act({})], "x", "NOPE"), b);
  assert.equal(unlisted.whatIf, null);
  assert.equal(unlisted.actions.length, 1);
  assert.equal(buildDegreeAdvice(reply([], "x", 5), b).whatIf, null);
  assert.equal(buildDegreeAdvice(reply([], "x", "FNCS-BS"), bodyOf()).whatIf, null);
  // A version-1 style reply with no whatIf key still reads.
  assert.equal(buildDegreeAdvice(JSON.stringify({ answer: "a", actions: [] }), b).whatIf, null);
});

Deno.test("degree-advisor: advice accepts fenced JSON and trims the answer", () => {
  const r = buildDegreeAdvice("```json\n" + reply([], "  hi  ") + "\n```", bodyOf());
  assert.equal(r.answer, "hi");
  assert.equal(buildDegreeAdvice(reply([], "a".repeat(3000)), bodyOf()).answer.length, 2000);
});

Deno.test("degree-advisor: unusable output throws", () => {
  const b = bodyOf();
  assert.throws(() => buildDegreeAdvice(reply([], "   "), b), /unusable model output/);
  assert.throws(() => buildDegreeAdvice("not json", b), /unusable model output/);
  assert.throws(() => buildDegreeAdvice("[1]", b), /unusable model output/);
  assert.throws(() => buildDegreeAdvice(JSON.stringify({ actions: [] }), b), /unusable model output/);
});

Deno.test("degree-advisor: schema is strict-shaped", () => {
  const s = DEGREE_ADVISOR_SCHEMA.schema as any;
  assert.equal(DEGREE_ADVISOR_SCHEMA.name, "degree_advice");
  assert.equal(s.additionalProperties, false);
  assert.deepEqual(Object.keys(s.properties), ["actions", "whatIf", "planning", "answer"]);
  assert.deepEqual(s.required, ["actions", "whatIf", "planning", "answer"]);
  assert.deepEqual(s.properties.planning.type, "boolean");
  assert.deepEqual(Object.keys(s.properties.actions.items.properties), ["op", "code", "term", "toTerm", "for"]);
  assert.deepEqual(s.properties.actions.items.properties.for.type, ["string", "null"]);
  assert.deepEqual(s.properties.whatIf.type, ["string", "null"]);
  assert.equal(s.properties.actions.items.additionalProperties, false);
  assert.deepEqual([...s.properties.actions.items.required].sort(), ["code", "for", "op", "term", "toTerm"]);
});

Deno.test("degree-advisor: instructions carry the load-bearing phrases", () => {
  assert.ok(DEGREE_ADVISOR_INSTRUCTIONS.includes("would count toward"));
  assert.ok(DEGREE_ADVISOR_INSTRUCTIONS.includes("ADDABLE"));
  for (const phrase of ["PROGRAMS", "EVERY", "Path@Penn", "PICKS", "FINISH", "REQUIREMENTS"]) {
    assert.ok(DEGREE_ADVISOR_INSTRUCTIONS.includes(phrase), phrase);
  }
  assert.ok(!DEGREE_ADVISOR_INSTRUCTIONS.toLowerCase().includes("guarantee"));
});

Deno.test("degree-advisor: a malformed body is a 400 and the model is never reached", async () => {
  const stub = installStub({ reserve: () => GRANTED, openrouter: { kind: "json", content: "{}" } });
  try {
    const res = await handleDegreeAdvisor(
      new Request("http://functions.test/degree-advisor", {
        method: "POST",
        headers: { Authorization: "Bearer test-jwt", "content-type": "application/json" },
        body: JSON.stringify({ question: "" }),
      }),
    );
    assert.equal(res.status, 400);
    assert.equal((await res.json()).error, "bad_request");
    assert.ok(!stub.log.includes("openrouter"));
  } finally {
    stub.restore();
  }
});

Deno.test("degree-advisor: a 200 carries actions, whatIf, answer and the model id", async () => {
  const content = JSON.stringify({ actions: [], whatIf: "FNCS-BS", answer: "reading penn's audit for finance." });
  const stub = installStub({ reserve: () => GRANTED, openrouter: { kind: "json", content } });
  try {
    const res = await handleDegreeAdvisor(
      new Request("http://functions.test/degree-advisor", {
        method: "POST",
        headers: { Authorization: "Bearer test-jwt", "content-type": "application/json" },
        body: JSON.stringify(valid({ programs: [{ code: "FNCS-BS", name: "Finance BS", kind: "concentration" }] })),
      }),
    );
    assert.equal(res.status, 200);
    const out = await res.json();
    assert.deepEqual(Object.keys(out).sort(), ["actions", "answer", "dropped", "model", "planning", "whatIf"]);
    assert.equal(out.planning, false);
    assert.deepEqual(out.dropped, []);
    assert.equal(out.whatIf, "FNCS-BS");
    assert.equal(typeof out.model, "string");
    assert.ok(out.model.length > 0);
  } finally {
    stub.restore();
  }
});

const req = (o: Record<string, unknown> = {}) => ({
  tag: "R1", label: "General Management elective", degree: "Wharton", need: "need 2 cu", patterns: ["MGMT @", "MGMT 2@"], ...o,
});

Deno.test("degree-advisor: requirements are optional and parsed", () => {
  assert.deepEqual(parseDegreeAdvisorBody(valid())!.requirements, []);
  assert.deepEqual(parseDegreeAdvisorBody(valid({ requirements: [req()] }))!.requirements, [req()]);
  const edge = parseDegreeAdvisorBody(valid({
    requirements: Array.from({ length: 120 }, (_, i) =>
      req({ tag: `R${i + 1}`, label: "a".repeat(160), degree: "a".repeat(80), need: "a".repeat(40), patterns: Array(20).fill("a".repeat(20)) })),
  }));
  assert.equal(edge!.requirements.length, 120);
  assert.ok(parseDegreeAdvisorBody(valid({ requirements: [req({ degree: "", need: "", patterns: [] })] })));
});

Deno.test("degree-advisor: every requirements violation is a malformed body", () => {
  const cases: Array<[string, unknown]> = [
    ["not array", "x"],
    ["121 entries", Array.from({ length: 121 }, (_, i) => req({ tag: `R${i}` }))],
    ["entry not object", [1]],
    ["bad tag", [req({ tag: "X1" })]],
    ["tag 4 digits", [req({ tag: "R1234" })]],
    ["duplicate tag", [req(), req()]],
    ["label empty", [req({ label: "" })]],
    ["label 161", [req({ label: "a".repeat(161) })]],
    ["degree 81", [req({ degree: "a".repeat(81) })]],
    ["degree not string", [req({ degree: 1 })]],
    ["need 41", [req({ need: "a".repeat(41) })]],
    ["patterns not array", [req({ patterns: "MGMT @" })]],
    ["patterns 21", [req({ patterns: Array(21).fill("A @") })]],
    ["pattern empty", [req({ patterns: [""] })]],
    ["pattern 21 chars", [req({ patterns: ["a".repeat(21)] })]],
    ["pattern not string", [req({ patterns: [1] })]],
  ];
  for (const [name, value] of cases) {
    assert.equal(parseDegreeAdvisorBody(valid({ requirements: value })), undefined, name);
  }
});

Deno.test("degree-advisor: REQUIREMENTS renders between ADDABLE and PROGRAMS", () => {
  const m = buildDegreeAdvisorMessages(bodyOf({
    requirements: [
      { tag: "R3", label: "Business Breadth", degree: "Wharton", need: "need 4 courses", patterns: ["MGMT @", "MGMT 2@"] },
      { tag: "R4", label: "Humanities", degree: "SEAS", need: "", patterns: [] },
    ],
  }));
  const s = m[1].content;
  assert.ok(s.indexOf("ADDABLE") < s.indexOf("REQUIREMENTS") && s.indexOf("REQUIREMENTS") < s.indexOf("PROGRAMS"));
  assert.ok(s.includes("REQUIREMENTS\nR3 | Wharton | Business Breadth | need 4 courses | patterns: MGMT @, MGMT 2@\nR4 | SEAS | Humanities | \n\nPROGRAMS"));
});

Deno.test("degree-advisor: matchesCoursePattern", () => {
  const table: Array<[string, string, boolean]> = [
    ["MGMT 2380", "MGMT @", true],
    ["mgmt 2380", "MGMT @", true],
    ["MGMT 2380", "mgmt @", true],
    ["CIS 1200", "MGMT @", false],
    ["CIS 1200", "@ @", true],
    ["CIS 1200", "@ @@@@", true],
    ["MGMT 2380", "MGMT 2@", true],
    ["MGMT 2380", "MGMT 23@@", true],
    ["MGMT 3380", "MGMT 2@", false],
    ["MGMT 2380", "MGMT 2380", true],
    ["MGMT 2381", "MGMT 2380", false],
    ["MGMT 2380", "MGMT 1@:2@", false],
    ["MGMT 2380", "MGMT 2@ (ATTR=X)", false],
    ["MGMT 2380", "MGMT", true],
    ["CIS 2380", "@ 2@", true],
    ["MGMT 2380", "", false],
  ];
  for (const [code, pattern, expected] of table) {
    assert.equal(matchesCoursePattern(code, pattern), expected, `${code} vs ${pattern}`);
  }
});

const picksBody = () => bodyOf({
  requirements: [
    { tag: "R1", label: "GM elective", degree: "Wharton", need: "need 1 cu", patterns: ["MGMT @"] },
    { tag: "R2", label: "Humanities", degree: "SEAS", need: "", patterns: [] },
  ],
});

Deno.test("degree-advisor: picks are kept by tag, shape and pattern, and listed for lookup", () => {
  const r = buildDegreeAdvice(reply([
    act({ code: "mgmt 2380", for: "R1" }),
    act({ code: "HIST 1000", for: "R2" }),
    act({ code: "MGMT 2380", for: "R9" }),
    act({ code: "ENGL 1000", for: null }),
    act({ code: "MGMT 238", for: "R1" }),
    act({ code: "ENGL 1000", for: "R1" }),
    act({ code: "CIS 4710", for: "R2" }),
    act({ code: "CIS 4710", for: "R7", term: "202810" }),
  ]), picksBody());
  assert.deepEqual(r.actions.map((a) => [a.code, a.for]), [
    ["MGMT 2380", "R1"], ["HIST 1000", "R2"], ["CIS 4710", "R2"], ["CIS 4710", null],
  ]);
  assert.deepEqual(r.pickCodes.sort(), ["HIST 1000", "MGMT 2380"]);
});

Deno.test("degree-advisor: finalize drops unverified picks and fills title and credits", () => {
  const draft = buildDegreeAdvice(reply([
    act({ code: "MGMT 2380", for: "R1" }),
    act({ code: "HIST 1000", for: "R2" }),
    act({ code: "CIS 4710", for: "R2" }),
    { op: "remove", code: "CIS 1200", term: "202730", toTerm: null, for: "R1" },
  ]), picksBody());
  const out = finalizeDegreeAdvice(draft, new Map([["MGMT 2380", { title: "Negotiations", credits: 1 }], ["HIST 1000", { title: "Old", credits: null }]]));
  assert.deepEqual(out.actions, [
    { op: "add", code: "MGMT 2380", term: "202730", toTerm: null, for: "R1", title: "Negotiations", credits: 1 },
    { op: "add", code: "HIST 1000", term: "202730", toTerm: null, for: "R2", title: "Old", credits: null },
    { op: "add", code: "CIS 4710", term: "202730", toTerm: null, for: "R2", title: null, credits: null },
    { op: "remove", code: "CIS 1200", term: "202730", toTerm: null, for: null, title: null, credits: null },
  ]);
  const none = finalizeDegreeAdvice(draft, new Map());
  assert.deepEqual(none.actions.map((a) => a.code), ["CIS 4710", "CIS 1200"]);
});

Deno.test("degree-advisor: a whatIf still empties picks too", () => {
  const b = bodyOf({ programs: [prog], requirements: picksBody().requirements });
  const r = buildDegreeAdvice(reply([act({ code: "MGMT 2380", for: "R1" })], "x", "FNCS-BS"), b);
  assert.deepEqual(r.actions, []);
  assert.deepEqual(r.pickCodes, []);
});

Deno.test("degree-advisor: a 200 verifies picks against Penn and drops unknown ones", async () => {
  const content = JSON.stringify({
    actions: [
      { op: "add", code: "MGMT 2380", term: "202730", toTerm: null, for: "R1" },
      { op: "add", code: "MGMT 2999", term: "202730", toTerm: null, for: "R1" },
    ],
    whatIf: null,
    answer: "done",
  });
  const stub = installStub({ reserve: () => GRANTED, openrouter: { kind: "json", content } });
  const stubFetch = globalThis.fetch;
  globalThis.fetch = ((input: Request | URL | string, init?: RequestInit) => {
    const url = String(input);
    if (url.startsWith("https://penncoursereview.com/")) {
      if (url.includes("MGMT-2380")) {
        return Promise.resolve(new Response(JSON.stringify({ id: "MGMT-2380", title: "Negotiations", credits: "1.00" }), { status: 200 }));
      }
      return Promise.resolve(new Response("{}", { status: 404 }));
    }
    return stubFetch(input as any, init);
  }) as typeof fetch;
  try {
    const res = await handleDegreeAdvisor(
      new Request("http://functions.test/degree-advisor", {
        method: "POST",
        headers: { Authorization: "Bearer test-jwt", "content-type": "application/json" },
        body: JSON.stringify(valid({
          requirements: [req({ patterns: ["MGMT @"] })],
        })),
      }),
    );
    assert.equal(res.status, 200);
    const out = await res.json();
    assert.deepEqual(out.actions, [
      { op: "add", code: "MGMT 2380", term: "202730", toTerm: null, for: "R1", title: "Negotiations", credits: 1 },
    ]);
    assert.deepEqual(out.dropped, ["MGMT 2999"]);
  } finally {
    globalThis.fetch = stubFetch;
    stub.restore();
  }
});

Deno.test("degree-advisor: round is optional, 1 to 3, and anything else is malformed", () => {
  assert.equal(parseDegreeAdvisorBody(valid())!.round, 1);
  for (const r of [1, 2, 3]) assert.equal(parseDegreeAdvisorBody(valid({ round: r }))!.round, r);
  for (const r of [0, 4, -1, 1.5, "2", null, true]) assert.equal(parseDegreeAdvisorBody(valid({ round: r })), undefined, String(r));
});

Deno.test("degree-advisor: planning passes through, defaults to false, survives whatIf", () => {
  const b = bodyOf({ programs: [prog] });
  assert.equal(buildDegreeAdvice(reply([]), b).planning, false);
  const withFlag = (planning: unknown, whatIf: string | null = null) =>
    JSON.stringify({ actions: [], whatIf, planning, answer: "ok" });
  assert.equal(buildDegreeAdvice(withFlag(true), b).planning, true);
  assert.equal(buildDegreeAdvice(withFlag(false), b).planning, false);
  assert.equal(buildDegreeAdvice(withFlag("yes"), b).planning, false);
  assert.equal(buildDegreeAdvice(withFlag(true, "FNCS-BS"), b).planning, true);
});

Deno.test("degree-advisor: finalize reports dropped picks, normalized, capped at 80", () => {
  const picks = Array.from({ length: 90 }, (_, i) => `MGMT ${1000 + i}`);
  const draft = {
    actions: picks.map((code) => ({ op: "add" as const, code, term: "202730", toTerm: null, for: "R1", title: null, credits: null })),
    whatIf: null, planning: true, answer: "x", pickCodes: picks,
  };
  const out = finalizeDegreeAdvice(draft, new Map([["MGMT 1000", { title: "T", credits: 1 }]]));
  assert.equal(out.actions.length, 1);
  assert.equal(out.dropped.length, 80);
  assert.ok(!out.dropped.includes("MGMT 1000"));
  assert.equal(out.planning, true);
  assert.deepEqual(finalizeDegreeAdvice({ ...draft, actions: [], pickCodes: [] }, new Map()).dropped, []);
});

Deno.test("degree-advisor: the student's instructions override the defaults; no hard load ceiling", () => {
  const t = DEGREE_ADVISOR_INSTRUCTIONS;
  assert.ok(t.includes("explicit instructions override every default"));
  assert.ok(t.includes("Never refuse an instruction about load or finish date"));
  assert.ok(!/never above 6/i.test(t));
  assert.ok(!/never bring a semester above 6/i.test(t));
  assert.ok(t.includes("I can take 7"));
  for (const phrase of ["STILL NEEDED", "WHOLE PLANS", "CONTINUATION", "continue the plan", "PLANNING FLAG"]) {
    assert.ok(t.includes(phrase), phrase);
  }
});

Deno.test("degree-advisor: unusable primary output retries once on the fallback model", async () => {
  const stub = installStub({ reserve: () => GRANTED, openrouter: { kind: "json", content: "{}" } });
  const stubFetch = globalThis.fetch;
  const models: string[] = [];
  const good = JSON.stringify({ actions: [], whatIf: null, planning: true, answer: "ok" });
  globalThis.fetch = ((input: Request | URL | string, init?: RequestInit) => {
    if (String(input).startsWith("https://openrouter.ai/")) {
      models.push(JSON.parse(String(init?.body)).model);
      const content = models.length === 1 ? '{"actions": [' : good;
      return Promise.resolve(new Response(JSON.stringify({ choices: [{ message: { content } }], usage: { completion_tokens: 5 } }), { status: 200 }));
    }
    return stubFetch(input as any, init);
  }) as typeof fetch;
  try {
    const res = await handleDegreeAdvisor(
      new Request("http://functions.test/degree-advisor", {
        method: "POST",
        headers: { Authorization: "Bearer test-jwt", "content-type": "application/json" },
        body: JSON.stringify(valid({ round: 2 })),
      }),
    );
    assert.equal(res.status, 200);
    const out = await res.json();
    assert.equal(out.planning, true);
    assert.equal(models.length, 2);
    assert.notEqual(models[0], models[1]);
    assert.equal(out.model, models[1]);
  } finally {
    globalThis.fetch = stubFetch;
    stub.restore();
  }
});

Deno.test("degree-advisor: unusable output on both models is a 502", async () => {
  const stub = installStub({ reserve: () => GRANTED, openrouter: { kind: "json", content: "not json" } });
  try {
    const res = await handleDegreeAdvisor(
      new Request("http://functions.test/degree-advisor", {
        method: "POST",
        headers: { Authorization: "Bearer test-jwt", "content-type": "application/json" },
        body: JSON.stringify(valid()),
      }),
    );
    assert.equal(res.status, 502);
  } finally {
    stub.restore();
  }
});
