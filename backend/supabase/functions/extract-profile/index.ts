// Rebuilds `course_profiles` rows for courses the caller is enrolled in
// and whose `profile_stale` flag is set. See PROTOCOL.md's
// "extract-profile" section for the wire contract.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2.115.0";
import { HttpError, corsHeaders, errorResponse, json, readJSON } from "../_shared/http.ts";
import { enforceMinimumVersion } from "../_shared/version.ts";
import { requireUser } from "../_shared/auth.ts";
import { limitsFromEnv, reserveUsage, type UsageLease } from "../_shared/quota.ts";
import { chatCompletionJSON, UpstreamError } from "../_shared/openrouter.ts";
import {
  isCoolingDown,
  PROFILE_INSTRUCTIONS,
  type ProfileSourceDocument,
  parseProfile,
  profileSourceHash,
  selectProfileInput,
} from "../_shared/profile.ts";

const MAX_COURSE_IDS = 20;
const DEFAULT_PROFILE_INPUT_CHARS = 60000;
// One call may rebuild up to MAX_COURSE_IDS profiles, each a model call over up
// to PROFILE_INPUT_CHARS of material, run one after another, and nothing used
// to bound the total: twenty slow calls could outlast the function's wall-clock
// limit and be cut off in the middle of a write. Past this budget no further
// course is started, and a call already in flight is aborted at it. A course
// that was not reached, or whose call was cut off, keeps `profile_stale` set,
// which is exactly how an upstream failure is already handled, so the next
// sync's call picks it up. The budget sits inside the 60 s a phone waits and
// well inside the runtime's own limit.
const DEFAULT_PROFILE_BUDGET_MS = 40_000;
// `website` is included here even though not every `website`-kind row is
// actually used -- `selectProfileInput` (see `_shared/profile.ts`) filters
// those further to the ones whose title/URL looks profile-relevant
// (syllabus/policy/grading/logistics/schedule). Fetching the kind here and
// filtering there, rather than filtering in this query, keeps that
// judgment call in the one pure, unit-tested module rather than splitting
// it across a SQL filter and application code.
const PROFILE_KINDS = ["syllabus", "home", "page", "website"] as const;

interface ExtractProfileBody {
  courseIDs: string[];
}

function parseBody(value: unknown): ExtractProfileBody | undefined {
  if (typeof value !== "object" || value === null) return undefined;
  const courseIDs = (value as Record<string, unknown>).courseIDs;
  if (!Array.isArray(courseIDs) || !courseIDs.every((id): id is string => typeof id === "string")) {
    return undefined;
  }
  if (courseIDs.length > MAX_COURSE_IDS) return undefined;
  return { courseIDs };
}

