// delete-account end to end with `fetch` stubbed (see `support/edgeStub.ts`),
// pinning that it is idempotent (hardening BE-14): a second call, or a retry
// after a failure part way, completes the deletion and answers 200 instead
// of dying on something the first call already did. A small in-memory world
// stands in for GoTrue's admin API and the tables, including the cascade
// that removes a device's link row when its auth user is deleted.
import { strict as assert } from "node:assert";
import { handleDeleteAccount } from "../supabase/functions/delete-account/index.ts";
import { GRANTED, installStub, USER_ID } from "./support/edgeStub.ts";

const DEVICE_A = "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa";
const DEVICE_B = "bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb";

interface World {
  /** Device user ids linked to the owner (their link rows still exist). */
  linkedDevices: string[];
  /** Auth users that no longer exist. */
  goneUsers: Set<string>;
  /** Auth users whose next admin delete fails with a 500, once. */
  failOnce: Set<string>;
  /** Everything that happened, in order: "delete-user:<id>", "delete-rows:<table>". */
  events: string[];
  /** How GoTrue answers the token lookup: by whether the user still exists
   *  ("by-existence"), always as valid ("verifies"), or as a bad token ("bad-jwt"). */
  tokenLookup: "by-existence" | "verifies" | "bad-jwt";
}

function world(overrides: Partial<World> = {}): World {
  return {
    linkedDevices: [DEVICE_A, DEVICE_B],
    goneUsers: new Set(),
    failOnce: new Set(),
    events: [],
    tokenLookup: "by-existence",
    ...overrides,
  };
}

const json = (status: number, body: unknown) =>
  new Response(JSON.stringify(body), { status, headers: { "content-type": "application/json" } });

function install(w: World, options: { callerIsDeviceOf?: string } = {}) {
  return installStub({
    reserve: () => GRANTED,
    openrouter: { kind: "fail", status: 500 },
    route: ({ method, url }) => {
      if (url.pathname === "/auth/v1/user") {
        if (w.tokenLookup === "bad-jwt") {
          return json(401, { code: 401, error_code: "bad_jwt", msg: "invalid JWT: unable to parse or verify signature" });
        }
        if (w.tokenLookup === "by-existence" && w.goneUsers.has(USER_ID)) {
          return json(403, { code: 403, error_code: "user_not_found", msg: "User from sub claim in JWT does not exist" });
        }
        return undefined; // the stub's default: a valid user
      }

      const admin = /^\/auth\/v1\/admin\/users\/(.+)$/.exec(url.pathname);
      if (admin && method === "DELETE") {
        const id = admin[1];
        if (w.goneUsers.has(id)) {
          return json(404, { code: 404, error_code: "user_not_found", msg: "User not found" });
        }
        if (w.failOnce.has(id)) {
          w.failOnce.delete(id);
          return json(500, { code: 500, error_code: "unexpected_failure", msg: "database error" });
        }
        w.goneUsers.add(id);
        w.linkedDevices = w.linkedDevices.filter((device) => device !== id); // the cascade
        w.events.push(`delete-user:${id}`);
        return json(200, {});
      }

      const rest = /^\/rest\/v1\/([^?]+)$/.exec(url.pathname);
      if (rest) {
        const table = rest[1];
        if (table.startsWith("device_links") && method === "GET") {
          if (url.searchParams.has("device_user_id")) {
            // requireUser's lookup of the caller: a plain user has no row, a linked device has one.
            return json(200, options.callerIsDeviceOf ? [{ owner_user_id: options.callerIsDeviceOf }] : []);
          }
          // selectLinkedDeviceIDs: the owner's links as they currently stand.
          return json(200, w.linkedDevices.map((device_user_id) => ({ device_user_id })));
        }
        if (method === "DELETE") {
          w.events.push(`delete-rows:${table}`);
          if (table === "device_links") w.linkedDevices = [];
          return new Response(null, { status: 204 });
        }
      }
      return undefined;
    },
  });
}

function deleteRequest(): Request {
  return new Request("http://functions.test/delete-account", {
    method: "POST",
    headers: { Authorization: "Bearer test-jwt", "content-type": "application/json" },
    body: "{}",
  });
}

