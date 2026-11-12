// The three font families the ambassador pages use, served from the Worker so
// the pages never call another host. The files are imported as base64 text by
// the bundler (esbuild's `base64` loader, set in scripts/build-sites.mjs and in
// the test harnesses) and decoded once per isolate. Under wrangler's `Data`
// rule they arrive as an ArrayBuffer instead, so both shapes are accepted.
import familjen from "./fonts/familjen-grotesk.woff2";
import inter from "./fonts/inter.woff2";
import spaceMono from "./fonts/space-mono.woff2";
import spaceMonoBold from "./fonts/space-mono-bold.woff2";

const SOURCES = {
  "familjen-grotesk": familjen,
  inter,
  "space-mono": spaceMono,
  "space-mono-bold": spaceMonoBold,
};

const decoded = new Map();

function toBytes(src) {
  if (typeof src !== "string") return new Uint8Array(src);
  const bin = atob(src);
  const out = new Uint8Array(bin.length);
  for (let i = 0; i < bin.length; i++) out[i] = bin.charCodeAt(i);
  return out;
}

// `file` is the last path segment, e.g. "inter.woff2". Null when it is not one of ours.
export function fontResponse(file) {
  const m = /^([a-z-]+)\.woff2$/.exec(file || "");
  if (!m || !Object.hasOwn(SOURCES, m[1])) return null;
  if (!decoded.has(m[1])) decoded.set(m[1], toBytes(SOURCES[m[1]]));
  return new Response(decoded.get(m[1]), {
    headers: {
      "content-type": "font/woff2",
      "cache-control": "public, max-age=31536000, immutable",
      "x-content-type-options": "nosniff",
    },
  });
}
