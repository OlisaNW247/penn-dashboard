import { test } from "node:test";
import assert from "node:assert/strict";
import { render, ED_URL } from "../src/popup/popup.js";

// A tiny DOM: enough for render(), which only builds elements.
class Node {
  constructor(tag) { this.tag = tag; this.attrs = {}; this.kids = []; this.className = ""; this.textContent = ""; this.listeners = {}; }
  setAttribute(k, v) { this.attrs[k] = v; }
  append(...c) { this.kids.push(...c); }
  replaceChildren() { this.kids = []; }
  addEventListener(n, f) { this.listeners[n] = f; }
  querySelector() { return new Node("x"); }
  get ownerDocument() { return fakeDoc; }
}
const fakeDoc = { createElement: (t) => new Node(t), createElementNS: (_, t) => new Node(t) };
const texts = (n) => [n.textContent, ...n.kids.flatMap(texts)].filter(Boolean);
const notes = (root) => root.kids[0].kids.filter((k) => k.className === "note");

function draw(over) {
  const root = new Node("div");
  render({ view: "todo", items: [], canvas: "in", gradescope: "in", paired: true, weekday: "Mon", ...over }, root, {});
  return root;
}

test("popup: ed none says to open ed once, with a link", () => {
  const n = notes(draw({ ed: "none" })).find((x) => texts(x).includes("open ed once to sync its posts"));
  assert.ok(n);
  assert.deepEqual(texts(n), ["open ed once to sync its posts", "ed"]);
  const a = n.kids[1];
  assert.equal(a.tag, "a");
  assert.equal(a.attrs.href, ED_URL);
  assert.equal(ED_URL, "https://edstem.org/us");
  assert.equal(a.attrs.target, "_blank");
  assert.equal(a.attrs.rel, "noopener");
  assert.equal(a.className, "pill");
});

test("popup: ed out says sign in to ed", () => {
  const n = notes(draw({ ed: "out" })).find((x) => texts(x).includes("sign in to ed"));
  assert.ok(n);
  assert.deepEqual(texts(n), ["sign in to ed", "ed"]);
});

test("popup: nothing about ed for in, error, unknown or missing", () => {
  for (const ed of ["in", "error", "unknown", undefined]) {
    const all = texts(draw({ ed }));
    assert.ok(!all.some((t) => /ed once|sign in to ed/.test(t)), String(ed));
  }
});

test("popup: nothing about ed when unpaired", () => {
  for (const ed of ["none", "out"]) {
    const all = texts(draw({ ed, paired: false }));
    assert.ok(!all.some((t) => /ed once|sign in to ed/.test(t)), ed);
  }
});
