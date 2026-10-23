// Port of the Ed Discussion pipeline:
//   Ed/EdWire.swift            decoding shape + EdJSON.parseDate
//   Ed/EdThreadFilter.swift    announcements, pinned, staff posts only
//   Ed/EdDocumentText.swift    Ed's XML document to plain text
//   Ed/EdDocumentBuilder.swift the header line + body
//   Ed/EdDocumentHeader.swift  the posting-day token and the header reader
//   Ed/EdIngestion.swift       threads to `ed` documents
//
// Privacy, as in Swift: a document is built for a KEPT thread and nothing
// else, so a student's post, a private thread, or a question never becomes
// one. No author name or id is ever written to a document, and this port goes
// one step further than Swift: the decoder does not even keep a user's
// `name` (Swift decodes it "for completeness" and uses it nowhere).
//
// Ed's XML is read by a strict well-formedness check plus a small event walk
// instead of XMLParser (no DOM in a service worker). Anything XMLParser would
// reject (a bare `&`, `&nbsp;`, a mismatched tag, no root element) throws
// here too and falls back to `strippingTags`, exactly as Swift does.
import { trimWhitespaceAndNewlines, trimWhitespaces } from "./text.js";
import { courseDocumentWire } from "./canvasDocuments.js";
import { parseDate as parseISO } from "./canvasApi.js";

export const KIND = "ed";
export const DEFAULT_API_BASE = "https://us.edstem.org/api";
export const MAX_THREADS_LIMIT = 100; // EdClient.maxLimit

// ------------------------------------------------------------------ URLs

// EdClient.user(): GET /user
export function userURL({ apiBase = DEFAULT_API_BASE } = {}) {
  return `${apiBase.replace(/\/+$/, "")}/user`;
}

// EdClient.threads: GET /courses/<id>/threads?limit&offset&sort. `limit` is
// clamped to Ed's cap of 100; the phone reads exactly one page of sort=new.
export function threadsURL(edCourseID, { limit = 100, offset = 0, sort = "new", apiBase = DEFAULT_API_BASE } = {}) {
  const clamped = Math.min(Math.max(limit, 1), MAX_THREADS_LIMIT);
  return (
    `${apiBase.replace(/\/+$/, "")}/courses/${edCourseID}/threads` +
    `?limit=${clamped}&offset=${Math.max(offset, 0)}&sort=${encodeURIComponent(sort)}`
  );
}

// EdIngestion.threadURL: the page in Ed's web app (always the `us` host).
export function threadURL(edCourseID, threadID) {
  return `https://edstem.org/us/courses/${edCourseID}/discussion/${threadID}`;
}

// -------------------------------------------------------------- decoding

export class EdDecodeError extends Error {
  constructor(detail) {
    super(`Ed returned data the app could not read: ${detail}`);
    this.name = "EdDecodeError";
  }
}

// EdJSON.parseDate. Ed's timestamps carry a UTC offset
// ("2026-03-05T14:21:55.123456+11:00"), often with microseconds. Normalizes,
// then parses: fraction cut to milliseconds, colon-less offsets accepted,
// a space allowed for the `T`, no zone means UTC. Returns a Date or null.
export function parseEdDate(raw) {
  let text = raw.replace(/^[ \t]+|[ \t]+$/g, "");
  if (text === "") return null;

  const space = text.indexOf(" ");
  if (space >= 0 && text.includes(":")) text = text.slice(0, space) + "T" + text.slice(space + 1);

  let zone;
  if (text.endsWith("Z") || text.endsWith("z")) {
    zone = "Z";
    text = text.slice(0, -1);
  } else {
    const signIndex = Math.max(text.lastIndexOf("+"), text.lastIndexOf("-"));
    if (signIndex > 10) {
      const sign = text[signIndex];
      const digits = text.slice(signIndex + 1).replaceAll(":", "");
      text = text.slice(0, signIndex);
      if (!(digits.length === 2 || digits.length === 4) || !/^\p{Nd}+$/u.test(digits)) return null;
      zone = `${sign}${digits.slice(0, 2)}:${digits.length === 4 ? digits.slice(2) : "00"}`;
    } else {
      zone = "Z";
    }
  }

  const dot = text.indexOf(".");
  if (dot >= 0) {
    const digits = text.slice(dot + 1);
    if (digits === "" || !/^\p{Nd}+$/u.test(digits)) return null;
    const fraction = digits.slice(0, 3).padEnd(3, "0");
    text = text.slice(0, dot);
    return parseISO(`${text}.${fraction}${zone}`) ?? parseISO(`${text}${zone}`);
  }
  return parseISO(`${text}${zone}`);
}

