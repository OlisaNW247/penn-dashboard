import { strict as assert } from "node:assert";
import { buildMessages, SYSTEM_INSTRUCTIONS } from "../supabase/functions/_shared/prompt.ts";
import type { CatalogCourseRow } from "../supabase/functions/_shared/catalog.ts";

const BASE_INPUT = {
  contextDocument: "PHYS 0151 syllabus text here.",
  catalog: [] as CatalogCourseRow[],
  profiles: { "phys-151": { latePolicy: "24 hour grace" } },
  history: [] as { role: "user" | "assistant"; content: string }[],
  excerpts: "",
  question: "When is the midterm?",
  askedAt: "2026-09-07T12:00:00.000Z",
};

const PHYS_CATALOG_ROW: CatalogCourseRow = {
  catalogCode: "PHYS-0151",
  semester: "2026C",
  title: "Principles II",
  description: "Electric and magnetic fields.",
  credits: 1.5,
  prerequisites: "",
  crosslistings: [],
  gradeModes: [],
  attributes: [],
  components: [
    { activity: "LEC", label: "Lecture", sectionCount: 2, credits: 1.5, sectionIDs: ["a", "b"], meetings: [] },
    { activity: "LAB", label: "Lab", sectionCount: 3, credits: null, sectionIDs: ["c", "d", "e"], meetings: [] },
  ],
  source: "penn-labs",
  fetchedAt: "2026-09-07T00:00:00Z",
};

Deno.test("buildMessages orders: instructions, context document, profiles, history, user turn (no catalog)", () => {
  const history = [
    { role: "user" as const, content: "hi" },
    { role: "assistant" as const, content: "hello" },
  ];
  const messages = buildMessages({ ...BASE_INPUT, history });

  assert.equal(messages[0].role, "system");
  assert.equal(messages[0].content, SYSTEM_INSTRUCTIONS);

  assert.equal(messages[1].role, "system");
  assert.equal(messages[1].content, BASE_INPUT.contextDocument);

  assert.equal(messages[2].role, "system");
  assert.ok(messages[2].content.startsWith("COURSE PROFILES (extracted from syllabi):\n"));

  assert.equal(messages[3].role, "user");
  assert.equal(messages[3].content, "hi");
  assert.equal(messages[4].role, "assistant");
  assert.equal(messages[4].content, "hello");

  const last = messages[messages.length - 1];
  assert.equal(last.role, "user");
  assert.ok(last.content.startsWith("Current date: 2026-09-07T12:00:00.000Z"));
  assert.ok(last.content.includes("QUESTION: When is the midterm?"));
});

Deno.test("buildMessages omits the COURSE STRUCTURE block when catalog is empty", () => {
  const messages = buildMessages(BASE_INPUT);
  assert.equal(messages.length, 4); // instructions, context, profiles, user turn
  assert.ok(!messages.some((m) => m.content.startsWith("COURSE STRUCTURE")));
});

Deno.test("buildMessages inserts COURSE STRUCTURE after the context document and before COURSE PROFILES", () => {
  const messages = buildMessages({ ...BASE_INPUT, catalog: [PHYS_CATALOG_ROW] });

  assert.equal(messages[0].content, SYSTEM_INSTRUCTIONS);
  assert.equal(messages[1].content, BASE_INPUT.contextDocument);

  assert.equal(messages[2].role, "system");
  assert.ok(messages[2].content.startsWith("COURSE STRUCTURE (from the Penn registrar via Penn Labs):\n"));
  assert.ok(messages[2].content.includes("PHYS-0151"));
  assert.ok(messages[2].content.includes("Lecture (2 sections)"));

  assert.equal(messages[3].role, "system");
  assert.ok(messages[3].content.startsWith("COURSE PROFILES (extracted from syllabi):\n"));
});

Deno.test("buildMessages's COURSE STRUCTURE block is byte-stable for identical input, called twice", () => {
  const input = { ...BASE_INPUT, catalog: [PHYS_CATALOG_ROW] };
  const first = buildMessages(input)[2].content;
  const second = buildMessages(input)[2].content;
  assert.equal(first, second);
});

Deno.test("buildMessages omits the excerpts block from the user turn when excerpts is empty", () => {
  const messages = buildMessages({ ...BASE_INPUT, excerpts: "" });
  const last = messages[messages.length - 1];
  assert.equal(
    last.content,
    "Current date: 2026-09-07T12:00:00.000Z\n\nQUESTION: When is the midterm?",
  );
});

