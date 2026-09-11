// Unit tests for the pure pieces of `_shared/categoryMap.ts`: request
// validation and its limits, the canonical `structureHash` (order-
// independence is the property that actually matters -- see that
// function's doc comment), the response sanitizer, and the prompt
// builder. None of this touches a database or OpenRouter -- the same
// reason `profile.test.ts` and `announcement.test.ts` don't either.
import { strict as assert } from "node:assert";
import {
  buildCategoryMapUserContent,
  MAX_GROUPS,
  MAX_ITEMS_TOTAL,
  MAX_NAME_CHARS,
  parseMapCategoriesBody,
  sanitizeCategoryMapping,
  structureHash,
  type CategoryMapGroup,
  type SanitizeCategoryMappingContext,
} from "../supabase/functions/_shared/categoryMap.ts";
import type { GradingWeight } from "../supabase/functions/_shared/profile.ts";

// ---------------------------------------------------------------------
// parseMapCategoriesBody
// ---------------------------------------------------------------------

function validBody(): unknown {
  return {
    courseID: "1949400",
    groups: [
      {
        id: "g1",
        name: "Problem Sets",
        items: [{ id: "i1", name: "Problem Set 1", pointsPossible: 10, submissionTypes: ["online_upload"] }],
      },
    ],
  };
}

Deno.test("parseMapCategoriesBody accepts a well-formed request", () => {
  const parsed = parseMapCategoriesBody(validBody());
  assert.ok(parsed);
  assert.equal(parsed!.courseID, "1949400");
  assert.equal(parsed!.groups.length, 1);
  assert.equal(parsed!.groups[0].items[0].pointsPossible, 10);
  assert.deepEqual(parsed!.groups[0].items[0].submissionTypes, ["online_upload"]);
});

Deno.test("parseMapCategoriesBody accepts an item with neither pointsPossible nor submissionTypes", () => {
  const body = { courseID: "c1", groups: [{ id: "g1", name: "G", items: [{ id: "i1", name: "Item" }] }] };
  const parsed = parseMapCategoriesBody(body);
  assert.ok(parsed);
  assert.equal(parsed!.groups[0].items[0].pointsPossible, undefined);
  assert.equal(parsed!.groups[0].items[0].submissionTypes, undefined);
});

Deno.test("parseMapCategoriesBody rejects a non-object body", () => {
  assert.equal(parseMapCategoriesBody("nope"), undefined);
  assert.equal(parseMapCategoriesBody(null), undefined);
  assert.equal(parseMapCategoriesBody([1, 2]), undefined);
});

Deno.test("parseMapCategoriesBody rejects a missing or non-string courseID", () => {
  assert.equal(parseMapCategoriesBody({ groups: [] }), undefined);
  assert.equal(parseMapCategoriesBody({ courseID: 123, groups: [] }), undefined);
  assert.equal(parseMapCategoriesBody({ courseID: "", groups: [] }), undefined);
});

Deno.test("parseMapCategoriesBody rejects more than MAX_GROUPS groups", () => {
  const groups = Array.from({ length: MAX_GROUPS + 1 }, (_, i) => ({ id: `g${i}`, name: `G${i}`, items: [] }));
  assert.equal(parseMapCategoriesBody({ courseID: "c1", groups }), undefined);
});

Deno.test("parseMapCategoriesBody accepts exactly MAX_GROUPS groups", () => {
  const groups = Array.from({ length: MAX_GROUPS }, (_, i) => ({ id: `g${i}`, name: `G${i}`, items: [] }));
  assert.ok(parseMapCategoriesBody({ courseID: "c1", groups }));
});

Deno.test("parseMapCategoriesBody rejects more than MAX_ITEMS_TOTAL items across all groups", () => {
  const items = Array.from({ length: MAX_ITEMS_TOTAL + 1 }, (_, i) => ({ id: `i${i}`, name: `I${i}` }));
  const body = { courseID: "c1", groups: [{ id: "g1", name: "G", items }] };
  assert.equal(parseMapCategoriesBody(body), undefined);
});

