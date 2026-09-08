// Unit tests for the pure catalog logic in
// supabase/functions/_shared/catalog.ts. Run with `deno task test` (see
// backend/deno.json). No network, no database -- `fetchCatalogCourse`'s
// tests inject a fake `fetch` rather than reaching the real Penn Labs API,
// which this container's network cannot reach anyway.
import { strict as assert } from "node:assert";
import {
  catalogCode,
  catalogIsStale,
  fetchCatalogCourse,
  parsePennLabsCourse,
  structureBlock,
  type CatalogCourseRow,
} from "../supabase/functions/_shared/catalog.ts";

const FIXTURE_PATH = new URL("./fixtures/penn-labs-phys-0151.json", import.meta.url);

async function loadFixture(): Promise<unknown> {
  const text = await Deno.readTextFile(FIXTURE_PATH);
  return JSON.parse(text);
}

// ---------------------------------------------------------------------
// catalogCode
// ---------------------------------------------------------------------

Deno.test("catalogCode: converts a space-separated course code to Penn Labs' dashed form", () => {
  assert.equal(catalogCode("PHYS 0151"), "PHYS-0151");
});

Deno.test("catalogCode: leaves an already-dashed code as-is", () => {
  assert.equal(catalogCode("PHYS-0151"), "PHYS-0151");
});

Deno.test("catalogCode: uppercases and trims", () => {
  assert.equal(catalogCode("  phys 0151  "), "PHYS-0151");
});

Deno.test("catalogCode: collapses internal whitespace runs before matching", () => {
  assert.equal(catalogCode("PHYS    0151"), "PHYS-0151");
});

Deno.test("catalogCode: allows a trailing letter suffix", () => {
  assert.equal(catalogCode("PHYS 0151A"), "PHYS-0151A");
});

Deno.test("catalogCode: allows a short (3-digit) course number", () => {
  assert.equal(catalogCode("CIS 121"), "CIS-121");
});

Deno.test("catalogCode: returns undefined for a raw Canvas descriptor that isn't a course code", () => {
  assert.equal(catalogCode("PSYC 1010-005 202430 Intro to Psych"), undefined);
});

Deno.test("catalogCode: returns undefined for empty input", () => {
  assert.equal(catalogCode(""), undefined);
});

Deno.test("catalogCode: returns undefined for a department code with too many letters", () => {
  assert.equal(catalogCode("ABCDEF 101"), undefined);
});

// ---------------------------------------------------------------------
// parsePennLabsCourse
// ---------------------------------------------------------------------

Deno.test("parsePennLabsCourse: maps top-level fields from the PHYS 0151 fixture", async () => {
  const row = parsePennLabsCourse(await loadFixture());
  assert.ok(row);
  assert.equal(row.catalogCode, "PHYS-0151");
  assert.equal(row.semester, "2026C");
  assert.equal(row.title, "Principles II");
  assert.equal(row.credits, 1.5);
  assert.equal(row.prerequisites, "");
  assert.deepEqual(row.crosslistings, []);
  assert.equal(row.source, "penn-labs");
  assert.ok(row.description.startsWith("The topics of this calculus-based course"));
});

Deno.test("parsePennLabsCourse: groups the fixture's 5 sections into a Lecture and a Lab component, lecture first", async () => {
  const row = parsePennLabsCourse(await loadFixture());
  assert.ok(row);
  assert.equal(row.components.length, 2);

  const [lecture, lab] = row.components;
  assert.equal(lecture.activity, "LEC");
  assert.equal(lecture.label, "Lecture");
  assert.equal(lecture.sectionCount, 2);
  assert.deepEqual(lecture.sectionIDs, ["PHYS-0151-401", "PHYS-0151-402"]);

  assert.equal(lab.activity, "LAB");
  assert.equal(lab.label, "Lab");
  assert.equal(lab.sectionCount, 3);
  assert.deepEqual(lab.sectionIDs, ["PHYS-0151-151", "PHYS-0151-152", "PHYS-0151-153"]);
});

Deno.test("parsePennLabsCourse: a component's credits is the max across its own sections, not the course's", async () => {
  const row = parsePennLabsCourse(await loadFixture());
  assert.ok(row);
  const lecture = row.components.find((c) => c.activity === "LEC");
  const lab = row.components.find((c) => c.activity === "LAB");
  // Fixture: LEC-401 states 1.5 credits, LEC-402 states 0.0 -- max is 1.5.
  assert.equal(lecture?.credits, 1.5);
  // Fixture: every LAB section states 0.0 credits (a real, stated value,
  // not an absence) -- max is 0, not null.
  assert.equal(lab?.credits, 0);
});

Deno.test("parsePennLabsCourse: derives grade modes from MODE-school attributes, stripping the prefix", async () => {
  const row = parsePennLabsCourse(await loadFixture());
  assert.ok(row);
  assert.deepEqual(row.gradeModes, ["Standard Letter Grade", "Pass/Fail"]);
});

