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
import {
  outcomeDetailForFallback,
  outcomeDetailForHedgeWin,
  reasoningFor,
  remainingBudget,
  shouldStartHedge,
} from "../_shared/fallback.ts";

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

/**
 * `ask`'s default model was `z-ai/glm-5.3-flash`, an always-thinking model,
 * with `reasoning` left unset -- the 2026-09-14 incident (this file's
 * `ask_outcomes` telemetry exists because of it): on a real syllabus-sized
 * prompt it spent the whole `MAX_TOKENS` cap on hidden reasoning and
 * answered with nothing. `reasoning: { effort: "low" }` (this file briefly
 * carried that alone, keyed off `_shared/fallback.ts`'s `reasoningFor`) cut
 * the reasoning spend from ~300 tokens to ~6, but 2026-09-22 canary runs
 * against the live function found it doesn't touch the actual failure
 * mode: 30 timed probes still saw 12 take over 8s to first delta and one
 * take 66s, and several of the slow ones reported *zero* reasoning tokens
 * -- meaning the tail is provider time-to-first-token, not thinking, and no
 * `reasoning` setting fixes a queueing delay on OpenRouter's or the
 * provider's side. The owner's rule from those numbers is "never more than
 * a 10 second wait," which a `reasoning` tweak alone cannot promise.
 *
 * What's here instead: `openai/gpt-4.1-mini` is the default *primary*
 * model -- 10/10 canary probes between 1.9s and 3.0s to first delta,
 * correct about dates, no `reasoning` field at all (it isn't a thinking
 * model and has no use for one) -- and `z-ai/glm-5.3-flash` (still with
 * low-effort reasoning; see `reasoningFor`) is the *fallback*,
 * started **concurrently**, not after waiting the primary out, the moment
 * `HEDGE_AFTER_MS` passes with no content from the primary yet
 * (`runHedgedRace`, below). Whichever model produces the first content
 * delta wins and the other is aborted; a primary that fails or empties
 * outright before the hedge would even fire skips straight to the
 * fallback alone, with no race to run. Two things tried and rejected along
 * the way: cheaper/faster models (Gemini Flash/Flash-Lite, `glm-4.5-air`,
 * `deepseek-v3.1`) answered quickly but got a plain "what's due tomorrow?"
 * wrong, which rules them out on correctness rather than latency; and a
 * bare "wait a fixed timeout, then retry against a different model"
 * (this file's first version of this fix) only *adds* the timeout to the
 * student's wait instead of covering it, which a concurrent race does not.
 * `MAX_TOKENS` stays 3000: the fallback's answer, with low- or no-effort
 * reasoning, needs a few hundred of it, not the full cap the original
 * incident exhausted.
 */
const HEDGE_AFTER_MS = 5_000;

/** The phone's `URLSession` gives up on `ask` at 60s; this is the backend's
 *  own tighter budget on the pre-stream race in `runHedgedRace` (the
 *  primary alone, or the primary and the hedge together) so a race that
 *  never resolves still leaves this function time to answer with a plain
 *  502 rather than being cut off by the client with nothing said at all.
 *  It does not bound a stream that has already started -- once a winner is
 *  found and `runAskStream` is generating the response, there is no
 *  further time limit here beyond the client's own 60s. */
