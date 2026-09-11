// Everything `map-categories/index.ts` needs that doesn't itself touch the
// network or a database: request validation, the canonical structure hash
// the per-course cache keys on, the instructions sent to the model, the
// user-message rendering, and sanitizing what comes back. Kept here, not
// inline in the function, for the same reason `_shared/profile.ts` and
// `_shared/announcement.ts` are split out -- every one of these is pure
// and testable without a live OpenRouter key or a Supabase project.
//
// The privacy boundary this file exists to enforce: the request this
// module validates carries only a course's Canvas assignment-*group*
// structure -- group and item names, points possible, submission types --
// never a score, a submission, or anything else about one student's own
// work. `parseMapCategoriesBody` builds its own output objects field by
// field rather than passing the client's JSON through, which is what
// makes "strip any key not listed" actually true: a client that tries to
// smuggle a `score` or `submitted` field onto an item has it silently
// dropped here, the same defense-in-depth `course_documents` having no
// `submitted` column gives principle 2 of PROTOCOL.md.
import { stableStringify } from "./prompt.ts";
import type { GradingWeight } from "./profile.ts";

// ---------------------------------------------------------------------
// Request validation
// ---------------------------------------------------------------------

export interface CategoryMapItem {
  id: string;
  name: string;
  pointsPossible?: number;
  submissionTypes?: string[];
}

export interface CategoryMapGroup {
  id: string;
  name: string;
  items: CategoryMapItem[];
}

export interface MapCategoriesRequestBody {
  courseID: string;
  groups: CategoryMapGroup[];
}

export const MAX_GROUPS = 40;
export const MAX_ITEMS_TOTAL = 400;
export const MAX_NAME_CHARS = 200;

