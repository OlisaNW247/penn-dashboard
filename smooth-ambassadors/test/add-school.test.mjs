// The school injector and the QR-swap that makes a new school's poster
// editions, against a synthetic host and a synthetic poster with a real QR
// generated here. No real poster is committed (the repository is public).
import { test } from "node:test";
import assert from "node:assert/strict";
import jpeg from "jpeg-js";
import jsQR from "jsqr";
import qrcode from "qrcode-generator";
import { addSchools, addSchoolImages, hostSchools, missingImages, AddSchoolError } from "../scripts/lib/add-school.mjs";
import { makeSchoolEdition, newSchoolURL, SchoolEditionError } from "../scripts/lib/school-edition.mjs";

const BASE = "https://scan.example.test";

// A 320x420 poster: a colour gradient, some stripes, and a QR on a white plate
// at 5px per module. `qrAt` places it; `url` is what it says.
function poster(url, { qrAt = [110, 230], px = 5, seed = 0 } = {}) {
  const W = 320, H = 420;
  const data = Buffer.alloc(W * H * 4, 255);
  for (let y = 0; y < H; y++)
    for (let x = 0; x < W; x++) {
      const i = (y * W + x) * 4;
      data[i] = (x * 255) / W;
      data[i + 1] = (y * 255) / H;
      data[i + 2] = 120 + ((x + y + seed) % 40);
      if (y > 40 && y < 60) data[i] = data[i + 1] = data[i + 2] = x % 20 < 10 ? 20 : 235;
    }
  const qr = qrcode(0, "M");
  qr.addData(url, "Byte");
  qr.make();
  const n = qr.getModuleCount();
  const [qx, qy] = qrAt;
  const q = 20; // quiet zone plate
  for (let y = qy - q; y < qy + n * px + q; y++)
    for (let x = qx - q; x < qx + n * px + q; x++) {
      const i = (y * W + x) * 4;
      data[i] = data[i + 1] = data[i + 2] = 255;
    }
  for (let r = 0; r < n; r++)
    for (let c = 0; c < n; c++)
      if (qr.isDark(r, c))
        for (let y = 0; y < px; y++)
          for (let x = 0; x < px; x++) {
            const i = ((qy + r * px + y) * W + qx + c * px + x) * 4;
            data[i] = data[i + 1] = data[i + 2] = 0;
          }
  return Buffer.from(jpeg.encode({ data, width: W, height: H }, 90).data);
}
const readUrl = (bytes) => {
  const img = jpeg.decode(bytes, { useTArray: true, formatAsRGBA: true });
  return jsQR(new Uint8ClampedArray(img.data.buffer, img.data.byteOffset, img.data.length), img.width, img.height)?.data;
};

const dashboard = (names = `upenn:'UPenn','case-western':'Case Western'`) =>
  `<select id="school">\n<option value="all">All schools</option><option value="upenn">UPenn</option><option value="case-western">Case Western</option>\n</select>\n<script>\nconst schoolNames = {${names}};\nconst x = 1;\n</script>`;
const host = ({ schools = `['upenn', 'UPenn'], ['case-western', 'Case Western'],`, dash = dashboard(), images = {}, posters = `['ib', 'IB'], ['jester', 'J'], ['ask', 'Ask']` } = {}) =>
  `const posters = new Map([${posters}]);\nconst schools = new Map([\n  ${schools}\n]);\nconst DASH = \`${dash}\`;\nconst imageData = ${JSON.stringify(images)};\nexport default {};\n`;

test("a school is appended to the Map, the dashboard select and schoolNames, in the host's style", () => {
  const r = addSchools(host(), [{ id: "harvard", name: "Harvard" }, { id: "new-place", name: "New Place" }]);
  assert.deepEqual(r.added, ["harvard", "new-place"]);
  assert.match(r.text, /\['case-western', 'Case Western'\], \['harvard', 'Harvard'\], \['new-place', 'New Place'\],\n\]\);/);
  assert.match(r.text, /<option value="case-western">Case Western<\/option><option value="harvard">Harvard<\/option><option value="new-place">New Place<\/option>\n<\/select>/);
  assert.match(r.text, /const schoolNames = \{upenn:'UPenn','case-western':'Case Western',harvard:'Harvard','new-place':'New Place'\};/);
  assert.deepEqual(hostSchools(r.text).ids, ["upenn", "case-western", "harvard", "new-place"]);
  // Only the three insertions differ: take them back out and the original is left.
  const back = r.text
    .replace(" ['harvard', 'Harvard'], ['new-place', 'New Place'],", "")
    .replace('<option value="harvard">Harvard</option><option value="new-place">New Place</option>', "")
    .replace(",harvard:'Harvard','new-place':'New Place'", "");
  assert.equal(back, host());
});

