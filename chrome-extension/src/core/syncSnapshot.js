// Sync snapshot, format 1 (docs/CHROME_EXTENSION.md, "The snapshot (format 1)").
// Pure: no chrome.*, no DOM. WebCrypto only, via globalThis.crypto.subtle.

export class SnapshotError extends Error {
  constructor(code, message) {
    super(message);
    this.name = "SnapshotError";
    this.code = code; // "format" | "shape" | "json" | "crypto" | "key"
  }
}

const bad = (m) => new SnapshotError("shape", m);

// ---------- dates ----------

export function toISO(value) {
  const d = value instanceof Date ? value : new Date(value);
  const t = d.getTime();
  if (!Number.isFinite(t)) throw bad(`invalid date: ${String(value)}`);
  return d.toISOString();
}

const time = (iso) => new Date(iso).getTime();

// ---------- construction ----------

const dict = () => Object.create(null);

export function emptySnapshot(deviceId, now) {
  return {
    format: 1,
    deviceId,
    writtenAt: toISO(now),
    completions: dict(),
    dueEdits: dict(),
    manual: dict(),
    workList: [],
  };
}

// ---------- encode / decode ----------

const cmp = (a, b) => {
  // code point order (not UTF-16 unit order)
  const x = Array.from(a), y = Array.from(b);
  const n = Math.min(x.length, y.length);
  for (let i = 0; i < n; i++) {
    const d = x[i].codePointAt(0) - y[i].codePointAt(0);
    if (d !== 0) return d;
  }
  return x.length - y.length;
};

const sortedKeys = (o) => Object.keys(o).sort(cmp);

function mapOut(src, fn) {
  const out = {};
  for (const k of sortedKeys(src)) Object.defineProperty(out, k, { value: fn(src[k]), enumerable: true, writable: true, configurable: true });
  return out;
}

export function encodeSnapshot(s) {
  const out = {
    format: 1,
    deviceId: s.deviceId,
    writtenAt: toISO(s.writtenAt),
    completions: mapOut(s.completions, (c) => ({ done: c.done, at: toISO(c.at) })),
    dueEdits: mapOut(s.dueEdits, (e) => ({ dueAt: e.dueAt == null ? null : toISO(e.dueAt), at: toISO(e.at) })),
    manual: mapOut(s.manual, (m) => ({
      title: m.title, course: m.course, dueAt: m.dueAt == null ? null : toISO(m.dueAt),
      kind: m.kind, repeatsWeekly: m.repeatsWeekly, removed: m.removed, at: toISO(m.at),
    })),
    workList: s.workList.map((w) => ({
      id: w.id, course: w.course, title: w.title, dueAt: w.dueAt == null ? null : toISO(w.dueAt),
      kind: w.kind, source: w.source, url: w.url == null ? null : w.url, done: w.done,
    })),
  };
  return JSON.stringify(out);
}

const isObj = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
const isStr = (v) => typeof v === "string";
const isBool = (v) => typeof v === "boolean";
const isDate = (v) => isStr(v) && Number.isFinite(new Date(v).getTime());
const isDateOrNull = (v) => v === null || isDate(v);
const isStrOrNull = (v) => v === null || isStr(v);

function needMap(v, name) {
  if (!isObj(v)) throw bad(`${name} must be an object`);
  return v;
}

