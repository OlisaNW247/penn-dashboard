// QR Code encoder (ISO/IEC 18004). Byte mode, error correction level M,
// versions 1-10, automatic version choice, all 8 masks scored with the
// standard penalty rules. No dependencies, no DOM.

// ---------- tables (level M) ----------
// [EC codewords per block, [blocks, data codewords per block] groups...]
const M_BLOCKS = [
  null,
  [10, [1, 16]],
  [16, [1, 28]],
  [26, [1, 44]],
  [18, [2, 32]],
  [24, [2, 43]],
  [16, [4, 27]],
  [18, [4, 31]],
  [22, [2, 38], [2, 39]],
  [22, [3, 36], [2, 37]],
  [26, [4, 43], [1, 44]],
];
const ALIGN = [null, [], [6, 18], [6, 22], [6, 26], [6, 30], [6, 34], [6, 22, 38], [6, 24, 42], [6, 26, 46], [6, 28, 50]];
export const MAX_VERSION = 10;
const FORMAT_ECL_M = 0; // 2-bit indicator for level M

const dataCodewords = (v) => M_BLOCKS[v].slice(1).reduce((s, [n, d]) => s + n * d, 0);
const sizeOf = (v) => 17 + 4 * v;
const countBits = (v) => (v <= 9 ? 8 : 16);

// ---------- Reed-Solomon over GF(256), polynomial 0x11D ----------
const EXP = new Uint8Array(512);
const LOG = new Uint8Array(256);
{
  let x = 1;
  for (let i = 0; i < 255; i++) {
    EXP[i] = x;
    LOG[x] = i;
    x <<= 1;
    if (x & 0x100) x ^= 0x11d;
  }
  for (let i = 255; i < 512; i++) EXP[i] = EXP[i - 255];
}
const gfMul = (a, b) => (a === 0 || b === 0 ? 0 : EXP[LOG[a] + LOG[b]]);

// Coefficients (highest degree first, leading 1 omitted) of
// (x - a^0)(x - a^1)...(x - a^(degree-1)).
export function generatorPolynomial(degree) {
  let g = [1];
  for (let i = 0; i < degree; i++) {
    const next = new Array(g.length + 1).fill(0);
    for (let j = 0; j < g.length; j++) {
      next[j] ^= g[j];
      next[j + 1] ^= gfMul(g[j], EXP[i]);
    }
    g = next;
  }
  return g.slice(1);
}

export function reedSolomonRemainder(data, degree) {
  const gen = generatorPolynomial(degree);
  const rem = new Array(degree).fill(0);
  for (const b of data) {
    const factor = b ^ rem.shift();
    rem.push(0);
    for (let i = 0; i < degree; i++) rem[i] ^= gfMul(gen[i], factor);
  }
  return rem;
}

// ---------- BCH ----------
// 15-bit format info: 5 data bits (ECL << 3 | mask), BCH(15,5) g=0x537, xor 0x5412.
export function formatBits(mask) {
  const data = (FORMAT_ECL_M << 3) | mask;
  let rem = data;
  for (let i = 0; i < 10; i++) rem = (rem << 1) ^ ((rem >>> 9) * 0x537);
  return ((data << 10) | rem) ^ 0x5412;
}
// 18-bit version info: 6 data bits, BCH(18,6) g=0x1F25.
export function versionBits(version) {
  let rem = version;
  for (let i = 0; i < 12; i++) rem = (rem << 1) ^ ((rem >>> 11) * 0x1f25);
  return (version << 12) | rem;
}

// ---------- bit stream ----------
function utf8(text) {
  return Array.from(new TextEncoder().encode(text));
}

function buildDataCodewords(bytes, version) {
  const bits = [];
  const push = (value, n) => { for (let i = n - 1; i >= 0; i--) bits.push((value >>> i) & 1); };
  push(0b0100, 4); // byte mode
  push(bytes.length, countBits(version));
  for (const b of bytes) push(b, 8);
  const capBits = dataCodewords(version) * 8;
  push(0, Math.min(4, capBits - bits.length)); // terminator
  while (bits.length % 8) bits.push(0);
  const out = [];
  for (let i = 0; i < bits.length; i += 8) {
    let b = 0;
    for (let j = 0; j < 8; j++) b = (b << 1) | bits[i + j];
    out.push(b);
  }
  for (let pad = 0xec; out.length < dataCodewords(version); pad ^= 0xec ^ 0x11) out.push(pad);
  return out;
}

