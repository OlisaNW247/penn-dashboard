// Unit tests for the pure (no-`SupabaseClient`) pieces of
// supabase/functions/_shared/db.ts's catalog handling: normalizing a
// `catalog_courses` row read back from Postgres, and deciding whether a
// code needs a fresh Penn Labs fetch. Run with `deno task test` (see
// backend/deno.json).
//
// Context: `catalog_courses.components` is jsonb, so Postgres hands back
// whatever shape was last written, not necessarily today's
// `CatalogComponent`. The first catalog commit (2026-09-07) wrote
// components without a `meetings` field; 6104d86 added `meetings:
// CatalogMeeting[]` to the type and `catalogEntryWire` started iterating
// it unconditionally, so a legacy row threw a TypeError there and took the
// whole `sync` manifest response down with it (a live 500). These tests
// pin down the fix: `dbRowToCatalogRow` normalizes on read and flags the
// row, and `catalogNeedsFetch` uses that flag to force a refetch even when
// the row is otherwise fresh.
import { strict as assert } from "node:assert";
import {
  catalogNeedsFetch,
  dbRowToCatalogRow,
  profileRowToWire,
  type CatalogCourseDBRow,
  type CourseProfileDBRow,
} from "../supabase/functions/_shared/db.ts";

function baseDBRow(overrides: Partial<CatalogCourseDBRow> = {}): CatalogCourseDBRow {
  return {
    catalog_code: "PHYS-0151",
    semester: "2026C",
    title: "Principles II",
    description: "Electric and magnetic fields.",
    credits: 1.5,
    prerequisites: "",
    crosslistings: [],
    grade_modes: [],
    attributes: [],
    components: [],
    source: "penn-labs",
    fetched_at: "2026-09-07T12:00:00Z",
    syllabus_url: null,
    ...overrides,
  };
}

// ---------------------------------------------------------------------
// dbRowToCatalogRow: legacy (pre-meetings) component normalization
// ---------------------------------------------------------------------

Deno.test("dbRowToCatalogRow: a legacy component (no meetings field) normalizes to meetings: [] and sets componentsLackMeetings", () => {
  // Shaped exactly like the first catalog commit wrote it -- no `meetings`
  // key at all, not an empty array -- so the cast is standing in for
  // "whatever Postgres actually returns for old jsonb", which is not
  // assignable to today's `CatalogComponent` without it.
  const legacyComponents = [
    { activity: "LEC", label: "Lecture", sectionCount: 2, credits: 1.5, sectionIDs: ["PHYS-0151-401"] },
  ] as unknown as CatalogCourseDBRow["components"];

  const row = dbRowToCatalogRow(baseDBRow({ components: legacyComponents }));

  assert.equal(row.componentsLackMeetings, true);
  assert.equal(row.components.length, 1);
  assert.deepEqual(row.components[0].meetings, []);
  // The rest of the component's fields survive normalization untouched.
  assert.equal(row.components[0].activity, "LEC");
  assert.deepEqual(row.components[0].sectionIDs, ["PHYS-0151-401"]);
});

Deno.test("dbRowToCatalogRow: a current-shaped component (meetings present) leaves componentsLackMeetings false", () => {
  const currentComponents: CatalogCourseDBRow["components"] = [
    {
      activity: "LEC",
      label: "Lecture",
      sectionCount: 1,
      credits: 1.5,
      sectionIDs: ["PHYS-0151-401"],
      meetings: [{ sectionID: "PHYS-0151-401", weekday: 2, startMinutes: 600, endMinutes: 660, room: null }],
      instructorsBySection: {},
    },
  ];

  const row = dbRowToCatalogRow(baseDBRow({ components: currentComponents }));

  assert.equal(row.componentsLackMeetings, false);
  assert.equal(row.components[0].meetings.length, 1);
});

Deno.test("dbRowToCatalogRow: a row with zero components is not flagged legacy (nothing to be missing meetings from)", () => {
  const row = dbRowToCatalogRow(baseDBRow({ components: [] }));
  assert.equal(row.componentsLackMeetings, false);
  assert.deepEqual(row.components, []);
});

Deno.test("dbRowToCatalogRow: a legacy sectionIDs-less component also normalizes without throwing", () => {
  const legacyComponents = [
    { activity: "LAB", label: "Lab", sectionCount: 1, credits: null },
  ] as unknown as CatalogCourseDBRow["components"];

  const row = dbRowToCatalogRow(baseDBRow({ components: legacyComponents }));

  assert.equal(row.componentsLackMeetings, true);
  assert.deepEqual(row.components[0].sectionIDs, []);
  assert.deepEqual(row.components[0].meetings, []);
});

