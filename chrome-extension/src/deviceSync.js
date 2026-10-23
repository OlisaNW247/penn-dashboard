// One encrypted snapshot exchange with the paired phone (docs/CHROME_EXTENSION.md,
// "Phone sync"). Everything is injected so it runs in node. Never throws, never
// logs keys, ciphertext or snapshot contents; the summary is counts only.
import {
  emptySnapshot, encodeSnapshot, decodeSnapshot, mergeSnapshots, seal, open, keyFromBase64url,
} from "./core/syncSnapshot.js";

export const KEYS = {
  pairingKey: "pairingKeyV1",
  session: "backendSessionV1",
  snapshot: "snapshotV1",
  deviceId: "deviceIdV1",
  rowId: "deviceSyncRowIdV1",
  remote: "remoteWorkListsV1",
  last: "deviceSyncAtV1",
};
export const THROTTLE_MS = 2 * 60 * 1000;

let inFlight = null;

// storage: chrome.storage.local-shaped (get/set/remove, promises).
// userId: optional async () => the backend user id (this device's row key).
// clearSession: optional async () => drop the backend's cached session.
// force: skip the throttle (still never concurrent).
export function deviceSyncPass(opts) {
  if (inFlight) return inFlight;
  inFlight = pass(opts).catch(() => ({ status: "error" })).finally(() => { inFlight = null; });
  return inFlight;
}

const get = async (storage, k) => (await storage.get(k))[k];

async function pass({ callFunction, storage, now = () => Date.now(), userId, clearSession, force = false }) {
  const keyText = await get(storage, KEYS.pairingKey);
  if (!keyText) return { status: "unpaired" };
  const t = typeof now === "function" ? now() : now;
  const nowMs = t instanceof Date ? t.getTime() : t;
  const last = await get(storage, KEYS.last);
  if (!force && typeof last === "number" && nowMs - last < THROTTLE_MS && nowMs >= last) return { status: "throttled" };
  await storage.set({ [KEYS.last]: nowMs });

  let key;
  try { key = keyFromBase64url(keyText); } catch { return { status: "error", kind: "key" }; }

  const unpair = async (reason) => {
    await storage.remove([KEYS.pairingKey, KEYS.session, KEYS.remote, KEYS.rowId]);
    try { await clearSession?.(); } catch { /* nothing to do */ }
    return { status: "unpaired", reason };
  };

  try {
    // A deleted extension user is replaced by a fresh anonymous one, which is
    // unlinked; only `status` says so (device-sync would answer an empty set).
    const st = await callFunction("pair", { action: "status" });
    if (!st || st.paired !== true) return await unpair("status");
    const got = await callFunction("device-sync", { action: "get" });
    const blobs = Array.isArray(got?.blobs) ? got.blobs : [];

    let deviceId = await get(storage, KEYS.deviceId);
    if (!deviceId) { deviceId = globalThis.crypto.randomUUID(); await storage.set({ [KEYS.deviceId]: deviceId }); }
    const mine = new Set([deviceId]);
    const rowId = await get(storage, KEYS.rowId);
    if (rowId) mine.add(rowId);
    if (userId) { try { const u = await userId(); if (u) mine.add(u); } catch { /* network; row id may still be known */ } }

    const remotes = [];
    let skipped = 0;
    for (const b of blobs) {
      if (!b || typeof b.deviceId !== "string" || mine.has(b.deviceId)) continue;
      try {
        const snap = decodeSnapshot(await open(key, b.ciphertext));
        if (mine.has(snap.deviceId)) continue; // our own snapshot under another row
        remotes.push(snap);
      } catch { skipped++; }
    }

    // Read local after the slow work, so a tick made meanwhile is merged, not lost.
    const stored = await get(storage, KEYS.snapshot);
    const local = stored && stored.format === 1 ? stored : emptySnapshot(deviceId, new Date(nowMs));
    const merged = mergeSnapshots(local, remotes);
    const { remoteWorkLists, ...snapshot } = merged;
    await storage.set({ [KEYS.snapshot]: snapshot, [KEYS.remote]: remoteWorkLists });

    const sealed = await seal(key, encodeSnapshot(snapshot));
    const res = await callFunction("device-sync", { action: "put", deviceId: snapshot.deviceId, ciphertext: sealed });
    if (res && typeof res.deviceId === "string" && res.deviceId) await storage.set({ [KEYS.rowId]: res.deviceId });
    return { status: "ok", remotes: remotes.length, skipped, completions: Object.keys(snapshot.completions).length };
  } catch (e) {
    if (e && e.kind === "notPaired") return unpair("notPaired");
    return { status: "error", kind: e && e.kind ? e.kind : "error" };
  }
}
