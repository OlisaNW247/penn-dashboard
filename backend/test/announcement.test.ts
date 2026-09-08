import { strict as assert } from "node:assert";
import {
  ANNOUNCEMENT_INSTRUCTIONS,
  buildAnnouncementUserContent,
  classMeetingsBlock,
  courseCodesMatch,
  courseProfileBlock,
  parseAssignments,
} from "../supabase/functions/_shared/announcement.ts";
import type { CatalogCourseRow } from "../supabase/functions/_shared/catalog.ts";

const NOW = new Date("2026-09-07T12:00:00.000Z");

const PHYS_CATALOG: CatalogCourseRow = {
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
    {
      activity: "LEC",
      label: "Lecture",
      sectionCount: 1,
      credits: 1.5,
      sectionIDs: ["PHYS-0151-401"],
      meetings: [
        { sectionID: "PHYS-0151-401", weekday: 3, startMinutes: 10 * 60 + 15, endMinutes: 11 * 60 + 44 },
      ],
    },
    {
      activity: "LAB",
      label: "Lab",
      sectionCount: 1,
      credits: 0,
      sectionIDs: ["PHYS-0151-151"],
      meetings: [
        { sectionID: "PHYS-0151-151", weekday: 2, startMinutes: 15 * 60 + 30, endMinutes: 17 * 60 + 29 },
      ],
    },
  ],
  source: "penn-labs",
  fetchedAt: "2026-09-07T00:00:00Z",
};

const PHYS_CATALOG_NO_MEETINGS: CatalogCourseRow = {
  ...PHYS_CATALOG,
  components: [
    { activity: "LEC", label: "Lecture", sectionCount: 1, credits: 1.5, sectionIDs: ["PHYS-0151-401"], meetings: [] },
  ],
};

// ---------------------------------------------------------------------
// buildAnnouncementUserContent -- base lines (unchanged behavior)
// ---------------------------------------------------------------------

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

// ---------------------------------------------------------------------
// buildAnnouncementUserContent -- COURSE STRUCTURE / CLASS MEETINGS /
// COURSE PROFILE context blocks
// ---------------------------------------------------------------------

Deno.test("buildAnnouncementUserContent includes COURSE STRUCTURE when a catalog row is given", () => {
  const content = buildAnnouncementUserContent({
    courseCode: "PHYS 0151",
    title: "t",
    message: "m",
    now: "2026-09-07T12:00:00.000Z",
    catalog: PHYS_CATALOG,
  });
  assert.ok(content.includes("COURSE STRUCTURE (from the Penn registrar via Penn Labs):"));
  assert.ok(content.includes('PHYS-0151 "Principles II"'));
});

Deno.test("buildAnnouncementUserContent omits COURSE STRUCTURE and CLASS MEETINGS when no catalog is given", () => {
  const content = buildAnnouncementUserContent({
    courseCode: "PHYS 0151",
    title: "t",
    message: "m",
    now: "2026-09-07T12:00:00.000Z",
  });
  assert.ok(!content.includes("COURSE STRUCTURE"));
  assert.ok(!content.includes("CLASS MEETINGS"));
});

Deno.test("buildAnnouncementUserContent includes CLASS MEETINGS with weekday-formatted, sorted lines", () => {
  const content = buildAnnouncementUserContent({
    courseCode: "PHYS 0151",
    title: "t",
    message: "m",
    now: "2026-09-07T12:00:00.000Z",
    catalog: PHYS_CATALOG,
  });
  assert.ok(content.includes("CLASS MEETINGS:"));
  // LAB (Monday) sorts before LEC (Tuesday).
  const labIndex = content.indexOf("LAB Mon 15:30");
  const lecIndex = content.indexOf("LEC Tue 10:15");
  assert.ok(labIndex >= 0 && lecIndex >= 0 && labIndex < lecIndex, content);
  assert.ok(content.includes("(section 401)"));
  assert.ok(content.includes("(section 151)"));
});

Deno.test("buildAnnouncementUserContent omits CLASS MEETINGS when the catalog row has no meetings", () => {
  const content = buildAnnouncementUserContent({
    courseCode: "PHYS 0151",
    title: "t",
    message: "m",
    now: "2026-09-07T12:00:00.000Z",
    catalog: PHYS_CATALOG_NO_MEETINGS,
  });
  assert.ok(content.includes("COURSE STRUCTURE"));
  assert.ok(!content.includes("CLASS MEETINGS"));
});

Deno.test("buildAnnouncementUserContent includes COURSE PROFILE with only the four permitted keys", () => {
  const content = buildAnnouncementUserContent({
    courseCode: "PHYS 0151",
    title: "t",
    message: "m",
    now: "2026-09-07T12:00:00.000Z",
    profile: {
      gradingWeights: [{ name: "Homework", percent: 20 }],
      latePolicy: "24 hour grace",
      examDates: [{ name: "Midterm", text: "in class" }],
      officeHours: [{ who: "Prof", when: "Mon 2-3" }],
    },
  });
  assert.ok(content.includes("COURSE PROFILE (extracted from the syllabus):"));
  assert.ok(content.includes("gradingWeights"));
  assert.ok(content.includes("latePolicy"));
  assert.ok(!content.includes("examDates"));
  assert.ok(!content.includes("officeHours"));
});

