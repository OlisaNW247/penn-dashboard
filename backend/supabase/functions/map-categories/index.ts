// Maps a course's Canvas assignment-group structure onto the grading
// categories that course's syllabus already states (`course_profiles.
// profile.gradingWeights`), for Grade Watcher to offer as a suggested
// mapping the student confirms. See PROTOCOL.md's "map-categories"
// section for the wire contract, and `_shared/categoryMap.ts` for the
// validation/hashing/prompt/sanitizing logic this file wires together --
// the same thin-index-file, fat-shared-module split `extract-profile` and
// `extract-announcement` already follow.
//
// Privacy: the request this function accepts carries only assignment-group
// and item *names* and *points possible* -- never a score, a submission,
// or any other student-specific fact (`parseMapCategoriesBody` builds its
// own output objects field by field, so an extra key on the client's JSON
// is simply never read, not merely ignored-but-present). The response is
// cached per course on `course_profiles` and shared across every student
// enrolled in it, exactly like `course_profiles.profile` already is --
// the structure being mapped (a course's own assignment-group names) is
// the same fact for every student in the course, not a private one.
import { HttpError, corsHeaders, errorResponse, json, readJSON } from "../_shared/http.ts";
import { requireUser } from "../_shared/auth.ts";
import { checkQuota, limitsFromEnv } from "../_shared/quota.ts";
import { chatCompletionJSON, UpstreamError } from "../_shared/openrouter.ts";
import { selectCourseProfileForCategoryMap, selectEnrolledCourseIDs, storeCategoryMap } from "../_shared/db.ts";
import {
  CATEGORY_MAP_INSTRUCTIONS,
  buildCategoryMapUserContent,
  parseCategoryMapping,
  parseMapCategoriesBody,
  sanitizeCategoryMapping,
  structureHash,
  type CategoryMapping,
} from "../_shared/categoryMap.ts";
import type { SupabaseClient } from "npm:@supabase/supabase-js@2";

