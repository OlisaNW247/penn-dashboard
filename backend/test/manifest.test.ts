// Unit tests for the pure manifest logic in
// supabase/functions/_shared/manifest.ts. Run with `deno task test` (see
// backend/deno.json) or `deno test test/manifest.test.ts` directly. No
// network, no database -- everything this file imports is pure.
import {
  CAPABILITY_GATED_KINDS,
  capWindowDocuments,
  diffManifest,
  filterByAcceptedKinds,
  freshCourses,
  goneIDs,
  isWindowKind,
  MAX_LINK_HREF_LENGTH,
  MAX_WINDOW_DOWNLOAD_PER_COURSE,
  liveIDsRetirableBy,
  MAX_TEXT_LENGTH,
  ManifestValidationError,
  parseAcceptsKinds,
  parseDocumentID,
  parseSyncClient,
  profileStaleCourses,
  retirableCollector,
  validateCourse,
  validateDocument,
  storableText,
  validateDocuments,
  WINDOW_KIND_MAX_AGE_DAYS,
  WINDOW_KINDS,
  windowAgeOutFilter,
  validateDocumentStub,
  validateFullySyncedCourse,
  validateLink,
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

Deno.test("validateDocument accepts kind ed", () => {
  const doc = validateDocument(
    validDocumentInput({ kind: "ed", id: "ed:100:8675309", sourceID: "8675309" }),
  );
  assertEquals(doc.kind, "ed");
  assertEquals(doc.id, "ed:100:8675309");
  assertEquals(doc.sourceID, "8675309");
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

Deno.test("validateCourse accepts a well-formed section", () => {
  const course = validateCourse({ courseID: "100", code: "PHYS 151", name: "Physics 151", section: "401" });
  assertEquals(course.section, "401");
});

Deno.test("validateCourse accepts an 8-character alphanumeric section", () => {
  const course = validateCourse({ courseID: "100", code: "PHYS 151", name: "Physics 151", section: "AbC12345" });
  assertEquals(course.section, "AbC12345");
});

Deno.test("validateCourse leaves section undefined when absent", () => {
  const course = validateCourse({ courseID: "100", code: "PHYS 151", name: "Physics 151" });
  assertEquals(course.section, undefined);
});

Deno.test("validateCourse rejects a section longer than 8 characters", () => {
  assertThrows(
    () => validateCourse({ courseID: "100", code: "PHYS 151", name: "Physics 151", section: "123456789" }),
    ManifestValidationError,
  );
});

Deno.test("validateCourse rejects a section with non-alphanumeric characters", () => {
  assertThrows(
    () => validateCourse({ courseID: "100", code: "PHYS 151", name: "Physics 151", section: "401-A" }),
    ManifestValidationError,
  );
});

Deno.test("validateCourse rejects an empty-string section", () => {
  assertThrows(
    () => validateCourse({ courseID: "100", code: "PHYS 151", name: "Physics 151", section: "" }),
    ManifestValidationError,
  );
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

// ---------------------------------------------------------------------
// validateLink
// ---------------------------------------------------------------------

function validLinkInput(overrides: Record<string, unknown> = {}): Record<string, unknown> {
  return {
    courseID: "100",
    href: "https://www.seas.upenn.edu/~cis2400/current/",
    text: "course website",
    origin: "page",
    ...overrides,
  };
}

Deno.test("validateLink: accepts a well-formed link", () => {
  const link = validateLink(validLinkInput());
  assertEquals(link, {
    courseID: "100",
    href: "https://www.seas.upenn.edu/~cis2400/current/",
    text: "course website",
    origin: "page",
  });
});

Deno.test("validateLink: text defaults to empty string when absent", () => {
  const input = validLinkInput();
  delete input["text"];
  const link = validateLink(input);
  assertEquals(link.text, "");
});

Deno.test("validateLink: accepts every LinkOrigin value", () => {
  for (const origin of ["page", "assignment", "module", "syllabus"]) {
    const link = validateLink(validLinkInput({ origin }));
    assertEquals(link.origin, origin);
  }
});

Deno.test("validateLink: rejects an unknown origin", () => {
  assertThrows(() => validateLink(validLinkInput({ origin: "announcement" })), ManifestValidationError);
});

Deno.test("validateLink: rejects a missing courseID or href", () => {
  const withoutCourseID = validLinkInput();
  delete withoutCourseID["courseID"];
  assertThrows(() => validateLink(withoutCourseID), ManifestValidationError);

  const withoutHref = validLinkInput();
  delete withoutHref["href"];
  assertThrows(() => validateLink(withoutHref), ManifestValidationError);
});

Deno.test("validateLink: rejects an href over MAX_LINK_HREF_LENGTH", () => {
  const longHref = "https://example.org/" + "a".repeat(MAX_LINK_HREF_LENGTH);
  assertThrows(() => validateLink(validLinkInput({ href: longHref })), ManifestValidationError);
});

Deno.test("validateLink: rejects a non-object entry", () => {
  assertThrows(() => validateLink("not an object"), ManifestValidationError);
});

// ---- Chrome extension: client, collector, acceptsKinds ----------------

Deno.test("parseSyncClient: absent means phone, only two values are valid", () => {
  assertEquals(parseSyncClient(undefined), "phone");
  assertEquals(parseSyncClient(null), "phone");
  assertEquals(parseSyncClient("phone"), "phone");
  assertEquals(parseSyncClient("extension"), "extension");
  assertThrows(() => parseSyncClient("Extension"), ManifestValidationError);
  assertThrows(() => parseSyncClient(1), ManifestValidationError);
});

Deno.test("complete-set: a phone retires only phone-collected rows, never a window kind", () => {
  const live = [
    { id: "page:1:1", kind: "page", collector: "phone" },
    { id: "announcement:1:2", kind: "announcement", collector: "extension" },
    { id: "file:1:3", kind: "file", collector: "extension" },
    { id: "ed:1:4", kind: "ed", collector: "phone" },
    { id: "page:1:5", kind: "page" }, // a row read without the column: the default is phone
  ];
  assertEquals(retirableCollector("phone"), "phone");
  assertEquals(liveIDsRetirableBy(live, "phone"), ["page:1:1", "page:1:5"]);
});

Deno.test("complete-set: the extension's report applies to every collector, still not a window kind", () => {
  const live = [
    { id: "page:1:1", kind: "page", collector: "phone" },
    { id: "announcement:1:2", kind: "announcement", collector: "extension" },
    { id: "ed:1:4", kind: "ed", collector: "extension" },
  ];
  assertEquals(retirableCollector("extension"), undefined);
  assertEquals(liveIDsRetirableBy(live, "extension"), ["page:1:1"]);
});

Deno.test("complete-set composed with goneIDs: nobody's list retires an announcement", () => {
  const live = [
    { id: "page:1:1", kind: "page", collector: "phone" },
    { id: "announcement:1:2", kind: "announcement", collector: "extension" },
  ];
  // The phone lists only the page it knows about.
  assertEquals(goneIDs(liveIDsRetirableBy(live, "phone"), ["page:1:1"]), []);
  // The extension, listing only the announcement, retires the stale page,
  // and the announcement is not in its retirable set to begin with.
  assertEquals(goneIDs(liveIDsRetirableBy(live, "extension"), ["announcement:1:2"]), ["page:1:1"]);
  // A client whose announcements request failed lists none; the pooled
  // announcement survives either way.
  assertEquals(goneIDs(liveIDsRetirableBy(live, "extension"), []), ["page:1:1"]);
});

Deno.test("file is a valid uploaded kind, and is not profile input", () => {
  const doc = validateDocument(validDocumentInput({ id: "file:100:9", kind: "file", sourceID: "9" }));
  assertEquals(doc.kind, "file");
  const before = new Map<string, string>();
  const after = new Map([["file:100:9", "h"]]);
  assertEquals([...profileStaleCourses(before, after, () => "file")], []);
});

Deno.test("parseAcceptsKinds: absent is empty, bad shapes are refused, unknown strings pass through", () => {
  assertEquals(parseAcceptsKinds(undefined), []);
  assertEquals(parseAcceptsKinds(["file", "future-kind"]), ["file", "future-kind"]);
  assertThrows(() => parseAcceptsKinds("file"), ManifestValidationError);
  assertThrows(() => parseAcceptsKinds([1]), ManifestValidationError);
  assertThrows(() => parseAcceptsKinds(Array(33).fill("file")), ManifestValidationError);
});

Deno.test("filterByAcceptedKinds withholds file unless accepted, leaves every other kind", () => {
  const docs = [
    { id: "page:1:1", kind: "page" },
    { id: "file:1:2", kind: "file" },
    { id: "ed:1:3", kind: "ed" },
  ];
  assertEquals(CAPABILITY_GATED_KINDS, ["file"]);
  assertEquals(filterByAcceptedKinds(docs, []).map((d) => d.id), ["page:1:1", "ed:1:3"]);
  assertEquals(filterByAcceptedKinds(docs, ["page"]).map((d) => d.id), ["page:1:1", "ed:1:3"]);
  assertEquals(filterByAcceptedKinds(docs, ["file"]).map((d) => d.id), ["page:1:1", "file:1:2", "ed:1:3"]);
});

Deno.test("a withheld file is in neither download nor serverManifest", () => {
  const docs = filterByAcceptedKinds(
    [
      { id: "page:1:1", kind: "page", contentHash: "a" },
      { id: "file:1:2", kind: "file", contentHash: "b" },
    ],
    [],
  );
  const { download, serverManifest } = diffManifest([], docs);
  assertEquals(download.map((d) => d.id), ["page:1:1"]);
  assertEquals(serverManifest.map((d) => d.id), ["page:1:1"]);
});

// ---- Window kinds: exemption, age-out, per-course cap, per-document rejection

Deno.test("WINDOW_KINDS is announcement and ed, and nothing else is a window kind", () => {
  assertEquals([...WINDOW_KINDS], ["announcement", "ed"]);
  for (const kind of ["home", "syllabus", "assignment", "module", "page", "website", "file"]) {
    assertFalse(isWindowKind(kind), kind);
  }
  assert(isWindowKind("announcement") && isWindowKind("ed"));
});

Deno.test("complete-set: an announcement is never retirable, whoever reports and whoever collected it", () => {
  const live = [
    { id: "announcement:1:1", kind: "announcement", collector: "phone" },
    { id: "announcement:1:2", kind: "announcement", collector: "extension" },
    { id: "ed:1:3", kind: "ed", collector: "extension" },
    { id: "syllabus:1:4", kind: "syllabus", collector: "phone" },
  ];
  assertEquals(liveIDsRetirableBy(live, "phone"), ["syllabus:1:4"]);
  assertEquals(liveIDsRetirableBy(live, "extension"), ["syllabus:1:4"]);
});

Deno.test("windowAgeOutFilter: the exact PostgREST or-expression, 120 days back from the caller's now", () => {
  assertEquals(WINDOW_KIND_MAX_AGE_DAYS, 120);
  // 2026-10-23 minus 120 days is 2026-06-25.
  const filter = windowAgeOutFilter(new Date("2026-10-23T12:00:00.000Z"));
  assertEquals(
    filter,
    "kind.not.in.(announcement,ed),updated_at.gte.2026-06-25T12:00:00.000Z," +
      "and(updated_at.is.null,fetched_at.gte.2026-06-25T12:00:00.000Z)",
  );
});

function windowDoc(n: number, overrides: Record<string, unknown> = {}) {
  return {
    id: `announcement:c1:${n}`,
    contentHash: `h${n}`,
    kind: "announcement" as const,
    courseID: "c1",
    // n = 1 is the oldest, a day apart.
    updatedAt: new Date(Date.UTC(2026, 0, 1) + n * 86_400_000).toISOString(),
    fetchedAt: "2026-10-01T00:00:00.000Z",
    ...overrides,
  };
}

Deno.test("diffManifest: 160 announcements in one course send the newest 150 and list all 160", () => {
  assertEquals(MAX_WINDOW_DOWNLOAD_PER_COURSE, 150);
  const docs = Array.from({ length: 160 }, (_, i) => windowDoc(i + 1));
  const { download, serverManifest } = diffManifest([], docs, {
    maxWindowPerCourse: MAX_WINDOW_DOWNLOAD_PER_COURSE,
  });
  assertEquals(download.length, 150);
  assertEquals(serverManifest.length, 160);
  // The ten oldest (1..10) are the ones left out.
  const sent = new Set(download.map((d) => d.id));
  for (let n = 1; n <= 10; n++) assertFalse(sent.has(`announcement:c1:${n}`), `n=${n}`);
  assert(sent.has("announcement:c1:11") && sent.has("announcement:c1:160"));
});

Deno.test("diffManifest cap: per course, census kinds untouched, fetchedAt stands in for a missing updatedAt", () => {
  const docs = [
    windowDoc(1, { courseID: "c1" }),
    windowDoc(2, { courseID: "c1" }),
    windowDoc(3, { courseID: "c1", updatedAt: undefined, fetchedAt: "2030-01-01T00:00:00.000Z" }),
    windowDoc(4, { id: "announcement:c2:4", courseID: "c2" }),
    { id: "page:c1:1", contentHash: "p", kind: "page", courseID: "c1", fetchedAt: "2026-01-01T00:00:00.000Z" },
  ];
  const { download, serverManifest } = diffManifest([], docs, { maxWindowPerCourse: 1 });
  // c1 keeps only #3 (fetchedAt 2030 is newest); c2's single row stays; the page stays.
  assertEquals(download.map((d) => d.id), ["announcement:c1:3", "announcement:c2:4", "page:c1:1"]);
  assertEquals(serverManifest.length, 5);
});

Deno.test("diffManifest without options sends everything, as before", () => {
  const docs = Array.from({ length: 160 }, (_, i) => windowDoc(i + 1));
  assertEquals(diffManifest([], docs).download.length, 160);
  assertEquals(capWindowDocuments(docs, 160).length, 160);
});

Deno.test("validateDocuments: one empty-text document is rejected alone and the other is kept", () => {
  const good = {
    id: "announcement:1:10", courseID: "1", course: "CIS 1200", kind: "announcement", sourceID: "10",
    title: "Hello", text: "body", fetchedAt: "2026-10-23T00:00:00Z", contentHash: "a",
  };
  const bad = { ...good, id: "announcement:1:11", sourceID: "11", text: "" };
  const { documents, rejected } = validateDocuments([good, bad, "not an object"]);
  assertEquals(documents.map((d) => d.id), ["announcement:1:10"]);
  assertEquals(rejected.length, 2);
  assertEquals(rejected[0], { id: "announcement:1:11", reason: 'expected non-empty string field "text"' });
  assertEquals(rejected[1].id, "");
  // validateDocument itself still throws, which is what the loop catches.
  assertThrows(() => validateDocument(bad), ManifestValidationError);
});

// 2026-10-27: one PDF whose text held NULs made Postgres refuse the upsert,
// and the whole 200-document batch failed with a 500.
Deno.test("storableText drops NULs and mends lone surrogates, keeping real pairs", () => {
  assertEquals(storableText("a\u0000b\u0000"), "ab");
  assertEquals(storableText("x\ud800y"), "x\ufffdy");
  assertEquals(storableText("x\udc00y"), "x\ufffdy");
  assertEquals(storableText("ok \ud83d\ude00"), "ok \ud83d\ude00");
});

Deno.test("validateDocument cleans title, course, url and text, and keeps the client's hash", () => {
  const doc = validateDocument(validDocumentInput({
    title: "Exam\u0000 1", course: "PHYS\u0000 151", url: "https://x.test/\u0000a", text: "Q1\u0000 \ud800done",
  }));
  assertEquals(doc.title, "Exam 1");
  assertEquals(doc.course, "PHYS 151");
  assertEquals(doc.url, "https://x.test/a");
  assertEquals(doc.text, "Q1 \ufffddone");
  assertEquals(doc.contentHash, "abc123");
  assertEquals(JSON.stringify(doc).includes("\\u0000"), false);
});

Deno.test("validateDocuments: a document whose text is only NULs is rejected alone", () => {
  const { documents, rejected } = validateDocuments([
    validDocumentInput(),
    validDocumentInput({ id: "syllabus:100:2", sourceID: "2", text: "\u0000\u0000" }),
  ]);
  assertEquals(documents.map((d) => d.id), ["syllabus:100:1"]);
  assertEquals(rejected, [{ id: "syllabus:100:2", reason: 'expected non-empty string field "text"' }]);
});
