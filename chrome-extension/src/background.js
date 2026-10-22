// Service worker skeleton. Collection lands in a later step.

const SYNC_ALARM = "sync";

function ensureAlarm() {
  chrome.alarms.create(SYNC_ALARM, { periodInMinutes: 60 });
}

chrome.runtime.onInstalled.addListener(ensureAlarm);
chrome.runtime.onStartup.addListener(ensureAlarm);

chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name !== SYNC_ALARM) return;
  // Stub: collection lands in a later step.
});
