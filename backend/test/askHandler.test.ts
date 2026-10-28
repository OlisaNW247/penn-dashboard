// handleAsk end to end, with `fetch` stubbed: Supabase's auth and PostgREST
// on one side, OpenRouter on the other. This is the only place the order of
// events in `ask` is pinned (hardening BE-C): the quota unit is reserved
// BEFORE the model is called, a refused request never reaches the model,
// the unit is given back only when the student got nothing and was still
// there, the tokens are settled however the stream ends, and a student who
// leaves stops the upstream call. The pure pieces (`reserveUsage`, the
// lease, the SQL) have their own tests; none of them can show that the
// handler wires them in this order.
//
// The stub implements the atomic semantic the database provides (a counter
// that grants at most `limit` reservations, however many arrive at once),
// so these tests show the handler trusts the reservation and does no
// unprotected read of its own; the atomicity itself is the SQL's
// (test/rls.test.sql).
import { strict as assert } from "node:assert";
import { handleAsk } from "../supabase/functions/ask/index.ts";
import { DENIED, GRANTED, installStub, tick, type Stub, USER_ID } from "./support/edgeStub.ts";

function askRequest(signal?: AbortSignal, extra: Record<string, unknown> = {}): Request {
  return new Request("http://functions.test/ask", {
    method: "POST",
    headers: { Authorization: "Bearer test-jwt", "content-type": "application/json" },
    body: JSON.stringify({
      question: "when is the midterm?",
      contextDocument: "CONTEXT",
      excerpts: "",
      askedAt: "2026-10-27T12:00:00Z",
      courseIDs: [],
      history: [],
      ...extra,
    }),
    signal,
  });
}

function settleCalls(stub: Stub) {
  return stub.rpcParams.filter((call) => call.fn === "settle_ask_usage").map((call) => call.params);
}

Deno.test("ask: a refused reservation is a 429 that never reaches the model or settles anything", async () => {
  const stub = installStub({ reserve: () => DENIED, openrouter: { kind: "answer" } });
  try {
    const res = await handleAsk(askRequest(), { allowProbeOverrides: false });
    assert.equal(res.status, 429);
    const body = await res.json();
    assert.equal(body.error, "quota_exceeded");
    assert.ok(typeof body.resetAt === "string");
    await tick();
    assert.ok(!stub.log.includes("openrouter"), "a refused request must not call the model");
    assert.deepEqual(settleCalls(stub), []);
  } finally {
    stub.restore();
  }
});

Deno.test("ask: the unit is reserved before the model is called, and the tokens are settled after a clean stream", async () => {
  const stub = installStub({
    reserve: () => GRANTED,
    openrouter: { kind: "answer", text: "tuesday", promptTokens: 321, completionTokens: 12 },
  });
  try {
    const res = await handleAsk(askRequest(), { allowProbeOverrides: false });
    assert.equal(res.status, 200);
    const text = await res.text();
    assert.ok(text.includes("tuesday"));
    assert.ok(text.includes('"type":"done"'));
    await tick();

    assert.ok(stub.log.indexOf("rpc:reserve_ask_usage") !== -1);
    assert.ok(
      stub.log.indexOf("rpc:reserve_ask_usage") < stub.log.indexOf("openrouter"),
      `reserve must come before the model call: ${stub.log.join(", ")}`,
    );
    assert.deepEqual(settleCalls(stub), [{
      p_user_id: USER_ID,
      p_day: "2026-10-27",
      p_prompt_tokens: 321,
      p_completion_tokens: 12,
      p_refund: false,
    }]);
    // The old record-after-the-stream path is gone: nothing is charged a second time.
    assert.ok(!stub.log.includes("rpc:record_ask_usage"));
    assert.ok(!stub.log.includes("rpc:ask_usage_counts"));
  } finally {
    stub.restore();
  }
});

Deno.test("ask: when both models fail and the student is still there, the unit is given back", async () => {
  const stub = installStub({ reserve: () => GRANTED, openrouter: { kind: "fail", status: 500 } });
  try {
    const res = await handleAsk(askRequest(), { allowProbeOverrides: false });
    assert.equal(res.status, 502);
    await res.text();
    await tick();
    const settles = settleCalls(stub);
    assert.equal(settles.length, 1);
    assert.equal(settles[0].p_refund, true);
    assert.equal(settles[0].p_prompt_tokens, 0);
  } finally {
    stub.restore();
  }
});

