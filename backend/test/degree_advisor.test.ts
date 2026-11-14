import { strict as assert } from "node:assert";
import {
  buildDegreeAdvice,
  buildDegreeAdvisorMessages,
  DEGREE_ADVISOR_INSTRUCTIONS,
  DEGREE_ADVISOR_SCHEMA,
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
  assert.ok(s.endsWith("ADDABLE\nCIS 4710, MATH 1400"));
  assert.deepEqual(m.slice(2, 4), [{ role: "user", content: "hi" }, { role: "assistant", content: "hello" }]);
  assert.equal(m[4].role, "user");
  assert.equal(m[4].content, "Current date: 2026-11-14T12:00:00Z\n\nplan fall");
});

Deno.test("degree-advisor: empty terms and addable read as none", () => {
  const m = buildDegreeAdvisorMessages(bodyOf({ terms: [], addable: [], history: [] }));
  assert.ok(m[1].content.includes("TERMS\nnone"));
  assert.ok(m[1].content.endsWith("ADDABLE\nnone"));
  assert.equal(m.length, 3);
});

const act = (o: Record<string, unknown>) => ({ op: "add", code: "CIS 4710", term: "202730", toTerm: null, ...o });
const reply = (actions: unknown[], answer = "ok") => JSON.stringify({ answer, actions });

Deno.test("degree-advisor: advice keeps a valid add and normalizes the code", () => {
  const r = buildDegreeAdvice(reply([act({ code: "cis 4710" })]), bodyOf());
  assert.deepEqual(r.actions, [{ op: "add", code: "CIS 4710", term: "202730", toTerm: null }]);
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
    { op: "move", code: "CIS 1200", term: "202730", toTerm: "202810" },
    { op: "add", code: "CIS 4710", term: "202730", toTerm: null },
    { op: "remove", code: "CIS 1200", term: "202730", toTerm: null },
  ]);
});

Deno.test("degree-advisor: advice drops duplicates and caps at 24", () => {
  const dup = buildDegreeAdvice(reply([act({}), act({ code: "cis 4710" })]), bodyOf());
  assert.equal(dup.actions.length, 1);
  const many = Array.from({ length: 40 }, (_, i) => ({ op: "remove", code: `CIS ${1000 + i}`, term: "202730", toTerm: null }));
  assert.equal(buildDegreeAdvice(reply(many), bodyOf()).actions.length, 24);
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
  assert.deepEqual(s.required, ["answer", "actions"]);
  assert.equal(s.properties.actions.items.additionalProperties, false);
  assert.deepEqual([...s.properties.actions.items.required].sort(), ["code", "op", "term", "toTerm"]);
});

Deno.test("degree-advisor: instructions carry the load-bearing phrases", () => {
  assert.ok(DEGREE_ADVISOR_INSTRUCTIONS.includes("would count toward"));
  assert.ok(DEGREE_ADVISOR_INSTRUCTIONS.includes("ADDABLE"));
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
