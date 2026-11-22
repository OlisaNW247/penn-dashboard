// The injector that adds catalog designs to the hosting platform's Worker,
// against synthetic hosts of each dictionary shape it accepts. The real file
// is not in this repository (it embeds the live images), so these pin what
// the reader tolerates and what it refuses.
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";
import { addPosters, hostDesigns, imagesKept, imageShape, AddPostersError } from "../scripts/lib/add-posters.mjs";
import { DESIGNS, POSTER_NAMES } from "../worker/catalog.js";

const root = join(dirname(fileURLToPath(import.meta.url)), "..");
const SCHOOLS = ["upenn", "umiami", "uva"];
const JPEG = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 1, 2, 3]);
const b64 = JPEG.toString("base64");

const host = (dict, mapBody = `["ib", "Funneled into IB"], ["soccer", "That Was Pretty Smooth"]`) =>
  `const appStore = "x";\nconst posters = new Map([${mapBody}]);\nconst imageData = ${JSON.stringify(dict)};\nconst schools = new Map();\n`;
const perSchool = { "ib": "data:image/jpeg;base64,AAAA", "upenn/soccer": "data:image/jpeg;base64,BBBB" };
const flat = { ib: "AAAA", soccer: "BBBB" };
const nested = { upenn: { ib: "AAAA" }, uva: { ib: "CCCC" } };
const schoolKeyed = { "upenn/ib": "data:image/jpeg;base64,AAAA", "uva/ib": "data:image/jpeg;base64,CCCC" };

test("reads the host's designs and quote style", () => {
  assert.deepEqual(hostDesigns(host(flat)).keys, ["ib", "soccer"]);
  assert.equal(hostDesigns(host(flat, `['ib', 'Funneled into IB']`)).quote, "'");
});

test("a per-school host gets one entry per school, a data URL like its neighbours", () => {
  const r = addPosters(host(schoolKeyed), [{ key: "missed", name: "Missed a Deadline?", jpeg: JPEG }], SCHOOLS);
  assert.deepEqual(r.added, ["missed"]);
  const dict = JSON.parse(r.text.split("\n")[2].slice("const imageData = ".length, -1));
  for (const s of SCHOOLS) assert.equal(dict[`${s}/missed`], `data:image/jpeg;base64,${b64}`);
  assert.equal(dict["upenn/ib"], schoolKeyed["upenn/ib"]);
  assert.match(r.text, /\["soccer", "That Was Pretty Smooth"\], \["missed", "Missed a Deadline\?"\]\]\);/);
  assert.ok(imagesKept(host(schoolKeyed), r.text));
});

test("a per-design host gets one bare base64 entry; a nested host one per school", () => {
  const a = addPosters(host(flat), [{ key: "ask", name: "Ask", jpeg: JPEG }], SCHOOLS);
  assert.equal(JSON.parse(a.text.split("\n")[2].slice(18, -1)).ask, b64);
  const n = addPosters(host(nested), [{ key: "ask", name: "Ask", jpeg: JPEG }], SCHOOLS);
  const d = JSON.parse(n.text.split("\n")[2].slice(18, -1));
  assert.equal(d.upenn.ask, b64);
  assert.equal(d.umiami.ask, b64);
  assert.equal(d.uva.ib, "CCCC");
  assert.ok(imagesKept(host(nested), n.text));
});

test("a design the host already lists is skipped, so a second run changes nothing", () => {
  const once = addPosters(host(flat), [{ key: "ask", name: "Ask", jpeg: JPEG }], SCHOOLS).text;
  const twice = addPosters(once, [{ key: "ask", name: "Ask", jpeg: JPEG }], SCHOOLS);
  assert.deepEqual(twice.added, []);
  assert.equal(twice.text, once);
  const none = addPosters(host(flat), [{ key: "ib", name: "Funneled into IB", jpeg: JPEG }], SCHOOLS);
  assert.equal(none.text, host(flat));
});

test("refuses what it does not understand, and writes nothing", () => {
  const add = [{ key: "ask", name: "Ask", jpeg: JPEG }];
  assert.throws(() => addPosters(host(perSchool), add, SCHOOLS), AddPostersError); // mixed keys
  assert.throws(() => addPosters(host({}), add, SCHOOLS), AddPostersError);
  assert.throws(() => addPosters(host(flat).replace("const imageData", "const images"), add, SCHOOLS), AddPostersError);
  assert.throws(() => addPosters(host(flat) + host(flat), add, SCHOOLS), AddPostersError); // two Maps
  assert.throws(() => addPosters(host(flat), [{ key: "Bad Key", name: "x", jpeg: JPEG }], SCHOOLS), AddPostersError);
  assert.throws(() => addPosters(host(flat), [{ key: "ask", name: "x", jpeg: Buffer.from("png") }], SCHOOLS), AddPostersError);
  assert.throws(() => imageShape({ a: 1 }, SCHOOLS), AddPostersError); // a value that is not a string
});

test("a changed or missing original picture is caught", () => {
  const edited = host({ ...schoolKeyed, "upenn/ib": "data:image/jpeg;base64,ZZZZ" });
  assert.equal(imagesKept(host(schoolKeyed), edited), false);
  assert.equal(imagesKept(host(schoolKeyed), host({ "uva/ib": schoolKeyed["uva/ib"] })), false);
});

test("every catalog design has a name, and a design not yet live has a preview the injector accepts", () => {
  const live = ["best-actor", "regista", "jester", "ib", "kylie", "compute", "these-two", "soccer", "grind", "ai-end", "smoother", "tabard", "taylor", "venture"];
  for (const key of DESIGNS) {
    assert.ok(POSTER_NAMES[key], key);
    if (live.includes(key)) continue;
    const jpeg = readFileSync(join(root, "posters/previews", `${key}.jpg`));
    const r = addPosters(host(schoolKeyed), [{ key, name: POSTER_NAMES[key], jpeg }], SCHOOLS);
    assert.deepEqual(r.added, [key]);
  }
});
