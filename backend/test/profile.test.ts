import { strict as assert } from "node:assert";
import {
  type ProfileSourceDocument,
  isCoolingDown,
  isoDayOf,
  PROFILE_BUDGET_COOLDOWN_MS,
  parseProfile,
  profileSourceHash,
  selectProfileInput,
} from "../supabase/functions/_shared/profile.ts";

function doc(partial: Partial<ProfileSourceDocument> & Pick<ProfileSourceDocument, "id" | "kind">): ProfileSourceDocument {
  return {
    title: "untitled",
    text: "",
    content_hash: "hash",
    url: null,
    ...partial,
  };
}

Deno.test("selectProfileInput orders syllabus before home before page", () => {
  const docs = [
    doc({ id: "p1", kind: "page", title: "Schedule", text: "page text" }),
    doc({ id: "h1", kind: "home", title: "Home", text: "home text" }),
    doc({ id: "s1", kind: "syllabus", title: "Syllabus", text: "syllabus text" }),
  ];
  const input = selectProfileInput(docs, 100000);
  const syllabusIndex = input.indexOf("syllabus text");
  const homeIndex = input.indexOf("home text");
  const pageIndex = input.indexOf("page text");
  assert.ok(syllabusIndex < homeIndex);
  assert.ok(homeIndex < pageIndex);
});

Deno.test("selectProfileInput ignores documents of kinds outside syllabus/home/page", () => {
  const docs = [
    doc({ id: "a1", kind: "announcement", text: "should not appear" }),
    doc({ id: "s1", kind: "syllabus", text: "syllabus text" }),
  ];
  const input = selectProfileInput(docs, 100000);
  assert.ok(!input.includes("should not appear"));
  assert.ok(input.includes("syllabus text"));
});

Deno.test("selectProfileInput never includes an ed document, even alone", () => {
  const ed = doc({ id: "ed:1:9", kind: "ed", title: "Pinned", text: "ed post should not appear" });
  assert.equal(selectProfileInput([ed], 100000), "");
  const input = selectProfileInput(
    [ed, doc({ id: "s1", kind: "syllabus", text: "syllabus text" })],
    100000,
  );
  assert.ok(!input.includes("ed post should not appear"));
  assert.ok(input.includes("syllabus text"));
});

Deno.test("selectProfileInput stops at a document boundary rather than truncating mid-document", () => {
  const docs = [
    doc({ id: "s1", kind: "syllabus", text: "x".repeat(50) }),
    doc({ id: "h1", kind: "home", text: "y".repeat(50) }),
  ];
  // Budget fits the first document (with its header line) whole, but not
  // both documents together, so the second is dropped rather than sliced.
  const input = selectProfileInput(docs, 100);
  assert.ok(input.includes("x".repeat(50)));
  assert.ok(!input.includes("y".repeat(50)));
});

Deno.test("selectProfileInput truncates a single oversized first document rather than returning empty", () => {
  const docs = [doc({ id: "s1", kind: "syllabus", text: "z".repeat(1000) })];
  const input = selectProfileInput(docs, 50);
  assert.ok(input.length <= 50);
  assert.ok(input.length > 0);
});

Deno.test("selectProfileInput includes a website doc whose title matches, ordered after syllabus and before home/page", () => {
  const docs = [
    doc({ id: "p1", kind: "page", title: "Projects", text: "page text" }),
    doc({ id: "h1", kind: "home", title: "Home", text: "home text" }),
    doc({ id: "w1", kind: "website", title: "Syllabus", url: "https://example.org/26fa/syllabus/", text: "website syllabus text" }),
    doc({ id: "s1", kind: "syllabus", title: "Syllabus", text: "canvas syllabus text" }),
  ];
  const input = selectProfileInput(docs, 100000);
  const syllabusIndex = input.indexOf("canvas syllabus text");
  const websiteIndex = input.indexOf("website syllabus text");
  const homeIndex = input.indexOf("home text");
  const pageIndex = input.indexOf("page text");
  assert.ok(syllabusIndex >= 0 && websiteIndex >= 0 && homeIndex >= 0 && pageIndex >= 0);
  assert.ok(syllabusIndex < websiteIndex);
  assert.ok(websiteIndex < homeIndex);
  assert.ok(homeIndex < pageIndex);
});

Deno.test("selectProfileInput includes a website doc whose URL (not title) matches", () => {
  const docs = [
    doc({ id: "w1", kind: "website", title: "Fall 2026", url: "https://example.org/26fa/grading/", text: "grading breakdown here" }),
  ];
  const input = selectProfileInput(docs, 100000);
  assert.ok(input.includes("grading breakdown here"));
});