function isObject(v) {
  return typeof v === "object" && v !== null && !Array.isArray(v);
}
function reqInt(o, key) {
  if (!Number.isSafeInteger(o[key])) throw new EdDecodeError(`${key} is not an integer`);
  return o[key];
}
function reqString(o, key) {
  if (typeof o[key] !== "string") throw new EdDecodeError(`${key} is not a string`);
  return o[key];
}
// decodeIfPresent: absent and null both read as "not there"; a wrong type throws.
function optOf(o, key, check, label) {
  const v = o[key];
  if (v === undefined || v === null) return null;
  if (!check(v)) throw new EdDecodeError(`${key} is not ${label}`);
  return v;
}
const optString = (o, key) => optOf(o, key, (v) => typeof v === "string", "a string");
const optInt = (o, key) => optOf(o, key, Number.isSafeInteger, "an integer");
const optBool = (o, key) => optOf(o, key, (v) => typeof v === "boolean", "a boolean");
function reqDate(o, key) {
  const raw = reqString(o, key);
  const d = parseEdDate(raw);
  if (d === null) throw new EdDecodeError(`Unrecognized Ed timestamp: ${raw}`);
  return d;
}
function optDate(o, key) {
  const raw = optString(o, key);
  if (raw === null) return null;
  const d = parseEdDate(raw);
  if (d === null) throw new EdDecodeError(`Unrecognized Ed timestamp: ${raw}`);
  return d;
}

// EdThread. Every optional is decodeIfPresent. `user_id` missing is 0 (never in
// the users array: an unknown author, treated as a student). `is_private`
// missing is TRUE: the filter's first check, so a thread that arrives without
// the flag is dropped, never uploaded on the strength of being pinned.
export function decodeThread(raw) {
  if (!isObject(raw)) throw new EdDecodeError("thread is not an object");
  return {
    id: reqInt(raw, "id"),
    userID: optInt(raw, "user_id") ?? 0,
    courseID: reqInt(raw, "course_id"),
    type: reqString(raw, "type"),
    title: reqString(raw, "title"),
    document: optString(raw, "document"),
    content: optString(raw, "content"),
    category: optString(raw, "category"),
    subcategory: optString(raw, "subcategory"),
    isPinned: optBool(raw, "is_pinned") ?? false,
    isPrivate: optBool(raw, "is_private") ?? true,
    isEndorsed: optBool(raw, "is_endorsed") ?? false,
    isAnonymous: optBool(raw, "is_anonymous") ?? false,
    createdAt: reqDate(raw, "created_at"),
    updatedAt: optDate(raw, "updated_at"),
    number: optInt(raw, "number"),
    replyCount: optInt(raw, "reply_count"),
  };
}

// EdThreadUser, minus `name`: only the id and the course role survive.
function decodeUser(raw) {
  if (!isObject(raw)) throw new EdDecodeError("user is not an object");
  return { id: reqInt(raw, "id"), courseRole: optString(raw, "course_role") };
}

// EdThreadsResponse. `users` absent reads as empty (every author unknown).
export function decodeThreadsResponse(json) {
  if (!isObject(json) || !Array.isArray(json.threads)) throw new EdDecodeError("threads is not an array");
  const users = json.users === undefined || json.users === null ? [] : json.users;
  if (!Array.isArray(users)) throw new EdDecodeError("users is not an array");
  return { threads: json.threads.map(decodeThread), users: users.map(decodeUser) };
}

// EdUserResponse: GET /user. `role` is optional (archived enrolments).
export function decodeUserResponse(json) {
  if (!isObject(json) || !Array.isArray(json.courses)) throw new EdDecodeError("courses is not an array");
  return {
    courses: json.courses.map((e) => {
      if (!isObject(e) || !isObject(e.course)) throw new EdDecodeError("enrolment has no course");
      const c = e.course;
      let role = null;
      if (e.role !== undefined && e.role !== null) {
        if (!isObject(e.role)) throw new EdDecodeError("role is not an object");
        role = { role: reqString(e.role, "role") };
      }
      return {
        course: {
          id: reqInt(c, "id"),
          code: reqString(c, "code"),
          name: reqString(c, "name"),
          year: optString(c, "year"),
          session: optString(c, "session"),
          status: optString(c, "status"),
        },
        role,
      };
    }),
  };
}