Deno.test("parsePennLabsCourse: never carries review-score fields through", async () => {
  const row = parsePennLabsCourse(await loadFixture());
  assert.ok(row);
  const keys = Object.keys(row);
  for (const forbidden of ["course_quality", "instructor_quality", "difficulty", "work_required"]) {
    assert.ok(!keys.includes(forbidden), `row must not carry ${forbidden}`);
  }
});

Deno.test("parsePennLabsCourse: returns undefined when the response is missing \"id\"", () => {
  const withoutID = { semester: "2026C", title: "No id" };
  assert.equal(parsePennLabsCourse(withoutID), undefined);
});

Deno.test("parsePennLabsCourse: returns undefined when the response is missing \"semester\"", () => {
  const withoutSemester = { id: "PHYS-0151", title: "No semester" };
  assert.equal(parsePennLabsCourse(withoutSemester), undefined);
});

Deno.test("parsePennLabsCourse: returns undefined for non-object input", () => {
  assert.equal(parsePennLabsCourse(null), undefined);
  assert.equal(parsePennLabsCourse("PHYS-0151"), undefined);
  assert.equal(parsePennLabsCourse([1, 2, 3]), undefined);
});

Deno.test("parsePennLabsCourse: defaults missing optional fields rather than failing", () => {
  const minimal = { id: "CIS-121", semester: "2026C" };
  const row = parsePennLabsCourse(minimal);
  assert.ok(row);
  assert.equal(row.title, "");
  assert.equal(row.description, "");
  assert.equal(row.credits, null);
  assert.deepEqual(row.crosslistings, []);
  assert.deepEqual(row.gradeModes, []);
  assert.deepEqual(row.components, []);
});

// ---------------------------------------------------------------------
// fetchCatalogCourse
// ---------------------------------------------------------------------

function jsonResponse(body: unknown, status = 200): Response {
  return new Response(JSON.stringify(body), { status });
}

Deno.test("fetchCatalogCourse: parses a successful response and sends the required User-Agent", async () => {
  const fixture = await loadFixture();
  let capturedHeaders: Headers | undefined;
  const fetchImpl: typeof fetch = async (input, init) => {
    capturedHeaders = new Headers(init?.headers);
    assert.equal(String(input), "https://penncoursereview.com/api/base/current/courses/PHYS-0151/");
    return jsonResponse(fixture);
  };

  const row = await fetchCatalogCourse({ fetchImpl, catalogCode: "PHYS-0151", timeoutMs: 2500 });
  assert.ok(row);
  assert.equal(row.catalogCode, "PHYS-0151");
  assert.ok(capturedHeaders?.get("User-Agent")?.startsWith("LowHangingFruit/1"));
});

Deno.test("fetchCatalogCourse: a 404 comes back as undefined, never throws", async () => {
  const fetchImpl: typeof fetch = async () => new Response("not found", { status: 404 });
  const row = await fetchCatalogCourse({ fetchImpl, catalogCode: "ZZZZ-9999", timeoutMs: 2500 });
  assert.equal(row, undefined);
});

Deno.test("fetchCatalogCourse: a thrown network error comes back as undefined, never throws", async () => {
  const fetchImpl: typeof fetch = async () => {
    throw new TypeError("network down");
  };
  const row = await fetchCatalogCourse({ fetchImpl, catalogCode: "PHYS-0151", timeoutMs: 2500 });
  assert.equal(row, undefined);
});

Deno.test("fetchCatalogCourse: a request that never settles times out to undefined", async () => {
  const fetchImpl: typeof fetch = (_input, init) =>
    new Promise((_resolve, reject) => {
      init?.signal?.addEventListener("abort", () => reject(new DOMException("Aborted", "AbortError")));
    });
  const row = await fetchCatalogCourse({ fetchImpl, catalogCode: "PHYS-0151", timeoutMs: 10 });
  assert.equal(row, undefined);
});

Deno.test("fetchCatalogCourse: a 200 with a non-JSON body comes back as undefined", async () => {
  const fetchImpl: typeof fetch = async () => new Response("<html>not json</html>", { status: 200 });
  const row = await fetchCatalogCourse({ fetchImpl, catalogCode: "PHYS-0151", timeoutMs: 2500 });
  assert.equal(row, undefined);
});

Deno.test("fetchCatalogCourse: a 200 with JSON that isn't a course comes back as undefined", async () => {
  const fetchImpl: typeof fetch = async () => jsonResponse({ nothing: "useful" });
  const row = await fetchCatalogCourse({ fetchImpl, catalogCode: "PHYS-0151", timeoutMs: 2500 });
  assert.equal(row, undefined);
});

// ---------------------------------------------------------------------
// catalogIsStale
// ---------------------------------------------------------------------