Deno.test("parseMapCategoriesBody accepts exactly MAX_ITEMS_TOTAL items total, split across groups", () => {
  const items = Array.from({ length: MAX_ITEMS_TOTAL }, (_, i) => ({ id: `i${i}`, name: `I${i}` }));
  const body = {
    courseID: "c1",
    groups: [
      { id: "g1", name: "G1", items: items.slice(0, 200) },
      { id: "g2", name: "G2", items: items.slice(200) },
    ],
  };
  assert.ok(parseMapCategoriesBody(body));
});

Deno.test("parseMapCategoriesBody rejects a group name longer than MAX_NAME_CHARS", () => {
  const body = { courseID: "c1", groups: [{ id: "g1", name: "x".repeat(MAX_NAME_CHARS + 1), items: [] }] };
  assert.equal(parseMapCategoriesBody(body), undefined);
});

Deno.test("parseMapCategoriesBody rejects an item name longer than MAX_NAME_CHARS", () => {
  const body = {
    courseID: "c1",
    groups: [{ id: "g1", name: "G", items: [{ id: "i1", name: "x".repeat(MAX_NAME_CHARS + 1) }] }],
  };
  assert.equal(parseMapCategoriesBody(body), undefined);
});

Deno.test("parseMapCategoriesBody strips any key not in the wire shape -- a client cannot smuggle a score", () => {
  const body = {
    courseID: "c1",
    groups: [
      {
        id: "g1",
        name: "G",
        items: [{ id: "i1", name: "Item", pointsPossible: 10, score: 9.5, submitted: true }],
      },
    ],
  };
  const parsed = parseMapCategoriesBody(body);
  assert.ok(parsed);
  const item = parsed!.groups[0].items[0] as unknown as Record<string, unknown>;
  assert.equal(item.score, undefined);
  assert.equal(item.submitted, undefined);
  assert.equal(Object.keys(item).sort().join(","), "id,name,pointsPossible");
});

Deno.test("parseMapCategoriesBody rejects a malformed item anywhere in the list, not just drops it", () => {
  const body = {
    courseID: "c1",
    groups: [{ id: "g1", name: "G", items: [{ id: "i1", name: "ok" }, { name: "missing id" }] }],
  };
  assert.equal(parseMapCategoriesBody(body), undefined);
});

Deno.test("parseMapCategoriesBody rejects a non-finite pointsPossible", () => {
  const body = { courseID: "c1", groups: [{ id: "g1", name: "G", items: [{ id: "i1", name: "I", pointsPossible: "10" }] }] };
  assert.equal(parseMapCategoriesBody(body), undefined);
});

// ---------------------------------------------------------------------
// structureHash
// ---------------------------------------------------------------------

Deno.test("structureHash is order-independent across groups and items", async () => {
  const a: CategoryMapGroup[] = [
    { id: "g1", name: "Problem Sets", items: [{ id: "i1", name: "PS1", pointsPossible: 10 }, { id: "i2", name: "PS2", pointsPossible: 10 }] },
    { id: "g2", name: "Exams", items: [{ id: "i3", name: "Midterm", pointsPossible: 100 }] },
  ];
  const b: CategoryMapGroup[] = [
    { id: "g2", name: "Exams", items: [{ id: "i3", name: "Midterm", pointsPossible: 100 }] },
    { id: "g1", name: "Problem Sets", items: [{ id: "i2", name: "PS2", pointsPossible: 10 }, { id: "i1", name: "PS1", pointsPossible: 10 }] },
  ];
  assert.equal(await structureHash(a), await structureHash(b));
});

Deno.test("structureHash changes when a name changes", async () => {
  const a: CategoryMapGroup[] = [{ id: "g1", name: "Problem Sets", items: [] }];
  const b: CategoryMapGroup[] = [{ id: "g1", name: "Problem Sets Renamed", items: [] }];
  assert.notEqual(await structureHash(a), await structureHash(b));
});

Deno.test("structureHash changes when a pointsPossible changes", async () => {
  const a: CategoryMapGroup[] = [{ id: "g1", name: "G", items: [{ id: "i1", name: "I", pointsPossible: 10 }] }];
  const b: CategoryMapGroup[] = [{ id: "g1", name: "G", items: [{ id: "i1", name: "I", pointsPossible: 20 }] }];
  assert.notEqual(await structureHash(a), await structureHash(b));
});