// ---------------------------------------------------------------- filter

export const STAFF_ROLES = new Set(["admin", "staff", "instructor", "ta", "tutor", "mentor"]);

// EdThreadFilter.decide. Unknown is dropped: a missing author, a missing role,
// a type Ed adds next year.
export function decide(thread, authorRole) {
  // Private beats everything, announcements included.
  if (thread.isPrivate) return { keep: false, reason: "private" };
  const type = thread.type.toLowerCase();
  if (type === "announcement") return { keep: true, reason: "announcement" };
  if (thread.isPinned) return { keep: true, reason: "pinned" };
  if (authorRole !== null && authorRole !== undefined && STAFF_ROLES.has(authorRole.toLowerCase()) && type !== "question") {
    return { keep: true, reason: "staff post" };
  }
  return { keep: false, reason: "student or question" };
}

// EdThreadFilter.keptThreads: roles come from the response's own `users`.
export function keptThreads(response) {
  const roles = new Map();
  for (const user of response.users) {
    if (user.courseRole !== null && user.courseRole !== undefined) roles.set(user.id, user.courseRole);
  }
  const kept = [];
  for (const thread of response.threads) {
    const decision = decide(thread, roles.get(thread.userID));
    if (decision.keep) kept.push({ thread, decision });
  }
  return kept;
}

// ----------------------------------------------------------- XML to text

const BLOCK_TAGS = new Set([
  "paragraph", "heading", "list-item", "callout", "pre", "snippet", "break", "figure",
  "p", "br", "li", "div", "tr", "h1", "h2", "h3", "h4", "h5", "h6", "blockquote",
]);

// EdDocumentText.normalize
export function normalize(text) {
  let s = text.replaceAll("\r\n", "\n").replaceAll("\r", "\n").replaceAll(" ", " ");
  s = s
    .split("\n")
    .map((line) => line.replace(/[ \t]+$/, ""))
    .join("\n");
  s = s.replace(/\n{3,}/g, "\n\n");
  return trimWhitespaceAndNewlines(s);
}

// EdDocumentText.decodeEntities (the fallback path only)
function decodeFallbackEntities(text) {
  if (!text.includes("&")) return text;
  let s = text;
  for (const [entity, value] of [
    ["&nbsp;", " "], ["&lt;", "<"], ["&gt;", ">"], ["&quot;", '"'], ["&apos;", "'"], ["&#39;", "'"],
  ]) {
    s = s.replaceAll(entity, value);
  }
  s = s.replace(/&#(x[0-9A-Fa-f]+|[0-9]+);/g, (whole, body) => {
    const v = body.startsWith("x") ? parseInt(body.slice(1), 16) : parseInt(body, 10);
    if (!Number.isFinite(v) || v > 0x10ffff || (v >= 0xd800 && v <= 0xdfff)) return whole;
    return String.fromCodePoint(v);
  });
  return s.replaceAll("&amp;", "&");
}

// EdDocumentText.strippingTags: tags removed, block tags to line breaks, the
// common entities decoded. A "<" only opens a tag when a letter, "/" or "!"
// follows and a ">" exists later: "a < b" is prose.
export function strippingTags(markup) {
  const chars = Array.from(markup);
  let out = "";
  let i = 0;
  while (i < chars.length) {
    const ch = chars[i];
    if (ch === "<" && i + 1 < chars.length && (/^\p{L}$/u.test(chars[i + 1]) || chars[i + 1] === "/" || chars[i + 1] === "!")) {
      let close = -1;
      for (let j = i + 1; j < chars.length; j++) {
        if (chars[j] === ">") {
          close = j;
          break;
        }
      }
      if (close >= 0) {
        const inner = chars.slice(i + 1, close).join("").replace(/^[/ ]+|[/ ]+$/g, "");
        const name = (inner.match(/^[^\p{White_Space}/]*/u)?.[0] ?? "").toLowerCase();
        if (BLOCK_TAGS.has(name)) out += "\n";
        i = close + 1;
        continue;
      }
    }
    out += ch;
    i += 1;
  }
  return normalize(decodeFallbackEntities(out));
}

class XMLError extends Error {}