// Split into blocks, append RS codewords, interleave.
function interleave(data, version) {
  const [ec, ...groups] = M_BLOCKS[version];
  const blocks = [];
  let pos = 0;
  for (const [n, len] of groups) {
    for (let i = 0; i < n; i++) {
      const d = data.slice(pos, pos + len);
      pos += len;
      blocks.push({ d, e: reedSolomonRemainder(d, ec) });
    }
  }
  const out = [];
  const maxLen = Math.max(...blocks.map((b) => b.d.length));
  for (let i = 0; i < maxLen; i++) for (const b of blocks) if (i < b.d.length) out.push(b.d[i]);
  for (let i = 0; i < ec; i++) for (const b of blocks) out.push(b.e[i]);
  return out;
}

// ---------- matrix ----------
function makeGrid(version) {
  const size = sizeOf(version);
  const modules = Array.from({ length: size }, () => new Array(size).fill(false));
  const fn = Array.from({ length: size }, () => new Array(size).fill(false)); // function-pattern mask
  const set = (x, y, dark) => { modules[y][x] = dark; fn[y][x] = true; };

  for (let i = 0; i < size; i++) { // timing
    set(6, i, i % 2 === 0);
    set(i, 6, i % 2 === 0);
  }
  const finder = (cx, cy) => {
    for (let dy = -4; dy <= 4; dy++) {
      for (let dx = -4; dx <= 4; dx++) {
        const x = cx + dx, y = cy + dy;
        if (x < 0 || y < 0 || x >= size || y >= size) continue;
        const d = Math.max(Math.abs(dx), Math.abs(dy));
        set(x, y, d !== 2 && d !== 4);
      }
    }
  };
  finder(3, 3);
  finder(size - 4, 3);
  finder(3, size - 4);

  const pos = ALIGN[version];
  for (const cy of pos) {
    for (const cx of pos) {
      const last = pos.length - 1;
      const onFinder = (cx === pos[0] && cy === pos[0]) || (cx === pos[0] && cy === pos[last]) || (cx === pos[last] && cy === pos[0]);
      if (onFinder) continue;
      for (let dy = -2; dy <= 2; dy++) for (let dx = -2; dx <= 2; dx++) set(cx + dx, cy + dy, Math.max(Math.abs(dx), Math.abs(dy)) !== 1);
    }
  }
  drawFormat(modules, fn, size, 0); // reserve; rewritten once the mask is chosen
  if (version >= 7) {
    const bits = versionBits(version);
    for (let i = 0; i < 18; i++) {
      const bit = ((bits >>> i) & 1) === 1;
      const a = size - 11 + (i % 3), b = Math.floor(i / 3);
      set(a, b, bit);
      set(b, a, bit);
    }
  }
  return { size, modules, fn };
}

function drawFormat(modules, fn, size, mask) {
  const bits = formatBits(mask);
  const set = (x, y, dark) => { modules[y][x] = dark; fn[y][x] = true; };
  const bit = (i) => ((bits >>> i) & 1) === 1;
  for (let i = 0; i <= 5; i++) set(8, i, bit(i));
  set(8, 7, bit(6));
  set(8, 8, bit(7));
  set(7, 8, bit(8));
  for (let i = 9; i < 15; i++) set(14 - i, 8, bit(i));
  for (let i = 0; i < 8; i++) set(size - 1 - i, 8, bit(i));
  for (let i = 8; i < 15; i++) set(8, size - 15 + i, bit(i));
  set(8, size - 8, true); // the always-dark module
}

function placeData(g, codewords) {
  const { size, modules, fn } = g;
  let i = 0;
  const total = codewords.length * 8;
  for (let right = size - 1; right >= 1; right -= 2) {
    if (right === 6) right = 5;
    for (let vert = 0; vert < size; vert++) {
      for (let j = 0; j < 2; j++) {
        const x = right - j;
        const upward = ((right + 1) & 2) === 0;
        const y = upward ? size - 1 - vert : vert;
        if (!fn[y][x] && i < total) {
          modules[y][x] = ((codewords[i >>> 3] >>> (7 - (i & 7))) & 1) === 1;
          i++;
        }
      }
    }
  }
  return i; // bits placed
}

const MASKS = [
  (x, y) => (x + y) % 2 === 0,
  (x, y) => y % 2 === 0,
  (x, y) => x % 3 === 0,
  (x, y) => (x + y) % 3 === 0,
  (x, y) => (Math.floor(y / 2) + Math.floor(x / 3)) % 2 === 0,
  (x, y) => ((x * y) % 2) + ((x * y) % 3) === 0,
  (x, y) => (((x * y) % 2) + ((x * y) % 3)) % 2 === 0,
  (x, y) => (((x + y) % 2) + ((x * y) % 3)) % 2 === 0,
];

function applyMask(g, mask) {
  for (let y = 0; y < g.size; y++) for (let x = 0; x < g.size; x++) if (!g.fn[y][x] && MASKS[mask](x, y)) g.modules[y][x] = !g.modules[y][x];
}

