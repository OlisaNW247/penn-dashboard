// The `extract-facts` prompt, strict JSON schema and response parser: Phase 0
// of docs/DAY_PLANNER_RESEARCH_2026-11-03.md (section 2.1 and Addendum A/C).
//
// Where `announcement.ts` turns one announcement into a list of new tasks,
// this reads ONE course document (an announcement, an Ed post, a page, the
// syllabus, a module) against the ITEM INDEX of the course's current work
// and emits *facts*: a new task, or a change to an item the index already
// holds (cancel, reschedule, scope change, note), or a `needs_review` the
// phone shows but never applies. Each fact carries a verbatim quote.
//
// Pure on purpose, like the rest of `_shared/` prompt code: no Deno.env, no
// network, no database, and never the system clock. "Now" and the posted
// date arrive in the document, so a test with a fixed instant is exact.
//
// The register and the rules are carried over from `announcement.ts`,
// including the failure that file exists because of: "The slides discussed
// today have been posted." became an overdue assignment. Passive voice and
// the instructor's own actions yield no fact.

export type FactType = "new_task" | "cancel" | "reschedule" | "scope_change" | "note" | "needs_review";
export type FactKind = "submission" | "preparation" | "event";

export interface IndexItem {
  sourceID: string;
  title: string;
  dueAt?: string;
  kind: "assignment" | "module_item" | "quiz" | "event";
}

export interface Meeting {
  weekday: "Mon" | "Tue" | "Wed" | "Thu" | "Fri" | "Sat" | "Sun";
  start: string; // "13:45"
  end: string;
  room?: string;
}

export interface FactsDocument {
  id: string;
  course: string; // course code, e.g. "CIS 2400"
  kind: "announcement" | "ed" | "page" | "syllabus" | "module";
  title: string;
  postedAt?: string; // ISO 8601
  text: string;
  index: IndexItem[];
  meetings: Meeting[];
  timezone: string; // IANA
  now: string; // ISO 8601
}

export interface Fact {
  type: FactType;
  target: string | null;
  title?: string;
  due_at: string | null;
  kind?: FactKind;
  quote: string;
  confidence: "high" | "medium";
}

export type RejectReason =
  | "bad_shape"
  | "quote_not_in_text"
  | "unknown_target"
  | "target_required"
  | "date_out_of_range"
  | "due_in_past"
  | "stale_document"
  | "title_required"
  | "due_required";

/** The longest title a stored fact keeps. A longer one is trimmed, not
 *  rejected: the prompt asks for 80, and the schema cannot carry a maxLength. */
export const MAX_FACT_TITLE_CHARS = 200;

export interface ParsedFacts {
  facts: Fact[];
  rejected: { fact: unknown; reason: RejectReason }[];
  parseFailed: boolean;
}

