// The server-side replacement for the iOS `ClaudeAnnouncementExtractor`
// (`LowHangingFruitKit/Sources/LowHangingFruitKit/Announcements/ClaudeAnnouncementExtractor.swift`).
// That type called Anthropic directly with a forced tool-use block; this
// backend goes through OpenRouter's `response_format: json_object` instead
// (see `openrouter.ts`'s `chatCompletionJSON`), so the *shape* of the
// request differs, but the instructions and the context lines placed ahead
// of the announcement body are carried over as closely as the change in
// transport allows.

/** Ported from `ClaudeAnnouncementExtractor.systemPrompt`
 *  (`ClaudeAnnouncementExtractor.swift:48-50`), with the tool-use framing
 *  ("record the extracted tasks") replaced by a JSON-object instruction
 *  since there is no forced-tool-call equivalent going through
 *  `response_format: json_object`. */
export const ANNOUNCEMENT_INSTRUCTIONS: string = [
  `You extract actionable student tasks from a professor's course `
  + `announcement. Extract only concrete, dated-or-datable tasks the `
  + `student must do (readings, submissions, preparation). Do not invent `
  + `tasks or deadlines; omit anything uncertain. Emit nothing for purely `
  + `informational announcements.`,

  `Respond with a single JSON object and nothing else -- no prose, no `
  + `markdown fence -- of exactly this shape:\n`
  + `{ "assignments": [ { "title": string, "dueAt": string | null } ] }`,

  `"title" is a short imperative task title, at most 80 characters. `
  + `"dueAt" is an ISO 8601 datetime with a timezone when the announcement `
  + `states or clearly implies one, or null when it gives none -- never `
  + `guess a date. If there are no extractable tasks, respond with `
  + `{ "assignments": [] }.`,
].join("\n\n");

export interface AnnouncementContext {
  courseCode: string;
  title: string;
  message: string;
  /** ISO 8601, omitted from the context lines when absent -- mirrors
   *  `announcement.postedAt` being optional on the Swift side. */
  postedAt?: string;
  /** ISO 8601 "now", supplied by the caller (the request body's `now`
   *  field) rather than read from the system clock here, for the same
   *  reason every other "current date" in this backend is caller-supplied:
   *  it keeps this function pure and testable with a fixed instant. */
  now: string;
}

/**
 * Course code, announcement title, optional posted-at, and "Current date"
 * as plain-text lines ahead of the body -- the same grounding
 * `ClaudeAnnouncementExtractor.userContent(for:now:)` gives the model,
 * reproduced line for line. The body is capped at 4000 characters for the
 * same reason the Swift version caps it: a professor occasionally pastes
 * an entire syllabus into an "announcement", and the sentence that states
 * the actual task is almost always in the first paragraph.
 */
export function buildAnnouncementUserContent(context: AnnouncementContext): string {
  const lines: string[] = [
    `Course: ${context.courseCode}`,
    `Announcement title: ${context.title}`,
  ];
  if (context.postedAt) {
    lines.push(`Posted at: ${context.postedAt}`);
  }
  lines.push(`Current date: ${context.now}`);
  lines.push("");
  lines.push(context.message.slice(0, 4000));
  return lines.join("\n");
}

export interface ExtractedAssignment {
  title: string;
  dueAt?: string;
}

const MAX_DUE_DATE_SKEW_MS = 400 * 24 * 60 * 60 * 1000;

/**
 * Parses the model's `{ "assignments": [...] }` response. Tolerant of a
 * fenced ```json block for the same reason `profile.ts`'s `parseProfile`
 * is; unparseable or wrongly-shaped input yields `[]` rather than
 * throwing, since a request that made it this far already spent its quota
 * and a parse failure should surface as "nothing extracted", not a 5xx.
 *
 * A `dueAt` is only kept when it parses as a real date *and* falls within
 * 400 days of `now` in either direction -- "future-or-recent sanity". That
 * catches a model hallucinating a year (a two-year-old syllabus template
 * left in the announcement text) or echoing an unfilled placeholder like
 * `"2024-01-01"`. A rejected date drops just the date, not the whole task
 * -- an undated task the app can't schedule is still more useful to show
 * the student than not surfacing it at all.
 */
export function parseAssignments(text: string, now: Date): ExtractedAssignment[] {
  let raw: unknown;
  try {
    raw = JSON.parse(extractJSON(text));
  } catch {
    return [];
  }
  if (typeof raw !== "object" || raw === null) return [];
  const assignments = (raw as Record<string, unknown>).assignments;
  if (!Array.isArray(assignments)) return [];

  const results: ExtractedAssignment[] = [];
  for (const entry of assignments) {
    if (typeof entry !== "object" || entry === null) continue;
    const title = (entry as Record<string, unknown>).title;
    if (typeof title !== "string" || title.trim().length === 0) continue;

    const rawDue = (entry as Record<string, unknown>).dueAt;
    const dueAt = typeof rawDue === "string" ? sanitizeDueDate(rawDue, now) : undefined;

    results.push(dueAt !== undefined ? { title, dueAt } : { title });
  }
  return results;
}

function sanitizeDueDate(raw: string, now: Date): string | undefined {
  const parsed = new Date(raw);
  if (Number.isNaN(parsed.getTime())) return undefined;
  const skew = Math.abs(parsed.getTime() - now.getTime());
  return skew <= MAX_DUE_DATE_SKEW_MS ? raw : undefined;
}

function extractJSON(text: string): string {
  const fenced = text.match(/```(?:json)?\s*([\s\S]*?)```/i);
  return (fenced ? fenced[1] : text).trim();
}
