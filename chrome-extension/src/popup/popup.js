import { buildState } from "../core/workList.js";
import { recordCompletion } from "../core/syncSnapshot.js";
import { encode, toSVG } from "../core/qr.js";
import { loadWorkList, loadSnapshot, saveSnapshot, KEYS } from "../adapters/store.js";

// Popup. `render(state, root, handlers)` is pure DOM-from-state: no chrome.*
// access, safe to call in a test with a fake document. The bottom of the file
// is the only part that touches the page, and it only runs inside the extension.

export const VIEWS = ["todo", "all", "prev"];
export const CANVAS_URL = "https://canvas.upenn.edu";
export const GRADESCOPE_URL = "https://www.gradescope.com";

// Same FNV-1a as courseAccentIndex(for:) in RedesignTokens.swift, so a class
// gets the same accent here as on the phone.
export function accentIndex(code) {
  let hash = 0xcbf29ce484222325n;
  for (const byte of new TextEncoder().encode(code)) {
    hash ^= BigInt(byte);
    hash = (hash * 0x100000001b3n) & 0xffffffffffffffffn;
  }
  return Number(hash % 6n);
}

export function visibleItems(state) {
  const items = state.items || [];
  if (state.view === "prev") return items.filter((i) => i.bucket === "prev");
  // todo: overdue + the next two days. all: future work only (overdue stays
  // out, as on the phone). See workList.js.
  if (state.view === "all") return items.filter((i) => i.bucket === "todo" || i.bucket === "later");
  return items.filter((i) => i.bucket === "overdue" || i.bucket === "todo");
}

const SVG_NS = "http://www.w3.org/2000/svg";

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

function tickIcon(doc) {
  const svg = doc.createElementNS(SVG_NS, "svg");
  svg.setAttribute("viewBox", "0 0 16 16");
  svg.setAttribute("aria-hidden", "true");
  const path = doc.createElementNS(SVG_NS, "path");
  path.setAttribute("d", "M3 8.5l3.2 3.2L13 4.5");
  svg.append(path);
  return svg;
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

  const picker = el(doc, "div", { className: "picker", role: "group", "aria-label": "view" });
  for (const view of VIEWS) {
    const b = el(doc, "button", { type: "button", "aria-pressed": String(state.view === view), text: view });
    b.addEventListener("click", () => on("view", view));
    picker.append(b);
  }
  shell.append(picker);

  // A signed-out Canvas keeps the last list on screen under the sign-in
  // line: run.js keeps each source's last good pool for exactly this, and
  // an empty popup would read as "nothing due". "all clear" is only said
  // when the list is empty and Canvas was actually read.
  if (state.canvas === "out") {
    shell.append(el(doc, "div", { className: "note" }, [
      el(doc, "p", { text: "sign in to canvas" }),
      el(doc, "a", { className: "pill", href: CANVAS_URL, target: "_blank", rel: "noopener", text: "canvas" }),
    ]));
  }
  {
    const items = visibleItems(state);
    if (items.length === 0) {
      if (state.canvas !== "out") {
        shell.append(el(doc, "div", { className: "note" }, [el(doc, "p", { text: "all clear" })]));
      }
    } else {
      const list = el(doc, "ul", { className: "list" });
      for (const item of items) {
        const tick = el(doc, "button", { className: "tick", type: "button", "aria-label": item.done ? "undo" : "done" }, [tickIcon(doc)]);
        tick.addEventListener("click", () => on("done", item.id));
        list.append(el(doc, "li", {
          className: "card" + (item.done ? " done" : ""),
          "data-accent": String(accentIndex(item.course || "")),
        }, [
          el(doc, "span", { className: "course", text: item.course }),
          el(doc, "span", { className: "title", text: item.title }),
          el(doc, "span", { className: "due", text: item.due }),
          tick,
        ]));
      }
      shell.append(list);
    }
  }

  if (state.canvas !== "out" && state.gradescope === "out") {
    shell.append(el(doc, "div", { className: "note" }, [
      el(doc, "p", { text: "sign in to gradescope" }),
      el(doc, "a", { className: "pill", href: GRADESCOPE_URL, target: "_blank", rel: "noopener", text: "gradescope" }),
    ]));
  }

  if (!state.paired) {
    const pair = el(doc, "button", { className: "pill pair quiet", type: "button", text: "pair with phone" });
    pair.addEventListener("click", () => on("pair"));
    shell.append(pair);
  } else {
    const unpair = el(doc, "button", { className: "textbtn foot", type: "button", text: "unpair" });
    unpair.addEventListener("click", () => on("unpair"));
    shell.append(unpair);
  }

  root.append(shell);
}

// Page wiring. Renders from storage at once, asks the worker to refresh, and
// re-renders when storage changes.
async function main() {
  const root = document.getElementById("root");
  if (!root) return;
  let view = "todo";
  let workList = await loadWorkList();
  let snapshot = await loadSnapshot();
  let stateItems = [];
  let remote = (await chrome.storage.local.get("remoteWorkListsV1")).remoteWorkListsV1 ?? [];
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
    const state = buildState({
      stored: workList?.items ?? [],
      completions: snapshot.completions,
      view,
      canvas: workList?.canvas ?? "unknown",
      gradescope: workList?.gradescope ?? "unknown",
      paired,
      remote,
      dueEdits: snapshot.dueEdits,
    });
    state.pairing = pairingView();
    stateItems = state.items;
    render(state, root, handlers);
  };
  const handlers = {
    view(v) { view = v; draw(); },
    async done(id) {
      const item = stateItems.find((i) => i.id === id);
      if (!item) return;
      snapshot = recordCompletion(snapshot, id, !item.done, new Date());
      await saveSnapshot(snapshot);
      draw();
    },
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
      if (res?.ok) { paired = false; remote = []; draw(); }
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
    if (changes.remoteWorkListsV1) remote = changes.remoteWorkListsV1.newValue ?? [];
    if (changes[KEYS.workList]) workList = changes[KEYS.workList].newValue ?? null;
    if (changes[KEYS.snapshot]) snapshot = changes[KEYS.snapshot].newValue ?? snapshot;
    draw();
  });

  draw();
  chrome.runtime.sendMessage({ type: "refresh" }).catch(() => {});
}

if (typeof document !== "undefined" && typeof chrome !== "undefined" && chrome.storage) main();