export async function handleExtractProfile(req: Request): Promise<Response> {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    // The Chrome extension calls this function and never sends the version
    // header, so only a present-and-below-floor header is refused here;
    // never the "header required" switch (headerOptional).
    await enforceMinimumVersion(req, { headerOptional: true });

    const { userId, serviceClient } = await requireUser(req);
    const body = parseBody(await readJSON<unknown>(req));
    if (!body) {
      return errorResponse("bad_request", "malformed extract-profile request", 400);
    }

    const quota = await checkAndConsumeQuota(serviceClient, userId);
    if (quota.response) return quota.response;
    const lease = quota.lease;

    if (body.courseIDs.length === 0) {
      return json(200, { updated: [] });
    }

    const staleIDs = await staleEnrolledCourseIDs(serviceClient, userId, body.courseIDs);
    if (staleIDs.length === 0) {
      return json(200, { updated: [] });
    }

    // Courses whose last build was cut off by the time budget are left alone
    // for a day (`profile_budget_aborted_at`; see the migration): a course
    // that always overruns would otherwise cost a unit of quota and 40
    // seconds on every sync, for nothing. They stay stale and are tried again
    // once the cool-down ends.
    const stamps = await selectBudgetAbortStamps(serviceClient, staleIDs);
    const now = new Date();
    const attemptIDs = staleIDs.filter((id) => !isCoolingDown(stamps.get(id), now));
    if (attemptIDs.length === 0) {
      // Nothing left to do but courses that are cooling down: no model call
      // is made, so the unit reserved up front is given back. (Safe to refund:
      // no model spend happened, unlike a refund after an aborted call.)
      await lease.release();
      return json(200, { updated: [] });
    }

    const apiKey = Deno.env.get("OPENROUTER_API_KEY");
    if (!apiKey) {
      console.error("extract-profile: OPENROUTER_API_KEY is not configured");
      return errorResponse("upstream", "model backend is not configured", 502);
    }
    const model = Deno.env.get("LHF_MODEL") ?? "z-ai/glm-5.3-flash";
    const fallbackModel = Deno.env.get("LHF_FALLBACK_MODEL") ?? "openai/gpt-5.6-luna";
    const maxChars = parsePositiveInt(
      Deno.env.get("PROFILE_INPUT_CHARS"),
      DEFAULT_PROFILE_INPUT_CHARS,
    );

    const budgetMs = parsePositiveInt(Deno.env.get("EXTRACT_PROFILE_BUDGET_MS"), DEFAULT_PROFILE_BUDGET_MS);
    const deadline = Date.now() + budgetMs;

    const updated: string[] = [];
    let skipped = 0;
    for (const courseID of attemptIDs) {
      const remaining = deadline - Date.now();
      if (remaining <= 0) {
        skipped += 1;
        continue;
      }
      // The model call is aborted when the budget runs out, so one slow
      // course cannot carry the call past it.
      const controller = new AbortController();
      const timer = setTimeout(() => controller.abort(), remaining);
      try {
        const wasUpdated = await rebuildProfile({
          serviceClient,
          courseID,
          maxChars,
          apiKey,
          model,
          fallbackModel,
          provider: providerFromEnv(),
          signal: controller.signal,
        });
        if (wasUpdated) {
          updated.push(courseID);
          // A build that succeeds ends the cool-down it was in.
          if (stamps.has(courseID)) await setBudgetAbortStamp(serviceClient, courseID, null);
        } else if (controller.signal.aborted) {
          // The budget cut this course's model call off: remember it.
          await setBudgetAbortStamp(serviceClient, courseID, new Date().toISOString());
        }
      } finally {
        clearTimeout(timer);
      }
    }
    if (skipped > 0) {
      // Counts only, never a course id or any material.
      console.warn(`extract-profile: time budget spent, ${skipped} course(s) left stale for the next call`);
    }

    return json(200, { updated });
  } catch (err) {
    if (err instanceof HttpError) {
      // 426 must keep its own code: the app keys its update wall on "update_required".
      return errorResponse(err.status === 426 ? err.code : "unauthorized", err.message, err.status);
    }
    console.error("extract-profile: unhandled failure", err);
    return errorResponse("bad_request", "request failed", 400);
  }
}

// Guarded by `import.meta.main`, like `ask/index.ts`, so a test can import
// `handleExtractProfile` without starting a second server. Deployed, this file
// is the entry point the runtime executes, so it serves exactly as before.
if (import.meta.main) {
  Deno.serve(handleExtractProfile);
}

/**
 * Reserves one request against the same daily/monthly quota `ask` uses, or
 * refuses with a 429. The check and the charge are one statement
 * (`reserveUsage`), where this used to read the count, decide, and then
 * write: ten parallel calls all read the same count and all went through,
 * which for a function that makes up to twenty model calls per invocation
 * is the expensive end of the hole. Counted once per invocation, not once
 * per course rebuilt: a single `extract-profile` call can rebuild several
 * courses' profiles at once (the sync client fires it once per upload with
 * every `profileStale` id from that run), and metering per course would let
 * one sync spend the quota as fast as several separate calls would. Charged
 * up front and kept, exactly as before, once any course is attempted: the work
 * is paid for once started, whatever it finds. The one exception is a call
 * with nothing to attempt but courses cooling down after a budget abort, which
 * makes no model call and gives the unit back (the caller releases the lease).
 * A counter that stalls fails open (unmetered), as in `ask`.
 *
 * Deliberately not tied to the client's connection: the sync client fires
 * this without awaiting it and a suspended app drops the connection, while
 * the profile it is building is shared with every classmate, so aborting on
 * disconnect would throw away paid work and leave `profile_stale` set for
 * the next sync to pay for again.
 */