const NAME_START = String.raw`[A-Za-z_:À-￿]`;
const NAME = `${NAME_START}[A-Za-z0-9_:.\\-\\u00B7\\u00C0-\\uFFFF]*`;
const NAME_RE = new RegExp(`^${NAME}`);
const ATTR_RE = new RegExp(`^(${NAME})[ \\t\\r\\n]*=[ \\t\\r\\n]*(?:"([^"]*)"|'([^']*)')`);
const XML_WS = /^[ \t\r\n]*/;

function validXMLChar(cp) {
  return cp === 0x9 || cp === 0xa || cp === 0xd || (cp >= 0x20 && cp <= 0xd7ff) || (cp >= 0xe000 && cp <= 0xfffd) || (cp >= 0x10000 && cp <= 0x10ffff);
}

// The five predefined entities and well-formed character references only;
// anything else (`&nbsp;`, a bare `&`) is a parse error, as in libxml2.
function decodeXMLEntities(s) {
  let out = "";
  let i = 0;
  while (i < s.length) {
    const amp = s.indexOf("&", i);
    if (amp < 0) return out + s.slice(i);
    out += s.slice(i, amp);
    const semi = s.indexOf(";", amp);
    if (semi < 0) throw new XMLError("bare &");
    const body = s.slice(amp + 1, semi);
    if (body === "lt") out += "<";
    else if (body === "gt") out += ">";
    else if (body === "amp") out += "&";
    else if (body === "quot") out += '"';
    else if (body === "apos") out += "'";
    else if (/^#x[0-9a-fA-F]+$/.test(body) || /^#[0-9]+$/.test(body)) {
      const cp = body[1] === "x" ? parseInt(body.slice(2), 16) : parseInt(body.slice(1), 10);
      if (!validXMLChar(cp)) throw new XMLError("bad character reference");
      out += String.fromCodePoint(cp);
    } else {
      throw new XMLError(`undefined entity ${body}`);
    }
    i = semi + 1;
  }
  return out;
}

// Tokenizes a whole document into start/end/text/cdata events, or throws.
function tokenizeXML(xml) {
  const events = [];
  const stack = [];
  let sawRoot = false;
  let pos = 0;
  while (pos < xml.length) {
    if (xml.startsWith("<!--", pos)) {
      const end = xml.indexOf("-->", pos + 4);
      if (end < 0) throw new XMLError("unterminated comment");
      pos = end + 3;
    } else if (xml.startsWith("<![CDATA[", pos)) {
      if (stack.length === 0) throw new XMLError("CDATA outside root");
      const end = xml.indexOf("]]>", pos + 9);
      if (end < 0) throw new XMLError("unterminated CDATA");
      events.push({ type: "cdata", text: xml.slice(pos + 9, end) });
      pos = end + 3;
    } else if (xml.startsWith("<?", pos)) {
      const end = xml.indexOf("?>", pos + 2);
      if (end < 0) throw new XMLError("unterminated PI");
      pos = end + 2;
    } else if (xml.startsWith("<!", pos)) {
      if (stack.length > 0) throw new XMLError("declaration inside root");
      const end = xml.indexOf(">", pos);
      if (end < 0) throw new XMLError("unterminated declaration");
      pos = end + 1;
    } else if (xml.startsWith("</", pos)) {
      const m = NAME_RE.exec(xml.slice(pos + 2));
      if (!m) throw new XMLError("bad end tag");
      let p = pos + 2 + m[0].length;
      p += XML_WS.exec(xml.slice(p))[0].length;
      if (xml[p] !== ">") throw new XMLError("bad end tag");
      if (stack.pop() !== m[0]) throw new XMLError("mismatched end tag");
      events.push({ type: "end", name: m[0] });
      pos = p + 1;
    } else if (xml[pos] === "<") {
      const m = NAME_RE.exec(xml.slice(pos + 1));
      if (!m) throw new XMLError("bad start tag");
      if (stack.length === 0 && sawRoot) throw new XMLError("second root");
      sawRoot = true;
      let p = pos + 1 + m[0].length;
      const attrs = {};
      for (;;) {
        const ws = XML_WS.exec(xml.slice(p))[0].length;
        p += ws;
        if (xml[p] === ">" || xml.startsWith("/>", p)) break;
        if (ws === 0) throw new XMLError("attribute needs whitespace");
        const a = ATTR_RE.exec(xml.slice(p));
        if (!a) throw new XMLError("bad attribute");
        const value = a[2] !== undefined ? a[2] : a[3];
        if (value.includes("<")) throw new XMLError("< in attribute");
        if (Object.hasOwn(attrs, a[1])) throw new XMLError("duplicate attribute");
        attrs[a[1]] = decodeXMLEntities(value.replace(/\r\n?/g, "\n").replace(/[\t\n]/g, " "));
        p += a[0].length;
      }
      events.push({ type: "start", name: m[0], attrs });
      if (xml[p] === ">") {
        stack.push(m[0]);
        pos = p + 1;
      } else {
        events.push({ type: "end", name: m[0] });
        pos = p + 2;
      }
    } else {
      let end = xml.indexOf("<", pos);
      if (end < 0) end = xml.length;
      const raw = xml.slice(pos, end);
      if (stack.length === 0) {
        if (!/^[ \t\r\n]*$/.test(raw)) throw new XMLError("text outside root");
      } else {
        if (/[\u0000-\u0008\u000B\u000C\u000E-\u001F]/.test(raw)) throw new XMLError("control character");
        events.push({ type: "text", text: decodeXMLEntities(raw.replace(/\r\n?/g, "\n")) });
      }
      pos = end;
    }
  }
  if (stack.length > 0) throw new XMLError("unclosed element");
  if (!sawRoot) throw new XMLError("no root element");
  return events;
}