const DEFAULT_MAP_DAILY_LIMIT = 20;

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") {
    return new Response(null, { headers: corsHeaders });
  }

  try {
    const { userId, serviceClient } = await requireUser(req);
    const body = parseMapCategoriesBody(await readJSON<unknown>(req));
    if (!body) {
      return errorResponse("bad_request", "malformed map-categories request", 400);
    }

    // Enrollment is this backend's one proof of access to a course's
    // material throughout (see PROTOCOL.md's "Limitations" section);
    // `discover-websites/index.ts` gates the same way for the same
    // reason -- a course's assignment-group *structure* is course-level
    // material like everything else this table stores, so it holds
    // itself to the identical gate.
    const enrolledCourseIDs = await selectEnrolledCourseIDs(serviceClient, userId);
    if (!enrolledCourseIDs.has(body.courseID)) {
      throw new HttpError(403, "not_enrolled", `not enrolled in course ${body.courseID}`);
    }

    const courseRow = await selectCourseProfileForCategoryMap(serviceClient, body.courseID);
    if (!courseRow || courseRow.gradingWeights.length === 0) {
      // No `course_profiles` row yet (no syllabus has ever been
      // extracted for this course), or one whose syllabus stated no
      // grading weights at all -- either way there is nothing to map
      // Canvas groups onto. Per the brief this degrades to `mapping:
      // null` rather than an error, and -- deliberately, unlike
      // `extract-profile`'s own quota accounting -- never touches the
      // quota, since no model call happens on this path. See the
      // cache-hit branch below for why "no model call, no quota spend" is
      // this function's rule throughout, not just for cache hits.
      return json(200, { mapping: null });
    }

    const validGroupIDs = new Set(body.groups.map((group) => group.id));
    const validItemIDs = new Set(body.groups.flatMap((group) => group.items.map((item) => item.id)));
    const validCategoryNames = courseRow.gradingWeights.map((weight) => weight.name);
    const hash = await structureHash(body.groups);

    if (courseRow.categoryMapHash === hash) {
      // Cache hit -- the brief's whole point in caching this per course
      // rather than per request: a structure this backend has already
      // mapped for one student in the course answers every classmate's
      // identical request with no further model call. Re-run the stored
      // value through `sanitizeCategoryMapping` against *this* request's
      // own valid-id/name sets rather than trusting the stored jsonb
      // blindly -- the normalize-on-read discipline CLAUDE.md's jsonb
      // trap requires of every jsonb column in this schema (a future
      // change to this module's output shape must not make an
      // already-cached row return something today's client can't parse).
      // No quota check, no model call: "cache hits do not count" per the
      // brief.
      const cached = sanitizeCategoryMapping(courseRow.categoryMap, {
        validCategoryNames,
        validGroupIDs,
        validItemIDs,
        extractedAt: courseRow.categoryMapAt ?? new Date().toISOString(),
        structureHash: hash,
      });
      return json(200, { mapping: cached });
    }

    const quotaResponse = await checkAndConsumeQuota(serviceClient, userId);
    if (quotaResponse) return quotaResponse;

    const apiKey = Deno.env.get("OPENROUTER_API_KEY");
    if (!apiKey) {
      console.error("map-categories: OPENROUTER_API_KEY is not configured");
      return errorResponse("upstream", "model backend is not configured", 502);
    }
    const model = Deno.env.get("LHF_MODEL") ?? "z-ai/glm-5.3-flash";
    const fallbackModel = Deno.env.get("LHF_FALLBACK_MODEL") ?? "openai/gpt-5.6-luna";

    const userContent = buildCategoryMapUserContent(courseRow.gradingWeights, body.groups);

    let text: string;
    try {
      text = await chatCompletionJSON({
        fetchImpl: fetch,
        apiKey,
        model,
        fallbackModel,
        provider: providerFromEnv(),
        messages: [
          { role: "system", content: CATEGORY_MAP_INSTRUCTIONS },
          { role: "user", content: userContent },
        ],
        maxTokens: 2000,
        temperature: 0,
      });
    } catch (err) {
      const status = err instanceof UpstreamError ? err.status : undefined;
      console.error("map-categories: upstream failure, status:", status ?? "network");
      return errorResponse("upstream", "the model backend failed", 502);
    }

    const mapping: CategoryMapping | null = parseCategoryMapping(text, {
      validCategoryNames,
      validGroupIDs,
      validItemIDs,
      extractedAt: new Date().toISOString(),
      structureHash: hash,
    });

    if (mapping) {
      try {
        await storeCategoryMap(serviceClient, body.courseID, mapping, hash);
      } catch (err) {
        // A caching write failure shouldn't turn into a user-visible
        // error when the actual mapping the caller just spent quota on
        // is already in hand -- the next request for this course simply
        // misses the cache and calls the model again, same as if this
        // row had never been written.
        console.error(
          "map-categories: storeCategoryMap failed",
          body.courseID,
          err instanceof Error ? err.message : String(err),
        );
      }
    }

    return json(200, { mapping });
  } catch (err) {
    if (err instanceof HttpError) {
      return errorResponse(err.code, err.message, err.status);
    }
    console.error("map-categories: unhandled failure", err);
    return errorResponse("bad_request", "request failed", 400);
  }
});

/**
 * Checks the `MAP_DAILY_LIMIT`-per-user daily quota (default 20) against
 * the same shared `ask_usage` counters `ask`/`extract-profile`/
 * `extract-announcement` already write to -- one pool of per-user daily
 * requests and one global monthly figure across every model-calling
 * function in this backend, not a separate counter per function, which is
 * why this reads `ASK_MONTHLY_GLOBAL_LIMIT` for the monthly half via
 * `limitsFromEnv` while overriding only the daily half with this
 * function's own env var. Records one request against the quota
 * immediately, before the model call actually happens, mirroring
 * `extract-profile`'s and `extract-announcement`'s own ordering; unlike
 * either of those, this function only ever reaches this point on a cache
 * *miss* (see the cache-hit branch and the no-profile early return above),
 * so "recorded unconditionally once this line runs" and "cache hits don't
 * count" are the same rule stated from two directions.
 */
async function checkAndConsumeQuota(
  serviceClient: SupabaseClient,
  userId: string,
): Promise<Response | undefined> {
  const { data, error } = await serviceClient.rpc("ask_usage_counts", { p_user_id: userId });
  if (error) {
    console.error("map-categories: ask_usage_counts failed", error.message);
    return errorResponse("upstream", "usage lookup failed", 502);
  }
  const row = Array.isArray(data) ? data[0] : data;
  const dailyLimit = parsePositiveInt(Deno.env.get("MAP_DAILY_LIMIT"), DEFAULT_MAP_DAILY_LIMIT);
  const monthlyGlobalLimit = limitsFromEnv(Deno.env).monthlyGlobalLimit;
  const quota = checkQuota({
    todayRequests: row?.today_requests ?? 0,
    monthRequests: row?.month_requests ?? 0,
    dailyLimit,
    monthlyGlobalLimit,
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
    console.error("map-categories: record_ask_usage failed", recordError.message);
  }
  return undefined;
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
