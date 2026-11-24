// Makes one new school's edition of a poster from another school's edition.
//
// The per-school posters are the same artwork with a different QR code in one
// square (`/scan/{school}/{design}`). To onboard a school without a design
// tool, this reads an existing school's JPEG, finds and decodes its QR, redraws
// that one square with the new school's URL, and checks its own work:
//   - the template's QR must decode to a URL that ends in
//     /scan/{templateSchool}/{design}, or this refuses (it would otherwise be
//     copying a picture whose QR says something else);
//   - the output must decode, with an independent reader, to exactly the new
//     URL;
//   - outside the QR square (and a guard band for JPEG ringing) the output
//     must still match the template closely, so nothing else on the poster
//     moved.
// No hostname is written here: the new URL is the decoded one with its school
// segment replaced.
//
// Build-time only (jpeg-js and jsqr are devDependencies and are never
// bundled into the deployed single file). Pure: bytes in, bytes out.
import jpeg from "jpeg-js";
import jsQR from "jsqr";
import qrcode from "qrcode-generator";

export class SchoolEditionError extends Error {}
const fail = (m) => {
  throw new SchoolEditionError(m);
};

const GUARD = 12; // pixels around the square ignored by the "nothing else moved" check
const WHITE_MARGIN = 3; // pixels of white painted beyond the old symbol
const QUALITY = 92;
const MAX_MEAN_DIFF = 2.5; // mean absolute channel difference outside the square
const MAX_BIG_FRACTION = 0.005; // share of outside pixels differing by more than 48

function decodeJpeg(bytes) {
  let img;
  try {
    img = jpeg.decode(bytes, { useTArray: true, formatAsRGBA: true });
  } catch (e) {
    fail("not a decodable JPEG: " + e.message);
  }
  return img;
}

function readQR(img) {
  return jsQR(new Uint8ClampedArray(img.data.buffer, img.data.byteOffset, img.data.length), img.width, img.height);
}

const isDark = (img, x, y) => {
  const i = (y * img.width + x) * 4;
  return img.data[i] + img.data[i + 1] + img.data[i + 2] < 384;
};

// The tight box of dark pixels near jsQR's estimate of the symbol. The finder
// patterns touch every side of a QR symbol, so this is the symbol itself, and
// the quiet zone around it is wide enough that the search never meets artwork.
function symbolBox(img, loc) {
  const pts = [loc.topLeftCorner, loc.topRightCorner, loc.bottomRightCorner, loc.bottomLeftCorner];
  const pad = 6;
  const x0 = Math.max(0, Math.floor(Math.min(...pts.map((p) => p.x))) - pad);
  const x1 = Math.min(img.width - 1, Math.ceil(Math.max(...pts.map((p) => p.x))) + pad);
  const y0 = Math.max(0, Math.floor(Math.min(...pts.map((p) => p.y))) - pad);
  const y1 = Math.min(img.height - 1, Math.ceil(Math.max(...pts.map((p) => p.y))) + pad);
  let bx0 = Infinity, by0 = Infinity, bx1 = -1, by1 = -1;
  for (let y = y0; y <= y1; y++)
    for (let x = x0; x <= x1; x++)
      if (isDark(img, x, y)) {
        if (x < bx0) bx0 = x;
        if (x > bx1) bx1 = x;
        if (y < by0) by0 = y;
        if (y > by1) by1 = y;
      }
  if (bx1 < 0) fail("no dark pixels where the QR code should be");
  return { x0: bx0, y0: by0, x1: bx1, y1: by1, w: bx1 - bx0 + 1, h: by1 - by0 + 1 };
}

export function newSchoolURL(decoded, templateSchool, design, newSchool) {
  const suffix = `/scan/${templateSchool}/${design}`;
  if (!decoded.endsWith(suffix)) fail(`the template's QR says ${JSON.stringify(decoded)}, which does not end in ${suffix}`);
  return decoded.slice(0, -suffix.length) + `/scan/${newSchool}/${design}`;
}

