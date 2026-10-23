// Port of Models/AssignmentDeduplicator.swift: collapses an assignment posted
// on both Canvas and Gradescope into one item, and hides the duplicate rows
// Canvas itself produces. Conservative on purpose: a false merge is worse than
// a missed one (Swift lines 3-25).
//
// Representation: assignments are the frozen plain objects of assignment.js;
// a Match is {canvasID, gradescopeID}, a CanvasCollapse is {canvasID,
// moduleID}, an OverrideCollapse is {survivorID, hiddenID}, all frozen.
// Dates are JS Dates; every duration here is in SECONDS, as in Swift.
//
// Determinism audit of the Swift: no step iterates a Dictionary or Set to
// produce output. Dictionaries and Sets are only used for lookup and
// membership (matchPairs 361-375, merge 447-449, collapseCanvasDuplicates
// 552-578, collapseCanvasOverrides 699-706 keeps its own groupOrder array).
// The one place Swift's guarantee is weaker than JS's is `sorted`, see
// matchPairs. Lookup tables below are Maps and Sets, never plain objects,
// because a token such as "constructor" or "__proto__" is a legal title word.

import { makeAssignment, assignmentID, canvasAssignmentID, Source } from "./assignment.js";

// Swift 43: refuse an identical-title match when both dates are known and
// further apart than this.
const SAME_TITLE_MAX_DUE_GAP = 21 * 86_400;

// Swift 54. Public: AppState reuses it for announcement twins.
export const similarTitleDueDateTolerance = 26 * 3600;

// Swift 62.
const SIMILAR_TITLE_THRESHOLD = 0.6;

// Swift's Double.greatestFiniteMagnitude stand-in for "no date".
const GREATEST_FINITE = Number.MAX_VALUE;

// Foundation's Date.distantFuture, 4001-01-01T00:00:00Z.
const DISTANT_FUTURE_MS = Date.UTC(4001, 0, 1);

// ---- small helpers --------------------------------------------------------

// Swift compares Strings; assignment.js documents that ids are compared by
// code point (its own helper is not exported, so this repeats it).
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

function secondsBetween(a, b) {
  return (a.getTime() - b.getTime()) / 1000;
}

function arraysEqual(a, b) {
  if (a.length !== b.length) return false;
  for (let i = 0; i < a.length; i++) if (a[i] !== b[i]) return false;
  return true;
}

function setsEqual(a, b) {
  if (a.size !== b.size) return false;
  for (const x of a) if (!b.has(x)) return false;
  return true;
}

function startsWith(tokens, prefix) {
  if (prefix.length > tokens.length) return false;
  for (let i = 0; i < prefix.length; i++) if (tokens[i] !== prefix[i]) return false;
  return true;
}

// Swift `Int(token)` on a token that is [a-z0-9]+ (normalize guarantees it):
// non-nil only for all-digit tokens that fit in Int64. A longer digit run
// returns nil in Swift, so it is neither a number nor stripped of leading
// zeros by canonicalize (Swift 833). Returned as BigInt so equality is by
// value like Swift's Int.
const INT64_MAX = 9223372036854775807n;
function parseInt64(token) {
  if (!/^[0-9]+$/.test(token)) return null;
  const v = BigInt(token);
  return v <= INT64_MAX ? v : null;
}
function isInt(token) {
  return parseInt64(token) !== null;
}

function makeMatch(canvasID, gradescopeID) {
  return Object.freeze({ canvasID, gradescopeID });
}

// ---- title normalization (Swift 739-848) -----------------------------------

function canonicalize(token) {
  // Swift 833: numeric tokens compare by value, so "03" == "3".
  const n = parseInt64(token);
  if (n !== null) return n.toString();
  switch (token) {
    case "hw": case "homework": case "ps": case "pset": case "psets": return "hw";
    case "midterm": case "midterms": return "midterm";
    case "lab": case "labs": return "lab";
    case "project": case "projects": case "proj": return "project";
    default: return token;
  }
}

