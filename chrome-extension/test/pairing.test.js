import { test } from "node:test";
import assert from "node:assert/strict";
import { transition, unpairedState, pairingLink, expiryMs, startPairing, unpair, loadPairingKey, PAIRING_KEY, SESSION_KEY, TTL_MS } from "../src/core/pairing.js";
import { keyToBase64url } from "../src/core/syncSnapshot.js";
import { BackendError } from "../src/adapters/backend.js";

const KEY = new Uint8Array(32).map((_, i) => i);

function fakeStorage(init = {}) {
  const data = { ...init };
  return {
    data,
    async get(k) { return typeof k === "string" ? (k in data ? { [k]: data[k] } : {}) : { ...data }; },
    async set(o) { Object.assign(data, o); },
    async remove(k) { for (const x of [].concat(k)) delete data[x]; },
  };
}

function fakeBackend(script) {
  const calls = [];
  return {
    calls,
    async ensureSession() {},
    async clearSession() { calls.push("clearSession"); },
    async callFunction(name, body) {
      calls.push(`${name}:${body.action}`);
      const r = script(body.action, calls);
      if (r instanceof Error) throw r;
      return r;
    },
  };
}

test("transition: happy path", () => {
  let s = unpairedState();
  s = transition(s, { type: "start" });
  assert.equal(s.kind, "starting");
  s = transition(s, { type: "started", code: "c", key: KEY, expiresAt: 1000 });
  assert.deepEqual(s, { kind: "showing", code: "c", key: KEY, expiresAt: 1000 });
  assert.equal(transition(s, { type: "status", paired: false }), s);
  assert.equal(transition(s, { type: "tick", now: 999 }), s);
  assert.equal(transition(s, { type: "status", paired: true }).kind, "paired");
});

test("transition: expiry, failure, restart, ignored events", () => {
  const showing = { kind: "showing", code: "c", key: KEY, expiresAt: 1000 };
  assert.equal(transition(showing, { type: "tick", now: 1000 }).kind, "expired");
  assert.equal(transition({ kind: "starting" }, { type: "fail", reason: "network" }).reason, "network");
  assert.equal(transition({ kind: "expired" }, { type: "start" }).kind, "starting");
  assert.equal(transition({ kind: "failed", reason: "x" }, { type: "start" }).kind, "starting");
  const paired = { kind: "paired" };
  assert.equal(transition(paired, { type: "start" }), paired);
  assert.equal(transition(paired, { type: "tick", now: 1e12 }), paired);
  assert.equal(transition(unpairedState(), { type: "status", paired: true }).kind, "unpaired");
  assert.equal(transition(paired, { type: "unpaired" }).kind, "unpaired");
});

test("link format and expiry fallback", () => {
  assert.equal(pairingLink("CODE", KEY), `smooth://pair?c=CODE#k=${keyToBase64url(KEY)}`);
  assert.equal(expiryMs("2026-10-22T12:10:00.000Z", 0), Date.parse("2026-10-22T12:10:00.000Z"));
  assert.equal(expiryMs(undefined, 5), 5 + TTL_MS);
  assert.equal(expiryMs("garbage", 5), 5 + TTL_MS);
});

test("flow: key persisted only after paired", async () => {
  const storage = fakeStorage();
  let polls = 0;
  const seenStorage = [];
  const backend = fakeBackend((action) => {
    if (action === "start") return { code: "CODE", expiresAt: new Date(10 * 60000).toISOString() };
    polls++;
    seenStorage.push(PAIRING_KEY in storage.data);
    return { paired: polls >= 3 };
  });
  const states = [];
  const sleeps = [];
  const final = await startPairing(backend, { storage, now: () => 0, sleep: async (ms) => { sleeps.push(ms); }, onState: (s) => states.push(s.kind), makeKey: () => KEY });
  assert.equal(final.kind, "paired");
  assert.deepEqual(states, ["starting", "showing", "paired"]);
  assert.deepEqual(sleeps, [2000, 2000, 2000]);
  assert.deepEqual(seenStorage, [false, false, false]);
  assert.equal(storage.data[PAIRING_KEY], keyToBase64url(KEY));
  assert.equal(await loadPairingKey(storage), keyToBase64url(KEY));
});

test("flow: expires without storing a key", async () => {
  const storage = fakeStorage();
  let t = 0;
  const backend = fakeBackend((a) => (a === "start" ? { code: "C", expiresAt: new Date(10 * 60000).toISOString() } : { paired: false }));
  const final = await startPairing(backend, { storage, now: () => t, sleep: async (ms) => { t += ms * 100; } });
  assert.equal(final.kind, "expired");
  assert.deepEqual(storage.data, {});
});

test("flow: start failure and fatal poll error", async () => {
  const storage = fakeStorage();
  const a = await startPairing(fakeBackend(() => new BackendError("conflict", 409, "already_paired")), { storage, sleep: async () => {} });
  assert.deepEqual(a, { kind: "failed", reason: "conflict" });
  const b = await startPairing(fakeBackend((act) => (act === "start" ? { code: "C", expiresAt: new Date(Date.now() + 600000).toISOString() } : new BackendError("unauthorized", 401, null))), { storage, sleep: async () => {} });
  assert.equal(b.reason, "unauthorized");
  assert.deepEqual(storage.data, {});
});

test("flow: transient poll errors keep polling; abort stops", async () => {
  const storage = fakeStorage();
  let n = 0;
  const backend = fakeBackend((a) => {
    if (a === "start") return { code: "C", expiresAt: new Date(Date.now() + 600000).toISOString() };
    return ++n === 1 ? new BackendError("network", 0, null) : { paired: true };
  });
  assert.equal((await startPairing(backend, { storage, sleep: async () => {} })).kind, "paired");
  const ctl = new AbortController();
  const b2 = fakeBackend(() => ({ code: "C", expiresAt: new Date(Date.now() + 600000).toISOString() }));
  const final = await startPairing(b2, { storage: fakeStorage(), sleep: async () => ctl.abort(), signal: ctl.signal });
  assert.equal(final.kind, "showing");
});

test("unpair removes key and session only", async () => {
  const storage = fakeStorage({ [PAIRING_KEY]: "k", [SESSION_KEY]: {}, snapshotV1: { format: 1 }, deviceIdV1: "d", workListV1: [] });
  const backend = fakeBackend(() => ({ unpaired: 1 }));
  assert.equal((await unpair(backend, storage)).kind, "unpaired");
  assert.deepEqual(backend.calls, ["pair:unpair", "clearSession"]);
  assert.deepEqual(Object.keys(storage.data).sort(), ["deviceIdV1", "snapshotV1", "workListV1"]);
});

test("unpair: server down keeps local state; notPaired still cleans up", async () => {
  const storage = fakeStorage({ [PAIRING_KEY]: "k" });
  await assert.rejects(unpair(fakeBackend(() => new BackendError("network", 0, null)), storage));
  assert.equal(storage.data[PAIRING_KEY], "k");
  await unpair(fakeBackend(() => new BackendError("notPaired", 403, "not_paired")), storage);
  assert.equal(PAIRING_KEY in storage.data, false);
});