Deno.test("catalogIsStale: false for a row fetched moments ago", () => {
  const now = new Date("2026-09-07T12:00:00Z");
  const fetchedAt = new Date("2026-09-07T11:00:00Z");
  assert.equal(catalogIsStale(fetchedAt, now), false);
});

Deno.test("catalogIsStale: true once the default 7-day window has elapsed", () => {
  const now = new Date("2026-09-15T00:00:01Z");
  const fetchedAt = new Date("2026-09-08T00:00:00Z");
  assert.equal(catalogIsStale(fetchedAt, now), true);
});

Deno.test("catalogIsStale: honors a custom maxAgeDays", () => {
  const now = new Date("2026-09-09T00:00:01Z");
  const fetchedAt = new Date("2026-09-08T00:00:00Z");
  assert.equal(catalogIsStale(fetchedAt, now, 2), false);
  assert.equal(catalogIsStale(fetchedAt, now, 1), true);
});

Deno.test("catalogIsStale: an unparseable timestamp counts as stale", () => {
  assert.equal(catalogIsStale("not-a-date", new Date("2026-09-07T00:00:00Z")), true);
});

// ---------------------------------------------------------------------
// structureBlock
// ---------------------------------------------------------------------

const PHYS_ROW: CatalogCourseRow = {
  catalogCode: "PHYS-0151",
  semester: "2026C",
  title: "Principles II",
  description: "  Electric  and\nmagnetic   fields.  ",
  credits: 1.5,
  prerequisites: "MATH 1410 or equivalent",
  crosslistings: [],
  gradeModes: ["Standard Letter Grade", "Pass/Fail"],
  attributes: [],
  components: [
    { activity: "LEC", label: "Lecture", sectionCount: 2, credits: 1.5, sectionIDs: ["PHYS-0151-401", "PHYS-0151-402"] },
    { activity: "LAB", label: "Lab", sectionCount: 3, credits: null, sectionIDs: ["PHYS-0151-151", "PHYS-0151-152", "PHYS-0151-153"] },
  ],
  source: "penn-labs",
  fetchedAt: "2026-09-07T12:00:00Z",
};

Deno.test("structureBlock: empty input is the empty string", () => {
  assert.equal(structureBlock([]), "");
});

Deno.test("structureBlock: renders the fixed field order, collapsing whitespace and omitting a null component credits phrase", () => {
  const block = structureBlock([PHYS_ROW]);
  assert.equal(
    block,
    `PHYS-0151 "Principles II" — 1.5 CU. Components: Lecture (2 sections), Lab (3 sections). `
    + `Grade modes offered: Standard Letter Grade, Pass/Fail. Prerequisites: MATH 1410 or equivalent. `
    + `Description: Electric and magnetic fields.`,
  );
});

Deno.test("structureBlock: omits prerequisites and grade-mode sentences when empty", () => {
  const row: CatalogCourseRow = {
    ...PHYS_ROW,
    prerequisites: "",
    gradeModes: [],
    components: [],
    description: "",
  };
  assert.equal(structureBlock([row]), `PHYS-0151 "Principles II" — 1.5 CU.`);
});

Deno.test("structureBlock: sorts multiple courses by catalogCode regardless of input order", () => {
  const cis: CatalogCourseRow = { ...PHYS_ROW, catalogCode: "CIS-1200", title: "Programming Languages" };
  const block = structureBlock([PHYS_ROW, cis]);
  assert.ok(block.indexOf("CIS-1200") < block.indexOf("PHYS-0151"));
});

Deno.test("structureBlock: truncates a long description to 600 characters", () => {
  const row: CatalogCourseRow = { ...PHYS_ROW, description: "x".repeat(1000), prerequisites: "", gradeModes: [], components: [] };
  const block = structureBlock([row]);
  const marker = "Description: ";
  const start = block.indexOf(marker) + marker.length;
  const described = block.slice(start, block.length - 1); // drop trailing "."
  assert.equal(described.length, 600);
});

Deno.test("structureBlock: byte-stable for identical input, called twice", () => {
  const first = structureBlock([PHYS_ROW]);
  const second = structureBlock([PHYS_ROW]);
  assert.equal(first, second);
});


Deno.test("structureBlock: states component credits only when they differ from the course total and are non-zero", () => {
  const row = {
    ...PHYS_ROW,
    components: [
      { activity: "LEC", label: "Lecture", sectionCount: 1, credits: 1.5, sectionIDs: ["X-1"] },
      { activity: "LAB", label: "Lab", sectionCount: 1, credits: 0, sectionIDs: ["X-2"] },
      { activity: "REC", label: "Recitation", sectionCount: 1, credits: 0.5, sectionIDs: ["X-3"] },
    ],
  };
  const block = structureBlock([row]);
  assert.ok(block.includes("Lecture (1 section), Lab (1 section), Recitation (1 section, 0.5 CU each)"), block);
  assert.ok(!block.includes("0 CU"), block);
});
