import { buildState } from "../core/workList.js";
import { recordCompletion } from "../core/syncSnapshot.js";
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

export function render(state, root, handlers = {}) {
  const doc = root.ownerDocument;
  const on = (name, ...args) => handlers[name] && handlers[name](...args);
  root.replaceChildren();

  const shell = el(doc, "main", { className: "shell" });

  shell.append(el(doc, "header", { className: "head" }, [
    el(doc, "h1", { className: "wordmark", text: "Smooth" }),
    el(doc, "span", { className: "weekday", text: state.weekday || "" }),
  ]));

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

  const draw = () => {
    const state = buildState({
      stored: workList?.items ?? [],
      completions: snapshot.completions,
      view,
      canvas: workList?.canvas ?? "unknown",
      gradescope: workList?.gradescope ?? "unknown",
      paired: false,
    });
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
    pair() {}, // inert until pairing lands
  };

  chrome.storage.onChanged.addListener((changes, area) => {
    if (area !== "local") return;
    if (changes[KEYS.workList]) workList = changes[KEYS.workList].newValue ?? null;
    if (changes[KEYS.snapshot]) snapshot = changes[KEYS.snapshot].newValue ?? snapshot;
    draw();
  });

  draw();
  chrome.runtime.sendMessage({ type: "refresh" }).catch(() => {});
}

if (typeof document !== "undefined" && typeof chrome !== "undefined" && chrome.storage) main();