// Reduces a title to a token array. Swift 770-787.
//
// Why `\s` and `\b` in JS agree with ICU here even though they differ in
// general: step 1 turns everything outside [a-z0-9\s] into a space, and the
// whitespace collapse in step 3 turns every remaining \s character into one,
// so the character classes JS and ICU disagree on (U+FEFF, U+000B) end up as
// the same single space either way. After step 1 only ASCII letters, digits
// and whitespace remain, so \b is ASCII-only in both engines.
export function normalize(raw) {
  let s = raw.toLowerCase();
  s = s.replace(/[^a-z0-9\s]/g, " ");
  // Phrase-level collapses before word-splitting (Swift 773-775).
  s = s.replace(/\bproblem\s+sets?\b/g, "hw");
  s = s.replace(/\bmid\s+terms?\b/g, "midterm");
  s = s.replace(/\s+/g, " ").replace(/^ +| +$/g, "");
  if (s === "") return [];

  const tokens = [];
  for (const word of s.split(" ")) {
    // splitLetterDigitRuns (Swift 813-829): "hw3" -> "hw", "3".
    for (const run of word.match(/[0-9]+|[a-z]+/g) ?? []) tokens.push(run);
  }
  return tokens.map(canonicalize);
}

function jaccardSimilarity(a, b) {
  const union = new Set([...a, ...b]).size;
  if (union === 0) return 0;
  let inter = 0;
  for (const x of a) if (b.has(x)) inter++;
  return inter / union;
}

// ---- pure heuristic (Swift 64-92) -----------------------------------------

export function isLikelyDuplicate(titleA, dueA, titleB, dueB) {
  const tokensA = normalize(titleA);
  const tokensB = normalize(titleB);
  if (tokensA.length === 0 || tokensB.length === 0) return false;

  if (arraysEqual(tokensA, tokensB)) {
    if (dueA != null && dueB != null && Math.abs(secondsBetween(dueA, dueB)) > SAME_TITLE_MAX_DUE_GAP) {
      return false;
    }
    return true;
  }

  if (dueA == null || dueB == null) return false;
  if (!(Math.abs(secondsBetween(dueA, dueB)) <= similarTitleDueDateTolerance)) return false;

  return jaccardSimilarity(new Set(tokensA), new Set(tokensB)) >= SIMILAR_TITLE_THRESHOLD;
}

// ---- announcement tier (Swift 94-325) -------------------------------------

function announcementCoreTokens(raw) {
  const tokens = normalize(raw);
  const leadIn = new Set(["please", "remember", "reminder", "you", "must", "should", "need", "needs", "to"]);
  while (tokens.length > 0 && leadIn.has(tokens[0])) tokens.shift();

  if (startsWith(tokens, ["turn", "in"]) || startsWith(tokens, ["hand", "in"])) {
    tokens.splice(0, 2);
  } else if (tokens.length > 0 && ["take", "complete", "submit", "upload", "do"].includes(tokens[0])) {
    tokens.shift();
  }

  while (tokens.length > 0 && ["the", "your", "a", "an"].includes(tokens[0])) tokens.shift();
  return tokens;
}

function announcementDatesDoNotContradict(announcementDue, existingDue) {
  if (announcementDue == null || existingDue == null) return true;
  return Math.abs(secondsBetween(announcementDue, existingDue)) <= SAME_TITLE_MAX_DUE_GAP;
}

const ASSESSMENT_KIND_WORDS = new Set([
  "quiz", "quizzes", "test", "tests", "assessment", "assessments",
  "exam", "exams", "midterm", "midterms", "prelim", "prelims",
  "final", "finals",
]);

// Swift 206-215: counts tokens, so "quiz 2 quiz 3" is 2.
function assessmentKindCount(tokens) {
  let count = 0;
  for (const t of tokens) if (ASSESSMENT_KIND_WORDS.has(t)) count++;
  return count;
}

const ASSESSMENT_KINDS = new Map([
  ["quiz", "quiz"], ["quizzes", "quiz"],
  ["test", "test"], ["tests", "test"],
  ["assessment", "assessment"], ["assessments", "assessment"],
  ["exam", "exam"], ["exams", "exam"],
  ["midterm", "midterm"], ["midterms", "midterm"],
  ["prelim", "prelim"], ["prelims", "prelim"],
  ["final", "final"], ["finals", "final"],
]);
const ASSESSMENT_RESERVED_MODIFIERS = ["practice", "retake", "makeup"];