// Penalty rules N1..N4 (3, 3, 40, 10).
export function penalty(modules) {
  const n = modules.length;
  let score = 0;
  const line = (get) => {
    for (let a = 0; a < n; a++) {
      let run = 1;
      for (let b = 1; b <= n; b++) {
        if (b < n && get(a, b) === get(a, b - 1)) run++;
        else { if (run >= 5) score += 3 + (run - 5); run = 1; }
      }
      // finder-like 1:1:3:1:1 with four light modules on a side
      for (let b = 0; b + 11 <= n; b++) {
        let p1 = true, p2 = true;
        const A = [1, 0, 1, 1, 1, 0, 1, 0, 0, 0, 0], B = [0, 0, 0, 0, 1, 0, 1, 1, 1, 0, 1];
        for (let k = 0; k < 11 && (p1 || p2); k++) {
          const v = get(a, b + k) ? 1 : 0;
          if (v !== A[k]) p1 = false;
          if (v !== B[k]) p2 = false;
        }
        if (p1) score += 40;
        if (p2) score += 40;
      }
    }
  };
  line((r, c) => modules[r][c]);
  line((c, r) => modules[r][c]);
  for (let y = 0; y < n - 1; y++) for (let x = 0; x < n - 1; x++) {
    const c = modules[y][x];
    if (c === modules[y][x + 1] && c === modules[y + 1][x] && c === modules[y + 1][x + 1]) score += 3;
  }
  let dark = 0;
  for (const row of modules) for (const m of row) if (m) dark++;
  const k = Math.ceil(Math.abs(dark * 20 - n * n * 10) / (n * n)) - 1;
  score += Math.max(0, k) * 10;
  return score;
}

// ---------- public ----------

export class QRError extends Error {}

export function chooseVersion(byteLength) {
  for (let v = 1; v <= MAX_VERSION; v++) {
    if (4 + countBits(v) + byteLength * 8 <= dataCodewords(v) * 8) return v;
  }
  throw new QRError(`text too long for QR version ${MAX_VERSION}-M (${byteLength} bytes)`);
}

// encode(text, { mask }) -> { size, modules, version, mask, codewords }
// `mask` (0-7) forces a mask, otherwise the lowest-penalty one is used.
export function encode(text, { mask } = {}) {
  const bytes = utf8(String(text));
  const version = chooseVersion(bytes.length);
  const codewords = interleave(buildDataCodewords(bytes, version), version);
  const base = makeGrid(version);
  const free = base.fn.reduce((n, r) => n + r.filter((f) => !f).length, 0);
  const remainder = version >= 2 && version <= 6 ? 7 : 0;
  if (free !== codewords.length * 8 + remainder) throw new QRError("internal: data capacity mismatch");
  placeData(base, codewords);
  const candidates = mask === undefined ? [0, 1, 2, 3, 4, 5, 6, 7] : [mask];
  let best = null;
  for (const m of candidates) {
    if (!Number.isInteger(m) || m < 0 || m > 7) throw new QRError("mask must be 0-7");
    const g = { size: base.size, fn: base.fn, modules: base.modules.map((r) => r.slice()) };
    applyMask(g, m);
    drawFormat(g.modules, g.fn.map((r) => r.slice()), g.size, m);
    const p = penalty(g.modules);
    if (!best || p < best.p) best = { p, m, modules: g.modules };
  }
  return { size: base.size, modules: best.modules, version, mask: best.m, codewords };
}

// SVG with `dark` modules in currentColor so the popup's ink colour applies.
// A QR code must be dark-on-light to scan: the background is a light paper
// colour (default #ffffff, the popup's light --paper), and callers must keep
// `color` dark on the element (in the popup's dark scheme, set
// color: #1b1714 on the QR's container rather than inheriting the light ink,
// or phones will not read it). Runs of dark modules in a row are merged into
// one path segment; shape-rendering is crispEdges.
export function toSVG(qr, { margin = 4, light = "#ffffff", dark = "currentColor" } = {}) {
  const total = qr.size + margin * 2;
  let d = "";
  for (let y = 0; y < qr.size; y++) {
    let x = 0;
    while (x < qr.size) {
      if (!qr.modules[y][x]) { x++; continue; }
      let run = 1;
      while (x + run < qr.size && qr.modules[y][x + run]) run++;
      d += `M${x + margin} ${y + margin}h${run}v1h${-run}z`;
      x += run;
    }
  }
  return `<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${total} ${total}" shape-rendering="crispEdges" role="img" aria-label="QR code">` +
    `<rect width="${total}" height="${total}" fill="${light}"/><path d="${d}" fill="${dark}"/></svg>`;
}
