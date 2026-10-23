import { test } from "node:test";
import assert from "node:assert/strict";
import { courseDocumentWire } from "../src/core/canvasDocuments.js";
import {
  plan, uploads, uploadBatches, fullyFetchedCourseIDs, MAX_BATCH_DOCUMENTS, MAX_BODY_BYTES,
  PHONE_MAX_ENDPOINT_ERRORS,
} from "../src/core/syncPlan.js";

// SyncPlannerTests.swift helpers
const course = (id) => ({ courseID: id, code: `CIS ${id}` });
const doc = (courseID, sourceID, text, kind = "page") =>
  courseDocumentWire({
    courseID, course: `CIS ${courseID}`, kind, sourceID, title: `Doc ${sourceID}`, text,
    fetchedAt: new Date(1_000_000),
  });
const stub = (d) => ({ id: d.id, contentHash: d.contentHash });

// SyncPlannerTests.planSplitsFreshFromFetch
test("plan splits fresh courses from ones needing a fetch, preserving order", () => {
  const p = plan([course("3"), course("1"), course("2")], { coursesFresh: ["1"] });
  assert.deepEqual(p.coursesToFetch.map((c) => c.courseID), ["3", "2"]);
  assert.deepEqual([...p.coursesFresh], ["1"]);
});

// SyncPlannerTests.planFetchesAllWhenNothingFresh
test("plan with no fresh courses fetches everything in the original order", () => {
  const p = plan([course("2"), course("1")], {});
  assert.deepEqual(p.coursesToFetch.map((c) => c.courseID), ["2", "1"]);
  assert.equal(p.coursesFresh.size, 0);
});

// SyncPlannerTests.uploadsExcludesMatchingDocuments
test("uploads excludes documents the server already has with a matching hash", () => {
  const known = doc("1", "a", "unchanged");
  const changed = doc("1", "b", "new text");
  const request = uploads({
    local: [known, changed],
    serverManifest: [stub(known), { id: changed.id, contentHash: "stale-hash" }],
    fullyFetched: [],
  });
  assert.deepEqual(request.documents.map((d) => d.id), [changed.id]);
});

// SyncPlannerTests.uploadsIncludesEverythingWhenServerManifestEmpty
test("uploads includes every local document when the server manifest is empty", () => {
  const a = doc("1", "a", "a");
  const b = doc("1", "b", "b");
  const request = uploads({ local: [a, b], serverManifest: [], fullyFetched: [] });
  assert.deepEqual(new Set(request.documents.map((d) => d.id)), new Set([a.id, b.id]));
});

// SyncPlannerTests.uploadsFullySyncedCoursesSorted
test("uploads lists fullySyncedCourses only for fully fetched courses, with sorted document ids", () => {
  const d1 = doc("1", "z", "z");
  const d2 = doc("1", "a", "a");
  const d3 = doc("2", "x", "x");
  const request = uploads({ local: [d1, d2, d3], serverManifest: [], fullyFetched: ["1"] });
  assert.equal(request.fullySyncedCourses.length, 1);
  const entry = request.fullySyncedCourses[0];
  assert.equal(entry.courseID, "1");
  assert.deepEqual(entry.documentIDs, [...entry.documentIDs].sort());
  assert.deepEqual(new Set(entry.documentIDs), new Set([d1.id, d2.id]));
});

// SyncPlannerTests.uploadsSortsFullySyncedCourseOrder
test("uploads sorts fullySyncedCourses entries by course id", () => {
  const request = uploads({ local: [doc("1", "a", "a"), doc("2", "b", "b")], serverManifest: [], fullyFetched: new Set(["2", "1"]) });
  assert.deepEqual(request.fullySyncedCourses.map((c) => c.courseID), ["1", "2"]);
});

const fiveDocs = () => Array.from({ length: 5 }, (_, i) => doc("1", String(i), `t${i}`));