// ---------------------------------------------------------------------
// catalogNeedsFetch
// ---------------------------------------------------------------------

const NOW = new Date("2026-09-09T12:00:00Z");

Deno.test("catalogNeedsFetch: true when no row exists yet", () => {
  assert.equal(catalogNeedsFetch(undefined, NOW), true);
});

Deno.test("catalogNeedsFetch: false for a fresh, current-shaped row", () => {
  const row = dbRowToCatalogRow(
    baseDBRow({
      fetched_at: "2026-09-09T11:00:00Z",
      components: [
        { activity: "LEC", label: "Lecture", sectionCount: 1, credits: 1.5, sectionIDs: ["PHYS-0151-401"], meetings: [], instructorsBySection: {} },
      ],
    }),
  );
  assert.equal(catalogNeedsFetch(row, NOW), false);
});

Deno.test("catalogNeedsFetch: a fresh row for another semester is refetched, a fresh row for this one is not", () => {
  const components = [
    { activity: "LEC", label: "Lecture", sectionCount: 1, credits: 1.5, sectionIDs: ["PHYS-0151-401"], meetings: [], instructorsBySection: {} },
  ];
  const now = new Date("2026-10-20T14:00:00Z");
  const spring = dbRowToCatalogRow(baseDBRow({ semester: "2027A", fetched_at: "2026-10-20T13:00:00Z", components }));
  const fall = dbRowToCatalogRow(baseDBRow({ semester: "2026C", fetched_at: "2026-10-20T13:00:00Z", components }));
  assert.equal(catalogNeedsFetch(spring, now), true);
  assert.equal(catalogNeedsFetch(fall, now), false);
});

Deno.test("catalogNeedsFetch: true for a legacy row even though it was fetched moments ago (nowhere near stale)", () => {
  const legacyComponents = [
    { activity: "LEC", label: "Lecture", sectionCount: 1, credits: 1.5, sectionIDs: ["PHYS-0151-401"] },
  ] as unknown as CatalogCourseDBRow["components"];
  const row = dbRowToCatalogRow(baseDBRow({ fetched_at: "2026-09-09T11:59:00Z", components: legacyComponents }));

  assert.equal(row.componentsLackMeetings, true);
  assert.equal(catalogNeedsFetch(row, NOW), true);
});

Deno.test("catalogNeedsFetch: true for an ordinarily-stale current-shaped row", () => {
  const row = dbRowToCatalogRow(
    baseDBRow({
      fetched_at: "2026-08-01T00:00:00Z", // well over 7 days before NOW
      components: [
        { activity: "LEC", label: "Lecture", sectionCount: 1, credits: 1.5, sectionIDs: ["PHYS-0151-401"], meetings: [], instructorsBySection: {} },
      ],
    }),
  );
  assert.equal(catalogNeedsFetch(row, NOW), true);
});

// ---------------------------------------------------------------------
// profileRowToWire: normalizing a course_profiles row into a
// CourseProfileWire. `course_profiles.profile` is jsonb -- same trap as
// `catalog_courses.components` above -- so these pin down that a legacy or
// malformed stored value degrades to empty rather than throwing.
// ---------------------------------------------------------------------

function baseProfileDBRow(overrides: Partial<CourseProfileDBRow> = {}): CourseProfileDBRow {
  return {
    course_id: "canvas-course-123",
    profile: {},
    updated_at: "2026-09-10T12:00:00Z",
    ...overrides,
  };
}

Deno.test("profileRowToWire: maps a full row's gradingWeights and components, dropping components' notes", () => {
  const wire = profileRowToWire(baseProfileDBRow({
    profile: {
      gradingWeights: [
        { name: "Labs", percent: 20, expectedCount: 12, dropLowest: 2 },
        { name: "Final", percent: 40 },
      ],
      components: [
        { name: "Lab", gradingBasis: "Pass/Fail", creditUnits: 0.5, notes: "meets weekly in DRLB" },
      ],
    },
  }));

  assert.equal(wire.courseID, "canvas-course-123");
  assert.equal(wire.extractedAt, "2026-09-10T12:00:00Z");
  assert.deepEqual(wire.gradingWeights, [
    { name: "Labs", percent: 20, expectedCount: 12, dropLowest: 2 },
    { name: "Final", percent: 40 },
  ]);
  assert.deepEqual(wire.components, [{ name: "Lab", gradingBasis: "Pass/Fail", creditUnits: 0.5 }]);
  assert.ok(!("notes" in wire.components[0]));
});

