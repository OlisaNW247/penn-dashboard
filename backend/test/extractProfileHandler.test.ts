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
  /** course ids stamped as cut off by the time budget (profile_budget_aborted_at set). */
  markedAborted: string[];
  /** course ids whose budget-abort stamp was cleared after a successful build. */
  markerCleared: string[];
}

interface InstallOptions {
  /** profile_budget_aborted_at per course, as the database holds it. */
  stamps?: Record<string, string>;
  /** Simulate the cool-down column not existing yet (migration not applied). */
  stampColumnMissing?: boolean;
}

const HOURS = 3_600_000;
const ago = (ms: number) => new Date(Date.now() - ms).toISOString();

function install(openrouter: OpenRouterBehaviour, budgetMs: string, options: InstallOptions = {}) {
  const recorded: Recorded = { cleared: [], upserted: [], markedAborted: [], markerCleared: [] };
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
        if ((url.searchParams.get("select") ?? "").includes("profile_budget_aborted_at")) {
          if (options.stampColumnMissing) {
            return json(400, { code: "42703", message: "column courses.profile_budget_aborted_at does not exist" });
          }
          return json(
            200,
            COURSES.map((course_id) => ({ course_id, profile_budget_aborted_at: options.stamps?.[course_id] ?? null })),
          );
        }
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
        const course = /^eq\.(.+)$/.exec(url.searchParams.get("course_id") ?? "")?.[1] ?? "?";
        const patch = JSON.parse(body) as Record<string, unknown>;
        if ("profile_budget_aborted_at" in patch) {
          (patch.profile_budget_aborted_at === null ? recorded.markerCleared : recorded.markedAborted).push(course);
        } else {
          recorded.cleared.push(course);
        }
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
  const { recorded, stub, restore } = install({ kind: "json", content: PROFILE_JSON, delayMs: 5 }, "10000");
  try {
    const res = await handleExtractProfile(profileRequest());
    assert.equal(res.status, 200);
    assert.deepEqual((await res.json()).updated.sort(), COURSES);
    assert.deepEqual(recorded.cleared.sort(), COURSES);
    assert.deepEqual(recorded.markedAborted, [], "nothing was cut off");
    assert.deepEqual(settleCalls(stub), [], "an ordinary call keeps its unit, as before");
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
    assert.deepEqual(recorded.markedAborted, ["102"], "only the course whose call was cut off is stamped, not the one never reached");
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
    assert.deepEqual(recorded.markedAborted, ["101"]);
    assert.ok(Date.now() - started < 1500, "a stalled call must not hold the function open");
    await tick(20);
    assert.ok(stub.openrouterSignals.length >= 1);
    for (const call of stub.openrouterSignals) assert.equal(call.signal.aborted, true, "the stalled request must be cancelled");
  } finally {
    restore();
  }
});

// ---------------------------------------------------------------------
// The cool-down (BE-12 follow-up). A course whose build always overruns the
// budget used to cost a unit of quota and 40 seconds on every sync, for
// nothing: it was aborted, left stale, and tried again. A course that was cut
// off is now left alone for a day, and a call with nothing else to do gives
// its unit back.
// ---------------------------------------------------------------------

function settleCalls(stub: { rpcParams: Array<{ fn: string; params: Record<string, unknown> }> }) {
  return stub.rpcParams.filter((call) => call.fn === "settle_ask_usage").map((call) => call.params);
}

Deno.test("extract-profile: when every stale course is cooling down there is no model call, nothing changes, and the unit is given back", async () => {
  const stamps = { "101": ago(2 * HOURS), "102": ago(10 * HOURS), "103": ago(23 * HOURS) };
  const { recorded, stub, restore } = install({ kind: "json", content: PROFILE_JSON }, "10000", { stamps });
  try {
    const res = await handleExtractProfile(profileRequest());
    assert.equal(res.status, 200);
    assert.deepEqual((await res.json()).updated, []);
    await tick(30);
    assert.equal(stub.openrouterSignals.length, 0, "a cooling-down course must not reach the model");
    assert.deepEqual(recorded, { cleared: [], upserted: [], markedAborted: [], markerCleared: [] });
    const settles = settleCalls(stub);
    assert.equal(settles.length, 1, "exactly one unit settled");
    assert.equal(settles[0].p_refund, true, "no model call was made, so the reserved unit goes back");
  } finally {
    restore();
  }
});

