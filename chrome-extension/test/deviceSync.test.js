import { test } from "node:test";
import assert from "node:assert/strict";
import { deviceSyncPass, THROTTLE_MS } from "../src/deviceSync.js";
import {
  emptySnapshot, encodeSnapshot, decodeSnapshot, seal, open, keyToBase64url,
  recordCompletion, recordDueEdit,
} from "../src/core/syncSnapshot.js";
import { BackendError } from "../src/adapters/backend.js";

const KEY = new Uint8Array(32).map((_, i) => i + 1);
const T0 = Date.parse("2026-10-22T12:00:00.000Z");
const iso = (ms) => new Date(ms).toISOString();

function fakeStorage(init = {}) {
  const data = { ...init };
  return {
    data,
    async get(k) { return typeof k === "string" ? (k in data ? { [k]: data[k] } : {}) : { ...data }; },
    async set(o) { Object.assign(data, o); },
    async remove(k) { for (const x of [].concat(k)) delete data[x]; },
  };
}

// A backend that stores blobs by row id. The extension is a linked device, so
// its row is keyed by its own user id whatever deviceId it sends.
function fakeServer({ extUser = "ext-user-0001" } = {}) {
  const rows = new Map();
  const calls = [];
  const server = {
    rows, calls, fail: null, paired: true,
    async callFunction(name, body) {
      calls.push(`${name}:${body.action}`);
      if (server.fail && (name !== "pair" || server.failStatus !== false)) throw server.fail;
      if (name === "pair") return { paired: server.paired !== false };
      if (body.action === "get") return { blobs: [...rows].map(([deviceId, ciphertext]) => ({ deviceId, ciphertext, updatedAt: "x" })) };
      rows.set(extUser, body.ciphertext);
      return { deviceId: extUser, updatedAt: "x" };
    },
    userId: async () => extUser,
  };
  return server;
}

const paired = (extra = {}) => fakeStorage({ pairingKeyV1: keyToBase64url(KEY), deviceIdV1: "ext-device-0001", ...extra });
const run = (server, storage, now, extra = {}) =>
  deviceSyncPass({ callFunction: server.callFunction, userId: server.userId, storage, now: () => now, ...extra });

async function phoneWrites(server, snap, rowId = "phone-user-0001") {
  server.rows.set(rowId, await seal(KEY, encodeSnapshot(snap)));
}

test("not paired: no-op, no network", async () => {
  const server = fakeServer();
  const r = await run(server, fakeStorage(), T0);
  assert.equal(r.status, "unpaired");
  assert.deepEqual(server.calls, []);
});

test("two-device round trip with the shared key", async () => {
  const server = fakeServer();
  const storage = paired();
  // extension ticks, then passes
  storage.data.snapshotV1 = recordCompletion(emptySnapshot("ext-device-0001", T0), "canvas:1", true, T0);
  let r = await run(server, storage, T0);
  assert.deepEqual(r, { status: "ok", remotes: 0, skipped: 0, completions: 1 });
  assert.equal(storage.data.deviceSyncRowIdV1, "ext-user-0001");
  // the phone-like reader sees it
  const seen = decodeSnapshot(await open(KEY, server.rows.get("ext-user-0001")));
  assert.equal(seen.deviceId, "ext-device-0001");
  assert.equal(seen.completions["canvas:1"].done, true);

  // phone writes a later un-tick, a due edit and a work list
  let phone = emptySnapshot("phone-device-0001", T0 + 1000);
  phone = recordCompletion(phone, "canvas:1", false, T0 + 5000);
  phone = recordDueEdit(phone, "gradescope:9", iso(T0 + 86400000), T0 + 6000);
  phone.workList = [{ id: "manual:m1", course: "CIS 1600", title: "t", dueAt: null, kind: "assignment", source: "manual", url: null, done: false }];
  await phoneWrites(server, phone);

  r = await run(server, storage, T0 + THROTTLE_MS + 1);
  assert.equal(r.status, "ok");
  assert.equal(r.remotes, 1);
  assert.equal(storage.data.snapshotV1.completions["canvas:1"].done, false);
  assert.equal(storage.data.snapshotV1.dueEdits["gradescope:9"].dueAt, iso(T0 + 86400000));
  assert.equal(storage.data.remoteWorkListsV1[0].deviceId, "phone-device-0001");
  assert.equal(storage.data.remoteWorkListsV1[0].workList[0].id, "manual:m1");
  // the merged state was written back for the phone
  const back = decodeSnapshot(await open(KEY, server.rows.get("ext-user-0001")));
  assert.equal(back.completions["canvas:1"].done, false);
  // own row is never merged as a remote
  assert.equal((await run(server, storage, T0 + 3 * THROTTLE_MS)).remotes, 1);
});