const IS_WHITESPACE = /^[\p{White_Space}]*$/u;

// EdDocumentText.Converter. The model is "lines": `lineOpen` says whether
// text has been written on the current output line; a line's prefix (quote
// marks, list marker, heading hashes) is written lazily by the first text on
// it, so an empty paragraph or list item emits nothing, not a lone "- ".
function convert(events) {
  let output = "";
  let lineOpen = false;
  let quoteDepth = 0;
  const lists = [];
  let pendingMarker = null;
  let pendingHeading = null;
  let blockDepth = 0;
  let inCode = false;
  const captures = [];
  const linkHrefs = [];

  const write = (text) => {
    if (captures.length === 0) output += text;
    else captures[captures.length - 1] += text;
  };
  const linePrefix = () => {
    let prefix = "> ".repeat(quoteDepth);
    if (lists.length > 0) {
      prefix += "  ".repeat(lists.length - 1);
      prefix += pendingMarker ?? "  ";
      pendingMarker = null;
    }
    if (pendingHeading !== null) {
      prefix += pendingHeading;
      pendingHeading = null;
    }
    return prefix;
  };
  const beginLineIfNeeded = () => {
    if (lineOpen) return;
    output += linePrefix();
    lineOpen = true;
  };
  const endLine = () => {
    if (!lineOpen || captures.length > 0) return;
    output += "\n";
    lineOpen = false;
  };
  const appendText = (string) => {
    if (inCode) {
      output += string;
      return;
    }
    // Whitespace between tags (pretty-printed XML) is layout, not content.
    if (!lineOpen && captures.length === 0 && IS_WHITESPACE.test(string)) return;
    beginLineIfNeeded();
    write(string);
  };

  for (const ev of events) {
    if (ev.type === "text" || ev.type === "cdata") {
      appendText(ev.text);
    } else if (ev.type === "start") {
      const a = ev.attrs;
      switch (ev.name) {
        case "paragraph":
          endLine();
          blockDepth += 1;
          break;
        case "heading": {
          endLine();
          blockDepth += 1;
          const parsed = /^[+-]?[0-9]+$/.test(a.level ?? "") ? Number(a.level) : 1;
          pendingHeading = "#".repeat(Math.min(Math.max(parsed, 1), 6)) + " ";
          break;
        }
        case "list": {
          endLine();
          const style = (a.style ?? "bullet").toLowerCase();
          lists.push({ ordered: style === "number" || style === "ordered", counter: 0 });
          break;
        }
        case "list-item":
          endLine();
          if (lists.length > 0) {
            const top = lists[lists.length - 1];
            top.counter += 1;
            pendingMarker = top.ordered ? `${top.counter}. ` : "- ";
          }
          break;
        case "callout":
          endLine();
          quoteDepth += 1;
          break;
        case "pre":
        case "snippet":
          endLine();
          output += "> ".repeat(quoteDepth) + "```" + (a.language ?? a.lang ?? "") + "\n";
          inCode = true;
          break;
        case "link":
          beginLineIfNeeded();
          captures.push("");
          linkHrefs.push(a.href ?? "");
          break;
        case "break":
          // A line break inside a paragraph: the next text on the new line
          // still needs the quote/list prefix, hence lineOpen off.
          write("\n");
          if (captures.length === 0) lineOpen = false;
          break;
        case "image":
          beginLineIfNeeded();
          write("[image]");
          if (blockDepth === 0) endLine();
          break;
        default:
          // document, bold, italic, underline, code, math, spoiler, figure and
          // anything Ed adds later are transparent: text kept, tags dropped.
          break;
      }
    } else if (ev.type === "end") {
      switch (ev.name) {
        case "paragraph":
        case "heading":
          endLine();
          blockDepth = Math.max(blockDepth - 1, 0);
          pendingHeading = null;
          break;
        case "list":
          endLine();
          if (lists.length > 0) lists.pop();
          pendingMarker = null;
          break;
        case "list-item":
          endLine();
          pendingMarker = null;
          break;
        case "callout":
          endLine();
          quoteDepth = Math.max(quoteDepth - 1, 0);
          break;
        case "pre":
        case "snippet":
          if (!output.endsWith("\n")) output += "\n";
          output += "> ".repeat(quoteDepth) + "```\n";
          inCode = false;
          lineOpen = false;
          break;
        case "link": {
          if (captures.length === 0) break;
          const label = captures.pop();
          const href = linkHrefs.pop();
          const text = trimWhitespaceAndNewlines(label);
          if (href === "" || text === "") write(href === "" ? text : href);
          else if (text === href) write(href);
          else write(`${text} (${href})`);
          break;
        }
        default:
          break;
      }
    }
  }
  return output;
}