Deno.test("extract-profile: a course whose cool-down has ended is tried again, and a successful build clears its stamp", async () => {
  const stamps = { "101": ago(25 * HOURS) };
  const { recorded, stub, restore } = install({ kind: "json", content: PROFILE_JSON, delayMs: 5 }, "10000", { stamps });
  try {
    const res = await handleExtractProfile(profileRequest());
    assert.deepEqual((await res.json()).updated.sort(), COURSES);
    assert.deepEqual(recorded.markerCleared, ["101"], "only the course that had a stamp needs it cleared");
    assert.deepEqual(recorded.markedAborted, []);
    assert.deepEqual(settleCalls(stub), []);
  } finally {
    restore();
  }
});

Deno.test("extract-profile: with some courses cooling down the others are rebuilt and the call is charged as usual", async () => {
  const stamps = { "101": ago(HOURS) };
  const { recorded, stub, restore } = install({ kind: "json", content: PROFILE_JSON, delayMs: 5 }, "10000", { stamps });
  try {
    const res = await handleExtractProfile(profileRequest());
    assert.deepEqual((await res.json()).updated.sort(), ["102", "103"]);
    assert.deepEqual(recorded.cleared.sort(), ["102", "103"], "the cooling-down course stays stale");
    assert.equal(stub.openrouterSignals.length, 2);
    assert.deepEqual(settleCalls(stub), [], "work was done, so the unit is kept");
  } finally {
    restore();
  }
});

Deno.test("extract-profile: a course that overruns every time is not retried for a day, and is not charged again", async () => {
  // Call 1: the model never answers; the budget cuts it off and the course is stamped.
  const first = install({ kind: "stall-before-first-byte" }, "100");
  let stamp: string | undefined;
  try {
    const res = await handleExtractProfile(profileRequest());
    assert.equal(res.status, 200);
    assert.deepEqual(first.recorded.markedAborted, ["101"]);
    stamp = new Date().toISOString(); // what the database now holds for course 101
    assert.deepEqual(settleCalls(first.stub), [], "the first, real attempt is charged");
  } finally {
    first.restore();
  }

  // Calls 2 and 3: the same stale courses, 101 now stamped (and 102, 103 stamped by their own earlier overruns).
  const stamps = { "101": stamp!, "102": stamp!, "103": stamp! };
  for (let call = 2; call <= 3; call++) {
    const again = install({ kind: "stall-before-first-byte" }, "100", { stamps });
    try {
      const started = Date.now();
      const res = await handleExtractProfile(profileRequest());
      assert.equal(res.status, 200);
      assert.ok(Date.now() - started < 80, `call ${call} must not spend the budget again`);
      await tick(30);
      assert.equal(again.stub.openrouterSignals.length, 0, `call ${call} must not reach the model`);
      const settles = settleCalls(again.stub);
      assert.equal(settles.length, 1);
      assert.equal(settles[0].p_refund, true, `call ${call} must not be charged`);
    } finally {
      again.restore();
    }
  }
});

Deno.test("extract-profile: if the cool-down column is not there yet, nothing is cooling down and profiles are still built", async () => {
  const { recorded, restore } = install({ kind: "json", content: PROFILE_JSON, delayMs: 5 }, "10000", {
    stampColumnMissing: true,
  });
  try {
    const res = await handleExtractProfile(profileRequest());
    assert.equal(res.status, 200);
    assert.deepEqual((await res.json()).updated.sort(), COURSES);
    assert.deepEqual(recorded.cleared.sort(), COURSES);
  } finally {
    restore();
  }
});