// SyncPlannerTests.uploadBatchesPutsFullySyncedCoursesOnLastBatchOnly
test("uploadBatches puts fullySyncedCourses only on the last batch", () => {
  const docs = fiveDocs();
  const request = { action: "upload", documents: docs, fullySyncedCourses: [{ courseID: "1", documentIDs: docs.map((d) => d.id) }], links: [] };
  const batches = uploadBatches(request, { maxDocuments: 2 });
  assert.equal(batches.length, 3);
  assert.ok(batches.slice(0, -1).every((b) => b.fullySyncedCourses.length === 0));
  assert.equal(batches.at(-1).fullySyncedCourses.length, 1);
  const allIDs = batches.flatMap((b) => b.documents.map((d) => d.id));
  assert.deepEqual(new Set(allIDs), new Set(docs.map((d) => d.id)));
  assert.equal(allIDs.length, docs.length);
});

// SyncPlannerTests.uploadBatchesEmptyDocumentsYieldsOneBatch
test("uploadBatches with no documents and fullySyncedCourses yields exactly one batch", () => {
  const request = { action: "upload", documents: [], fullySyncedCourses: [{ courseID: "1", documentIDs: [] }], links: [] };
  const batches = uploadBatches(request);
  assert.equal(batches.length, 1);
  assert.equal(batches[0].documents.length, 0);
  assert.equal(batches[0].fullySyncedCourses.length, 1);
});

// SyncPlannerTests.uploadBatchesSingleBatchWhenUnderLimit
test("uploadBatches with documents fitting in one batch under maxDocuments", () => {
  const docs = fiveDocs().slice(0, 3);
  const request = { action: "upload", documents: docs, fullySyncedCourses: [{ courseID: "1", documentIDs: docs.map((d) => d.id) }], links: [] };
  const batches = uploadBatches(request, { maxDocuments: 200 });
  assert.equal(batches.length, 1);
  assert.equal(batches[0].fullySyncedCourses.length, 1);
});

// SyncPlannerTests.uploadsForwardsLinks
test("uploads forwards links onto the request unfiltered", () => {
  const link = { courseID: "1", href: "https://example.com", text: "Site", origin: "page" };
  const request = uploads({ local: [doc("1", "a", "a")], serverManifest: [], fullyFetched: [], links: [link] });
  assert.deepEqual(request.links.map((l) => l.href), ["https://example.com"]);
  assert.deepEqual(request.links.map((l) => l.origin), ["page"]);
});

// SyncPlannerTests.uploadsDefaultsLinksToEmpty
test("uploads defaults links to empty when not given", () => {
  assert.deepEqual(uploads({ local: [doc("1", "a", "a")], serverManifest: [], fullyFetched: [] }).links, []);
});

// SyncPlannerTests.uploadBatchesPutsLinksOnLastBatchOnly
test("uploadBatches puts links only on the last batch", () => {
  const link = { courseID: "1", href: "https://example.com", text: "Site", origin: "page" };
  const request = { action: "upload", documents: fiveDocs(), fullySyncedCourses: [], links: [link] };
  const batches = uploadBatches(request, { maxDocuments: 2 });
  assert.equal(batches.length, 3);
  assert.ok(batches.slice(0, -1).every((b) => b.links.length === 0));
  assert.deepEqual(batches.at(-1).links, [link]);
});

// SyncPlannerTests.uploadBatchesEmptyDocumentsCarriesLinks
test("uploadBatches with no documents still carries links on the single batch", () => {
  const link = { courseID: "1", href: "https://example.com", text: "Site", origin: "page" };
  const batches = uploadBatches({ action: "upload", documents: [], fullySyncedCourses: [], links: [link] });
  assert.equal(batches.length, 1);
  assert.deepEqual(batches[0].links, [link]);
});