const TOTAL_BUDGET_MS = 45_000;

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

  // Per-step wall-clock timing, logged once per request. Added 2026-09-22
  // when a 50-run soak on the canary had one request take 10.2 s to its
  // first delta with the hedge never firing -- the hedge timer only
  // watches the model call, so the time had gone into the database reads
  // before it, and nothing measured them. Declared here, immediately after
  // `startedAt`, rather than further down past the quota check, so `auth`
  // and `parse` -- the two steps that run before this file has even seen
  // the request body -- can be timed too. Milliseconds only.
  const timing: Record<string, number> = {};
  const timed = async <T>(label: string, work: () => Promise<T>): Promise<T> => {
    const t0 = Date.now();
    try {
      return await work();
    } finally {
      timing[label] = Date.now() - t0;
    }
  };

  // `requireUser` (`_shared/auth.ts`) has no deadline of its own -- it
  // awaits GoTrue's `auth.getUser()` unbounded -- and its contract is
  // shared by five other edge functions (delete-account, discover-websites,
  // extract-announcement, extract-profile, map-categories, sync), so it is
  // not changed here; a 3s client-side race around the call, local to this
  // file, gets `ask` the same "never hang forever on auth" guarantee
  // without touching what those other five functions rely on. If
  // `requireUser` does eventually settle after the race has already timed
  // out, its result (or its own thrown `HttpError`) is simply discarded --
  // `.catch(() => {})` below exists only to keep that late settlement from
  // surfacing as an unhandled promise rejection in the isolate's logs.
  const AUTH_TIMEOUT_MS = 3000;
  const withAuthTimeout = <T>(promise: Promise<T>): Promise<T> => {
    let timer: number | undefined;
    const timeout = new Promise<never>((_, reject) => {
      timer = setTimeout(() => {
        promise.catch(() => {});
        reject(new HttpError(401, "unauthorized", `auth check exceeded ${AUTH_TIMEOUT_MS}ms deadline`));
      }, AUTH_TIMEOUT_MS);
    });
    return Promise.race([promise, timeout]).finally(() => clearTimeout(timer));
  };

  try {
    const { userId, serviceClient } = await timed("auth", () => withAuthTimeout(requireUser(req)));
    const rawBody = await timed("parse", () => readJSON<unknown>(req));
    const body = parseAskRequestBody(rawBody);

    // Only ever non-`undefined` when `options.allowProbeOverrides` is true
    // (i.e. this is `ask-canary`, never production `ask`) -- see
    // `_shared/probe.ts`'s `extractProbeOverrides`.
    const probeOverrides = extractProbeOverrides(rawBody, options.allowProbeOverrides);
    const model = probeOverrides?.model ?? Deno.env.get("LHF_MODEL") ?? "openai/gpt-4.1-mini";
    // `resolvedFallbackModel`/`fallbackDisabled`/`hedgeAfterMs` are resolved
    // once here so both branches of `runHedgedRace` (the immediate
    // sequential fallback when the primary fails or empties before the
    // hedge would fire, and the concurrent race once it does) agree on the
    // same model, the same on/off switch and the same timing -- computing
    // any of these twice risked a canary override landing in one path but
    // not the other.
    const resolvedFallbackModel = probeOverrides?.fallbackModel ?? Deno.env.get("LHF_ASK_FALLBACK_MODEL") ??
      "z-ai/glm-5.3-flash";
    // `probe.disableFallback` also turns off the hedge, not just the
    // sequential fallback -- a harness measuring the primary model alone
    // needs neither a second model finishing the job for it nor one racing
    // it partway through.
    const fallbackDisabled = probeOverrides?.disableFallback ?? false;
    const hedgeAfterMs = probeOverrides?.hedgeAfterMs ?? HEDGE_AFTER_MS;

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

    // The quota check and loading which of the request's `courseIDs` this
    // user is actually enrolled in are independent of each other -- neither
    // reads anything the other writes -- so they run concurrently rather
    // than back-to-back. This does not change the early-return semantics: a
    // 429 from `checkAskQuota` is still returned regardless of what
    // `loadEnrolledCourseIDs` came back with (its result is simply unused
    // and discarded on that path, a small wasted read rather than a
    // correctness risk).
    const [quotaResponse, enrolledIDs] = await Promise.all([
      timed("quota", () => checkAskQuota(serviceClient, userId)),
      timed("enrolled", () => loadEnrolledCourseIDs(serviceClient, userId, body.courseIDs)),
    ]);
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

    // Same reasoning as above: `loadCourseProfiles` and `loadCatalogCourses`
    // both depend only on `enrolledIDs`, not on each other, so they also run
    // concurrently.
    const [profiles, catalog] = await Promise.all([
      timed("profiles", () => loadCourseProfiles(serviceClient, enrolledIDs)),
      timed("catalog", () => loadCatalogCourses(serviceClient, enrolledIDs)),
    ]);

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

    // One shared builder for every model this request might call (the
    // primary, and the fallback whether it runs sequentially or hedged),
    // so the only things that ever differ between them are `forModel`,
    // `forReasoning` and `signal` -- never `messages`, `maxTokens`,
    // `temperature` or provider routing, which must stay identical for a
    // fallback or hedge-won answer to be trustworthy in the same way the
    // primary's would have been.
    const buildStreamOptions = (forModel: string, forReasoning: unknown, signal: AbortSignal) => ({
      fetchImpl: fetch,
      apiKey,
      model: forModel,
      messages,
      provider: providerFromEnv(),
      providerOverride: probeOverrides?.provider,
      maxTokens: probeOverrides?.maxTokens ?? MAX_TOKENS,
      temperature: probeOverrides?.temperature ?? TEMPERATURE,
      reasoning: forReasoning,
      signal,
    });

    // `probeOverrides?.reasoning` only ever overrides the *primary*
    // candidate's reasoning shape -- there is no equivalent field for the
    // fallback candidate specifically, since `reasoningFor` already gives
    // it the one shape that was actually measured (see the long comment on
    // `HEDGE_AFTER_MS` above), and a canary wanting to test the fallback
    // model's own reasoning shape can do that directly by pointing `model`
    // (not `fallbackModel`) at it.
    const raceStartedAt = Date.now();
    timing.preRace = raceStartedAt - startedAt;
    const race = await runHedgedRace({
      buildStreamOptions,
      primary: { model, reasoning: probeOverrides?.reasoning ?? reasoningFor(model) },
      fallback: fallbackDisabled ? undefined : { model: resolvedFallbackModel, reasoning: reasoningFor(resolvedFallbackModel) },
      hedgeAfterMs,
      totalBudgetMs: TOTAL_BUDGET_MS,
      startedAt,
    });

    timing.race = Date.now() - raceStartedAt;
    console.log(`ask: timing ${JSON.stringify(timing)}`);
    if (!race.ok) {
      logUpstreamFailure("before first chunk (race)", race.failure.cause);
      scheduleBackground(recordOutcome(serviceClient, {
        userId,
        model: race.failure.model,
        outcome: "upstream_error",
        upstreamStatus: race.failure.upstreamStatus,
        detail: race.failure.detail,
        latencyMs: Date.now() - startedAt,
        probe: probeTag,
        preRaceMs: timing.preRace,
        raceMs: timing.race,
      }));
      return errorResponse("upstream", "the model backend failed", 502);
    }

    return streamResponse(runAskStream(race.winner.iterator, race.winner.first, serviceClient, userId, {
      model: race.winner.model,
      startedAt,
      probe: probeTag,
      outcomeDetail: race.winner.detail,
      preRaceMs: timing.preRace,
      raceMs: timing.race,
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
 * caller above (`runHedgedRace`, by way of `handleAsk`) can inspect it to
 * decide 502-vs-stream without this generator re-requesting it and
 * silently dropping a chunk. `first` is always a content `delta` now --
 * `runHedgedRace` never hands back a winner that hasn't produced one, so
 * the whole "stream ran clean but said nothing" (`empty`) case is resolved
 * *before* this generator ever runs, not inside it -- the `deltaCount === 0`
 * check below is left in as a defensive belt-and-braces for a future caller
 * that changes what it hands in, but under `runHedgedRace` it should never
 * actually fire. `telemetry.outcomeDetail`, when set, is `runHedgedRace`'s
 * account of how
 * this particular stream was chosen (a hedge win, or a sequential fallback
 * after the primary failed or emptied) -- `undefined` for the ordinary case
 * of the primary winning outright, so an unremarkable request's outcome row
 * looks exactly as it did before any of this existed.
 */
async function* runAskStream(
  iterator: AsyncIterator<StreamEvent>,
  first: IteratorResult<StreamEvent>,
  serviceClient: SupabaseClient,
  userId: string,
  telemetry: {
    model: string;
    startedAt: number;
    probe: string | null;
    outcomeDetail?: string;
    preRaceMs?: number;
    raceMs?: number;
  },
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
      // A mid-stream failure after content had already reached the student
      // (`contentChars > 0`, guaranteed here since `first` is always a
      // delta) is never eligible for a fallback -- the race is long over by
      // the time this generator is even running -- so `outcomeDetail` is
      // folded in only to say *how this stream was chosen*, never to try
      // another model now.
      detail: telemetry.outcomeDetail
        ? `${telemetry.outcomeDetail}; then upstream_error: ${describeUpstreamError(err)}`.slice(0, 200)
        : describeUpstreamError(err),
      probe: telemetry.probe,
      preRaceMs: telemetry.preRaceMs,
      raceMs: telemetry.raceMs,
    }));
    yield { type: "error", code: "upstream", message: "the model backend failed" };
    return;
  }

  // `first` is always a content delta (see this function's doc comment), so
  // `deltaCount` is at least 1 by construction and this branch should be
  // unreachable in practice -- left as a defensive check, and worth an
  // alarmed log rather than a silent pass, exactly because reaching it
  // would mean the guarantee above stopped holding somewhere upstream.
  if (deltaCount === 0) {
    console.warn(`ask: stream ended with no text despite a delta first-event; completion tokens ${completionTokens}`);
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
    detail: telemetry.outcomeDetail,
    probe: telemetry.probe,
    preRaceMs: telemetry.preRaceMs,
    raceMs: telemetry.raceMs,
  }));

  yield { type: "done", usage: { promptTokens, completionTokens, cachedTokens } };
}