test("a Map without a trailing comma, and double quotes, are followed", () => {
  const r = addSchools(host({ schools: `["upenn", "UPenn"], ["a", "A"]` }), [{ id: "b", name: "B" }]);
  assert.match(r.text, /\["a", "A"\], \["b", "B"\]\n\]\);/);
});

test("a school the host already has is skipped, so a second run changes nothing", () => {
  const once = addSchools(host(), [{ id: "harvard", name: "Harvard" }]).text;
  const twice = addSchools(once, [{ id: "harvard", name: "Harvard" }, { id: "case-western", name: "Case Western" }]);
  assert.deepEqual(twice.added, []);
  assert.equal(twice.text, once);
});

test("each anchor must be found exactly once, or nothing is written", () => {
  const add = [{ id: "harvard", name: "Harvard" }];
  const good = host();
  assert.throws(() => addSchools(good + good.split("\n")[1], add), AddSchoolError); // none: second Map handled below
  assert.throws(() => addSchools(good + "const schools = new Map([['x','X']]);\n", add), AddSchoolError); // two Maps
  assert.throws(() => addSchools(host({ dash: dashboard().replace("</option>\n</select>", "</option></select>") }), add), AddSchoolError); // no option anchor
  assert.throws(() => addSchools(host({ dash: dashboard() + "\n" + dashboard() }), add), AddSchoolError); // two option anchors and two names
  assert.throws(() => addSchools(host({ dash: dashboard().replace("const schoolNames", "const names") }), add), AddSchoolError);
  assert.throws(() => addSchools(host({ dash: dashboard() + "const schoolNames = {};" }), add), AddSchoolError); // two names
  assert.throws(() => addSchools(good.replace("const schools = new Map([", "const sch = new Map(["), add), AddSchoolError);
  // Nothing is ever returned half-edited: the input string is immutable, and a throw returns no text.
});

test("a bad id or name is refused", () => {
  for (const bad of [{ id: "Har Vard", name: "H" }, { id: "x", name: "A'B" }, { id: "x", name: "A<B" }, { id: "x", name: "A&B" }, { id: "x", name: "A\\B" }, { id: "x", name: "A\nB" }, { id: "x", name: "" }, { id: "../x", name: "X" }])
    assert.throws(() => addSchools(host(), [bad]), AddSchoolError, JSON.stringify(bad));
});

// ---- the QR swap

test("the edition says the new school's URL and moves nothing else", () => {
  const tpl = poster(`${BASE}/scan/uva/ib`);
  const r = makeSchoolEdition(tpl, "uva", "ib", "harvard");
  assert.equal(r.url, `${BASE}/scan/harvard/ib`);
  assert.equal(readUrl(r.jpeg), `${BASE}/scan/harvard/ib`);
  assert.equal(readUrl(tpl), `${BASE}/scan/uva/ib`);
  // Independent pixel check outside the QR square plus a guard band.
  const a = jpeg.decode(tpl, { useTArray: true, formatAsRGBA: true });
  const b = jpeg.decode(r.jpeg, { useTArray: true, formatAsRGBA: true });
  assert.equal(`${a.width}x${a.height}`, `${b.width}x${b.height}`);
  const { box } = r;
  let sum = 0, n = 0, inside = 0;
  for (let y = 0; y < a.height; y++)
    for (let x = 0; x < a.width; x++) {
      const near = x >= box.x0 - 14 && x <= box.x1 + 14 && y >= box.y0 - 14 && y <= box.y1 + 14;
      const i = (y * a.width + x) * 4;
      const d = Math.abs(a.data[i] - b.data[i]) + Math.abs(a.data[i + 1] - b.data[i + 1]) + Math.abs(a.data[i + 2] - b.data[i + 2]);
      if (near) inside += d;
      else (sum += d), n++;
    }
  assert.ok(sum / n / 3 < 2.5, `mean difference outside ${sum / n / 3}`);
  assert.ok(inside > 0, "the square did change");
});

test("a longer URL (a bigger code) still fills the same square and decodes", () => {
  const r = makeSchoolEdition(poster(`${BASE}/scan/uva/ib`), "uva", "ib", "a-school-with-a-rather-long-id");
  assert.equal(readUrl(r.jpeg), `${BASE}/scan/a-school-with-a-rather-long-id/ib`);
});

