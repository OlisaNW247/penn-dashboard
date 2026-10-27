// extract-announcement end to end with `fetch` stubbed (see
// `support/edgeStub.ts`), pinning the quota reservation around its model
// call (hardening BE-C). Its rule differs from `ask`'s in one way that
// matters: a request that fails while the student is still there gets its
// unit back, because the phone retries a failed announcement and a
// deterministic failure must not drain the student's asks. Everything else
// is the same: reserved before the model call, refused with a 429 without
// reaching the model, kept once the model has answered, kept when the
// student has left (refunding an abandoned request would make hanging up
// free), and unmetered when the counter fails open.
import { strict as assert } from "node:assert";
import { handleExtractAnnouncement } from "../supabase/functions/extract-announcement/index.ts";
import { DENIED, GRANTED, installStub, tick, type Stub } from "./support/edgeStub.ts";

function announcementRequest(signal?: AbortSignal): Request {
  return new Request("http://functions.test/extract-announcement", {
    method: "POST",
    headers: { Authorization: "Bearer test-jwt", "content-type": "application/json" },
    body: JSON.stringify({
      announcementID: "a1",
      courseCode: "PHYS 0151",
      title: "Problem set 4",
      message: "Problem set 4 is due Friday.",
      now: "2026-10-27T12:00:00Z",
    }),
    signal,
  });
}

const ANSWER = JSON.stringify({ assignments: [] });

function settleCalls(stub: Stub) {
  return stub.rpcParams.filter((call) => call.fn === "settle_ask_usage").map((call) => call.params);
}

Deno.test("extract-announcement: a refused reservation is a 429 that never reaches the model", async () => {
  const stub = installStub({ reserve: () => DENIED, openrouter: { kind: "json", content: ANSWER } });
  try {
    const res = await handleExtractAnnouncement(announcementRequest());
    assert.equal(res.status, 429);
    assert.equal((await res.json()).error, "quota_exceeded");
    await tick();
    assert.ok(!stub.log.includes("openrouter"));
    assert.deepEqual(settleCalls(stub), []);
  } finally {
    stub.restore();
  }
});

Deno.test("extract-announcement: the unit is reserved before the model call and kept after an answer", async () => {
  const stub = installStub({ reserve: () => GRANTED, openrouter: { kind: "json", content: ANSWER } });
  try {
    const res = await handleExtractAnnouncement(announcementRequest());
    assert.equal(res.status, 200);
    assert.deepEqual((await res.json()).assignments, []);
    await tick();
    assert.ok(
      stub.log.indexOf("rpc:reserve_ask_usage") < stub.log.indexOf("openrouter"),
      `reserve must come before the model call: ${stub.log.join(", ")}`,
    );
    assert.deepEqual(settleCalls(stub), [], "an answered request keeps its unit and has nothing to settle");
    // The old charge-after-the-answer path is gone.
    assert.ok(!stub.log.includes("rpc:record_ask_usage"));
    assert.ok(!stub.log.includes("rpc:ask_usage_counts"));
  } finally {
    stub.restore();
  }
});

Deno.test("extract-announcement: a failed model call gives the unit back while the student is still there", async () => {
  const stub = installStub({ reserve: () => GRANTED, openrouter: { kind: "fail", status: 500 } });
  try {
    const res = await handleExtractAnnouncement(announcementRequest());
    assert.equal(res.status, 502);
    await res.text();
    await tick();
    const settles = settleCalls(stub);
    assert.equal(settles.length, 1);
    assert.equal(settles[0].p_refund, true);
  } finally {
    stub.restore();
  }
});

Deno.test("extract-announcement: a missing model key gives the unit back too, since no model was called", async () => {
  const stub = installStub({ reserve: () => GRANTED, openrouter: { kind: "json", content: ANSWER } });
  const saved = Deno.env.get("OPENROUTER_API_KEY");
  Deno.env.delete("OPENROUTER_API_KEY");
  try {
    const res = await handleExtractAnnouncement(announcementRequest());
    assert.equal(res.status, 502);
    await res.text();
    await tick();
    assert.ok(!stub.log.includes("openrouter"));
    const settles = settleCalls(stub);
    assert.equal(settles.length, 1);
    assert.equal(settles[0].p_refund, true);
  } finally {
    if (saved !== undefined) Deno.env.set("OPENROUTER_API_KEY", saved);
    stub.restore();
  }
});

Deno.test("extract-announcement: a student who leaves stops the model call and keeps the unit", async () => {
  const stub = installStub({ reserve: () => GRANTED, openrouter: { kind: "stall-before-first-byte" } });
  const gone = new AbortController();
  try {
    const pending = handleExtractAnnouncement(announcementRequest(gone.signal));
    await tick(40);
    gone.abort();
    const outcome = await Promise.race([pending, tick(1000).then(() => "still waiting" as const)]);
    assert.notEqual(outcome, "still waiting", "leaving must cut the model call off at once");
    await (outcome as Response).text();
    await tick();
    assert.equal(stub.openrouterSignals[0].signal.aborted, true);
    const settles = settleCalls(stub);
    assert.equal(settles.length, 1);
    assert.equal(settles[0].p_refund, false, "refunding an abandoned request would make hanging up free");
  } finally {
    stub.restore();
  }
});

Deno.test("extract-announcement: when the counter fails open the request still runs, with nothing to settle", async () => {
  const stub = installStub({
    reserve: () => GRANTED,
    reserveStatus: 504,
    openrouter: { kind: "json", content: ANSWER },
  });
  try {
    const res = await handleExtractAnnouncement(announcementRequest());
    assert.equal(res.status, 200);
    await res.text();
    await tick();
    assert.deepEqual(settleCalls(stub), []);
  } finally {
    stub.restore();
  }
});

Deno.test("extract-announcement: parallel requests are limited by the reservation", async () => {
  let granted = 0;
  const stub = installStub({
    reserve: () => (granted++ < 2 ? GRANTED : DENIED),
    openrouter: { kind: "json", content: ANSWER },
  });
  try {
    const responses = await Promise.all([1, 2, 3, 4].map(() => handleExtractAnnouncement(announcementRequest())));
    await Promise.all(responses.map((r) => r.text()));
    assert.deepEqual(responses.map((r) => r.status).sort(), [200, 200, 429, 429]);
    assert.equal(stub.log.filter((entry) => entry === "openrouter").length, 2);
  } finally {
    stub.restore();
  }
});