Deno.test("delete-account: an owner's devices go first, then their rows, then the owner", async () => {
  const w = world();
  const stub = install(w);
  try {
    const res = await handleDeleteAccount(deleteRequest());
    assert.equal(res.status, 200);
    assert.deepEqual(await res.json(), { deleted: true });

    const order = w.events;
    const lastDevice = Math.max(order.indexOf(`delete-user:${DEVICE_A}`), order.indexOf(`delete-user:${DEVICE_B}`));
    assert.ok(lastDevice >= 0 && order.includes(`delete-user:${DEVICE_A}`) && order.includes(`delete-user:${DEVICE_B}`));
    assert.ok(lastDevice < order.indexOf("delete-rows:enrollments"), `devices before rows: ${order.join(", ")}`);
    assert.ok(order.indexOf("delete-rows:enrollments") < order.indexOf(`delete-user:${USER_ID}`), "rows before the owner");
    assert.equal(order[order.length - 1], `delete-user:${USER_ID}`);
  } finally {
    stub.restore();
  }
});

Deno.test("delete-account: a failure on a device is a 502 that leaves the remaining devices findable, and the retry finishes the job", async () => {
  const w = world({ failOnce: new Set([DEVICE_B]) });
  const stub = install(w);
  try {
    const first = await handleDeleteAccount(deleteRequest());
    assert.equal(first.status, 502);
    await first.text();
    // The first device is gone; the second still has its link row, so the retry can find it.
    assert.ok(w.goneUsers.has(DEVICE_A));
    assert.deepEqual(w.linkedDevices, [DEVICE_B]);
    assert.ok(!w.goneUsers.has(USER_ID), "the owner must survive a failed attempt");

    const second = await handleDeleteAccount(deleteRequest());
    assert.equal(second.status, 200);
    assert.deepEqual(await second.json(), { deleted: true });
    assert.ok(w.goneUsers.has(DEVICE_B), "the retry deleted the device the first attempt never reached");
    assert.ok(w.goneUsers.has(USER_ID));
  } finally {
    stub.restore();
  }
});

Deno.test("delete-account: an auth user that is already gone is skipped, not an error", async () => {
  const w = world({ goneUsers: new Set([DEVICE_A]) }); // gone, but its link row survived
  const stub = install(w);
  try {
    const res = await handleDeleteAccount(deleteRequest());
    assert.equal(res.status, 200);
    assert.ok(w.goneUsers.has(DEVICE_B) && w.goneUsers.has(USER_ID));
  } finally {
    stub.restore();
  }
});

Deno.test("delete-account: a second call for an account that is already gone answers 200 and deletes nothing", async () => {
  const w = world();
  const stub = install(w);
  try {
    assert.equal((await handleDeleteAccount(deleteRequest())).status, 200);
    const eventsAfterFirst = w.events.length;

    // The same token again: GoTrue now says the user does not exist.
    const second = await handleDeleteAccount(deleteRequest());
    assert.equal(second.status, 200);
    assert.deepEqual(await second.json(), { deleted: true });
    assert.equal(w.events.length, eventsAfterFirst, "the retry must not do any deletion work");
  } finally {
    stub.restore();
  }
});

Deno.test("delete-account: a bad or expired token is still a 401, never a 200", async () => {
  const w = world({ tokenLookup: "bad-jwt" });
  const stub = install(w);
  try {
    const res = await handleDeleteAccount(deleteRequest());
    assert.equal(res.status, 401);
    assert.equal((await res.json()).error, "unauthorized");
    assert.deepEqual(w.events, []);
  } finally {
    stub.restore();
  }
});

Deno.test("delete-account: a linked device only unpairs itself, and doing it twice is fine", async () => {
  const OWNER = "99999999-9999-9999-9999-999999999999";
  const w = world({ linkedDevices: [USER_ID] });
  const stub = install(w, { callerIsDeviceOf: OWNER });
  try {
    const first = await handleDeleteAccount(deleteRequest());
    assert.equal(first.status, 200);
    assert.ok(w.goneUsers.has(USER_ID));
    assert.ok(!w.goneUsers.has(OWNER), "a device never deletes its owner");
    await first.text();

    // The device's own token again: its user is gone.
    const second = await handleDeleteAccount(deleteRequest());
    assert.equal(second.status, 200);
    assert.deepEqual(await second.json(), { deleted: true });
  } finally {
    stub.restore();
  }
});

Deno.test("delete-account: unpairing a device whose auth user is already gone is a 200", async () => {
  const OWNER = "99999999-9999-9999-9999-999999999999";
  // The auth user vanished but the token still verifies, so only the admin delete finds it gone.
  const w = world({ linkedDevices: [USER_ID], goneUsers: new Set([USER_ID]), tokenLookup: "verifies" });
  const stub = install(w, { callerIsDeviceOf: OWNER });
  try {
    const res = await handleDeleteAccount(deleteRequest());
    assert.equal(res.status, 200);
    assert.deepEqual(await res.json(), { deleted: true });
  } finally {
    stub.restore();
  }
});