test("a template whose QR does not end in the expected suffix is refused", () => {
  assert.throws(() => makeSchoolEdition(poster(`${BASE}/scan/uva/kylie`), "uva", "ib", "harvard"), SchoolEditionError);
  assert.throws(() => makeSchoolEdition(poster(`${BASE}/scan/clark/ib`), "uva", "ib", "harvard"), SchoolEditionError);
  assert.throws(() => makeSchoolEdition(poster(`${BASE}/scan/uva/ib`), "uva", "ib", "uva"), SchoolEditionError);
  assert.throws(() => makeSchoolEdition(poster(`${BASE}/scan/uva/ib`), "uva", "ib", "Bad School"), SchoolEditionError);
  assert.throws(() => makeSchoolEdition(Buffer.from("not a jpeg"), "uva", "ib", "harvard"), SchoolEditionError);
  assert.equal(newSchoolURL(`${BASE}/scan/uva/ib`, "uva", "ib", "harvard"), `${BASE}/scan/harvard/ib`);
});

test("a poster with no QR is refused", () => {
  const blank = Buffer.from(jpeg.encode({ data: Buffer.alloc(200 * 200 * 4, 200), width: 200, height: 200 }, 90).data);
  assert.throws(() => makeSchoolEdition(blank, "uva", "ib", "harvard"), /no QR/);
});

// ---- the pictures a new school gets

const b64 = (b) => b.toString("base64");
const generic = Buffer.from([0xff, 0xd8, 0xff, 0xe0, 9, 9, 9]);
const imagesFor = (over = {}) => ({
  "upenn/ib": b64(poster(`${BASE}/scan/ib`)),
  "case-western/ib": b64(poster(`${BASE}/scan/case-western/ib`)),
  "uva/ib": b64(poster(`${BASE}/scan/uva/ib`)),
  "upenn/jester": b64(generic),
  "upenn/ask": b64(generic),
  "case-western/ask": b64(generic),
  "uva/ask": b64(generic),
  ...over,
});
const withUva = (images) =>
  host({ schools: `['upenn', 'UPenn'], ['case-western', 'Case Western'], ['uva', 'UVA'], ['harvard', 'Harvard'],`, images });
const parse = (text) => JSON.parse(text.split("\n").find((l) => l.startsWith("const imageData = ")).slice(18, -1));
const opts = { upennOnly: ["jester"], makeEdition: (b, from, d, to) => makeSchoolEdition(b, from, d, to).jpeg };

test("a design identical across two schools is copied; a differing one is a QR edition from the first school", () => {
  const before = imagesFor();
  const r = addSchoolImages(withUva(before), ["harvard"], opts);
  const d = parse(r.text);
  assert.equal(d["harvard/ask"], before["case-western/ask"]);
  assert.equal(readUrl(Buffer.from(d["harvard/ib"], "base64")), `${BASE}/scan/harvard/ib`);
  assert.equal(d["harvard/jester"], undefined, "UPenn-only designs are never made");
  assert.equal(r.made.length, 2);
  for (const k of Object.keys(before)) assert.equal(d[k], before[k], k); // nothing existing changes
  assert.deepEqual(missingImages(r.text, ["jester"]), []);
});

test("a second run is a no-op, and a host that already has harvard pictures is left alone", () => {
  const once = addSchoolImages(withUva(imagesFor()), ["harvard"], opts).text;
  const twice = addSchoolImages(once, ["harvard"], opts);
  assert.equal(twice.text, once);
  assert.deepEqual(twice.made, []);
});

test("the data URL prefix of the host is kept", () => {
  const pre = Object.fromEntries(Object.entries(imagesFor()).map(([k, v]) => [k, "data:image/jpeg;base64," + v]));
  const d = parse(addSchoolImages(withUva(pre), ["harvard"], opts).text);
  assert.match(d["harvard/ib"], /^data:image\/jpeg;base64,/);
  assert.match(d["harvard/ask"], /^data:image\/jpeg;base64,/);
});

test("no template, a template whose QR is wrong, or a design-keyed host fails loudly", () => {
  const noIb = imagesFor();
  delete noIb["case-western/ib"];
  delete noIb["uva/ib"];
  assert.throws(() => addSchoolImages(withUva(noIb), ["harvard"], opts), AddSchoolError);
  const wrong = imagesFor({ "case-western/ib": b64(poster(`${BASE}/scan/clark/ib`)) });
  assert.throws(() => addSchoolImages(withUva(wrong), ["harvard"], opts), SchoolEditionError);
  assert.throws(() => addSchoolImages(withUva({ ib: "AAAA", ask: "BBBB" }), ["harvard"], opts), AddSchoolError);
});

test("missingImages names every valid pair without a picture", () => {
  const text = withUva(imagesFor());
  assert.deepEqual(missingImages(text, ["jester"]).sort(), ["harvard/ask", "harvard/ib"]);
});
