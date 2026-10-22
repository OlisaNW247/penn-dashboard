// Service worker. Thin: it only decides when to run `refresh`.
import { refresh } from "./run.js";

const SYNC_ALARM = "sync";

function start() {
  chrome.alarms.create(SYNC_ALARM, { periodInMinutes: 60 });
  refresh();
}

chrome.runtime.onInstalled.addListener(start);
chrome.runtime.onStartup.addListener(start);

chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === SYNC_ALARM) refresh();
});

chrome.runtime.onMessage.addListener((message, _sender, sendResponse) => {
  if (message?.type !== "refresh") return false;
  refresh().then(() => sendResponse({ ok: true }));
  return true;
});
