// The streamed "ask" endpoint. PROTOCOL.md's "ask" section is the contract;
// see there for the request/response shapes and the quota rules. This file
// wires together, in order: auth, request validation, quota check, loading
// the caller's course profiles, building the prompt, and streaming the
// model's answer back as SSE -- deferring almost all of the actual logic to
// `_shared/*`, which is what makes each piece independently testable
// without a live Supabase project or OpenRouter key.
//
// Nothing here ever logs the question, the context document, the excerpts,
// or the model's answer -- only status codes and token counts, per the
// module's brief and the same discipline `ClaudeAssistantResponder` already
// holds itself to on the iOS side for exactly the same data.
import type { SupabaseClient } from "@supabase/supabase-js";
import { HttpError, corsHeaders, errorResponse, json, readJSON } from "../_shared/http.ts";
import { requireUser } from "../_shared/auth.ts";
import { checkQuota, limitsFromEnv } from "../_shared/quota.ts";
import { buildMessages, type HistoryTurn } from "../_shared/prompt.ts";
import { chatCompletionStream, type StreamEvent, UpstreamError } from "../_shared/openrouter.ts";
import { streamResponse, type SSEEvent } from "../_shared/sse.ts";

interface AskRequestBody {
  question: string;
  contextDocument: string;
  excerpts: string;
  askedAt: string;
  courseIDs: string[];
  history: HistoryTurn[];
}

function isHistoryTurn(value: unknown): value is HistoryTurn {
  if (typeof value !== "object" || value === null) return false;
  const turn = value as Record<string, unknown>;
  return (turn.role === "user" || turn.role === "assistant") && typeof turn.content === "string";
}

function parseAskRequestBody(value: unknown): AskRequestBody | undefined {
  if (typeof value !== "object" || value === null) return undefined;
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
    return undefined;
  }
  return {
    question: body.question,
    contextDocument: body.contextDocument,
    excerpts: body.excerpts,
    askedAt: body.askedAt,
    courseIDs: body.courseIDs,
    history: body.history,
  };
}

const MAX_TOKENS = 1200;
const TEMPERATURE = 0.2;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const { userId, serviceClient } = await requireUser(req);
    const rawBody = await readJSON<unknown>(req);
    const body = parseAskRequestBody(rawBody);
    if (!body) {
      return errorResponse("bad_request", "malformed ask request", 400);
    }

    const quotaResponse = await checkAskQuota(serviceClient, userId);
    if (quotaResponse) return quotaResponse;

    const profiles = await loadCourseProfiles(serviceClient, userId, body.courseIDs);

    const messages = buildMessages({
      contextDocument: body.contextDocument,
      profiles,
      history: body.history,
      excerpts: body.excerpts,
      question: body.question,
      askedAt: body.askedAt,
    });

    const model = Deno.env.get("LHF_MODEL") ?? "z-ai/glm-5.3-flash";
    const fallbackModel = Deno.env.get("LHF_FALLBACK_MODEL") ?? "openai/gpt-5.6-luna";
    const apiKey = Deno.env.get("OPENROUTER_API_KEY");
    if (!apiKey) {
      console.error("ask: OPENROUTER_API_KEY is not configured");
      return errorResponse("upstream", "model backend is not configured", 502);
    }

    const upstream = chatCompletionStream({
      fetchImpl: fetch,
      apiKey,
      model,
      fallbackModel,
      messages,
      provider: providerFromEnv(),
      maxTokens: MAX_TOKENS,
      temperature: TEMPERATURE,
    });
    const iterator = upstream[Symbol.asyncIterator]();

    // Pull the first chunk *before* committing to a streaming response.
    // PROTOCOL.md draws the line at whether any `delta` has reached the
    // student yet: an upstream failure before that point is a plain 502
    // JSON response, and only a failure after streaming has begun becomes
    // a mid-stream `error` event. Fetching one item here is what lets this
    // handler tell the two cases apart -- once `streamResponse` is called,
    // the HTTP status and headers are already committed.
    let first: IteratorResult<StreamEvent>;
    try {
      first = await iterator.next();
    } catch (err) {
      logUpstreamFailure("before first chunk", err);
      return errorResponse("upstream", "the model backend failed", 502);
    }

    return streamResponse(runAskStream(iterator, first, serviceClient, userId));
  } catch (err) {
    if (err instanceof HttpError) {
      return errorResponse("unauthorized", err.message, err.status);
    }
    console.error("ask: unhandled failure", err);
    return errorResponse("bad_request", "request failed", 400);
  }
});

