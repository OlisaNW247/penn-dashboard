// Unit tests for the pure manifest logic in
// supabase/functions/_shared/manifest.ts. Run with `deno task test` (see
// backend/deno.json) or `deno test test/manifest.test.ts` directly. No
// network, no database -- everything this file imports is pure.
import {
  diffManifest,
  freshCourses,
  goneIDs,
  MAX_TEXT_LENGTH,
  ManifestValidationError,
  parseDocumentID,
  profileStaleCourses,
  validateCourse,
  validateDocument,
  validateDocumentStub,
  validateFullySyncedCourse,
  type CourseDocumentWire,
  type DocumentKind,
} from "../supabase/functions/_shared/manifest.ts";

// Tiny local assertion helpers rather than pulling in std/assert -- keeps
// this test file dependency-free (no jsr:/esm.sh specifier, which may not
// be reachable in every environment this runs in) beyond the module under
// test.
function assertEquals<T>(actual: T, expected: T, message?: string): void {
  const same = JSON.stringify(actual) === JSON.stringify(expected);
  if (!same) {
    throw new Error(message ?? `expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}

function assert(condition: boolean, message?: string): void {
  if (!condition) throw new Error(message ?? "assertion failed");
}

function assertFalse(condition: boolean, message?: string): void {
  assert(!condition, message ?? "expected condition to be false");
}

function assertThrows(fn: () => unknown, expectedErrorClass?: new (...args: never[]) => Error): void {
  try {
    fn();
  } catch (err) {
    if (expectedErrorClass && !(err instanceof expectedErrorClass)) {
      throw new Error(`expected error of type ${expectedErrorClass.name}, got ${String(err)}`);
    }
    return;
  }
  throw new Error("expected function to throw, but it did not");
}

function validDocumentInput(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    id: "syllabus:100:1",
    courseID: "100",
    course: "PHYS 151",
    kind: "syllabus",
    sourceID: "1",
    title: "Syllabus",
    text: "Welcome to the course.",
    fetchedAt: "2026-09-07T00:00:00Z",
    contentHash: "abc123",
    ...overrides,
  };
}

Deno.test("validateDocument accepts a well-formed document", () => {
  const doc = validateDocument(validDocumentInput());
  assertEquals(doc.id, "syllabus:100:1");
  assertEquals(doc.courseID, "100");
  assertEquals(doc.kind, "syllabus");
});

Deno.test("validateDocument rejects an id that doesn't match kind:courseID:sourceID", () => {
  assertThrows(
    () => validateDocument(validDocumentInput({ id: "syllabus:999:1" })),
    ManifestValidationError,
  );
});

Deno.test("validateDocument rejects an unknown kind", () => {
  assertThrows(
    () => validateDocument(validDocumentInput({ kind: "quiz", id: "quiz:100:1" })),
    ManifestValidationError,
  );
});

Deno.test("validateDocument strips a submitted key rather than rejecting the document", () => {
  const raw = validDocumentInput({ submitted: true });
  const doc = validateDocument(raw);
  assertFalse(Object.prototype.hasOwnProperty.call(doc, "submitted"));
  // Also prove it was removed from the source object, since validateDocument
  // deletes it in place before reading other fields.
  assertFalse(Object.prototype.hasOwnProperty.call(raw, "submitted"));
});

Deno.test("validateDocument caps text length at MAX_TEXT_LENGTH", () => {
  const longText = "x".repeat(MAX_TEXT_LENGTH + 500);
  const doc = validateDocument(validDocumentInput({ text: longText }));
  assertEquals(doc.text.length, MAX_TEXT_LENGTH);
});

Deno.test("validateDocument rejects a missing required field", () => {
  const raw = validDocumentInput();
  delete raw["title"];
  assertThrows(() => validateDocument(raw), ManifestValidationError);
});

Deno.test("validateCourse accepts a well-formed course and rejects a missing field", () => {
  const course = validateCourse({ courseID: "100", code: "PHYS 151", name: "Physics 151" });
  assertEquals(course.courseID, "100");
  assertEquals(course.url, undefined);

  assertThrows(() => validateCourse({ code: "PHYS 151", name: "Physics 151" }), ManifestValidationError);
});

Deno.test("validateDocumentStub accepts a well-formed stub and rejects a bad one", () => {
  const stub = validateDocumentStub({ id: "syllabus:100:1", contentHash: "abc" });
  assertEquals(stub.id, "syllabus:100:1");
  assertThrows(() => validateDocumentStub({ id: "syllabus:100:1" }), ManifestValidationError);
});

Deno.test("validateFullySyncedCourse accepts a well-formed entry and rejects a bad one", () => {
  const fsc = validateFullySyncedCourse({ courseID: "100", documentIDs: ["a", "b"] });
  assertEquals(fsc.documentIDs, ["a", "b"]);
  assertThrows(
    () => validateFullySyncedCourse({ courseID: "100", documentIDs: "not-an-array" }),
    ManifestValidationError,
  );
});

Deno.test("parseDocumentID splits kind/courseID/sourceID and returns null for malformed ids", () => {
  assertEquals(parseDocumentID("syllabus:100:1"), { kind: "syllabus", courseID: "100", sourceID: "1" });
  // sourceID itself may contain colons; only the first two are structural.
  assertEquals(parseDocumentID("page:100:1:2"), { kind: "page", courseID: "100", sourceID: "1:2" });
  assertEquals(parseDocumentID("no-colons-here"), null);
  assertEquals(parseDocumentID("only:one-colon"), null);
});

function wireDoc(id: string, contentHash: string): CourseDocumentWire {
  const parsed = parseDocumentID(id)!;
  return {
    id,
    courseID: parsed.courseID,
    course: "PHYS 151",
    kind: parsed.kind as DocumentKind,
    sourceID: parsed.sourceID,
    title: "Title",
    text: "text",
    fetchedAt: "2026-09-07T00:00:00Z",
    contentHash,
  };
}

Deno.test("diffManifest downloads a server doc the client doesn't have at all", () => {
  const serverDocs = [wireDoc("syllabus:100:1", "hash-a")];
  const { download } = diffManifest([], serverDocs);
  assertEquals(download.length, 1);
  assertEquals(download[0].id, "syllabus:100:1");
});

Deno.test("diffManifest downloads a server doc whose hash differs from the client's", () => {
  const serverDocs = [wireDoc("syllabus:100:1", "hash-new")];
  const { download } = diffManifest([{ id: "syllabus:100:1", contentHash: "hash-old" }], serverDocs);
  assertEquals(download.length, 1);
  assertEquals(download[0].contentHash, "hash-new");
});

Deno.test("diffManifest does not download a doc the client already has identically", () => {
  const serverDocs = [wireDoc("syllabus:100:1", "hash-a")];
  const { download } = diffManifest([{ id: "syllabus:100:1", contentHash: "hash-a" }], serverDocs);
  assertEquals(download.length, 0);
});

Deno.test("diffManifest's serverManifest lists every live doc regardless of client match", () => {
  const serverDocs = [wireDoc("syllabus:100:1", "hash-a"), wireDoc("page:100:2", "hash-b")];
  const { serverManifest } = diffManifest([{ id: "syllabus:100:1", contentHash: "hash-a" }], serverDocs);
  assertEquals(serverManifest.length, 2);
  assert(serverManifest.some((s) => s.id === "page:100:2" && s.contentHash === "hash-b"));
});

Deno.test("goneIDs returns live ids absent from the uploaded set", () => {
  const result = goneIDs(["a", "b", "c"], ["a", "c"]);
  assertEquals(result, ["b"]);
});

Deno.test("goneIDs is empty when every live id was re-uploaded", () => {
  const result = goneIDs(["a", "b"], ["a", "b", "c"]);
  assertEquals(result, []);
});

Deno.test("profileStaleCourses ignores announcement/assignment hash changes", () => {
  const before = new Map([["announcement:100:1", "old"], ["assignment:100:2", "old"]]);
  const after = new Map([["announcement:100:1", "new"], ["assignment:100:2", "new"]]);
  const kindOf = (id: string): DocumentKind | undefined =>
    id.startsWith("announcement") ? "announcement" : "assignment";
  const stale = profileStaleCourses(before, after, kindOf);
  assertEquals(stale.size, 0);
});

Deno.test("profileStaleCourses detects a syllabus hash change", () => {
  const before = new Map([["syllabus:100:1", "old-hash"]]);
  const after = new Map([["syllabus:100:1", "new-hash"]]);
  const stale = profileStaleCourses(before, after, () => "syllabus");
  assertEquals([...stale], ["100"]);
});

Deno.test("profileStaleCourses detects a relevant doc appearing or disappearing", () => {
  const before = new Map<string, string>();
  const after = new Map([["page:200:9", "hash"]]);
  const stale = profileStaleCourses(before, after, () => "page");
  assertEquals([...stale], ["200"]);
});

Deno.test("profileStaleCourses is unaffected when an irrelevant kind is added", () => {
  const before = new Map<string, string>();
  const after = new Map([["announcement:200:9", "hash"]]);
  const stale = profileStaleCourses(before, after, () => "announcement");
  assertEquals(stale.size, 0);
});

Deno.test("freshCourses: a course synced just inside the window is fresh", () => {
  const now = new Date("2026-09-07T12:00:00Z");
  const lastSync = new Date(now.getTime() - 59 * 60_000); // 59 minutes ago, default window is 60
  const result = freshCourses([{ courseID: "100", lastFullSyncAt: lastSync }], now);
  assertEquals(result, ["100"]);
});

Deno.test("freshCourses: a course synced exactly at the window boundary is not fresh", () => {
  const now = new Date("2026-09-07T12:00:00Z");
  const lastSync = new Date(now.getTime() - 60 * 60_000); // exactly 60 minutes ago
  const result = freshCourses([{ courseID: "100", lastFullSyncAt: lastSync }], now);
  assertEquals(result, []);
});

Deno.test("freshCourses: a course with no prior full sync is never fresh", () => {
  const now = new Date("2026-09-07T12:00:00Z");
  const result = freshCourses([{ courseID: "100", lastFullSyncAt: null }], now);
  assertEquals(result, []);
});
