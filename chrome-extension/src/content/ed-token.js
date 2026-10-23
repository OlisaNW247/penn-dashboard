// Content script on https://edstem.org. Ed keeps its session token in
// localStorage (`authToken`, else `authToken:us`; the same two keys the phone
// reads in EdSessionLauncher.readAuthToken). This reads that one value and
// hands it to the service worker, which keeps it in chrome.storage.session
// only. Nothing else from the page is read, logged or sent. Classic script
// (content scripts cannot be modules).
(() => {
  let token = null;
  try {
    token = localStorage.getItem("authToken") || localStorage.getItem("authToken:us");
  } catch {
    token = null;
  }
  if (typeof token !== "string" || token === "") return;
  try {
    const sent = chrome.runtime.sendMessage({ type: "edToken", token });
    if (sent && typeof sent.catch === "function") sent.catch(() => {});
  } catch {
    // The extension was reloaded under this tab; nothing to do.
  }
})();
