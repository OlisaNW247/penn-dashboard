// chrome.storage.local wrappers. Keys: workListV1, snapshotV1, deviceIdV1.
// Nothing here ever holds a feed URL or a cookie.
import { emptySnapshot } from "../core/syncSnapshot.js";

const area = () => chrome.storage.local;

export const KEYS = { workList: "workListV1", snapshot: "snapshotV1", deviceId: "deviceIdV1" };

export async function loadWorkList() {
  return (await area().get(KEYS.workList))[KEYS.workList] ?? null;
}

export async function saveWorkList(value) {
  await area().set({ [KEYS.workList]: value });
}

async function deviceId() {
  const got = (await area().get(KEYS.deviceId))[KEYS.deviceId];
  if (got) return got;
  const id = crypto.randomUUID();
  await area().set({ [KEYS.deviceId]: id });
  return id;
}

export async function loadSnapshot(now = new Date()) {
  const got = (await area().get(KEYS.snapshot))[KEYS.snapshot];
  if (got && got.format === 1) {
    // Storage hands back plain objects; the snapshot maps are plain too.
    return got;
  }
  return emptySnapshot(await deviceId(), now);
}

export async function saveSnapshot(snapshot) {
  await area().set({ [KEYS.snapshot]: snapshot });
}