// EdDocumentText.plainText(fromDocument:). A parse failure never yields an
// empty string for a post that had text: the fallback is `strippingTags`.
export function plainTextFromDocument(xml) {
  const trimmed = trimWhitespaceAndNewlines(xml);
  if (trimmed === "") return "";
  try {
    const text = normalize(convert(tokenizeXML(trimmed)));
    if (text !== "") return text;
  } catch (e) {
    if (!(e instanceof XMLError)) throw e;
  }
  return strippingTags(trimmed);
}

// ---------------------------------------------------------------- header

export const POSTED_MARKER = "· posted ";
const OPENING = "[ed · ";

const dayFormatter = new Intl.DateTimeFormat("en-US", {
  timeZone: "America/New_York",
  year: "numeric",
  month: "numeric",
  day: "numeric",
  hourCycle: "h23",
  hour: "numeric",
  minute: "numeric",
  second: "numeric",
});

function easternParts(date) {
  const parts = {};
  for (const p of dayFormatter.formatToParts(date)) parts[p.type] = Number(p.value);
  parts.hour = parts.hour % 24;
  return parts;
}

// EdDocumentHeader.postedDayString: the US Eastern calendar day, `2026-10-12`,
// hand-padded digits (no locale can change a byte of it).
export function postedDayString(date) {
  const p = easternParts(date);
  const pad = (v, w) => String(Math.max(v ?? 0, 0)).padStart(w, "0");
  return `${pad(p.year, 4)}-${pad(p.month, 2)}-${pad(p.day, 2)}`;
}

// EdDocumentHeader.postedDay(from:): noon US Eastern of the day, or null for
// anything but a real `yyyy-MM-dd` (so `2026-02-31` is null, not March 3).
export function postedDay(string) {
  if (!/^[0-9]{4}-[0-9]{2}-[0-9]{2}$/.test(string)) return null;
  const year = Number(string.slice(0, 4));
  const month = Number(string.slice(5, 7));
  const day = Number(string.slice(8, 10));
  const guess = new Date(0);
  guess.setUTCFullYear(year, month - 1, day);
  guess.setUTCHours(12, 0, 0, 0);
  const wall = easternParts(guess);
  const wallAsUTC = new Date(0);
  wallAsUTC.setUTCFullYear(wall.year, wall.month - 1, wall.day);
  wallAsUTC.setUTCHours(wall.hour, wall.minute, wall.second, 0);
  const result = new Date(guess.getTime() - (wallAsUTC.getTime() - guess.getTime()));
  const back = easternParts(result);
  if (back.year !== year || back.month !== month || back.day !== day || back.hour !== 12) return null;
  return result;
}

