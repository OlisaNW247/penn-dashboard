import { isMissingTable } from "../supabase/functions/_shared/auth.ts";

function assertEquals<T>(actual: T, expected: T): void {
  if (actual !== expected) throw new Error(`expected ${expected}, got ${actual}`);
}

// requireUser treats a missing device_links table as "not linked" so that a
// function deployed before the migration keeps serving every phone, and
// fails closed on any other lookup error.
Deno.test("isMissingTable: only the two missing-relation codes", () => {
  assertEquals(isMissingTable({ code: "42P01" }), true);
  assertEquals(isMissingTable({ code: "PGRST205" }), true);
  assertEquals(isMissingTable({ code: "PGRST301" }), false);
  assertEquals(isMissingTable({ code: "57014" }), false);
  assertEquals(isMissingTable({ code: null }), false);
  assertEquals(isMissingTable({}), false);
});