Deno.test("buildAnnouncementUserContent omits COURSE PROFILE when the profile has none of the four keys", () => {
  const content = buildAnnouncementUserContent({
    courseCode: "PHYS 0151",
    title: "t",
    message: "m",
    now: "2026-09-07T12:00:00.000Z",
    profile: { examDates: [{ name: "Midterm", text: "in class" }] },
  });
  assert.ok(!content.includes("COURSE PROFILE"));
});

Deno.test("buildAnnouncementUserContent orders STRUCTURE before MEETINGS before PROFILE, all present", () => {
  const content = buildAnnouncementUserContent({
    courseCode: "PHYS 0151",
    title: "t",
    message: "m",
    now: "2026-09-07T12:00:00.000Z",
    catalog: PHYS_CATALOG,
    profile: { latePolicy: "24 hour grace" },
  });
  const structureIndex = content.indexOf("COURSE STRUCTURE");
  const meetingsIndex = content.indexOf("CLASS MEETINGS");
  const profileIndex = content.indexOf("COURSE PROFILE");
  assert.ok(structureIndex >= 0 && meetingsIndex >= 0 && profileIndex >= 0, content);
  assert.ok(structureIndex < meetingsIndex && meetingsIndex < profileIndex, content);
});

Deno.test("buildAnnouncementUserContent is byte-stable for identical input with full context, called twice", () => {
  const input = {
    courseCode: "PHYS 0151",
    title: "t",
    message: "m",
    now: "2026-09-07T12:00:00.000Z",
    catalog: PHYS_CATALOG,
    profile: { latePolicy: "24 hour grace" },
  };
  assert.equal(buildAnnouncementUserContent(input), buildAnnouncementUserContent(input));
});

// ---------------------------------------------------------------------
// classMeetingsBlock
// ---------------------------------------------------------------------

Deno.test("classMeetingsBlock: empty string when catalog is undefined", () => {
  assert.equal(classMeetingsBlock(undefined), "");
});

Deno.test("classMeetingsBlock: empty string when the catalog row has no meetings", () => {
  assert.equal(classMeetingsBlock(PHYS_CATALOG_NO_MEETINGS), "");
});

Deno.test("classMeetingsBlock: formats every weekday abbreviation correctly", () => {
  const row: CatalogCourseRow = {
    ...PHYS_CATALOG,
    components: [
      {
        activity: "LEC",
        label: "Lecture",
        sectionCount: 1,
        credits: null,
        sectionIDs: ["X-1"],
        meetings: [
          { sectionID: "X-1", weekday: 1, startMinutes: 600, endMinutes: 660 },
          { sectionID: "X-1", weekday: 2, startMinutes: 600, endMinutes: 660 },
          { sectionID: "X-1", weekday: 3, startMinutes: 600, endMinutes: 660 },
          { sectionID: "X-1", weekday: 4, startMinutes: 600, endMinutes: 660 },
          { sectionID: "X-1", weekday: 5, startMinutes: 600, endMinutes: 660 },
          { sectionID: "X-1", weekday: 6, startMinutes: 600, endMinutes: 660 },
          { sectionID: "X-1", weekday: 7, startMinutes: 600, endMinutes: 660 },
        ],
      },
    ],
  };
  const lines = classMeetingsBlock(row).split("\n");
  assert.deepEqual(
    lines.map((line) => line.split(" ")[1]),
    ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"],
  );
});

// ---------------------------------------------------------------------
// courseProfileBlock
// ---------------------------------------------------------------------

Deno.test("courseProfileBlock: empty string for undefined/non-object/array input", () => {
  assert.equal(courseProfileBlock(undefined), "");
  assert.equal(courseProfileBlock(null), "");
  assert.equal(courseProfileBlock("late policy is 24h"), "");
  assert.equal(courseProfileBlock([{ latePolicy: "x" }]), "");
});

Deno.test("courseProfileBlock: keeps only gradingWeights, latePolicy, components, keyPolicies", () => {
  const block = courseProfileBlock({
    gradingWeights: [{ name: "HW", percent: 20 }],
    latePolicy: "24h grace",
    components: [{ name: "Lab" }],
    keyPolicies: [{ topic: "Attendance", text: "..." }],
    examDates: [{ name: "Final", text: "TBD" }],
    contacts: [{ name: "TA" }],
  });
  assert.ok(block.includes("gradingWeights"));
  assert.ok(block.includes("latePolicy"));
  assert.ok(block.includes("components"));
  assert.ok(block.includes("keyPolicies"));
  assert.ok(!block.includes("examDates"));
  assert.ok(!block.includes("contacts"));
});