Deno.test("selectProfileInput excludes a website doc whose title/url don't look profile-relevant", () => {
  const docs = [
    doc({ id: "w1", kind: "website", title: "Projects", url: "https://example.org/26fa/projects/", text: "project specs here" }),
  ];
  const input = selectProfileInput(docs, 100000);
  assert.equal(input, "");
});

Deno.test("parseProfile accepts a bare JSON object", () => {
  const profile = parseProfile(JSON.stringify({ latePolicy: "24 hours" }));
  assert.equal(profile.latePolicy, "24 hours");
});

Deno.test("parseProfile strips a ```json fenced block", () => {
  const text = "```json\n" + JSON.stringify({ attendancePolicy: "no more than 2 absences" }) + "\n```";
  const profile = parseProfile(text);
  assert.equal(profile.attendancePolicy, "no more than 2 absences");
});

Deno.test("parseProfile drops unknown top-level keys", () => {
  const profile = parseProfile(JSON.stringify({ latePolicy: "x", notARealKey: "y" }));
  assert.equal(profile.latePolicy, "x");
  assert.ok(!("notARealKey" in profile));
});

Deno.test("parseProfile drops a gradingWeights entry whose percent is a string, not a number", () => {
  const profile = parseProfile(JSON.stringify({
    gradingWeights: [{ name: "Midterm", percent: "30%" }, { name: "Final", percent: 40 }],
  }));
  assert.deepEqual(profile.gradingWeights, [{ name: "Final", percent: 40 }]);
});

Deno.test("parseProfile rejects a top-level array or scalar and returns an empty profile", () => {
  assert.deepEqual(parseProfile("[1,2,3]"), {});
  assert.deepEqual(parseProfile('"just a string"'), {});
});

Deno.test("parseProfile returns an empty profile for unparseable text instead of throwing", () => {
  assert.deepEqual(parseProfile("not json at all"), {});
});

Deno.test("parseProfile keeps optional sub-fields when present and omits them when absent", () => {
  const profile = parseProfile(JSON.stringify({
    examDates: [{ name: "Midterm", date: "2026-10-01", text: "in class" }, { name: "Final", text: "TBD" }],
    officeHours: [{ who: "Prof. X", when: "Tue 2-3pm" }],
  }));
  assert.deepEqual(profile.examDates, [
    { name: "Midterm", date: "2026-10-01", text: "in class" },
    { name: "Final", text: "TBD" },
  ]);
  assert.deepEqual(profile.officeHours, [{ who: "Prof. X", when: "Tue 2-3pm" }]);
});

Deno.test("parseProfile drops an empty array down to an omitted key", () => {
  const profile = parseProfile(JSON.stringify({ textbooks: [] }));
  assert.ok(!("textbooks" in profile));
});

Deno.test("parseProfile keeps a components entry with its optional sub-fields", () => {
  const profile = parseProfile(JSON.stringify({
    components: [
      { name: "Lab", gradingBasis: "Pass/Fail", creditUnits: 0.5, notes: "meets weekly in DRLB" },
      { name: "Lecture" },
    ],
  }));
  assert.deepEqual(profile.components, [
    { name: "Lab", gradingBasis: "Pass/Fail", creditUnits: 0.5, notes: "meets weekly in DRLB" },
    { name: "Lecture" },
  ]);
});

Deno.test("parseProfile drops a components entry missing \"name\" and coerces a non-numeric creditUnits away", () => {
  const profile = parseProfile(JSON.stringify({
    components: [
      { gradingBasis: "no name, should be dropped" },
      { name: "Lab", creditUnits: "0.5 CU" },
    ],
  }));
  assert.deepEqual(profile.components, [{ name: "Lab" }]);
});

Deno.test("profileSourceHash is stable regardless of input order", async () => {
  const a = await profileSourceHash([{ id: "1", content_hash: "h1" }, { id: "2", content_hash: "h2" }]);
  const b = await profileSourceHash([{ id: "2", content_hash: "h2" }, { id: "1", content_hash: "h1" }]);
  assert.equal(a, b);
});

Deno.test("profileSourceHash changes when a content_hash changes", async () => {
  const a = await profileSourceHash([{ id: "1", content_hash: "h1" }]);
  const b = await profileSourceHash([{ id: "1", content_hash: "h2" }]);
  assert.notEqual(a, b);
});

Deno.test("profileSourceHash is a 64-character hex sha-256 digest", async () => {
  const hash = await profileSourceHash([{ id: "1", content_hash: "h1" }]);
  assert.match(hash, /^[0-9a-f]{64}$/);
});

// ---------------------------------------------------------------------
// gradingWeights: expectedCount / dropLowest
// ---------------------------------------------------------------------

Deno.test("parseProfile accepts expectedCount and dropLowest as non-negative integers", () => {
  const profile = parseProfile(JSON.stringify({
    gradingWeights: [{ name: "Labs", percent: 20, expectedCount: 12, dropLowest: 2 }],
  }));
  assert.deepEqual(profile.gradingWeights, [{ name: "Labs", percent: 20, expectedCount: 12, dropLowest: 2 }]);
});

