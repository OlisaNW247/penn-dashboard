// `parseAskRequestBody`'s shape check and its size caps (hardening BE-A).
// The caps are generous on purpose (a real syllabus-sized prompt is about
// 56k characters of context document, the cap is 400k), so the tests pin
// both sides: a realistic heavy request still parses, and each field's
// ceiling is enforced at exactly its boundary.
import { strict as assert } from "node:assert";
import {
  type AskRequestBody,
  MAX_CONTEXT_DOCUMENT_CHARS,
  MAX_EXCERPTS_CHARS,
  MAX_HISTORY_CHARS_ACCEPTED,
  MAX_HISTORY_TURNS_ACCEPTED,
  MAX_QUESTION_CHARS,
  parseAskRequestBody,
} from "../supabase/functions/_shared/askRequest.ts";

function validBody(overrides: Partial<Record<keyof AskRequestBody, unknown>> = {}): Record<string, unknown> {
  return {
    question: "when is the midterm?",
    contextDocument: "CONTEXT",
    excerpts: "",
    askedAt: "2026-10-27T12:00:00Z",
    courseIDs: ["1", "2"],
    history: [],
    ...overrides,
  };
}

function tooLarge(value: unknown, field: string): void {
  const result = parseAskRequestBody(value);
  assert.equal(result.ok, false);
  if (!result.ok) {
    assert.equal(result.kind, "too_large");
    assert.ok(result.reason.includes(field), result.reason);
  }
}

Deno.test("parseAskRequestBody: a valid body round-trips", () => {
  const result = parseAskRequestBody(validBody({ history: [{ role: "user", content: "hi" }] }));
  assert.equal(result.ok, true);
  if (result.ok) {
    assert.equal(result.body.question, "when is the midterm?");
    assert.deepEqual(result.body.history, [{ role: "user", content: "hi" }]);
  }
});

Deno.test("parseAskRequestBody: a realistic heavy request is nowhere near the caps", () => {
  // 14k tokens is about 56k characters; give it twice that, plus excerpts and a full history.
  const result = parseAskRequestBody(validBody({
    contextDocument: "x".repeat(112_000),
    excerpts: "e".repeat(30_000),
    history: Array.from({ length: 10 }, (_, i) => ({ role: i % 2 ? "assistant" : "user", content: "c".repeat(800) })),
  }));
  assert.equal(result.ok, true);
});

Deno.test("parseAskRequestBody: the wrong shape is malformed, not too_large", () => {
  for (const bad of [null, "text", 5, [], {}, validBody({ question: 5 }), validBody({ courseIDs: [1] }), validBody({ history: [{ role: "system", content: "x" }] })]) {
    const result = parseAskRequestBody(bad);
    assert.equal(result.ok, false);
    if (!result.ok) assert.equal(result.kind, "malformed");
  }
});

Deno.test("parseAskRequestBody: contextDocument is capped at exactly its ceiling", () => {
  assert.equal(parseAskRequestBody(validBody({ contextDocument: "x".repeat(MAX_CONTEXT_DOCUMENT_CHARS) })).ok, true);
  tooLarge(validBody({ contextDocument: "x".repeat(MAX_CONTEXT_DOCUMENT_CHARS + 1) }), "contextDocument");
});

Deno.test("parseAskRequestBody: excerpts are capped at exactly their ceiling", () => {
  assert.equal(parseAskRequestBody(validBody({ excerpts: "x".repeat(MAX_EXCERPTS_CHARS) })).ok, true);
  tooLarge(validBody({ excerpts: "x".repeat(MAX_EXCERPTS_CHARS + 1) }), "excerpts");
});

Deno.test("parseAskRequestBody: the question is capped at exactly its ceiling", () => {
  assert.equal(parseAskRequestBody(validBody({ question: "x".repeat(MAX_QUESTION_CHARS) })).ok, true);
  tooLarge(validBody({ question: "x".repeat(MAX_QUESTION_CHARS + 1) }), "question");
});

Deno.test("parseAskRequestBody: history is capped by turn count", () => {
  const turns = (n: number) => Array.from({ length: n }, () => ({ role: "user", content: "x" }));
  assert.equal(parseAskRequestBody(validBody({ history: turns(MAX_HISTORY_TURNS_ACCEPTED) })).ok, true);
  tooLarge(validBody({ history: turns(MAX_HISTORY_TURNS_ACCEPTED + 1) }), "history turns");
});

Deno.test("parseAskRequestBody: history is capped by total characters too, so one huge turn cannot slip under the turn cap", () => {
  const one = (n: number) => [{ role: "user", content: "x".repeat(n) }];
  assert.equal(parseAskRequestBody(validBody({ history: one(MAX_HISTORY_CHARS_ACCEPTED) })).ok, true);
  tooLarge(validBody({ history: one(MAX_HISTORY_CHARS_ACCEPTED + 1) }), "history characters");
  const spread = Array.from({ length: 20 }, () => ({ role: "assistant", content: "x".repeat(MAX_HISTORY_CHARS_ACCEPTED / 10) }));
  tooLarge(validBody({ history: spread }), "history characters");
});

Deno.test("parseAskRequestBody: the refusal reason carries the field name and none of the content", () => {
  const result = parseAskRequestBody(validBody({ question: "SECRET-QUESTION".repeat(5_000) }));
  assert.equal(result.ok, false);
  if (!result.ok) assert.ok(!result.reason.includes("SECRET"));
});
