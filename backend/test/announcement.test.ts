import { strict as assert } from "node:assert";
import {
  ANNOUNCEMENT_INSTRUCTIONS,
  buildAnnouncementUserContent,
  parseAssignments,
} from "../supabase/functions/_shared/announcement.ts";

const NOW = new Date("2026-09-07T12:00:00.000Z");

Deno.test("buildAnnouncementUserContent includes course, title and current date lines", () => {
  const content = buildAnnouncementUserContent({
    courseCode: "PHYS 0151",
    title: "Midterm reminder",
    message: "Read chapter 4 before Friday.",
    now: "2026-09-07T12:00:00.000Z",
  });
  assert.equal(
    content,
    [
      "Course: PHYS 0151",
      "Announcement title: Midterm reminder",
      "Current date: 2026-09-07T12:00:00.000Z",
      "",
      "Read chapter 4 before Friday.",
    ].join("\n"),
  );
});

Deno.test("buildAnnouncementUserContent includes Posted at only when provided", () => {
  const withPosted = buildAnnouncementUserContent({
    courseCode: "PHYS 0151",
    title: "t",
    message: "m",
    postedAt: "2026-09-01T00:00:00.000Z",
    now: "2026-09-07T12:00:00.000Z",
  });
  assert.ok(withPosted.includes("Posted at: 2026-09-01T00:00:00.000Z"));

  const withoutPosted = buildAnnouncementUserContent({
    courseCode: "PHYS 0151",
    title: "t",
    message: "m",
    now: "2026-09-07T12:00:00.000Z",
  });
  assert.ok(!withoutPosted.includes("Posted at:"));
});

Deno.test("buildAnnouncementUserContent caps the message body at 4000 characters", () => {
  const content = buildAnnouncementUserContent({
    courseCode: "PHYS 0151",
    title: "t",
    message: "m".repeat(5000),
    now: "2026-09-07T12:00:00.000Z",
  });
  const body = content.split("\n").pop()!;
  assert.equal(body.length, 4000);
});

Deno.test("parseAssignments reads title and dueAt from a well-formed response", () => {
  const text = JSON.stringify({
    assignments: [{ title: "Read chapter 4", dueAt: "2026-09-12T00:00:00.000Z" }],
  });
  assert.deepEqual(parseAssignments(text, NOW), [
    { title: "Read chapter 4", dueAt: "2026-09-12T00:00:00.000Z" },
  ]);
});

Deno.test("parseAssignments strips a fenced ```json block", () => {
  const text = "```json\n" + JSON.stringify({ assignments: [{ title: "Submit lab" }] }) + "\n```";
  assert.deepEqual(parseAssignments(text, NOW), [{ title: "Submit lab" }]);
});

Deno.test("parseAssignments keeps a title-only task when dueAt is null", () => {
  const text = JSON.stringify({ assignments: [{ title: "Read chapter 4", dueAt: null }] });
  assert.deepEqual(parseAssignments(text, NOW), [{ title: "Read chapter 4" }]);
});

Deno.test("parseAssignments drops a dueAt more than 400 days in the future", () => {
  const farFuture = new Date(NOW.getTime() + 401 * 24 * 60 * 60 * 1000).toISOString();
  const text = JSON.stringify({ assignments: [{ title: "Read chapter 4", dueAt: farFuture }] });
  assert.deepEqual(parseAssignments(text, NOW), [{ title: "Read chapter 4" }]);
});

Deno.test("parseAssignments drops a dueAt more than 400 days in the past", () => {
  const farPast = new Date(NOW.getTime() - 401 * 24 * 60 * 60 * 1000).toISOString();
  const text = JSON.stringify({ assignments: [{ title: "Old task", dueAt: farPast }] });
  assert.deepEqual(parseAssignments(text, NOW), [{ title: "Old task" }]);
});

Deno.test("parseAssignments keeps a dueAt exactly 399 days out", () => {
  const nearFuture = new Date(NOW.getTime() + 399 * 24 * 60 * 60 * 1000).toISOString();
  const text = JSON.stringify({ assignments: [{ title: "Read chapter 4", dueAt: nearFuture }] });
  assert.deepEqual(parseAssignments(text, NOW), [{ title: "Read chapter 4", dueAt: nearFuture }]);
});

Deno.test("parseAssignments drops an unparseable dueAt string but keeps the title", () => {
  const text = JSON.stringify({ assignments: [{ title: "Read chapter 4", dueAt: "not-a-date" }] });
  assert.deepEqual(parseAssignments(text, NOW), [{ title: "Read chapter 4" }]);
});

Deno.test("parseAssignments drops an entry with no title", () => {
  const text = JSON.stringify({ assignments: [{ dueAt: "2026-09-12T00:00:00.000Z" }] });
  assert.deepEqual(parseAssignments(text, NOW), []);
});

Deno.test("parseAssignments returns an empty list for purely informational announcements", () => {
  assert.deepEqual(parseAssignments(JSON.stringify({ assignments: [] }), NOW), []);
});

Deno.test("parseAssignments returns an empty list for unparseable text instead of throwing", () => {
  assert.deepEqual(parseAssignments("not json", NOW), []);
});

Deno.test("ANNOUNCEMENT_INSTRUCTIONS demands JSON-only output", () => {
  assert.ok(ANNOUNCEMENT_INSTRUCTIONS.toLowerCase().includes("json"));
  assert.ok(ANNOUNCEMENT_INSTRUCTIONS.includes("assignments"));
});