function isPlainObject(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function isNonEmptyString(value: unknown): value is string {
  return typeof value === "string" && value.length > 0;
}

/** Validates and reshapes one item, keeping only the four wire fields --
 *  everything else on the client's object (a `score`, a `submitted` flag,
 *  anything) is simply never read, which is what makes this the
 *  enforcement point for "strip any key not listed" rather than a
 *  allowlist check that still leaves the original object reachable.
 *  Returns `undefined` (caller drops the whole request, not just this
 *  item -- see `parseMapCategoriesBody`) when `id`/`name` are missing or
 *  `name` exceeds `MAX_NAME_CHARS`, or when `pointsPossible`/
 *  `submissionTypes` are present but the wrong shape. */
function parseItem(value: unknown): CategoryMapItem | undefined {
  if (!isPlainObject(value)) return undefined;
  const { id, name, pointsPossible, submissionTypes } = value;
  if (!isNonEmptyString(id) || !isNonEmptyString(name) || name.length > MAX_NAME_CHARS) return undefined;

  const item: CategoryMapItem = { id, name };

  if (pointsPossible !== undefined) {
    if (typeof pointsPossible !== "number" || !Number.isFinite(pointsPossible)) return undefined;
    item.pointsPossible = pointsPossible;
  }

  if (submissionTypes !== undefined) {
    if (!Array.isArray(submissionTypes) || !submissionTypes.every((entry): entry is string => typeof entry === "string")) {
      return undefined;
    }
    item.submissionTypes = submissionTypes;
  }

  return item;
}

function parseGroup(value: unknown): CategoryMapGroup | undefined {
  if (!isPlainObject(value)) return undefined;
  const { id, name, items } = value;
  if (!isNonEmptyString(id) || !isNonEmptyString(name) || name.length > MAX_NAME_CHARS) return undefined;
  if (!Array.isArray(items)) return undefined;

  const parsedItems: CategoryMapItem[] = [];
  for (const rawItem of items) {
    const item = parseItem(rawItem);
    if (!item) return undefined;
    parsedItems.push(item);
  }

  return { id, name, items: parsedItems };
}

/**
 * Validates and reshapes the request body per PROTOCOL.md's
 * "map-categories" limits: at most `MAX_GROUPS` groups, at most
 * `MAX_ITEMS_TOTAL` items total across every group, every name at most
 * `MAX_NAME_CHARS` characters. Any violation -- including a single
 * malformed group or item anywhere in the list -- rejects the whole
 * request (`undefined`) rather than silently dropping the offending entry,
 * because a client sending a malformed request is a client bug worth a
 * 400, not a partially-honored request that quietly maps fewer items than
 * it asked for.
 */
export function parseMapCategoriesBody(value: unknown): MapCategoriesRequestBody | undefined {
  if (!isPlainObject(value)) return undefined;
  const { courseID, groups } = value;
  if (!isNonEmptyString(courseID)) return undefined;
  if (!Array.isArray(groups) || groups.length > MAX_GROUPS) return undefined;

  const parsedGroups: CategoryMapGroup[] = [];
  let totalItems = 0;
  for (const rawGroup of groups) {
    const group = parseGroup(rawGroup);
    if (!group) return undefined;
    totalItems += group.items.length;
    if (totalItems > MAX_ITEMS_TOTAL) return undefined;
    parsedGroups.push(group);
  }

  return { courseID, groups: parsedGroups };
}

// ---------------------------------------------------------------------
// Canonical structure hash
// ---------------------------------------------------------------------

/**
 * Reduces `groups` to the fields the cache key is actually built from --
 * name, points, submission types -- sorted by id at both the group and
 * item level, so two requests describing the identical course structure
 * hash identically regardless of what order Canvas's own API (or the
 * client's own iteration) happened to list groups and items in. This is
 * the same order-independence discipline `profileSourceHash`
 * (`_shared/profile.ts`) and `buildMessages` (`_shared/prompt.ts`) hold
 * their own hashes/prompts to, and for the identical reason: without it, a
 * cache keyed on this hash would treat "the same structure, listed in a
 * different order" as a structure change and needlessly re-call the
 * model.
 */
function canonicalStructure(groups: CategoryMapGroup[]): unknown {
  return groups
    .slice()
    .sort((a, b) => a.id.localeCompare(b.id))
    .map((group) => ({
      id: group.id,
      name: group.name,
      items: group.items
        .slice()
        .sort((a, b) => a.id.localeCompare(b.id))
        .map((item) => {
          const out: Record<string, unknown> = { id: item.id, name: item.name };
          if (item.pointsPossible !== undefined) out.pointsPossible = item.pointsPossible;
          if (item.submissionTypes !== undefined) out.submissionTypes = item.submissionTypes;
          return out;
        }),
    }));
}

/**
 * sha-256 hex digest, truncated to its first 16 characters (plenty of
 * collision resistance for "is this the same structure as last time",
 * and a shorter string to store/compare than a full 64-character digest),
 * of `stableStringify`'s rendering of `canonicalStructure(groups)`.
 * Deliberately excludes `courseID` -- the hash is stored *on* a
 * per-course `course_profiles` row (see the
 * `20260910120000_category_map.sql` migration), so the course identity is
 * already the row key and folding it into the hash itself would add
 * nothing but the theoretical (and here irrelevant) ability to compare
 * hashes across courses. Reuses `_shared/prompt.ts`'s `stableStringify`
 * for the same jsonb-key-order-independence reason `courseProfileBlock`
 * does, rather than a second stable-JSON implementation.
 */
export async function structureHash(groups: CategoryMapGroup[]): Promise<string> {
  const canonical = canonicalStructure(groups);
  const bytes = new TextEncoder().encode(stableStringify(canonical));
  const digest = await crypto.subtle.digest("SHA-256", bytes);
  const hex = Array.from(new Uint8Array(digest)).map((byte) => byte.toString(16).padStart(2, "0")).join("");
  return hex.slice(0, 16);
}

// ---------------------------------------------------------------------
// Model instructions and prompt building
// ---------------------------------------------------------------------

export const CATEGORY_MAP_INSTRUCTIONS: string = [
  `You map a Penn course's Canvas assignment groups onto the grading `
  + `categories its syllabus already defines, for a student's grade `
  + `tracker. Respond with a single JSON object and nothing else -- no `
  + `prose before or after it, no markdown code fence, no commentary.`,

  `Use exactly this shape:\n`
  + `{ "categories": [ { "name": string, "canvasGroupIDs": [string], `
  + `"itemIDs": [string], "expectedCount"?: number } ],\n`
  + `  "excludedItemIDs": [string],\n`
  + `  "reasons": { "<id>": string } }`,

  `Every "name" you emit MUST be copied verbatim from the SYLLABUS `
  + `CATEGORIES list below -- never invent a category the syllabus doesn't `
  + `have, and never rename or reword one. A Canvas group that doesn't `
  + `belong to any syllabus category is left out of every category's `
  + `"canvasGroupIDs" (its items may still need individual handling per the `
  + `rules below).`,

  `Every Canvas group belongs to at most one syllabus category -- put its `
  + `id in exactly one category's "canvasGroupIDs", never more than one.`,

  `An attendance, roll-call or participation item belongs in an `
  + `attendance/participation syllabus category when the SYLLABUS `
  + `CATEGORIES list has one -- put its id in that category's "itemIDs". `
  + `When no such category exists, put its id in "excludedItemIDs" instead, `
  + `with a short reason in "reasons".`,

  `A zero-point item that cannot actually be scored (a placeholder, a `
  + `survey worth 0 points, a purely informational Canvas entry) belongs in `
  + `"excludedItemIDs" with a short reason in "reasons", not in any `
  + `category.`,

  `"expectedCount" on a category is the item count the SYLLABUS `
  + `CATEGORIES list states for it -- copy it exactly when present, omit `
  + `the field entirely when the syllabus doesn't state a count for that `
  + `category. Never guess a count from how many Canvas items you were `
  + `given.`,

  `"reasons" keys are ids from the CANVAS ASSIGNMENT GROUPS list (a group `
  + `id or an item id) and values are a short phrase explaining an `
  + `unusual placement -- most often why an id landed in `
  + `"excludedItemIDs", but also usable for a category assignment that `
  + `might not be obvious. Every id anywhere in your response `
  + `("canvasGroupIDs", "itemIDs", "excludedItemIDs", "reasons" keys) MUST `
  + `be one of the ids listed under CANVAS ASSIGNMENT GROUPS -- never `
  + `invent one.`,
].join("\n\n");

const SYLLABUS_CATEGORIES_HEADER = "SYLLABUS CATEGORIES:";
const CANVAS_GROUPS_HEADER = "CANVAS ASSIGNMENT GROUPS:";

function renderGradingWeight(weight: GradingWeight): string {
  const count = weight.expectedCount !== undefined ? `, expected ${weight.expectedCount} items` : "";
  return `- ${weight.name}: ${weight.percent}%${count}`;
}

function renderItem(item: CategoryMapItem): string {
  const points = item.pointsPossible !== undefined ? `${item.pointsPossible} pts` : "no points listed";
  const types = item.submissionTypes && item.submissionTypes.length > 0
    ? ` [${item.submissionTypes.join(", ")}]`
    : "";
  return `  - ${item.name} (${item.id}): ${points}${types}`;
}

function renderGroup(group: CategoryMapGroup): string {
  const header = `Group "${group.name}" (${group.id}):`;
  const items = group.items.length > 0 ? group.items.map(renderItem).join("\n") : "  (no items)";
  return `${header}\n${items}`;
}

/**
 * Renders the SYLLABUS CATEGORIES and CANVAS ASSIGNMENT GROUPS blocks the
 * model needs, in the same fixed group/item order `structureHash` sorts
 * to (by id) -- this prompt isn't part of a cached prefix the way
 * `ask`'s is, so byte-stability isn't required here for a caching reason,
 * but sorting anyway costs nothing and keeps this function's output
 * exercisable with a plain string-inclusion test regardless of the
 * caller's own array order.
 */
export function buildCategoryMapUserContent(
  gradingWeights: GradingWeight[],
  groups: CategoryMapGroup[],
): string {
  const sortedGroups = groups.slice().sort((a, b) => a.id.localeCompare(b.id));
  const categoriesBlock = gradingWeights.length > 0
    ? gradingWeights.map(renderGradingWeight).join("\n")
    : "(none)";
  const groupsBlock = sortedGroups.length > 0 ? sortedGroups.map(renderGroup).join("\n\n") : "(none)";

  return [
    `${SYLLABUS_CATEGORIES_HEADER}\n${categoriesBlock}`,
    `${CANVAS_GROUPS_HEADER}\n${groupsBlock}`,
  ].join("\n\n");
}

// ---------------------------------------------------------------------
// Response parsing / sanitizing
// ---------------------------------------------------------------------

export interface CategoryMappingCategory {
  name: string;
  canvasGroupIDs: string[];
  itemIDs: string[];
  expectedCount?: number;
}

export interface CategoryMapping {
  categories: CategoryMappingCategory[];
  excludedItemIDs: string[];
  reasons: Record<string, string>;
  extractedAt: string;
  structureHash: string;
}

export interface SanitizeCategoryMappingContext {
  /** The profile's `gradingWeights[].name` values, verbatim -- the only
   *  strings a category's "name" is allowed to equal. */
  validCategoryNames: readonly string[];
  /** Every group id present in the request that produced this mapping. */
  validGroupIDs: ReadonlySet<string>;
  /** Every item id present in the request that produced this mapping. */
  validItemIDs: ReadonlySet<string>;
  extractedAt: string;
  structureHash: string;
}

function isFiniteNonNegativeInteger(value: unknown): value is number {
  return typeof value === "number" && Number.isFinite(value) && Number.isInteger(value) && value >= 0;
}

/** Filters `value` down to the strings it contains that are members of
 *  `validIDs`, dropping anything else (a non-string element, or a string
 *  the request never listed) -- this is the enforcement point for "drop
 *  unknown ids" and, combined with the caller's `claimed` set, for "an id
 *  may appear in at most one category". `claimed` is mutated in place
 *  (ids accepted here are added to it) so the *next* category's call
 *  sees them as already taken -- first category in `raw.categories`'s own
 *  array order wins, per the brief. */
function filterKnownIDs(value: unknown, validIDs: ReadonlySet<string>, claimed: Set<string>): string[] {
  if (!Array.isArray(value)) return [];
  const kept: string[] = [];
  for (const entry of value) {
    if (typeof entry !== "string") continue;
    if (!validIDs.has(entry)) continue;
    if (claimed.has(entry)) continue; // already claimed by an earlier category -- first wins
    claimed.add(entry);
    kept.push(entry);
  }
  return kept;
}

/**
 * Validates and reshapes the model's raw parsed JSON into a
 * `CategoryMapping`, or `null` when `raw` isn't even a plain object (the
 * model returned something unusable -- a bare string, an array, `null`).
 * A pure function, independent of `JSON.parse`/fence-stripping (see
 * `parseCategoryMapping` below), so every rule PROTOCOL.md's
 * "map-categories" section states is directly testable against a plain
 * object literal:
 *
 * - `categories[].name` must equal one of `context.validCategoryNames`
 *   verbatim; a category naming anything else is dropped entirely (not
 *   just its name field) -- there is no category to keep once its
 *   identity is invalid.
 * - `canvasGroupIDs`/`itemIDs`/`excludedItemIDs` are filtered to ids the
 *   request actually listed; unknown ids are dropped silently.
 * - Group ids and item ids each occupy their own id space for the
 *   "at most one category" rule -- a group id and an item id are
 *   generated by different client-side counters and could theoretically
 *   collide as strings, but a client's own `id`s are opaque to this
 *   function, so `canvasGroupIDs` and `itemIDs` are tracked with separate
 *   `claimed` sets rather than one shared set, matching how the wire
 *   contract itself keeps them as two distinct fields throughout.
 * - `expectedCount` is kept only when it is a finite non-negative
 *   integer; anything else (a fraction, a negative, a string) is omitted,
 *   never coerced.
 * - `excludedItemIDs` is filtered to known item ids the same way, with no
 *   cross-check against what a category already claimed -- a model
 *   contradicting itself (naming an id both included and excluded) is a
 *   model quality issue for the app to notice and surface, not something
 *   this sanitizer resolves by guessing which claim is more authoritative.
 * - `reasons` keeps only entries whose key is a known group or item id and
 *   whose value is a string; everything else is dropped.
 */
export function sanitizeCategoryMapping(
  raw: unknown,
  context: SanitizeCategoryMappingContext,
): CategoryMapping | null {
  if (!isPlainObject(raw)) return null;

  const claimedGroupIDs = new Set<string>();
  const claimedItemIDs = new Set<string>();
  const categories: CategoryMappingCategory[] = [];

  const rawCategories = Array.isArray(raw.categories) ? raw.categories : [];
  for (const entry of rawCategories) {
    if (!isPlainObject(entry)) continue;
    const name = entry.name;
    if (typeof name !== "string" || !context.validCategoryNames.includes(name)) continue;

    const canvasGroupIDs = filterKnownIDs(entry.canvasGroupIDs, context.validGroupIDs, claimedGroupIDs);
    const itemIDs = filterKnownIDs(entry.itemIDs, context.validItemIDs, claimedItemIDs);

    const category: CategoryMappingCategory = { name, canvasGroupIDs, itemIDs };
    if (isFiniteNonNegativeInteger(entry.expectedCount)) category.expectedCount = entry.expectedCount;
    categories.push(category);
  }

  const validIDs = new Set<string>([...context.validGroupIDs, ...context.validItemIDs]);
  const excludedItemIDs = Array.isArray(raw.excludedItemIDs)
    ? raw.excludedItemIDs.filter((id): id is string => typeof id === "string" && context.validItemIDs.has(id))
    : [];

  const reasons: Record<string, string> = {};
  if (isPlainObject(raw.reasons)) {
    for (const [key, value] of Object.entries(raw.reasons)) {
      if (typeof value === "string" && validIDs.has(key)) reasons[key] = value;
    }
  }

  return {
    categories,
    excludedItemIDs,
    reasons,
    extractedAt: context.extractedAt,
    structureHash: context.structureHash,
  };
}

function extractJSON(text: string): string {
  const fenced = text.match(/```(?:json)?\s*([\s\S]*?)```/i);
  return (fenced ? fenced[1] : text).trim();
}

/**
 * Parses the model's response text (tolerant of a fenced ```json block,
 * for the same reason `profile.ts`'s `parseProfile` is) and sanitizes it.
 * Unparseable JSON, or JSON that isn't a plain object, comes back `null` --
 * the same "one course's malformed extraction must not fail the whole
 * request" posture `parseProfile` takes, except here there is only ever
 * one course per request, so `null` becomes the response's top-level
 * `{ "mapping": null }` rather than a batch continuing without this one
 * entry.
 */
export function parseCategoryMapping(
  text: string,
  context: SanitizeCategoryMappingContext,
): CategoryMapping | null {
  let raw: unknown;
  try {
    raw = JSON.parse(extractJSON(text));
  } catch {
    return null;
  }
  return sanitizeCategoryMapping(raw, context);
}
