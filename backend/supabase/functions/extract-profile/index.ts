// Rebuilds `course_profiles` rows for courses the caller is enrolled in
// and whose `profile_stale` flag is set. See PROTOCOL.md's
// "extract-profile" section for the wire contract.
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";
import { HttpError, corsHeaders, errorResponse, json, readJSON } from "../_shared/http.ts";
import { requireUser } from "../_shared/auth.ts";
import { checkQuota, limitsFromEnv } from "../_shared/quota.ts";
import { chatCompletionJSON, UpstreamError } from "../_shared/openrouter.ts";
import {
  PROFILE_INSTRUCTIONS,
  type ProfileSourceDocument,
  parseProfile,
  profileSourceHash,
  selectProfileInput,
} from "../_shared/profile.ts";

const MAX_COURSE_IDS = 20;
const DEFAULT_PROFILE_INPUT_CHARS = 60000;
const PROFILE_KINDS = ["syllabus", "home", "page"] as const;

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

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const { userId, serviceClient } = await requireUser(req);
    const body = parseBody(await readJSON<unknown>(req));
    if (!body) {
      return errorResponse("bad_request", "malformed extract-profile request", 400);
    }

    const quotaResponse = await checkAndConsumeQuota(serviceClient, userId);
    if (quotaResponse) return quotaResponse;

    if (body.courseIDs.length === 0) {
      return json(200, { updated: [] });
    }

    const staleIDs = await staleEnrolledCourseIDs(serviceClient, userId, body.courseIDs);
    if (staleIDs.length === 0) {
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

    const updated: string[] = [];
    for (const courseID of staleIDs) {
      const wasUpdated = await rebuildProfile({
        serviceClient,
        courseID,
        maxChars,
        apiKey,
        model,
        fallbackModel,
        provider: providerFromEnv(),
      });
      if (wasUpdated) updated.push(courseID);
    }

    return json(200, { updated });
  } catch (err) {
    if (err instanceof HttpError) {
      return errorResponse("unauthorized", err.message, err.status);
    }
    console.error("extract-profile: unhandled failure", err);
    return errorResponse("bad_request", "request failed", 400);
  }
});

/**
 * Checks the same daily/monthly quota `ask` uses, and -- if the caller is
 * under quota -- immediately records one request against it. This call
 * counts once per invocation, not once per course rebuilt: a single
 * `extract-profile` call can rebuild several courses' profiles at once
 * (the sync client fires it once per upload with every `profileStale` id
 * from that run), and metering per course would let one sync spend the
 * quota as fast as several separate calls would.
 */
async function checkAndConsumeQuota(
  serviceClient: SupabaseClient,
  userId: string,
): Promise<Response | undefined> {
  const { data, error } = await serviceClient.rpc("ask_usage_counts", { p_user_id: userId });
  if (error) {
    console.error("extract-profile: ask_usage_counts failed", error.message);
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

  const { error: recordError } = await serviceClient.rpc("record_ask_usage", {
    p_user_id: userId,
    p_prompt_tokens: 0,
    p_completion_tokens: 0,
  });
  if (recordError) {
    console.error("extract-profile: record_ask_usage failed", recordError.message);
  }
  return undefined;
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
    .select("id, kind, title, text, content_hash")
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
