import { test } from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { encode, toSVG, generatorPolynomial, reedSolomonRemainder, formatBits, versionBits, chooseVersion, penalty } from "../src/core/qr.js";

const hash = (q) => createHash("sha256").update(q.modules.map((r) => r.map((b) => (b ? 1 : 0)).join("")).join("\n")).digest("hex");
const LINK = "smooth://pair?c=AbCdEfGhIjKlMnOpQrStUv#k=" + "A".repeat(43);
const C150 = "The quick brown fox 0123456789 ".repeat(5).slice(0, 150);

// Pinned matrices. Each was rendered (scale 8, margin 4) and decoded to exactly its
// input with OpenCV 4.10.0 QRCodeDetector.detectAndDecode.
test("pinned vectors (OpenCV-confirmed)", () => {
  const cases = [
    ["A", 1, 3, "bc9009ae87ca68f1d256b69eb26362086d73d9f0b95f1e9f3dccae752626c3b6"],
    [LINK, 5, 4, "5f8e92149ead40a3079054fea9cfb7a1d7734563f4cc8db078cca3d06371a5f5"],
    [C150, 8, 2, "0296cfe3b799228e5dd30e51defb8039d1d193a7f1d4f95025f0c4894a47dfd0"],
  ];
  for (const [text, version, mask, h] of cases) {
    const q = encode(text);
    assert.equal(q.version, version);
    assert.equal(q.mask, mask);
    assert.equal(q.size, 17 + 4 * version);
    assert.equal(hash(q), h);
  }
});

test("Reed-Solomon: generator polynomial exponents (ISO 18004 Annex A, degree 10)", () => {
  // alpha exponents of the degree-10 generator, published: 0 251 67 46 61 118 70 64 94 32 45
  const EXP = [];
  let x = 1;
  for (let i = 0; i < 255; i++) { EXP.push(x); x = x << 1; if (x & 0x100) x ^= 0x11d; }
  const logOf = (v) => EXP.indexOf(v);
  assert.deepEqual(generatorPolynomial(10).map(logOf), [251, 67, 46, 61, 118, 70, 64, 94, 32, 45]);
});

test("Reed-Solomon: 'HELLO WORLD' 1-Q textbook codewords (thonky.com QR tutorial)", () => {
  const data = [32, 91, 11, 120, 209, 114, 220, 77, 67, 64, 236, 17, 236];
  assert.deepEqual(reedSolomonRemainder(data, 13), [168, 72, 22, 82, 217, 54, 156, 0, 46, 15, 180, 122, 16]);
});

test("format info BCH (ISO 18004 table C.1, level M)", () => {
  assert.equal(formatBits(0).toString(2).padStart(15, "0"), "101010000010010");
  assert.equal(formatBits(1).toString(2).padStart(15, "0"), "101000100100101");
});

test("version info BCH (ISO 18004 table D.1)", () => {
  assert.equal(versionBits(7), 0x07c94);
  assert.equal(versionBits(8), 0x085bc);
  assert.equal(versionBits(10), 0x0a4d3);
});

test("structure: finders, separators, timing, dark module, format copies", () => {
  for (const text of ["A", LINK, C150]) {
    const q = encode(text);
    const m = q.modules, n = q.size;
    for (const [ox, oy] of [[0, 0], [n - 7, 0], [0, n - 7]]) {
      for (let dy = 0; dy < 7; dy++) for (let dx = 0; dx < 7; dx++) {
        const d = Math.max(Math.abs(dx - 3), Math.abs(dy - 3));
        assert.equal(m[oy + dy][ox + dx], d !== 2, `finder ${ox},${oy} ${dx},${dy}`);
      }
    }
    for (let i = 8; i < n - 8; i++) {
      assert.equal(m[6][i], i % 2 === 0);
      assert.equal(m[i][6], i % 2 === 0);
    }
    assert.equal(m[n - 8][8], true);
    // separators are light
    for (let i = 0; i < 8; i++) { assert.equal(m[7][i], false); assert.equal(m[i][7], false); }
    // both format copies agree and match the chosen mask
    const bits = formatBits(q.mask);
    const bit = (i) => ((bits >>> i) & 1) === 1;
    const a = [], b = [];
    for (let i = 0; i <= 5; i++) a[i] = m[i][8];
    a[6] = m[7][8]; a[7] = m[8][8]; a[8] = m[8][7];
    for (let i = 9; i < 15; i++) a[i] = m[8][14 - i];
    for (let i = 0; i < 8; i++) b[i] = m[8][n - 1 - i];
    for (let i = 8; i < 15; i++) b[i] = m[n - 15 + i][8];
    for (let i = 0; i < 15; i++) { assert.equal(a[i], bit(i)); assert.equal(b[i], bit(i)); }
  }
});