export const FACTS_INSTRUCTIONS: string = [
  `You read ONE course document -- an announcement, a discussion post, a `
  + `page, a syllabus or a module -- against an ITEM INDEX of the course's `
  + `current work, and emit zero or more facts about what that document `
  + `says the STUDENT must now do, or no longer must do. Every fact carries `
  + `a verbatim quote from the document that supports it. The title is part `
  + `of the document: a fact stated only in the title is a fact, and its `
  + `quote may come from the title.`,

  `Each fact has a "type":\n`
  + `- "new_task": work the student must do that is NOT in the index. Give a `
  + `short imperative "title" (at most 80 characters), a "kind" and a `
  + `"due_at" (or null).\n`
  + `- "cancel": an indexed item no longer needs doing. "target" is required.\n`
  + `- "reschedule": an indexed item has a new date. "target" is required and `
  + `"due_at" is the NEW date.\n`
  + `- "scope_change": assigned work whose requirement shrinks or grows, e.g. `
  + `"only problems 1-4". "target" is required and the change goes in "title".\n`
  + `- "note": information attached to an indexed item, e.g. "covers `
  + `chapters 5-6". "target" is required and the note goes in "title".\n`
  + `- "needs_review": an indexed item put in doubt. It is shown to the `
  + `student and never applied. "target" is optional.`,

  `Name a target ONLY by its sourceID exactly as it appears in the ITEM `
  + `INDEX, never by title. Never invent an item the index already has -- use `
  + `its sourceID as the "target" of a change instead of emitting a new_task.`,

  `A sentence in passive voice or the first person about something the `
  + `instructor did or will do -- "the slides discussed today have been `
  + `posted", "I uploaded the recording", "we will cover chapter 6 next `
  + `week" -- is informational and yields no fact, even when it names course `
  + `material. A room, time or office-hours change yields no fact either `
  + `unless it moves or cancels an indexed item. "X is posted" or `
  + `"released" for work the index already holds, or that matches an indexed `
  + `item by number or name, yields no fact. Extract only what THIS document `
  + `says.`,

  `A new_task needs an explicit instruction directed at students, with an `
  + `action verb (submit, turn in, upload, complete, bring, take the exam or `
  + `quiz, or attend when the document states that attendance is required), `
  + `AND a stated date, or a date resolvable from the posted date and CLASS `
  + `MEETINGS. A required exam or quiz is kind "event"; a required `
  + `deliverable is kind "submission". A title that merely names something `
  + `("Final exam:", "Homework 9") is not an instruction. Study advice, `
  + `"I recommend", "feel free", "it would be great if", optional reading, `
  + `optional dated events (a career talk, a forum), social threads, and `
  + `account or admin chores ("accept the invitation", "sign up for the `
  + `tool") yield no fact. Regrade, appeal and score-posting logistics, and `
  + `advice conditional on the student's own score, yield no fact.`,

  `Optional opportunities are NEVER a new_task, even when they earn credit `
  + `and have a stated date: a point redemption session, an optional `
  + `resubmission window, an extra-credit talk. If the opportunity concerns `
  + `an indexed item, emit a "note" on that item with the opportunity in `
  + `"title" (for example "optional resubmission by Thursday Nov 5"); `
  + `otherwise emit no fact. Do not prefix a title with "optional" to make `
  + `an optional thing a task. This rule only blocks CREATING a task: it `
  + `never blocks a cancel, reschedule, scope_change or note on an item the `
  + `index already holds, even when that item is itself optional -- giving `
  + `an indexed "MT1 P3 Redemption" item its date is a reschedule.`,

  // Exam assumption: the owner confirmed on 2026-11-04 that required exams
  // and quizzes with a stated date are tasks, kind "event".
  // Owner's answer: a line with a due date counts as clear action words even
  // with no verb; the due date is the action word.
  `A new_task quote must contain the instruction itself, verbatim -- the `
  + `sentence with the action words and the requirement. A module, syllabus `
  + `or announcement line that names the work and states its due date `
  + `("Pipelining Worksheet (file). Due Tuesday, November 10 at 1:45 PM", `
  + `"Final exam: Dec 15, 9am", "Quiz 2 for Chap. 22 on Friday") IS the `
  + `instruction: the due date is the action word, and the quote must `
  + `contain that line with its date. A bare title with no date and no verb `
  + `such as "Final exam:" is not an instruction: extend the quote to a `
  + `sentence that states the requirement and the date; if the document has `
  + `no such sentence, emit needs_review (with no target unless an indexed `
  + `item is meant) instead of a new_task.`,

  `Grade weights, late or submission policy, and other standing rules yield `
  + `no fact; a post that restates an indexed item's existing due date yields `
  + `no fact.`,

  `When the title or text names an indexed item and gives or resolves a `
  + `date, emit reschedule with that date rather than needs_review. A change `
  + `for one section or group only, or an indexed item made optional, is `
  + `needs_review on that item, never reschedule and never cancel. Use `
  + `needs_review only for an indexed item whose date, scope or status the `
  + `document puts in doubt without saying how (a holiday collision, a `
  + `section-only change, "we may move the midterm", "now optional"). A `
  + `cancellation or "no quiz on X" for something not in the index, a `
  + `conditional poll, or a contradiction between a stated weekday and date, `
  + `yields no fact.`,

  // Why this paragraph exists (2026-11-05, PHYS 0151, first sync): months of
  // old posts were extracted against today's index. "Quiz 5 on capacitors
  // will be on Sep 19th" (posted September) met an index already showing
  // Oct 19 and came back as needs_review "date conflicts"; the index is
  // newer than the post, so the right answer is no fact. "Quiz 2 for
  // Chap.22 is rescheduled to Sep 23" (not indexed, now November) came back
  // as a new_task for a date long past. The wrong fix is to skip old
  // documents entirely: a syllabus is old and still the only source of an
  // unindexed final exam, and a coverage note or a cancel on an item the
  // index still holds stays true. The validator backs the two hard cases
  // (stale_document, due_in_past).
  `The ITEM INDEX is Canvas as of the current date. A document posted more `
  + `than 7 days before the current date is older than the index: Canvas has `
  + `had time to absorb whatever it announced. For such a document, a date `
  + `it states for an indexed item that differs from the index was `
  + `superseded, so emit no reschedule and no needs_review about that `
  + `item's date; notes about coverage, format, materials or location still `
  + `apply, and a cancel still applies when the index still holds the item. `
  + `Work whose stated or resolved date is already before the current date `
  + `is over: emit no new_task for it, whatever the document says.`,

  `What an exam or quiz covers or excludes ("covers chapters 5-6", "will not `
  + `test X"), stated for the first time, is a note on that item; `
  + `scope_change is only for assigned work whose requirement shrinks or `
  + `grows (problems dropped or added, a different venue). A note must add `
  + `information about an indexed item not already captured by the `
  + `document's primary fact: coverage, format, allowed materials ("bring a `
  + `calculator"), location. Restatements, reminders to do the item, grade `
  + `releases, FAQs, tips, reasons for a change, and Q&A confirmations are `
  + `not notes. At most one note per target per document.`,

  `"due_at" is an ISO 8601 datetime with a timezone, or null. Resolve a `
  + `relative date ("Friday", "before Tuesday's class") from the document's `
  + `posted date, the weekday it gives, and the CLASS MEETINGS block when `
  + `present; "before class" or "in class" means that day's class start `
  + `time. When the day is known (stated, or "today", "tomorrow" or a `
  + `weekday resolved from the posted date) and no time is stated, "due_at" `
  + `is 23:59 in the document's timezone on that day; never null for a known `
  + `day. Null only when no day is stated or resolvable. "kind" is `
  + `"submission" for anything handed in or completed on a platform, `
  + `"preparation" for work with nothing to hand in (read, watch, review, `
  + `bring), and "event" for a dated happening such as an exam or review `
  + `session.`,

  `When nothing in the document changes the student's work, return an empty `
  + `"facts" list.`,

  `The "quote" must be copied exactly from the document, character for `
  + `character; a quote that does not appear in the document discards the `
  + `fact. "confidence" is "high" when the document states the fact outright `
  + `and "medium" when you inferred it.`,

  `Respond with JSON only, matching the provided schema exactly: `
  + `{ "facts": [ { "type", "target", "title", "due_at", "kind", "quote", "confidence" } ] }. `
  + `Use null for "target" and "due_at" when they do not apply.`,
].join("\n\n");