test("a bad blob is skipped, the good one still merges", async () => {
  const server = fakeServer();
  const storage = paired();
  server.rows.set("junk-user-0001", "AAAA");
  server.rows.set("wrongkey-0001", await seal(new Uint8Array(32).fill(9), encodeSnapshot(emptySnapshot("x-device-0001", T0))));
  server.rows.set("notjson-user-01", await seal(KEY, "not json"));
  server.rows.set("notbase64-0001", "%%%");
  await phoneWrites(server, recordCompletion(emptySnapshot("phone-device-0001", T0), "canvas:2", true, T0 + 1));
  const r = await run(server, storage, T0);
  assert.equal(r.status, "ok");
  assert.equal(r.remotes, 1);
  assert.equal(r.skipped, 4);
  assert.equal(storage.data.snapshotV1.completions["canvas:2"].done, true);
});

async function clearScenario(setup, expectStatus = "unpaired") {
  const server = fakeServer();
  const snap = recordCompletion(emptySnapshot("ext-device-0001", T0), "canvas:1", true, T0);
  const storage = paired({ backendSessionV1: { accessToken: "a" }, snapshotV1: snap, remoteWorkListsV1: [], deviceSyncRowIdV1: "r" });
  setup(server);
  let cleared = false;
  const r = await run(server, storage, T0, { clearSession: async () => { cleared = true; } });
  return { r, storage, snap, cleared, server };
}

test("status paired:false (fresh identity after re-signup) clears, keeps the snapshot, skips device-sync", async () => {
  const { r, storage, snap, cleared, server } = await clearScenario((s) => { s.paired = false; });
  assert.equal(r.status, "unpaired");
  for (const k of ["pairingKeyV1", "backendSessionV1", "remoteWorkListsV1", "deviceSyncRowIdV1"]) assert.equal(storage.data[k], undefined);
  assert.deepEqual(storage.data.snapshotV1, snap);
  assert.ok(cleared);
  assert.deepEqual(server.calls, ["pair:status"]);
});

test("device-sync notPaired is a second clear signal", async () => {
  const { r, storage, snap } = await clearScenario((s) => {
    const orig = s.callFunction;
    s.callFunction = async (n, b) => { if (n === "device-sync") throw new BackendError("notPaired", 403, "not_paired"); return orig(n, b); };
  });
  assert.equal(r.status, "unpaired");
  assert.equal(storage.data.pairingKeyV1, undefined);
  assert.deepEqual(storage.data.snapshotV1, snap);
});

test("unauthorized, network and server errors keep everything and stop", async () => {
  for (const kind of ["unauthorized", "network", "server"]) {
    const { r, storage, snap, cleared } = await clearScenario((s) => { s.fail = new BackendError(kind, 0, null); });
    assert.equal(r.status, "error");
    assert.equal(r.kind, kind);
    assert.ok(storage.data.pairingKeyV1);
    assert.ok(storage.data.backendSessionV1);
    assert.deepEqual(storage.data.snapshotV1, snap);
    assert.equal(cleared, false);
  }
});

test("other errors keep the pairing", async () => {
  const server = fakeServer();
  const storage = paired();
  server.fail = new BackendError("network", 0, null);
  const r = await run(server, storage, T0);
  assert.equal(r.status, "error");
  assert.ok(storage.data.pairingKeyV1);
});

test("throttle: once per two minutes, force bypasses", async () => {
  const server = fakeServer();
  const storage = paired();
  assert.equal((await run(server, storage, T0)).status, "ok");
  assert.equal((await run(server, storage, T0 + THROTTLE_MS - 1)).status, "throttled");
  assert.equal((await run(server, storage, T0 + THROTTLE_MS - 1, { force: true })).status, "ok");
  assert.equal((await run(server, storage, T0 + 2 * THROTTLE_MS)).status, "ok");
});

test("never concurrent: overlapping calls share one pass", async () => {
  const server = fakeServer();
  const storage = paired();
  const [a, b] = await Promise.all([run(server, storage, T0), run(server, storage, T0)]);
  assert.equal(a, b);
  assert.equal(server.calls.filter((c) => c === "device-sync:get").length, 1);
});
