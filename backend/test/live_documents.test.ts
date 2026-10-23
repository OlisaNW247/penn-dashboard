// Tests for the live-document reads in supabase/functions/_shared/db.ts
// that `sync` is built on: pagination under PostgREST's max_rows, the age-out
// of window kinds, and the complete-set query's window-kind exclusion. A
// fake client records the query chain so the exact filters are pinned
// without a database.
import {
  LIVE_DOCUMENT_PAGE_SIZE,
  selectLiveDocumentIDsForCourse,
  selectLiveDocumentSnapshots,
  selectLiveDocumentsForCourses,
} from "../supabase/functions/_shared/db.ts";

function assertEquals<T>(actual: T, expected: T, message?: string): void {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(message ?? `expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}

interface Recorded {
  table: string;
  select: string;
  calls: Array<[string, ...unknown[]]>;
  ranges: Array<[number, number]>;
}

/** A thenable, chainable stand-in for the PostgREST builder. `rows` is the
 * whole result set; `.range(a, b)` slices it like the server would, capped
 * at `maxRows` the way the live project's max_rows silently caps. */
function fakeClient(rows: unknown[], maxRows = 1000) {
  const recorded: Recorded[] = [];
  const client = {
    from(table: string) {
      const rec: Recorded = { table, select: "", calls: [], ranges: [] };
      recorded.push(rec);
      let rangeArgs: [number, number] | undefined;
      const builder: Record<string, unknown> = {
        select(columns: string) {
          rec.select = columns;
          return builder;
        },
        range(from: number, to: number) {
          rec.ranges.push([from, to]);
          rangeArgs = [from, to];
          return builder;
        },
        then(resolve: (v: unknown) => void) {
          const slice = rangeArgs
            ? rows.slice(rangeArgs[0], Math.min(rangeArgs[1] + 1, rangeArgs[0] + maxRows))
            : rows;
          resolve({ data: slice, error: null });
        },
      };
      for (const name of ["in", "is", "or", "order", "eq", "neq", "not"]) {
        builder[name] = (...args: unknown[]) => {
          rec.calls.push([name, ...args]);
          return builder;
        };
      }
      return builder;
    },
  };
  return { client: client as never, recorded };
}

const NOW = new Date("2026-10-23T12:00:00.000Z");

Deno.test("selectLiveDocumentsForCourses pages 500, 500, 120 and returns all 1120 in one call", async () => {
  const rows = Array.from({ length: 1120 }, (_, i) => ({ id: `page:c:${String(i).padStart(5, "0")}` }));
  const { client, recorded } = fakeClient(rows);
  const result = await selectLiveDocumentsForCourses(client, ["c"], NOW);
  assertEquals(LIVE_DOCUMENT_PAGE_SIZE, 500);
  assertEquals(result.length, 1120);
  assertEquals(recorded.length, 3);
  assertEquals(recorded.map((r) => r.ranges[0]), [[0, 499], [500, 999], [1000, 1499]]);
  assertEquals(new Set((result as Array<{ id: string }>).map((r) => r.id)).size, 1120);
});

Deno.test("a page that is exactly full costs one more (empty) request, then stops", async () => {
  const rows = Array.from({ length: 500 }, (_, i) => ({ id: `page:c:${i}` }));
  const { client, recorded } = fakeClient(rows);
  const result = await selectLiveDocumentsForCourses(client, ["c"], NOW);
  assertEquals(result.length, 500);
  assertEquals(recorded.length, 2);
});

Deno.test("the live read filters live rows, ages out window kinds, and orders by id", async () => {
  const { client, recorded } = fakeClient([]);
  await selectLiveDocumentsForCourses(client, ["c1", "c2"], NOW);
  const rec = recorded[0];
  assertEquals(rec.table, "course_documents");
  assertEquals(rec.calls, [
    ["in", "course_id", ["c1", "c2"]],
    ["is", "gone_at", null],
    [
      "or",
      "kind.not.in.(announcement,ed),updated_at.gte.2026-06-25T12:00:00.000Z," +
      "and(updated_at.is.null,fetched_at.gte.2026-06-25T12:00:00.000Z)",
    ],
    ["order", "id", { ascending: true }],
  ]);
});

Deno.test("the upload snapshots select only id, kind, content_hash and collector, with the same age-out", async () => {
  const { client, recorded } = fakeClient([{ id: "a", kind: "page", content_hash: "h" }]);
  const result = await selectLiveDocumentSnapshots(client, ["c"], NOW);
  assertEquals(result.length, 1);
  assertEquals(recorded[0].select, "id, kind, content_hash, collector");
  assertEquals(recorded[0].calls.some((c) => c[0] === "or"), true);
});

Deno.test("an empty course list reads nothing", async () => {
  const { client, recorded } = fakeClient([]);
  assertEquals((await selectLiveDocumentsForCourses(client, [], NOW)).length, 0);
  assertEquals(recorded.length, 0);
});

Deno.test("the complete-set id read excludes every window kind and scopes by collector", async () => {
  const { client, recorded } = fakeClient([{ id: "page:c:1" }]);
  const ids = await selectLiveDocumentIDsForCourse(client, "c", "phone");
  assertEquals(ids, ["page:c:1"]);
  assertEquals(recorded[0].calls, [
    ["eq", "course_id", "c"],
    ["not", "kind", "in", "(announcement,ed)"],
    ["is", "gone_at", null],
    ["eq", "collector", "phone"],
  ]);
});
