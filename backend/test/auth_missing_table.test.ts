import { assertEquals } from "jsr:@std/assert@1";
import { isMissingTable } from "../supabase/functions/_shared/auth.ts";

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
