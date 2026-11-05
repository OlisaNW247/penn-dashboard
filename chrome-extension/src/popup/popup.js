import { encode, toSVG } from "../core/qr.js";
import { loadWorkList, KEYS } from "../adapters/store.js";

// Popup. `render(state, root, handlers)` is pure DOM-from-state: no chrome.*
// access, safe to call in a test with a fake document. The bottom of the file
// is the only part that touches the page, and it only runs inside the extension.
// The popup is pairing plus one status line (owner, 2026-11-05): the extension
// gathers data for the phone and has no list of its own.

export const CANVAS_URL = "https://canvas.upenn.edu";
export const ED_URL = "https://edstem.org/us";
export const GRADESCOPE_URL = "https://www.gradescope.com";

// Not drawn by the popup any more; kept because test/workList.test.js pins the
// phone's todo/all/prev rules through it.
export function visibleItems(state) {
  const items = state.items || [];
  if (state.view === "prev") return items.filter((i) => i.bucket === "prev");
  if (state.view === "all") return items.filter((i) => i.bucket === "todo" || i.bucket === "later");
  return items.filter((i) => i.bucket === "overdue" || i.bucket === "todo");
}

// "synced just now" under a minute, then minutes, then hours. `at` is ms or null.
export function syncedLabel(at, now = Date.now()) {
  if (!Number.isFinite(at)) return "not synced yet";
  const mins = Math.floor((now - at) / 60000);
  if (mins < 1) return "synced just now";
  if (mins < 60) return `synced ${mins}m ago`;
  return `synced ${Math.floor(mins / 60)}h ago`;
}

// chrome.storage values: a number in ms or an ISO string; anything else is nothing.
export function toMillis(v) {
  if (typeof v === "number") return Number.isFinite(v) && v > 0 ? v : null;
  if (typeof v === "string") { const t = Date.parse(v); return Number.isNaN(t) ? null : t; }
  return null;
}

function el(doc, tag, props = {}, children = []) {
  const node = doc.createElement(tag);
  for (const [k, v] of Object.entries(props)) {
    if (k === "className") node.className = v;
    else if (k === "text") node.textContent = v;
    else node.setAttribute(k, v);
  }
  for (const c of children) node.append(c);
  return node;
}

// pairing: { kind: "starting" | "showing" | "expired" | "failed", svg? }
function renderPairing(doc, shell, pairing, on) {
  const textButton = (text, name) => {
    const b = el(doc, "button", { className: "textbtn", type: "button", text });
    b.addEventListener("click", () => on(name));
    return b;
  };
  if (pairing.kind === "showing" && pairing.svg) {
    const qr = el(doc, "div", { className: "qr", role: "img", "aria-label": "pairing code" });
    qr.innerHTML = pairing.svg; // generated from module bits only, see core/qr.js
    shell.append(el(doc, "div", { className: "note" }, [
      qr,
      el(doc, "p", { text: "scan with your iphone" }),
      textButton("cancel", "pairCancel"),
    ]));
  } else if (pairing.kind === "expired" || pairing.kind === "failed") {
    shell.append(el(doc, "div", { className: "note" }, [
      el(doc, "p", { text: pairing.kind === "expired" ? "code expired" : "couldn't pair" }),
      el(doc, "button", { className: "pill", type: "button", text: "try again" }),
      textButton("cancel", "pairCancel"),
    ]));
    shell.querySelector(".pill").addEventListener("click", () => on("pair"));
  } else {
    shell.append(el(doc, "div", { className: "note" }, [textButton("cancel", "pairCancel")]));
  }
}

