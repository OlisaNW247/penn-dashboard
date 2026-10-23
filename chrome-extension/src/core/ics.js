// Port of Canvas/ICSParser.swift and the pure parts of Canvas/CanvasICSClient.swift
// (SUMMARY split, kind classification, normalizing events to assignments).
// Fetching is not here; the adapter layer owns that.
//
// The parser is deliberately a small subset of RFC 5545 and keeps every
// quirk Swift has: nested components are not skipped (a VALARM's SUMMARY would
// overwrite the event's), a quoted TZID is not unquoted and so falls through to
// floating local time, blank lines are dropped before unfolding, and a later
// duplicate field replaces an earlier one.
import { makeAssignment, Source, Kind } from "./assignment.js";
import { parse as parseCourseCode } from "./courseCode.js";
import { trimWhitespaceAndNewlines, trimWhitespaces } from "./text.js";

// ICSParser.swift:42-53. Blank lines vanish first (split's default omits empty
// subsequences), so a fold across a blank line differs from strict RFC 5545.
function unfold(text) {
  const result = [];
  for (const line of text.split(/\r\n|\n|\r/)) {
    if (line === "") continue;
    const first = line[0];
    if ((first === " " || first === "\t") && result.length > 0) {
      result[result.length - 1] += line.slice(1);
    } else {
      result.push(line);
    }
  }
  return result;
}

// ICSParser.swift:83-104. A trailing lone backslash stays as it is.
function unescape(s) {
  let out = "";
  for (let i = 0; i < s.length; i++) {
    const c = s[i];
    if (c === "\\" && i + 1 < s.length) {
      const next = s[i + 1];
      out += next === "n" || next === "N" ? "\n" : next;
      i++;
    } else {
      out += c;
    }
  }
  return out;
}

// ICSParser.swift:62-80. Splits at the FIRST colon, so colons inside values
// (URLs, times) are safe. Parameters without `=` are ignored.
function parseFieldLine(line) {
  const colon = line.indexOf(":");
  if (colon < 0) return null;
  const parts = line.slice(0, colon).split(";");
  const name = parts[0].toUpperCase();
  const params = {};
  for (const p of parts.slice(1)) {
    const eq = p.indexOf("=");
    if (eq >= 0) params[p.slice(0, eq).toUpperCase()] = p.slice(eq + 1);
  }
  return { name, params, value: unescape(line.slice(colon + 1)) };
}

const daysInMonth = (y, m) => new Date(Date.UTC(y, m, 0)).getUTCDate();

// Swift's DateFormatter is non-lenient and needs the whole string to match, so
// a calendar-invalid or trailing-garbage value is nil, not a rolled-over date.
function validFields(f) {
  return f.month >= 1 && f.month <= 12 && f.day >= 1 && f.day <= daysInMonth(f.year, f.month)
    && f.hour <= 23 && f.minute <= 59 && f.second <= 59;
}

function localDate(f) {
  const d = new Date(0);
  d.setFullYear(f.year, f.month - 1, f.day);
  d.setHours(f.hour, f.minute, f.second, 0);
  return d;
}

function zoneOffsetMs(utcMs, timeZone) {
  const parts = new Intl.DateTimeFormat("en-US", {
    timeZone, hourCycle: "h23", year: "numeric", month: "numeric", day: "numeric",
    hour: "numeric", minute: "numeric", second: "numeric",
  }).formatToParts(new Date(utcMs));
  const g = (t) => Number(parts.find((p) => p.type === t).value);
  const asUTC = Date.UTC(g("year"), g("month") - 1, g("day"), g("hour"), g("minute"), g("second"));
  return asUTC - Math.floor(utcMs / 1000) * 1000;
}

function zonedDate(f, timeZone) {
  const guess = Date.UTC(f.year, f.month - 1, f.day, f.hour, f.minute, f.second);
  const first = zoneOffsetMs(guess, timeZone);
  let t = guess - first;
  const second = zoneOffsetMs(t, timeZone);
  if (second !== first) t = guess - second;
  return new Date(t);
}

function timeZoneOrNull(id) {
  try {
    new Intl.DateTimeFormat("en-US", { timeZone: id });
    return id;
  } catch {
    return null;
  }
}

// ICSParser.swift:124-159. Local times use the runtime's zone, as Swift uses
// TimeZone.current.
//
// Where this can still differ from Swift: a local time that does not exist
// (inside a spring-forward gap) is shifted forward here, where ICU's strict
// parse most likely returns nil; Intl accepts some zone names Foundation
// rejects and vice versa.
function parseDate(value, params) {
  // Date-only means "due by the end of that day" in the student's own zone,
  // not 23:59:59 UTC, which would fire hours early for an Eastern student.
  if (params.VALUE === "DATE" || ([...value].length === 8 && !value.includes("T"))) {
    const m = /^([0-9]{4})([0-9]{2})([0-9]{2})$/.exec(value);
    if (!m) return null;
    const f = { year: +m[1], month: +m[2], day: +m[3], hour: 23, minute: 59, second: 59 };
    return validFields(f) ? localDate(f) : null;
  }

  const utc = value.endsWith("Z");
  const body = utc ? value.slice(0, -1) : value;
  const m = /^([0-9]{4})([0-9]{2})([0-9]{2})T([0-9]{2})([0-9]{2})([0-9]{2})$/.exec(body);
  if (!m) return null;
  const f = { year: +m[1], month: +m[2], day: +m[3], hour: +m[4], minute: +m[5], second: +m[6] };
  if (!validFields(f)) return null;
  if (utc) return new Date(Date.UTC(f.year, f.month - 1, f.day, f.hour, f.minute, f.second));
  // The TZID value is not unquoted, so TZID="America/New_York" is not a
  // zone name and falls through to floating time (hazard #16).
  const tz = params.TZID !== undefined ? timeZoneOrNull(params.TZID) : null;
  return tz ? zonedDate(f, tz) : localDate(f);
}

