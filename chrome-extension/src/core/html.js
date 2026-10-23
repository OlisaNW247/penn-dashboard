// Port of Knowledge/HTMLText.swift: Canvas HTML to plain text, entity
// decoding, and `<a href>` extraction (the upload's `links`). The Swift is the
// spec; a different string here is a different contentHash, and the phone and
// the extension would re-upload each other's copy forever.
//
// No DOM: a service worker has no DOMParser. Regexes only, as in Swift.
//
// ICU (NSRegularExpression) treats \s and \b as Unicode-aware; JavaScript's are
// not, even with the `u` flag. `\s` is written as [\p{White_Space}] (ICU's
// definition) and every `\b` as a lookahead against ICU's \w, the same
// approach courseCode.js takes. In each pattern below the \b sits right after
// a letter or digit, so "boundary" reduces to "next character is not a word
// character".
import { trimWhitespaceAndNewlines } from "./text.js";

const S = String.raw`[\p{White_Space}]`;
const NOT_WORD = String.raw`(?![\p{Alphabetic}\p{M}\p{Nd}\p{Pc}\p{Join_Control}])`;

// HTMLText.swift:15-17. `[\s\S]*?`, not `.*?`, for the reason Swift's own
// comment gives: a multi-line <style> block must match.
const SCRIPT = new RegExp(`<script${NOT_WORD}[^>]*>[\\s\\S]*?</script>`, "giu");
const STYLE = new RegExp(`<style${NOT_WORD}[^>]*>[\\s\\S]*?</style>`, "giu");
const COMMENT = /<!--[\s\S]*?-->/giu;
// :20-23
const BR = new RegExp(`<br${S}*/?>`, "giu");
const BLOCK_CLOSE = new RegExp(
  `</(p|div|li|h[1-6]|tr|blockquote|section|article|header|footer|table|ul|ol|pre)${S}*>`,
  "giu",
);
const LI_OPEN = new RegExp(`<(li)${NOT_WORD}[^>]*>`, "giu");
const CELL_OPEN = new RegExp(`<(td|th)${NOT_WORD}[^>]*>`, "giu");
const ANY_TAG = /<[^>]+>/giu;
// :31-34
const SPACE_RUNS = /[ \t\r ]+/giu;
const SPACES_AROUND_NEWLINE = / *\n */giu;
const NEWLINE_RUNS = /\n{2,}/giu;

export function plainText(html) {
  let s = html;
  s = s.replace(SCRIPT, " ");
  s = s.replace(STYLE, " ");
  s = s.replace(COMMENT, " ");
  s = s.replace(BR, "\n");
  s = s.replace(BLOCK_CLOSE, "\n");
  s = s.replace(LI_OPEN, "\n• ");
  s = s.replace(CELL_OPEN, " ");
  s = s.replace(ANY_TAG, " ");
  s = decodeEntities(s);
  s = s.replace(SPACE_RUNS, " ");
  s = s.replace(SPACES_AROUND_NEWLINE, "\n");
  s = s.replace(NEWLINE_RUNS, "\n");
  return trimWhitespaceAndNewlines(s);
}

// HTMLText.swift:40-44, in the same order, case-sensitive.
const NAMED = [
  ["&nbsp;", " "], ["&lt;", "<"], ["&gt;", ">"], ["&quot;", '"'],
  ["&#39;", "'"], ["&apos;", "'"], ["&ndash;", "–"], ["&mdash;", "—"],
  ["&hellip;", "…"], ["&rsquo;", "’"], ["&lsquo;", "‘"],
  ["&rdquo;", "”"], ["&ldquo;", "“"], ["&bull;", "•"],
];

// Unicode.Scalar(value) is nil for surrogates and anything past U+10FFFF; the
// entity is then left as written, as in Swift.
function scalarFromCodePoint(value) {
  if (!Number.isFinite(value) || value > 0x10ffff || (value >= 0xd800 && value <= 0xdfff)) return null;
  return String.fromCodePoint(value);
}

// `UInt32(string)` is nil on overflow past 2^32-1, which is past U+10FFFF
// anyway, so the range check above covers it.
function replaceNumericEntities(text) {
  return text.replace(/&#(x[0-9a-fA-F]+|[0-9]+);/g, (whole, body) => {
    const value = body.startsWith("x") ? parseInt(body.slice(1), 16) : parseInt(body, 10);
    return scalarFromCodePoint(value) ?? whole;
  });
}

export function decodeEntities(text) {
  let s = text;
  for (const [entity, value] of NAMED) s = s.replaceAll(entity, value);
  s = replaceNumericEntities(s);
  // `&amp;` last so "&amp;lt;" does not double-decode.
  return s.replaceAll("&amp;", "&");
}

// HTMLText.swift:105-106. `.dotMatchesLineSeparators`, case-insensitive.
const ANCHOR = new RegExp(`(<a${NOT_WORD}[^>]*>)([\\s\\S]*?)</a>`, "giu");
// :133. First href in the opening tag. (`data-href=` matches too, as in Swift.)
const HREF = new RegExp(`href${S}*=${S}*"([^"]*)"|href${S}*=${S}*'([^']*)'`, "iu");

function firstHref(openingTag) {
  const m = HREF.exec(openingTag);
  if (!m) return null;
  if (m[1] !== undefined) return m[1];
  if (m[2] !== undefined) return m[2];
  return null;
}

// Every `<a href>...</a>`, href kept exactly as written (relative or
// absolute), link text stripped of tags and entity-decoded. Anchor-only hrefs
// ("#", "#section") and empty ones are skipped.
export function links(html) {
  const out = [];
  for (const match of html.matchAll(ANCHOR)) {
    const href = firstHref(match[1]);
    if (href === null) continue;
    const trimmed = trimWhitespaceAndNewlines(href);
    if (trimmed === "" || trimmed.startsWith("#")) continue;
    const text = trimWhitespaceAndNewlines(plainText(match[2]).replaceAll("\n", " "));
    out.push({ href: trimmed, text });
  }
  return out;
}
