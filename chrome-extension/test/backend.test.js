import { test } from "node:test";
import assert from "node:assert/strict";
import { createBackend, BackendError, SESSION_KEY, SUPABASE_URL, PUBLISHABLE_KEY } from "../src/adapters/backend.js";

function fakeStorage(init = {}) {
  const data = { ...init };
  return {
    data,
    async get(k) { return k in data ? { [k]: data[k] } : {}; },
    async set(o) { Object.assign(data, o); },
    async remove(k) { delete data[k]; },
  };
}
const resp = (status, json) => ({ ok: status >= 200 && status < 300, status, text: async () => (json === undefined ? "" : JSON.stringify(json)) });
const sess = (n, extra = {}) => ({ access_token: `a${n}`, refresh_token: `r${n}`, expires_at: 10_000 + n * 1000, user: { id: "u1" }, ...extra });

function harness(handler, storage = fakeStorage(), nowSec = 1000) {
  const log = [];
  const fetch = async (url, init) => {
    const entry = { url, method: init.method, headers: init.headers, body: init.body ? JSON.parse(init.body) : null };
    log.push(entry);
    return handler(entry, log);
  };
  return { log, storage, backend: createBackend({ fetch, storage, now: () => nowSec * 1000 }) };
}

test("signs up anonymously once, stores session, calls function with bearer", async () => {
  const h = harness((e) => (e.url.includes("/auth/v1/signup") ? resp(200, sess(1)) : resp(200, { ok: 1 })));
  assert.deepEqual(await h.backend.callFunction("pair", { action: "start" }), { ok: 1 });
  await h.backend.callFunction("pair", { action: "status" });
  const signups = h.log.filter((e) => e.url.endsWith("/auth/v1/signup"));
  assert.equal(signups.length, 1);
  assert.deepEqual(signups[0].body, {});
  assert.equal(signups[0].headers.apikey, PUBLISHABLE_KEY);
  const call = h.log[1];
  assert.equal(call.url, `${SUPABASE_URL}/functions/v1/pair`);
  assert.equal(call.headers.Authorization, "Bearer a1");
  assert.deepEqual(h.storage.data[SESSION_KEY], { accessToken: "a1", refreshToken: "r1", expiresAt: 11_000, userId: "u1" });
});

test("reuses persisted session across instances; refreshes when near expiry and stores rotated token", async () => {
  const storage = fakeStorage({ [SESSION_KEY]: { accessToken: "old", refreshToken: "rold", expiresAt: 1010, userId: "u1" } });
  const h = harness((e) => (e.url.includes("grant_type=refresh_token") ? resp(200, sess(2)) : resp(200, {})), storage, 1000);
  await h.backend.callFunction("x", {});
  assert.equal(h.log[0].url, `${SUPABASE_URL}/auth/v1/token?grant_type=refresh_token`);
  assert.deepEqual(h.log[0].body, { refresh_token: "rold" });
  assert.equal(h.log[1].headers.Authorization, "Bearer a2");
  assert.equal(storage.data[SESSION_KEY].refreshToken, "r2");
});

test("401 refreshes and retries once; a second 401 is unauthorized", async () => {
  let fn = 0;
  const h = harness((e) => {
    if (e.url.endsWith("/signup")) return resp(200, sess(1));
    if (e.url.includes("refresh_token")) return resp(200, sess(2));
    fn++;
    return fn === 1 ? resp(401, { error: "unauthorized" }) : resp(200, { done: true });
  });
  assert.deepEqual(await h.backend.callFunction("f", {}), { done: true });
  assert.equal(h.log.filter((e) => e.url.includes("/functions/")).length, 2);
  assert.equal(h.storage.data[SESSION_KEY].refreshToken, "r2");

  const h2 = harness((e) => (e.url.endsWith("/signup") ? resp(200, sess(1)) : e.url.includes("refresh_token") ? resp(200, sess(2)) : resp(401, { error: "unauthorized" })));
  await assert.rejects(h2.backend.callFunction("f", {}), (e) => e instanceof BackendError && e.kind === "unauthorized" && e.status === 401);
  assert.equal(h2.log.filter((e) => e.url.includes("/functions/")).length, 2);
});

test("error kinds and codes", async () => {
  const cases = [
    [403, "not_paired", "notPaired"],
    [404, "pairing_not_found", "pairingNotFound"],
    [409, "already_paired", "conflict"],
    [413, "too_large", "tooLarge"],
    [429, "quota_exceeded", "quota"],
    [502, "upstream", "server"],
    [500, undefined, "server"],
  ];
  for (const [status, code, kind] of cases) {
    const h = harness((e) => (e.url.endsWith("/signup") ? resp(200, sess(1)) : resp(status, code ? { error: code } : {})));
    await assert.rejects(h.backend.callFunction("f", {}), (e) => e.kind === kind && e.status === status && e.code === (code ?? null), `${status}`);
  }
});

test("network failures", async () => {
  const backend = createBackend({ fetch: async () => { throw new TypeError("offline"); }, storage: fakeStorage() });
  await assert.rejects(backend.callFunction("f", {}), (e) => e.kind === "network" && e.status === 0);
  const h = harness((e) => (e.url.endsWith("/signup") ? resp(200, sess(1)) : resp(200, {})));
  await h.backend.callFunction("f", {});
});

test("concurrent calls share one signup", async () => {
  const h = harness((e) => (e.url.endsWith("/signup") ? resp(200, sess(1)) : resp(200, {})));
  await Promise.all([h.backend.callFunction("a", {}), h.backend.callFunction("b", {})]);
  assert.equal(h.log.filter((e) => e.url.endsWith("/signup")).length, 1);
});

test("rejected refresh surfaces unauthorized; clearSession removes the stored session", async () => {
  const storage = fakeStorage({ [SESSION_KEY]: { accessToken: "a", refreshToken: "r", expiresAt: 0, userId: "u" } });
  const h = harness(() => resp(400, { error: "invalid_grant" }), storage);
  await assert.rejects(h.backend.callFunction("f", {}), (e) => e.kind === "unauthorized");
  await h.backend.clearSession();
  assert.equal(SESSION_KEY in storage.data, false);
});

test("errors never carry tokens", async () => {
  const h = harness((e) => (e.url.endsWith("/signup") ? resp(200, sess(1)) : resp(500, { error: "boom" })));
  await assert.rejects(h.backend.callFunction("f", { ciphertext: "SECRET" }), (e) => !JSON.stringify(e).includes("a1") && !e.message.includes("SECRET"));
});
