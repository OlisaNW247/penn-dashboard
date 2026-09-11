// Builds the OpenAI-style `messages` array `ask/index.ts` sends to
// OpenRouter. Every choice here is in service of one property: for
// identical inputs, `buildMessages` must return byte-identical output,
// forever -- that's what makes the stable prefix (frozen instructions,
// context document, course profiles) eligible for whatever prompt caching
// the chosen provider offers. See the iOS-side `AssistantContextDocument`
// doc comment (and the CLAUDE.md trap about it) for the fuller story of why
// this matters: a byte that varies for no reason anywhere in that prefix
// invalidates the cache for every byte after it, silently, with no error
// and no symptom except a bigger bill.
//
// Concretely, that rules out: reading the clock in here (the caller passes
// `askedAt` in explicitly, and it belongs after the cache boundary, in the
// per-turn user message -- not folded into the cached blocks), relying on
// `Object.keys` insertion order for the course-profiles JSON (Postgres
// `jsonb` does not promise a stable key order across reads, so this file
// sorts keys itself rather than trusting the input), and any
// non-deterministic iteration (`Set`, unsorted `Map`) over `courseIDs`. The
// same rule applies to `structureBlock` (_shared/catalog.ts), which is why
// that function sorts its own rows by `catalogCode` rather than trusting
// the order a Postgres query happened to return them in.

import { structureBlock, type CatalogCourseRow } from "./catalog.ts";

/** Ported near-verbatim from `ClaudeAssistantResponder.systemInstructions`
 *  (`LowHangingFruitUI/ClaudeAssistantResponder.swift:64-97`) -- same voice,
 *  same `<sources>COURSE|kind|detail; …</sources>` trailer contract the app
 *  already parses (`SourcesBlockSplitter`), extended with one paragraph
 *  covering the course-profiles block this backend adds that the iOS-direct
 *  Anthropic path never had. A `const`, never template-interpolated, for
 *  the caching reason above -- the exact discipline the Swift source's own
 *  comment on this string documents.
 */
export const SYSTEM_INSTRUCTIONS: string = [
  `You are the "ask" assistant inside Low Hanging Fruit, a Penn student's `
  + `personal academic dashboard. You will be given a document containing `
  + `everything the app currently holds about the student's classes — `
  + `syllabi, deadlines, announcements — followed by a COURSE PROFILES `
  + `block of structured facts extracted from those syllabi, followed by `
  + `the student's question.`,

  `Answer only from that document and the course profiles. Do not use `
  + `outside knowledge of Penn, these courses, or their policies, and do `
  + `not guess at a number, date or rule neither source states. If the `
  + `document doesn't answer the question, say plainly that you don't have `
  + `that, and suggest what you do have that's close.`,

  `Write the way a classmate who actually read the syllabus would: the `
  + `answer up front, the exception or caveat second, no restating the `
  + `question, no "As an AI" framing.`,

  `The COURSE PROFILES block is structured data pulled mechanically from `
  + `each course's syllabus — grading weights, late and attendance `
  + `policies, exam dates, office hours, contacts, textbooks. Treat it as `
  + `reliable, but the document's own prose may be more current or more `
  + `detailed; prefer the document when the two disagree. Its keys are `
  + `site labels, not bare course codes — a course split across a lecture `
  + `Canvas site and a lab Canvas site has one profile keyed to each `
  + `(e.g. "PHYS 0151 — lecture site (section 401)" and "PHYS 0151 — lab `
  + `site (section 151)"); answer a "class" or "lecture" question from the `
  + `lecture site's profile and a "lab" question from the lab site's, and `
  + `say which site your answer came from when a course has more than one.`,

  `A COURSE STRUCTURE block, when present, comes from the Penn registrar, `
  + `not the professor, and lists each course's components — a Canvas `
  + `course site can bundle more than one, such as a 1.0 CU lecture plus a `
  + `0.5 CU lab under one course code. When a course has more than one `
  + `component, say which component your answer is about rather than `
  + `speaking of "the class" as if it were one undifferentiated thing. `
  + `Treat "the class" or "lecture" as asking about the lecture component `
  + `and "the lab" as asking about the lab component. Retrieved excerpts `
  + `are sometimes labelled [lab] or [lecture] by the app; when they are, `
  + `prefer the label matching the question, and never state a lab-specific `
  + `rule (grading, attendance, late work) as if it were the whole course's `
  + `rule without saying it's the lab's.`,

  `The student's message may also carry a RETRIEVED EXCERPTS section: `
  + `short passages from their course materials (syllabus prose, `
  + `announcements, assignment descriptions, course pages) that the app `
  + `matched to the question. Treat those excerpts as part of the `
  + `document, and prefer them for any policy question — they are the only `
  + `place attendance, late-work and office-hours text can appear in full. `
  + `An excerpt labelled [website] comes from the course's own external `
  + `website (its syllabus, schedule or policy pages, not Canvas) — treat `
  + `it as every bit as authoritative as the syllabus itself, not as a `
  + `secondary or unofficial source.`,

  `If your answer relies on specific facts from the document, end it with `
  + `a line of its own — nothing else on that line, nothing after it — in `
  + `exactly this form:\n`
  + `<sources>COURSE|kind|detail; COURSE|kind|detail</sources>\n`
  + `COURSE is the course code as it appears in the document, such as `
  + `"PHYS 0151". kind is one short lowercase word: syllabus, canvas, `
  + `website, or announcement — use "website" for a fact drawn from the `
  + `course's own external website rather than Canvas. detail is a few `
  + `words locating the fact, such as "§4 `
  + `attendance, p.2". Separate multiple sources with "; ". If nothing in `
  + `your answer traces back to a specific cited fact, omit the <sources> `
  + `block entirely — never emit an empty or invented one.`,
].join("\n\n");