// Swift's URL(string:) is far more permissive than `new URL`: it accepts
// relative strings such as "foo", which become null here. Valid absolute URLs
// are kept as the original string, not the normalized href.
function urlOrNull(value) {
  if (value === undefined) return null;
  try {
    new URL(value);
    return value;
  } catch {
    return null;
  }
}

function makeEvent(fields) {
  return {
    // A fresh random id per parse for UID-less events, as in Swift (uuidString
    // is uppercase), so such an event's assignment id is not stable.
    uid: fields.UID?.value ?? crypto.randomUUID().toUpperCase(),
    summary: fields.SUMMARY?.value ?? "(untitled)",
    dtStart: fields.DTSTART ? parseDate(fields.DTSTART.value, fields.DTSTART.params) : null,
    url: urlOrNull(fields.URL?.value),
  };
}

// Returns [{ uid, summary, dtStart: Date|null, url: string|null }].
export function parseICS(text) {
  const events = [];
  let inEvent = false;
  let fields = {};
  for (const line of unfold(text)) {
    if (line === "BEGIN:VEVENT") {
      inEvent = true;
      fields = {};
    } else if (line === "END:VEVENT") {
      if (inEvent) events.push(makeEvent(fields));
      inEvent = false;
    } else if (inEvent) {
      const parsed = parseFieldLine(line);
      if (parsed) fields[parsed.name] = { params: parsed.params, value: parsed.value };
    }
  }
  return events;
}

// ICSParser.swift:15. Bytes that are not valid UTF-8 give an empty feed; there
// is no Latin-1 fallback.
export function parseICSBytes(bytes) {
  let text;
  try {
    text = new TextDecoder("utf-8", { fatal: true, ignoreBOM: true }).decode(bytes);
  } catch {
    return [];
  }
  return parseICS(text);
}

// CanvasICSClient.swift:105-116. The trailing-whitespace trim matters: one
// stray CR after the bracket used to send a whole class to "(unknown course)".
// The last bracket group is the course.
export function splitCourse(summary) {
  const trimmed = trimWhitespaceAndNewlines(summary);
  const open = trimmed.lastIndexOf("[");
  if (open < 0 || !trimmed.endsWith("]")) return { title: trimmed, course: "(unknown course)" };
  return {
    title: trimWhitespaces(trimmed.slice(0, open)),
    course: trimWhitespaces(trimmed.slice(open + 1, -1)),
  };
}

function pathOf(url) {
  let path = new URL(url).pathname;
  try {
    path = decodeURIComponent(path); // Swift's URL.path is percent-decoded
  } catch { /* keep the encoded path */ }
  return path.toLowerCase();
}

function classifyFromURL(url) {
  if (url == null) return null;
  const path = pathOf(url);
  if (path.includes("/assignments/")) return Kind.ASSIGNMENT;
  if (path.includes("/quizzes/")) return Kind.QUIZ;
  if (path.includes("/discussion_topics/") || path.includes("/discussions/")) return Kind.DISCUSSION;
  if (path.includes("/calendar_events/")) return Kind.EVENT;
  return null;
}

// CanvasICSClient.swift:57-76: the URL path first, then the UID.
export function classify(event) {
  const fromURL = classifyFromURL(event.url);
  if (fromURL) return fromURL;
  const uid = event.uid.toLowerCase();
  if (uid.includes("assignment")) return Kind.ASSIGNMENT;
  if (uid.includes("quiz")) return Kind.QUIZ;
  if (uid.includes("discussion")) return Kind.DISCUSSION;
  if (uid.includes("calendar") || uid.includes("event")) return Kind.EVENT;
  return Kind.OTHER;
}

// CanvasICSClient.swift:41-55. The registrar section CourseCode.parse also
// returns is dropped here, as in Swift.
export function normalize(event) {
  const { title, course } = splitCourse(event.summary);
  const parsed = parseCourseCode(course);
  return makeAssignment({
    source: Source.CANVAS,
    sourceID: event.uid,
    kind: classify(event),
    course: parsed.code,
    title,
    dueAt: event.dtStart,
    url: event.url,
    term: parsed.term,
    submitted: false, // the ICS feed does not expose submission status
  });
}

// `input` is the feed as text or as bytes (Uint8Array / ArrayBuffer).
export function calendarItems(input) {
  const events = typeof input === "string" ? parseICS(input) : parseICSBytes(input);
  return events.map(normalize);
}

export function assignmentsFromICS(input) {
  return calendarItems(input).filter((a) => a.kind === Kind.ASSIGNMENT);
}
