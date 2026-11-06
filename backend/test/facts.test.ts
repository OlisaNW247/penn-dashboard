import { strict as assert } from "node:assert";
import {
  buildFactsMessages,
  FACTS_INSTRUCTIONS,
  FACTS_JSON_SCHEMA,
  type FactsDocument,
  MAX_FACT_TITLE_CHARS,
  parseFacts,
  resolveDueAt,
  STALE_DOCUMENT_MS,
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

// ---------------------------------------------------------------------
// Hostile input: none of this may throw, and every bad shape must come back
// as a clean rejection or `parseFailed`, never a partial fact.
// ---------------------------------------------------------------------

Deno.test("parseFacts: non-object and wrongly shaped JSON is parseFailed, never a throw", () => {
  for (const text of [
    "", "   ", "null", "true", "42", '"facts"', "[]", "[{}]", "{}", '{"facts":null}', '{"facts":{}}',
    '{"facts":"x"}', '{"facts":42}', "{", '{"facts":[}', "```json\n[]\n```", "```json\n{\"facts\":", "\u0000\u0001",
  ]) {
    const parsed = parseFacts(text, doc);
    assert.equal(parsed.parseFailed, true, `expected parseFailed for ${JSON.stringify(text)}`);
    assert.deepEqual(parsed.facts, []);
  }
});

Deno.test("parseFacts: array entries of the wrong kind are bad_shape rejections", () => {
  const parsed = parseFacts(wrap([null, 1, "x", [], [{}], true, {}, { type: "note" }, { type: 5, quote: "HW3", confidence: "high" }]), doc);
  assert.equal(parsed.parseFailed, false);
  assert.deepEqual(parsed.facts, []);
  assert.equal(parsed.rejected.length, 9);
  assert.ok(parsed.rejected.every((r) => r.reason === "bad_shape"));
});

Deno.test("parseFacts: a field of the wrong type rejects the fact (target, title, due_at, kind, confidence, quote)", () => {
  const ok = { ...base, type: "note", target: "a1", title: "t", quote: "HW3" };
  for (const bad of [
    { target: 5 }, { target: {} }, { target: ["a1"] }, { title: 5 }, { title: {} }, { due_at: 5 }, { due_at: {} },
    { kind: "party" }, { kind: 5 }, { confidence: "low" }, { confidence: 1 }, { confidence: null },
    { quote: 5 }, { quote: "" }, { quote: "   " }, { quote: null },
  ]) {
    const parsed = parseFacts(wrap([{ ...ok, ...bad }]), doc);
    assert.deepEqual(parsed.facts, [], JSON.stringify(bad));
    assert.equal(parsed.rejected.length, 1, JSON.stringify(bad));
  }
});

Deno.test("parseFacts: 10,000 facts do not throw, stay in order, and finish quickly", () => {
  const many = Array.from({ length: 10_000 }, (_, i) => ({
    ...base, type: "note", target: i % 2 === 0 ? "a1" : "nope", title: `n${i}`, quote: "HW3",
  }));
  const started = Date.now();
  const parsed = parseFacts(wrap(many), doc);
  assert.ok(Date.now() - started < 5000, "10k facts took over 5 s");
  assert.equal(parsed.facts.length, 5000);
  assert.equal(parsed.rejected.length, 5000);
  assert.ok(parsed.rejected.every((r) => r.reason === "unknown_target"));
  assert.equal(parsed.facts[0].title, "n0");
  assert.equal(parsed.facts.at(-1)!.title, "n9998");
});

Deno.test("parseFacts: a huge quote or title is handled without throwing", () => {
  const huge = "x".repeat(2_000_000);
  const parsed = parseFacts(wrap([{ ...base, type: "new_task", title: huge, quote: huge }]), doc);
  assert.deepEqual(parsed.facts, []);
  assert.equal(parsed.rejected[0].reason, "quote_not_in_text");
});

Deno.test("parseFacts: Unicode form, curly quotes, dashes and NBSP are folded on both sides, and the stored quote is as emitted", () => {
  const nfc = "Caf\u00e9 quiz is cancelled";
  const d: FactsDocument = { ...doc, text: `${nfc}. Don't forget the \u201cfinal\u201d \u2013 bring\u00a0ID.` };
  const nfd = nfc.normalize("NFD");
  assert.notEqual(nfd, nfc);
  const kept = [
    nfc,
    nfd,
    "Don\u2019t forget the \u201cfinal",
    "Don't forget the \"final\"",
    "Don't forget the \u201cfinal\u201d",
    "the \"final\" - bring ID",
    "the \u201cfinal\u201d \u2014 bring ID",
  ];
  for (const quote of kept) {
    const parsed = parseFacts(wrap([{ ...base, type: "needs_review", quote }]), d);
    assert.equal(parsed.facts.length, 1, quote);
    assert.equal(parsed.facts[0].quote, quote, "the quote is stored as the model emitted it");
  }
});

Deno.test("parseFacts: a curly-quote quote matches straight-quote text, and a quote still fails when a word differs", () => {
  const d: FactsDocument = { ...doc, text: "Don't forget: it's \"open book\"." };
  const match = parseFacts(wrap([{ ...base, type: "needs_review", quote: "it\u2019s \u201copen book\u201d" }]), d);
  assert.equal(match.facts.length, 1);
  assert.equal(match.facts[0].quote, "it\u2019s \u201copen book\u201d");
  for (const quote of ["it\u2019s \u201cclosed book\u201d", "it\u2019s open book today", "Caf\u00e9"]) {
    const parsed = parseFacts(wrap([{ ...base, type: "needs_review", quote }]), d);
    assert.deepEqual(parsed.facts, [], quote);
    assert.equal(parsed.rejected[0].reason, "quote_not_in_text");
  }
});

Deno.test("parseFacts: targets that merely share a prefix with a real sourceID are unknown_target", () => {
  const d: FactsDocument = {
    ...doc,
    index: [
      { sourceID: "a1", title: "HW3", kind: "assignment" },
      { sourceID: "a10", title: "HW4", kind: "assignment" },
      { sourceID: "module:7", title: "Week 7", kind: "module_item" },
    ],
  };
  for (const target of ["a", "a1 ", " a1", "A1", "a100", "a1/", "module:", "module:70", "module", "a1\u0000", ""]) {
    const parsed = parseFacts(wrap([{ ...base, type: "cancel", target, quote: "HW3" }]), d);
    assert.deepEqual(parsed.facts, [], JSON.stringify(target));
    // An empty-string target is not null, so it is unknown rather than missing.
    assert.equal(parsed.rejected[0].reason, "unknown_target", JSON.stringify(target));
  }
  for (const target of ["a1", "a10", "module:7"]) {
    assert.equal(parseFacts(wrap([{ ...base, type: "cancel", target, quote: "HW3" }]), d).facts.length, 1);
  }
});

Deno.test("parseFacts: extra keys such as seq, as string, float or negative, are ignored and never copied", () => {
  for (const seq of ["7", 1.5, -3, null, {}, [1]]) {
    const parsed = parseFacts(wrap([{ ...base, type: "note", target: "a1", title: "n", quote: "HW3", seq, id: 9 }]), doc);
    assert.equal(parsed.facts.length, 1);
    assert.deepEqual(Object.keys(parsed.facts[0]).sort(), ["confidence", "due_at", "quote", "target", "title", "type"]);
  }
});

Deno.test("parseFacts: due_at in 1900 or 9999 or unparseable is dropped for new_task, and rejects a reschedule", () => {
  const dates = ["1900-01-01T00:00:00Z", "9999-12-31T23:59:59Z", "+275760-09-13T00:00:00.000Z", "10000-01-01", "-000001-01-01T00:00:00Z", "0000-00-00", "Friday", "2026-13-45T99:99:99Z", ""];
  for (const due_at of dates) {
    const task = parseFacts(wrap([{ ...base, type: "new_task", title: "Read", kind: "preparation", due_at, quote: "read chapter 5" }]), doc);
    assert.equal(task.facts.length, 1, due_at);
    assert.equal(task.facts[0].due_at, null, due_at);
    const move = parseFacts(wrap([{ ...base, type: "reschedule", target: "a1", due_at, quote: "HW3" }]), doc);
    assert.deepEqual(move.facts, [], due_at);
    assert.equal(move.rejected[0].reason, "date_out_of_range", due_at);
  }
});

Deno.test("parseFacts: an unparseable `now` disables the range check instead of throwing", () => {
  const d: FactsDocument = { ...doc, now: "not a date" };
  const parsed = parseFacts(wrap([{ ...base, type: "reschedule", target: "a1", due_at: "2031-01-01T00:00:00Z", quote: "HW3" }]), d);
  assert.equal(parsed.facts.length, 1);
});

Deno.test("FACTS_INSTRUCTIONS carries the stale-document paragraph", () => {
  for (const phrase of [
    "The ITEM INDEX is Canvas as of the current date.",
    "more than 7 days before the current date",
    "emit no reschedule and no needs_review about that item's date",
    "a cancel still applies when the index still holds the item",
    "emit no new_task for it",
  ]) {
    assert.ok(FACTS_INSTRUCTIONS.includes(phrase), `missing "${phrase}"`);
  }
  assert.equal(STALE_DOCUMENT_MS, 7 * 24 * 60 * 60 * 1000);
});

Deno.test("parseFacts rejects a new_task whose date is already past", () => {
  // doc.now is 2026-11-05T23:35Z.
  const parsed = parseFacts(wrap([
    { ...base, type: "new_task", title: "Quiz 2", due_at: "2026-09-23T13:45:00-04:00", quote: "read chapter 5" },
  ]), doc);
  assert.equal(parsed.facts.length, 0);
  assert.equal(parsed.rejected[0].reason, "due_in_past");
});

Deno.test("parseFacts keeps a new_task due in the future", () => {
  const parsed = parseFacts(wrap([
    { ...base, type: "new_task", title: "Quiz 2", due_at: "2026-11-12T13:45:00-05:00", quote: "read chapter 5" },
  ]), doc);
  assert.equal(parsed.facts.length, 1);
  assert.equal(parsed.rejected.length, 0);
});

Deno.test("parseFacts rejects a reschedule from a 30-day-old document", () => {
  const old = { ...doc, postedAt: "2026-10-06T23:30:00Z" };
  const parsed = parseFacts(wrap([
    { ...base, type: "reschedule", target: "a1", due_at: "2026-11-06T23:59:00Z", quote: "HW3 is now due Friday" },
  ]), old);
  assert.equal(parsed.facts.length, 0);
  assert.equal(parsed.rejected[0].reason, "stale_document");
});

Deno.test("parseFacts keeps a reschedule from a 2-day-old document", () => {
  const recent = { ...doc, postedAt: "2026-11-03T23:30:00Z" };
  const parsed = parseFacts(wrap([
    { ...base, type: "reschedule", target: "a1", due_at: "2026-11-06T23:59:00Z", quote: "HW3 is now due Friday" },
  ]), recent);
  assert.equal(parsed.facts.length, 1);
});

Deno.test("parseFacts keeps a reschedule from a document with no postedAt", () => {
  const undated = { ...doc, postedAt: undefined };
  const parsed = parseFacts(wrap([
    { ...base, type: "reschedule", target: "a1", due_at: "2026-11-06T23:59:00Z", quote: "HW3 is now due Friday" },
  ]), undated);
  assert.equal(parsed.facts.length, 1);
});

Deno.test("parseFacts keeps a new_task due 23:59 today in the document's zone", () => {
  // 09:00 New York on 2026-11-05; 23:59 that evening is later today.
  const d = { ...doc, now: "2026-11-05T14:00:00Z" };
  const parsed = parseFacts(wrap([
    { ...base, type: "new_task", title: "Quiz 2", due_at: "2026-11-05T23:59:00-05:00", quote: "read chapter 5" },
  ]), d);
  assert.equal(parsed.facts.length, 1);
});

Deno.test("parseFacts keeps a new_task whose date-only due_at is today", () => {
  // Parses as UTC midnight, before `now`, but is still today in New York.
  const d = { ...doc, now: "2026-11-05T14:00:00Z" };
  const parsed = parseFacts(wrap([
    { ...base, type: "new_task", title: "Quiz 2", due_at: "2026-11-05", quote: "read chapter 5" },
  ]), d);
  assert.equal(parsed.facts.length, 1);
});

Deno.test("parseFacts rejects a new_task due yesterday in the document's zone", () => {
  const d = { ...doc, now: "2026-11-05T14:00:00Z" };
  const parsed = parseFacts(wrap([
    { ...base, type: "new_task", title: "Quiz 2", due_at: "2026-11-04T23:59:00-05:00", quote: "read chapter 5" },
  ]), d);
  assert.equal(parsed.facts.length, 0);
  assert.equal(parsed.rejected[0].reason, "due_in_past");
});

// --- offset-less dates are the document's local time ---------------------

Deno.test("resolveDueAt: offset-less strings are local to the zone, offsets are kept as written", () => {
  // November 10 is EST (UTC-5); a date-only value is 23:59 local that day.
  assert.equal(resolveDueAt("2026-11-10", "America/New_York"), "2026-11-11T04:59:00.000Z");
  assert.equal(resolveDueAt("2026-11-10T23:59", "America/New_York"), "2026-11-11T04:59:00.000Z");
  assert.equal(resolveDueAt("2026-11-10T09:30:15", "America/New_York"), "2026-11-10T14:30:15.000Z");
  // Summer (EDT, UTC-4) and a zone east of UTC.
  assert.equal(resolveDueAt("2026-06-10T12:00", "America/New_York"), "2026-06-10T16:00:00.000Z");
  assert.equal(resolveDueAt("2026-11-10T08:00", "Europe/Paris"), "2026-11-10T07:00:00.000Z");
  // Already absolute: returned unchanged.
  assert.equal(resolveDueAt("2026-11-10T23:59:00Z", "America/New_York"), "2026-11-10T23:59:00Z");
  assert.equal(resolveDueAt("2026-11-10T23:59:00-05:00", "Asia/Tokyo"), "2026-11-10T23:59:00-05:00");
  // Garbage, impossible dates, and an unusable zone (falls back to UTC).
  assert.equal(resolveDueAt("next friday", "America/New_York"), undefined);
  assert.equal(resolveDueAt("2026-02-30", "America/New_York"), undefined);
  assert.equal(resolveDueAt("2026-11-10T25:00", "America/New_York"), undefined);
  assert.equal(resolveDueAt("2026-11-10T12:00", "Not/AZone"), "2026-11-10T12:00:00.000Z");
});

Deno.test("resolveDueAt: the offset is right on either side of the fall-back DST change", () => {
  assert.equal(resolveDueAt("2026-11-01T12:00", "America/New_York"), "2026-11-01T17:00:00.000Z");
  assert.equal(resolveDueAt("2026-10-31T12:00", "America/New_York"), "2026-10-31T16:00:00.000Z");
});

Deno.test("parseFacts: a date-only or offset-less due_at is stored as the zone's instant, not UTC", () => {
  const parsed = parseFacts(wrap([
    { ...base, type: "new_task", title: "Problem set", due_at: "2026-11-10", kind: "submission", quote: "read chapter 5" },
    { ...base, type: "reschedule", target: "a1", due_at: "2026-11-10T23:59", quote: "HW3 is now due Friday" },
  ]), doc);
  assert.equal(parsed.rejected.length, 0);
  assert.equal(parsed.facts[0].due_at, "2026-11-11T04:59:00.000Z");
  assert.equal(parsed.facts[1].due_at, "2026-11-11T04:59:00.000Z");
});

Deno.test("parseFacts: a date-only due_at for today in the zone is still live, an offset one is untouched", () => {
  const parsed = parseFacts(wrap([
    { ...base, type: "new_task", title: "Today", due_at: "2026-11-05", quote: "read chapter 5" },
    { ...base, type: "new_task", title: "Kept", due_at: "2026-11-10T23:59:00-05:00", quote: "read chapter 5" },
  ]), doc);
  assert.equal(parsed.facts.length, 2);
  assert.equal(parsed.facts[1].due_at, "2026-11-10T23:59:00-05:00");
});

// --- reschedule needs a date; titles are capped; note/scope need a title --

Deno.test("parseFacts rejects a reschedule with no due date as due_required", () => {
  const parsed = parseFacts(wrap([
    { ...base, type: "reschedule", target: "a1", due_at: null, quote: "HW3 is now due Friday" },
    { ...base, type: "reschedule", target: "a1", quote: "HW3 is now due Friday" },
  ]), doc);
  assert.equal(parsed.facts.length, 0);
  assert.deepEqual(parsed.rejected.map((r) => r.reason), ["due_required", "due_required"]);
});

Deno.test("parseFacts trims a title and caps it at MAX_FACT_TITLE_CHARS without rejecting", () => {
  const long = "x".repeat(MAX_FACT_TITLE_CHARS + 50);
  const parsed = parseFacts(wrap([
    { ...base, type: "new_task", title: `  ${long}  `, quote: "read chapter 5" },
    { ...base, type: "note", target: "a1", title: "  covers ch 5  ", quote: "read chapter 5" },
  ]), doc);
  assert.equal(parsed.rejected.length, 0);
  assert.equal(parsed.facts[0].title, "x".repeat(MAX_FACT_TITLE_CHARS));
  assert.equal(parsed.facts[1].title, "covers ch 5");
});

Deno.test("parseFacts: note and scope_change need a title, needs_review does not", () => {
  const parsed = parseFacts(wrap([
    { ...base, type: "note", target: "a1", quote: "read chapter 5" },
    { ...base, type: "scope_change", target: "a1", title: "   ", quote: "read chapter 5" },
    { ...base, type: "needs_review", target: "a1", title: "   ", quote: "read chapter 5" },
  ]), doc);
  assert.deepEqual(parsed.rejected.map((r) => r.reason), ["title_required", "title_required"]);
  assert.equal(parsed.facts.length, 1);
  assert.equal(parsed.facts[0].type, "needs_review");
  assert.equal(parsed.facts[0].title, undefined, "a blank title is left off, not stored empty");
});