// Swift 217-238. The ordinal is the first integer at or after the FIRST kind
// token, wherever it sits.
function assessmentIdentity(tokens) {
  const kindIndex = tokens.findIndex((t) => ASSESSMENT_KINDS.has(t));
  if (kindIndex < 0) return null;
  let ordinal = null;
  for (let i = kindIndex; i < tokens.length; i++) {
    const n = parseInt64(tokens[i]);
    if (n !== null) { ordinal = n; break; }
  }
  if (ordinal === null) return null;
  const all = new Set(tokens);
  return {
    kind: ASSESSMENT_KINDS.get(tokens[kindIndex]),
    ordinal,
    modifiers: new Set(ASSESSMENT_RESERVED_MODIFIERS.filter((m) => all.has(m))),
  };
}

function assessmentIdentitiesEqual(a, b) {
  return a.kind === b.kind && a.ordinal === b.ordinal && setsEqual(a.modifiers, b.modifiers);
}

// Swift 251-261, including spellings normalize already rewrites.
const WORK_NOUNS = new Map([
  ["hw", "hw"], ["hws", "hw"], ["hmwk", "hw"], ["homework", "hw"], ["homeworks", "hw"],
  ["ps", "hw"], ["pset", "hw"], ["psets", "hw"],
  ["lab", "lab"], ["labs", "lab"],
  ["project", "project"], ["projects", "project"], ["proj", "project"], ["projs", "project"],
  ["milestone", "milestone"], ["milestones", "milestone"],
  ["assignment", "assignment"], ["assignments", "assignment"],
  ["asst", "assignment"], ["assn", "assignment"], ["assign", "assignment"],
  ["essay", "essay"], ["essays", "essay"],
  ["paper", "paper"], ["papers", "paper"],
]);

// Swift 269-278.
const WORK_MODIFIER_WORDS = new Map([
  ["solution", "solution"], ["solutions", "solution"],
  ["grade", "grade"], ["grades", "grade"], ["graded", "grade"],
  ["regrade", "regrade"], ["regrades", "regrade"],
  ["extension", "extension"], ["extensions", "extension"], ["extended", "extension"],
  ["practice", "practice"], ["retake", "retake"], ["makeup", "makeup"],
  ["redo", "redo"],
  ["resubmission", "resubmission"], ["resubmissions", "resubmission"],
  ["resubmit", "resubmission"], ["resubmitted", "resubmission"],
]);

// Swift 281.
const ORDINAL_FILLERS = new Set(["no", "number", "num"]);

// Swift 310-325.
function workModifiers(tokens) {
  const modifiers = new Set();
  tokens.forEach((token, index) => {
    const canonical = WORK_MODIFIER_WORDS.get(token);
    if (canonical !== undefined) {
      modifiers.add(canonical);
    } else if (token === "make" && index + 1 < tokens.length && tokens[index + 1] === "up") {
      modifiers.add("makeup");
    } else if (token === "part" || token === "parts" || token === "pt") {
      // A bare "part" at the end still marks the title (value "").
      const value = index + 1 < tokens.length ? tokens[index + 1] : "";
      modifiers.add(`part:${value}`);
    }
  });
  return modifiers;
}

// Swift 295-308. The ordinal is the integer directly after the noun (past
// "no"/"number"/"num"), not the first integer anywhere after it. A noun with
// no ordinal is skipped, and a SECOND noun-with-ordinal makes the whole title
// ambiguous (null), even when it repeats the first.
function workIdentity(tokens) {
  if (assessmentKindCount(tokens) !== 0) return null;
  let found = null;
  for (let index = 0; index < tokens.length; index++) {
    const noun = WORK_NOUNS.get(tokens[index]);
    if (noun === undefined) continue;
    let next = index + 1;
    while (next < tokens.length && ORDINAL_FILLERS.has(tokens[next])) next++;
    if (next >= tokens.length) continue;
    const ordinal = parseInt64(tokens[next]);
    if (ordinal === null) continue;
    if (found !== null) return null;
    found = { noun, ordinal };
  }
  if (found === null) return null;
  return { noun: found.noun, ordinal: found.ordinal, modifiers: workModifiers(tokens) };
}