Deno.test("structureHash changes when submissionTypes changes", async () => {
  const a: CategoryMapGroup[] = [{ id: "g1", name: "G", items: [{ id: "i1", name: "I", submissionTypes: ["online_upload"] }] }];
  const b: CategoryMapGroup[] = [{ id: "g1", name: "G", items: [{ id: "i1", name: "I", submissionTypes: ["online_quiz"] }] }];
  assert.notEqual(await structureHash(a), await structureHash(b));
});

Deno.test("structureHash is stable for identical input and is 16 hex characters", async () => {
  const groups: CategoryMapGroup[] = [{ id: "g1", name: "G", items: [{ id: "i1", name: "I", pointsPossible: 5 }] }];
  const first = await structureHash(groups);
  const second = await structureHash(JSON.parse(JSON.stringify(groups)));
  assert.equal(first, second);
  assert.match(first, /^[0-9a-f]{16}$/);
});

// ---------------------------------------------------------------------
// sanitizeCategoryMapping
// ---------------------------------------------------------------------

function context(overrides: Partial<SanitizeCategoryMappingContext> = {}): SanitizeCategoryMappingContext {
  return {
    validCategoryNames: ["HomeWorks", "Midterms"],
    validGroupIDs: new Set(["g1", "g2", "g3"]),
    validItemIDs: new Set(["i1", "i7", "i9"]),
    extractedAt: "2026-09-10T00:00:00.000Z",
    structureHash: "abc123",
    ...overrides,
  };
}

Deno.test("sanitizeCategoryMapping returns null for a non-object", () => {
  assert.equal(sanitizeCategoryMapping("nope", context()), null);
  assert.equal(sanitizeCategoryMapping(null, context()), null);
  assert.equal(sanitizeCategoryMapping([1, 2], context()), null);
  assert.equal(sanitizeCategoryMapping(42, context()), null);
});

Deno.test("sanitizeCategoryMapping accepts the brief's example shape", () => {
  const raw = {
    categories: [{ name: "HomeWorks", canvasGroupIDs: ["g1", "g3"], itemIDs: ["i9"], expectedCount: 8 }],
    excludedItemIDs: ["i7"],
    reasons: { i7: "zero-point placeholder", i9: "attendance tool item" },
  };
  const result = sanitizeCategoryMapping(raw, context());
  assert.ok(result);
  assert.equal(result!.categories.length, 1);
  assert.equal(result!.categories[0].name, "HomeWorks");
  assert.deepEqual(result!.categories[0].canvasGroupIDs, ["g1", "g3"]);
  assert.deepEqual(result!.categories[0].itemIDs, ["i9"]);
  assert.equal(result!.categories[0].expectedCount, 8);
  assert.deepEqual(result!.excludedItemIDs, ["i7"]);
  assert.deepEqual(result!.reasons, { i7: "zero-point placeholder", i9: "attendance tool item" });
  assert.equal(result!.extractedAt, "2026-09-10T00:00:00.000Z");
  assert.equal(result!.structureHash, "abc123");
});

Deno.test("sanitizeCategoryMapping drops a category whose name the profile doesn't have", () => {
  const raw = { categories: [{ name: "Invented Category", canvasGroupIDs: ["g1"], itemIDs: [] }] };
  const result = sanitizeCategoryMapping(raw, context());
  assert.ok(result);
  assert.equal(result!.categories.length, 0);
});

Deno.test("sanitizeCategoryMapping drops ids the request never listed", () => {
  const raw = {
    categories: [{ name: "HomeWorks", canvasGroupIDs: ["g1", "g99"], itemIDs: ["i1", "iNope"] }],
    excludedItemIDs: ["i7", "iAlsoNope"],
  };
  const result = sanitizeCategoryMapping(raw, context());
  assert.ok(result);
  assert.deepEqual(result!.categories[0].canvasGroupIDs, ["g1"]);
  assert.deepEqual(result!.categories[0].itemIDs, ["i1"]);
  assert.deepEqual(result!.excludedItemIDs, ["i7"]);
});