async function checkAndConsumeQuota(
  serviceClient: SupabaseClient,
  userId: string,
): Promise<{ response: Response; lease?: undefined } | { response?: undefined; lease: UsageLease }> {
  const reservation = await reserveUsage(serviceClient, userId, limitsFromEnv(Deno.env));
  if (reservation.status === "denied") {
    return { response: json(429, { error: "quota_exceeded", resetAt: reservation.resetAt.toISOString() }) };
  }
  return { lease: reservation.lease };
}

/** `profile_budget_aborted_at` for the given courses, keyed by course id, only
 *  those that have one. Best-effort on purpose: if the read fails (the
 *  migration that adds the column has not been applied yet) it reads as "no
 *  course is cooling down" and the function behaves as it did before, so the
 *  function and the migration can go out in either order. The stale-course
 *  read above is a separate query for the same reason: a missing column must
 *  never be able to stop profiles being built. */
async function selectBudgetAbortStamps(
  serviceClient: SupabaseClient,
  courseIDs: string[],
): Promise<Map<string, string>> {
  const stamps = new Map<string, string>();
  const { data, error } = await serviceClient
    .from("courses")
    .select("course_id, profile_budget_aborted_at")
    .in("course_id", courseIDs);
  if (error || !data) {
    console.warn("extract-profile: budget cool-down lookup failed, treating no course as cooling down");
    return stamps;
  }
  for (const row of data as Array<{ course_id: string; profile_budget_aborted_at: string | null }>) {
    if (row.profile_budget_aborted_at) stamps.set(row.course_id, row.profile_budget_aborted_at);
  }
  return stamps;
}

/** Stamps (or, with `null`, clears) a course's budget-abort marker. Best-effort,
 *  for the same reason as the read: failing to write it costs one repeated
 *  attempt, never a lost profile. */
async function setBudgetAbortStamp(
  serviceClient: SupabaseClient,
  courseID: string,
  stamp: string | null,
): Promise<void> {
  const { error } = await serviceClient
    .from("courses")
    .update({ profile_budget_aborted_at: stamp })
    .eq("course_id", courseID);
  if (error) console.warn("extract-profile: could not record the budget cool-down, it will be retried next call");
}

/** Intersects `courseIDs` with the caller's actual enrollments, then
 *  further narrows to courses currently flagged `profile_stale`. Two
 *  queries, not a join, for the same reason `ask/index.ts` uses two: this
 *  runs as `service_role` and RLS does not apply, so the enrollment check
 *  is this function's job. */
async function staleEnrolledCourseIDs(
  serviceClient: SupabaseClient,
  userId: string,
  courseIDs: string[],
): Promise<string[]> {
  const { data: enrollments, error: enrollError } = await serviceClient
    .from("enrollments")
    .select("course_id")
    .eq("user_id", userId)
    .in("course_id", courseIDs);
  if (enrollError || !enrollments) {
    console.error("extract-profile: enrollments lookup failed", enrollError?.message);
    return [];
  }
  const enrolledIDs = enrollments.map((row: { course_id: string }) => row.course_id);
  if (enrolledIDs.length === 0) return [];

  const { data: courses, error: courseError } = await serviceClient
    .from("courses")
    .select("course_id, profile_stale")
    .in("course_id", enrolledIDs);
  if (courseError || !courses) {
    console.error("extract-profile: courses lookup failed", courseError?.message);
    return [];
  }

  return (courses as Array<{ course_id: string; profile_stale: boolean }>)
    .filter((course) => course.profile_stale)
    .map((course) => course.course_id);
}

