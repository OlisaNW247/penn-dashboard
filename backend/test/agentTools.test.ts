import { assert, assertEquals } from "jsr:@std/assert@1";
import { decodedSizeOf, decodeBase64, FixtureToolBackend, MAX_FILE_BYTES } from "../supabase/functions/_shared/agentTools.ts";

const NOW = new Date("2026-11-08T12:00:00Z");
const backend = (pageSize = 10) => new FixtureToolBackend(NOW, pageSize);

Deno.test("fixture views: todo, all, prev", async () => {
  const b = backend();
  const titles = async (view: "todo" | "all" | "prev", course?: string) =>
    (await b.listWork("u", view, course, NOW)).map((w) => w.title);
  // Overdue first, then due within 48 hours.
  assertEquals(await titles("todo"), ["Project 1", "Homework 4"]);
  // Future work: Lecture 12 reading (+5d, nothing to submit), Lab 5 (+10d), and Homework 4 (+1d) is still in the future.
  assertEquals(await titles("all"), ["Homework 4", "Lecture 12 reading", "Lab 5 report"]);
  assertEquals(await titles("prev"), ["Homework 3"]);
  assertEquals(await titles("todo", "phys0151"), ["Homework 4"]);
  const noSubmission = (await b.listWork("u", "all", undefined, NOW)).find((w) => w.noSubmission);
  assertEquals(noSubmission?.title, "Lecture 12 reading");
});

Deno.test("fixture views follow the now argument", async () => {
  const b = backend();
  const later = new Date(NOW.getTime() + 4 * 86_400_000);
  const todo = (await b.listWork("u", "todo", undefined, later)).map((w) => w.title);
  assert(todo.includes("Lecture 12 reading"));
});

Deno.test("search excerpts and paging", async () => {
  const b = backend(1);
  const first = await b.searchCourseMaterial("u", "homework", undefined, undefined, 1);
  assertEquals(first.items.length, 1);
  assertEquals(first.hasMore, true);
  assert(first.items[0].excerpt.toLowerCase().includes("homework"));
  const second = await b.searchCourseMaterial("u", "homework", undefined, undefined, 2);
  assertEquals(second.items.length, 1);
  assertEquals(second.page, 2);
  assert(first.items[0].documentId !== second.items[0].documentId);

  const bounded = await backend().searchCourseMaterial("u", "homework", "CIS 2400");
  assertEquals(bounded.items.length, 0);
  const byKind = await backend().searchCourseMaterial("u", "energy", undefined, "ed");
  assertEquals(byKind.items.length, 1);
  assertEquals((await backend().searchCourseMaterial("u", "   ")).items.length, 0);
});

Deno.test("announcements honour the days window", async () => {
  const b = backend();
  assertEquals((await b.getAnnouncements("u", undefined, 14)).items.length, 1);
  assertEquals((await b.getAnnouncements("u", undefined, 1)).items.length, 0);
});

Deno.test("decoded size is known from the length alone", () => {
  assertEquals(decodedSizeOf("AAAA"), 3);
  assertEquals(decodedSizeOf("AAA="), 2);
  assertEquals(decodedSizeOf("AA=="), 1);
  assertEquals(decodedSizeOf("AAA"), null);
  assertEquals(decodedSizeOf(""), null);
  assertEquals(decodedSizeOf("A".repeat(2_097_152)), MAX_FILE_BYTES);
  assert(decodedSizeOf("A".repeat(2_097_156))! > MAX_FILE_BYTES);
  assertEquals(decodeBase64("AA==").byteLength, 1);
});

Deno.test("fixture proposeSubmission decodes, measures and reads back", async () => {
  const b = backend();
  const made = await b.proposeSubmission("u", "c", "Claude", {
    assignmentId: "asg-phys-hw4",
    kind: "file",
    fileBase64: "A".repeat(4096),
    fileName: "x.bin",
    mimeType: "application/octet-stream",
  });
  assertEquals(made.bytes, 3072);
  assert(typeof made.decodeMs === "number");
  assertEquals(await b.draftStatus("u", made.id), { id: made.id, status: "proposed" });
  assertEquals(await b.draftStatus("someone-else", made.id), null);
});

Deno.test("fixture proposeSubmission: at most 20 open drafts per student, a decided one frees a slot", async () => {
  const b = backend();
  const text = { assignmentId: "asg-phys-hw4", kind: "text" as const, body: "x" };
  const first = await b.proposeSubmission("u", "c", "Claude", text);
  for (let i = 1; i < 20; i++) await b.proposeSubmission("u", "c", "Claude", text);
  let refused = "";
  try {
    await b.proposeSubmission("u", "c", "Claude", text);
  } catch (e) {
    refused = (e as Error).name;
  }
  assertEquals(refused, "DraftLimitError");
  // Another student is unaffected.
  await b.proposeSubmission("other", "c", "Claude", text);
  b.drafts.get(first.id)!.status = "declined";
  await b.proposeSubmission("u", "c", "Claude", text);
});