const FACT_TYPES = ["new_task", "cancel", "reschedule", "scope_change", "note", "needs_review"] as const;
const FACT_KINDS = ["submission", "preparation", "event"] as const;
const CONFIDENCES = ["high", "medium"] as const;

/** The `schema` for `response_format: { type: "json_schema", strict: true }`.
 *  Strict mode demands `additionalProperties: false` and every property
 *  listed in `required`, so optional fields (`title`, `kind`, `target`,
 *  `due_at`) are required-but-nullable here instead of omitted. No
 *  `minimum`/`maxLength`: Anthropic's mode rejects them, so length and range
 *  checks live in `parseFacts`, not here. The wrong fix for a model that
 *  over-writes titles is a `maxLength` in this schema; it would make the
 *  whole request fail on one provider. */
export const FACTS_JSON_SCHEMA: Record<string, unknown> = {
  type: "object",
  additionalProperties: false,
  required: ["facts"],
  properties: {
    facts: {
      type: "array",
      items: {
        type: "object",
        additionalProperties: false,
        required: ["type", "target", "title", "due_at", "kind", "quote", "confidence"],
        properties: {
          type: { type: "string", enum: [...FACT_TYPES] },
          target: { type: ["string", "null"] },
          title: { type: ["string", "null"] },
          due_at: { type: ["string", "null"] },
          // Not `enum: [..., null]` on a nullable type: Anthropic's schema
          // mode rejects a null inside an enum list (400 "Invalid schema:
          // Enum val..." on the first live Haiku 5.5 call, 2026-11-03), while
          // OpenAI's strict mode and the others accept this anyOf form.
          kind: { anyOf: [{ type: "string", enum: [...FACT_KINDS] }, { type: "null" }] },
          quote: { type: "string" },
          confidence: { type: "string", enum: [...CONFIDENCES] },
        },
      },
    },
  },
};

const MAX_TEXT_CHARS = 12000;
const MAX_DUE_DATE_SKEW_MS = 400 * 24 * 60 * 60 * 1000;

