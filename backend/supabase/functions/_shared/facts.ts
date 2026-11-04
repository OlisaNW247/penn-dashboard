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
  | "title_required";

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
  + `a verbatim quote from the document that supports it.`,

  `Each fact has a "type":\n`
  + `- "new_task": work the document asks of the student that is NOT in the `
  + `index. Give a short imperative "title" (at most 80 characters), a `
  + `"kind" and a "due_at" (or null).\n`
  + `- "cancel": an indexed item no longer needs doing. "target" is required.\n`
  + `- "reschedule": an indexed item has a new date. "target" is required and `
  + `"due_at" is the NEW date.\n`
  + `- "scope_change": an indexed item's scope changes, e.g. "only problems `
  + `1-4". "target" is required and the change goes in "title".\n`
  + `- "note": information attached to an indexed item, e.g. "covers `
  + `chapters 5-6". "target" is required and the note goes in "title".\n`
  + `- "needs_review": ambiguous or conditional, e.g. "skip HW5 if you did `
  + `the project". It is shown to the student and never applied. "target" is `
  + `optional.`,

  `Name a target ONLY by its sourceID exactly as it appears in the ITEM `
  + `INDEX, never by title. Never invent an item the index already has -- use `
  + `its sourceID as the "target" of a change instead of emitting a new_task.`,

  `A sentence in passive voice or the first person about something the `
  + `instructor did or will do -- "the slides discussed today have been `
  + `posted", "I uploaded the recording", "we will cover chapter 6 next `
  + `week" -- is informational and yields no fact, even when it names course `
  + `material. A room, time or office-hours change yields no fact either `
  + `unless it moves or cancels an indexed item. A later correction post `
  + `supersedes an earlier one, but that is handled elsewhere: extract only `
  + `what THIS document says.`,

  `"due_at" is an ISO 8601 datetime with a timezone, or null. Resolve a `
  + `relative date ("Friday", "before Tuesday's class") from the document's `
  + `posted date, the weekday it gives, and the CLASS MEETINGS block when `
  + `present; "before class" or "in class" means that day's class start `
  + `time, not 23:59. When you are not sure of a date, set "due_at" to null `
  + `rather than guess, and do no calendar arithmetic beyond that. "kind" is `
  + `"submission" for anything handed in or completed on a platform, `
  + `"preparation" for work with nothing to hand in (read, watch, review, `
  + `bring), and "event" for a dated happening such as an exam or review `
  + `session.`,

  `When a post is ambiguous, prefer a "needs_review" fact over a guess. When `
  + `nothing in the document changes the student's work, return an empty `
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

function normalizeForQuote(s: string): string {
  return s.replace(/\s+/g, " ").trim().toLowerCase();
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
    const title = typeof e.title === "string" ? e.title : undefined;
    if (type === "new_task" && (title === undefined || title.trim().length === 0)) {
      reject("title_required");
      continue;
    }

    let dueAt: string | null = null;
    if (typeof e.due_at === "string") {
      const parsed = new Date(e.due_at).getTime();
      const ok = !Number.isNaN(parsed) && (Number.isNaN(now) || Math.abs(parsed - now) <= MAX_DUE_DATE_SKEW_MS);
      if (ok) {
        dueAt = e.due_at;
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
    if (title !== undefined) fact.title = title;
    if (typeof e.kind === "string") fact.kind = e.kind as FactKind;
    result.facts.push(fact);
  }
  return result;
}
