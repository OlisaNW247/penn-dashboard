import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import {
  emptySnapshot, encodeSnapshot, decodeSnapshot, seal, open, mergeSnapshots,
  recordCompletion, recordDueEdit, recordManual, removeManual,
  generateKey, keyToBase64url, keyFromBase64url, SnapshotError,
} from "../src/core/syncSnapshot.js";

const vec = JSON.parse(readFileSync(new URL("./fixtures/sync-vector-1.json", import.meta.url), "utf8"));
const hex = (h) => Uint8Array.from(h.match(/../g).map((x) => parseInt(x, 16)));
const T = (n) => `2026-10-22T${String(n).padStart(2, "0")}:00:00.000Z`;
const plain = (s) => JSON.parse(JSON.stringify(s));

test("vector: seal with the fixed nonce equals sealedBase64", async () => {
  assert.equal(await seal(hex(vec.keyHex), vec.plaintext, hex(vec.nonceHex)), vec.sealedBase64);
});

test("vector: open returns the plaintext", async () => {
  assert.equal(await open(hex(vec.keyHex), vec.sealedBase64), vec.plaintext);
});

test("vector: encode(decode(plaintext)) is byte for byte the plaintext", () => {
  assert.equal(encodeSnapshot(decodeSnapshot(vec.plaintext)), vec.plaintext);
});

test("seal with a random nonce round-trips and differs each time", async () => {
  const k = generateKey();
  const a = await seal(k, "héllo"), b = await seal(k, "héllo");
  assert.notEqual(a, b);
  assert.equal(await open(k, a), "héllo");
});

test("tampering one byte makes open throw", async () => {
  const bytes = Uint8Array.from(Buffer.from(vec.sealedBase64, "base64"));
  for (const i of [0, 20, bytes.length - 1]) {
    const t = bytes.slice(); t[i] ^= 1;
    await assert.rejects(open(hex(vec.keyHex), Buffer.from(t).toString("base64")), SnapshotError);
  }
});

test("wrong key throws", async () => {
  await assert.rejects(open(generateKey(), vec.sealedBase64), SnapshotError);
});

test("key base64url round trip, no padding", () => {
  const k = generateKey();
  assert.equal(k.length, 32);
  const s = keyToBase64url(k);
  assert.match(s, /^[A-Za-z0-9_-]{43}$/);
  assert.deepEqual(keyFromBase64url(s), k);
  assert.throws(() => keyFromBase64url("abc"), SnapshotError);
});

test("decode rejects format 2, bad JSON and malformed shapes", () => {
  const ok = JSON.parse(vec.plaintext);
  assert.throws(() => decodeSnapshot(JSON.stringify({ ...ok, format: 2 })), (e) => e.code === "format");
  assert.throws(() => decodeSnapshot("nope"), SnapshotError);
  assert.throws(() => decodeSnapshot("[]"), SnapshotError);
  assert.throws(() => decodeSnapshot(JSON.stringify({ ...ok, completions: [] })), SnapshotError);
  assert.throws(() => decodeSnapshot(JSON.stringify({ ...ok, completions: { a: { done: "yes", at: T(1) } } })), SnapshotError);
  assert.throws(() => decodeSnapshot(JSON.stringify({ ...ok, writtenAt: "yesterday" })), SnapshotError);
  assert.throws(() => decodeSnapshot(JSON.stringify({ ...ok, workList: {} })), SnapshotError);
  assert.throws(() => decodeSnapshot(JSON.stringify({ ...ok, deviceId: undefined })), SnapshotError);
});

test("decode ignores unknown extra fields", () => {
  const ok = JSON.parse(vec.plaintext);
  ok.future = 1;
  ok.completions["canvas:123"].extra = true;
  assert.equal(encodeSnapshot(decodeSnapshot(JSON.stringify(ok))), vec.plaintext);
});

test("full snapshot round trips with spec key order", () => {
  let s = emptySnapshot("d1", T(1));
  s = recordCompletion(s, "canvas:1", false, T(2));
  s = recordDueEdit(s, "canvas:1", null, T(3));
  s = recordManual(s, "m1", { title: "T", course: "CIS 1200", dueAt: T(9), kind: "assignment", repeatsWeekly: true }, T(4));
  s.workList = [{ id: "canvas:1", course: "C", title: "t", dueAt: null, kind: "assignment", source: "canvas", url: null, done: false }];
  const text = encodeSnapshot(s);
  assert.deepEqual(Object.keys(JSON.parse(text)), ["format", "deviceId", "writtenAt", "completions", "dueEdits", "manual", "workList"]);
  assert.deepEqual(Object.keys(JSON.parse(text).manual.m1), ["title", "course", "dueAt", "kind", "repeatsWeekly", "removed", "at"]);
  assert.deepEqual(Object.keys(JSON.parse(text).workList[0]), ["id", "course", "title", "dueAt", "kind", "source", "url", "done"]);
  assert.equal(encodeSnapshot(decodeSnapshot(text)), text);
});