// ---------------------------------------------------------------------
// courseCodesMatch
// ---------------------------------------------------------------------

Deno.test("courseCodesMatch: matches regardless of case, spacing and dash", () => {
  assert.ok(courseCodesMatch("PHYS 0151", "phys-0151"));
  assert.ok(courseCodesMatch("PHYS  0151", "PHYS0151"));
});

Deno.test("courseCodesMatch: does not match a different course, and two empty codes never match", () => {
  assert.ok(!courseCodesMatch("PHYS 0151", "CIS 1200"));
  assert.ok(!courseCodesMatch("", ""));
});

// ---------------------------------------------------------------------
// parseAssignments
// ---------------------------------------------------------------------

Deno.test("parseAssignments reads title, dueAt and kind from a well-formed response", () => {
  const text = JSON.stringify({
    assignments: [{ title: "Read chapter 4", dueAt: "2026-09-12T00:00:00.000Z", kind: "submission" }],
  });
  assert.deepEqual(parseAssignments(text, NOW), [
    { title: "Read chapter 4", dueAt: "2026-09-12T00:00:00.000Z", kind: "submission" },
  ]);
});

Deno.test("parseAssignments defaults kind to \"submission\" when absent", () => {
  const text = JSON.stringify({ assignments: [{ title: "Submit lab" }] });
  assert.deepEqual(parseAssignments(text, NOW), [{ title: "Submit lab", kind: "submission" }]);
});

Deno.test("parseAssignments keeps an explicit \"preparation\" kind", () => {
  const text = JSON.stringify({ assignments: [{ title: "Read chapter 4", kind: "preparation" }] });
  assert.deepEqual(parseAssignments(text, NOW), [{ title: "Read chapter 4", kind: "preparation" }]);
});

Deno.test("parseAssignments defaults an unrecognized kind value to \"submission\"", () => {
  const text = JSON.stringify({ assignments: [{ title: "Read chapter 4", kind: "homework" }] });
  assert.deepEqual(parseAssignments(text, NOW), [{ title: "Read chapter 4", kind: "submission" }]);
});

Deno.test("parseAssignments strips a fenced ```json block", () => {
  const text = "```json\n" + JSON.stringify({ assignments: [{ title: "Submit lab" }] }) + "\n```";
  assert.deepEqual(parseAssignments(text, NOW), [{ title: "Submit lab", kind: "submission" }]);
});

Deno.test("parseAssignments keeps a title-only task when dueAt is null", () => {
  const text = JSON.stringify({ assignments: [{ title: "Read chapter 4", dueAt: null }] });
  assert.deepEqual(parseAssignments(text, NOW), [{ title: "Read chapter 4", kind: "submission" }]);
});

Deno.test("parseAssignments drops a dueAt more than 400 days in the future", () => {
  const farFuture = new Date(NOW.getTime() + 401 * 24 * 60 * 60 * 1000).toISOString();
  const text = JSON.stringify({ assignments: [{ title: "Read chapter 4", dueAt: farFuture }] });
  assert.deepEqual(parseAssignments(text, NOW), [{ title: "Read chapter 4", kind: "submission" }]);
});

Deno.test("parseAssignments drops a dueAt more than 400 days in the past", () => {
  const farPast = new Date(NOW.getTime() - 401 * 24 * 60 * 60 * 1000).toISOString();
  const text = JSON.stringify({ assignments: [{ title: "Old task", dueAt: farPast }] });
  assert.deepEqual(parseAssignments(text, NOW), [{ title: "Old task", kind: "submission" }]);
});

Deno.test("parseAssignments keeps a dueAt exactly 399 days out", () => {
  const nearFuture = new Date(NOW.getTime() + 399 * 24 * 60 * 60 * 1000).toISOString();
  const text = JSON.stringify({ assignments: [{ title: "Read chapter 4", dueAt: nearFuture }] });
  assert.deepEqual(parseAssignments(text, NOW), [
    { title: "Read chapter 4", dueAt: nearFuture, kind: "submission" },
  ]);
});

Deno.test("parseAssignments drops an unparseable dueAt string but keeps the title", () => {
  const text = JSON.stringify({ assignments: [{ title: "Read chapter 4", dueAt: "not-a-date" }] });
  assert.deepEqual(parseAssignments(text, NOW), [{ title: "Read chapter 4", kind: "submission" }]);
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

Deno.test("ANNOUNCEMENT_INSTRUCTIONS demands JSON-only output and states the kind rule", () => {
  assert.ok(ANNOUNCEMENT_INSTRUCTIONS.toLowerCase().includes("json"));
  assert.ok(ANNOUNCEMENT_INSTRUCTIONS.includes("assignments"));
  assert.ok(ANNOUNCEMENT_INSTRUCTIONS.includes("submission"));
  assert.ok(ANNOUNCEMENT_INSTRUCTIONS.includes("preparation"));
});