// No Swift test. SyncPlanner.uploadBatches defaults maxDocuments to 200.
test("uploadBatches defaults to 200 documents per batch", () => {
  assert.equal(MAX_BATCH_DOCUMENTS, 200);
  const docs = Array.from({ length: 450 }, (_, i) => doc("1", String(i).padStart(3, "0"), "t"));
  const batches = uploadBatches({ action: "upload", documents: docs, fullySyncedCourses: [{ courseID: "1", documentIDs: [] }], links: [] });
  assert.deepEqual(batches.map((b) => b.documents.length), [200, 200, 50]);
  assert.deepEqual(batches.map((b) => b.fullySyncedCourses.length), [0, 0, 1]);
});

// No Swift test: the 6 MB body limit (backend/PROTOCOL.md) the phone only
// approximates by document count.
test("uploadBatches also splits on the byte budget", () => {
  assert.equal(MAX_BODY_BYTES, 6 * 1024 * 1024);
  const big = (i) => doc("1", String(i), "é".repeat(1000)); // 2000 UTF-8 bytes of text each
  const docs = [0, 1, 2, 3, 4].map(big);
  const request = { action: "upload", documents: docs, fullySyncedCourses: [{ courseID: "1", documentIDs: docs.map((d) => d.id) }], links: [] };
  const batches = uploadBatches(request, { maxBytes: 5000 });
  assert.ok(batches.length >= 3);
  for (const b of batches) {
    assert.ok(new TextEncoder().encode(JSON.stringify(b)).length <= 5000 || b.documents.length === 1);
  }
  assert.deepEqual(batches.flatMap((b) => b.documents.map((d) => d.id)), docs.map((d) => d.id));
  // fullySyncedCourses still only on the last batch, after every document
  assert.ok(batches.slice(0, -1).every((b) => b.fullySyncedCourses.length === 0));
  assert.equal(batches.at(-1).fullySyncedCourses.length, 1);
});

test("uploadBatches: a trailer that would overflow the last batch rides in a final batch of its own", () => {
  const docs = [doc("1", "a", "x".repeat(300))];
  const ids = Array.from({ length: 200 }, (_, i) => `page:1:${i}`);
  const request = { action: "upload", documents: docs, fullySyncedCourses: [{ courseID: "1", documentIDs: ids }], links: [] };
  const withDoc = new TextEncoder().encode(JSON.stringify({ ...request, fullySyncedCourses: [] })).length;
  const batches = uploadBatches(request, { maxBytes: withDoc + 50 });
  assert.equal(batches.length, 2);
  assert.equal(batches[0].documents.length, 1);
  assert.equal(batches[0].fullySyncedCourses.length, 0);
  assert.equal(batches[1].documents.length, 0);
  assert.equal(batches[1].fullySyncedCourses.length, 1);
});

// No Swift test: the extension's upload carries `client`.
test("uploads and uploadBatches carry `client` only when given", () => {
  const request = uploads({ local: [doc("1", "a", "a")], serverManifest: [], fullyFetched: [], client: "extension" });
  assert.equal(request.client, "extension");
  assert.ok(uploadBatches(request).every((b) => b.client === "extension"));
  assert.ok(!("client" in uploads({ local: [], serverManifest: [], fullyFetched: [] })));
});

// CourseKnowledgeCollector.run's `courseErrors <= 1` rule, and the
// extension's stricter default.
test("fullyFetchedCourseIDs: zero failed endpoints by default; the phone's tolerance is a parameter", () => {
  const results = { 1: 0, 2: 1, 3: 2 };
  assert.deepEqual([...fullyFetchedCourseIDs(results)], ["1"]);
  assert.equal(PHONE_MAX_ENDPOINT_ERRORS, 1);
  assert.deepEqual([...fullyFetchedCourseIDs(results, { maxErrors: PHONE_MAX_ENDPOINT_ERRORS })], ["1", "2"]);
  assert.deepEqual([...fullyFetchedCourseIDs(new Map([["9", 0]]))], ["9"]);
});
