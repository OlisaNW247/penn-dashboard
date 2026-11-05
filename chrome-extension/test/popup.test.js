import { test } from "node:test";
import assert from "node:assert/strict";
import { render, ED_URL, CANVAS_URL } from "../src/popup/popup.js";

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
const all = (n) => [n, ...n.kids.flatMap(all)];
const NOW = Date.parse("2026-11-05T12:00:00Z");
const notes = (root) => root.kids[0].kids.filter((k) => k.className === "note");

function draw(over) {
  const root = new Node("div");
  render({ canvas: "in", gradescope: "in", paired: true, weekday: "Mon", now: NOW, ...over }, root, {});
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

test("popup: unpaired shows the pair button and no status line", () => {
  const root = draw({ paired: false });
  assert.ok(texts(root).includes("pair with phone"));
  assert.ok(!texts(root).some((t) => /synced/.test(t)));
  assert.ok(!texts(root).includes("unpair"));
});

test("popup: paired status line", () => {
  const line = (over) => texts(notes(draw(over))[0])[0];
  assert.equal(line({ syncedAt: NOW - 20000 }), "synced just now");
  assert.equal(line({ syncedAt: NOW - 7 * 60000 }), "synced 7m ago");
  assert.equal(line({ syncedAt: NOW - 3 * 3600000 - 5000 }), "synced 3h ago");
  assert.equal(line({}), "not synced yet");
  assert.ok(!texts(draw({ syncedAt: NOW })).includes("pair with phone"));
  assert.ok(texts(draw({})).includes("unpair"));
});

test("popup: canvas out shows the sign-in note with its link", () => {
  const n = notes(draw({ canvas: "out" })).find((x) => texts(x).includes("sign in to canvas"));
  assert.ok(n);
  assert.equal(n.kids[1].attrs.href, CANVAS_URL);
  assert.ok(!notes(draw({})).some((x) => texts(x).includes("sign in to canvas")));
});

test("popup: gradescope out shows its note", () => {
  assert.ok(notes(draw({ gradescope: "out" })).some((x) => texts(x).includes("sign in to gradescope")));
});

test("popup: no list, picker or dashboard words in either state", () => {
  for (const over of [{ paired: false }, { paired: true, syncedAt: NOW, canvas: "out" }]) {
    const root = draw(over);
    assert.ok(!texts(root).some((t) => /todo|all clear|prev/.test(t)));
    assert.ok(!all(root).some((n) => /\b(card|list|picker|tick)\b/.test(n.className)));
    assert.ok(!all(root).some((n) => n.tag === "ul" || n.tag === "li"));
  }
});
