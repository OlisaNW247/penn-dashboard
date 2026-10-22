// Service worker. Thin: it decides when to run `refresh` and the phone exchange,
// and it owns pairing so that it survives the popup closing.
import { refresh } from "./run.js";
import { defaultBackend } from "./adapters/backend.js";
import { deviceSyncPass } from "./deviceSync.js";
import { startPairing, pairingLink, unpair } from "./core/pairing.js";

const SYNC_ALARM = "sync";
export const PAIRING_STATE = "pairingStateV1"; // storage.session, never holds the key
export const PAIRING_LINK = "pairingLinkV1"; // storage.session, only while showing

const syncDevices = (force = false) => {
  const backend = defaultBackend();
  return deviceSyncPass({
    callFunction: backend.callFunction,
    userId: backend.userId,
    clearSession: backend.clearSession,
    storage: chrome.storage.local,
    now: () => Date.now(),
    force,
  });
};

const refreshThenSync = async () => { await refresh(); await syncDevices(); };

function start() {
  chrome.alarms.create(SYNC_ALARM, { periodInMinutes: 60 });
  refreshThenSync();
}

// A worker that died mid-pairing leaves a QR nobody is polling for.
chrome.storage.session.remove([PAIRING_STATE, PAIRING_LINK]);

chrome.runtime.onInstalled.addListener(start);
chrome.runtime.onStartup.addListener(start);

chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === SYNC_ALARM) refreshThenSync();
});

// ---- pairing ----

let pairing = null; // { abort: AbortController }

async function publish(state) {
  if (state.kind === "showing") {
    await chrome.storage.session.set({
      [PAIRING_STATE]: { kind: "showing", expiresAt: state.expiresAt },
      [PAIRING_LINK]: pairingLink(state.code, state.key),
    });
    return;
  }
  await chrome.storage.session.remove(PAIRING_LINK);
  await chrome.storage.session.set({
    [PAIRING_STATE]: state.kind === "failed" ? { kind: "failed" } : { kind: state.kind },
  });
}

async function runPairing() {
  const ctl = new AbortController();
  pairing = { abort: ctl };
  let chain = Promise.resolve();
  try {
    const final = await startPairing(defaultBackend(), {
      storage: chrome.storage.local,
      signal: ctl.signal,
      onState: (s) => { chain = chain.then(() => publish(s)); },
    });
    await chain;
    if (ctl.signal.aborted) {
      await chrome.storage.session.remove([PAIRING_STATE, PAIRING_LINK]);
    } else if (final.kind === "paired") {
      syncDevices(true);
    }
  } finally {
    pairing = null;
  }
}

// ---- phone exchange after a tick, debounced ----

let tickTimer = null;
chrome.storage.onChanged.addListener((changes, area) => {
  if (area !== "local" || !changes.snapshotV1) return;
  if (changes.snapshotV1.newValue?.writtenAt === changes.snapshotV1.oldValue?.writtenAt) return; // our own merge
  clearTimeout(tickTimer);
  tickTimer = setTimeout(() => syncDevices(true), 5000);
});

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  switch (message?.type) {
    case "refresh":
      refreshThenSync().then(() => sendResponse({ ok: true }));
      return true;
    case "sync":
      syncDevices().then(() => sendResponse({ ok: true }));
      return true;
    case "pair:start":
      if (!pairing) runPairing().catch(() => {});
      sendResponse({ ok: true });
      return false;
    case "pair:cancel":
      pairing?.abort.abort();
      chrome.storage.session.remove([PAIRING_STATE, PAIRING_LINK]).then(() => sendResponse({ ok: true }));
      return true;
    case "unpair": {
      const backend = defaultBackend();
      unpair(backend, chrome.storage.local)
        .then(() => chrome.storage.local.remove("remoteWorkListsV1"))
        .then(() => chrome.storage.session.remove([PAIRING_STATE, PAIRING_LINK]))
        .then(() => sendResponse({ ok: true }), () => sendResponse({ ok: false }));
      return true;
    }
    default:
      return false;
  }
});