// ---------------------------------------------------------------------
// The hedged race
// ---------------------------------------------------------------------

interface RaceCandidate {
  model: string;
  reasoning: unknown;
}

interface RaceWinner {
  model: string;
  iterator: AsyncIterator<StreamEvent>;
  first: IteratorResult<StreamEvent>;
  /** `outcomeDetailForHedgeWin`/`outcomeDetailForFallback`'s output, or
   *  `undefined` when the primary answered on its own with no race and no
   *  fallback ever started -- the ordinary case, which should leave
   *  `ask_outcomes.detail` exactly as unremarkable as it was before any of
   *  this existed. */
  detail?: string;
}

interface RaceFailure {
  /** Whichever model actually ran last -- the fallback's, if one was ever
   *  started, since it is the model that had the last word on this
   *  request; the primary's alone otherwise. Neither model "produced the
   *  answer" in this branch (there is none), but `ask_outcomes.model` has
   *  no third option to mean that, and the last model tried is closer to
   *  the truth than the one this request started with. */
  model: string;
  detail: string;
  upstreamStatus?: number;
  cause: unknown;
}

/** One participant in the race: an already-started model call, its own
 *  `AbortController` (so the loser can be cancelled the instant a winner is
 *  found, or every participant cancelled once `totalBudgetMs` runs out),
 *  and whichever `.next()` call is currently outstanding for it. `pending`
 *  is `null` exactly when this racer has been removed from the race --
 *  either it produced the winning delta (moot, the race is over) or it
 *  exhausted (a clean end or a thrown error) with nothing to show. */