const TAIL_WORK_WORDS = ["quiz", "exam", "midterm", "test", "hw", "lab", "project", "assignment"];

export function isLikelyAnnouncementDuplicate(announcementTitle, announcementDue, existingTitle, existingDue) {
  const announcementTokens = announcementCoreTokens(announcementTitle);
  const existingTokens = normalize(existingTitle);
  if (announcementTokens.length === 0 || existingTokens.length === 0) return false;

  // A. identical core tokens (Swift 115-117).
  if (arraysEqual(announcementTokens, existingTokens)) {
    return announcementDatesDoNotContradict(announcementDue, existingDue);
  }

  // B. same assessment kind and ordinal (Swift 127-132). Only the
  // announcement side is required to name exactly one assessment kind.
  const announcementIdentity = assessmentIdentity(announcementTokens);
  const existingIdentity = assessmentIdentity(existingTokens);
  if (announcementIdentity !== null && existingIdentity !== null
      && assessmentKindCount(announcementTokens) === 1
      && assessmentIdentitiesEqual(announcementIdentity, existingIdentity)) {
    return announcementDatesDoNotContradict(announcementDue, existingDue);
  }

  // C. same work noun (Swift 148-158). Once both sides have a work identity
  // with the same noun this tier decides alone, and every path returns.
  const announcementWork = workIdentity(announcementTokens);
  const existingWork = workIdentity(existingTokens);
  if (announcementWork !== null && existingWork !== null && announcementWork.noun === existingWork.noun) {
    if (announcementWork.ordinal !== existingWork.ordinal) return false;
    if (!setsEqual(announcementWork.modifiers, existingWork.modifiers)) return false;
    return announcementDatesDoNotContradict(announcementDue, existingDue);
  }

  // D. numbered structured title as a prefix (Swift 169-180).
  const trailingTokens = announcementTokens.slice(existingTokens.length);
  const tailStartsWithStructuredTitle = startsWith(announcementTokens, existingTokens);
  const structuredTitleIsNumbered = existingTokens.some(isInt);
  const tailIntroducesAnotherWorkItem = trailingTokens.some(
    (token) => isInt(token) || TAIL_WORK_WORDS.includes(token),
  );
  if (tailStartsWithStructuredTitle
      && structuredTitleIsNumbered
      && trailingTokens.length > 0
      && !tailIntroducesAnotherWorkItem) {
    return announcementDatesDoNotContradict(announcementDue, existingDue);
  }

  // E. ordinary heuristic on the RAW titles: the lead-in stripping above is
  // deliberately not applied here (Swift 182-187).
  return isLikelyDuplicate(announcementTitle, announcementDue, existingTitle, existingDue);
}

// ---- course-scoped 1:1 pairing (Swift 327-425) -----------------------------

function matchScore(canvas, gradescope) {
  const tokensA = normalize(canvas.title);
  const tokensB = normalize(gradescope.title);
  if (arraysEqual(tokensA, tokensB)) return 2.0; // exact-title tier always outranks fuzzy
  return jaccardSimilarity(new Set(tokensA), new Set(tokensB));
}

function dueDateGap(a, b) {
  if (a == null || b == null) return GREATEST_FINITE;
  return Math.abs(secondsBetween(a, b));
}