/** A document posted longer ago than this is older than the ITEM INDEX: Canvas
 * has had time to absorb what it announced, so a reschedule it states was
 * superseded (2026-11-05, PHYS 0151: a September "Quiz 5 will be on Sep 19th"
 * against an index that already said Oct 19 produced a needs_review). Mirrors
 * the 7 days in the prompt; the validator enforces it for reschedules because
 * a model can miss it, while needs_review about the same date is left to the
 * prompt, which can tell a date conflict from a coverage note. */
export const STALE_DOCUMENT_MS = 7 * 24 * 60 * 60 * 1000;

/** Weekday name of `iso` in `timeZone`, via Intl so it never depends on the
 *  host's zone or clock. `undefined` when the date or zone is unusable. */
function weekdayName(iso: string, timeZone: string): string | undefined {
  const date = new Date(iso);
  if (Number.isNaN(date.getTime())) return undefined;
  try {
    return new Intl.DateTimeFormat("en-US", { weekday: "long", timeZone }).format(date);
  } catch {
    return undefined;
  }
}

/** A `due_at` string as an absolute ISO instant, or `undefined` when it is
 *  not a date at all. A string with an offset (`Z`, `+05:30`) is already
 *  absolute and is returned unchanged. One WITHOUT an offset ("2026-11-10",
 *  "2026-11-10T23:59") is a wall-clock time in the document's `timeZone`, not
 *  UTC: reading it as UTC put "2026-11-10T23:59" five hours late for a
 *  student in New York. A bare date is 23:59 local that day (the prompt's own
 *  rule for "by Friday"). An unusable zone falls back to UTC, the old
 *  behaviour, rather than dropping the fact. */
export function resolveDueAt(raw: string, timeZone: string): string | undefined {
  const s = raw.trim();
  const m = /^(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2})(?:\.\d+)?)?)?$/.exec(s);
  if (!m) {
    return Number.isNaN(new Date(s).getTime()) ? undefined : s;
  }
  const [y, mo, d] = [Number(m[1]), Number(m[2]), Number(m[3])];
  const hasTime = m[4] !== undefined;
  const h = hasTime ? Number(m[4]) : 23;
  const mi = hasTime ? Number(m[5]) : 59;
  const sec = m[6] !== undefined ? Number(m[6]) : 0;
  if (mo < 1 || mo > 12 || d < 1 || d > 31 || h > 23 || mi > 59 || sec > 59) return undefined;
  const wall = Date.UTC(y, mo - 1, d, h, mi, sec);
  if (new Date(wall).getUTCMonth() !== mo - 1) return undefined; // Feb 30
  const offsetAt = (instant: number): number | undefined => {
    try {
      const parts = new Intl.DateTimeFormat("en-US", {
        timeZone,
        hourCycle: "h23",
        year: "numeric",
        month: "numeric",
        day: "numeric",
        hour: "numeric",
        minute: "numeric",
        second: "numeric",
      }).formatToParts(new Date(instant));
      const get = (t: string) => Number(parts.find((p) => p.type === t)?.value);
      const asUTC = Date.UTC(get("year"), get("month") - 1, get("day"), get("hour"), get("minute"), get("second"));
      return asUTC - Math.floor(instant / 1000) * 1000;
    } catch {
      return undefined;
    }
  };
  const first = offsetAt(wall);
  if (first === undefined) return new Date(wall).toISOString();
  // Two passes settle the offset across a DST change.
  let instant = wall - first;
  const second = offsetAt(instant);
  if (second !== undefined && second !== first) instant = wall - second;
  return new Date(instant).toISOString();
}

/** Calendar day (YYYY-MM-DD) of `iso` in `timeZone`; a bare date is that day.
 *  `null` when the date or zone is unusable. */
function dayKey(iso: string, timeZone: string): string | null {
  if (/^\d{4}-\d{2}-\d{2}$/.test(iso)) return iso;
  const d = new Date(iso);
  if (Number.isNaN(d.getTime())) return null;
  try {
    return new Intl.DateTimeFormat("en-CA", { timeZone, year: "numeric", month: "2-digit", day: "2-digit" }).format(d);
  } catch {
    return null;
  }
}

