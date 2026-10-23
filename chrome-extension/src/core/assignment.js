// Port of Models/Assignment.swift as plain objects. Field names and defaults
// are Swift's. Two representation choices differ from Swift: `url` is an
// absolute URL string (or null), not a URL object, so an assignment survives
// JSON and chrome.storage unchanged; and `term` is the plain object from
// term.js (or null).

// The Swift rawValues (Assignment.swift:7-49).
export const Source = Object.freeze({
  CANVAS: "canvas",
  GRADESCOPE: "gradescope",
  MANUAL: "manual",
  CANVAS_SUGGESTION: "canvasSuggestion",
  CANVAS_MODULES: "canvasModules",
  CANVAS_ANNOUNCEMENT: "canvasAnnouncement",
});

export const Kind = Object.freeze({
  ASSIGNMENT: "assignment",
  QUIZ: "quiz",
  DISCUSSION: "discussion",
  EVENT: "event",
  OTHER: "other",
});

export function makeAssignment({
  source,
  sourceID,
  kind,
  course,
  title,
  dueAt = null,
  url = null,
  term = null,
  submitted = false,
  scoreEarned = null,
  scoreMax = null,
  linkedID = null,
}) {
  return Object.freeze({
    source, sourceID, kind, course, title, dueAt, url, term,
    submitted, scoreEarned, scoreMax, linkedID,
  });
}

export function assignmentID(a) {
  return `${a.source}:${a.sourceID}`;
}

export function isAssignment(a) {
  return a.kind === Kind.ASSIGNMENT;
}

// Swift compares Strings by Unicode scalar values; JavaScript's `<` compares
// UTF-16 units, which disagree only for astral characters against U+E000-FFFF.
// Ids are ASCII in practice, but the tie-break decides row order, so compare
// by code point.
function compareByCodePoint(a, b) {
  const ca = [...a];
  const cb = [...b];
  const n = Math.min(ca.length, cb.length);
  for (let i = 0; i < n; i++) {
    const d = ca[i].codePointAt(0) - cb[i].codePointAt(0);
    if (d !== 0) return d;
  }
  return ca.length - cb.length;
}

// Assignment.swift:61-72: earlier due date first, undated last, and the id as
// a deterministic tie-break (also used when both dates are equal).
export function isOrderedByDueDate(lhs, rhs) {
  const l = lhs.dueAt;
  const r = rhs.dueAt;
  if (l != null && r != null && l.getTime() !== r.getTime()) {
    return l.getTime() < r.getTime();
  }
  if (l == null && r != null) return false;
  if (l != null && r == null) return true;
  return compareByCodePoint(assignmentID(lhs), assignmentID(rhs)) < 0;
}

// The three expressions behind canvasAssignmentID (Assignment.swift:168-209),
// unchanged and in Swift's order. \d is Unicode in ICU, hence \p{Nd}.
const URL_PATH_ASSIGNMENT = /\/assignments\/(\p{Nd}+)/u;
const URL_FRAGMENT_ASSIGNMENT = /#assignment_(\p{Nd}+)/u;
// Unanchored on purpose: it finds "assignment-7" inside "sub_assignment-7", so
// a sub-assignment UID resolves to "7". CanvasAssignmentIDPinTests pins this;
// the id is a join key, so changing it is an identity change (hazard #20).
const UID_ASSIGNMENT = /assignment-(\p{Nd}+)/u;

// Tried in order: URL path, URL `#assignment_` fragment (the only carrier of
// the real id on section-override events), then the UID, and the UID only for
// source `canvas`: a `canvasModules` sourceID holds a module-item id from a
// different id space (Assignment.swift:168-180).
//
// Models/SourceLink.swift:175-179 has a second fragment parser that is
// stricter (exact `assignment_` prefix, all-digits remainder, via the parsed
// URL's fragment). It is not what this function does and is not ported here.
export function canvasAssignmentID(a) {
  if (a.source !== Source.CANVAS && a.source !== Source.CANVAS_MODULES) return null;
  if (a.url != null) {
    const byPath = URL_PATH_ASSIGNMENT.exec(a.url);
    if (byPath) return byPath[1];
    const byFragment = URL_FRAGMENT_ASSIGNMENT.exec(a.url);
    if (byFragment) return byFragment[1];
  }
  if (a.source !== Source.CANVAS) return null;
  const byUID = UID_ASSIGNMENT.exec(a.sourceID);
  return byUID ? byUID[1] : null;
}
