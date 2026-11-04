// Generates the contract fixtures the Swift tests decode:
//   LowHangingFruitKit/Tests/LowHangingFruitKitTests/Fixtures/manifest-with-facts.json
//   LowHangingFruitKit/Tests/LowHangingFruitKitTests/Fixtures/document-posted-at.json
//
// Regenerate (from the repo root; read-only on the backend, writes only the
// two fixture files) whenever `_shared/manifest.ts`, `_shared/db.ts` or the
// `handleManifest` assembly in `sync/index.ts` changes shape:
//
//   deno run --allow-read --allow-write --allow-env --allow-net=deno.land,jsr.io,registry.npmjs.org,esm.sh \
//     backend/test/fixtures/facts/make-swift-fixture.ts
//
// The manifest file is built by calling the SAME functions `handleManifest`
// calls (`documentRowToWire`, `filterByAcceptedKinds`, `diffManifest`,
// `freshCourses`, `profileRowToWire`, `factsResponse`) on hand-made DB rows,
// so the JSON shape is whatever the server code produces, not what anyone
// believes it produces. `catalog` is left empty: it needs a Penn Labs row and
// is not part of the facts contract. The only hand-written part is the rows.
//
// `document-posted-at.json` is `validateDocument`'s output for an upload that
// carries `postedAt`. `documentRowToWire` never serves `postedAt` back in
// `download` (by design, see `CourseDocumentWire.postedAt` in manifest.ts), so
// the field can only be exercised on the upload direction.

import { documentRowToWire, profileRowToWire } from "../../../supabase/functions/_shared/db.ts";
import type { CourseDocumentRow } from "../../../supabase/functions/_shared/db.ts";
import {
  diffManifest,
  factsResponse,
  filterByAcceptedKinds,
  freshCourses,
  validateDocument,
} from "../../../supabase/functions/_shared/manifest.ts";
import type { FactRowWithDocument } from "../../../supabase/functions/_shared/manifest.ts";

const outDir = new URL("../../../../LowHangingFruitKit/Tests/LowHangingFruitKitTests/Fixtures/", import.meta.url);

function docRow(over: Partial<CourseDocumentRow> & Pick<CourseDocumentRow, "kind" | "source_id" | "course_id" | "title">): CourseDocumentRow {
  return {
    id: `${over.kind}:${over.course_id}:${over.source_id}`,
    course_code: over.course_id === "1234" ? "CIS 2400" : "MATH 1400",
    url: `https://canvas.upenn.edu/courses/${over.course_id}/${over.kind}s/${over.source_id}`,
    text: `Body of ${over.title}.`,
    content_hash: `hash-${over.source_id}`,
    updated_at: "2026-11-01T12:00:00.000Z",
    fetched_at: "2026-11-02T08:30:00.000Z",
    due_at: null,
    points_possible: null,
    first_seen_at: "2026-11-01T12:00:00.000Z",
    gone_at: null,
    ...over,
  };
}

const rows: CourseDocumentRow[] = [
  docRow({ kind: "announcement", course_id: "1234", source_id: "55", title: "HW3 is cancelled", posted_at: "2026-11-02T09:00:00.000Z" }),
  docRow({ kind: "assignment", course_id: "1234", source_id: "555", title: "PSet 3", due_at: "2026-11-10T04:59:00.000Z", points_possible: 100 }),
  docRow({ kind: "syllabus", course_id: "99", source_id: "syllabus", title: "MATH 1400 syllabus" }),
];

const liveDocs = filterByAcceptedKinds(rows.map(documentRowToWire), []);
const { download, serverManifest } = diffManifest([], liveDocs, { maxWindowPerCourse: 150 });
const now = new Date("2026-11-04T12:00:00.000Z");
const coursesFresh = freshCourses(
  [{ courseID: "1234", lastFullSyncAt: "2026-11-04T11:50:00.000Z" }, { courseID: "99", lastFullSyncAt: null }],
  now,
);
const profiles = [
  profileRowToWire({
    course_id: "1234",
    updated_at: "2026-11-01T00:00:00.000Z",
    profile: {
      gradingWeights: [{ name: "Homework", percent: 40, expectedCount: 8, dropLowest: 1 }, { name: "Final", percent: 60 }],
      components: [{ name: "Lecture", gradingBasis: "graded", creditUnits: 1 }],
      examDates: [{ name: "Final Exam", date: "2026-12-15", text: "Final exam Dec 15" }],
    },
  }),
  // A legacy row with nothing usable in it: the server must still answer.
  profileRowToWire({ course_id: "99", updated_at: "2026-10-01T00:00:00.000Z", profile: "not an object" }),
];

function factRow(
  seq: number,
  type: FactRowWithDocument["fact_type"],
  over: Partial<FactRowWithDocument> = {},
): FactRowWithDocument {
  return {
    seq,
    course_id: "1234",
    document_id: "announcement:1234:55",
    content_hash: "hash-55",
    fact_type: type,
    target_source_id: "555",
    title: null,
    due_at: null,
    kind: null,
    quote: "the quote",
    confidence: "high",
    posted_at: "2026-11-02T09:00:00.000Z",
    course_documents: { content_hash: "hash-55", gone_at: null },
    ...over,
  };
}

const factRows: FactRowWithDocument[] = [
  factRow(101, "cancel"),
  factRow(102, "reschedule", { due_at: "2026-11-12T04:59:00.000Z", quote: "now due Thursday" }),
  factRow(103, "new_task", { target_source_id: null, title: "Read ch. 5", due_at: "2026-11-09T14:00:00.000Z", kind: "preparation", confidence: "medium", posted_at: null }),
  factRow(104, "needs_review", { target_source_id: "module:abc", quote: "maybe moved?", confidence: "medium" }),
  // Withheld (document edited since extraction): never served, still moves the cursor.
  factRow(107, "cancel", { content_hash: "stale-hash" }),
];
const { facts, factsCursor } = factsResponse(factRows, 100);

const manifest = { coursesFresh, serverManifest, download, catalog: [], profiles, facts, factsCursor };

const validated = validateDocument({
  id: "announcement:1234:56",
  courseID: "1234",
  course: "CIS 2400",
  kind: "announcement",
  sourceID: "56",
  title: "Posted with a date",
  text: "Body.",
  fetchedAt: "2026-11-02T08:30:00Z",
  contentHash: "hash-56",
  postedAt: "2026-11-02T04:00:00-05:00",
});

await Deno.writeTextFile(new URL("manifest-with-facts.json", outDir), JSON.stringify(manifest, null, 2) + "\n");
await Deno.writeTextFile(new URL("document-posted-at.json", outDir), JSON.stringify(validated, null, 2) + "\n");
console.log("wrote fixtures; facts:", facts.length, "cursor:", factsCursor, "download:", download.length);