async function checkAskQuota(
  serviceClient: SupabaseClient,
  userId: string,
): Promise<Response | undefined> {
  const { data, error } = await serviceClient.rpc("ask_usage_counts", { p_user_id: userId });
  if (error) {
    console.error("ask: ask_usage_counts failed", error.message);
    return errorResponse("upstream", "usage lookup failed", 502);
  }
  const row = Array.isArray(data) ? data[0] : data;
  const limits = limitsFromEnv(Deno.env);
  const quota = checkQuota({
    todayRequests: row?.today_requests ?? 0,
    monthRequests: row?.month_requests ?? 0,
    dailyLimit: limits.dailyLimit,
    monthlyGlobalLimit: limits.monthlyGlobalLimit,
    now: new Date(),
  });
  if (!quota.allowed) {
    return json(429, { error: "quota_exceeded", resetAt: quota.resetAt.toISOString() });
  }
  return undefined;
}

/**
 * Resolves `courseIDs` to `{ courseID: profile }` for only the courses
 * `userId` is actually enrolled in, silently ignoring any id in the
 * request the caller isn't enrolled in (per PROTOCOL.md's recorded
 * limitation: enrollment is asserted by the client, so this is the one
 * place the server can still refuse to hand back another course's
 * profile). Two queries rather than one join because `serviceClient` runs
 * as `service_role` and bypasses RLS entirely -- the enrollment check has
 * to happen in application code here, not by relying on the database
 * policies that gate the `authenticated` role.
 */
async function loadCourseProfiles(
  serviceClient: SupabaseClient,
  userId: string,
  courseIDs: string[],
): Promise<Record<string, unknown>> {
  if (courseIDs.length === 0) return {};

  const { data: enrollments, error: enrollError } = await serviceClient
    .from("enrollments")
    .select("course_id")
    .eq("user_id", userId)
    .in("course_id", courseIDs);
  if (enrollError || !enrollments) {
    console.error("ask: enrollments lookup failed", enrollError?.message);
    return {};
  }

  const enrolledIDs = enrollments.map((row: { course_id: string }) => row.course_id);
  if (enrolledIDs.length === 0) return {};

  const { data: profileRows, error: profileError } = await serviceClient
    .from("course_profiles")
    .select("course_id, profile")
    .in("course_id", enrolledIDs);
  if (profileError || !profileRows) {
    console.error("ask: course_profiles lookup failed", profileError?.message);
    return {};
  }

  const profiles: Record<string, unknown> = {};
  for (const row of profileRows as Array<{ course_id: string; profile: unknown }>) {
    profiles[row.course_id] = row.profile;
  }
  return profiles;
}

function providerFromEnv(): { order?: string[] } | undefined {
  const raw = Deno.env.get("LHF_PROVIDER_ORDER");
  if (!raw) return undefined;
  const order = raw.split(",").map((entry) => entry.trim()).filter((entry) => entry.length > 0);
  return order.length > 0 ? { order } : undefined;
}

function logUpstreamFailure(when: string, err: unknown): void {
  const status = err instanceof UpstreamError ? err.status : undefined;
  console.error("ask: upstream failure", when, "status:", status ?? "network");
}

/**
 * The actual SSE body. Takes the already-fetched `first` result so the
 * caller above can inspect it (to decide 502-vs-stream) without this
 * generator re-requesting it and silently dropping a chunk.
 */
async function* runAskStream(
  iterator: AsyncIterator<StreamEvent>,
  first: IteratorResult<StreamEvent>,
  serviceClient: SupabaseClient,
  userId: string,
): AsyncGenerator<SSEEvent> {
  let promptTokens = 0;
  let completionTokens = 0;
  let cachedTokens = 0;
  let current = first;

  try {
    while (!current.done) {
      const event = current.value;
      if (event.type === "delta") {
        yield { type: "delta", text: event.text };
      } else if (event.type === "usage") {
        promptTokens = event.promptTokens;
        completionTokens = event.completionTokens;
        cachedTokens = event.cachedTokens;
      }
      current = await iterator.next();
    }
  } catch (err) {
    logUpstreamFailure("mid-stream", err);
    yield { type: "error", code: "upstream", message: "the model backend failed" };
    return;
  }

  yield { type: "done", usage: { promptTokens, completionTokens, cachedTokens } };

  // Recorded after the stream has already fully reached the student, and a
  // failure to record is only ever logged, never surfaced -- the answer
  // was already delivered and can't be un-sent, so the worst case here is
  // one under-counted request against the quota, not a broken response.
  const { error } = await serviceClient.rpc("record_ask_usage", {
    p_user_id: userId,
    p_prompt_tokens: promptTokens,
    p_completion_tokens: completionTokens,
  });
  if (error) {
    console.error("ask: record_ask_usage failed", error.message);
  }
}