export function makeSchoolEdition(templateBytes, templateSchool, design, newSchool) {
  for (const [what, v] of [["template school", templateSchool], ["design", design], ["new school", newSchool]]) {
    if (!/^[a-z0-9-]+$/.test(v ?? "")) fail(`bad ${what} ${JSON.stringify(v)}`);
  }
  if (templateSchool === newSchool) fail("the new school is the template school");
  const src = decodeJpeg(Buffer.from(templateBytes));
  const found = readQR(src);
  if (!found) fail(`no QR code found in the ${templateSchool}/${design} poster`);
  const url = newSchoolURL(found.data, templateSchool, design, newSchool);

  const box = symbolBox(src, found.location);
  if (Math.abs(box.w - box.h) > 3) fail(`the QR symbol is not square (${box.w}x${box.h})`);
  if (box.w < 80 || box.w > src.width * 0.6) fail(`the QR symbol is an implausible size (${box.w}px)`);

  const qr = qrcode(0, "M");
  qr.addData(url, "Byte");
  qr.make();
  const n = qr.getModuleCount();

  const out = { width: src.width, height: src.height, data: Buffer.from(src.data) };
  const put = (x, y, v) => {
    if (x < 0 || y < 0 || x >= out.width || y >= out.height) return;
    const i = (y * out.width + x) * 4;
    out.data[i] = out.data[i + 1] = out.data[i + 2] = v;
    out.data[i + 3] = 255;
  };
  for (let y = box.y0 - WHITE_MARGIN; y <= box.y1 + WHITE_MARGIN; y++)
    for (let x = box.x0 - WHITE_MARGIN; x <= box.x1 + WHITE_MARGIN; x++) put(x, y, 255);
  for (let r = 0; r < n; r++) {
    const ya = box.y0 + Math.round((r * box.h) / n);
    const yb = box.y0 + Math.round(((r + 1) * box.h) / n);
    for (let c = 0; c < n; c++) {
      if (!qr.isDark(r, c)) continue;
      const xa = box.x0 + Math.round((c * box.w) / n);
      const xb = box.x0 + Math.round(((c + 1) * box.w) / n);
      for (let y = ya; y < yb; y++) for (let x = xa; x < xb; x++) put(x, y, 0);
    }
  }
  const bytes = Buffer.from(jpeg.encode(out, QUALITY).data);

  // Check 1: an independent decode of the finished file says exactly the new URL.
  const back = decodeJpeg(bytes);
  const again = readQR(back);
  if (!again || again.data !== url) fail(`the finished poster's QR decodes to ${JSON.stringify(again?.data)}, expected ${JSON.stringify(url)}`);

  // Check 2: nothing outside the square (and its guard band) moved.
  const gx0 = box.x0 - GUARD, gx1 = box.x1 + GUARD, gy0 = box.y0 - GUARD, gy1 = box.y1 + GUARD;
  let sum = 0, big = 0, count = 0;
  for (let y = 0; y < src.height; y++)
    for (let x = 0; x < src.width; x++) {
      if (x >= gx0 && x <= gx1 && y >= gy0 && y <= gy1) continue;
      const i = (y * src.width + x) * 4;
      for (let k = 0; k < 3; k++) {
        const d = Math.abs(src.data[i + k] - back.data[i + k]);
        sum += d;
        if (d > 48) big++;
        count++;
      }
    }
  const mean = sum / count;
  if (mean > MAX_MEAN_DIFF) fail(`outside the QR the poster changed too much (mean difference ${mean.toFixed(2)})`);
  if (big / count > MAX_BIG_FRACTION) fail(`outside the QR too many pixels moved (${((big / count) * 100).toFixed(3)}%)`);

  return { jpeg: bytes, url, templateUrl: found.data, box, meanOutsideDiff: mean };
}