interface RebuildProfileOptions {
  serviceClient: SupabaseClient;
  courseID: string;
  maxChars: number;
  apiKey: string;
  model: string;
  fallbackModel: string;
  provider?: { order?: string[] };
  /** Aborts the model call when the call's time budget runs out. */
  signal?: AbortSignal;
}

/** Rebuilds one course's profile. Returns whether it actually produced and
 *  stored a new profile -- `false` covers every "nothing to do, or
 *  something failed" outcome, and every one of those still clears
 *  `profile_stale` where appropriate rather than leaving the course stuck
 *  re-attempting on every future call, *except* an upstream model failure,
 *  which deliberately leaves the flag set so the next sync's
 *  `extract-profile` call tries again. */
async function rebuildProfile(options: RebuildProfileOptions): Promise<boolean> {
  const { serviceClient, courseID } = options;

  const { data: docs, error: docsError } = await serviceClient
    .from("course_documents")
    .select("id, kind, title, text, content_hash, url")
    .eq("course_id", courseID)
    .in("kind", PROFILE_KINDS)
    .is("gone_at", null);
  if (docsError || !docs) {
    console.error("extract-profile: course_documents lookup failed", courseID, docsError?.message);
    return false;
  }

  const sourceDocs = docs as ProfileSourceDocument[];
  const input = selectProfileInput(sourceDocs, options.maxChars);

  if (input.length === 0) {
    // No live syllabus/home/page document to build a profile from. Still
    // clear the flag -- otherwise this course would be re-attempted on
    // every future extract-profile call until it happens to gain a
    // document of one of those kinds, for no benefit.
    await clearProfileStale(serviceClient, courseID);
    return false;
  }

  let profileText: string;
  try {
    profileText = await chatCompletionJSON({
      fetchImpl: fetch,
      apiKey: options.apiKey,
      model: options.model,
      fallbackModel: options.fallbackModel,
      provider: options.provider,
      messages: [
        { role: "system", content: PROFILE_INSTRUCTIONS },
        { role: "user", content: input },
      ],
      maxTokens: 2000,
      temperature: 0,
      signal: options.signal,
    });
  } catch (err) {
    const status = err instanceof UpstreamError ? err.status : undefined;
    console.error("extract-profile: upstream failure", courseID, "status:", status ?? "network");
    return false; // leave profile_stale set; retry on the next call
  }

  const profile = parseProfile(profileText);
  const sourceHash = await profileSourceHash(sourceDocs);

  const { error: upsertError } = await serviceClient
    .from("course_profiles")
    .upsert({
      course_id: courseID,
      profile,
      source_hash: sourceHash,
      model: options.model,
      updated_at: new Date().toISOString(),
    });
  if (upsertError) {
    console.error("extract-profile: course_profiles upsert failed", courseID, upsertError.message);
    return false;
  }

  const cleared = await clearProfileStale(serviceClient, courseID);
  return cleared;
}

async function clearProfileStale(serviceClient: SupabaseClient, courseID: string): Promise<boolean> {
  const { error } = await serviceClient
    .from("courses")
    .update({ profile_stale: false })
    .eq("course_id", courseID);
  if (error) {
    console.error("extract-profile: clearing profile_stale failed", courseID, error.message);
    return false;
  }
  return true;
}

function providerFromEnv(): { order?: string[] } | undefined {
  const raw = Deno.env.get("LHF_PROVIDER_ORDER");
  if (!raw) return undefined;
  const order = raw.split(",").map((entry) => entry.trim()).filter((entry) => entry.length > 0);
  return order.length > 0 ? { order } : undefined;
}

function parsePositiveInt(raw: string | undefined, fallback: number): number {
  if (raw === undefined) return fallback;
  const parsed = Number.parseInt(raw, 10);
  return Number.isFinite(parsed) && parsed > 0 ? parsed : fallback;
}
