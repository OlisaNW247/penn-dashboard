// requireUser's device_links lookup (hardening BE-11). Every function runs it
// to resolve a linked device to its owner, so a stall in it used to hang every
// function at once. It now has its own deadline, and a lookup that does not
// answer fails the request exactly as a lookup error does: never "not linked",
// which would treat a linked device as a fresh student with a full quota.
import { strict as assert } from "node:assert";
import { HttpError } from "../supabase/functions/_shared/http.ts";
import { requireUser } from "../supabase/functions/_shared/auth.ts";
import { GRANTED, installStub, USER_ID } from "./support/edgeStub.ts";

function request(): Request {
  return new Request("http://functions.test/anything", { method: "POST", headers: { Authorization: "Bearer test-jwt" } });
}

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

/** A stub whose device_links lookup answers `answer(signal)`; everything else is the default. */
function stubLinkLookup(answer: (signal: AbortSignal | undefined) => Promise<Response>) {
  return installStub({
    reserve: () => GRANTED,
    openrouter: { kind: "fail", status: 500 },
    route: ({ url, method, signal }) =>
      url.pathname.startsWith("/rest/v1/device_links") && method === "GET" ? answer(signal) : undefined,
  });
}

Deno.test("requireUser: a device_links lookup that never answers fails the request with a 502 at the deadline, and is aborted", async () => {
  let aborted = false;
  const stub = stubLinkLookup((signal) =>
    new Promise<Response>((_resolve, reject) => {
      signal?.addEventListener("abort", () => {
        aborted = true;
        reject(new DOMException("aborted", "AbortError"));
      });
    })
  );
  try {
    const started = Date.now();
    await assert.rejects(
      () => requireUser(request(), { linkLookupDeadlineMs: 50 }),
      (err: unknown) => err instanceof HttpError && err.status === 502 && err.code === "upstream",
    );
    assert.ok(Date.now() - started < 2000, "it must not wait for the lookup");
    assert.equal(aborted, true, "the stalled request must be cancelled, not left open");
  } finally {
    stub.restore();
  }
});

Deno.test("requireUser: a lookup that answers in time resolves a plain user to themselves", async () => {
  const stub = stubLinkLookup(() => Promise.resolve(json(200, [])));
  try {
    const identity = await requireUser(request(), { linkLookupDeadlineMs: 500 });
    assert.equal(identity.userId, USER_ID);
    assert.equal(identity.callerUserId, USER_ID);
    assert.equal(identity.deviceOwnerLinked, false);
  } finally {
    stub.restore();
  }
});

Deno.test("requireUser: a lookup that answers in time resolves a linked device to its owner", async () => {
  const OWNER = "99999999-9999-9999-9999-999999999999";
  const stub = stubLinkLookup(() => Promise.resolve(json(200, [{ owner_user_id: OWNER }])));
  try {
    const identity = await requireUser(request(), { linkLookupDeadlineMs: 500 });
    assert.equal(identity.userId, OWNER);
    assert.equal(identity.callerUserId, USER_ID);
    assert.equal(identity.deviceOwnerLinked, true);
  } finally {
    stub.restore();
  }
});

Deno.test("requireUser: a lookup error is still a 502, and a missing table is still 'not linked'", async () => {
  const failing = stubLinkLookup(() => Promise.resolve(json(500, { code: "XX000", message: "boom" })));
  try {
    await assert.rejects(
      () => requireUser(request(), { linkLookupDeadlineMs: 500 }),
      (err: unknown) => err instanceof HttpError && err.status === 502,
    );
  } finally {
    failing.restore();
  }

  const missing = stubLinkLookup(() => Promise.resolve(json(404, { code: "PGRST205", message: "no such table" })));
  try {
    const identity = await requireUser(request(), { linkLookupDeadlineMs: 500 });
    assert.equal(identity.userId, USER_ID);
    assert.equal(identity.deviceOwnerLinked, false);
  } finally {
    missing.restore();
  }
});