test("record helpers return new snapshots and leave the input alone", () => {
  const s = emptySnapshot("d1", T(1));
  const before = plain(s);
  const s2 = recordCompletion(s, "canvas:1", true, T(2));
  assert.deepEqual(plain(s), before);
  assert.deepEqual(plain(s2.completions), { "canvas:1": { done: true, at: T(2) } });
  assert.equal(s2.writtenAt, T(2));
  const s3 = removeManual(recordManual(s2, "m", { title: "x" }, T(3)), "m", T(4));
  assert.equal(s3.manual.m.removed, true);
  assert.equal(s3.manual.m.title, "x");
  assert.equal(s3.manual.m.at, T(4));
});

const snap = (id, f) => f(emptySnapshot(id, T(0)));

test("merge: newer wins", () => {
  const a = recordCompletion(emptySnapshot("a", T(0)), "x", true, T(1));
  const b = recordCompletion(emptySnapshot("b", T(0)), "x", false, T(2));
  assert.equal(mergeSnapshots(a, [b]).completions.x.done, false);
  assert.equal(mergeSnapshots(b, [a]).completions.x.done, false);
});

test("merge: tie goes to the larger deviceId", () => {
  const a = recordCompletion(emptySnapshot("a", T(0)), "x", true, T(1));
  const b = recordCompletion(emptySnapshot("b", T(0)), "x", false, T(1));
  assert.equal(mergeSnapshots(a, [b]).completions.x.done, false);
  assert.equal(mergeSnapshots(b, [a]).completions.x.done, false);
});

test("merge: un-tick beats an older tick", () => {
  const a = recordCompletion(emptySnapshot("z", T(0)), "x", true, T(1));
  const b = recordCompletion(emptySnapshot("a", T(0)), "x", false, T(5));
  const m = mergeSnapshots(a, [b]);
  assert.deepEqual(m.completions.x, { done: false, at: T(5) });
});

test("merge: dueAt null edit is kept when newer", () => {
  const a = recordDueEdit(emptySnapshot("a", T(0)), "x", T(9), T(1));
  const b = recordDueEdit(emptySnapshot("b", T(0)), "x", null, T(2));
  assert.deepEqual(mergeSnapshots(a, [b]).dueEdits.x, { dueAt: null, at: T(2) });
});

test("merge: tombstone beats older edit, loses to newer re-add", () => {
  const edit = recordManual(emptySnapshot("a", T(0)), "m", { title: "old" }, T(1));
  const gone = removeManual(emptySnapshot("b", T(0)), "m", T(2));
  let m = mergeSnapshots(edit, [gone]);
  assert.equal(m.manual.m.removed, true);
  const readd = recordManual(emptySnapshot("a", T(0)), "m", { title: "new" }, T(3));
  m = mergeSnapshots(m, [readd]);
  assert.equal(m.manual.m.removed, false);
  assert.equal(m.manual.m.title, "new");
  // the tombstone is kept when nobody re-adds
  assert.equal(mergeSnapshots(gone, [emptySnapshot("c", T(0))]).manual.m.removed, true);
});

test("merge: three-way is order independent", () => {
  const a = recordDueEdit(recordCompletion(emptySnapshot("a", T(0)), "x", true, T(1)), "d", T(7), T(3));
  const b = recordManual(recordCompletion(emptySnapshot("b", T(0)), "x", false, T(2)), "m", { title: "b" }, T(5));
  const c = removeManual(recordManual(recordCompletion(emptySnapshot("c", T(0)), "x", true, T(2)), "m", { title: "c" }, T(5)), "m", T(5));
  const view = (m) => plain({ c: m.completions, d: m.dueEdits, m: m.manual });
  const ref = view(mergeSnapshots(a, [b, c]));
  for (const [l, rs] of [[a, [c, b]], [b, [a, c]], [b, [c, a]], [c, [a, b]], [c, [b, a]]]) {
    assert.deepEqual(view(mergeSnapshots(l, rs)), ref);
  }
});

test("merge: work lists are not merged and inputs are unchanged", () => {
  const wl = (id) => [{ id, course: "C", title: "t", dueAt: null, kind: "assignment", source: "canvas", url: null, done: false }];
  const a = { ...recordCompletion(emptySnapshot("a", T(0)), "x", true, T(1)), workList: wl("A") };
  const b = { ...recordCompletion(emptySnapshot("b", T(0)), "x", false, T(2)), workList: wl("B") };
  const c = { ...emptySnapshot("c", T(0)), workList: wl("C") };
  const before = plain([a, b, c]);
  const m = mergeSnapshots(a, [b, c]);
  assert.deepEqual(plain([a, b, c]), before);
  assert.deepEqual(m.remoteWorkLists.map((r) => [r.deviceId, r.workList[0].id]), [["b", "B"], ["c", "C"]]);
  assert.deepEqual(m.workList.map((w) => w.id), ["A"]);
  m.completions.x.done = true;
  m.remoteWorkLists[0].workList[0].id = "zz";
  assert.deepEqual(plain([a, b, c]), before);
});