export function decodeSnapshot(text) {
  let raw;
  try { raw = JSON.parse(text); } catch (e) { throw new SnapshotError("json", "snapshot is not valid JSON"); }
  if (!isObj(raw)) throw bad("snapshot must be an object");
  if (raw.format !== 1) throw new SnapshotError("format", `unsupported snapshot format: ${JSON.stringify(raw.format)}`);
  if (!isStr(raw.deviceId) || raw.deviceId === "") throw bad("deviceId must be a non-empty string");
  if (!isDate(raw.writtenAt)) throw bad("writtenAt must be an ISO date");

  const completions = dict();
  for (const [k, c] of Object.entries(needMap(raw.completions, "completions"))) {
    if (!isObj(c) || !isBool(c.done) || !isDate(c.at)) throw bad(`completions.${k} malformed`);
    Object.defineProperty(completions, k, { value: { done: c.done, at: c.at }, enumerable: true, writable: true, configurable: true });
  }
  const dueEdits = dict();
  for (const [k, e] of Object.entries(needMap(raw.dueEdits, "dueEdits"))) {
    if (!isObj(e) || !isDateOrNull(e.dueAt) || !isDate(e.at)) throw bad(`dueEdits.${k} malformed`);
    Object.defineProperty(dueEdits, k, { value: { dueAt: e.dueAt, at: e.at }, enumerable: true, writable: true, configurable: true });
  }
  const manual = dict();
  for (const [k, m] of Object.entries(needMap(raw.manual, "manual"))) {
    if (!isObj(m) || !isStr(m.title) || !isStr(m.course) || !isDateOrNull(m.dueAt) || !isStr(m.kind)
        || !isBool(m.repeatsWeekly) || !isBool(m.removed) || !isDate(m.at)) throw bad(`manual.${k} malformed`);
    Object.defineProperty(manual, k, {
      value: { title: m.title, course: m.course, dueAt: m.dueAt, kind: m.kind, repeatsWeekly: m.repeatsWeekly, removed: m.removed, at: m.at },
      enumerable: true, writable: true, configurable: true,
    });
  }
  if (!Array.isArray(raw.workList)) throw bad("workList must be an array");
  const workList = raw.workList.map((w, i) => {
    if (!isObj(w) || !isStr(w.id) || !isStr(w.course) || !isStr(w.title) || !isDateOrNull(w.dueAt)
        || !isStr(w.kind) || !isStr(w.source) || !isStrOrNull(w.url) || !isBool(w.done)) throw bad(`workList[${i}] malformed`);
    return { id: w.id, course: w.course, title: w.title, dueAt: w.dueAt, kind: w.kind, source: w.source, url: w.url, done: w.done };
  });
  return { format: 1, deviceId: raw.deviceId, writtenAt: raw.writtenAt, completions, dueEdits, manual, workList };
}

// ---------- base64 ----------

function bytesToBase64(bytes) {
  let s = "";
  for (let i = 0; i < bytes.length; i += 0x8000) s += String.fromCharCode(...bytes.subarray(i, i + 0x8000));
  return btoa(s);
}

