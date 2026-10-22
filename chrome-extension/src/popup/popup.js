// Popup. `render(state, root, handlers)` is pure DOM-from-state: no chrome.*
// access, safe to call in a test with a fake document. The bottom of the file
// is the only part that touches the page, and it works without chrome.*.

// Clearly fake data. A later step replaces this with real state.
export const SAMPLE = {
  weekday: "tuesday",
  view: "todo", // todo | all | prev
  canvas: "in", // in | out
  paired: false,
  items: [
    { id: "s1", course: "TEST 101", title: "Sample problem set", due: "5h left", bucket: "todo", done: false },
    { id: "s2", course: "DEMO 220", title: "Example reading response", due: "in 2 days", bucket: "todo", done: false },
    { id: "s3", course: "FAKE 330", title: "Placeholder lab report", due: "Fri", bucket: "todo", done: false },
    { id: "s4", course: "TEST 101", title: "Sample project draft", due: "Nov 14", bucket: "later", done: false },
    { id: "s5", course: "DEMO 220", title: "Example quiz", due: "2 days late", bucket: "prev", done: true },
  ],
};

export const VIEWS = ["todo", "all", "prev"];
export const CANVAS_URL = "https://canvas.upenn.edu";

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
  if (state.view === "all") return items.filter((i) => i.bucket !== "prev");
  return items.filter((i) => i.bucket === "todo");
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

  if (state.canvas === "out") {
    shell.append(el(doc, "div", { className: "note" }, [
      el(doc, "p", { text: "sign in to canvas" }),
      el(doc, "a", { className: "pill", href: CANVAS_URL, target: "_blank", rel: "noopener", text: "canvas" }),
    ]));
  } else {
    const items = visibleItems(state);
    if (items.length === 0) {
      shell.append(el(doc, "div", { className: "note" }, [el(doc, "p", { text: "all clear" })]));
    } else {
      const list = el(doc, "ul", { className: "list" });
      for (const item of items) {
        const tick = el(doc, "button", { className: "tick", type: "button", "aria-label": "done" }, [tickIcon(doc)]);
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

  if (!state.paired) {
    const pair = el(doc, "button", { className: "pill pair quiet", type: "button", text: "pair with phone" });
    pair.addEventListener("click", () => on("pair"));
    shell.append(pair);
  }

  root.append(shell);
}

// Page wiring. Local-only: it never needs chrome.*.
function main() {
  const root = document.getElementById("root");
  if (!root) return;
  const state = structuredClone(SAMPLE);
  const handlers = {
    view(v) { state.view = v; draw(); },
    done(id) {
      const item = state.items.find((i) => i.id === id);
      if (item) { item.done = true; item.bucket = "prev"; }
      draw();
    },
    pair() {}, // does nothing yet
  };
  const draw = () => render(state, root, handlers);
  // Screenshot hook: ?canvas=out, ?view=all, ?empty=1, ?paired=1
  const q = new URLSearchParams(location.search);
  if (q.get("canvas")) state.canvas = q.get("canvas");
  if (q.get("view")) state.view = q.get("view");
  if (q.get("paired")) state.paired = true;
  if (q.get("empty")) state.items = [];
  draw();
}

if (typeof document !== "undefined") main();