Deno.test("buildMessages includes the excerpts block ahead of QUESTION: when non-empty", () => {
  const excerpts = "RETRIEVED EXCERPTS (from the student's synced course materials):\n[1] PHYS 0151 · syllabus · \"Grading\": ...";
  const messages = buildMessages({ ...BASE_INPUT, excerpts });
  const last = messages[messages.length - 1];
  assert.equal(
    last.content,
    `Current date: 2026-09-07T12:00:00.000Z\n\n${excerpts}\n\nQUESTION: When is the midterm?`,
  );
});

Deno.test("buildMessages is byte-stable for identical input, called twice", () => {
  const first = JSON.stringify(buildMessages(BASE_INPUT));
  const second = JSON.stringify(buildMessages(BASE_INPUT));
  assert.equal(first, second);
});

Deno.test("buildMessages sorts course-profile object keys regardless of input order", () => {
  const profilesA = { b: { z: 1, a: 2 }, a: { latePolicy: "x" } };
  const profilesB = { a: { latePolicy: "x" }, b: { a: 2, z: 1 } };
  const messagesA = buildMessages({ ...BASE_INPUT, profiles: profilesA });
  const messagesB = buildMessages({ ...BASE_INPUT, profiles: profilesB });
  assert.equal(messagesA[2].content, messagesB[2].content);
});

Deno.test("buildMessages caps the question at 2000 characters", () => {
  const longQuestion = "q".repeat(3000);
  const messages = buildMessages({ ...BASE_INPUT, question: longQuestion });
  const last = messages[messages.length - 1];
  const questionPart = last.content.slice(last.content.indexOf("QUESTION: ") + "QUESTION: ".length);
  assert.equal(questionPart.length, 2000);
});

Deno.test("buildMessages caps history to the last 10 turns", () => {
  const history = Array.from({ length: 15 }, (_, i) => ({
    role: (i % 2 === 0 ? "user" : "assistant") as "user" | "assistant",
    content: `turn-${i}`,
  }));
  const messages = buildMessages({ ...BASE_INPUT, history });
  // messages[0..2] are the three system blocks, the last message is the
  // user turn -- everything between is history.
  const historyMessages = messages.slice(3, messages.length - 1);
  assert.equal(historyMessages.length, 10);
  assert.equal(historyMessages[0].content, "turn-5");
  assert.equal(historyMessages[historyMessages.length - 1].content, "turn-14");
});

Deno.test("buildMessages drops oldest history turns to stay within the 8000 char budget", () => {
  const history = [
    { role: "user" as const, content: "a".repeat(4000) },
    { role: "assistant" as const, content: "b".repeat(4000) },
    { role: "user" as const, content: "c".repeat(4000) },
  ];
  const messages = buildMessages({ ...BASE_INPUT, history });
  const historyMessages = messages.slice(3, messages.length - 1);
  // The oldest ("a") turn should have been dropped to fit under 8000 chars
  // total, leaving the two most recent turns (8000 chars exactly).
  assert.equal(historyMessages.length, 2);
  assert.equal(historyMessages[0].content, "b".repeat(4000));
  assert.equal(historyMessages[1].content, "c".repeat(4000));
});

Deno.test("buildMessages keeps at least the most recent turn even if it alone exceeds the char budget", () => {
  const history = [{ role: "user" as const, content: "x".repeat(9000) }];
  const messages = buildMessages({ ...BASE_INPUT, history });
  const historyMessages = messages.slice(3, messages.length - 1);
  assert.equal(historyMessages.length, 1);
  assert.equal(historyMessages[0].content.length, 9000);
});

Deno.test("SYSTEM_INSTRUCTIONS keeps the exact <sources> trailer contract the app parses", () => {
  assert.ok(SYSTEM_INSTRUCTIONS.includes("<sources>COURSE|kind|detail; COURSE|kind|detail</sources>"));
  assert.ok(SYSTEM_INSTRUCTIONS.includes("syllabus, canvas, website, or announcement"));
});

Deno.test("SYSTEM_INSTRUCTIONS explains the [website] excerpt label", () => {
  assert.ok(SYSTEM_INSTRUCTIONS.includes("[website]"));
  assert.ok(SYSTEM_INSTRUCTIONS.includes("as authoritative as the syllabus"));
});
