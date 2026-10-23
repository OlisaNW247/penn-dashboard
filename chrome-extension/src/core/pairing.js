// Pairing (docs/CHROME_EXTENSION.md "Pairing"). A pure state machine plus a
// thin flow. The key K lives in memory until `status` reports paired, and only
// then is it written to storage. Nothing here logs codes or keys.
import { generateKey, keyToBase64url } from "./syncSnapshot.js";

export const PAIRING_KEY = "pairingKeyV1";
export const SESSION_KEY = "backendSessionV1";
export const POLL_MS = 2000;
export const TTL_MS = 10 * 60 * 1000;

// ---------- pure ----------

export const unpairedState = () => ({ kind: "unpaired" });

export function pairingLink(code, key) {
  return `smooth://pair?c=${code}#k=${keyToBase64url(key)}`;
}

// States: unpaired | starting | showing{code,key,expiresAt} | paired | expired | failed{reason}
// Events: {type:"start"} {type:"started",code,key,expiresAt}
//         {type:"status",paired} {type:"tick",now} {type:"fail",reason} {type:"unpaired"}
// Unknown or irrelevant events return the same state object.
export function transition(state, event) {
  switch (event.type) {
    case "start":
      return state.kind === "unpaired" || state.kind === "expired" || state.kind === "failed" ? { kind: "starting" } : state;
    case "started":
      return state.kind === "starting"
        ? { kind: "showing", code: event.code, key: event.key, expiresAt: event.expiresAt }
        : state;
    case "status":
      return state.kind === "showing" && event.paired === true ? { kind: "paired" } : state;
    case "tick":
      return state.kind === "showing" && event.now >= state.expiresAt ? { kind: "expired" } : state;
    case "fail":
      return state.kind === "starting" || state.kind === "showing" ? { kind: "failed", reason: event.reason } : state;
    case "unpaired":
      return { kind: "unpaired" };
    default:
      return state;
  }
}

// The server answers expiresAt (ten minutes out). Fall back to ten minutes
// from now if it is missing or unparseable.
export function expiryMs(expiresAt, now) {
  const t = typeof expiresAt === "string" || typeof expiresAt === "number" ? new Date(expiresAt).getTime() : NaN;
  return Number.isFinite(t) ? t : now + TTL_MS;
}

// ---------- flow ----------

const realSleep = (ms) => new Promise((r) => setTimeout(r, ms));

// Runs until paired, expired, failed or aborted. onState(state) is called on
// every change (the popup renders `showing` as a QR of pairingLink()).
// Returns the final state; an aborted flow returns the last state and stores nothing.
export async function startPairing(backend, { storage, now = () => Date.now(), sleep = realSleep, onState = () => {}, signal, makeKey = generateKey } = {}) {
  let state = unpairedState();
  const go = (event) => {
    const next = transition(state, event);
    if (next !== state) { state = next; onState(state); }
    return state;
  };
  go({ type: "start" });
  let key;
  try {
    await backend.ensureSession?.();
    const res = await backend.callFunction("pair", { action: "start" });
    if (!res || typeof res.code !== "string" || !res.code) throw new Error("no code");
    key = makeKey();
    go({ type: "started", code: res.code, key, expiresAt: expiryMs(res.expiresAt, now()) });
  } catch (e) {
    return go({ type: "fail", reason: e && e.kind ? e.kind : "error" });
  }
  for (;;) {
    if (signal && signal.aborted) return state;
    await sleep(POLL_MS);
    if (signal && signal.aborted) return state;
    try {
      const st = await backend.callFunction("pair", { action: "status" });
      if (st && st.paired === true) {
        await storage.set({ [PAIRING_KEY]: keyToBase64url(key) });
        return go({ type: "status", paired: true });
      }
    } catch (e) {
      // Transient errors keep polling until the code expires; auth/conflict ends it.
      if (e && (e.kind === "unauthorized" || e.kind === "conflict")) return go({ type: "fail", reason: e.kind });
    }
    if (go({ type: "tick", now: now() }).kind === "expired") return state;
  }
}

export async function loadPairingKey(storage) {
  return (await storage.get(PAIRING_KEY))[PAIRING_KEY] ?? null;
}

// Unpair this device. Removes the key and the backend session. The local
// snapshotV1 ledger is deliberately left alone (the student's own changes).
// A network/server failure throws and deletes nothing, so the user can retry.
export async function unpair(backend, storage) {
  try {
    await backend.callFunction("pair", { action: "unpair" });
  } catch (e) {
    if (!e || !["unauthorized", "notPaired", "pairingNotFound"].includes(e.kind)) throw e;
  }
  await storage.remove([PAIRING_KEY, SESSION_KEY]);
  await backend.clearSession?.();
  return unpairedState();
}
