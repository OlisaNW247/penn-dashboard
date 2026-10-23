// The popup's work list, as pure functions: merged assignments + the local
// snapshot's completions + `now` in, the popup state out. No chrome.*, no DOM.
//
// Ports the phone's view rules; each function names its Swift origin.
//   todo : DashboardViewModel.todoSections (overdue + due within 2 days)
//   all  : DashboardViewModel.allSections  (future work, overdue excluded)
//   prev : DashboardViewModel.doneSections (finished work, this week first)
// All times are local (the phone uses Calendar.current).
import { makeAssignment, assignmentID } from "./assignment.js";
import { parse } from "./courseCode.js";

const DAY = 86_400_000;
const WEEKDAYS = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"];
const WEEKDAYS_LONG = ["sunday", "monday", "tuesday", "wednesday", "thursday", "friday", "saturday"];
const MONTHS = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

// ---- storage form: Assignment <-> JSON-safe object ---------------------------

export function toStored(a) {
  return {
    source: a.source, sourceID: a.sourceID, kind: a.kind, course: a.course, title: a.title,
    dueAt: a.dueAt ? new Date(a.dueAt).toISOString() : null,
    url: a.url ?? null, term: a.term ?? null, submitted: !!a.submitted,
    scoreEarned: a.scoreEarned ?? null, scoreMax: a.scoreMax ?? null, linkedID: a.linkedID ?? null,
  };
}

export function fromStored(s) {
  return makeAssignment({ ...s, dueAt: s.dueAt ? new Date(s.dueAt) : null });
}

// ---- calendar helpers (local time) -------------------------------------------

// Whole calendar days from a's day to b's day; DST-proof.
function calendarDays(a, b) {
  const u = (d) => Date.UTC(d.getFullYear(), d.getMonth(), d.getDate());
  return Math.round((u(b) - u(a)) / DAY);
}

function startOfWeek(d) { // Sunday, as Calendar.current in en_US
  return new Date(d.getFullYear(), d.getMonth(), d.getDate() - d.getDay());
}

const sameWeek = (a, b) => startOfWeek(a).getTime() === startOfWeek(b).getTime();

// Term(date:) (Term.swift:46-53), year + season rank (spring 1, summer 2, fall 3).
function termRankOf(date) {
  const m = date.getMonth() + 1;
  return { year: date.getFullYear(), rank: m <= 5 ? 1 : m <= 7 ? 2 : 3 };
}

// Term.startDate / endDate (Term.swift:59-95).
function termStart({ year, rank }) {
  return new Date(year, rank === 1 ? 0 : rank === 2 ? 4 : 7, rank === 1 ? 1 : rank === 2 ? 15 : 1);
}
function termEnd({ year, rank }) {
  return rank === 1 ? new Date(year, 4, 31, 23, 59, 59)
    : rank === 2 ? new Date(year, 7, 31, 23, 59, 59)
    : new Date(year, 11, 31, 23, 59, 59);
}

const SEASON_RANK = { 10: 1, 20: 2, 30: 3 };
const termKey = (t) => t.year * 10 + SEASON_RANK[t.season];

// ---- due phrases -------------------------------------------------------------

// RedesignTokens.swift:591-624 `dueText` for overdue, the last day, and up to
// two days out ("5h left", "in 2 days", "2 days late"); `smoothDueValue`
// (RedesignTokens.swift:550-583) beyond that: the weekday for the next five
// days, then "Nov 14".
export function dueLabel(due, now) {
  if (!due) return "no date";
  const s = (due.getTime() - now.getTime()) / 1000;
  if (s < 0) {
    const late = -s;
    if (late < 3600) return `${Math.max(1, Math.floor(late / 60))}m late`;
    if (late < 86_400) return `${Math.max(1, Math.floor(late / 3600))}h late`;
    const d = calendarDays(due, now);
    return `${Math.max(1, d)} day${d === 1 ? "" : "s"} late`;
  }
  if (s < 3600) return `${Math.max(1, Math.floor(s / 60))}m left`;
  if (s < 86_400) return `${Math.max(1, Math.floor(s / 3600))}h left`;
  const d = calendarDays(now, due);
  if (d <= 2) return `in ${Math.max(1, d)} day${d === 1 ? "" : "s"}`;
  if (s <= 5 * 86_400) return WEEKDAYS[due.getDay()];
  return `${MONTHS[due.getMonth()]} ${due.getDate()}`;
}