export type ChatRole = "system" | "user" | "assistant";

export interface ChatMessage {
  role: ChatRole;
  content: string;
}

export interface HistoryTurn {
  role: "user" | "assistant";
  content: string;
}

export interface BuildMessagesInput {
  /** The rendered, byte-stable `AssistantContext.contextDocument`. */
  contextDocument: string;
  /** `catalog_courses` rows reachable from the caller's `courseIDs` through
   *  `courses.catalog_code` (see `_shared/db.ts`'s
   *  `selectCatalogCoursesForCourseIDs`). May be `[]` -- a course with no
   *  resolved catalog code, or one Penn Labs has never successfully
   *  answered for, simply contributes nothing here rather than blocking
   *  the rest of the prompt. */
  catalog: CatalogCourseRow[];
  /** Site label (`_shared/catalog.ts`'s `siteLabel`, e.g. "PHYS 0151 —
   *  lecture site (section 401)") -> profile JSON (or `null`), one entry
   *  per enrolled Canvas course the caller resolved. Keyed by label
   *  rather than bare course code so a course split across a lecture
   *  Canvas site and a lab Canvas site carries two distinct entries
   *  instead of one clobbering the other -- see
   *  `20260908090000_course_section.sql` and the SYSTEM_INSTRUCTIONS
   *  paragraph above this block feeds. `ask/index.ts`'s
   *  `loadCourseProfiles` is responsible for excluding courses the caller
   *  isn't enrolled in before this is ever called; this function trusts
   *  its input. */
  profiles: Record<string, unknown>;
  /** Prior turns, oldest first. May be `[]`. */
  history: HistoryTurn[];
  /** Rendered RETRIEVED EXCERPTS block, or `""`. */
  excerpts: string;
  question: string;
  /** ISO 8601 instant the question was asked, exactly as the client sent
   *  it -- never re-derived from `new Date()` here, which is the whole
   *  point (see the module doc comment). */
  askedAt: string;
}

const MAX_HISTORY_TURNS = 10;
const MAX_HISTORY_CHARS = 8000;
const MAX_QUESTION_CHARS = 2000;