Deno.test("profileRowToWire: a legacy row lacking gradingWeights entirely yields []", () => {
  const wire = profileRowToWire(baseProfileDBRow({
    profile: { latePolicy: "24 hours" },
  }));
  assert.deepEqual(wire.gradingWeights, []);
  assert.deepEqual(wire.components, []);
});

Deno.test("profileRowToWire: a malformed gradingWeights value (not an array) yields [], no throw", () => {
  const wire = profileRowToWire(baseProfileDBRow({
    profile: { gradingWeights: "not an array" },
  }));
  assert.deepEqual(wire.gradingWeights, []);
});

Deno.test("profileRowToWire: a malformed components value (not an array) yields [], no throw", () => {
  const wire = profileRowToWire(baseProfileDBRow({
    profile: { components: { name: "Lab" } },
  }));
  assert.deepEqual(wire.components, []);
});

Deno.test("profileRowToWire: a profile value that isn't a JSON object at all degrades to empty, no throw", () => {
  const wire = profileRowToWire(baseProfileDBRow({ profile: "not an object" }));
  assert.deepEqual(wire.gradingWeights, []);
  assert.deepEqual(wire.components, []);
  assert.deepEqual(wire.examDates, []);
});

// ---------------------------------------------------------------------
// profileRowToWire's `examDates`: the syllabus exams `extract-profile`
// already stored but `sync` never sent. Same jsonb discipline as above, plus
// the one rule specific to this field -- a `date` leaves the server only as
// a real `YYYY-MM-DD` day.
// ---------------------------------------------------------------------

Deno.test("profileRowToWire: maps examDates, keeping a real ISO day and dropping the rest of a date-time", () => {
  const wire = profileRowToWire(baseProfileDBRow({
    profile: {
      examDates: [
        { name: "Midterm 1", date: "2026-10-23", text: "Midterm 1: Thursday, October 23" },
        { name: "Midterm 2", date: "2026-11-20T19:00:00-05:00", text: "Midterm 2, Nov 20, 7pm" },
        { name: "Final Exam", text: "Date set by the registrar" },
      ],
    },
  }));
  assert.deepEqual(wire.examDates, [
    { name: "Midterm 1", date: "2026-10-23", text: "Midterm 1: Thursday, October 23" },
    { name: "Midterm 2", date: "2026-11-20", text: "Midterm 2, Nov 20, 7pm" },
    { name: "Final Exam", text: "Date set by the registrar" },
  ]);
  assert.ok(!("date" in wire.examDates[2]));
});

Deno.test("profileRowToWire: an exam whose date isn't a real ISO day goes out undated, not dropped and not guessed", () => {
  const wire = profileRowToWire(baseProfileDBRow({
    profile: {
      examDates: [
        { name: "Midterm", date: "October 23", text: "t" },
        { name: "Quiz-ish", date: "10/23/2026", text: "t" },
        { name: "Impossible day", date: "2026-02-30", text: "t" },
        { name: "Impossible month", date: "2026-13-01", text: "t" },
        { name: "Empty date", date: "", text: "t" },
        { name: "Not a string", date: 20261023, text: "t" },
      ],
    },
  }));
  assert.equal(wire.examDates.length, 6);
  for (const exam of wire.examDates) {
    assert.ok(!("date" in exam), `${exam.name} should be undated`);
  }
});

Deno.test("profileRowToWire: a legacy row lacking examDates entirely yields []", () => {
  const wire = profileRowToWire(baseProfileDBRow({
    profile: { gradingWeights: [{ name: "Final", percent: 100 }] },
  }));
  assert.deepEqual(wire.examDates, []);
  assert.deepEqual(wire.gradingWeights, [{ name: "Final", percent: 100 }]);
});

Deno.test("profileRowToWire: a malformed examDates value (not an array) yields [], no throw", () => {
  for (const examDates of ["Midterm Oct 23", { name: "Midterm", date: "2026-10-23", text: "t" }, 7, null]) {
    const wire = profileRowToWire(baseProfileDBRow({ profile: { examDates } }));
    assert.deepEqual(wire.examDates, []);
  }
});

Deno.test("profileRowToWire: malformed examDates entries are dropped one by one, the good ones kept", () => {
  const wire = profileRowToWire(baseProfileDBRow({
    profile: {
      examDates: [
        "Midterm Oct 23",
        null,
        42,
        { date: "2026-10-23", text: "no name" },
        { name: "No text", date: "2026-10-23" },
        { name: 7, text: "t" },
        { name: "   ", date: "2026-10-23", text: "blank name" },
        { name: "Final Exam", date: "2026-12-15", text: "Final Exam: Dec 15" },
      ],
    },
  }));
  assert.deepEqual(wire.examDates, [
    { name: "Final Exam", date: "2026-12-15", text: "Final Exam: Dec 15" },
  ]);
});