interface Racer {
  name: "primary" | "fallback";
  model: string;
  abort: AbortController;
  iterator: AsyncIterator<StreamEvent>;
  pending: Promise<IteratorResult<StreamEvent>> | null;
  /** Set once this racer exhausts, so a caller building `RaceFailure`'s
   *  detail after the whole race comes up empty can describe *how* each
   *  side failed without re-deriving it from scratch. */
  outcome?: { failed: true; err: unknown } | { failed: false };
}

function armNext(racer: Racer): void {
  racer.pending = racer.iterator.next();
}

function describeRacerOutcome(outcome: Racer["outcome"]): string {
  if (!outcome) return "not attempted";
  return outcome.failed ? `upstream_error: ${describeUpstreamError(outcome.err)}` : "empty";
}

/**
 * Runs `primary`, and -- unless `fallback` is `undefined` (the canary's
 * `probe.disableFallback`) -- `fallback` too, either sequentially (the
 * moment `primary` fails or exhausts with no content, before the hedge
 * would even have fired) or concurrently (the moment `hedgeAfterMs` passes
 * with `primary` still silent), and resolves once either produces a
 * content delta or both have nothing left to try. This is the entire
 * "which model actually answers" decision for one request; `handleAsk`
 * only has to turn the result into a 502 or a call to `runAskStream`.
 *
 * Every `.next()` call across both racers is raced with `Promise.race`
 * against a one-shot hedge timer (armed only while `fallback` hasn't
 * started yet) and, from the moment either racer starts, against nothing
 * else time-wise -- the *overall* `totalBudgetMs` ceiling is a separate
 * timer that aborts whichever racers are still active when it fires, so a
 * primary that neither answers nor ever cleanly ends (a stalled connection
 * OpenRouter never closes) cannot hold this function open past that point.
 * A `usage`/`done`-typed `StreamEvent` from a racer is not a win -- only a
 * `delta` is -- so such events just re-arm that racer's `.next()` and the
 * race continues.
 */