export function buildMessages(input: BuildMessagesInput): ChatMessage[] {
  const messages: ChatMessage[] = [];

  messages.push({ role: "system", content: SYSTEM_INSTRUCTIONS });
  messages.push({ role: "system", content: input.contextDocument });

  // Inserted after the context document and before the course-profiles
  // block per the catalog delegation brief -- the registrar's view of a
  // course's shape (does it even have a lab?) is more fundamental than the
  // syllabus-derived profile facts that follow it, but still belongs after
  // the context document itself, which is the single most authoritative
  // source this prompt has. Only added when there's something to say --
  // an empty `structureBlock` (no course in `courseIDs` resolved a catalog
  // code, or none has been fetched yet) would otherwise add a header with
  // nothing under it, all cached-prefix cost for zero information.
  //
  // Deduped by `catalogCode` before rendering: a multi-site course (PHYS
  // 0151's lecture site and lab site, see the section-column migration)
  // resolves the *same* `catalog_courses` row from more than one enrolled
  // Canvas course id, and `input.catalog` is one row per resolved Canvas
  // course id, not per unique registrar code -- without this dedupe, a
  // student enrolled in both of PHYS 0151's sites would see "PHYS-0151"
  // described twice in one COURSE STRUCTURE block, identically, which is
  // both wasted prefix and reads as a copy-paste bug rather than the two
  // sites the COURSE PROFILES block below already distinguishes by label.
  const structure = structureBlock(dedupeByCatalogCode(input.catalog));
  if (structure.length > 0) {
    messages.push({
      role: "system",
      content: `COURSE STRUCTURE (from the Penn registrar via Penn Labs):\n${structure}`,
    });
  }

  messages.push({
    role: "system",
    content: `COURSE PROFILES (extracted from syllabi):\n${stableStringify(input.profiles)}`,
  });

  for (const turn of capHistory(input.history)) {
    messages.push({ role: turn.role, content: turn.content });
  }

  const question = input.question.slice(0, MAX_QUESTION_CHARS);
  const head = `Current date: ${input.askedAt}`;
  const userContent = input.excerpts.length > 0
    ? `${head}\n\n${input.excerpts}\n\nQUESTION: ${question}`
    : `${head}\n\nQUESTION: ${question}`;
  messages.push({ role: "user", content: userContent });

  return messages;
}

/**
 * Collapses `rows` to at most one `CatalogCourseRow` per unique
 * `catalogCode`, keeping the first occurrence of each -- the fix for the
 * multi-site duplication `buildMessages` documents at its own call site
 * above. First-occurrence rather than "merge" because every row for a
 * given `catalogCode` reaching this function is, by construction, the
 * exact same `catalog_courses` row read twice (once per Canvas course id
 * that resolved to it) -- there is nothing to merge, only a duplicate to
 * drop. Order of the surviving rows follows `rows`' own order;
 * `structureBlock` sorts by `catalogCode` itself regardless, so this
 * function doesn't need to.
 */
function dedupeByCatalogCode(rows: CatalogCourseRow[]): CatalogCourseRow[] {
  const seen = new Set<string>();
  const deduped: CatalogCourseRow[] = [];
  for (const row of rows) {
    if (seen.has(row.catalogCode)) continue;
    seen.add(row.catalogCode);
    deduped.push(row);
  }
  return deduped;
}

/**
 * Keeps the most recent turns, then drops whole turns from the *oldest* end
 * until the remaining turns' combined content fits `MAX_HISTORY_CHARS`.
 * Dropping whole turns rather than truncating one turn's text mid-sentence
 * keeps every turn that does make it into the prompt coherent -- a half a
 * message reads as a non-sequitur to the model, where a missing early turn
 * just reads as "the conversation started a bit later than it really did",
 * which is a far smaller distortion. At least one turn (the most recent) is
 * always kept even if it alone exceeds the budget, so a single very long
 * last turn is never silently dropped to zero.
 */
function capHistory(history: HistoryTurn[]): HistoryTurn[] {
  const recent = history.slice(-MAX_HISTORY_TURNS);
  let total = recent.reduce((sum, turn) => sum + turn.content.length, 0);
  let start = 0;
  while (total > MAX_HISTORY_CHARS && start < recent.length - 1) {
    total -= recent[start].content.length;
    start += 1;
  }
  return recent.slice(start);
}

/**
 * `JSON.stringify` with every object's keys sorted, recursively. Array
 * order is left alone -- arrays are already ordered data (the profile
 * schema's `gradingWeights`, `examDates`, etc. are meaningfully ordered
 * lists, not sets), it's only object *key* order that `jsonb` and
 * `JSON.parse` don't promise to preserve.
 *
 * Exported so `_shared/announcement.ts`'s `courseProfileBlock` can render
 * its own (smaller) subset of a course profile with the same
 * jsonb-key-order-independence this file needs for its own COURSE
 * PROFILES block -- one stable-stringify implementation, not two that
 * could drift.
 */
export function stableStringify(value: unknown): string {
  if (value === null || typeof value !== "object") {
    return JSON.stringify(value);
  }
  if (Array.isArray(value)) {
    return `[${value.map(stableStringify).join(",")}]`;
  }
  const record = value as Record<string, unknown>;
  const keys = Object.keys(record).sort();
  const body = keys
    .map((key) => `${JSON.stringify(key)}:${stableStringify(record[key])}`)
    .join(",");
  return `{${body}}`;
}