Deno.test("ask: a student who leaves mid-stream stops the model call and keeps the unit, with the tokens seen", async () => {
  const stub = installStub({ reserve: () => GRANTED, openrouter: { kind: "stall-after-first-delta" } });
  const gone = new AbortController();
  try {
    const res = await handleAsk(askRequest(gone.signal), { allowProbeOverrides: false });
    assert.equal(res.status, 200);
    const reader = res.body!.getReader();
    const first = await reader.read();
    assert.ok(new TextDecoder().decode(first.value).includes("partial"));

    gone.abort(); // the connection closes
    await tick(60);

    assert.equal(stub.openrouterSignals.length, 1);
    assert.equal(stub.openrouterSignals[0].signal.aborted, true, "the upstream request must be aborted");
    const settles = settleCalls(stub);
    assert.equal(settles.length, 1, `expected exactly one settle, got ${JSON.stringify(settles)}`);
    assert.equal(settles[0].p_refund, false, "an abandoned request stays counted");
    await reader.cancel().catch(() => {});
  } finally {
    stub.restore();
  }
});

Deno.test("ask: cancelling the response body (the other way the runtime reports a gone client) also aborts the model call", async () => {
  const stub = installStub({ reserve: () => GRANTED, openrouter: { kind: "stall-after-first-delta" } });
  try {
    const res = await handleAsk(askRequest(), { allowProbeOverrides: false });
    const reader = res.body!.getReader();
    await reader.read();
    await reader.cancel();
    await tick(60);

    assert.equal(stub.openrouterSignals[0].signal.aborted, true);
    const settles = settleCalls(stub);
    assert.equal(settles.length, 1);
    assert.equal(settles[0].p_refund, false);
  } finally {
    stub.restore();
  }
});

Deno.test("ask: a student who leaves before the first word is NOT refunded (hang up and keep the unit)", async () => {
  const stub = installStub({ reserve: () => GRANTED, openrouter: { kind: "stall-before-first-byte" } });
  const gone = new AbortController();
  try {
    const pending = handleAsk(askRequest(gone.signal), { allowProbeOverrides: false });
    await tick(40);
    gone.abort();
    // Within a second, not "eventually": the race's own 45 s budget would
    // abort the call too, which is the very wait a gone client must not cost.
    const outcome = await Promise.race([pending, tick(1000).then(() => "still waiting" as const)]);
    assert.notEqual(outcome, "still waiting", "leaving must stop the model call at once");
    const res = outcome as Response;
    await res.text();
    await tick();

    assert.equal(stub.openrouterSignals[0].signal.aborted, true, "the stalled model call must be cut off");
    const settles = settleCalls(stub);
    assert.equal(settles.length, 1);
    assert.equal(settles[0].p_refund, false, "refunding an abandoned request would make hanging up free");
  } finally {
    stub.restore();
  }
});

Deno.test("ask: when the counter fails open the request still runs, with nothing to settle", async () => {
  const stub = installStub({ reserve: () => GRANTED, reserveStatus: 504, openrouter: { kind: "answer" } });
  try {
    const res = await handleAsk(askRequest(), { allowProbeOverrides: false });
    assert.equal(res.status, 200);
    assert.ok((await res.text()).includes('"type":"done"'));
    await tick();
    assert.deepEqual(settleCalls(stub), []);
  } finally {
    stub.restore();
  }
});

Deno.test("ask: parallel requests are limited by the reservation, not by a read-then-charge in the handler", async () => {
  let granted = 0;
  const stub = installStub({
    // The database's behaviour: at most 2 reservations, however many arrive together.
    reserve: () => (granted++ < 2 ? GRANTED : DENIED),
    openrouter: { kind: "answer" },
  });
  try {
    const responses = await Promise.all([1, 2, 3, 4, 5].map(() => handleAsk(askRequest(), { allowProbeOverrides: false })));
    const statuses = responses.map((r) => r.status).sort();
    await Promise.all(responses.map((r) => r.text()));
    await tick();
    assert.deepEqual(statuses, [200, 200, 429, 429, 429]);
    assert.equal(stub.log.filter((entry) => entry === "openrouter").length, 2);
  } finally {
    stub.restore();
  }
});

Deno.test("ask: a hedge that would fire after the student left sends nothing live", async () => {
  const stub = installStub({ reserve: () => GRANTED, openrouter: { kind: "stall-before-first-byte" } });
  const gone = new AbortController();
  try {
    // The canary entry point, only to shorten the hedge from 5 s to 30 ms.
    const pending = handleAsk(askRequest(gone.signal, { probe: { hedgeAfterMs: 30 } }), { allowProbeOverrides: true });
    await tick(10);
    gone.abort();
    const outcome = await Promise.race([pending, tick(1000).then(() => "still waiting" as const)]);
    assert.notEqual(outcome, "still waiting", "leaving must stop the race at once, hedge included");
    await (outcome as Response).text();
    await tick(80);

    assert.ok(stub.openrouterSignals.length >= 1);
    // Anything sent after the student left carried an already-aborted signal.
    for (const call of stub.openrouterSignals.slice(1)) {
      assert.equal(call.abortedAtCall, true, "a request started after the student left must be dead on arrival");
    }
    for (const call of stub.openrouterSignals) {
      assert.equal(call.signal.aborted, true);
    }
  } finally {
    stub.restore();
  }
});