// confirmedPairings are honored first, and only while both sides are still
// present and unclaimed (Swift 358-375). Candidates are generated canvas-major,
// gradescope-minor, then sorted by score desc, due gap asc, canvas id asc
// (Swift 396-402).
//
// Tie order: the comparator does not distinguish two candidates that share a
// canvas id, score and gap (the same canvas item against two gradescope items
// equally good). Swift's `sorted` is documented as not guaranteed stable,
// though the stdlib's implementation is; JS's Array.prototype.sort is
// guaranteed stable. Both therefore keep generation order, i.e. gradescope
// input order. Chosen: stable, matching what Swift does in practice.
export function matchPairs(canvasItems, gradescopeItems, confirmedPairings = []) {
  if (canvasItems.length === 0 || gradescopeItems.length === 0) return [];

  const canvasIDs = new Set(canvasItems.map(assignmentID));
  const gradescopeIDs = new Set(gradescopeItems.map(assignmentID));
  const matches = [];
  const usedCanvasIDs = new Set();
  const usedGradescopeIDs = new Set();
  for (const pairing of confirmedPairings) {
    if (!canvasIDs.has(pairing.canvasID)
        || !gradescopeIDs.has(pairing.gradescopeID)
        || usedCanvasIDs.has(pairing.canvasID)
        || usedGradescopeIDs.has(pairing.gradescopeID)) continue;
    usedCanvasIDs.add(pairing.canvasID);
    usedGradescopeIDs.add(pairing.gradescopeID);
    matches.push(makeMatch(pairing.canvasID, pairing.gradescopeID));
  }

  const candidates = [];
  for (const canvasItem of canvasItems) {
    if (usedCanvasIDs.has(assignmentID(canvasItem))) continue;
    for (const gradescopeItem of gradescopeItems) {
      if (gradescopeItem.course !== canvasItem.course) continue;
      if (usedGradescopeIDs.has(assignmentID(gradescopeItem))) continue;
      if (!isLikelyDuplicate(canvasItem.title, canvasItem.dueAt, gradescopeItem.title, gradescopeItem.dueAt)) continue;
      candidates.push({
        canvas: canvasItem,
        gradescope: gradescopeItem,
        score: matchScore(canvasItem, gradescopeItem),
      });
    }
  }

  const ordered = candidates.slice().sort((a, b) => {
    if (a.score !== b.score) return a.score > b.score ? -1 : 1;
    const gapA = dueDateGap(a.canvas.dueAt, a.gradescope.dueAt);
    const gapB = dueDateGap(b.canvas.dueAt, b.gradescope.dueAt);
    if (gapA !== gapB) return gapA < gapB ? -1 : 1;
    return compareByCodePoint(assignmentID(a.canvas), assignmentID(b.canvas));
  });

  for (const candidate of ordered) {
    const cid = assignmentID(candidate.canvas);
    const gid = assignmentID(candidate.gradescope);
    if (usedCanvasIDs.has(cid) || usedGradescopeIDs.has(gid)) continue;
    usedCanvasIDs.add(cid);
    usedGradescopeIDs.add(gid);
    matches.push(makeMatch(cid, gid));
  }
  return matches;
}

// ---- merge (Swift 427-488) --------------------------------------------------

// Canvas supplies display metadata; submitted is either side; each score
// field falls back to Gradescope independently; term is Canvas's only (Swift
// 473-488). `??` is Swift's `??` here: it falls through on null, not on 0.
export function mergedAssignment(canvas, gradescope) {
  return makeAssignment({
    source: canvas.source,
    sourceID: canvas.sourceID,
    kind: canvas.kind,
    course: canvas.course,
    title: canvas.title,
    dueAt: canvas.dueAt,
    url: canvas.url,
    term: canvas.term,
    submitted: canvas.submitted || gradescope.submitted,
    scoreEarned: canvas.scoreEarned ?? gradescope.scoreEarned,
    scoreMax: canvas.scoreMax ?? gradescope.scoreMax,
    linkedID: assignmentID(gradescope),
  });
}