test("version info blocks present for version >= 7 and agree", () => {
  const q = encode(C150); // version 8
  assert.equal(q.version, 8);
  const bits = versionBits(8), n = q.size;
  for (let i = 0; i < 18; i++) {
    const bit = ((bits >>> i) & 1) === 1;
    const a = n - 11 + (i % 3), b = Math.floor(i / 3);
    assert.equal(q.modules[b][a], bit);
    assert.equal(q.modules[a][b], bit);
  }
});

test("alignment pattern at version 2", () => {
  const q = encode("x".repeat(20)); // 20 bytes -> version 2
  assert.equal(q.version, 2);
  for (let dy = -2; dy <= 2; dy++) for (let dx = -2; dx <= 2; dx++) {
    assert.equal(q.modules[18 + dy][18 + dx], Math.max(Math.abs(dx), Math.abs(dy)) !== 1);
  }
});

test("automatic version choice at M-level byte capacities", () => {
  // byte capacity at level M for versions 1..10
  const caps = [14, 26, 42, 62, 84, 106, 122, 152, 180, 213];
  caps.forEach((cap, i) => {
    assert.equal(chooseVersion(cap), i + 1);
    if (i < 9) assert.equal(chooseVersion(cap + 1), i + 2, `cap ${cap}`);
    else assert.throws(() => chooseVersion(cap + 1));
  });
});

test("too long throws, 213 bytes fits", () => {
  assert.equal(encode("x".repeat(213)).version, 10);
  assert.throws(() => encode("x".repeat(214)), /too long/);
});

test("codeword count matches version capacity", () => {
  const totals = [26, 44, 70, 100, 134, 172, 196, 242, 292, 346];
  totals.forEach((t, i) => {
    const q = encode("x".repeat([14, 26, 42, 62, 84, 106, 122, 152, 180, 213][i]));
    assert.equal(q.version, i + 1);
    assert.equal(q.codewords.length, t);
  });
});

test("data codewords: mode, count, UTF-8 bytes, terminator, pad bytes", () => {
  const q = encode("A"); // version 1: 0100 00000001 01000001 0000 then pad
  assert.deepEqual(q.codewords.slice(0, 4), [0x40, 0x14, 0x10, 0xec]);
  assert.equal(q.codewords[4], 0x11);
  const u = encode("é"); // 2 UTF-8 bytes: C3 A9
  assert.deepEqual(u.codewords.slice(0, 4), [0x40, 0x2c, 0x3a, 0x90]);
});

test("forcing a mask sets that mask; automatic choice has the minimum penalty", () => {
  const scores = [];
  for (let m = 0; m < 8; m++) {
    const q = encode(LINK, { mask: m });
    assert.equal(q.mask, m);
    scores.push(penalty(q.modules));
  }
  assert.equal(new Set(scores).size > 1, true);
  assert.equal(penalty(encode(LINK).modules), Math.min(...scores));
  assert.throws(() => encode("a", { mask: 8 }), /mask/);
});

test("penalty rules on small known grids", () => {
  const blank = Array.from({ length: 21 }, () => new Array(21).fill(false));
  // all light: N1 rows+cols: 42 lines * (3+16); N2: 400 blocks * 3; N4: 0% dark -> k=9 -> 90
  assert.equal(penalty(blank), 42 * 19 + 400 * 3 + 90);
});

test("toSVG: currentColor modules, light background, viewBox with margin", () => {
  const q = encode("A");
  const svg = toSVG(q, { margin: 4 });
  assert.match(svg, /^<svg [^>]*viewBox="0 0 29 29"/);
  assert.match(svg, /fill="currentColor"/);
  assert.match(svg, /<rect width="29" height="29" fill="#ffffff"\/>/);
  // dark-module count from the path equals the matrix
  let dark = 0;
  for (const r of q.modules) for (const b of r) if (b) dark++;
  let drawn = 0;
  for (const mt of svg.matchAll(/M(\d+) (\d+)h(\d+)v1h-\d+z/g)) {
    const [x, y, w] = [+mt[1] - 4, +mt[2] - 4, +mt[3]];
    for (let i = 0; i < w; i++) assert.equal(q.modules[y][x + i], true);
    drawn += w;
  }
  assert.equal(drawn, dark);
});