async function runHedgedRace(options: {
  buildStreamOptions: (model: string, reasoning: unknown, signal: AbortSignal) => Parameters<typeof chatCompletionStream>[0];
  primary: RaceCandidate;
  fallback: RaceCandidate | undefined;
  hedgeAfterMs: number;
  totalBudgetMs: number;
  startedAt: number;
}): Promise<{ ok: true; winner: RaceWinner } | { ok: false; failure: RaceFailure }> {
  const { buildStreamOptions, primary, fallback, hedgeAfterMs, totalBudgetMs, startedAt } = options;

  const allRacers: Racer[] = [];

  function startRacer(name: "primary" | "fallback", candidate: RaceCandidate): Racer {
    const abort = new AbortController();
    const upstream = chatCompletionStream(buildStreamOptions(candidate.model, candidate.reasoning, abort.signal));
    const racer: Racer = {
      name,
      model: candidate.model,
      abort,
      iterator: upstream[Symbol.asyncIterator](),
      pending: null,
    };
    armNext(racer);
    allRacers.push(racer);
    return racer;
  }

  // The overall ceiling: aborts every racer still active when it fires,
  // independent of the hedge. Cleared once the race concludes one way or
  // the other so it never fires against a request that's already moved on
  // to streaming a winner's answer.
  const totalBudgetTimer = setTimeout(() => {
    for (const racer of allRacers) {
      if (racer.pending) racer.abort.abort();
    }
  }, remainingBudget(startedAt, Date.now(), totalBudgetMs));

  const primaryRacer = startRacer("primary", primary);
  let fallbackRacer: Racer | undefined;
  let hedgeTimerID: number | undefined;
  let hedgeSignal: Promise<"hedge"> | undefined;
  if (fallback) {
    hedgeSignal = new Promise((resolve) => {
      hedgeTimerID = setTimeout(() => resolve("hedge"), hedgeAfterMs);
    });
  }

  // Tracks *why* the fallback started, for `RaceWinner.detail` below --
  // "the hedge timer fired while the primary was still active" reads very
  // differently to a canary than "the primary had already failed or
  // emptied," even though both go through this same `startRacer` call.
  let fallbackStartedViaHedge = false;

  function maybeStartFallbackNow(viaHedge: boolean): void {
    if (!fallback || fallbackRacer) return;
    if (hedgeTimerID !== undefined) clearTimeout(hedgeTimerID);
    hedgeSignal = undefined;
    fallbackStartedViaHedge = viaHedge;
    fallbackRacer = startRacer("fallback", fallback);
    // `startRacer` only arms the racer's own `.next()` and records it in
    // `allRacers` (for the total-budget abort sweep and the post-race
    // failure report); it does not know about `active`, the set the race
    // loop below actually polls, so without this the fallback would run a
    // real request to completion with nothing ever reading its output.
    active = [...active, fallbackRacer];
  }

  let active: Racer[] = [primaryRacer];

  try {
    while (active.length > 0) {
      const racerEntries = active.map((racer) =>
        racer.pending!.then((value) => ({ tag: "racer" as const, racer, ok: true as const, value }))
          .catch((err) => ({ tag: "racer" as const, racer, ok: false as const, err }))
      );
      const raceEntries: Array<Promise<
        | { tag: "racer"; racer: Racer; ok: true; value: IteratorResult<StreamEvent> }
        | { tag: "racer"; racer: Racer; ok: false; err: unknown }
        | { tag: "hedge" }
      >> = [...racerEntries];
      if (hedgeSignal) raceEntries.push(hedgeSignal.then(() => ({ tag: "hedge" as const })));

      const settled = await Promise.race(raceEntries);

      if (settled.tag === "hedge") {
        // Re-check with the pure predicate rather than trusting the timer
        // callback alone -- by the time this microtask runs, `active`
        // could already be down to just the fallback (the primary
        // exhausted and `maybeStartFallbackNow` already ran) or the loop
        // could already be about to exit with a winner; `shouldStartHedge`
        // is the single place that decides "no delta yet" for both this
        // and the timer callback itself.
        if (shouldStartHedge({ firstDeltaAt: undefined, now: Date.now(), startedAt, hedgeAfterMs })) {
          maybeStartFallbackNow(true);
        }
        continue;
      }

      const { racer } = settled;
      if (!settled.ok) {
        racer.pending = null;
        racer.outcome = { failed: true, err: settled.err };
        active = active.filter((r) => r !== racer);
        if (racer.name === "primary") maybeStartFallbackNow(false);
        continue;
      }

      if (settled.value.done) {
        racer.pending = null;
        racer.outcome = { failed: false };
        active = active.filter((r) => r !== racer);
        if (racer.name === "primary") maybeStartFallbackNow(false);
        continue;
      }

      const event = settled.value.value;
      if (event.type === "delta") {
        for (const other of allRacers) {
          if (other !== racer && other.pending) other.abort.abort();
        }
        // Three shapes for `detail`: the ordinary case (no fallback ever
        // started -- the primary answered on its own, `undefined`, nothing
        // remarkable to record); a genuine hedge win (the fallback started
        // because the timer fired while the primary was still active, and
        // either model could have been the one to answer -- `racer.model`
        // says which); and a sequential fallback (the fallback only started
        // because the primary had already failed or emptied outright, so
        // there was never actually a race to describe).
        const detail = !fallbackRacer
          ? undefined
          : fallbackStartedViaHedge
          ? outcomeDetailForHedgeWin(hedgeAfterMs, racer.model)
          : outcomeDetailForFallback(primary.model, primaryRacer.outcome?.failed ? "upstream_error" : "empty");
        return {
          ok: true,
          winner: { model: racer.model, iterator: racer.iterator, first: settled.value, detail },
        };
      }

      // `usage` or `done`-typed `StreamEvent` -- not a win, keep racing.
      armNext(racer);
    }
  } finally {
    clearTimeout(totalBudgetTimer);
    if (hedgeTimerID !== undefined) clearTimeout(hedgeTimerID);
  }

  // Every racer that ever started exhausted with nothing. `fallback`
  // configured-but-never-started can't happen here -- the loop only exits
  // once `active` is empty, and the primary exhausting always calls
  // `maybeStartFallbackNow` first when a fallback is configured.
  const failedModel = fallbackRacer?.model ?? primaryRacer.model;
  const detail = fallback
    ? `primary ${primary.model} ${describeRacerOutcome(primaryRacer.outcome)}; fallback ${fallback.model} ${
      describeRacerOutcome(fallbackRacer?.outcome)
    }`.slice(0, 200)
    : describeRacerOutcome(primaryRacer.outcome);
  const failureCause = fallbackRacer?.outcome?.failed
    ? fallbackRacer.outcome.err
    : primaryRacer.outcome?.failed
    ? primaryRacer.outcome.err
    : undefined;
  const upstreamStatus = failureCause instanceof UpstreamError ? failureCause.status : undefined;

  return {
    ok: false,
    failure: { model: failedModel, detail, upstreamStatus, cause: failureCause },
  };
}