export function render(state, root, handlers = {}) {
  const doc = root.ownerDocument;
  const on = (name, ...args) => handlers[name] && handlers[name](...args);
  root.replaceChildren();

  const shell = el(doc, "main", { className: "shell" });

  shell.append(el(doc, "header", { className: "head" }, [
    el(doc, "h1", { className: "wordmark", text: "Smooth" }),
    el(doc, "span", { className: "weekday", text: state.weekday || "" }),
  ]));

  if (state.pairing) {
    renderPairing(doc, shell, state.pairing, on);
    root.append(shell);
    return;
  }

  if (!state.paired) {
    const pair = el(doc, "button", { className: "pill pair quiet", type: "button", text: "pair with phone" });
    pair.addEventListener("click", () => on("pair"));
    shell.append(pair);
    root.append(shell);
    return;
  }

  shell.append(el(doc, "div", { className: "note" }, [
    el(doc, "p", { text: syncedLabel(state.syncedAt, state.now) }),
  ]));

  // Ed is read with a token only an Ed page can hand over (session-only, gone
  // after a browser restart), so say so when the last run had none.
  if (state.ed === "none" || state.ed === "out") {
    shell.append(el(doc, "div", { className: "note" }, [
      el(doc, "p", { text: state.ed === "none" ? "open ed once to sync its posts" : "sign in to ed" }),
      el(doc, "a", { className: "pill", href: ED_URL, target: "_blank", rel: "noopener", text: "ed" }),
    ]));
  }

  if (state.canvas === "out") {
    shell.append(el(doc, "div", { className: "note" }, [
      el(doc, "p", { text: "sign in to canvas" }),
      el(doc, "a", { className: "pill", href: CANVAS_URL, target: "_blank", rel: "noopener", text: "canvas" }),
    ]));
  }

  if (state.canvas !== "out" && state.gradescope === "out") {
    shell.append(el(doc, "div", { className: "note" }, [
      el(doc, "p", { text: "sign in to gradescope" }),
      el(doc, "a", { className: "pill", href: GRADESCOPE_URL, target: "_blank", rel: "noopener", text: "gradescope" }),
    ]));
  }

  const unpair = el(doc, "button", { className: "textbtn foot", type: "button", text: "unpair" });
  unpair.addEventListener("click", () => on("unpair"));
  shell.append(unpair);

  root.append(shell);
}

// Page wiring. Renders from storage at once, asks the worker to refresh, and
// re-renders when storage changes.
async function main() {
  const root = document.getElementById("root");
  if (!root) return;
  let workList = await loadWorkList();
  let deviceSyncAt = (await chrome.storage.local.get("deviceSyncAtV1")).deviceSyncAtV1;
  let edStatus = (await chrome.storage.local.get("collectSummaryV1")).collectSummaryV1?.ed ?? "unknown";
  let paired = !!(await chrome.storage.local.get("pairingKeyV1")).pairingKeyV1;
  const sess = await chrome.storage.session.get(["pairingStateV1", "pairingLinkV1"]);
  let pairState = sess.pairingStateV1 ?? null;
  let pairLink = sess.pairingLinkV1 ?? null;
  let svgFor = { link: null, svg: null };

  const pairingView = () => {
    if (paired || !pairState) return null;
    if (pairState.kind === "showing" && pairLink) {
      if (svgFor.link !== pairLink) {
        try { svgFor = { link: pairLink, svg: toSVG(encode(pairLink)) }; } catch { return { kind: "failed" }; }
      }
      return { kind: "showing", svg: svgFor.svg };
    }
    if (pairState.kind === "paired") return null;
    return { kind: pairState.kind === "unpaired" ? "starting" : pairState.kind };
  };

  const draw = () => {
    const state = {
      canvas: workList?.canvas ?? "unknown",
      gradescope: workList?.gradescope ?? "unknown",
      paired,
      weekday: new Date().toLocaleDateString("en-US", { weekday: "long" }).toLowerCase(),
      syncedAt: Math.max(toMillis(workList?.refreshedAt) ?? 0, toMillis(deviceSyncAt) ?? 0) || null,
      now: Date.now(),
    };
    state.ed = edStatus;
    state.pairing = pairingView();
    render(state, root, handlers);
  };
  const handlers = {
    pair() {
      pairState = { kind: "starting" };
      pairLink = null;
      draw();
      chrome.runtime.sendMessage({ type: "pair:start" }).catch(() => {});
    },
    pairCancel() {
      pairState = null;
      pairLink = null;
      draw();
      chrome.runtime.sendMessage({ type: "pair:cancel" }).catch(() => {});
    },
    async unpair() {
      if (!confirm("unpair?")) return;
      const res = await chrome.runtime.sendMessage({ type: "unpair" }).catch(() => null);
      if (res?.ok) { paired = false; draw(); }
    },
  };

  chrome.storage.onChanged.addListener((changes, area) => {
    if (area === "session") {
      if (changes.pairingStateV1) pairState = changes.pairingStateV1.newValue ?? null;
      if (changes.pairingLinkV1) pairLink = changes.pairingLinkV1.newValue ?? null;
      draw();
      return;
    }
    if (area !== "local") return;
    if (changes.pairingKeyV1) paired = !!changes.pairingKeyV1.newValue;
    if (changes.collectSummaryV1) edStatus = changes.collectSummaryV1.newValue?.ed ?? "unknown";
    if (changes.deviceSyncAtV1) deviceSyncAt = changes.deviceSyncAtV1.newValue;
    if (changes[KEYS.workList]) workList = changes[KEYS.workList].newValue ?? null;
    draw();
  });

  draw();
  chrome.runtime.sendMessage({ type: "refresh" }).catch(() => {});
}

if (typeof document !== "undefined" && typeof chrome !== "undefined" && chrome.storage) main();