// ---- visibility rules --------------------------------------------------------

// AppState.isTooOld (AppState.swift:6592): due more than 5 months ago.
function isTooOld(due, now) {
  if (!due) return false;
  const cutoff = new Date(now);
  cutoff.setMonth(cutoff.getMonth() - 5);
  return due < cutoff;
}

// AppState.withinTermCap (AppState.swift:6565-6588), with nothing archived: a
// future term is out; with no term, due must not pass the end of the current
// term (or a week out, whichever is later). Undated and term-less items pass
// (archivedCourseTerms is empty).
function withinTermCap(a, due, now) {
  const cur = termRankOf(now);
  if (a.term) return termKey(a.term) <= cur.year * 10 + cur.rank;
  if (!due) return true;
  const cap = Math.max(termEnd(cur).getTime(), now.getTime() + 7 * DAY);
  return due.getTime() <= cap;
}

const byDueThenID = (x, y) => {
  const a = x.due?.getTime(), b = y.due?.getTime();
  if (a != null && b != null && a !== b) return a - b;
  if (a == null && b != null) return 1;
  if (a != null && b == null) return -1;
  return x.id < y.id ? -1 : x.id > y.id ? 1 : 0;
};

// The student's completion for an item, from the local snapshot. A record on
// the item's own id wins over one on its linked (Gradescope) id, as isCompleted
// follows linkedID (AppState.swift:7382-7384). With no record, the feed's own
// `submitted` decides. An explicit un-tick (done:false) beats `submitted`.
export function completionOf(a, completions) {
  const own = completions?.[assignmentID(a)];
  const linked = a.linkedID ? completions?.[a.linkedID] : undefined;
  const rec = own ?? linked;
  if (rec) return { done: !!rec.done, at: rec.done ? new Date(rec.at) : null };
  return { done: !!a.submitted, at: null };
}

// ---- the phone's items, merged into the view -------------------------------------

// A due-date edit from the merged snapshot; `dueAt: null` means "edit cleared",
// so the item keeps its own date. An edit on the item's own id wins over one
// on its linked id.
function editedDue(a, base, dueEdits) {
  const id = a.id ?? assignmentID(a);
  const e = dueEdits?.[id] ?? (a.linkedID ? dueEdits?.[a.linkedID] : undefined);
  return e && e.dueAt ? new Date(e.dueAt) : base;
}

// Items in the phone work lists (remoteWorkListsV1: [{deviceId, workList}])
// whose id the laptop does not hold, first mention wins. Pure.
export function remoteItems(remote, laptopIDs = new Set()) {
  const seen = new Set(laptopIDs);
  const out = [];
  for (const r of remote ?? []) {
    for (const w of r?.workList ?? []) {
      if (!w || typeof w.id !== "string" || seen.has(w.id)) continue;
      seen.add(w.id);
      out.push(w);
    }
  }
  return out;
}

// ---- the state -----------------------------------------------------------------