Deno.test("parseProfile drops expectedCount/dropLowest when omitted, keeping the rest of the entry", () => {
  const profile = parseProfile(JSON.stringify({
    gradingWeights: [{ name: "Final", percent: 40 }],
  }));
  assert.deepEqual(profile.gradingWeights, [{ name: "Final", percent: 40 }]);
  assert.ok(profile.gradingWeights);
  assert.ok(!("expectedCount" in profile.gradingWeights[0]));
  assert.ok(!("dropLowest" in profile.gradingWeights[0]));
});

Deno.test("parseProfile drops a negative expectedCount, keeping the rest of the entry", () => {
  const profile = parseProfile(JSON.stringify({
    gradingWeights: [{ name: "Labs", percent: 20, expectedCount: -1 }],
  }));
  assert.deepEqual(profile.gradingWeights, [{ name: "Labs", percent: 20 }]);
});

Deno.test("parseProfile drops a fractional dropLowest, keeping the rest of the entry", () => {
  const profile = parseProfile(JSON.stringify({
    gradingWeights: [{ name: "Homework", percent: 15, dropLowest: 1.5 }],
  }));
  assert.deepEqual(profile.gradingWeights, [{ name: "Homework", percent: 15 }]);
});

Deno.test("parseProfile drops a string expectedCount, keeping the rest of the entry", () => {
  const profile = parseProfile(JSON.stringify({
    gradingWeights: [{ name: "Quizzes", percent: 10, expectedCount: "twelve" }],
  }));
  assert.deepEqual(profile.gradingWeights, [{ name: "Quizzes", percent: 10 }]);
});

Deno.test("isoDayOf keeps a bare ISO day and the day of an ISO date-time, whatever its offset", () => {
  assert.equal(isoDayOf("2026-10-23"), "2026-10-23");
  assert.equal(isoDayOf("  2026-10-23  "), "2026-10-23");
  assert.equal(isoDayOf("2026-10-23T18:00:00-04:00"), "2026-10-23");
  assert.equal(isoDayOf("2026-10-23T23:59:59Z"), "2026-10-23");
  assert.equal(isoDayOf("2026-10-23 18:00"), "2026-10-23");
});

Deno.test("isoDayOf accepts a real leap day and refuses a day the calendar doesn't have", () => {
  assert.equal(isoDayOf("2028-02-29"), "2028-02-29");
  assert.equal(isoDayOf("2026-02-29"), undefined);
  assert.equal(isoDayOf("2026-02-30"), undefined);
  assert.equal(isoDayOf("2026-04-31"), undefined);
  assert.equal(isoDayOf("2026-13-01"), undefined);
  assert.equal(isoDayOf("2026-00-10"), undefined);
  assert.equal(isoDayOf("2026-10-00"), undefined);
  assert.equal(isoDayOf("0050-10-23"), undefined);
});

Deno.test("isoDayOf refuses anything that isn't written as YYYY-MM-DD", () => {
  for (const raw of ["", "TBD", "October 23", "Oct 23, 2026", "10/23/2026", "2026-10", "2026-1-5", "20261023", "2026-10-23x", "week 8"]) {
    assert.equal(isoDayOf(raw), undefined, JSON.stringify(raw));
  }
});

Deno.test("isCoolingDown: inside 24 hours of a budget abort, not after, never without a usable stamp", () => {
  const now = new Date("2026-10-27T12:00:00Z");
  const ago = (ms: number) => new Date(now.getTime() - ms).toISOString();
  assert.equal(isCoolingDown(ago(1000), now), true);
  assert.equal(isCoolingDown(ago(PROFILE_BUDGET_COOLDOWN_MS - 1000), now), true);
  assert.equal(isCoolingDown(ago(PROFILE_BUDGET_COOLDOWN_MS), now), false, "the boundary is exclusive");
  assert.equal(isCoolingDown(ago(PROFILE_BUDGET_COOLDOWN_MS + 1000), now), false);
  for (const missing of [null, undefined, "", "not a date"]) {
    assert.equal(isCoolingDown(missing, now), false, String(missing));
  }
});

Deno.test("isCoolingDown: a stamp a little in the future is clock skew and counts as just made; one far ahead is not trusted", () => {
  const now = new Date("2026-10-27T12:00:00Z");
  assert.equal(isCoolingDown(new Date(now.getTime() + 60_000).toISOString(), now), true);
  assert.equal(isCoolingDown(new Date(now.getTime() + 3_600_000).toISOString(), now), false);
  assert.equal(isCoolingDown(new Date(now.getTime() + 30 * 86_400_000).toISOString(), now), false);
});