Deno.test("profileRowToWire: examDates doesn't disturb gradingWeights or components, and carries no other profile field", () => {
  const wire = profileRowToWire(baseProfileDBRow({
    profile: {
      gradingWeights: [{ name: "Final", percent: 100 }],
      components: [{ name: "Lab", creditUnits: 0.5 }],
      latePolicy: "24 hours",
      officeHours: [{ who: "Prof. X", when: "Tue 2-3pm" }],
      examDates: [{ name: "Final Exam", date: "2026-12-15", text: "Dec 15" }],
    },
  }));
  assert.deepEqual(wire.gradingWeights, [{ name: "Final", percent: 100 }]);
  assert.deepEqual(wire.components, [{ name: "Lab", creditUnits: 0.5 }]);
  assert.deepEqual(Object.keys(wire).sort(), ["components", "courseID", "examDates", "extractedAt", "gradingWeights"]);
});

// ---------------------------------------------------------------------
// rooms and instructors: legacy detection is by key presence
// ---------------------------------------------------------------------

Deno.test("dbRowToCatalogRow: meetings without a room key (and no instructorsBySection) set componentsLackSectionDetails and normalize to room: null / {}", () => {
  const legacy = [
    {
      activity: "LEC",
      label: "Lecture",
      sectionCount: 1,
      credits: 1.5,
      sectionIDs: ["PHYS-0151-401"],
      meetings: [{ sectionID: "PHYS-0151-401", weekday: 2, startMinutes: 600, endMinutes: 660 }],
    },
  ] as unknown as CatalogCourseDBRow["components"];
  const row = dbRowToCatalogRow(baseDBRow({ components: legacy }));
  assert.equal(row.componentsLackMeetings, false);
  assert.equal(row.componentsLackSectionDetails, true);
  assert.equal(row.components[0].meetings[0].room, null);
  assert.deepEqual(row.components[0].instructorsBySection, {});
});

Deno.test("catalogNeedsFetch: true for a row lacking section details even when fetched moments ago", () => {
  const legacy = [
    {
      activity: "LEC",
      label: "Lecture",
      sectionCount: 1,
      credits: 1.5,
      sectionIDs: ["PHYS-0151-401"],
      meetings: [{ sectionID: "PHYS-0151-401", weekday: 2, startMinutes: 600, endMinutes: 660 }],
      instructorsBySection: {},
    },
  ] as unknown as CatalogCourseDBRow["components"];
  const row = dbRowToCatalogRow(baseDBRow({ fetched_at: "2026-09-09T11:59:00Z", components: legacy }));
  assert.equal(row.componentsLackSectionDetails, true); // room key absent
  assert.equal(catalogNeedsFetch(row, NOW), true);

  const noInstructorsKey = [
    {
      activity: "LEC",
      label: "Lecture",
      sectionCount: 1,
      credits: 1.5,
      sectionIDs: ["PHYS-0151-401"],
      meetings: [{ sectionID: "PHYS-0151-401", weekday: 2, startMinutes: 600, endMinutes: 660, room: "A1" }],
    },
  ] as unknown as CatalogCourseDBRow["components"];
  const row2 = dbRowToCatalogRow(baseDBRow({ fetched_at: "2026-09-09T11:59:00Z", components: noInstructorsKey }));
  assert.equal(row2.componentsLackSectionDetails, true); // instructorsBySection key absent
  assert.equal(catalogNeedsFetch(row2, NOW), true);
});

Deno.test("catalogNeedsFetch: a present room: null and instructorsBySection: {} are real facts, not legacy, and a fresh row is not refetched", () => {
  const current: CatalogCourseDBRow["components"] = [
    {
      activity: "ONL",
      label: "Online",
      sectionCount: 1,
      credits: 1,
      sectionIDs: ["ONLN-0100-001"],
      meetings: [{ sectionID: "ONLN-0100-001", weekday: 2, startMinutes: 600, endMinutes: 660, room: null }],
      instructorsBySection: {},
    },
  ];
  const row = dbRowToCatalogRow(baseDBRow({ fetched_at: "2026-09-09T11:00:00Z", components: current }));
  assert.equal(row.componentsLackSectionDetails, false);
  assert.equal(row.components[0].meetings[0].room, null);
  assert.equal(catalogNeedsFetch(row, NOW), false);
});