export function buildFactsMessages(doc: FactsDocument): { system: string; user: string } {
  const lines: string[] = [
    `Course: ${doc.course}`,
    `Document kind: ${doc.kind}`,
    `Title: ${doc.title}`,
  ];
  if (doc.postedAt) {
    const day = weekdayName(doc.postedAt, doc.timezone);
    lines.push(
      day !== undefined
        ? `Posted at: ${doc.postedAt} (${day} in ${doc.timezone})`
        : `Posted at: ${doc.postedAt}`,
    );
  }
  lines.push(`Current date: ${doc.now}`);

  lines.push("");
  lines.push("ITEM INDEX (sourceID | title | due):");
  if (doc.index.length === 0) {
    lines.push("(empty)");
  } else {
    for (const item of doc.index) {
      lines.push(`${item.sourceID} | ${item.title} | ${item.dueAt ?? "undated"}`);
    }
  }

  if (doc.meetings.length > 0) {
    lines.push("");
    lines.push("CLASS MEETINGS:");
    for (const m of doc.meetings) {
      lines.push(`${m.weekday} ${m.start}-${m.end}${m.room ? ` ${m.room}` : ""}`);
    }
  }

  lines.push("");
  lines.push("DOCUMENT:");
  lines.push(doc.text.slice(0, MAX_TEXT_CHARS));
  return { system: FACTS_INSTRUCTIONS, user: lines.join("\n") };
}

// Copied from announcement.ts, where it is private; exporting it from there
// would touch a file this change is not allowed to.
function extractJSON(text: string): string {
  const fenced = text.match(/```(?:json)?\s*([\s\S]*?)```/i);
  return (fenced ? fenced[1] : text).trim();
}

/** Folds both the document and a quote the same way before the containment
 *  check: Unicode NFKC, curly quotes and apostrophes to straight, en/em
 *  dashes to "-", non-breaking space to space, then whitespace collapsed and
 *  lowercased. Applied to BOTH sides, so it cannot make a quote match text
 *  that does not say it; it only stops typography the model re-spelled
 *  (NFD, curly vs straight) from discarding a true fact. The stored quote is
 *  the model's own string, never this folded form. */
function normalizeForQuote(s: string): string {
  return s
    .normalize("NFKC")
    .replace(/[\u2018\u2019]/g, "'")
    .replace(/[\u201C\u201D]/g, '"')
    .replace(/[\u2013\u2014]/g, "-")
    .replace(/\u00A0/g, " ")
    .replace(/\s+/g, " ")
    .trim()
    .toLowerCase();
}

const TARGET_REQUIRED: ReadonlySet<string> = new Set(["cancel", "reschedule", "scope_change", "note"]);

/**
 * Validates the model's `{ "facts": [...] }` response. Strict JSON schema
 * guarantees shape, not truth, so every fact is checked in code: the quote
 * must appear in the document (the "no invented tasks" guard, compared after
 * collapsing whitespace and case because documents are HTML-stripped and the
 * model re-wraps lines), and a target must be a sourceID the model was shown.
 * Order is preserved because a later fact on the same target supersedes an
 * earlier one downstream.
 *
 * A date more than 400 days from `doc.now` (or unparseable) mirrors
 * `parseAssignments`: the date is dropped and the fact kept -- except for
 * `reschedule`, where the date IS the fact, so the whole fact goes. The wrong
 * fix is keeping a reschedule with a null date: the phone would read it as
 * "moved to nowhere".
 */