// EdDocumentHeader.parse: reads back the first line the builder writes,
// `[ed · pinned] Homework / Hw 3 · posted 2026-10-12`. Text with no header is
// not an error: reason is null and body is the whole text.
export function parseHeader(text) {
  const none = { reason: null, category: null, body: text, postedAt: null };
  const nl = text.indexOf("\n");
  const lineEnd = nl < 0 ? text.length : nl;
  const firstLine = text.slice(0, lineEnd);
  if (!firstLine.startsWith(OPENING)) return none;
  const closed = firstLine.indexOf("]", OPENING.length);
  if (closed < 0) return none;
  const reason = trimWhitespaces(firstLine.slice(OPENING.length, closed));
  if (reason === "") return none;
  let category = trimWhitespaces(firstLine.slice(closed + 1));
  let postedAt = null;
  const marker = category.lastIndexOf(POSTED_MARKER);
  if (marker >= 0 && (marker === 0 || category[marker - 1] === " ")) {
    const day = postedDay(category.slice(marker + POSTED_MARKER.length));
    if (day !== null) {
      postedAt = day;
      category = trimWhitespaces(category.slice(0, marker));
    }
  }
  const body = lineEnd === text.length ? "" : text.slice(lineEnd + 1);
  return { reason, category: category === "" ? null : category, body, postedAt };
}

// EdDocumentHeader.carriesNoText: nothing but the header and `[image]`
// placeholders (no letter or digit left).
export function carriesNoText(text) {
  const remaining = parseHeader(text).body.replaceAll("[image]", "");
  return !/[\p{L}\p{N}]/u.test(remaining);
}

// --------------------------------------------------------------- builder

export const sourceID = (thread) => String(thread.id);

// EdDocumentBuilder.title: trimmed, with a stand-in so a document is never
// untitled.
export function title(thread) {
  const trimmed = trimWhitespaceAndNewlines(thread.title);
  if (trimmed !== "") return trimmed;
  return `Ed thread #${thread.number ?? thread.id}`;
}

const nonEmpty = (value) => {
  if (value === null || value === undefined) return null;
  const t = trimWhitespaceAndNewlines(value);
  return t === "" ? null : t;
};

// EdDocumentBuilder.text: a one-line header, then the plain-text body. The
// header never names the author; its last token is the day the thread was
// CREATED (Eastern), omitted for the epoch default.
export function text(thread, decision) {
  let header = `[ed · ${decision.reason}]`;
  const category = nonEmpty(thread.category);
  if (category !== null) {
    header += " " + category;
    const sub = nonEmpty(thread.subcategory);
    if (sub !== null) header += " / " + sub;
  }
  if (thread.createdAt.getTime() > 0) header += " " + POSTED_MARKER + postedDayString(thread.createdAt);

  let body = "";
  if (thread.document !== null && thread.document !== undefined) body = plainTextFromDocument(thread.document);
  if (body === "" && thread.content !== null && thread.content !== undefined) body = strippingTags(thread.content);
  return body === "" ? header : header + "\n" + body;
}

// ------------------------------------------------------------- ingestion

// EdIngestion.defaultMaxAge: about a semester.
export const DEFAULT_MAX_AGE_DAYS = 120;

// EdIngestion.documents: one `ed` wire document per kept, recent thread,
// newest first (ties by source id). Recency is `updatedAt` when Ed sends one,
// else `createdAt`, the same value stored as the document's `updatedAt`.
// `course` is `{ courseID, code }` (the Canvas course the Ed course matched;
// pooling is keyed on the Canvas id).
export function documents({ course, edCourseID, response, now = new Date(), maxAgeDays = DEFAULT_MAX_AGE_DAYS }) {
  const cutoff = new Date(now).getTime() - maxAgeDays * 86_400_000;
  const built = [];
  for (const { thread, decision } of keptThreads(response)) {
    const moved = thread.updatedAt ?? thread.createdAt;
    if (moved.getTime() < cutoff) continue;
    built.push(
      courseDocumentWire({
        courseID: course.courseID,
        course: course.code,
        kind: KIND,
        sourceID: sourceID(thread),
        title: title(thread),
        url: threadURL(edCourseID, thread.id),
        text: text(thread, decision),
        updatedAt: moved,
        fetchedAt: now,
      }),
    );
  }
  return built.sort((l, r) => {
    const lt = new Date(l.updatedAt).getTime();
    const rt = new Date(r.updatedAt).getTime();
    if (lt !== rt) return rt - lt;
    return l.sourceID < r.sourceID ? -1 : l.sourceID > r.sourceID ? 1 : 0;
  });
}
