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
// holds itself to on the iOS side for exactly the same data. The
// `ask_outcomes` row this file now writes on every path holds the same
// discipline: `detail` is an error class/message, capped, never the
// question or the answer (`_shared/outcomes.ts` enforces the cap itself,
// belt-and-braces, rather than trusting every call site here to remember).
//
// The body of the handler is `handleAsk`, exported so `ask-canary/index.ts`
// can serve the identical logic with `allowProbeOverrides: true` -- a
// canary result is only useful if it predicts production, which means it
// has to run through the exact same prompt-building, quota, and streaming
// code, not a parallel reimplementation that could drift.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { HttpError, corsHeaders, errorResponse, json, readJSON } from "../_shared/http.ts";
import { requireUser } from "../_shared/auth.ts";
import { limitsFromEnv, lookupUsageCounts, quotaDecision, recordUsage } from "../_shared/quota.ts";
import { buildMessages, type HistoryTurn } from "../_shared/prompt.ts";
import { selectCatalogCoursesByCodes, selectCatalogCoursesForCourseIDs } from "../_shared/db.ts";
import { activityForSection, siteLabel, type CatalogCourseRow } from "../_shared/catalog.ts";
import { chatCompletionStream, type StreamEvent, UpstreamError } from "../_shared/openrouter.ts";
import { streamResponse, type SSEEvent } from "../_shared/sse.ts";
import { applyContextTrim, extractProbeOverrides, readProbeTag } from "../_shared/probe.ts";
import { classifyStreamOutcome, recordOutcome } from "../_shared/outcomes.ts";

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

const MAX_TOKENS = 3000;
const TEMPERATURE = 0.2;

/** Supabase Edge Runtime's background-task API: registering a promise here
 *  tells the runtime to keep this isolate alive until the promise settles,
 *  independent of whether the HTTP response has already finished streaming
 *  to the client. Not part of the `Deno` namespace, so it isn't in the
 *  standard type definitions this project checks against -- declared
 *  ambiently here rather than pulled from a types package that may not
 *  exist for it. See `scheduleBackground`'s comment for why this matters
 *  and what the wrong fix looked like. */
declare const EdgeRuntime: { waitUntil(promise: Promise<unknown>): void } | undefined;

/**
 * Fires `promise` without making the caller wait for it, registering it
 * with `EdgeRuntime.waitUntil` when that's available so the isolate isn't
 * torn down before it settles. This is the fix for a real bug: the
 * previous version of this file `await`ed `recordUsage` *after*
 * `yield done`, on the theory that the SSE response had already fully
 * reached the client by then, so a slow write only delayed closing the
 * stream. That reasoning doesn't hold on Supabase's Edge Runtime
 * specifically -- once `_shared/sse.ts`'s `streamResponse` has nothing left
 * to pull from this generator, the client can finish reading and the
 * runtime is free to tear the isolate down, and there is no guarantee an
 * `await` sitting after the generator's last `yield` gets to run before
 * that happens. `EdgeRuntime.waitUntil` is Supabase's answer to exactly
 * this. `recordUsage`/`recordOutcome` never throw (both hold themselves to
 * the same fail-open discipline PROTOCOL.md's quota section describes), so
 * there's nothing to catch here; the fallback branch (no `EdgeRuntime`, in
 * a local `supabase functions serve` or any future runtime that doesn't
 * provide it) is still correct because calling an async function already
 * starts it running -- `scheduleBackground` not registering it with
 * anything just means there's no isolate-lifetime guarantee beyond
 * whatever the surrounding process already gives every other in-flight
 * promise.
 */
function scheduleBackground(promise: Promise<unknown>): void {
  if (typeof EdgeRuntime !== "undefined" && typeof EdgeRuntime.waitUntil === "function") {
    EdgeRuntime.waitUntil(promise);
  }
}