// Matched canvas items become merged items in canvas order; unmatched
// gradescope items follow in input order (Swift 435-459).
//
// Swift builds `Dictionary(uniqueKeysWithValues:)` over the gradescope ids,
// which traps the process if two gradescope items share an id (Swift 447).
// JS cannot sensibly trap; the later item wins instead.
export function merge(canvasItems, gradescopeItems, confirmedPairings = []) {
  const matches = matchPairs(canvasItems, gradescopeItems, confirmedPairings);
  if (matches.length === 0) return [...canvasItems, ...gradescopeItems];

  const gradescopeByID = new Map(gradescopeItems.map((g) => [assignmentID(g), g]));
  const gradescopeIDByCanvasID = new Map(matches.map((m) => [m.canvasID, m.gradescopeID]));
  const matchedGradescopeIDs = new Set(matches.map((m) => m.gradescopeID));

  const mergedCanvas = canvasItems.map((canvasItem) => {
    const gradescopeID = gradescopeIDByCanvasID.get(assignmentID(canvasItem));
    const gradescopeItem = gradescopeID === undefined ? undefined : gradescopeByID.get(gradescopeID);
    if (gradescopeItem === undefined) return canvasItem;
    return mergedAssignment(canvasItem, gradescopeItem);
  });
  const unmatchedGradescope = gradescopeItems.filter((g) => !matchedGradescopeIDs.has(assignmentID(g)));
  return [...mergedCanvas, ...unmatchedGradescope];
}

// ---- Canvas ICS <-> Canvas Modules collapse (Swift 490-627) -----------------

// Many-to-one on purpose: a canvas row may absorb any number of module rows
// (the same assignment listed under two Modules), so there is no canvas-side
// claim set; only the module side is claimed (Swift 529-543).
export function collapseCanvasDuplicates(canvasItems, moduleItems) {
  if (canvasItems.length === 0 || moduleItems.length === 0) {
    return { canvasItems, moduleItems, collapses: [] };
  }

  const canvasByCourse = new Map();
  for (const item of canvasItems) {
    if (!canvasByCourse.has(item.course)) canvasByCourse.set(item.course, []);
    canvasByCourse.get(item.course).push(item);
  }

  const collapsedModuleIDs = new Set();
  const collapsesByModuleID = new Map();

  // Pass 1: exact Canvas assignment id, over every module row before any
  // fuzzy matching, so pass 2 can never steal an id match (Swift 558-578).
  // When two canvas rows share an id the later one wins (Swift 570).
  const canvasByIDInCourse = new Map();
  for (const item of canvasItems) {
    const id = canvasAssignmentID(item);
    if (id === null) continue;
    if (!canvasByIDInCourse.has(item.course)) canvasByIDInCourse.set(item.course, new Map());
    canvasByIDInCourse.get(item.course).set(id, item);
  }
  for (const moduleItem of moduleItems) {
    const moduleAssignmentID = canvasAssignmentID(moduleItem);
    if (moduleAssignmentID === null) continue;
    const canvasMatch = canvasByIDInCourse.get(moduleItem.course)?.get(moduleAssignmentID);
    if (canvasMatch === undefined) continue;
    const moduleID = assignmentID(moduleItem);
    collapsedModuleIDs.add(moduleID);
    collapsesByModuleID.set(moduleID, Object.freeze({ canvasID: assignmentID(canvasMatch), moduleID }));
  }

  // Pass 2: the title/due heuristic for what pass 1 left, smallest gap first,
  // then module id, then canvas id. A module row takes its first candidate
  // and is done (Swift 580-620).
  const candidates = [];
  for (const moduleItem of moduleItems) {
    if (collapsedModuleIDs.has(assignmentID(moduleItem))) continue;
    for (const canvasItem of canvasByCourse.get(moduleItem.course) ?? []) {
      if (!isLikelyDuplicate(moduleItem.title, moduleItem.dueAt, canvasItem.title, canvasItem.dueAt)) continue;
      candidates.push({
        moduleItem,
        canvasItem,
        gap: dueDateGap(moduleItem.dueAt, canvasItem.dueAt),
      });
    }
  }
  const ordered = candidates.slice().sort((a, b) => {
    if (a.gap !== b.gap) return a.gap < b.gap ? -1 : 1;
    const m = compareByCodePoint(assignmentID(a.moduleItem), assignmentID(b.moduleItem));
    if (m !== 0) return m;
    return compareByCodePoint(assignmentID(a.canvasItem), assignmentID(b.canvasItem));
  });
  for (const candidate of ordered) {
    const moduleID = assignmentID(candidate.moduleItem);
    if (collapsedModuleIDs.has(moduleID)) continue;
    collapsedModuleIDs.add(moduleID);
    collapsesByModuleID.set(moduleID, Object.freeze({ canvasID: assignmentID(candidate.canvasItem), moduleID }));
  }

  const survivors = moduleItems.filter((m) => !collapsedModuleIDs.has(assignmentID(m)));
  // Reported in module input order (Swift 623-625).
  const collapses = [];
  for (const m of moduleItems) {
    const c = collapsesByModuleID.get(assignmentID(m));
    if (c !== undefined) collapses.push(c);
  }
  return { canvasItems, moduleItems: survivors, collapses };
}

