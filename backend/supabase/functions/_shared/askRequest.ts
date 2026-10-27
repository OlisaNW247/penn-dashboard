// Parsing and size-capping of `ask`'s request body. This used to live inside
// `ask/index.ts` (still the only caller); it is here because this
// directory's tests exercise `_shared/*`, never a function's own `index.ts`
// (see `test/ask.test.ts`'s header), and the caps below are a spend control
// worth pinning with tests.
//
// Why there are caps at all. Everything in the body except `askedAt` and
// `courseIDs` is pasted straight into the prompt that LHF's own OpenRouter
// key pays for. `readJSON` bounds the whole body at 6 MB, which is a limit
// on memory, not on spend: a signed-in anonymous account (anyone can mint
// one) could send a 5 MB `contextDocument` forty times a day and the only
// thing between that and the bill was the daily request count. The caps
// below are deliberately generous. A real syllabus-sized prompt is about
// 14k tokens (roughly 56k characters of context document), so a ceiling of
// 400k characters is seven times that, and nothing the phone builds comes
// near it; the point is to refuse a body that is *a different kind of
// thing*, not to trim a heavy user. The wrong fix would have been a tight
// cap picked from today's typical size: the next student with twelve long
// syllabi would get a 413 from `ask` and silently fall back to the weaker
// on-device answer.
import type { HistoryTurn } from "./prompt.ts";

/** Characters, not bytes: the context document is the phone's byte-stable
 *  `AssistantContextDocument`. */
export const MAX_CONTEXT_DOCUMENT_CHARS = 400_000;
export const MAX_EXCERPTS_CHARS = 100_000;
/** The phone caps the question near 2,000 characters; this is the server's
 *  own ceiling, so a client that forgets can't use the question as the
 *  side door the other fields close. */
export const MAX_QUESTION_CHARS = 20_000;
/** `prompt.ts` keeps only the last ten turns, but still keeps the final one
 *  whole however long it is, so the turn count alone bounds nothing. */
export const MAX_HISTORY_TURNS_ACCEPTED = 40;
export const MAX_HISTORY_CHARS_ACCEPTED = 100_000;

export interface AskRequestBody {
  question: string;
  contextDocument: string;
  excerpts: string;
  askedAt: string;
  courseIDs: string[];
  history: HistoryTurn[];
}

export type AskRequestParse =
  | { ok: true; body: AskRequestBody }
  /** `malformed`: wrong shape, 400. `too_large`: right shape, over a cap,
   *  413 (the same status `readJSON` uses for an over-size body). `reason`
   *  names the field and is safe to log and return: it never contains any
   *  of the request's content. */
  | { ok: false; kind: "malformed" | "too_large"; reason: string };

function isHistoryTurn(value: unknown): value is HistoryTurn {
  if (typeof value !== "object" || value === null) return false;
  const turn = value as Record<string, unknown>;
  return (turn.role === "user" || turn.role === "assistant") && typeof turn.content === "string";
}

export function parseAskRequestBody(value: unknown): AskRequestParse {
  const malformed: AskRequestParse = { ok: false, kind: "malformed", reason: "malformed ask request" };
  if (typeof value !== "object" || value === null) return malformed;
  const body = value as Record<string, unknown>;
  if (
    typeof body.question !== "string" ||
    typeof body.contextDocument !== "string" ||
    typeof body.excerpts !== "string" ||
    typeof body.askedAt !== "string" ||
    !Array.isArray(body.courseIDs) ||
    !body.courseIDs.every((id): id is string => typeof id === "string") ||
    !Array.isArray(body.history) ||
    !body.history.every(isHistoryTurn)
  ) {
    return malformed;
  }

  const tooLarge = (field: string): AskRequestParse => ({
    ok: false,
    kind: "too_large",
    reason: `ask request over size cap: ${field}`,
  });
  if (body.question.length > MAX_QUESTION_CHARS) return tooLarge("question");
  if (body.contextDocument.length > MAX_CONTEXT_DOCUMENT_CHARS) return tooLarge("contextDocument");
  if (body.excerpts.length > MAX_EXCERPTS_CHARS) return tooLarge("excerpts");
  if (body.history.length > MAX_HISTORY_TURNS_ACCEPTED) return tooLarge("history turns");
  let historyChars = 0;
  for (const turn of body.history as HistoryTurn[]) {
    historyChars += turn.content.length;
    if (historyChars > MAX_HISTORY_CHARS_ACCEPTED) return tooLarge("history characters");
  }

  return {
    ok: true,
    body: {
      question: body.question,
      contextDocument: body.contextDocument,
      excerpts: body.excerpts,
      askedAt: body.askedAt,
      courseIDs: body.courseIDs,
      history: body.history as HistoryTurn[],
    },
  };
}