export function parseFacts(text: string, doc: FactsDocument): ParsedFacts {
  let raw: unknown;
  try {
    raw = JSON.parse(extractJSON(text));
  } catch {
    return { facts: [], rejected: [], parseFailed: true };
  }
  if (typeof raw !== "object" || raw === null || !Array.isArray((raw as Record<string, unknown>).facts)) {
    return { facts: [], rejected: [], parseFailed: true };
  }

  const result: ParsedFacts = { facts: [], rejected: [], parseFailed: false };
  // The title is part of the document: a Canvas announcement often carries
  // its whole point there ("Quiz 2 for Chap.22 is rescheduled to Sep 23")
  // with a body that says only why. The prompt shows the model the title,
  // so a quote from it is as verifiable as one from the body. Checking the
  // body alone, the first version of this check, made that fact impossible
  // to emit at all (found labelling Marco's PHYS 0151 posts, 2026-11-03).
  const normalizedText = normalizeForQuote(doc.title + "\n" + doc.text);
  const knownIDs = new Set(doc.index.map((item) => item.sourceID));
  const now = new Date(doc.now).getTime();

  for (const entry of (raw as { facts: unknown[] }).facts) {
    const reject = (reason: RejectReason) => result.rejected.push({ fact: entry, reason });

    if (typeof entry !== "object" || entry === null || Array.isArray(entry)) {
      reject("bad_shape");
      continue;
    }
    const e = entry as Record<string, unknown>;
    const type = e.type;
    if (typeof type !== "string" || !(FACT_TYPES as readonly string[]).includes(type)) {
      reject("bad_shape");
      continue;
    }
    if (typeof e.quote !== "string" || e.quote.trim().length === 0) {
      reject("bad_shape");
      continue;
    }
    if (e.confidence !== "high" && e.confidence !== "medium") {
      reject("bad_shape");
      continue;
    }
    const target = e.target ?? null;
    if (target !== null && typeof target !== "string") {
      reject("bad_shape");
      continue;
    }
    if (e.title != null && typeof e.title !== "string") {
      reject("bad_shape");
      continue;
    }
    if (e.due_at != null && typeof e.due_at !== "string") {
      reject("bad_shape");
      continue;
    }
    // Offset-less dates are the document's local time (see resolveDueAt).
    // Everything below, and the stored fact, uses the resolved string.
    const dueRaw: string | null = typeof e.due_at === "string" ? (resolveDueAt(e.due_at, doc.timezone) ?? e.due_at) : null;
    if (e.kind != null && !(FACT_KINDS as readonly string[]).includes(e.kind as string)) {
      reject("bad_shape");
      continue;
    }

    if (!normalizedText.includes(normalizeForQuote(e.quote))) {
      reject("quote_not_in_text");
      continue;
    }
    if (target !== null && !knownIDs.has(target)) {
      reject("unknown_target");
      continue;
    }
    if (TARGET_REQUIRED.has(type) && target === null) {
      reject("target_required");
      continue;
    }
    const trimmedTitle = typeof e.title === "string" ? e.title.trim().slice(0, MAX_FACT_TITLE_CHARS).trim() : undefined;
    const title = trimmedTitle === undefined ? undefined : trimmedTitle;
    // new_task names the work in its title; scope_change and note carry the
    // change / the note in it (see the prompt). needs_review has no title in
    // the schema ("target is optional"), so it is left alone.
    if (
      (type === "new_task" || type === "scope_change" || type === "note") &&
      (title === undefined || title.length === 0)
    ) {
      reject("title_required");
      continue;
    }

    // A reschedule from a document posted more than STALE_DOCUMENT_MS before
    // `now` is rejected outright. Undated documents are untouched: without a
    // post date there is no evidence the index is newer.
    if (type === "reschedule" && doc.postedAt) {
      const posted = new Date(doc.postedAt).getTime();
      if (!Number.isNaN(posted) && !Number.isNaN(now) && now - posted > STALE_DOCUMENT_MS) {
        reject("stale_document");
        continue;
      }
    }
    // Work due on an earlier calendar day than today is over, so a new_task
    // for it is noise (2026-11-05: a September "Quiz 2 ... rescheduled to
    // Sep 23" synced in November). Days in the document's zone, not
    // instants: "due 23:59 today" and a date-only due_at for today (which
    // parses as UTC midnight, hours before `now`) are still live work, and
    // comparing instants would drop both. Only a plausible date counts: an
    // unparseable or out-of-range one (1900, 9999) is garbage rather than
    // "past", and keeps going to the null-the-date path below, as before.
    if (type === "new_task" && dueRaw !== null) {
      const due = new Date(dueRaw).getTime();
      if (!Number.isNaN(due) && !Number.isNaN(now) && Math.abs(now - due) <= MAX_DUE_DATE_SKEW_MS) {
        const dueDay = dayKey(dueRaw, doc.timezone);
        const today = dayKey(doc.now, doc.timezone);
        if (dueDay !== null && today !== null && dueDay < today) {
          reject("due_in_past");
          continue;
        }
      }
    }

    // A reschedule IS a new date: without one there is nothing to apply.
    if (type === "reschedule" && dueRaw === null) {
      reject("due_required");
      continue;
    }

    let dueAt: string | null = null;
    if (dueRaw !== null) {
      const parsed = new Date(dueRaw).getTime();
      const ok = !Number.isNaN(parsed) && (Number.isNaN(now) || Math.abs(parsed - now) <= MAX_DUE_DATE_SKEW_MS);
      if (ok) {
        dueAt = dueRaw;
      } else if (type === "reschedule") {
        reject("date_out_of_range");
        continue;
      }
    }

    const fact: Fact = {
      type: type as FactType,
      target,
      due_at: dueAt,
      quote: e.quote,
      confidence: e.confidence,
    };
    if (title !== undefined && title.length > 0) fact.title = title;
    if (typeof e.kind === "string") fact.kind = e.kind as FactKind;
    result.facts.push(fact);
  }
  return result;
}