// ---- Canvas ICS section-override collapse (Swift 629-737) -------------------

// `preferredDueDates` maps a Canvas assignment id to the student's effective
// due date; a Map or a plain object is accepted.
function preferredFor(preferredDueDates, id) {
  if (preferredDueDates instanceof Map) return preferredDueDates.get(id) ?? null;
  return Object.hasOwn(preferredDueDates, id) ? preferredDueDates[id] : null;
}

// Swift's `min(by:)` keeps the first element among ties (it only replaces the
// running minimum when the next element is strictly less), so equal rows
// resolve to the earliest in input order.
function minBy(rows, less) {
  let result = rows[0];
  for (let i = 1; i < rows.length; i++) if (less(rows[i], result)) result = rows[i];
  return result;
}

export function collapseCanvasOverrides(canvasItems, preferredDueDates) {
  if (canvasItems.length === 0) return { canvasItems, collapses: [] };

  // Groups keyed by (course, canvas assignment id), in first-seen order via
  // groupOrder, exactly as Swift keeps it (Swift 699-706).
  const groups = new Map();
  const groupOrder = [];
  for (const item of canvasItems) {
    if (item.source !== Source.CANVAS) continue;
    const id = canvasAssignmentID(item);
    if (id === null) continue;
    const key = JSON.stringify([item.course, id]);
    if (!groups.has(key)) {
      groups.set(key, { assignmentID: id, rows: [] });
      groupOrder.push(key);
    }
    groups.get(key).rows.push(item);
  }

  const hiddenIDs = new Set();
  const collapsesByHiddenID = new Map();
  for (const key of groupOrder) {
    const { assignmentID: canvasID, rows } = groups.get(key);
    if (rows.length < 2) continue;
    const preferred = preferredFor(preferredDueDates, canvasID);
    const survivor = minBy(rows, (a, b) => {
      if (preferred != null) {
        const gapA = a.dueAt != null ? Math.abs(secondsBetween(a.dueAt, preferred)) : GREATEST_FINITE;
        const gapB = b.dueAt != null ? Math.abs(secondsBetween(b.dueAt, preferred)) : GREATEST_FINITE;
        if (gapA !== gapB) return gapA < gapB;
      } else {
        // nil counts as distantFuture, so an undated row loses to any dated
        // one and ties with a row dated exactly then (Swift 719-721).
        const dateA = a.dueAt != null ? a.dueAt.getTime() : DISTANT_FUTURE_MS;
        const dateB = b.dueAt != null ? b.dueAt.getTime() : DISTANT_FUTURE_MS;
        if (dateA !== dateB) return dateA < dateB;
      }
      return compareByCodePoint(assignmentID(a), assignmentID(b)) < 0;
    });
    const survivorID = assignmentID(survivor);
    for (const row of rows) {
      const rowID = assignmentID(row);
      if (rowID === survivorID) continue;
      hiddenIDs.add(rowID);
      collapsesByHiddenID.set(rowID, Object.freeze({ survivorID, hiddenID: rowID }));
    }
  }

  const survivors = canvasItems.filter((a) => !hiddenIDs.has(assignmentID(a)));
  // In the input order of the hidden rows (Swift 733-735).
  const collapses = [];
  for (const a of canvasItems) {
    const c = collapsesByHiddenID.get(assignmentID(a));
    if (c !== undefined) collapses.push(c);
  }
  return { canvasItems: survivors, collapses };
}