// `stored`: workListV1.items. `completions`: snapshot.completions.
// Returns the object `render(state, root)` takes.
export function buildState({
  stored = [], completions = {}, now = new Date(), view = "todo",
  canvas = "unknown", gradescope = "unknown", paired = false,
  remote = [], dueEdits = {},
}) {
  const active = [];
  const finished = [];
  const laptopIDs = new Set();
  for (const s of stored) {
    const a = fromStored(s);
    laptopIDs.add(assignmentID(a));
    if (a.linkedID) laptopIDs.add(a.linkedID);
  }
  for (const s of stored) {
    const a = fromStored(s);
    const due = editedDue(a, a.dueAt, dueEdits);
    const c = completionOf(a, completions);
    const row = {
      id: assignmentID(a),
      course: parse(a.course).code,
      title: a.title,
      due,
      done: c.done,
      completedAt: c.at,
    };
    if (c.done) { finished.push(row); continue; }
    if (isTooOld(due, now) || !withinTermCap(a, due, now)) continue;
    active.push(row);
  }

  // The phone's own work list: what the laptop did not read. Laptop wins on
  // fields, the merged snapshot on done. The phone already applied its view
  // rules, so the too-old and term filters are not applied again.
  for (const w of remoteItems(remote, laptopIDs)) {
    const rec = completions?.[w.id];
    const done = rec ? !!rec.done : !!w.done;
    const due = editedDue({ id: w.id }, w.dueAt ? new Date(w.dueAt) : null, dueEdits);
    const row = {
      id: w.id, course: parse(w.course).code, title: w.title, due, done,
      completedAt: done && rec ? new Date(rec.at) : null,
    };
    (done ? finished : active).push(row);
  }

  // DashboardViewModel.timelineSections (L284-). Overdue is s<0; "todo" holds
  // everything up to 2 days out (today + the two-day window); beyond that, and
  // undated, is "later". The popup shows overdue+todo for the todo view,
  // todo+later for all (overdue stays out of all), prev for prev.
  const items = [];
  for (const r of active.sort(byDueThenID)) {
    const s = r.due ? (r.due.getTime() - now.getTime()) / 1000 : null;
    const bucket = s == null ? "later" : s < 0 ? "overdue" : s <= 2 * 86_400 ? "todo" : "later";
    items.push({ id: r.id, course: r.course, title: r.title, due: dueLabel(r.due, now), bucket, done: false });
  }

  // doneSections (L370-): this week first, then this term; newest first;
  // placed by completion time, else due date. Unplaceable items still show.
  const placed = (r) => r.completedAt ?? r.due;
  const start = termStart(termRankOf(now));
  const newest = (x, y) => {
    const a = placed(x)?.getTime() ?? -Infinity, b = placed(y)?.getTime() ?? -Infinity;
    return a === b ? (x.id < y.id ? -1 : 1) : b - a;
  };
  const week = finished.filter((r) => placed(r) && sameWeek(placed(r), now)).sort(newest);
  const weekIDs = new Set(week.map((r) => r.id));
  const earlier = finished
    .filter((r) => !weekIDs.has(r.id))
    .filter((r) => !placed(r) || placed(r) >= start)
    .sort(newest);
  for (const r of [...week, ...earlier]) {
    const p = placed(r);
    const label = !p ? "" : sameWeek(p, now) ? WEEKDAYS[p.getDay()] : `${MONTHS[p.getMonth()]} ${p.getDate()}`;
    items.push({ id: r.id, course: r.course, title: r.title, due: label, bucket: "prev", done: true });
  }

  return {
    weekday: WEEKDAYS_LONG[now.getDay()],
    view, canvas, gradescope, paired, items,
  };
}

// ---- which Canvas calendar items reach the dashboard -----------------------------

// AppState.isAssessment (AppState.swift:6664-6674): quiz kind, or an exam-ish
// title in a real course.
export function isAssessment(a) {
  if (a.kind === "quiz") return true;
  if (a.course === "(unknown course)") return false;
  return /\b(midterms?|exams?|quiz|quizzes|prelims?|finals|final exam)\b/i.test(a.title);
}

// canvasRelevant (AppState.swift, rebuildDashboardItems): an assignment or an
// assessment. The phone also admits `.event` items (readings, lectures); those
// are left out here, see the open question in the step report.
export const isCanvasRelevant = (a) => a.kind === "assignment" || isAssessment(a);