export async function handleAsk(
  req: Request,
  options: { allowProbeOverrides: boolean },
): Promise<Response> {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  const startedAt = Date.now();
  // Independent of `allowProbeOverrides`: tagging an outcome row doesn't
  // change how the request is served, so production `ask` honors it too --
  // a harness pointed at production (rather than `ask-canary`) can still
  // mark its own traffic. See `_shared/probe.ts`'s doc comment.
  const probeTag = readProbeTag(req);

  try {
    const { userId, serviceClient } = await requireUser(req);
    const rawBody = await readJSON<unknown>(req);
    const body = parseAskRequestBody(rawBody);

    // Only ever non-`undefined` when `options.allowProbeOverrides` is true
    // (i.e. this is `ask-canary`, never production `ask`) -- see
    // `_shared/probe.ts`'s `extractProbeOverrides`.
    const probeOverrides = extractProbeOverrides(rawBody, options.allowProbeOverrides);
    const model = probeOverrides?.model ?? Deno.env.get("LHF_MODEL") ?? "z-ai/glm-5.3-flash";
    const fallbackModel = Deno.env.get("LHF_FALLBACK_MODEL") ?? "openai/gpt-5.6-luna";

    if (!body) {
      scheduleBackground(recordOutcome(serviceClient, {
        userId,
        model,
        outcome: "client_error",
        detail: "malformed ask request",
        latencyMs: Date.now() - startedAt,
        probe: probeTag,
      }));
      return errorResponse("bad_request", "malformed ask request", 400);
    }

    const quotaResponse = await checkAskQuota(serviceClient, userId);
    if (quotaResponse) {
      scheduleBackground(recordOutcome(serviceClient, {
        userId,
        model,
        outcome: "quota",
        latencyMs: Date.now() - startedAt,
        probe: probeTag,
      }));
      return quotaResponse;
    }

    const enrolledIDs = await loadEnrolledCourseIDs(serviceClient, userId, body.courseIDs);
    const profiles = await loadCourseProfiles(serviceClient, enrolledIDs);
    const catalog = await loadCatalogCourses(serviceClient, enrolledIDs);

    // `contextTrimChars` is the one override that lets a canary harness
    // reproduce the 2026-09-14 "reasoning ate the whole cap" shape at a
    // prompt size it picks, without needing a real 14.5k-token syllabus
    // fixture lying around. A no-op (returns `contextDocument` unchanged)
    // whenever the probe didn't ask for it, including in production, where
    // `probeOverrides` itself is always `undefined`.
    const contextDocument = applyContextTrim(body.contextDocument, probeOverrides?.contextTrimChars);

    const messages = buildMessages({
      contextDocument,
      catalog,
      profiles,
      history: body.history,
      excerpts: body.excerpts,
      question: body.question,
      askedAt: body.askedAt,
    });

    const apiKey = Deno.env.get("OPENROUTER_API_KEY");
    if (!apiKey) {
      console.error("ask: OPENROUTER_API_KEY is not configured");
      scheduleBackground(recordOutcome(serviceClient, {
        userId,
        model,
        outcome: "upstream_error",
        detail: "OPENROUTER_API_KEY is not configured",
        latencyMs: Date.now() - startedAt,
        probe: probeTag,
      }));
      return errorResponse("upstream", "model backend is not configured", 502);
    }

    const upstream = chatCompletionStream({
      fetchImpl: fetch,
      apiKey,
      model,
      fallbackModel,
      messages,
      provider: providerFromEnv(),
      providerOverride: probeOverrides?.provider,
      maxTokens: probeOverrides?.maxTokens ?? MAX_TOKENS,
      temperature: probeOverrides?.temperature ?? TEMPERATURE,
      // `ask` answers from the context document and excerpts it was already
      // handed, not by reasoning the problem out -- and `model` is a
      // thinking model that otherwise spends output tokens on hidden
      // `delta.reasoning` before ever emitting `delta.content`. On
      // 2026-09-14 a real 14.5k-token prompt reasoned until the then-1200
      // `max_tokens` cap and answered with nothing. The fix that shipped
      // the same day, `reasoning: { enabled: false }`, was rejected by
      // OpenRouter (or the provider behind it) with a 400 on the very
      // first live call, so production `ask` still leaves `reasoning`
      // unset here (`probeOverrides` is always `undefined` in production,
      // so this is always `undefined` too) -- see
      // `_shared/openrouter.ts`'s `ChatCompletionStreamOptions.reasoning`
      // and `buildRequestBody`, which forward whatever shape is given
      // verbatim now, for `ask-canary` to try other shapes against without
      // a code change here. Raising `MAX_TOKENS` to 3000 here is the
      // interim measure so a prompt that reasons *and* answers has room
      // for both; turning reasoning off again, once a shape is found that
      // OpenRouter accepts, is the intended end state, not this cap --
      // `ask_outcomes.reasoning_tokens` (recorded below) is what will show
      // when that's actually needed anymore.
      reasoning: probeOverrides?.reasoning,
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
      scheduleBackground(recordOutcome(serviceClient, {
        userId,
        model,
        outcome: "upstream_error",
        upstreamStatus: err instanceof UpstreamError ? err.status : undefined,
        detail: describeUpstreamError(err),
        latencyMs: Date.now() - startedAt,
        probe: probeTag,
      }));
      return errorResponse("upstream", "the model backend failed", 502);
    }

    return streamResponse(runAskStream(iterator, first, serviceClient, userId, {
      model,
      startedAt,
      probe: probeTag,
    }));
  } catch (err) {
    if (err instanceof HttpError) {
      return errorResponse("unauthorized", err.message, err.status);
    }
    console.error("ask: unhandled failure", err);
    return errorResponse("bad_request", "request failed", 400);
  }
}

// Guarded by `import.meta.main` rather than called unconditionally: this
// file is also *imported* (for `handleAsk`) by `ask-canary/index.ts`, and
// an unconditional `Deno.serve` call here would then run a second time
// inside the canary function's own isolate the moment that import
// executes -- two `Deno.serve()` calls with no explicit port both try to
// bind the same default address, and the second one fails outright. Real
// deployed `ask` (where this file *is* the entrypoint the runtime
// executes directly) still calls this exactly as before -- `import.meta
// .main` is `true` there and only there, so production behavior is
// unchanged; the canary's own `Deno.serve` call in its own `index.ts` is
// what actually serves that function.
if (import.meta.main) {
  Deno.serve((req) => handleAsk(req, { allowProbeOverrides: false }));
}

async function checkAskQuota(
  serviceClient: SupabaseClient,
  userId: string,
): Promise<Response | undefined> {
  const lookup = await lookupUsageCounts(serviceClient, userId);
  if (!lookup.ok) {
    // Fail open -- see quota.ts's module comment and PROTOCOL.md's quota
    // section for the 2026-09-13 incident this guards against. A stalled
    // counter must never turn into a dead "ask" for the student in front
    // of it.
    console.warn(`ask: quota lookup ${lookup.reason}, failing open: ${lookup.message}`);
  }
  const decision = quotaDecision(lookup, limitsFromEnv(Deno.env), new Date());
  if (!decision.allowed) {
    return json(429, { error: "quota_exceeded", resetAt: decision.resetAt.toISOString() });
  }
  return undefined;
}

/**
 * Resolves the request's `courseIDs` down to the subset `userId` is
 * actually enrolled in, silently dropping any id the caller isn't
 * enrolled in (per PROTOCOL.md's recorded limitation: enrollment is
 * asserted by the client, so this is the one place the server can still
 * refuse to hand back another course's data). Both `loadCourseProfiles`
 * and `loadCatalogCourses` below are handed this same already-checked
 * list rather than each re-deriving it, and each trusts it rather than
 * re-checking enrollment itself -- one place decides who's enrolled in
 * what for this request, not two that could drift apart.
 */
async function loadEnrolledCourseIDs(
  serviceClient: SupabaseClient,
  userId: string,
  courseIDs: string[],
): Promise<string[]> {
  if (courseIDs.length === 0) return [];

  const { data: enrollments, error: enrollError } = await serviceClient
    .from("enrollments")
    .select("course_id")
    .eq("user_id", userId)
    .in("course_id", courseIDs);
  if (enrollError || !enrollments) {
    console.error("ask: enrollments lookup failed", enrollError?.message);
    return [];
  }

  return enrollments.map((row: { course_id: string }) => row.course_id);
}

/**
 * `{ label: profile }` for `enrolledIDs`, one entry per enrolled Canvas
 * course id -- not one per registrar course -- keyed by
 * `_shared/catalog.ts`'s `siteLabel` rather than the bare course code so
 * that a course split across a lecture Canvas site and a lab Canvas site
 * (PHYS 0151's two sites, see `20260908090000_course_section.sql`) gets
 * two distinct entries instead of one clobbering the other under a
 * shared `"PHYS 0151"` key. Resolving each course's label needs its own
 * `courses` row (`code`, `section`, `catalog_code`) plus, when a
 * `catalog_code` resolved, that code's `catalog_courses` row (to turn a
 * bare section number into "lecture"/"lab" via `activityForSection`) --
 * three queries total (courses, the catalog rows their codes point at,
 * course_profiles), all scoped to `enrolledIDs`/the codes those rows
 * resolve to, none joined, for the same "`serviceClient` is service_role
 * and bypasses RLS so there's no policy doing this join for us" reason
 * every other multi-table read in this backend is written as separate
 * queries. A lookup failure on any of the three degrades that piece
 * (no label refinement, or no profile) rather than failing the whole
 * request -- consistent with every other best-effort fallback `ask`
 * already takes toward missing profile/catalog data.
 *
 * Every enrolled course id gets an entry, whether or not it has an
 * extracted profile yet (a fresh sync, or a course whose material hasn't
 * cleared `extract-profile`) -- the entry's `profile` is `null` in that
 * case rather than the course being absent, so the model still sees that
 * a lecture site and a lab site both exist even before either has a
 * profile of its own.
 */
async function loadCourseProfiles(
  serviceClient: SupabaseClient,
  enrolledIDs: string[],
): Promise<Record<string, unknown>> {
  if (enrolledIDs.length === 0) return {};

  const { data: courseRows, error: courseError } = await serviceClient
    .from("courses")
    .select("course_id, code, section, catalog_code")
    .in("course_id", enrolledIDs);
  if (courseError || !courseRows) {
    console.error("ask: courses lookup failed", courseError?.message);
    return {};
  }
  const courses = courseRows as Array<{
    course_id: string;
    code: string;
    section: string | null;
    catalog_code: string | null;
  }>;

  const catalogCodes = [
    ...new Set(courses.map((row) => row.catalog_code).filter((code): code is string => code !== null)),
  ];
  let catalogByCode = new Map<string, CatalogCourseRow>();
  try {
    catalogByCode = await selectCatalogCoursesByCodes(serviceClient, catalogCodes);
  } catch (err) {
    console.error("ask: catalog lookup for profile labels failed", err instanceof Error ? err.message : String(err));
  }

  const { data: profileRows, error: profileError } = await serviceClient
    .from("course_profiles")
    .select("course_id, profile")
    .in("course_id", enrolledIDs);
  if (profileError) {
    console.error("ask: course_profiles lookup failed", profileError.message);
  }
  const profileByCourseID = new Map<string, unknown>();
  for (const row of (profileRows ?? []) as Array<{ course_id: string; profile: unknown }>) {
    profileByCourseID.set(row.course_id, row.profile);
  }

  const profiles: Record<string, unknown> = {};
  for (const row of courses) {
    const catalogRow = row.catalog_code ? catalogByCode.get(row.catalog_code) : undefined;
    const activity = row.section && catalogRow ? activityForSection(catalogRow, row.section) : undefined;
    const label = siteLabel(row.code, row.section ?? undefined, activity);
    profiles[label] = profileByCourseID.get(row.course_id) ?? null;
  }
  return profiles;
}

/** `catalog_courses` rows reachable from `enrolledIDs` through
 *  `courses.catalog_code`, for `buildMessages`'s COURSE STRUCTURE block.
 *  A lookup failure degrades to an empty list rather than failing the
 *  whole request -- exactly `loadCourseProfiles`'s posture toward its own
 *  lookup failing, since a missing catalog block is a strictly smaller
 *  loss to the answer than a missing course-profiles block. */
async function loadCatalogCourses(
  serviceClient: SupabaseClient,
  enrolledIDs: string[],
): Promise<CatalogCourseRow[]> {
  try {
    return await selectCatalogCoursesForCourseIDs(serviceClient, enrolledIDs);
  } catch (err) {
    console.error("ask: catalog lookup failed", err instanceof Error ? err.message : String(err));
    return [];
  }
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
  if (err instanceof UpstreamError) {
    console.error("ask: upstream failure detail", err.message);
  }
}

/** `err.message` when it's an `UpstreamError` (which already carries
 *  OpenRouter's own rejection body, capped to 400 characters by
 *  `_shared/openrouter.ts`'s `readErrorBody`), otherwise any other
 *  `Error`'s message, otherwise its string form -- the same fallback chain
 *  `loadCatalogCourses`/`loadCourseProfiles` already use for an unknown
 *  thrown value. Feeds `ask_outcomes.detail`, which caps it again to 200
 *  characters (`_shared/outcomes.ts`), so this never needs to know that
 *  limit itself. */
function describeUpstreamError(err: unknown): string {
  return err instanceof Error ? err.message : String(err);
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
  telemetry: { model: string; startedAt: number; probe: string | null },
): AsyncGenerator<SSEEvent> {
  let promptTokens = 0;
  let completionTokens = 0;
  let cachedTokens = 0;
  let reasoningTokens: number | undefined;
  let deltaCount = 0;
  let contentChars = 0;
  let firstDeltaMs: number | undefined;
  let current = first;

  try {
    while (!current.done) {
      const event = current.value;
      if (event.type === "delta") {
        if (deltaCount === 0) {
          firstDeltaMs = Date.now() - telemetry.startedAt;
        }
        deltaCount += 1;
        contentChars += event.text.length;
        yield { type: "delta", text: event.text };
      } else if (event.type === "usage") {
        promptTokens = event.promptTokens;
        completionTokens = event.completionTokens;
        cachedTokens = event.cachedTokens;
        reasoningTokens = event.reasoningTokens;
      }
      current = await iterator.next();
    }
  } catch (err) {
    logUpstreamFailure("mid-stream", err);
    scheduleBackground(recordOutcome(serviceClient, {
      userId,
      model: telemetry.model,
      outcome: "upstream_error",
      promptTokens,
      completionTokens,
      reasoningTokens,
      cachedTokens,
      contentChars,
      deltaCount,
      latencyMs: Date.now() - telemetry.startedAt,
      firstDeltaMs,
      upstreamStatus: err instanceof UpstreamError ? err.status : undefined,
      detail: describeUpstreamError(err),
      probe: telemetry.probe,
    }));
    yield { type: "error", code: "upstream", message: "the model backend failed" };
    return;
  }

  // Reasoning is not turned off for `ask` right now (see the call site
  // above), so `completionTokens` nonzero while `deltaCount` is zero can
  // still happen if a prompt is large enough to exhaust the raised
  // `MAX_TOKENS` on reasoning alone -- this is the exact shape of the
  // 2026-09-14 incident, and worth knowing about the next time it
  // happens, rather than the student's empty answer being the only trace.
  // It now also lands as an `empty` row in `ask_outcomes` below, so this
  // log line is a live tail's warning, not the only record.
  if (deltaCount === 0) {
    console.warn(`ask: stream ended with no text; completion tokens ${completionTokens}`);
  }

  const outcome = classifyStreamOutcome({ contentChars, streamFailed: false });
  const latencyMs = Date.now() - telemetry.startedAt;

  // Scheduled as background work via `scheduleBackground`, and `done` is
  // yielded *after* both calls are made -- not after either has settled.
  // The previous version of this file `await`ed `recordUsage` after
  // `yield done`; see `scheduleBackground`'s doc comment above for why
  // that was the actual bug (Supabase's Edge Runtime is free to tear this
  // isolate down as soon as the client has read everything this generator
  // is ever going to produce, which can be before an `await` placed after
  // the last `yield` ever runs) and why `EdgeRuntime.waitUntil` -- not
  // simply moving these two calls earlier and awaiting them before
  // `yield done` -- is the fix: awaiting them here would delay the
  // student's `done` event, and therefore their answer finishing render,
  // by however long two RPC round-trips take, for telemetry they get
  // nothing from.
  scheduleBackground(recordUsage(serviceClient, userId, promptTokens, completionTokens));
  scheduleBackground(recordOutcome(serviceClient, {
    userId,
    model: telemetry.model,
    outcome,
    promptTokens,
    completionTokens,
    reasoningTokens,
    cachedTokens,
    contentChars,
    deltaCount,
    latencyMs,
    firstDeltaMs,
    probe: telemetry.probe,
  }));

  yield { type: "done", usage: { promptTokens, completionTokens, cachedTokens } };
}
