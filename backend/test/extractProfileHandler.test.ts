// extract-profile's time budget (hardening BE-12, the deadline half). One call
// may rebuild up to twenty profiles, one model call after another, and nothing
// bounded the total. Past the budget no further course is started and a model
// call in flight is aborted; a course not reached keeps `profile_stale` set,
// so the next sync's call picks it up, as it already does after an upstream
// failure. `fetch` is stubbed (see `support/edgeStub.ts`) and the budget is set
// through the same env var production reads.
import { strict as assert } from "node:assert";
import { handleExtractProfile } from "../supabase/functions/extract-profile/index.ts";
import { GRANTED, installStub, tick, type OpenRouterBehaviour } from "./support/edgeStub.ts";

const COURSES = ["101", "102", "103"];
const PROFILE_JSON = JSON.stringify({ latePolicy: "no late work" });

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

interface Recorded {
  /** course ids whose profile_stale flag was cleared (PATCH courses). */
  cleared: string[];
  /** course ids whose profile was upserted (POST course_profiles). */
  upserted: string[];
}

function install(openrouter: OpenRouterBehaviour, budgetMs: string) {
  const recorded: Recorded = { cleared: [], upserted: [] };
  const savedBudget = Deno.env.get("EXTRACT_PROFILE_BUDGET_MS");
  Deno.env.set("EXTRACT_PROFILE_BUDGET_MS", budgetMs);
  const stub = installStub({
    reserve: () => GRANTED,
    openrouter,
    route: ({ method, url, body }) => {
      const table = url.pathname.replace("/rest/v1/", "");
      if (!url.pathname.startsWith("/rest/v1/")) return undefined;
      if (table === "enrollments" && method === "GET") return json(200, COURSES.map((course_id) => ({ course_id })));
      if (table === "courses" && method === "GET") {
        return json(200, COURSES.map((course_id) => ({ course_id, profile_stale: true })));
      }
      if (table === "course_documents" && method === "GET") {
        const course = /^eq\.(.+)$/.exec(url.searchParams.get("course_id") ?? "")?.[1] ?? "?";
        return json(200, [{
          id: `syllabus:${course}:1`,
          kind: "syllabus",
          title: "Syllabus",
          text: "Grading: homework 40%, exams 60%. No late work.",
          content_hash: "h",
          url: null,
        }]);
      }
      if (table === "course_profiles" && method === "POST") {
        recorded.upserted.push(String((JSON.parse(body) as { course_id: string }).course_id));
        return new Response(null, { status: 201 });
      }
      if (table === "courses" && method === "PATCH") {
        recorded.cleared.push(/^eq\.(.+)$/.exec(url.searchParams.get("course_id") ?? "")?.[1] ?? "?");
        return new Response(null, { status: 204 });
      }
      return undefined;
    },
  });
  return {
    recorded,
    stub,
    restore() {
      stub.restore();
      if (savedBudget === undefined) Deno.env.delete("EXTRACT_PROFILE_BUDGET_MS");
      else Deno.env.set("EXTRACT_PROFILE_BUDGET_MS", savedBudget);
    },
  };
}

function profileRequest(): Request {
  return new Request("http://functions.test/extract-profile", {
    method: "POST",
    headers: { Authorization: "Bearer test-jwt", "content-type": "application/json" },
    body: JSON.stringify({ courseIDs: COURSES }),
  });
}

Deno.test("extract-profile: inside the budget every stale course is rebuilt", async () => {
  const { recorded, restore } = install({ kind: "json", content: PROFILE_JSON, delayMs: 5 }, "10000");
  try {
    const res = await handleExtractProfile(profileRequest());
    assert.equal(res.status, 200);
    assert.deepEqual((await res.json()).updated.sort(), COURSES);
    assert.deepEqual(recorded.cleared.sort(), COURSES);
  } finally {
    restore();
  }
});

Deno.test("extract-profile: once the budget is spent no further course is started, and the rest stay stale", async () => {
  // Each model call takes 120 ms against a 200 ms budget: the first finishes
  // at 120 ms, the second starts at 120 ms and is cut off at 200 ms, the third
  // is never started.
  const { recorded, stub, restore } = install({ kind: "json", content: PROFILE_JSON, delayMs: 120 }, "200");
  try {
    const started = Date.now();
    const res = await handleExtractProfile(profileRequest());
    assert.equal(res.status, 200);
    const updated: string[] = (await res.json()).updated;
    assert.deepEqual(updated, ["101"], "only the course that finished inside the budget is reported updated");
    assert.deepEqual(recorded.cleared, ["101"], "a course not reached must keep profile_stale set");
    assert.deepEqual(recorded.upserted, ["101"]);
    assert.ok(Date.now() - started < 1500, "the call must end at the budget, not run all three out");
    // Course 101's call and course 102's primary were live. The attempt on
    // the fallback model after 102's primary was cut off carries the same
    // aborted signal, so a real fetch rejects it without sending anything. A
    // third live call would mean course 103 was started past the budget.
    assert.equal(
      stub.openrouterSignals.filter((call) => !call.abortedAtCall).length,
      2,
      "the third course must never reach the model",
    );
  } finally {
    restore();
  }
});

Deno.test("extract-profile: a model call that never answers is aborted at the budget and the course stays stale", async () => {
  const { recorded, stub, restore } = install({ kind: "stall-before-first-byte" }, "100");
  try {
    const started = Date.now();
    const res = await handleExtractProfile(profileRequest());
    assert.equal(res.status, 200);
    assert.deepEqual((await res.json()).updated, []);
    assert.deepEqual(recorded.cleared, []);
    assert.ok(Date.now() - started < 1500, "a stalled call must not hold the function open");
    await tick(20);
    assert.ok(stub.openrouterSignals.length >= 1);
    for (const call of stub.openrouterSignals) assert.equal(call.signal.aborted, true, "the stalled request must be cancelled");
  } finally {
    restore();
  }
});