function base64ToBytes(b64) {
  let bin;
  try { bin = atob(b64); } catch { throw new SnapshotError("crypto", "not valid base64"); }
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

// ---------- keys ----------

export function generateKey() {
  return globalThis.crypto.getRandomValues(new Uint8Array(32));
}

export function keyToBase64url(key) {
  return bytesToBase64(key).replace(/\+/g, "-").replace(/\//g, "_").replace(/=+$/, "");
}

export function keyFromBase64url(text) {
  if (!isStr(text) || !/^[A-Za-z0-9_-]+$/.test(text)) throw new SnapshotError("key", "key is not base64url");
  const std = text.replace(/-/g, "+").replace(/_/g, "/");
  const bytes = base64ToBytes(std + "=".repeat((4 - (std.length % 4)) % 4));
  if (bytes.length !== 32) throw new SnapshotError("key", "key must be 32 bytes");
  return bytes;
}

// ---------- envelope: AES-256-GCM, nonce || ciphertext || tag, no AAD ----------

async function importKey(keyBytes) {
  if (!(keyBytes instanceof Uint8Array) || keyBytes.length !== 32) throw new SnapshotError("key", "key must be 32 bytes");
  return globalThis.crypto.subtle.importKey("raw", keyBytes, { name: "AES-GCM" }, false, ["encrypt", "decrypt"]);
}

export async function seal(keyBytes, plaintext, nonceBytes) {
  const nonce = nonceBytes ?? globalThis.crypto.getRandomValues(new Uint8Array(12));
  if (nonce.length !== 12) throw new SnapshotError("crypto", "nonce must be 12 bytes");
  const key = await importKey(keyBytes);
  const ct = new Uint8Array(await globalThis.crypto.subtle.encrypt(
    { name: "AES-GCM", iv: nonce, tagLength: 128 }, key, new TextEncoder().encode(plaintext)));
  const out = new Uint8Array(12 + ct.length);
  out.set(nonce, 0);
  out.set(ct, 12);
  return bytesToBase64(out);
}

export async function open(keyBytes, base64) {
  const bytes = base64ToBytes(base64);
  if (bytes.length < 12 + 16) throw new SnapshotError("crypto", "sealed box too short");
  const key = await importKey(keyBytes);
  let pt;
  try {
    pt = await globalThis.crypto.subtle.decrypt(
      { name: "AES-GCM", iv: bytes.subarray(0, 12), tagLength: 128 }, key, bytes.subarray(12));
  } catch {
    throw new SnapshotError("crypto", "authentication failed");
  }
  return new TextDecoder("utf-8", { fatal: true }).decode(pt);
}

// ---------- merge ----------

// true when (at, deviceId) a beats b: later time, tie to larger deviceId.
function beats(a, b) {
  const ta = time(a.at), tb = time(b.at);
  if (ta !== tb) return ta > tb;
  return cmp(a.deviceId, b.deviceId) > 0;
}

function mergeMap(snapshots, field) {
  const best = new Map();
  for (const s of snapshots) {
    for (const k of Object.keys(s[field])) {
      const cand = { at: s[field][k].at, deviceId: s.deviceId, rec: s[field][k] };
      const cur = best.get(k);
      if (!cur || beats(cand, cur)) best.set(k, cand);
    }
  }
  const out = dict();
  for (const k of [...best.keys()].sort(cmp)) {
    Object.defineProperty(out, k, { value: { ...best.get(k).rec }, enumerable: true, writable: true, configurable: true });
  }
  return out;
}

// Merged snapshot keeps local's deviceId, writtenAt and workList. Remote work lists
// are returned separately, never merged.
export function mergeSnapshots(local, remotes) {
  const all = [local, ...remotes];
  const merged = {
    format: 1,
    deviceId: local.deviceId,
    writtenAt: local.writtenAt,
    completions: mergeMap(all, "completions"),
    dueEdits: mergeMap(all, "dueEdits"),
    manual: mergeMap(all, "manual"),
    workList: local.workList.map((w) => ({ ...w })),
  };
  const remoteWorkLists = remotes.map((r) => ({ deviceId: r.deviceId, workList: r.workList.map((w) => ({ ...w })) }));
  return Object.assign(merged, { remoteWorkLists });
}

// ---------- local edits ----------

function withField(snapshot, field, key, value, now) {
  const at = toISO(now);
  const next = {
    ...snapshot,
    writtenAt: at,
    completions: { ...snapshot.completions },
    dueEdits: { ...snapshot.dueEdits },
    manual: { ...snapshot.manual },
    workList: snapshot.workList.map((w) => ({ ...w })),
  };
  Object.setPrototypeOf(next.completions, null);
  Object.setPrototypeOf(next.dueEdits, null);
  Object.setPrototypeOf(next.manual, null);
  Object.defineProperty(next[field], key, { value, enumerable: true, writable: true, configurable: true });
  return next;
}

export function recordCompletion(snapshot, assignmentID, done, now) {
  return withField(snapshot, "completions", assignmentID, { done: !!done, at: toISO(now) }, now);
}

export function recordDueEdit(snapshot, assignmentID, dueAt, now) {
  return withField(snapshot, "dueEdits", assignmentID,
    { dueAt: dueAt == null ? null : toISO(dueAt), at: toISO(now) }, now);
}

export function recordManual(snapshot, manualID, fields, now) {
  const prev = snapshot.manual[manualID] ?? {};
  const f = { ...prev, ...fields };
  return withField(snapshot, "manual", manualID, {
    title: f.title ?? "",
    course: f.course ?? "",
    dueAt: f.dueAt == null ? null : toISO(f.dueAt),
    kind: f.kind ?? "assignment",
    repeatsWeekly: !!f.repeatsWeekly,
    removed: false,
    at: toISO(now),
  }, now);
}

export function removeManual(snapshot, manualID, now) {
  const prev = snapshot.manual[manualID] ?? {};
  return withField(snapshot, "manual", manualID, {
    title: prev.title ?? "",
    course: prev.course ?? "",
    dueAt: prev.dueAt ?? null,
    kind: prev.kind ?? "assignment",
    repeatsWeekly: !!prev.repeatsWeekly,
    removed: true,
    at: toISO(now),
  }, now);
}