Deno.test("sanitizeCategoryMapping: an id claimed by an earlier category is dropped from a later one (first wins)", () => {
  const raw = {
    categories: [
      { name: "HomeWorks", canvasGroupIDs: ["g1"], itemIDs: ["i1"] },
      { name: "Midterms", canvasGroupIDs: ["g1"], itemIDs: ["i1"] },
    ],
  };
  const result = sanitizeCategoryMapping(raw, context());
  assert.ok(result);
  assert.deepEqual(result!.categories[0].canvasGroupIDs, ["g1"]);
  assert.deepEqual(result!.categories[0].itemIDs, ["i1"]);
  assert.deepEqual(result!.categories[1].canvasGroupIDs, []);
  assert.deepEqual(result!.categories[1].itemIDs, []);
});

Deno.test("sanitizeCategoryMapping keeps a non-negative integer expectedCount", () => {
  const raw = { categories: [{ name: "HomeWorks", canvasGroupIDs: [], itemIDs: [], expectedCount: 0 }] };
  const result = sanitizeCategoryMapping(raw, context());
  assert.equal(result!.categories[0].expectedCount, 0);
});

Deno.test("sanitizeCategoryMapping omits a fractional, negative, or non-numeric expectedCount", () => {
  for (const bad of [1.5, -1, "8", null, NaN]) {
    const raw = { categories: [{ name: "HomeWorks", canvasGroupIDs: [], itemIDs: [], expectedCount: bad }] };
    const result = sanitizeCategoryMapping(raw, context());
    assert.equal(result!.categories[0].expectedCount, undefined, `expectedCount ${String(bad)} should be dropped`);
  }
});

Deno.test("sanitizeCategoryMapping drops a reasons entry keyed by an unknown id, or with a non-string value", () => {
  const raw = { categories: [], reasons: { i7: "ok reason", unknownID: "should be dropped", i9: 42 } };
  const result = sanitizeCategoryMapping(raw, context());
  assert.deepEqual(result!.reasons, { i7: "ok reason" });
});

Deno.test("sanitizeCategoryMapping treats missing categories/excludedItemIDs/reasons as empty rather than failing", () => {
  const result = sanitizeCategoryMapping({}, context());
  assert.ok(result);
  assert.deepEqual(result!.categories, []);
  assert.deepEqual(result!.excludedItemIDs, []);
  assert.deepEqual(result!.reasons, {});
});

Deno.test("sanitizeCategoryMapping drops a non-object entry inside categories", () => {
  const raw = { categories: ["not an object", { name: "HomeWorks", canvasGroupIDs: [], itemIDs: [] }] };
  const result = sanitizeCategoryMapping(raw, context());
  assert.equal(result!.categories.length, 1);
  assert.equal(result!.categories[0].name, "HomeWorks");
});

// ---------------------------------------------------------------------
// buildCategoryMapUserContent
// ---------------------------------------------------------------------

Deno.test("buildCategoryMapUserContent includes every syllabus category and every group/item name exactly once", () => {
  const weights: GradingWeight[] = [
    { name: "HomeWorks", percent: 20, expectedCount: 8 },
    { name: "Midterms", percent: 30 },
  ];
  const groups: CategoryMapGroup[] = [
    { id: "g1", name: "Problem Sets", items: [{ id: "i1", name: "Problem Set 1", pointsPossible: 10, submissionTypes: ["online_upload"] }] },
    { id: "g2", name: "Exams", items: [{ id: "i2", name: "Midterm 1" }] },
  ];
  const content = buildCategoryMapUserContent(weights, groups);

  for (const name of ["HomeWorks", "Midterms", "Problem Sets", "Exams", "Problem Set 1", "Midterm 1"]) {
    const occurrences = content.split(name).length - 1;
    assert.equal(occurrences, 1, `expected "${name}" to appear exactly once, appeared ${occurrences} times`);
  }
  assert.ok(content.includes("20%"));
  assert.ok(content.includes("expected 8 items"));
  assert.ok(content.includes("g1"));
  assert.ok(content.includes("i1"));
  assert.ok(content.includes("online_upload"));
});

Deno.test("buildCategoryMapUserContent handles no grading weights and no groups without throwing", () => {
  const content = buildCategoryMapUserContent([], []);
  assert.ok(content.includes("(none)"));
});
