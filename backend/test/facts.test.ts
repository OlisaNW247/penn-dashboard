import { strict as assert } from "node:assert";
import {
  buildFactsMessages,
  FACTS_INSTRUCTIONS,
  FACTS_JSON_SCHEMA,
  type FactsDocument,
  parseFacts,
} from "../supabase/functions/_shared/facts.ts";

// A Thursday-evening post, so "Friday" is resolvable from the posted weekday.
const doc: FactsDocument = {
  id: "ann-1",
  course: "CIS 2400",
  kind: "announcement",
  title: "Homework update",
  postedAt: "2026-11-05T23:30:00Z", // 18:30 Thursday in New York
  text: "HW3 is now due Friday.\nPlease   read chapter 5 before class.",
  index: [
    { sourceID: "a1", title: "HW3", dueAt: "2026-11-04T04:59:00Z", kind: "assignment" },
    { sourceID: "m7", title: "Week 9 reading", kind: "module_item" },
  ],
  meetings: [{ weekday: "Tue", start: "13:45", end: "15:15", room: "Towne 100" }],
  timezone: "America/New_York",
  now: "2026-11-05T23:35:00Z",
};

const wrap = (facts: unknown[]) => JSON.stringify({ facts });
const base = { target: null, title: null, due_at: null, kind: null, confidence: "high" };

Deno.test("FACTS_JSON_SCHEMA is strict at every object level", () => {
  // Strict mode fails the whole request, on some providers, if any object
  // leaves a property out of `required` or allows extras; walk everything
  // so a later edit that adds a field cannot forget one.
  let objects = 0;
  const walk = (node: unknown) => {
    if (Array.isArray(node)) return node.forEach(walk);
    if (typeof node !== "object" || node === null) return;
    const n = node as Record<string, unknown>;
    if (n.type === "object") {
      objects++;
      assert.equal(n.additionalProperties, false);
      assert.deepEqual([...(n.required as string[])].sort(), Object.keys(n.properties as object).sort());
    }
    assert.ok(!("minimum" in n) && !("maxLength" in n));
    Object.values(n).forEach(walk);
  };
  walk(FACTS_JSON_SCHEMA);
  assert.equal(objects, 2);
});

Deno.test("FACTS_INSTRUCTIONS keeps the rules the bench taught", () => {
  for (const word of ["23:59", "optional", "covers", "title"]) {
    assert.ok(FACTS_INSTRUCTIONS.includes(word), `missing "${word}"`);
  }
});

Deno.test("buildFactsMessages renders weekday, index, meetings and document", () => {
  const { user } = buildFactsMessages(doc);
  assert.match(user, /^Course: CIS 2400\nDocument kind: announcement\nTitle: Homework update\n/);
  assert.ok(user.includes("Posted at: 2026-11-05T23:30:00Z (Thursday in America/New_York)"));
  assert.ok(user.includes("Current date: 2026-11-05T23:35:00Z"));
  assert.ok(user.includes("a1 | HW3 | 2026-11-04T04:59:00Z"));
  assert.ok(user.includes("m7 | Week 9 reading | undated"));
  assert.ok(user.includes("CLASS MEETINGS:\nTue 13:45-15:15 Towne 100"));
  assert.ok(user.endsWith("DOCUMENT:\n" + doc.text));
});

Deno.test("buildFactsMessages marks an empty index and omits empty meetings", () => {
  const { user } = buildFactsMessages({ ...doc, index: [], meetings: [], postedAt: undefined });
  assert.ok(user.includes("ITEM INDEX (sourceID | title | due):\n(empty)"));
  assert.ok(!user.includes("CLASS MEETINGS"));
  assert.ok(!user.includes("Posted at"));
});

Deno.test("parseFacts accepts a fenced response and tolerates whitespace and case in quotes", () => {
  const body = "```json\n" + wrap([
    { ...base, type: "reschedule", target: "a1", due_at: "2026-11-06T23:59:00-05:00", quote: "hw3 is now due\n friday." },
  ]) + "\n```";
  const parsed = parseFacts(body, doc);
  assert.equal(parsed.parseFailed, false);
  assert.equal(parsed.facts.length, 1);
  assert.equal(parsed.facts[0].target, "a1");
  assert.equal(parsed.facts[0].title, undefined);
});

Deno.test("parseFacts rejects a quote that is not in the document", () => {
  const parsed = parseFacts(wrap([{ ...base, type: "cancel", target: "a1", quote: "HW3 is cancelled" }]), doc);
  assert.equal(parsed.facts.length, 0);
  assert.equal(parsed.rejected[0].reason, "quote_not_in_text");
});

Deno.test("parseFacts accepts a quote taken from the title", () => {
  const titled = { ...doc, title: "Quiz 2 is rescheduled to Sep 23" };
  const parsed = parseFacts(wrap([{ ...base, type: "reschedule", target: "a1", due_at: "2026-09-23T23:59:00-04:00", quote: "rescheduled to Sep 23" }]), titled);
  assert.equal(parsed.rejected.length, 0);
  assert.equal(parsed.facts.length, 1);
});

Deno.test("parseFacts rejects a target that is not in the index", () => {
  const parsed = parseFacts(wrap([{ ...base, type: "note", target: "zzz", title: "x", quote: "read chapter 5" }]), doc);
  assert.equal(parsed.rejected[0].reason, "unknown_target");
});

Deno.test("parseFacts requires a target for changes and a title for new tasks", () => {
  const parsed = parseFacts(wrap([
    { ...base, type: "cancel", quote: "read chapter 5" },
    { ...base, type: "new_task", title: "  ", quote: "read chapter 5" },
    { ...base, type: "needs_review", quote: "read chapter 5" }, // target optional
  ]), doc);
  assert.deepEqual(parsed.rejected.map((r) => r.reason), ["target_required", "title_required"]);
  assert.equal(parsed.facts.length, 1);
  assert.equal(parsed.facts[0].type, "needs_review");
});

Deno.test("parseFacts drops a reschedule whose date is two years old", () => {
  // The date is the whole fact for a reschedule; keeping it with a null date
  // would tell the phone the item moved to nowhere.
  const parsed = parseFacts(wrap([
    { ...base, type: "reschedule", target: "a1", due_at: "2024-11-06T23:59:00Z", quote: "HW3 is now due Friday" },
  ]), doc);
  assert.equal(parsed.facts.length, 0);
  assert.equal(parsed.rejected[0].reason, "date_out_of_range");
});

Deno.test("parseFacts keeps a new_task with a bad date and nulls the date", () => {
  const parsed = parseFacts(wrap([
    { ...base, type: "new_task", title: "Read chapter 5", kind: "preparation", due_at: "not a date", quote: "read chapter 5" },
  ]), doc);
  assert.equal(parsed.facts.length, 1);
  assert.equal(parsed.facts[0].due_at, null);
  assert.equal(parsed.facts[0].kind, "preparation");
});

Deno.test("parseFacts flags unparseable output and keeps order", () => {
  assert.deepEqual(parseFacts("sorry, no", doc), { facts: [], rejected: [], parseFailed: true });
  const parsed = parseFacts(wrap([
    { ...base, type: "note", target: "m7", title: "n1", quote: "read chapter 5" },
    { ...base, type: "note", target: "a1", title: "n2", quote: "HW3" },
  ]), doc);
  assert.deepEqual(parsed.facts.map((f) => f.title), ["n1", "n2"]);
});
